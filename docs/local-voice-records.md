# Local voice records additions

These are our local additions to the voice records status answer that [voice-relay.md](voice-relay.md) describes.
They live in the [local layer](local-layer.md): `bin/fm_local_voice_records.py`, `bin/fm-local-voice-fleet-states.sh` and `bin/fm-local-classify-lib.sh`, reached from `bin/fm_voice_records.py` and `bin/fm-classify-lib.sh` through small hooks.
`tests/fm-local-voice-records.test.sh` holds every behavior below.

## Live captain holds

What is waiting on the captain is counted twice in every status answer, spoken or not.
`awaiting_captain` is every captain hold, and `awaiting_captain_live` leaves out holds deferred to a future hold-until date, which matches what Captain's Call shows.

## Fleet counts

The `fm_voice_records.py status` command, which the Beacon status button runs, also returns `fleet_working` and `fleet_stuck` at every scope.
They are integers only, the one exception to voice-relay.md's rule that only open work and this home's own runtime records are ever assembled.
They count agents across this home and every registered local second mate home, the second mates themselves and this home's own firstmate session included, by their current state rather than their last event.
`fleet_working` counts each agent that `bin/fm-crew-state.sh` reads as working now, plus each session that is mid-turn, so a busy second mate counts whatever its status log last said.
`fleet_stuck` counts each agent that reads blocked or failed now; a declared pause, a decision waiting on the captain, and an idle session count toward neither.
A remote or unreadable second mate home is skipped, and the read takes no lock, writes nothing, wakes nobody and reaches no other host.
Every read runs at once under one four-second deadline, and an agent that has not answered by then counts toward neither.
When a live session the counts depend on cannot be read at all - `herdr` is not on the reader's `PATH`, or a `herdr` call fails - both are JSON `null` rather than 0, and `fleet_unknown_reason` carries a short reason; a consumer treats that as unknown, never idle.
The missing tool is detected before any `herdr` call, so that answer returns at once, and `herdr` is looked for only on the `PATH` the caller gives, so a caller under launchd's bare `PATH` must supply one that includes it.
`fleet_unknown_reason` is absent whenever both counts are numbers.
A long status log is read from the open-decisions cursor its home's own drain keeps, plus only the lines appended since, so its length does not set the cost.
That cursor read is the `FM_OPEN_DECISIONS_CURSOR_PEEK=1` opt-in in `bin/fm-local-classify-lib.sh`; it never writes the cursor and falls back to upstream's whole-log fold whenever the cursor cannot serve.
On the captain's Mac mini on 2026-10-14, with twelve agents across three homes, the whole read took 0.50 to 0.53 seconds.
The spoken answer leaves both counts out, because it is read on every question.

`bin/fm-local-voice-fleet-states.sh` answers one agent's current state or session busy verdict per call, read-only; its header owns the exact reads.
