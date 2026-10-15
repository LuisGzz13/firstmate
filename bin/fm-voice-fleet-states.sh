#!/usr/bin/env bash
# fm-voice-fleet-states.sh - one agent's current state, for the fleet counts in
# bin/fm_voice_records.py (fleet_working, fleet_stuck).
#
# This script decides nothing itself. Each answer comes from the owner of that
# question, so the counts cannot drift from what supervision reads:
#   - the registered second mate homes from bin/fm-secondmate-registry-lib.sh,
#   - a task's current state from bin/fm-crew-state.sh, never from the last
#     line of its status log; FM_OPEN_DECISIONS_CURSOR_PEEK=1 lets its fold of
#     open decisions answer from the cursor that home's own drain keeps
#     (bin/fm-classify-lib.sh), so a log grown over weeks is not refolded from
#     its first byte on every button press, and nothing is written,
#   - a second mate session's busy verdict from bin/fm-busy-lib.sh
#     (fm_busy_classify_meta), the semantic busy-state contract,
#   - the primary session's process from bin/fm-session-lock-lib.sh
#     (fm_session_lock_inspect), its pane from bin/fm-supervisor-target-lib.sh,
#     and that pane's busy verdict from bin/fm-backend.sh
#     (fm_backend_busy_state).
#
# Usage:
#   fm-voice-fleet-states.sh homes <home>
#       Print one "<second-mate-home>" line per registered LOCAL second mate in
#       <home>'s data/secondmates.md (FM_DATA_OVERRIDE honoured) whose state
#       directory is readable.
#       A remote route, a record the registry parser rejects, and an unreadable
#       home are skipped silently: the counts are a best-effort read, and one
#       missing home must not fail the read of every other.
#   fm-voice-fleet-states.sh agent <home> <id>
#       Print one line "<state> <session>" for the task recorded at
#       <home>/state/<id>.meta (FM_STATE_OVERRIDE honoured, as for primary).
#       <state> is the state word bin/fm-crew-state.sh prints (working,
#       parked, done, blocked, paused, failed, unknown).
#       <session> is the first word of fm_busy_classify_meta (busy, idle,
#       unknown, dead) for a kind=secondmate record, which is how a second
#       mate that is mid-turn shows as working while its own routed status log
#       still reads parked or resolved; it is "-" for every other kind, whose
#       session is already folded into bin/fm-crew-state.sh's verdict.
#       A record carrying remote_host= prints "unknown -" without contacting
#       that host.
#   fm-voice-fleet-states.sh primary <home>
#       Print one line "- <session>", in the agent shape with no task state,
#       where <session> is the busy verdict (busy, idle, unknown) of the
#       firstmate session holding <home>'s session lock. The pane is discovered exactly as the
#       away-mode daemon discovers its own, from the TMUX_PANE, HERDR_ENV,
#       HERDR_PANE_ID and HERDR_SESSION variables in that session's process
#       environment, which only a process of the same user can read. A free,
#       stale or unreadable lock, an unreadable environment, or a pane the
#       backend cannot classify all print unknown; only busy means mid-turn.
#
# Read-only: no lock, no write, no wake. Forge reads are disabled for the
# current-state read (FM_CREW_STATE_NO_FORGE=1), so nothing here leaves this
# host; the only endpoints asked are this host's own backends.
# Exit 0 on every completed read, 2 on a usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-voice-fleet-states.sh homes <home> | agent <home> <id> | primary <home>" >&2
  exit 2
}

homes() {  # <home>
  local reg="${FM_DATA_OVERRIDE:-$1/data}/secondmates.md" line
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  [ -f "$reg" ] && [ -r "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue
    case "$SECONDMATE_REGISTRY_HOME" in /*) ;; *) continue ;; esac
    [ -d "$SECONDMATE_REGISTRY_HOME/state" ] && [ -r "$SECONDMATE_REGISTRY_HOME/state" ] \
      && [ -x "$SECONDMATE_REGISTRY_HOME/state" ] || continue
    printf '%s\n' "$SECONDMATE_REGISTRY_HOME"
  done < "$reg"
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

agent() {  # <home> <id>
  local home=$1 id=$2 state meta line word session=-
  state=${FM_STATE_OVERRIDE:-$home/state}
  meta="$state/$id.meta"
  if [ ! -f "$meta" ] || [ -n "$(meta_value "$meta" remote_host)" ]; then
    printf 'unknown -\n'
    return 0
  fi
  line=$(FM_HOME=$home FM_STATE_OVERRIDE=$state FM_CREW_STATE_NO_FORGE=1 FM_OPEN_DECISIONS_CURSOR_PEEK=1 \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null </dev/null || true)
  word=${line#state: }
  word=${word%% *}
  case "$line" in "state: "*) ;; *) word=unknown ;; esac
  [ -n "$word" ] || word=unknown
  if [ "$(meta_value "$meta" kind)" = secondmate ]; then
    # shellcheck source=bin/fm-backend.sh
    . "$SCRIPT_DIR/fm-backend.sh"
    # shellcheck source=bin/fm-busy-lib.sh
    . "$SCRIPT_DIR/fm-busy-lib.sh"
    session=$(fm_busy_classify_meta "$meta" "$id" "$state" 2>/dev/null </dev/null || true)
    session=${session%% *}
    [ -n "$session" ] || session=unknown
  fi
  printf '%s %s\n' "$word" "$session"
}

# One variable from <pid>'s environment, or nothing. Linux exposes the
# environment as a NUL-separated file; macOS appends it to `ps eww`'s command
# column, where the last match wins because the environment follows the argv.
process_env_value() {  # <pid> <name>
  if [ -r "/proc/$1/environ" ]; then
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | tail -1
  else
    ps eww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n "s/^$2=//p" | tail -1
  fi
}

primary() {  # <home>
  local state=${FM_STATE_OVERRIDE:-$1/state} pid name value backend target verdict
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_inspect "$state"
  pid=$FM_LOCK_INSPECT_PID
  if [ "$FM_LOCK_INSPECT_STATE" != held ] || [ "$FM_LOCK_INSPECT_LIVE_HARNESS" != true ]; then
    printf -- '- unknown\n'
    return 0
  fi
  unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION
  for name in TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION; do
    value=$(process_env_value "$pid" "$name")
    [ -z "$value" ] || export "$name=$value"
  done
  # shellcheck source=bin/fm-supervisor-target-lib.sh
  . "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
  if ! backend=$(discover_supervisor_backend) || ! target=$(discover_supervisor_target); then
    printf -- '- unknown\n'
    return 0
  fi
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  verdict=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null </dev/null || true)
  case "$verdict" in busy|idle) ;; *) verdict=unknown ;; esac
  printf -- '- %s\n' "$verdict"
}

case "${1:-}" in
  homes) [ "$#" = 2 ] || usage; homes "$2" ;;
  agent) [ "$#" = 3 ] || usage; agent "$2" "$3" ;;
  primary) [ "$#" = 2 ] || usage; primary "$2" ;;
  *) usage ;;
esac
exit 0
