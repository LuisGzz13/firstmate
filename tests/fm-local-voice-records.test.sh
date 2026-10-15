#!/usr/bin/env bash
# tests/fm-local-voice-records.test.sh - our local additions to the voice records status answer.
#
# Part of the local layer (docs/local-layer.md): these cases cover
# bin/fm_local_voice_records.py, bin/fm-local-voice-fleet-states.sh and
# bin/fm-local-classify-lib.sh, so tests/fm-voice-relay.test.sh stays upstream's.
# They also hold the layer's own promise: with the local files absent, the
# upstream modules they hook into answer exactly as upstream does.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-local-voice-records)

# --- live captain holds -----------------------------------------------------
#
# The live count drives the Beacon's white flash, so a hold deferred to a future
# hold-until date must stay out of it while still counting as waiting overall.
# Dates sit far from today so the case never depends on when it runs.

LIVE_HOME="$TMP_ROOT/live-holds"
mkdir -p "$LIVE_HOME/data" "$LIVE_HOME/state" "$LIVE_HOME/config"
cat > "$LIVE_HOME/data/backlog.md" <<'EOF'
# Backlog

## Queued
- [ ] undated-call - Undated captain call (kind: captain) (hold: choose) (hold-kind: captain)
- [ ] due-call - Captain call whose deferral has passed (kind: captain) (hold: choose) (hold-kind: captain) (hold-until: 2000-01-01)
- [ ] later-call - Captain call deferred to later (kind: captain) (hold: choose) (hold-kind: captain) (hold-until: 2999-12-31)
EOF
for scope in counts full; do
  live=$(python3 "$ROOT/bin/fm_voice_records.py" status --home "$LIVE_HOME" --scope "$scope") \
    || fail "live-hold fixture failed at $scope scope"
  assert_contains "$live" '"awaiting_captain": 3' \
    "a deferred hold should still count as waiting on the captain at $scope scope"
  assert_contains "$live" '"awaiting_captain_live": 2' \
    "a hold deferred to a future date should leave the live count at $scope scope"
done
pass "the live captain count excludes only holds deferred to a future date"

# --- the local layer is optional --------------------------------------------
#
# Upstream does not have the local files. Without them, the upstream module and
# library must run as upstream does: no added keys, no error, no wrap.

BARE="$TMP_ROOT/bare-bin"
mkdir -p "$BARE"
cp "$ROOT/bin/fm_voice_records.py" "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$BARE/"
bare=$(python3 "$BARE/fm_voice_records.py" status --home "$LIVE_HOME" --scope counts) \
  || fail "the upstream module failed without the local layer: $bare"
assert_contains "$bare" '"awaiting_captain": 3' "the upstream count should stand without the local layer"
assert_not_contains "$bare" awaiting_captain_live "the live count is the local layer's to add"
assert_not_contains "$bare" fleet_working "the fleet counts are the local layer's to add"
bare_wrap=$(FM_OPEN_DECISIONS_CURSOR_PEEK=1 bash -c '. "$1/fm-classify-lib.sh"; declare -F _fm_local_upstream_status_open_decisions || echo none' \
  _ "$BARE") || fail "the upstream library failed to source without the local layer"
assert_equals none "$bare_wrap" "without the local file the library must not wrap anything"
pass "without the local files the upstream module and library answer as upstream does"

# --- the cursor wrap is opt-in and steps aside on a fold-version change -----
#
# A cursor whose persisted set disagrees with its log tells the two paths
# apart: only the cursor read reports the planted decision. A real cursor never
# disagrees with its log; this one is planted to make the path visible.
PEEK="$TMP_ROOT/peek"
mkdir -p "$PEEK/state"
printf '%s\n' "working [at=1792000000]: nothing open here" > "$PEEK/state/pk.status"
fm_write_meta "$PEEK/state/pk.meta" "kind=ship"
FM_HOME="$PEEK" bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_incremental "$2" >/dev/null' \
  _ "$ROOT" "$PEEK/state/pk.status"
peek_cursor="$PEEK/state/.pk.open-decisions-cursor"
[ -s "$peek_cursor" ] || fail "the incremental fold did not leave a cursor to plant in"
printf '%s' "blocked [at=1792000000] [key=planted]: only the cursor says so" >> "$peek_cursor"
peek_read() {  # <peek-flag> [<upstream-fold-version>]
  FM_HOME="$PEEK" FM_OPEN_DECISIONS_CURSOR_PEEK=$1 bash -c '
    . "$1/bin/fm-classify-lib.sh"
    [ -z "$3" ] || FM_OPEN_DECISIONS_FOLD_VERSION=$3
    status_open_decisions "$2"' _ "$ROOT" "$PEEK/state/pk.status" "${2:-}"
}
assert_contains "$(peek_read 1)" planted "an opted-in read should answer from the cursor"
assert_not_contains "$(peek_read 0)" planted "a read that did not opt in must fold the whole log"
assert_not_contains "$(peek_read 1 999)" planted \
  "an upstream fold version the local reader was not written for must fall back to the whole log"
pass "the cursor read is opt-in and steps aside when upstream's fold version moves"

# --- fleet counts: every local home, by current state ----------------------
# The Beacon status button lights amber when anything in the fleet is working
# and red when anything is stuck. Reading only this home's workers, by the last
# line of each status log, showed green while a second mate's worker was busy.
# These cases hold the fleet reading to current state across homes: a second
# mate's own workers count, a busy session counts even when its log last says
# "resolved", a declared pause or an open decision counts as neither, and a
# remote or missing home is skipped without failing the read.
command -v jq >/dev/null 2>&1 || { printf 'all local voice records cases passed (fleet counts skipped: no jq)\n'; exit 0; }
FLEET="$TMP_ROOT/fleet"
FLEET_MAIN="$FLEET/main"
FLEET_MATE="$FLEET/mate"
FLEET_BIN="$FLEET/bin"
FLEET_AGENTS="$FLEET/agents"
FLEET_SSH_LOG="$FLEET/ssh.log"
mkdir -p "$FLEET_MAIN/data" "$FLEET_MAIN/state" "$FLEET_MATE/data" "$FLEET_MATE/state" "$FLEET_BIN"

# herdr answers every pane as present and running a claude in the foreground;
# each pane's agent_status comes from $FLEET_AGENTS ("<pane> <status>" lines).
cat > "$FLEET_BIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
pane_status() {
  awk -v p="$1" '$1 == p { s = $2 } END { print s }' "$FM_FAKE_FLEET_AGENTS" 2>/dev/null
}
# A call naming the pane in $FM_FAKE_FLEET_SLOW hangs, as one agent's read does
# on a loaded host, so its read misses the fleet deadline.
for arg in "$@"; do
  case "$arg" in *"${FM_FAKE_FLEET_SLOW:-<none>}"*) sleep 30 ;; esac
done
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane read") printf 'all quiet\n> \n' ;;
  "pane process-info")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"x","shell_pid":%s,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"claude","argv0":"claude"}]}}}\n' "$PPID" ;;
  "agent get")
    status=$(pane_status "${3:-}")
    [ -n "$status" ] || exit 1
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$status" ;;
esac
exit 0
SH
# No validation run exists for any fixture task, and the daemon answers up.
cat > "$FLEET_BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  daemon) printf 'daemon running (pid 4242)\n' ;;
esac
exit 0
SH
# A remote home is never contacted: any ssh attempt is recorded and fails.
cat > "$FLEET_BIN/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_FLEET_SSH_LOG"
exit 255
SH
chmod +x "$FLEET_BIN/herdr" "$FLEET_BIN/no-mistakes" "$FLEET_BIN/ssh"

# A worker carries the semantic busy record its Claude hooks keep, written here
# through the record's one writer exactly as a hook would write it.
fleet_worker() {  # <home> <id> <pane> <busy|idle> <status-line>
  local wt="$FLEET/wt/$2" gen
  mkdir -p "$wt"
  git -C "$wt" init -q -b "fm/$2" 2>/dev/null || { git -C "$wt" init -q && git -C "$wt" checkout -q -b "fm/$2"; }
  fm_write_meta "$1/state/$2.meta" "window=default:$3" "worktree=$wt" "kind=ship" \
    "mode=local-only" "backend=herdr" "harness=claude"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" "$4" --gen "$gen" \
    --source claude-hook --event fixture >/dev/null
  printf '%s\n' "$5" > "$1/state/$2.status"
  printf '%s idle\n' "$3" >> "$FLEET_AGENTS"
}

: > "$FLEET_AGENTS"
# Mid-turn after an answered decision: the log's last line is "resolved", and
# only the current state says this worker is working.
fleet_worker "$FLEET_MATE" sw-work wA:p1 busy "needs-decision [at=1792000000] [key=pin]: which pin"
printf '%s\n' "resolved [at=1792000100] [key=pin]: pin 4" >> "$FLEET_MATE/state/sw-work.status"
fleet_worker "$FLEET_MATE" sw-block wB:p1 idle "blocked [at=1792000000]: the board will not enumerate over USB"
fleet_worker "$FLEET_MATE" sw-pause wC:p1 idle "paused [at=1792000000]: waiting on CI until 2099-01-01T00:00Z"
fleet_worker "$FLEET_MATE" sw-ask wD:p1 idle "needs-decision [at=1792000000] [key=shape]: which payload shape"
fleet_worker "$FLEET_MAIN" mw-pause wE:p1 idle "paused [at=1792000000]: waiting on the captain's hardware"

# The second mate itself: its routed log last says "resolved", the shape the
# last-line reading took for not working, while its session is mid-turn.
fm_write_secondmate_meta "$FLEET_MAIN/state/mate.meta" "$FLEET_MATE" default:wS:p1 starklab claude
printf 'backend=herdr\n' >> "$FLEET_MAIN/state/mate.meta"
printf '%s\n' "needs-decision [at=1792000000] [key=ask]: which colorway" \
  "resolved [at=1792000100] [key=ask]: green idle" > "$FLEET_MAIN/state/mate.status"
printf 'wS:p1 working\n' >> "$FLEET_AGENTS"
# A remote second mate, whose record names its host: skipped, never contacted.
fm_write_secondmate_meta "$FLEET_MAIN/state/far.meta" "/srv/far/home" default:wF:p1 other claude
printf 'remote_host=far.example\nbackend=herdr\n' >> "$FLEET_MAIN/state/far.meta"
printf 'working [at=1792000000]: on the far host\n' > "$FLEET_MAIN/state/far.status"
cat > "$FLEET_MAIN/data/secondmates.md" <<EOF
- mate - Own the lab. (home: $FLEET_MATE; scope: the lab; projects: starklab; added 2026-10-14)
- far - Own the far work. (host: far.example; root: /srv/far; home: /srv/far/home; scope: far work; projects: other; added 2026-10-14)
- gone - Own nothing now. (home: $FLEET/missing; scope: nothing; projects: none; added 2026-10-14)
EOF

fleet_read() {  # [scope]
  PATH="$FLEET_BIN:$PATH" FM_FAKE_FLEET_SLOW="${FLEET_SLOW:-}" FM_FAKE_FLEET_AGENTS="$FLEET_AGENTS" FM_FAKE_FLEET_SSH_LOG="$FLEET_SSH_LOG" \
    python3 "$ROOT/bin/fm_voice_records.py" status --home "$FLEET_MAIN" --scope "${1:-counts}"
}
fleet_field() {  # <json> <field>
  printf '%s' "$1" | python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2"
}
set_pane() {  # <pane> <status>
  awk -v p="$1" -v s="$2" '$1 == p { $2 = s } { print }' "$FLEET_AGENTS" > "$FLEET_AGENTS.new"
  mv "$FLEET_AGENTS.new" "$FLEET_AGENTS"
}

fleet_out=$(fleet_read) || fail "the fleet read failed: $fleet_out"
assert_equals 2 "$(fleet_field "$fleet_out" fleet_working)" \
  "the second mate's working worker and its busy session should both count as working"
assert_equals 1 "$(fleet_field "$fleet_out" fleet_stuck)" \
  "the second mate's blocked worker should count as stuck"
for id in sw-work sw-block sw-pause sw-ask mw-pause mate far; do
  assert_not_contains "$fleet_out" "$id" "the counts scope must not name $id"
done
[ ! -s "$FLEET_SSH_LOG" ] || fail "the fleet read contacted a remote host: $(cat "$FLEET_SSH_LOG")"
pass "fleet counts read every local home by current state, and skip the remote and missing ones"

set_pane wS:p1 idle
fleet_out=$(fleet_read full) || fail "the fleet read failed: $fleet_out"
assert_equals 1 "$(fleet_field "$fleet_out" fleet_working)" \
  "an idle second mate whose log says resolved is not working"
assert_equals 1 "$(fleet_field "$fleet_out" fleet_stuck)" \
  "the full scope carries the same stuck count"
pass "an idle second mate is not working, and a pause or an open decision is neither"

# The primary firstmate session counts while it is mid-turn: the session-lock
# holder's own pane, discovered from its environment, is busy.
if standin=$(fm_agent_standin "$FLEET/standin"); then
  cp "$standin" "$FLEET/standin/claude" 2>/dev/null || ln -sf "$standin" "$FLEET/standin/claude"
  HERDR_ENV=1 HERDR_PANE_ID=wM:p1 HERDR_SESSION=default "$FLEET/standin/claude" 60 >/dev/null 2>&1 &
  primary_pid=$!
  sleep 0.2
  printf '%s\n' "$primary_pid" > "$FLEET_MAIN/state/.lock"
  printf 'wM:p1 working\n' >> "$FLEET_AGENTS"
  fleet_out=$(fleet_read) || fail "the fleet read failed: $fleet_out"
  primary_busy=$(fleet_field "$fleet_out" fleet_working)
  set_pane wM:p1 idle
  fleet_out=$(fleet_read) || fail "the fleet read failed: $fleet_out"
  primary_idle=$(fleet_field "$fleet_out" fleet_working)
  kill "$primary_pid" 2>/dev/null || true
  wait "$primary_pid" 2>/dev/null || true
  rm -f "$FLEET_MAIN/state/.lock"
  assert_equals 2 "$primary_busy" "a mid-turn primary session should count as working"
  assert_equals 1 "$primary_idle" "an idle primary session is not working"
  pass "the primary firstmate session counts as working only while its pane is busy"
else
  pass "primary session case skipped: no stand-in process survives a harness name here"
fi

# A long-lived log must not make a button press slow. A second mate's worker
# raised a blocker long ago and has appended thousands of lines since; its
# home's drain keeps the incremental open-decisions cursor, as every drain
# does. The fleet read answers from that cursor plus only the bytes appended
# after it, still finds the buried blocker, and leaves the cursor untouched.
fleet_worker "$FLEET_MATE" sw-long wG:p1 idle "blocked [at=1792000000] [key=usb]: the bench port is gone"
i=0
while [ "$i" -lt 3000 ]; do
  printf 'working [at=1792000001]: routine progress line %04d on a long-running task\n' "$i"
  i=$((i + 1))
done >> "$FLEET_MATE/state/sw-long.status"
FM_HOME="$FLEET_MATE" bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_incremental "$2" >/dev/null' \
  _ "$ROOT" "$FLEET_MATE/state/sw-long.status"
long_cursor="$FLEET_MATE/state/.sw-long.open-decisions-cursor"
[ -s "$long_cursor" ] || fail "the incremental fold did not leave a cursor to read from"
long_before=$(LC_ALL=C wc -c < "$FLEET_MATE/state/sw-long.status" | tr -d '[:space:]')
printf 'working [at=1792000002]: one more line after the drain\n' >> "$FLEET_MATE/state/sw-long.status"
long_after=$(LC_ALL=C wc -c < "$FLEET_MATE/state/sw-long.status" | tr -d '[:space:]')
cursor_sum=$(cksum < "$long_cursor")
long_probe="$FLEET/long.probe"
: > "$long_probe"
fleet_out=$(FM_OPEN_DECISIONS_READ_PROBE="$long_probe" fleet_read) || fail "the fleet read failed: $fleet_out"
assert_equals 2 "$(fleet_field "$fleet_out" fleet_stuck)" \
  "a blocker buried under thousands of later lines must still count as stuck"
long_folded=$(grep -F "$(printf '%s\t' "$FLEET_MATE/state/sw-long.status")" "$long_probe" | cut -f2 | sort -u)
assert_equals "$((long_after - long_before))" "$long_folded" \
  "the long log should be folded from the cursor on, never from its first byte"
assert_equals "$cursor_sum" "$(cksum < "$long_cursor")" "the fleet read must not rewrite the cursor"
pass "a long status log is read from its existing cursor, bounded by new appends, without a write"

# A live session the counts depend on cannot be read: herdr is missing from
# the caller's PATH (launchd's bare PATH, where the Beacon reader once took
# four seconds and answered fleet_working=0, a false green), or a herdr call
# fails. Both counts must read as unknown, never as 0, and the read must
# return well inside the deadline rather than waiting it out.
assert_not_contains "$(fleet_read)" fleet_unknown_reason \
  "a fully readable fleet must keep the plain count shape"
fleet_unknown() {  # <json> <reason-fragment> <label>
  printf '%s' "$1" | python3 -c '
import json, sys
got = json.load(sys.stdin)
ok = (got.get("fleet_working", 0) is None and got.get("fleet_stuck", 0) is None
      and sys.argv[1] in (got.get("fleet_unknown_reason") or ""))
sys.exit(0 if ok else 1)' "$2" || fail "$3: $1"
}
fleet_timed() {  # <path> -> json; seconds on fd 3
  local started out
  started=$(python3 -c 'import time; print(time.monotonic())')
  out=$(PATH="$1" FM_FAKE_FLEET_AGENTS="$FLEET_AGENTS" FM_FAKE_FLEET_SSH_LOG="$FLEET_SSH_LOG" \
    "$FLEET_PYTHON" "$ROOT/bin/fm_voice_records.py" status --home "$FLEET_MAIN" --scope counts) || return 1
  python3 -c 'import sys, time; print("%.2f" % (time.monotonic() - float(sys.argv[1])))' "$started" >&3
  printf '%s' "$out"
}
FLEET_PYTHON=$(command -v python3)
# PATH with every herdr removed: a directory that holds one is replaced by a
# mirror of everything else in it, so the rest of the toolchain still resolves.
FLEET_NOHERDR="$FLEET/noherdr"
mkdir -p "$FLEET_NOHERDR/fake"
ln -sf "$FLEET_BIN/no-mistakes" "$FLEET_NOHERDR/fake/no-mistakes"
ln -sf "$FLEET_BIN/ssh" "$FLEET_NOHERDR/fake/ssh"
noherdr_path="$FLEET_NOHERDR/fake"
mirror=0
old_ifs=$IFS
IFS=:
for dir in $PATH; do
  [ -n "$dir" ] && [ "$dir" != "$FLEET_BIN" ] || continue
  if [ -x "$dir/herdr" ]; then
    mirror=$((mirror + 1))
    mkdir -p "$FLEET_NOHERDR/$mirror"
    for entry in "$dir"/*; do
      [ "${entry##*/}" = herdr ] || ln -sf "$entry" "$FLEET_NOHERDR/$mirror/${entry##*/}"
    done
    dir="$FLEET_NOHERDR/$mirror"
  fi
  noherdr_path="$noherdr_path:$dir"
done
IFS=$old_ifs
PATH="$noherdr_path" command -v herdr >/dev/null 2>&1 && fail "the test PATH still resolves herdr"
fleet_out=$(fleet_timed "$noherdr_path" 3>"$FLEET/noherdr.secs") || fail "the fleet read failed without herdr: $fleet_out"
fleet_unknown "$fleet_out" "herdr is not on PATH" "herdr missing from PATH must read as unknown, not 0"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2.0 else 1)' "$(cat "$FLEET/noherdr.secs")" \
  || fail "the read without herdr must return at once, not wait out the deadline: $(cat "$FLEET/noherdr.secs")s"
pass "herdr missing from PATH reads both fleet counts as unknown, at once"

# Every herdr call errors, as a herdr that cannot reach its server does.
mkdir -p "$FLEET/failbin"
cat > "$FLEET/failbin/herdr" <<'SH'
#!/usr/bin/env bash
printf 'error: herdr cannot reach its server\n' >&2
exit 1
SH
chmod +x "$FLEET/failbin/herdr"
fleet_out=$(fleet_timed "$FLEET/failbin:$FLEET_BIN:$PATH" 3>"$FLEET/fail.secs") || fail "the fleet read failed: $fleet_out"
fleet_unknown "$fleet_out" "a herdr read failed" "a failing herdr call must read as unknown, not 0"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 2.0 else 1)' "$(cat "$FLEET/fail.secs")" \
  || fail "a failing herdr must be seen before the server wait: $(cat "$FLEET/fail.secs")s"
pass "a failing herdr call reads both fleet counts as unknown"

# One agent's read misses the deadline, as under load at background priority:
# the busy second mate worker's herdr calls hang. Dropping it from both counts
# lowered fleet_working and could read a false green; the counts must read as
# unknown instead, while the read still returns soon after the deadline.
set_pane wS:p1 working
fleet_out=$(fleet_read) || fail "the fleet read failed: $fleet_out"
assert_equals 2 "$(fleet_field "$fleet_out" fleet_working)" "the fixture should start with two working"
started=$(python3 -c 'import time; print(time.monotonic())')
fleet_out=$(FLEET_SLOW=wA:p1 fleet_read) || fail "the fleet read failed with a slow agent: $fleet_out"
slow_secs=$(python3 -c 'import sys, time; print("%.2f" % (time.monotonic() - float(sys.argv[1])))' "$started")
fleet_unknown "$fleet_out" "missed the" "an agent past the deadline must read as unknown, not a lower count"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 6.0 else 1)' "$slow_secs" \
  || fail "a slow agent must not hold the read past the deadline: ${slow_secs}s"
pass "an agent whose read misses the deadline reads both fleet counts as unknown"

# One agent's read fails outright, with no answer: the reader crashed. Its
# agent is unseen just as a late one is, so the counts must not drop it.
FAILROOT="$FLEET/failroot"
mkdir -p "$FAILROOT"
cat > "$FAILROOT/fm-local-voice-fleet-states.sh" <<SH
#!/usr/bin/env bash
case "\$1 \${3:-}" in
  "agent sw-work") exit 1 ;;
esac
exec "$ROOT/bin/fm-local-voice-fleet-states.sh" "\$@"
SH
chmod +x "$FAILROOT/fm-local-voice-fleet-states.sh"
fleet_out=$(PATH="$FLEET_BIN:$PATH" FM_FAKE_FLEET_AGENTS="$FLEET_AGENTS" FM_FAKE_FLEET_SSH_LOG="$FLEET_SSH_LOG" \
  python3 -c '
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "bin"))
import fm_local_voice_records as m
print(json.dumps(m.fleet_activity(sys.argv[2], lambda h: os.path.join(h, "state"), root=sys.argv[3])))' \
  "$ROOT" "$FLEET_MAIN" "$FAILROOT") || fail "the fleet read failed with a failing reader: $fleet_out"
fleet_unknown "$fleet_out" "read failed" "an agent whose read fails must read as unknown, not a lower count"
pass "an agent whose read fails reads both fleet counts as unknown"

printf 'all local voice records cases passed\n'
