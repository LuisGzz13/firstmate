# Local layer

This checkout carries our own Firstmate changes on top of upstream [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
Upstream changes its shared files often, so every local edit inside an upstream file is a future merge conflict.
The local layer keeps our own work in files upstream does not have, so an upstream merge never has to touch it.
Firstmate features are built here first; publishing one upstream is a separate decision by the captain.

## The rule

- A new local feature keeps its code, docs and tests in local files, named as below.
- An upstream file is touched only by a hook: the smallest import, source or call that reaches a local file.
- A hook degrades to upstream's own behavior when its local file is absent, so a copy of the upstream file alone still works as upstream ships it.
- Apart from its hook lines, every upstream file stays byte-identical to upstream.
- A local layer that changes how an upstream function behaves does so only under an explicit opt-in, so every other caller keeps upstream's behavior.
- A local file that mirrors an upstream format pins the upstream version it was written against and steps aside to upstream's own path when that version moves, so an upstream change costs speed, never correctness.
- A fix to existing upstream behavior that only makes sense inside the upstream function stays in that function instead, as a candidate for an upstream pull request, so it leaves our diff when upstream takes it.

## Naming

| Kind | Name | Example |
| --- | --- | --- |
| Shell script | `bin/fm-local-<topic>.sh` | `bin/fm-local-voice-fleet-states.sh` |
| Layer over an upstream shell library | `bin/fm-local-<upstream name>` | `bin/fm-local-classify-lib.sh` over `bin/fm-classify-lib.sh` |
| Python module | `bin/fm_local_<topic>.py` | `bin/fm_local_voice_records.py` |
| Test | `tests/fm-local-<topic>.test.sh` | `tests/fm-local-voice-records.test.sh` |
| Doc | `docs/local-<topic>.md` | `docs/local-voice-records.md` |

`git ls-files | grep -E '(^|/)(fm[-_])?local[-_]'` lists the whole layer.
`bin/fm-test-run.sh` runs a `tests/fm-local-*.test.sh` file like any other test, serially in its `unclassified` family, with no edit to the runner.
`bin/fm-doc-audience-check.sh` requires every tracked Markdown file to be classified, so each local doc needs one entry in `docs/documentation-audiences.json`, which is that doc's hook.

## Hook patterns

A shell library sources its local layer as its last step, guarded by a readability test, so every upstream definition already exists:

```sh
# Local layer (docs/local-layer.md): absent upstream, so nothing is sourced there.
# shellcheck source=bin/fm-local-classify-lib.sh
[ ! -r "$_FM_CLASSIFY_LIB_DIR/fm-local-classify-lib.sh" ] || . "$_FM_CLASSIFY_LIB_DIR/fm-local-classify-lib.sh"
```

A Python module imports its local layer under a guard and calls it only when the import succeeded:

```python
try:  # Local layer, docs/local-layer.md: absent upstream, so this degrades to None.
    import fm_local_voice_records as _local
except ImportError:
    _local = None
```

A local test case goes in a local test file, so upstream test files stay untouched.

## Hooks in place

| Upstream file | Hook | Local file |
| --- | --- | --- |
| `bin/fm-classify-lib.sh` | sources the local layer as its last step | `bin/fm-local-classify-lib.sh` |
| `bin/fm_voice_records.py` | guarded import, one call in `fleet_status`, one in `main` | `bin/fm_local_voice_records.py` |
| `docs/documentation-audiences.json` | one entry per local doc | `docs/local-*.md` |

The local features behind them are described in [local-voice-records.md](local-voice-records.md).

## Fixes kept in upstream files

The secondmate seeded-slot fix in `bin/fm-home-seed.sh`, `bin/fm-teardown.sh` and `bin/fm-wake-lib.sh` mirrors the open upstream pull request https://github.com/kunchenguid/firstmate/pull/6273.
The secondmate clone-pool fix in `bin/fm-spawn.sh` and `bin/fm-wake-lib.sh` repairs upstream's spawn path and has no upstream pull request yet.
Both stay where they are under the last rule above, together with their docs and tests.

## Checking the footprint

`git diff --stat $(git merge-base HEAD origin/main) HEAD` shows every upstream file the local checkout still edits.
After `git fetch origin`, `git merge-tree --write-tree HEAD origin/main` shows whether the next upstream merge would conflict, without touching the working tree.
