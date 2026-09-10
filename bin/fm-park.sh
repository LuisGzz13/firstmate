#!/usr/bin/env bash
# fm-park.sh - is it safe to consolidate this home right now?
#
# Usage:
#   fm-park.sh [--repo <path>]...
#
# Prints one of two verdicts and nothing else:
#   SAFE     nothing blocks consolidating this home right now (exit 0)
#   BLOCKED  one line per blocker, each naming the action that clears it (exit 1)
# A usage error exits 2. --repo adds a repository outside this home to the
# scan, repeatable, for a checkout the home does not already know about.
#
# WHY THIS EXISTS. Consolidating a home means everything durable on this
# machine has to be reachable from somewhere else afterwards. The eight-point
# gate that question was first answered by was checked by hand exactly once,
# and between that check and the previous one three of its conditions had
# cleared on their own while three entirely new ones appeared - including a
# commit that existed in exactly one place on Earth for four days. A gate that
# is only ever checked by hand goes stale between checks, and what it misses is
# what gets lost. This runs the same gate in seconds, on either machine.
#
# READ-ONLY, AND THAT IS THE POINT. This pushes nothing, commits nothing,
# writes no record, and makes no network call. A preflight that changes state
# cannot be run freely, and being freely runnable is what keeps it honest. The
# no-network rule has one consequence worth stating: branches are judged
# against the remote-tracking refs this machine last fetched, so the verdict is
# about what this machine already knows.
#
# WHAT IT CHECKS, and what the carried scope means. The carried scope is the
# home's data/ and config/ directories - the deny-by-default allowlist a
# consolidated home is rebuilt from. Everything else on this machine is either
# reproducible or gone.
#
#   1. No validation run owns a branch.
#   2. No committed-but-unpushed work in any repository this home can see.
#   3. No uncommitted changes in any local copy.
#   4. No worker mid-work. A declared wait is fine; an idle worker is fine.
#   5. Nothing durable stranded outside the carried scope.
#   6. Every pending captain call is recorded durably.
#
# TWO TRAPS THIS DELIBERATELY AVOIDS, both proved on real repositories. A check
# that falls for either is worse than no check at all.
#
#   A remote is not always named `origin`. One repository here names its only
#   remote `dotfiles`, and a scan of refs/remotes/origin/ reported 17 unpushed
#   commits that were fully pushed. Every remote is resolved by name.
#
#   A remote is not always somewhere else. no-mistakes registers a remote
#   pointing at a bare mirror under ~/.no-mistakes/repos/ on this same disk, so
#   a plain `--not --remotes` counts work as safe that lives nowhere but here.
#   On this machine that hid one real commit. Only a remote whose URL is not a
#   local filesystem path counts as somewhere else.
#
# The dangerous direction is the false negative - a branch on no remote at all
# is exactly the case that stranded that four-day commit - so a doubtful branch
# is reported rather than passed over. The one thing that clears an unpushed
# branch without a remote is a git bundle inside the carried scope naming that
# branch's exact current tip: the captain deliberately captured it, and a stale
# bundle names an older tip so it still reports.
#
# WHAT IT DELIBERATELY DOES NOT TREAT AS A BLOCKER, so the verdict stays worth
# reading:
#
#   A worker whose state cannot be established (bin/fm-crew-state.sh reporting
#   unknown, most often a torn-down endpoint) is not evidence of work in
#   progress. Anything such a worker could have written is already caught by
#   the uncommitted and unpushed checks, and a dead endpoint is the ordinary
#   case, so treating it as a blocker would fire constantly and say nothing.
#
#   A secondmate's own home is skipped. It consolidates through its own run of
#   this check, and reaching a remote one would need the network this refuses
#   to use.
#
#   Whether two records of one already-durable captain call agree is not a
#   consolidation question - both machines read the same backlog either way.
#   bin/fm-captain-hold.sh diverged owns that seam.
#
# Coverage inside the carried scope is byte identity: an artifact is carried
# when a file with the same bytes exists under data/ or config/. That is what
# copying it there produces, it can never clear something that is not actually
# there, and it needs no guess about whether one file's content was folded into
# another.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

EXTRA_REPOS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      EXTRA_REPOS+=("$2")
      shift 2
      ;;
    --repo=*)
      EXTRA_REPOS+=("${1#--repo=}")
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

BLOCKERS=()
blocker() { BLOCKERS+=("$1"); }

# --- the carried scope ------------------------------------------------------

# One sha256 per regular file under the given directories, batched so a large
# tree costs one process rather than one per file. Prints nothing for a
# directory that does not exist.
park_hash_tree() {  # <name-glob-or-empty> <dir>...
  local glob=$1 dir
  local -a dirs=() filter=()
  shift
  for dir in "$@"; do
    [ -d "$dir" ] && dirs+=("$dir")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  [ -n "$glob" ] && filter=(-name "$glob")
  if command -v shasum >/dev/null 2>&1; then
    find "${dirs[@]}" -type f "${filter[@]+"${filter[@]}"}" -exec shasum -a 256 {} + 2>/dev/null | awk '{print $1}'
  else
    find "${dirs[@]}" -type f "${filter[@]+"${filter[@]}"}" -exec sha256sum {} + 2>/dev/null | awk '{print $1}'
  fi
}

# Every content hash inside the carried scope, computed once. Deliberately not
# wrapped in a command substitution anywhere: that would run the build in a
# subshell and silently recompute it on every lookup.
PARK_CARRIED_HASHES=
PARK_CARRIED_BUILT=0
park_build_carried() {
  [ "$PARK_CARRIED_BUILT" -eq 0 ] || return 0
  PARK_CARRIED_BUILT=1
  PARK_CARRIED_HASHES=$'\n'"$(park_hash_tree '' "$DATA" "$CONFIG")"$'\n'
}

# 0 when hash $1 is already inside the carried scope.
park_hash_is_carried() {  # <sha256>
  park_build_carried
  [ -n "$1" ] || return 1
  case "$PARK_CARRIED_HASHES" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# Every branch tip named by a git bundle inside the carried scope, computed
# once. A bundle is how a branch with no remote still travels.
PARK_BUNDLE_TIPS=
PARK_BUNDLE_BUILT=0
park_build_bundles() {
  local f tips=''
  [ "$PARK_BUNDLE_BUILT" -eq 0 ] || return 0
  PARK_BUNDLE_BUILT=1
  if [ -d "$DATA" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      tips="$tips$(git bundle list-heads "$f" 2>/dev/null | awk '{print $1}')"$'\n'
    done < <(find "$DATA" -type f -name '*.bundle' 2>/dev/null)
  fi
  PARK_BUNDLE_TIPS=$'\n'"$tips"
}

# 0 when commit $1 is a branch tip in a carried bundle.
park_bundle_has() {  # <sha>
  park_build_bundles
  [ -n "$1" ] || return 1
  case "$PARK_BUNDLE_TIPS" in
    *$'\n'"$1"$'\n'*) return 0 ;;
  esac
  return 1
}

# How many files under directory $1 - all of them, or only those matching name
# glob $2 - have bytes the carried scope does not already hold.
park_uncarried_count() {  # <dir> [name-glob]
  local dir=$1 glob=${2:-} h count=0
  [ -d "$dir" ] || { printf '0'; return 0; }
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    park_hash_is_carried "$h" && continue
    count=$((count + 1))
  done < <(park_hash_tree "$glob" "$dir")
  printf '%s' "$count"
}

# --- repositories and local copies ------------------------------------------

# 0 when remote URL $1 points somewhere other than this machine's filesystem.
# Anything absolute, relative, home-relative, or file:// is on this same disk,
# so work reachable only from it has not left the machine.
park_url_is_offsite() {  # <url>
  case "$1" in
    ''|/*|./*|../*|~*|file://*) return 1 ;;
    *://*) return 0 ;;
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}

# rev-list arguments naming everything reachable from repository $1's
# off-machine remotes, one per line. Prints nothing when it has none, which the
# caller must read as "nothing here is anywhere else", never as "all clear".
park_offsite_globs() {  # <repo>
  local repo=$1 name url
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(git -C "$repo" remote get-url "$name" 2>/dev/null) || continue
    park_url_is_offsite "$url" || continue
    printf -- '--glob=refs/remotes/%s/\n' "$name"
  done < <(git -C "$repo" remote 2>/dev/null)
}

# The repository top-level of $1, or nothing when it is not one.
park_toplevel() {  # <dir>
  [ -d "$1" ] || return 0
  git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

# Every repository this home can see: the home itself, each project clone, and
# any extra path the caller named. One top-level per line, deduplicated.
park_repos() {
  local dir top seen=$'\n'
  {
    printf '%s\n' "$FM_HOME"
    if [ -d "$PROJECTS" ]; then
      for dir in "$PROJECTS"/*/; do
        [ -d "$dir" ] || continue
        printf '%s\n' "${dir%/}"
      done
    fi
    [ "${#EXTRA_REPOS[@]}" -gt 0 ] && printf '%s\n' "${EXTRA_REPOS[@]}"
  } | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    top=$(park_toplevel "$dir")
    [ -n "$top" ] || continue
    case "$seen" in *$'\n'"$top"$'\n'*) continue ;; esac
    seen="$seen$top"$'\n'
    printf '%s\n' "$top"
  done
}

# Every local copy attached to repository $1, as "<path>\t<branch-or-empty>".
# git is asked rather than the task records, because a copy left behind by
# finished work holds no record and is exactly where stranded commits sit.
park_copies() {  # <repo>
  git -C "$1" worktree list --porcelain 2>/dev/null | awk '
    function emit() { if (path != "" && !bare && !gone) printf "%s\t%s\n", path, branch }
    /^worktree / { emit(); path = substr($0, 10); branch = ""; bare = 0; gone = 0; next }
    /^bare$/ { bare = 1; next }
    /^prunable/ { gone = 1; next }
    /^branch / { branch = substr($0, 8); sub(/^refs\/heads\//, "", branch); next }
    END { emit() }
  '
}

# The captain-facing name of a repository or local copy.
park_name() {  # <path>
  basename "$1"
}

# Commits reachable from <rev> in <dir> but from none of the given off-machine
# ref globs. Prints 0 when the count cannot be established, rather than a wrong
# number.
park_unpushed_count() {  # <dir> <rev> <glob>...
  local dir=$1 rev=$2 count
  shift 2
  count=$(git -C "$dir" rev-list "$rev" --not "$@" --count 2>/dev/null) || count=0
  case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s' "$count"
}

# --- conditions 2 and 3: unpushed and uncommitted work ----------------------

# Uncommitted changes in local copy $1. The harness scratch files an agent
# drops in a copy it works in are not the captain's work, and a review board
# left in .lavish/ is reported once by the stranded-material check rather than
# twice.
park_dirty() {  # <copy>
  git -C "$1" status --porcelain 2>/dev/null \
    | grep -vE '^\?\? (\.claude/|\.lavish/|\.fm-(grok|kimi)-turnend$)'
}

check_local_copies() {
  local repo name copy branch glob count tip
  local -a globs
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    name=$(park_name "$repo")

    globs=()
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      globs+=("$glob")
    done < <(park_offsite_globs "$repo")

    while IFS=$'\t' read -r copy branch; do
      [ -n "$copy" ] || continue
      [ -d "$copy" ] || continue

      if [ -n "$(park_dirty "$copy")" ]; then
        blocker "Uncommitted changes in the local copy of $name at $copy. Commit them, or discard them."
      fi

      # Commits sitting on no branch at all are invisible to the branch scan
      # below, and they are the ones no push would ever pick up.
      [ "${#globs[@]}" -gt 0 ] || continue
      [ -z "$branch" ] || continue
      count=$(park_unpushed_count "$copy" HEAD "${globs[@]}")
      [ "$count" -gt 0 ] || continue
      tip=$(git -C "$copy" rev-parse --verify HEAD 2>/dev/null) || tip=
      park_bundle_has "$tip" && continue
      blocker "$count commit(s) in the local copy of $name at $copy sit on no branch and on no remote off this machine. Put them on a branch and push it."
    done < <(park_copies "$repo")

    if [ "${#globs[@]}" -eq 0 ]; then
      # No off-machine remote at all. Listing every commit would be noise, so
      # say it once: nothing in this repository is anywhere else.
      count=$(git -C "$repo" rev-list --all --count 2>/dev/null) || count=0
      case "${count:-}" in ''|*[!0-9]*) count=0 ;; esac
      if [ "$count" -gt 0 ]; then
        blocker "The local copy of $name at $repo has no remote off this machine, so none of its $count commit(s) exist anywhere else. Add a remote and push it."
      fi
      continue
    fi

    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      count=$(park_unpushed_count "$repo" "$branch" "${globs[@]}")
      [ "$count" -gt 0 ] || continue
      tip=$(git -C "$repo" rev-parse --verify "$branch" 2>/dev/null) || tip=
      park_bundle_has "$tip" && continue
      blocker "Unpushed work on $name: $count commit(s) on $branch exist on no remote off this machine. Push the branch."
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
  done < <(park_repos)
}

# --- conditions 1 and 4: validation runs and workers ------------------------

check_workers() {
  local meta id project name line state source
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$(sed -n 's/^kind=//p' "$meta" | head -1)" = secondmate ] && continue
    project=$(sed -n 's/^project=//p' "$meta" | head -1)
    if [ -n "$project" ]; then name=$(park_name "$project"); else name=$id; fi

    line=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null) || continue
    state=$(printf '%s' "$line" | sed -n 's/^state: \([^ ]*\).*/\1/p')
    source=$(printf '%s' "$line" | sed -n 's/.*source: \([^ ]*\).*/\1/p')

    case "$state" in
      parked)
        blocker "A validation run on $name is waiting for a decision before it can finish. Answer it, or stop the run."
        ;;
      working)
        if [ "$source" = run-step ]; then
          blocker "A validation run is still working on $name. Wait for it to finish, or stop it."
        else
          blocker "A worker is still working on $name. Wait for it to finish, or stop it."
        fi
        ;;
    esac
  done
}

# --- condition 5: durable material outside the carried scope ----------------

check_stranded() {
  local repo copy store count meta id data_dir others
  local seen=$'\n'

  # Build the carried-scope index here, in this shell, so the per-store counts
  # below reuse it instead of each command substitution rebuilding its own.
  park_build_carried

  # Review boards. Lavish writes them beside the code it was run from, so they
  # land in local copies that cleanup destroys on purpose.
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    while IFS=$'\t' read -r copy _; do
      [ -n "$copy" ] || continue
      store="$copy/.lavish"
      [ -d "$store" ] || continue
      case "$seen" in *$'\n'"$store"$'\n'*) continue ;; esac
      seen="$seen$store"$'\n'
      count=$(park_uncarried_count "$store")
      [ "$count" -gt 0 ] || continue
      blocker "$count review board file(s) under $store are not in the home's data/ folder, so they would not travel. Copy them into data/, or delete them."
    done < <(park_copies "$repo")
  done < <(park_repos)

  # The captain's own answers as he typed them, captured beside live state.
  # Only the captured answers themselves - the sibling markers beside them are
  # runtime bookkeeping, not something anyone would want back.
  count=$(park_uncarried_count "$STATE/procevent-inbox" '*.result')
  if [ "$count" -gt 0 ]; then
    blocker "$count of the captain's recorded answers under $STATE/procevent-inbox are not in the home's data/ folder, so his exact words would not travel. Copy them into data/."
  fi

  # A task whose only account of itself is a local record. Its own folder under
  # data/ holds nothing but the instructions it was given, and it recorded no
  # pull request either, so cleanup would take the only narrative with it.
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ -f "$STATE/$id.status" ] || continue
    [ "$(sed -n 's/^kind=//p' "$meta" | head -1)" = secondmate ] && continue
    [ -n "$(sed -n 's/^pr=//p' "$meta" | head -1)" ] && continue
    data_dir="$DATA/$id"
    others=0
    if [ -d "$data_dir" ]; then
      others=$(find "$data_dir" -type f ! -name brief.md ! -name launch-brief.md 2>/dev/null | wc -l | tr -d ' ')
    fi
    case "${others:-}" in ''|*[!0-9]*) others=0 ;; esac
    [ "$others" -gt 0 ] && continue
    blocker "The only account of the work on $id is a local record that cleanup removes. Write what is worth keeping into $data_dir."
  done
}

# --- condition 6: pending captain calls -------------------------------------

check_captain_calls() {
  local task key verb note
  [ -d "$STATE" ] || return 0
  while IFS=$'\t' read -r task key verb note; do
    [ -n "$task" ] || continue
    : "$verb"
    # Exit 0 means the backlog still records this as an open call, so the other
    # machine reads the same obligation. Anything else - including "cannot
    # tell" - leaves it unproven, and the doubtful case is the one worth
    # reporting.
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" >/dev/null 2>&1 && continue
    blocker "An open question on $task is only in a local record, so the other machine would not see it: ${note:-$key}. Record it as a held task."
  done < <(scan_open_decisions "$STATE")
}

# --- verdict ----------------------------------------------------------------

check_local_copies
check_workers
check_stranded
check_captain_calls

if [ "${#BLOCKERS[@]}" -eq 0 ]; then
  printf 'SAFE - nothing blocks consolidating this home right now.\n'
else
  printf 'BLOCKED - %s thing(s) to clear before consolidating this home.\n\n' "${#BLOCKERS[@]}"
  printf -- '- %s\n' "${BLOCKERS[@]}"
fi
printf '\nJudged from what this machine already knows; no network call was made.\n'
[ "${#BLOCKERS[@]}" -eq 0 ]
