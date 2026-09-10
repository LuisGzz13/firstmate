---
name: park
description: >-
  Check whether it is safe to consolidate this home right now, before pushing its records so another machine can continue the work.
  Use when the captain invokes /park, or asks whether he can store everything and push, whether it is safe to switch machines, or what is left before the work can be picked up elsewhere.
  It reports either that nothing is in the way, or one line per thing that is, each naming the action that clears it.
user-invocable: true
metadata:
  internal: true
---

# park

The captain works one project at a time on one machine, then consolidates so any machine can continue.
`/park` is the checkpoint he runs before consolidating.
It answers one question: is everything durable on this machine reachable from somewhere else afterwards?

It changes nothing.
No push, no commit, no cleanup, no record written, no network call.
That is deliberate: a preflight that changes state cannot be run freely, and being freely runnable is the whole point.

## Run it

```
bin/fm-park.sh
```

Add `--repo <path>`, repeatable, for a repository outside this home the captain also consolidates - his dotfiles, say.
Exit 0 means safe, 1 means blocked, 2 is a usage error.
`bin/fm-park.sh --help` owns the mechanics; that header is where the conditions, the traps, and the reasoning behind each boundary are written down.

## Report it

The script's own lines are already written for the captain, so relay them as they are rather than rewording them into internal vocabulary.
Lead with the verdict, then the blockers in the order printed.

When it is safe, say so in one line and stop.
Do not list what was checked; he asked whether he can consolidate, not for an audit.

When it is blocked, give him the count and the lines, then add what the script cannot know:

- Which blockers he can clear himself right now, and which need a worker.
- Whether any of them is work you should dispatch rather than hand him.
- If a blocker looks wrong to you, say why in one sentence rather than passing it on unexamined.

Never tell him it is safe when the check said otherwise, and never soften a blocker into a suggestion.
The reason this exists is that the previous by-hand check missed things that were then nearly lost.

## What it will and will not tell you

Two things it deliberately reports rather than resolves, so read them as prompts rather than verdicts.

A local copy holding review boards or screenshots is reported until those bytes are inside the home's `data/` folder.
Content that was folded into another file instead of copied still reports, because proving that would mean guessing.
The clearing action is the captain's call: copy it in, or delete it.

An open question with no held task is reported as something the other machine would not see.
That is a real gap and `captain-hold-lifecycle` owns closing it, but the question may already have been answered in a way that only you know about.
Check before you hand it over.

Two things it does not check at all.
Anything a secondmate holds is its own home's business and consolidates through its own run of this check.
And whether two records of an already-durable captain call agree is `bin/fm-captain-hold.sh diverged`'s question, not this one.

## After it is clear

`/park` is the check.
Pushing the consolidated home is a separate act with its own authority: it is outward-facing, and the captain approves it.
A rejected push means the other machine wrote, and must never be forced past.
