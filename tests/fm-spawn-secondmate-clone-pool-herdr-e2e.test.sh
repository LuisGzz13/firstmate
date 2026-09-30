#!/usr/bin/env bash
# tests/fm-spawn-secondmate-clone-pool-herdr-e2e.test.sh - isolated end-to-end
# test, on the real pinned Treehouse and a private Herdr lab session, that a
# secondmate home's own clone of a project launches workers from worktrees of
# that clone.
#
# Treehouse keys a pool by the repository's directory name and origin URL, so a
# root home's projects/<name> and a secondmate home's projects/<name> clone of
# one origin share a pool, and `treehouse get` from the secondmate clone handed
# out the root clone's free slot: every launch from that home was refused.
# bin/fm-wake-lib.sh's fm_treehouse_clone_pool_ensure gives the secondmate clone
# its own pool, and bin/fm-spawn.sh refuses any copy that is not a worktree of
# the declared project. tests/fm-spawn-pool-base-freshen.test.sh pins that logic
# portably; this drives the real bin/fm-spawn.sh and bin/fm-teardown.sh to prove
# the real Treehouse honors it.
#
# Covers:
#   - a default-pool slot the secondmate clone left behind (a pool from before
#     the rule) is refused for the root home's non-Claude worker
#   - the root home's clone launches from the default pool and cleans up
#   - the secondmate clone then launches from its own per-home pool, a worktree
#     of its own clone, while the root clone's slot is free in the default pool,
#     and the clone still reads clean
#   - cleanup returns that copy to the secondmate's pool and the next launch
#     reuses it
#
# Herdr keeps the real HOME, so the scratch pools land under ~/.treehouse; the
# repository name is unique per run and cleanup removes only the pools this
# run added for it. Herdr safety follows tests/herdr-test-safety.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-clone-pool-e2e.XXXXXX")
SESSION="fm-lab-clone-pool-e2e-$$"
export HERDR_SESSION="$SESSION"
REPO="fmclonepool$$"
TREEHOUSE_DIR="$HOME/.treehouse"
mkdir -p "$TREEHOUSE_DIR"
treehouse_entries() { find "$TREEHOUSE_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort; }
treehouse_entries > "$TMP_ROOT/treehouse-before"
SM_POOL_ROOT=

cleanup_all() {
  local entry
  herdr_safe_stop_and_delete "$SESSION"
  comm -13 "$TMP_ROOT/treehouse-before" <(treehouse_entries) |
    while IFS= read -r entry; do
      case "$entry" in
        "$REPO"-*) rm -rf "${TREEHOUSE_DIR:?}/$entry" ;;
        *) [ -n "$SM_POOL_ROOT" ] && [ "$entry" = "${SM_POOL_ROOT##*/}" ] && rm -rf "${TREEHOUSE_DIR:?}/$entry" ;;
      esac
    done
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

git_c() { git -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"; }

ROOT_HOME="$TMP_ROOT/root-home"
SM_HOME="$TMP_ROOT/sm-home"
for home in "$ROOT_HOME" "$SM_HOME"; do
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
done
printf 'e2eclonepool\n' > "$SM_HOME/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT_HOME" > "$SM_HOME/.fm-secondmate-parent"
# The root home's own records of the secondmate, which cleanup from its home resolves.
printf -- '- e2eclonepool - E2E secondmate. (home: %s; scope: e2e; projects: %s; added 2026-09-30)\n' \
  "$SM_HOME" "$REPO" > "$ROOT_HOME/data/secondmates.md"
printf 'kind=secondmate\nhome=%s\n' "$SM_HOME" > "$ROOT_HOME/state/e2eclonepool.meta"

git init -q -b main "$TMP_ROOT/seed"
printf '# scratch\n' > "$TMP_ROOT/seed/README.md"
git -C "$TMP_ROOT/seed" add README.md
git_c -C "$TMP_ROOT/seed" commit -qm initial
git clone -q --bare "$TMP_ROOT/seed" "$TMP_ROOT/$REPO.git"
ROOT_CLONE="$ROOT_HOME/projects/$REPO"
SM_CLONE="$SM_HOME/projects/$REPO"
git clone -q "file://$TMP_ROOT/$REPO.git" "$ROOT_CLONE"
git clone -q "file://$TMP_ROOT/$REPO.git" "$SM_CLONE"
SM_POOL_ROOT=$(. "$ROOT/bin/fm-wake-lib.sh" && fm_treehouse_clone_pool_root "$SM_HOME") \
  || fail "could not resolve the secondmate home's Treehouse pool root"

common_dir() { (cd "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)" && pwd -P); }
ROOT_COMMON=$(common_dir "$ROOT_CLONE")
SM_COMMON=$(common_dir "$SM_CLONE")

spawn() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nE2E task %s.\n\n## Firstmate spec\nDo nothing.\n' "$id" > "$home/data/$id/brief.md"
  ( cd "$home" && FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "projects/$REPO" "sh -c 'echo $id-ok; exec sleep 600'" --scout --backend herdr ) \
    > "$TMP_ROOT/$id.out" 2>&1
}

teardown() {  # <home> <id>
  local home=$1 id=$2
  printf '# report\nnothing\n' > "$home/data/$id/report.md"
  ( cd "$home" && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none \
    && FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "$id" ) > "$TMP_ROOT/$id.teardown" 2>&1 \
    || fail "cleanup of $id failed"$'\n'"$(cat "$TMP_ROOT/$id.teardown")"
}

task_copy() { sed -n 's/^worktree=//p' "$1/state/$2.meta" 2>/dev/null; }

# --- 0. a default-pool slot the secondmate clone left behind ------------------
LEGACY=$(cd "$SM_CLONE" && treehouse get --lease 2>/dev/null) || fail "could not lease a default-pool slot from the secondmate clone"
[ "$(common_dir "$LEGACY")" = "$SM_COMMON" ] || fail "the legacy slot is not a worktree of the secondmate clone"
( cd "$SM_CLONE" && treehouse return --force "$LEGACY" ) >/dev/null 2>&1 || fail "could not return the legacy slot"

spawn "$ROOT_HOME" rootlegacy
rc=$?
[ "$rc" -ne 0 ] || fail "the root home launched a worker in the secondmate clone's slot"$'\n'"$(cat "$TMP_ROOT/rootlegacy.out")"
grep -q "another clone of the same origin shares this Treehouse pool" "$TMP_ROOT/rootlegacy.out" \
  || fail "the refusal did not name the shared pool"$'\n'"$(cat "$TMP_ROOT/rootlegacy.out")"
[ ! -e "$ROOT_HOME/state/rootlegacy.meta" ] || fail "the refused spawn published a task record"
pass "real Treehouse E2E: the root home refuses a default-pool slot that belongs to the secondmate clone"

# --- 1. the root home's clone launches from the default pool -----------------
spawn "$ROOT_HOME" rootcm || fail "the root home's spawn failed"$'\n'"$(cat "$TMP_ROOT/rootcm.out")"
ROOT_COPY=$(task_copy "$ROOT_HOME" rootcm)
[ "$(common_dir "$ROOT_COPY")" = "$ROOT_COMMON" ] || fail "the root home's copy is not a worktree of its clone: $ROOT_COPY"
case "$ROOT_COPY" in "$TREEHOUSE_DIR/$REPO"-*) ;; *) fail "the root home's copy is not in the default pool: $ROOT_COPY" ;; esac
[ ! -e "$ROOT_CLONE/treehouse.toml" ] || fail "the root home's spawn wrote a treehouse.toml into its clone"
teardown "$ROOT_HOME" rootcm
pass "real Treehouse E2E: the root home's clone launches from the default pool and returns its slot"

# --- 2. the secondmate clone launches from its own pool ----------------------
spawn "$SM_HOME" smcm || fail "the secondmate clone's spawn failed"$'\n'"$(cat "$TMP_ROOT/smcm.out")"
SM_COPY=$(task_copy "$SM_HOME" smcm)
[ "$(common_dir "$SM_COPY")" = "$SM_COMMON" ] || fail "the secondmate's copy is not a worktree of its own clone: $SM_COPY"
case "$SM_COPY" in "$SM_POOL_ROOT/.treehouse/$REPO"-*) ;; *) fail "the secondmate's copy is not in its own pool: $SM_COPY" ;; esac
[ -z "$(git -C "$SM_CLONE" status --porcelain --untracked-files=all)" ] \
  || fail "the secondmate clone reads as changed: $(git -C "$SM_CLONE" status --porcelain --untracked-files=all)"
pass "real Treehouse E2E: the secondmate clone launches from its own pool while the root clone's slot is free"

# --- 3. cleanup returns the copy to the secondmate's pool, and it is reused ---
teardown "$SM_HOME" smcm
spawn "$SM_HOME" smcm2 || fail "the secondmate clone's second spawn failed"$'\n'"$(cat "$TMP_ROOT/smcm2.out")"
[ "$(task_copy "$SM_HOME" smcm2)" = "$SM_COPY" ] \
  || fail "the secondmate's second launch did not reuse its returned copy: $(task_copy "$SM_HOME" smcm2)"
teardown "$SM_HOME" smcm2
pass "real Treehouse E2E: the secondmate's cleanup returns its copy to its own pool for reuse"
