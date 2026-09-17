---
name: babysit-run
description: "Launch a long-running pipeline (hours to days) under a detached watcher and end the turn. The watcher costs zero tokens while polling; the agent is woken exactly once, on the first actionable event (success, failure, unclean death, stall, or launch failure), and reads a small pre-digested report instead of a multi-GB log. Self-trigger this as your closing action after writing and validating a pipeline that needs to run unattended — do not hand a command string back to the user and ask them to babysit it manually. To adopt a pipeline that is ALREADY running (started by hand or by a dead session) rather than starting one, use babysit-attach instead. For a synchronous status check without waiting for the wake-up, use babysit-status."
---

# /babysit-run <command>

Wraps `run_pipeline.sh` + `watch_pipeline.sh` + `pipeline_report.sh` (`${CLAUDE_PLUGIN_ROOT}/scripts/`). Replaces
ad-hoc "run this and let me know" prompting with a versioned contract.

**Starting a pipeline is this skill. Adopting one that is already running is
`babysit-attach`** — use that when the process already exists (launched by hand in another
tmux pane, or by a session that has since died). Do not relaunch a running pipeline to get it
under a watcher; attach to it.

**This skill is meant to be self-invoked.** If you just wrote and validated a pipeline that
will run for a long time, call
`Skill(babysit-run, args="<the exact command you just validated>")` yourself as your closing
action — venv path, core count, config flags and all. The user should never need to hand you a
command string or ask you to do this; treat it as standard closing behavior for any pipeline
you author that isn't a quick foreground run.

## Launch (first invocation)

1. `"${CLAUDE_PLUGIN_ROOT}/scripts/run_pipeline.sh" -- <command>` — returns instantly, prints
   the launched PID and rundir. Default `RUNDIR` is `.pipeline-run/` in the current directory;
   pass `--rundir DIR` to both this and the watcher if you need a non-default location (e.g.
   running several pipelines from the same directory).
2. Start the watcher via the `Bash` tool with **`run_in_background: true`**:
   `"${CLAUDE_PLUGIN_ROOT}/scripts/watch_pipeline.sh" --rundir <same dir>` (add
   `--stall-timeout SEC`, `0` to disable, default
   7200s).
3. Report that the pipeline is launched and the watcher is parked, then **end the turn**.

Do not poll, do not use `/loop`, do not use `ScheduleWakeup` to check on it. The harness
re-invokes this session automatically when the backgrounded watcher process exits — an interval
wakeup only burns tokens for no benefit, since polling itself is free and only the wake-up costs
anything.

**Cost note:** the session that backgrounds the watcher is the one resumed when it exits, hours
or days later, with its accumulated context resent uncached exactly once. That's a bounded,
one-time cost proportional to how much the authoring session did before this call — not a
repeated-resume pattern. It doesn't justify a mandatory fresh-session step. If a particular
session ran unusually long before reaching this point and you want to trim the resend, `/clear`
immediately before calling this skill is an optional escape hatch, never the default.

## On re-invocation (watcher exited)

Read **only** `<rundir>/pipeline_status.json` and `<rundir>/report.md` — not the raw
`pipeline.log`, unless diagnosis genuinely requires a specific span the report didn't capture.

- **`SUCCESS`** — summarize and `PushNotification`.
- **`NOTSTARTED`** — launch problem (bad command, missing rundir). Report immediately, do not
  retry automatically.
- **`STALLED`** — always `PushNotification` and stop. Never auto-act: log-size stall detection
  is heuristic and can false-positive on a genuinely quiet long step. The pipeline is still
  running, untouched — say so.
- **`FAILED` / `DIED_UNCLEAN` / `FATAL_DETECTED`** — diagnose from the report, then:
  - **Confident, mechanical, no semantic change to the workflow itself** — apply, relaunch
    (`run_pipeline.sh` again, same rundir), re-arm the watcher, and `PushNotification` stating
    exactly what was changed. An auto-fix is never silent. Examples: stale `.snakemake` lock →
    `--unlock`; incomplete output metadata → `--rerun-incomplete`; disk was full and is now
    confirmed clear; a transient network fetch failure.
  - **In doubt** — write `<rundir>/needs_human.md` with the question and context, then
    `PushNotification` the question. It should be answerable from a phone via Remote Control.
  - **Always treat as in doubt, regardless of apparent confidence:** any edit to the pipeline's
    own script/config/parameters (a Snakefile, a shell script's flags, a YAML config, ...); any
    tool-version change; any deletion of existing outputs; any resource bump; every
    `oom_suspected` classification (the fix is inherently a resource or parameter decision, and —
    per the report — the diagnosis itself is not certain: exit 137 with no exit file is
    indistinguishable from a manual `kill -9`).
- **Retry budget** — `pipeline_status.json.attempt >= 2` means this would be attempt 3.
  Always escalate to `needs_human.md` + notification at that point, whatever the confidence in
  the fix.

The user's only expected involvement is the push notification when something actionable
happens — they should never need to hand back a command or manually check progress.

If a wake-up is ever missed (e.g. this session gets `/clear`'d before the watcher exits), a
`SessionStart` hook auto-surfaces any pipeline registered under the new session's cwd, so a
fresh session in the same directory picks it back up without the user having to ask.
