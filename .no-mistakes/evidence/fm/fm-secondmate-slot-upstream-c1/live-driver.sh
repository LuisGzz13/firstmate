#!/usr/bin/env bash
# Live driver for the persistent-secondmate-slot change (target 1e71c99).
# Real pieces: Treehouse v2 (pool rooted inside the lab via a repo-local
# treehouse.toml, so ~/.treehouse is never used), a named fm-lab-* Herdr
# session driven only through bin/fm-herdr-lab.sh, and the change's own
# bin/fm-home-seed.sh / bin/fm-teardown.sh run from a disposable marked lab
# home that is a primary checkout of the target tree. No agent is launched.
set -u

SRC=/Users/luisgzz/.no-mistakes/worktrees/2168187621a3/01M3TD5RAXF1M89YXYS6R1JSE3
PRE_FIX_REV=727f692   # the commit before the review fix (marker-only evidence)
ORIG_PATH=$PATH
HELPER="$SRC/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr)
REAL_TREEHOUSE=$(command -v treehouse)
export TREEHOUSE_NO_UPDATE_CHECK=1

FAILS=0
step() { printf '\n=== %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

L=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
L=$(cd "$L" && pwd -P)
H="$L/home"
FAKEBIN="$L/bin"
LOG="$L/runtime.log"
mkdir -p "$FAKEBIN"
: > "$LOG"
ls -1A "$HOME/.treehouse" 2>/dev/null | LC_ALL=C sort > "$L/treehouse-before"

SESSION=$("$HELPER" name fm-sm-slot)
export HERDR_LAB_HELPER=$HELPER HERDR_LAB_SESSION=$SESSION HERDR_ORIGINAL_PATH=$ORIG_PATH
export REAL_HERDR REAL_TREEHOUSE RUNTIME_LOG=$LOG

cleanup() {
  local status=$?
  step "teardown"
  env PATH="$ORIG_PATH" "$HELPER" teardown "$SESSION" && echo "herdr lab session $SESSION torn down" || status=1
  if ls -1A "$HOME/.treehouse" 2>/dev/null | LC_ALL=C sort | diff "$L/treehouse-before" - >/dev/null; then
    echo "~/.treehouse listing unchanged by this run"
  else
    echo "WARNING: ~/.treehouse listing changed"; status=1
  fi
  rm -rf "$L"
  [ ! -e "$L" ] && echo "lab root $L removed"
  echo "FAILS=$FAILS"
  [ "$FAILS" -eq 0 ] || status=1
  exit "$status"
}
trap cleanup EXIT

# --- Lab home: a marked disposable FM_HOME that is a primary checkout -------
step "setup: marked lab home with the target tree, Treehouse pool inside the lab"
"$SRC/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 1
(cd "$SRC" && git archive HEAD) | tar -x -C "$H" || exit 1
printf 'max_trees = 4\nroot = "%s/th"\n' "$L" > "$H/treehouse.toml"
git -C "$H" init -q -b main
printf '.fm-lab-home\n' >> "$H/.git/info/exclude"
git -C "$H" add -A
git -C "$H" -c user.name=lab -c user.email=lab@example.invalid commit -qm "lab: firstmate tree $(git -C "$SRC" rev-parse --short HEAD)"
echo "lab home $H at tree of $(git -C "$SRC" rev-parse --short HEAD) (treehouse root $L/th)"

# Logging pass-through shims: every call reaches the real binary.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf 'herdr' >> "$RUNTIME_LOG"; printf ' <%s>' "$@" >> "$RUNTIME_LOG"; printf '\n' >> "$RUNTIME_LOG"
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do case "$arg" in --session|--session=*) exit 9 ;; esac; done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "$RUNTIME_LOG"; printf ' <%s>' "$@" >> "$RUNTIME_LOG"; printf '\n' >> "$RUNTIME_LOG"
exec "$REAL_TREEHOUSE" "$@"
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"

"$HELPER" provision "$SESSION" || { echo "could not provision herdr lab"; exit 1; }
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"; }
CREATE=$(lab workspace create --cwd "$H" --label sm-slot --no-focus) || exit 1
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') || exit 1
CONTROL_PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') || exit 1
echo "herdr lab session $SESSION workspace $WS"

declare -A TAB PANE
new_pane() {  # <id>
  local out
  out=$(lab tab create --workspace "$WS" --cwd "$H" --label "fm-$1" --no-focus) || return 1
  TAB[$1]=$(printf '%s' "$out" | jq -er '.result.tab.tab_id')
  PANE[$1]=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id')
}
pane_present() { lab pane get "$1" >/dev/null 2>&1; }

fm() {  # <script> <args...> : run a lab-home script as an operator would
  local script=$1; shift
  ( cd "$L" && env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      PATH="$FAKEBIN:$ORIG_PATH" FM_HOME="$H" "$H/bin/$script" "$@" )
}
run() {  # <tag> <script> <args...> : capture out/err/rc and echo them
  local tag=$1; shift
  : > "$LOG"
  fm "$@" > "$L/$tag.out" 2> "$L/$tag.err"
  RC=$?
  printf -- '$ %s %s   (rc=%s)\n' "$1" "${*:2}" "$RC"
  sed 's/^/  stdout| /' "$L/$tag.out"
  sed 's/^/  stderr| /' "$L/$tag.err"
  if grep -q '^treehouse' "$LOG"; then grep '^treehouse' "$LOG" | sed 's/^/  pool-op| /'; else echo "  pool-op| (no treehouse call)"; fi
  return 0
}
lib() {  # <shell snippet> : evaluate with the lab's own wake library sourced
  ( cd "$L" && FM_HOME="$H" bash -c '. "$1/bin/fm-wake-lib.sh"; shift; eval "$1"' _ "$H" "$1" )
}
pool_state() { cat "$POOL/treehouse-state.json"; }
slot_lease() { lib "fm_treehouse_slot_lease_holder '$SLOT'; echo \"exit=\$?\""; }
show_claim() { if [ -f "$POOL/1/.fm-slot-owner" ]; then printf '  claim: %s\n' "$(tr '\n' ' ' < "$POOL/1/.fm-slot-owner")"; else echo '  claim: <absent>'; fi; }
fingerprint() {
  ( cd "$POOL" && find . -path ./treehouse-state.lock -prune -o \( -type f -o -type l \) -print \
      | LC_ALL=C sort | while IFS= read -r p; do
          if [ -L "$p" ]; then printf 'link:%s %s\n' "$(readlink "$p")" "$p"; else printf '%s %s\n' "$(cksum < "$p")" "$p"; fi
        done
    git -C "$SLOT" rev-parse HEAD )
}

write_scout() {  # <id>
  local id=$1
  mkdir -p "$H/data/$id"
  printf 'Complete lab report with no unresolved choices.\n' > "$H/data/$id/report.md"
  printf '%s\n' "window=$SESSION:${PANE[$id]}" "endpoint_task_id=$id" "worktree=$SLOT" \
    "project=$H" "kind=scout" "backend=herdr" "herdr_session=$SESSION" \
    "herdr_workspace_id=$WS" "herdr_tab_id=${TAB[$id]}" "herdr_pane_id=${PANE[$id]}" \
    "decisions_reviewed=1" "decision_keys=" > "$H/state/$id.meta"
}

# Take a pool slot the way a crew pane does: interactive `treehouse get`
# inside the task's own Herdr pane, then claim it as fm-spawn does.
pane_takes_slot() {  # <id>
  local id=$1 i
  lab pane run "${PANE[$id]}" "cd '$H' && treehouse get" >/dev/null || return 1
  for i in $(seq 1 100); do
    POOL=$(ls -d "$L"/th/.treehouse/home-* 2>/dev/null | head -1)
    [ -n "$POOL" ] && grep -q '"owner_pid"' "$POOL/treehouse-state.json" 2>/dev/null && break
    sleep 0.2
  done
  SLOT=$(cd "$POOL/1/home" 2>/dev/null && pwd -P) || return 1
  echo "  $id in-use pool entry: $(jq -c '.worktrees[0] | {name, owner_pid: (.owner_pid != null), leased}' "$POOL/treehouse-state.json")"
  lab pane read "${PANE[$id]}" --source recent --lines 6 2>/dev/null | sed "s/^/  $id pane| /"
  lib "fm_treehouse_slot_owner_claim '$SLOT' '$id' '$H'"
}
pane_leaves_slot() {  # <id> : the task's shell leaves the Treehouse subshell
  local id=$1 i
  lab pane run "${PANE[$id]}" "exit" >/dev/null || return 1
  for i in $(seq 1 100); do
    grep -q '"owner_pid"' "$POOL/treehouse-state.json" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

# === Scenario 1-3: slot used by two scouts, then a fresh leased seed =========
step "phase 1: two completed scouts used pool slot 1 in turn (real treehouse get in their own panes)"
new_pane old-scout-a; new_pane old-scout-b
pane_takes_slot old-scout-a || { echo "slot acquisition failed"; exit 1; }
FIRST_SLOT=$SLOT
write_scout old-scout-a
pane_leaves_slot old-scout-a || bad "old-scout-a's subshell did not leave the slot"
pane_takes_slot old-scout-b || { echo "slot reacquisition failed"; exit 1; }
write_scout old-scout-b
pane_leaves_slot old-scout-b || bad "old-scout-b's subshell did not leave the slot"
check "both scouts were handed the same pool slot $SLOT" [ "$FIRST_SLOT" = "$SLOT" ]
show_claim
echo "  pool state: $(pool_state | tr -d ' \n')"

step "scenario: seed rollback returns its leased slot and drops only its own claim"
( cd "$L" && PATH="$FAKEBIN:$ORIG_PATH" FM_HOME="$H" FM_SECONDMATE_CHARTER='Lab persistent charter' \
    FM_SECONDMATE_SCOPE='lab persistent scope' "$H/bin/fm-brief.sh" mate --secondmate --no-projects ) >/dev/null \
  || bad "could not scaffold the lab charter"
cp "$H/data/mate/brief.md" "$L/brief.good"
printf '\n{TASK}\n' >> "$H/data/mate/brief.md"
run seed-rollback fm-home-seed.sh mate - --no-projects
check "seed with a placeholder charter fails" [ "$RC" -ne 0 ]
check "rollback really returned the leased slot (pool records no lease)" \
  [ "$(slot_lease | tail -1)" = "exit=1" ]
check "rollback dropped its own claim" [ ! -e "$POOL/1/.fm-slot-owner" ]
check "rollback kept the replaced claim of old-scout-b as recovery evidence" \
  [ "$(cat "$POOL/1/.fm-slot-owner.prior")" = "$(printf 'task=old-scout-b\nhome=%s' "$H")" ]
show_claim; echo "  prior: $(tr '\n' ' ' < "$POOL/1/.fm-slot-owner.prior")"

step "scenario: a fresh leased seed publishes the secondmate's slot-owner claim"
cp "$L/brief.good" "$H/data/mate/brief.md"
run seed fm-home-seed.sh mate - --no-projects
check "seed succeeded" [ "$RC" -eq 0 ]
check "seed leased the same pool slot the scouts used" grep -qx "home=$SLOT" "$L/seed.out"
check "pool state records the durable lease held by mate" [ "$(slot_lease | head -1)" = mate ]
check "slot-owner claim names mate and the registering home" \
  [ "$(cat "$POOL/1/.fm-slot-owner")" = "$(printf 'task=mate\nhome=%s' "$H")" ]
show_claim
echo "  pool entry: $(pool_state | jq -c '.worktrees[0] | {name,leased,lease_holder}')"
echo "  slot markers: .fm-secondmate-home=$(cat "$SLOT/.fm-secondmate-home"), parent=$(grep parent_home "$SLOT/.fm-secondmate-parent")"

step "scenario: stale completed scouts on the freshly seeded home finish records-only"
BEFORE=$(fingerprint)
run td-a fm-teardown.sh old-scout-a
check "old-scout-a teardown finished" [ "$RC" -eq 0 ]
check "old-scout-a record removed" [ ! -e "$H/state/old-scout-a.meta" ]
check "old-scout-a's own dead pane was closed" bash -c "! env PATH='$ORIG_PATH' '$HELPER' run '$SESSION' pane get '${PANE[old-scout-a]}' >/dev/null 2>&1"
check "no pool operation ran" bash -c "! grep -q '^treehouse' '$LOG'"
check "seeded home, lease, and claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]
run td-b fm-teardown.sh old-scout-b
check "old-scout-b teardown finished" [ "$RC" -eq 0 ]
check "no pool operation ran" bash -c "! grep -q '^treehouse' '$LOG'"
check "seeded home, lease, and claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]
check "lease still held by mate" [ "$(slot_lease | head -1)" = mate ]

# === Scenario 4: a home seeded before seeding published its claim ===========
step "phase 4: legacy shape - the leased home's claim still names the scout that used it before"
new_pane old-scout-c
write_scout old-scout-c
lib "fm_treehouse_slot_owner_claim '$SLOT' old-scout-c '$H'"
show_claim
BEFORE=$(fingerprint)
for mode in plain --force; do
  if [ "$mode" = --force ]; then run td-c-force fm-teardown.sh old-scout-c --force; tag=td-c-force
  else run td-c fm-teardown.sh old-scout-c; tag=td-c; fi
  check "ordinary teardown ($mode) refuses the leased home whose claim is its own" [ "$RC" -ne 0 ]
  check "refusal ($mode) names claim-slot mate" grep -q 'claim-slot mate' "$L/$tag.err"
  check "refusal ($mode) ran no pool operation" bash -c "! grep -q '^treehouse' '$LOG'"
  check "refusal ($mode) left home/lease/claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]
  check "refusal ($mode) kept the record and the pane" bash -c "[ -e '$H/state/old-scout-c.meta' ] && env PATH='$ORIG_PATH' '$HELPER' run '$SESSION' pane get '${PANE[old-scout-c]}' >/dev/null 2>&1"
done
mv "$POOL/1/.fm-slot-owner" "$L/claim.aside"
run td-c-absent fm-teardown.sh old-scout-c --force
check "ordinary forced teardown refuses the leased home with no claim at all" [ "$RC" -ne 0 ]
check "absent-claim refusal ran no pool operation" bash -c "! grep -q '^treehouse' '$LOG'"
check "absent-claim refusal left the home in place" [ -f "$SLOT/.fm-secondmate-home" ]
mv "$L/claim.aside" "$POOL/1/.fm-slot-owner"

step "scenario: claim-slot refuses when ownership proof fails (identity marker mismatch)"
cp "$SLOT/.fm-secondmate-home" "$L/marker.good"
printf 'impostor\n' > "$SLOT/.fm-secondmate-home"
CLAIM_BEFORE=$(cksum < "$POOL/1/.fm-slot-owner")
run claim-bad fm-home-seed.sh claim-slot mate
check "claim-slot refused" [ "$RC" -ne 0 ]
check "claim unchanged after refusal" [ "$(cksum < "$POOL/1/.fm-slot-owner")" = "$CLAIM_BEFORE" ]
cp "$L/marker.good" "$SLOT/.fm-secondmate-home"
run claim-ghost fm-home-seed.sh claim-slot ghost
check "claim-slot for an unregistered id refused" [ "$RC" -ne 0 ]
check "claim unchanged after refusal" [ "$(cksum < "$POOL/1/.fm-slot-owner")" = "$CLAIM_BEFORE" ]

step "scenario: claim-slot reconciles the legacy claim; a retry is unchanged"
run claim fm-home-seed.sh claim-slot mate
check "claim-slot succeeded" [ "$RC" -eq 0 ]
check "claim-slot reported replaced" grep -q 'slot-owner claim replaced' "$L/claim.out"
check "claim now names mate" [ "$(cat "$POOL/1/.fm-slot-owner")" = "$(printf 'task=mate\nhome=%s' "$H")" ]
check "prior claim kept at .prior" [ "$(cat "$POOL/1/.fm-slot-owner.prior")" = "$(printf 'task=old-scout-c\nhome=%s' "$H")" ]
check "claim-slot never touched the pool" bash -c "! grep -q '^treehouse' '$LOG'"
run claim-again fm-home-seed.sh claim-slot mate
check "repeated claim-slot reported unchanged" grep -q 'slot-owner claim unchanged' "$L/claim-again.out"

step "scenario: after reconciliation the stale dead scout finishes without touching the home"
BEFORE=$(fingerprint)
run td-c-after fm-teardown.sh old-scout-c
check "old-scout-c teardown finished" [ "$RC" -eq 0 ]
check "old-scout-c record removed" [ ! -e "$H/state/old-scout-c.meta" ]
check "no pool operation ran" bash -c "! grep -q '^treehouse' '$LOG'"
check "seeded home, lease, and claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]

step "scenario (adversarial): a contradictory secondmate record naming the home still refuses"
new_pane old-scout-d
write_scout old-scout-d
printf '%s\n' "window=$SESSION:${PANE[old-scout-d]}" "endpoint_task_id=other-mate" "kind=secondmate" \
  "home=$SLOT" "worktree=$SLOT" > "$H/state/other-mate.meta"
BEFORE=$(fingerprint)
run td-d fm-teardown.sh old-scout-d
check "teardown refused beside a contradictory secondmate record" [ "$RC" -ne 0 ]
check "refusal names other-mate" grep -q 'other-mate' "$L/td-d.err"
check "refusal left home/lease/claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]
rm -f "$H/state/other-mate.meta"
run td-d-after fm-teardown.sh old-scout-d
check "with the contradiction gone, old-scout-d finishes" [ "$RC" -eq 0 ]
check "and still touches nothing in the home" [ "$(fingerprint)" = "$BEFORE" ]


# === Scenario: forced parent teardown never returns a child slot that is a home
step "phase 5: forced retirement of another secondmate whose stale child record names mate's leased home"
( cd "$L" && PATH="$FAKEBIN:$ORIG_PATH" FM_HOME="$H" FM_SECONDMATE_CHARTER='Lab parent charter' \
    FM_SECONDMATE_SCOPE='lab parent scope' "$H/bin/fm-brief.sh" domain --secondmate --no-projects ) >/dev/null \
  || bad "could not scaffold the domain charter"
run seed-domain fm-home-seed.sh domain "$L/domain" --no-projects
check "plain-clone secondmate domain seeded" [ "$RC" -eq 0 ]
DOMAIN=$(cd "$L/domain" && pwd -P)
new_pane domain; new_pane stale-child
printf '%s\n' "window=$SESSION:${PANE[domain]}" "endpoint_task_id=domain" "worktree=$DOMAIN" "project=$DOMAIN" \
  "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "home=$DOMAIN" "projects=" \
  "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WS" "herdr_tab_id=${TAB[domain]}" \
  "herdr_pane_id=${PANE[domain]}" > "$H/state/domain.meta"
printf '%s\n' "window=$SESSION:${PANE[stale-child]}" "endpoint_task_id=stale-child" "worktree=$SLOT" "project=$H" \
  "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WS" "herdr_tab_id=${TAB[stale-child]}" \
  "herdr_pane_id=${PANE[stale-child]}" > "$DOMAIN/state/stale-child.meta"
# Legacy shape: the leased home's claim still names the child that used the slot.
lib "fm_treehouse_slot_owner_claim '$SLOT' stale-child '$DOMAIN'"
show_claim
BEFORE=$(fingerprint)
run td-domain-force fm-teardown.sh domain --force
check "forced parent teardown refused" [ "$RC" -ne 0 ]
check "refusal names the persistent secondmate home" grep -q 'persistent secondmate home' "$L/td-domain-force.err"
check "refusal ran no pool operation" bash -c "! grep -q '^treehouse' '$LOG'"
check "refusal closed no pane" bash -c "! grep -q 'pane> <close' '$LOG'"
check "mate's home, lease, and claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]
check "domain record, home, and child record kept" bash -c "[ -e '$H/state/domain.meta' ] && [ -d '$DOMAIN' ] && [ -e '$DOMAIN/state/stale-child.meta' ]"
check "both panes still present" bash -c "env PATH='$ORIG_PATH' '$HELPER' run '$SESSION' pane get '${PANE[domain]}' >/dev/null 2>&1 && env PATH='$ORIG_PATH' '$HELPER' run '$SESSION' pane get '${PANE[stale-child]}' >/dev/null 2>&1"
run claim-for-domain fm-home-seed.sh claim-slot mate
check "claim-slot reconciles mate's claim" grep -q 'slot-owner claim replaced' "$L/claim-for-domain.out"
BEFORE=$(fingerprint)
run td-domain-force2 fm-teardown.sh domain --force
check "with mate's claim reconciled, forced retirement of domain finishes" [ "$RC" -eq 0 ]
check "domain's plain-clone home removed and its route dropped" bash -c "[ ! -e '$DOMAIN' ] && [ ! -e '$H/state/domain.meta' ] && ! grep -q -- '- domain ' '$H/data/secondmates.md'"
check "mate's leased home was never returned" bash -c "! grep -q '^treehouse <return>.*$SLOT' '$LOG'"
check "mate's home, lease, and claim byte-identical" [ "$(fingerprint)" = "$BEFORE" ]
check "lease still held by mate" [ "$(slot_lease | head -1)" = mate ]

# === Scenario 5: retire the secondmate, then an ordinary crewmate reuses it =
step "phase 6: retire secondmate mate with the real fm-teardown.sh (real treehouse return)"
new_pane mate
printf '%s\n' "window=$SESSION:${PANE[mate]}" "endpoint_task_id=mate" "worktree=$SLOT" "project=$SLOT" \
  "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "home=$SLOT" "projects=" \
  "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WS" "herdr_tab_id=${TAB[mate]}" \
  "herdr_pane_id=${PANE[mate]}" > "$H/state/mate.meta"
run retire fm-teardown.sh mate
check "secondmate retirement finished" [ "$RC" -eq 0 ]
check "retirement returned the home through real treehouse return" grep -q "^treehouse <return> <--force> <$SLOT>" "$LOG"
check "pool now records slot 1 unleased" [ "$(slot_lease | tail -1)" = "exit=1" ]
check "retired markers stay in the returned slot (gitignored)" \
  bash -c "[ -e '$SLOT/.fm-secondmate-home' ] && [ -e '$SLOT/.fm-secondmate-parent' ]"
echo "  pool entry: $(pool_state | jq -c '.worktrees[0]')"
echo "  leftover markers: $(ls -A "$SLOT" | grep -E '^\.fm-secondmate' | tr '\n' ' ')"
show_claim

step "phase 7: an ordinary crewmate takes the returned slot with real treehouse get"
new_pane next-crew
pane_takes_slot next-crew || bad "next-crew could not take a slot"
check "next-crew was handed the retired secondmate's slot" [ "$SLOT" = "$FIRST_SLOT" ]
write_scout next-crew
pane_leaves_slot next-crew || bad "next-crew's subshell did not leave the slot"
show_claim

step "regression check: the pre-review-fix library ($PRE_FIX_REV) strands this crewmate"
cp "$H/bin/fm-wake-lib.sh" "$L/wake-lib.target"
git -C "$SRC" show "$PRE_FIX_REV:bin/fm-wake-lib.sh" > "$H/bin/fm-wake-lib.sh"
BEFORE=$(fingerprint)
run td-next-prefix fm-teardown.sh next-crew
check "pre-fix teardown refuses (the reported failure reproduces)" [ "$RC" -ne 0 ]
check "pre-fix refusal is the unprovable-ownership refusal" grep -q 'ownership cannot be proved' "$L/td-next-prefix.err"
cp "$L/wake-lib.target" "$H/bin/fm-wake-lib.sh"
check "lab code restored to the target tree" git -C "$H" diff --quiet -- bin/fm-wake-lib.sh

step "scenario: at the target commit the crewmate in the retired slot tears down normally"
run td-next fm-teardown.sh next-crew
check "next-crew teardown finished" [ "$RC" -eq 0 ]
check "next-crew record removed" [ ! -e "$H/state/next-crew.meta" ]
check "the slot was returned through real treehouse return" grep -q "^treehouse <return> <--force> <$SLOT>" "$LOG"
check "next-crew's own claim was released" [ ! -e "$POOL/1/.fm-slot-owner" ]
check "pool records slot 1 unleased and idle" [ "$(pool_state | jq -c '.worktrees[0] | (.leased // false) or has("owner_pid")')" = false ]
check "control pane untouched" pane_present "$CONTROL_PANE"
echo "  pool entry: $(pool_state | jq -c '.worktrees[0]')"
