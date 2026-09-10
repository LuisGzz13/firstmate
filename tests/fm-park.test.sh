#!/usr/bin/env bash
# Behavior tests for bin/fm-park.sh - the read-only "is it safe to consolidate
# this home" check.
#
# Two of these exist because the check falling for either trap would be worse
# than having no check: a remote that is not named origin must not be read as
# unpushed work, and a remote that IS named origin but points at a bare mirror
# on this same disk must not be read as work that left the machine.
#
# fm-park.sh resolves its siblings from its own directory, so each fixture runs
# it from a mirror bin/ of symlinks into the real bin/, with fm-crew-state.sh
# and fm-captain-hold.sh replaced by stubs. That keeps every assertion on
# fm-park.sh's own behavior through its real command-line interface, without a
# production knob that exists only for tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-park)
fm_git_identity

# --- fixtures ---------------------------------------------------------------

# A home with the standard directories and a mirror bin/. Echoes the home path.
make_home() {
  local name=$1 home bin f
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  # A real home keeps its operational directories out of its own repository,
  # and the fixture has to match or every case would trip the uncommitted check.
  cat > "$home/.gitignore" <<'IGNORE'
/bin/
/state/
/data/
/config/
/projects/
/.lavish/
/crew-states
IGNORE
  bin="$home/bin"
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$bin/$(basename "$f")"
  done
  rm -f "$bin/fm-crew-state.sh" "$bin/fm-captain-hold.sh"
  : > "$home/crew-states"
  cat > "$bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
line=$(sed -n "s/^$1	//p" "$FM_PARK_TEST_STATES" 2>/dev/null | head -1)
[ -n "$line" ] || line="state: done · source: status-log · nothing running"
printf '%s\n' "$line"
SH
  chmod +x "$bin/fm-crew-state.sh"
  cat > "$bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
exit "${FM_PARK_TEST_HOLD_RC:-1}"
SH
  chmod +x "$bin/fm-captain-hold.sh"
  printf '%s\n' "$home"
}

# Run the check against home $1, with any remaining arguments passed through.
# Sets PARK_OUT and PARK_RC rather than echoing, because a caller capturing the
# output in a command substitution would run this in a subshell and never see
# the exit code the whole suite asserts on.
PARK_RC=0
PARK_OUT=
park() {
  local home=$1
  PARK_RC=0
  PARK_OUT=$(FM_HOME="$home" FM_PARK_TEST_STATES="$home/crew-states" \
    "$home/bin/fm-park.sh" "${@:2}" 2>&1) || PARK_RC=$?
}

# Point every remote-tracking ref of remote $2 at its local branch, which is
# exactly what a completed push and fetch leaves behind - and needs no network.
park_sync_remote() {  # <repo> <remote>
  local repo=$1 name=$2 b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    git -C "$repo" update-ref "refs/remotes/$name/$b" "$(git -C "$repo" rev-parse "$b")"
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/)
}

# A repository with one commit, fully pushed to a remote that is genuinely off
# this machine. The remote NAME is a parameter because assuming origin is one
# of the two traps under test.
park_repo() {  # <dir> [remote-name] [url]
  local dir=$1 name=${2:-origin} url=${3:-}
  [ -n "$url" ] || url="https://example.invalid/$(basename "$dir").git"
  fm_git_init_commit "$dir"
  if [ -f "$dir/.gitignore" ]; then
    git -C "$dir" add .gitignore
    git -C "$dir" -c user.name=fmtest -c user.email=fmtest@example.invalid \
      commit -qm gitignore
  fi
  git -C "$dir" remote add "$name" "$url"
  park_sync_remote "$dir" "$name"
}

park_commit() {  # <dir> <file> <text>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm "$3"
}

set_state() {  # <home> <task-id> <crew-state-line>
  printf '%s\t%s\n' "$2" "$3" >> "$1/crew-states"
}

write_task() {  # <home> <task-id> [extra-meta-line...]
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" \
    "window=fixture:w1:p1" \
    "worktree=$home" \
    "project=$home" \
    "kind=ship" \
    "mode=local-only" \
    "${@}"
  printf 'working: under way\n' >> "$home/state/$id.status"
  # Give the task a durable account of itself so the stranded-material check
  # stays out of the way of cases that are not about it.
  mkdir -p "$home/data/$id"
  printf 'report\n' > "$home/data/$id/report.md"
}

# --- the clean baseline -----------------------------------------------------

test_clean_home_is_safe() {
  local home out
  home=$(make_home clean)
  park_repo "$home"
  park "$home"; out=$PARK_OUT

  expect_code 0 "$PARK_RC" "a clean home did not exit 0"
  assert_contains "$out" "SAFE" "a clean home was not reported safe"
  assert_not_contains "$out" "BLOCKED" "a clean home reported a blocker"
  assert_contains "$out" "no network call" "the verdict dropped its no-network statement"
  pass "a clean home is safe"
}

test_usage_error_exits_2() {
  local home out
  home=$(make_home usage)
  park "$home" --nonsense; out=$PARK_OUT
  expect_code 2 "$PARK_RC" "an unknown argument did not exit 2"
  assert_contains "$out" "fm-park.sh" "the usage error did not print usage"
  pass "an unknown argument is a usage error"
}

# --- conditions 2 and 3: unpushed and uncommitted work ----------------------

test_uncommitted_changes_block() {
  local home out
  home=$(make_home dirty)
  park_repo "$home/projects/alpha"
  printf 'edited\n' > "$home/projects/alpha/README.md"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "uncommitted changes did not exit 1"
  assert_contains "$out" "Uncommitted changes in the local copy of alpha" \
    "uncommitted changes were not reported"
  assert_contains "$out" "$home/projects/alpha" "the report did not name the local copy"
  pass "uncommitted changes in a local copy block"
}

test_unpushed_commits_block() {
  local home out
  home=$(make_home unpushed)
  park_repo "$home/projects/alpha"
  git -C "$home/projects/alpha" checkout -q -b feature
  park_commit "$home/projects/alpha" one.txt one
  park_commit "$home/projects/alpha" two.txt two

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "unpushed commits did not exit 1"
  assert_contains "$out" "Unpushed work on alpha: 2 commit(s) on feature" \
    "unpushed commits were not reported with their branch and count"
  pass "committed-but-unpushed work blocks"
}

test_a_remote_not_named_origin_is_not_a_false_blocker() {
  local home out
  home=$(make_home named-remote)
  # The trap: this repository's only remote is named `dotfiles`, and everything
  # is pushed to it. A scan of refs/remotes/origin/ would report every commit
  # as unpushed.
  park_repo "$home/projects/dots" dotfiles https://example.invalid/dots.git
  git -C "$home/projects/dots" checkout -q -b feature
  park_commit "$home/projects/dots" one.txt one
  park_sync_remote "$home/projects/dots" dotfiles
  park_repo "$home"

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a fully pushed non-origin remote was treated as a blocker"
  assert_not_contains "$out" "Unpushed work on dots" \
    "work pushed to a remote not named origin was reported as unpushed"
  pass "a remote that is not named origin is resolved by name"
}

test_a_remote_on_this_disk_is_not_somewhere_else() {
  local home out mirror tip
  home=$(make_home local-mirror)
  park_repo "$home/projects/alpha"
  git -C "$home/projects/alpha" checkout -q -b feature
  park_commit "$home/projects/alpha" one.txt one

  # The trap: a validation pipeline registers a remote pointing at a bare
  # mirror on this same disk and pushes the branch there. `--not --remotes`
  # would call this work safe when it exists nowhere but here.
  mirror="$TMP_ROOT/local-mirror.aux.git"
  git init -q --bare "$mirror"
  git -C "$home/projects/alpha" remote add no-mistakes "$mirror"
  tip=$(git -C "$home/projects/alpha" rev-parse feature)
  git -C "$home/projects/alpha" update-ref refs/remotes/no-mistakes/feature "$tip"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "work held only by a same-disk mirror was not reported"
  assert_contains "$out" "Unpushed work on alpha: 1 commit(s) on feature" \
    "a local-path remote was accepted as somewhere else"
  pass "a remote whose URL is a local path does not count as off this machine"
}

test_a_file_url_remote_is_not_somewhere_else() {
  local home out tip
  home=$(make_home file-url)
  # A genuinely off-machine remote holds main, so the repository is not caught
  # by the no-remote-at-all case and the branch below is judged on its own.
  park_repo "$home/projects/alpha"
  git -C "$home/projects/alpha" checkout -q -b feature
  park_commit "$home/projects/alpha" one.txt one
  git -C "$home/projects/alpha" remote add backup "file:///srv/mirrors/alpha.git"
  tip=$(git -C "$home/projects/alpha" rev-parse feature)
  git -C "$home/projects/alpha" update-ref refs/remotes/backup/feature "$tip"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a file:// remote was accepted as off this machine"
  assert_contains "$out" "Unpushed work on alpha: 1 commit(s) on feature" \
    "work held only by a file:// remote was not reported"
  pass "a file:// remote does not count as off this machine"
}

test_a_repository_with_no_remote_at_all_blocks_once() {
  local home out
  home=$(make_home no-remote)
  fm_git_init_commit "$home/projects/alpha"
  park_commit "$home/projects/alpha" one.txt one
  park_commit "$home/projects/alpha" two.txt two

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a repository with no remote was not reported"
  assert_contains "$out" "has no remote off this machine" \
    "a repository with no remote at all was not reported"
  assert_contains "$out" "3 commit(s) exist anywhere else" \
    "the no-remote report did not count the work at risk"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'has no remote off this machine')" \
    "a repository with no remote was reported more than once"
  pass "a repository on no remote at all is reported once, for the whole repository"
}

test_commits_on_no_branch_block() {
  local home out copy
  home=$(make_home detached)
  park_repo "$home/projects/alpha"
  copy="$TMP_ROOT/detached.aux"
  git -C "$home/projects/alpha" worktree add --quiet --detach "$copy"
  park_commit "$copy" scratch.txt scratch

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a commit on no branch was not reported"
  assert_contains "$out" "sit on no branch and on no remote off this machine" \
    "a commit reachable from no branch at all was not reported"
  pass "commits on no branch in a local copy block"
}

test_a_bundle_in_the_carried_scope_clears_an_unpushed_branch() {
  local home out tip
  home=$(make_home bundled)
  park_repo "$home/projects/alpha"
  git -C "$home/projects/alpha" checkout -q -b feature
  park_commit "$home/projects/alpha" one.txt one

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "the unpushed branch was not reported before it was captured"

  mkdir -p "$home/data/alpha"
  git -C "$home/projects/alpha" bundle create -q "$home/data/alpha/feature.bundle" feature
  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a branch captured in a carried bundle was still reported"
  assert_not_contains "$out" "Unpushed work on alpha" \
    "a branch whose exact tip is in a carried bundle was reported as at risk"

  # A bundle that names an older tip proves nothing about the work added since.
  tip=$(git -C "$home/projects/alpha" rev-parse feature)
  park_commit "$home/projects/alpha" two.txt two
  assert_not_equals "$tip" "$(git -C "$home/projects/alpha" rev-parse feature)" \
    "the fixture did not actually advance the branch past the bundled tip"
  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a stale bundle was accepted for work added after it"
  assert_contains "$out" "Unpushed work on alpha" \
    "a bundle naming an older tip cleared a branch that has moved on"
  pass "a carried bundle clears exactly the tip it names, and nothing later"
}

# --- conditions 1 and 4: validation runs and workers ------------------------

test_a_worker_mid_work_blocks() {
  local home out
  home=$(make_home worker)
  park_repo "$home"
  write_task "$home" alpha-w1
  set_state "$home" alpha-w1 "state: working · source: pane · harness busy"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a worker mid-work did not block"
  assert_contains "$out" "A worker is still working on" "a busy worker was not reported"
  assert_not_contains "$out" "A validation run is still working" \
    "a busy pane was misreported as a validation run"
  pass "a worker mid-work blocks"
}

test_an_active_validation_run_blocks_and_names_itself() {
  local home out
  home=$(make_home run-active)
  park_repo "$home"
  write_task "$home" alpha-v1
  set_state "$home" alpha-v1 "state: working · source: run-step · running"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "an active validation run did not block"
  assert_contains "$out" "A validation run is still working on" \
    "an active validation run was not reported as one"
  pass "an active validation run blocks and is named as a validation run"
}

test_a_parked_run_blocks() {
  local home out
  home=$(make_home run-parked)
  park_repo "$home"
  write_task "$home" alpha-p1
  set_state "$home" alpha-p1 "state: parked · source: run-step · awaiting approval"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a run parked at a gate did not block"
  assert_contains "$out" "waiting for a decision before it can finish" \
    "a run parked at a gate was not reported"
  pass "a validation run parked at a gate still owns its branch and blocks"
}

test_declared_waits_and_idle_workers_do_not_block() {
  local home out state
  for state in \
    "state: paused · source: status-log · waiting on the captain's client answers" \
    "state: blocked · source: status-log · needs a credential" \
    "state: done · source: status-log · finished" \
    "state: failed · source: run-step · failed" \
    "state: unknown · source: none · backend target gone"; do
    home=$(make_home "idle-$RANDOM")
    park_repo "$home"
    write_task "$home" alpha-i1
    set_state "$home" alpha-i1 "$state"
    park "$home"; out=$PARK_OUT
    expect_code 0 "$PARK_RC" "a worker reported as '$state' was treated as mid-work"
    assert_contains "$out" "SAFE" "a worker reported as '$state' blocked the verdict"
  done
  pass "declared waits, finished work, and an unreachable worker do not block"
}

test_a_secondmate_home_is_left_to_its_own_check() {
  local home out
  home=$(make_home secondmate)
  park_repo "$home"
  fm_write_secondmate_meta "$home/state/mate-s1.meta" "$home/mate"
  printf 'working: under way\n' >> "$home/state/mate-s1.status"
  set_state "$home" mate-s1 "state: working · source: pane · harness busy"

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a busy secondmate blocked this home's verdict"
  assert_contains "$out" "SAFE" "a secondmate was checked from the parent home"
  pass "a secondmate home consolidates through its own check"
}

# --- condition 5: durable material outside the carried scope ----------------

test_review_boards_outside_the_carried_scope_block() {
  local home out
  home=$(make_home boards)
  park_repo "$home"
  mkdir -p "$home/.lavish"
  printf '<html>a board the captain reviewed</html>\n' > "$home/.lavish/decision.html"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a review board outside the carried scope did not block"
  assert_contains "$out" "1 review board file(s)" "the stranded board was not reported"
  assert_contains "$out" "$home/.lavish" "the report did not name the store"

  # Copying it into data/ is what makes it travel, and that is what clears it.
  mkdir -p "$home/data/boards"
  cp "$home/.lavish/decision.html" "$home/data/boards/decision.html"
  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a board copied into data/ was still reported"
  assert_not_contains "$out" "review board file(s)" "a carried board was reported as stranded"
  pass "review boards block until their bytes are inside the carried scope"
}

test_records_consolidated_into_one_archive_count_as_carried() {
  local home out i
  home=$(make_home consolidated)
  park_repo "$home"
  mkdir -p "$home/state/procevent-inbox"
  for i in 1 2 3; do
    printf 'The captain answered board %s: absorb it and keep one hundred and fifty flat everywhere.\n' \
      "$i" > "$home/state/procevent-inbox/board.$i.result"
  done

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "captured answers outside the carried scope did not block"
  assert_contains "$out" "3 of the captain's recorded answers" \
    "the three captured answers were not reported"

  # Exporting them into ONE archive is what actually happens, and it leaves no
  # file with matching bytes. A per-file comparison would light this blocker
  # forever, which is the whole reason the containment pass exists.
  {
    printf '# The captain answers, verbatim archive\n\n'
    for i in 1 2 3; do
      printf '## board.%s\n\n```\n' "$i"
      cat "$home/state/procevent-inbox/board.$i.result"
      printf '```\n\n'
    done
  } > "$home/data/captain-answers-archive.md"

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "records consolidated into one archive were still reported"
  assert_not_contains "$out" "recorded answers" \
    "an archive that carries every record did not clear them"
  pass "records consolidated into a single archive count as carried"
}

test_a_partial_archive_still_reports_what_it_left_out() {
  local home out
  home=$(make_home partial-archive)
  park_repo "$home"
  mkdir -p "$home/state/procevent-inbox"
  printf 'The captain kept the home address as the return address on every label.\n' \
    > "$home/state/procevent-inbox/board.1.result"
  printf 'The captain chose Phobos, because it is the only name that obeys the rule.\n' \
    > "$home/state/procevent-inbox/board.2.result"

  # An archive that carries one record and not the other must still report the
  # one it left out: the conservative bias is what this whole check is for.
  {
    printf '# archive\n\n'
    cat "$home/state/procevent-inbox/board.1.result"
  } > "$home/data/captain-answers-archive.md"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a record the archive left out was passed over"
  assert_contains "$out" "1 of the captain's recorded answers" \
    "a partial archive cleared a record it does not carry"
  pass "a partial archive still reports the records it left out"
}

test_a_board_carried_under_a_different_name_and_folder_clears() {
  local home out
  home=$(make_home renamed-board)
  park_repo "$home"
  mkdir -p "$home/.lavish" "$home/data/boards/archive"
  printf '<html><body>The decision, the evidence behind it, and the plan it produced.</body></html>\n' \
    > "$home/.lavish/decision.html"
  cp "$home/.lavish/decision.html" "$home/data/boards/archive/2026-09-10-decision-record.html"

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a board carried under a different name and folder was reported"
  assert_not_contains "$out" "review board file(s)" \
    "coverage was decided by filename rather than by content"
  pass "a board carried under a different name and folder clears"
}

test_a_board_folded_into_a_larger_document_clears() {
  local home out
  home=$(make_home folded-board)
  park_repo "$home"
  mkdir -p "$home/.lavish"
  cat > "$home/.lavish/decision.html" <<'BOARD'
<html><body>
<p>The first finding, which settled how the shipping rate is calculated.</p>
<p>The second finding, which settled which of the two names the product takes.</p>
</body></html>
BOARD
  {
    printf '# Report\n\nThe board this was built from is reproduced below.\n\n'
    cat "$home/.lavish/decision.html"
    printf '\nAnd the conclusion it led to.\n'
  } > "$home/data/report.md"

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a board folded into a larger carried document was reported"
  pass "a board folded into a larger carried document clears"
}

test_boilerplate_alone_never_clears_an_artifact() {
  local home out
  home=$(make_home boilerplate)
  park_repo "$home"
  mkdir -p "$home/.lavish"
  # Two boards from one generator share every line of their frame. Only the
  # first is carried. The second must still report, because sharing a frame is
  # not being carried.
  cat > "$home/.lavish/carried.html" <<'BOARD'
<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
<body class="board-frame board-frame--wide" data-generator="the shared board generator">
<p>The first board says the coating was tested for eighteen months in the desert.</p>
</body></html>
BOARD
  sed 's/first board says the coating was tested for eighteen months in the desert/second board says something else entirely that appears nowhere else/'     "$home/.lavish/carried.html" > "$home/.lavish/stranded.html"
  cp "$home/.lavish/carried.html" "$home/data/carried.html"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a board sharing only its frame with a carried board was cleared"
  assert_contains "$out" "1 review board file(s)" \
    "shared boilerplate cleared an artifact that is not carried, or the carried one was reported"
  pass "shared boilerplate alone never clears an artifact"
}

test_a_binary_artifact_is_judged_on_its_bytes_alone() {
  local home out
  home=$(make_home binary)
  park_repo "$home"
  mkdir -p "$home/.lavish"
  printf '\211PNG\r\n\032\n' > "$home/.lavish/shot.png"
  printf 'this is padding that makes the screenshot long enough to sample from\n' \
    >> "$home/.lavish/shot.png"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a screenshot outside the carried scope was not reported"
  assert_contains "$out" "1 review board file(s)" "the screenshot was not reported"

  cp "$home/.lavish/shot.png" "$home/data/shot.png"
  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a screenshot copied into data/ was still reported"
  pass "a binary artifact clears by its bytes and never by sampled lines"
}

test_captured_captain_answers_block_but_their_markers_do_not() {
  local home out
  home=$(make_home answers)
  park_repo "$home"
  mkdir -p "$home/state/procevent-inbox"
  printf 'Absorb it - keep 150 flat everywhere\n' > "$home/state/procevent-inbox/board.1.result"
  printf 'lavish\n' > "$home/state/procevent-inbox/board.1.adapter"
  : > "$home/state/procevent-inbox/board.1.handled"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a captured captain answer outside the carried scope did not block"
  assert_contains "$out" "1 of the captain's recorded answers" \
    "the captured answer was not reported, or its runtime markers were counted with it"

  cp "$home/state/procevent-inbox/board.1.result" "$home/data/captain-answer.txt"
  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "an answer copied into data/ was still reported"
  pass "captured captain answers block until carried, and their markers never count"
}

test_a_task_with_no_durable_account_blocks() {
  local home out
  home=$(make_home account)
  park_repo "$home"
  fm_write_meta "$home/state/orphan-o1.meta" "kind=ship" "project=$home"
  printf 'working: the whole engineering handover lives here\n' >> "$home/state/orphan-o1.status"
  mkdir -p "$home/data/orphan-o1"
  printf 'instructions\n' > "$home/data/orphan-o1/brief.md"
  printf 'instructions\n' > "$home/data/orphan-o1/launch-brief.md"

  park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a task whose only account is a local record did not block"
  assert_contains "$out" "The only account of the work on orphan-o1" \
    "the task with no durable account was not reported"

  printf 'what was proved and what remains\n' > "$home/data/orphan-o1/handover.md"
  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a task whose account was written into data/ was still reported"
  pass "a task blocks until something other than its instructions is in the carried scope"
}

test_a_recorded_pull_request_is_a_durable_account() {
  local home out
  home=$(make_home account-pr)
  park_repo "$home"
  fm_write_meta "$home/state/shipped-s1.meta" \
    "kind=ship" "project=$home" "pr=https://example.invalid/x/pull/7"
  printf 'done: PR https://example.invalid/x/pull/7\n' >> "$home/state/shipped-s1.status"

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a task whose deliverable is a recorded pull request blocked"
  assert_not_contains "$out" "The only account of the work on shipped-s1" \
    "a task with a recorded pull request was reported as having no durable account"
  pass "a recorded pull request is a durable account of the work"
}

# --- condition 6: pending captain calls -------------------------------------

test_an_open_question_with_no_held_task_blocks() {
  local home out
  home=$(make_home calls)
  park_repo "$home"
  write_task "$home" alpha-q1
  printf 'needs-decision [key=shipping]: flat rate or by weight\n' >> "$home/state/alpha-q1.status"

  # The backlog does not record it: nothing the other machine reads would show
  # the captain owes an answer.
  FM_PARK_TEST_HOLD_RC=1 park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "an unrecorded open question did not block"
  assert_contains "$out" "An open question on alpha-q1 is only in a local record" \
    "the unrecorded open question was not reported"
  assert_contains "$out" "flat rate or by weight" "the report did not carry the question itself"

  # Recorded as a held task, the other machine reads the same obligation.
  FM_PARK_TEST_HOLD_RC=0 park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "an open question recorded as a held task still blocked"
  pass "an open question blocks until it is recorded durably"
}

test_an_unprovable_captain_call_is_reported_rather_than_assumed_safe() {
  local home out
  home=$(make_home calls-unknown)
  park_repo "$home"
  write_task "$home" alpha-q2
  printf 'blocked [key=creds]: needs the store token\n' >> "$home/state/alpha-q2.status"

  # Exit 2 is "cannot tell". The doubtful case is the one worth reporting.
  FM_PARK_TEST_HOLD_RC=2 park "$home"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "an unprovable captain call was passed over"
  assert_contains "$out" "An open question on alpha-q2 is only in a local record" \
    "a captain call that could not be proven durable was not reported"
  pass "a captain call that cannot be proven durable is reported, not assumed safe"
}

test_a_resolved_question_does_not_block() {
  local home out
  home=$(make_home calls-resolved)
  park_repo "$home"
  write_task "$home" alpha-q3
  printf 'needs-decision [key=shipping]: flat rate or by weight\n' >> "$home/state/alpha-q3.status"
  printf 'resolved [key=shipping]: flat rate everywhere\n' >> "$home/state/alpha-q3.status"

  FM_PARK_TEST_HOLD_RC=1 park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "an answered question was still reported as pending"
  assert_contains "$out" "SAFE" "an answered question blocked the verdict"
  pass "a question the captain already answered does not block"
}

# --- reach ------------------------------------------------------------------

test_an_extra_repository_is_scanned_on_request() {
  local home out outside
  home=$(make_home extra-repo)
  park_repo "$home"
  outside="$TMP_ROOT/extra-repo.aux/outside"
  fm_git_init_commit "$outside"
  git -C "$outside" remote add dotfiles https://example.invalid/outside.git
  park_sync_remote "$outside" dotfiles
  park_commit "$outside" one.txt one

  park "$home"; out=$PARK_OUT
  expect_code 0 "$PARK_RC" "a repository outside the home was scanned without being asked for"

  park "$home" --repo "$outside"; out=$PARK_OUT
  expect_code 1 "$PARK_RC" "a named repository outside the home was not scanned"
  assert_contains "$out" "Unpushed work on outside: 1 commit(s) on main" \
    "the named repository's unpushed work was not reported"
  pass "--repo brings a repository outside the home into the scan"
}

test_the_check_changes_nothing() {
  local home before after
  home=$(make_home read-only)
  park_repo "$home"
  write_task "$home" alpha-r1
  set_state "$home" alpha-r1 "state: working · source: pane · harness busy"
  mkdir -p "$home/.lavish"
  printf 'board\n' > "$home/.lavish/board.html"
  git -C "$home" checkout -q -b feature
  park_commit "$home" one.txt one

  before=$(find "$home" -print0 2>/dev/null | LC_ALL=C sort -z | tr '\0' '\n')
  park "$home"
  expect_code 1 "$PARK_RC" "the read-only fixture did not produce the expected verdict"
  after=$(find "$home" -print0 2>/dev/null | LC_ALL=C sort -z | tr '\0' '\n')

  assert_equals "$before" "$after" "the check added or removed files under the home"
  assert_equals "feature" "$(git -C "$home" rev-parse --abbrev-ref HEAD)" \
    "the check moved the checked-out branch"
  assert_equals "" "$(git -C "$home" status --porcelain)" \
    "the check left the repository dirty"
  pass "the check writes nothing and moves nothing"
}

test_clean_home_is_safe
test_usage_error_exits_2
test_uncommitted_changes_block
test_unpushed_commits_block
test_a_remote_not_named_origin_is_not_a_false_blocker
test_a_remote_on_this_disk_is_not_somewhere_else
test_a_file_url_remote_is_not_somewhere_else
test_a_repository_with_no_remote_at_all_blocks_once
test_commits_on_no_branch_block
test_a_bundle_in_the_carried_scope_clears_an_unpushed_branch
test_a_worker_mid_work_blocks
test_an_active_validation_run_blocks_and_names_itself
test_a_parked_run_blocks
test_declared_waits_and_idle_workers_do_not_block
test_a_secondmate_home_is_left_to_its_own_check
test_review_boards_outside_the_carried_scope_block
test_captured_captain_answers_block_but_their_markers_do_not
test_records_consolidated_into_one_archive_count_as_carried
test_a_partial_archive_still_reports_what_it_left_out
test_a_board_carried_under_a_different_name_and_folder_clears
test_a_board_folded_into_a_larger_document_clears
test_boilerplate_alone_never_clears_an_artifact
test_a_binary_artifact_is_judged_on_its_bytes_alone
test_a_task_with_no_durable_account_blocks
test_a_recorded_pull_request_is_a_durable_account
test_an_open_question_with_no_held_task_blocks
test_an_unprovable_captain_call_is_reported_rather_than_assumed_safe
test_a_resolved_question_does_not_block
test_an_extra_repository_is_scanned_on_request
test_the_check_changes_nothing
