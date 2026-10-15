"""fm_local_voice_records.py - our local additions to the voice records status answer.

This module is part of the local layer (docs/local-layer.md): upstream Firstmate
does not have it, and bin/fm_voice_records.py reaches it only through a guarded
import and two calls, so the upstream file stays mergeable and works unchanged
when this file is absent. docs/local-voice-records.md is the operator view of
what it adds.

LIVE CAPTAIN HOLDS. with_live_captain_holds adds awaiting_captain_live to every
status answer, spoken or not: the captain holds that are not deferred to a
future hold-until date, which is what Captain's Call shows.

FLEET COUNTS. with_fleet_counts adds fleet_working and fleet_stuck to the
`status` command, which the Beacon status button runs: how many agents across
this home and every registered local second mate home are working now, and how
many are blocked or failed now. They read CURRENT state, not the last event:
each task through bin/fm-crew-state.sh, a second mate's session and this home's
primary session through their busy verdicts, so a mid-turn session counts as
working whatever its log last said, and a declared pause, a decision waiting or
an idle session counts as neither. bin/fm-local-voice-fleet-states.sh owns each
read; fleet_activity below runs them together under one deadline. When a live
session they depend on cannot be read at all - herdr not on this process's
PATH, or a herdr call failing - both are null and fleet_unknown_reason says
why, because a zero there would read as idle. The spoken answer leaves them
out, because it is read on every question and the current-state read is the
slow one.

The two counts are integers and carry nothing written in any record, so they
are the one exception to bin/fm_voice_records.py's rule that only open task
lines and this home's own runtime records are ever assembled.
"""

import datetime
import os
import signal
import subprocess
import time

# The fleet counts. Current states are bin/fm-crew-state.sh's words, and a
# session is busy on bin/fm-busy-lib.sh's word: a declared pause, a captain
# hold, a decision waiting (parked) and an idle session are none of these.
# One deadline covers every read in the fleet together, inside the Beacon's
# own five-second reader timeout.
FLEET_WORKING_STATE = "working"
FLEET_STUCK_STATES = ("blocked", "failed")
FLEET_BUSY_SESSION = "busy"
FLEET_BUDGET_SECONDS = 4.0
# A read that could not see a live session at all, and why. Any one of them
# makes both counts unknown: the rest of the fleet cannot vouch for the agent
# that went unseen.
FLEET_UNREADABLE = {
    "no-herdr": "herdr is not on PATH, so live sessions cannot be read",
    "unreadable": "a herdr read failed, so live sessions cannot be read",
}


def with_live_captain_holds(answer, held_for_captain):
    """Return <answer> with awaiting_captain_live right after awaiting_captain.

    The live subset is what Captain's Call shows: a hold deferred to a future
    hold-until date is not yet the captain's to answer. Same rule as the fleet
    snapshot's "dated" bucket in bin/fm-fleet-snapshot.sh, which follows
    tasks-axi's contract that a hold is inactive on and after that UTC date.
    """
    today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
    live = len([
        i for i in held_for_captain
        if i["tags"].get("hold-until", "").strip() <= today
    ])
    out = {}
    for key, value in answer.items():
        out[key] = value
        if key == "awaiting_captain":
            out["awaiting_captain_live"] = live
    out.setdefault("awaiting_captain_live", live)
    return out


def with_fleet_counts(answer, home, state_dir):
    """Return <answer> with the fleet counts of fleet_activity added.

    <state_dir> is bin/fm_voice_records.py's resolver, so this home's state
    directory honours FM_STATE_OVERRIDE exactly as the rest of the answer does.
    """
    out = dict(answer)
    out.update(fleet_activity(home, state_dir))
    return out


def _home_jobs(helper, home, state, env):
    """Yield one agent read per task recorded in <state>."""
    try:
        names = sorted(n for n in os.listdir(state) if n.endswith(".meta"))
    except OSError:
        return
    for name in names:
        yield [helper, "agent", home, name[: -len(".meta")]], env


def _fleet_jobs(home, helper, state_dir):
    """Yield the (argv, env) reads that together cover the whole local fleet.

    This home's primary session, every task recorded here (its second mates
    included), and every task recorded in each local second mate's own home.
    This home's reads come first, so they are already running while the second
    mate homes are listed. A second mate home is read with its own state
    directory, so an override meant for this home never redirects the read of
    another.
    """
    ambient = dict(os.environ)
    elsewhere = {k: v for k, v in ambient.items()
                 if k not in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE")}
    yield [helper, "primary", home], ambient
    for job in _home_jobs(helper, home, state_dir(home), ambient):
        yield job
    try:
        listed = subprocess.run(
            [helper, "homes", home], stdin=subprocess.DEVNULL, env=ambient,
            capture_output=True, text=True, timeout=FLEET_BUDGET_SECONDS,
            check=False).stdout.splitlines()
    except (OSError, subprocess.SubprocessError):
        listed = []
    seen = {os.path.realpath(home)}
    for other in listed:
        other = other.strip()
        if not other or os.path.realpath(other) in seen:
            continue
        seen.add(os.path.realpath(other))
        for job in _home_jobs(helper, other, os.path.join(other, "state"), elsewhere):
            yield job


def fleet_activity(home, state_dir, root=None):
    """Return fleet_working and fleet_stuck across every local home.

    Every read runs at once and the whole set shares one deadline, because the
    caller is a button press: a read that has not answered by then counts
    toward neither figure rather than holding the answer back. A read that
    reports its live session unreadable (FLEET_UNREADABLE) makes both figures
    None, with fleet_unknown_reason, and stops the reads still running.
    Nothing here takes a lock, writes a record, wakes firstmate or reaches the
    network; see bin/fm-local-voice-fleet-states.sh, which owns what each read
    asks.
    """
    root = root or os.path.dirname(os.path.abspath(__file__))
    helper = os.path.join(root, "fm-local-voice-fleet-states.sh")
    working = stuck = 0
    if not os.access(helper, os.X_OK):
        return {"fleet_working": working, "fleet_stuck": stuck}
    running = []
    for argv, env in _fleet_jobs(home, helper, state_dir):
        try:
            # Its own process group, so a read past the deadline is stopped
            # whole rather than leaving its current-state read running on.
            running.append(subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, env=env, text=True,
                start_new_session=True))
        except OSError:
            continue
    deadline = time.monotonic() + FLEET_BUDGET_SECONDS
    reason = None
    for proc in running:
        try:
            if reason is not None:
                raise subprocess.TimeoutExpired(proc.args, 0)
            out, _ = proc.communicate(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                proc.kill()
            proc.communicate()
            continue
        words = (out or "").split()
        state = words[0] if words else "unknown"
        session = words[1] if len(words) > 1 else "-"
        unseen = FLEET_UNREADABLE.get(state) or FLEET_UNREADABLE.get(session)
        if unseen:
            reason = unseen
            continue
        if state == FLEET_WORKING_STATE or session == FLEET_BUSY_SESSION:
            working += 1
        if state in FLEET_STUCK_STATES:
            stuck += 1
    if reason is not None:
        return {"fleet_working": None, "fleet_stuck": None,
                "fleet_unknown_reason": reason}
    return {"fleet_working": working, "fleet_stuck": stuck}
