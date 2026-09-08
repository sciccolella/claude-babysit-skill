---
name: babysit-attach
description: "Adopt a pipeline that is ALREADY running — started by hand in another terminal/tmux pane, or by a Claude session that has since died or been /cleared — and put it under a detached watcher, same as babysit-run but without relaunching it. Use when the user says something is already running and asks you to watch it, keep an eye on it, or notify them when it finishes, or when you discover an orphaned long-running process you should not restart. Never use this to start a new pipeline — that's babysit-run. For a synchronous status check without waiting for the wake-up, use babysit-status."
---

# /babysit-attach [--pid PID] [--log FILE] [--auto]

Wraps `attach_pipeline.sh` + `watch_pipeline.sh` + `pipeline_report.sh` (`${CLAUDE_PLUGIN_ROOT}/scripts/`). Puts an
**already-running** pipeline under the same watch/report/notify contract as `babysit-run`,
without relaunching it.

**Fidelity is lower than `babysit-run`, on purpose — say so.** The exit status of a process is
only delivered to its parent; a process this session did not spawn can never yield a real exit
code (no `waitid` on a pidfd we don't own). `PTRACE_ATTACH` could technically intercept
`exit_group`, but is deliberately not used: it stops the tracee and risks perturbing or killing
a run that may be hours into scientific work, for a number the log already implies. So adopted
outcomes are **inferred** from snakemake's own terminal summary lines (`N of N steps (100%)
done` vs `Exiting because a job execution failed`) and reported as `SUCCESS_INFERRED` /
`FAILED_INFERRED` / `ENDED_UNKNOWN` — never bare `SUCCESS`/`FAILED`. Say "inferred from the log,
not a confirmed exit code" when reporting these to the user; do not round that up to certainty.

## Attach (first invocation)

1. Pick a mode (all invoked as `"${CLAUDE_PLUGIN_ROOT}/scripts/attach_pipeline.sh" ...`):
   - `--auto` — tries to find a running `snakemake` process
     (`pgrep -f snakemake`, excluding this tooling's own processes) and
     `.snakemake/log/*.snakemake.log` on its own. Snakemake writes that log regardless of where
     the user redirected stdout, which is what makes a bare `snakemake` with no redirect
     adoptable at all. If several candidate processes exist, it lists them and asks you to
     rerun with `--pid`.
   - `--pid PID [--log FILE]` — explicit PID, given by the user or found via
     `pgrep -af <name>`. Without `--log`, only process liveness is tracked (no fatal-marker
     scan, no terminal-line inference) — weaker, but still gives you death detection and a
     push when the process ends.
   - `--log FILE` — no process at all (e.g. you only have a log path, or the
     process is on a remote host you can `tail` but not `kill -0`). Weakest mode: only
     terminal-line inference and log-growth stall detection, no death detection.
   - Pass `--rundir DIR` to keep multiple attaches distinct; default is `.pipeline-attach/`.
2. Start the watcher exactly as in `babysit-run`, via `Bash` with **`run_in_background:
   true`**: `"${CLAUDE_PLUGIN_ROOT}/scripts/watch_pipeline.sh" --rundir <same dir>`
   (`--stall-timeout SEC`, default 7200s).
   The watcher auto-detects the adopted rundir and switches scan/classify behavior — no extra
   flag needed unless you want `--scan-from start` to rescan the log's full history (off by
   default for attach: a stale `Error in rule` from a retry snakemake already recovered from
   should not fire a false alarm).
3. Report what was attached (PID and/or log path, and which mode — full/pid/log) and that the
   watcher is parked, then **end the turn**.

Do not poll. Do not use `/loop` or `ScheduleWakeup`. Same reasoning as `babysit-run`: the
harness re-invokes this session automatically when the backgrounded watcher exits.

**Retry budget carries over from adoption.** `attach_pipeline.sh` seeds `attempts=1` since an
adopted run has no launch history of its own — a later auto-fix relaunch is attempt 2, not
attempt 1, so the same `attempt >= 2 → always escalate` rule in `babysit-run` still holds.

## On re-invocation (watcher exited)

Read `<rundir>/pipeline_status.json` and `<rundir>/report.md` first; check `adopted: true` /
the report's adopted-run note before drawing conclusions from `status`.

- **`SUCCESS_INFERRED`** — summarize, note it's inferred from the log's terminal line rather
  than a real exit code, `PushNotification`.
- **`FAILED_INFERRED`** — same caveat, diagnose from the report's failing-rule section if
  present, then follow `babysit-run`'s FAILED branch (confident mechanical fix vs. escalate).
  A relaunch here uses `run_pipeline.sh`, same as any other fix — from this point on the run is
  fully owned, no longer merely adopted.
- **`ENDED_UNKNOWN`** — the process ended (or, in `--log`-only mode, the log stopped changing
  and nothing else fired) but the log gave no terminal line to classify by. Do not guess.
  `PushNotification` with what's known (last log lines, duration) and ask.
- **`DIED_UNCLEAN`** / **`NOTSTARTED`** / **`STALLED`** / **`FATAL_DETECTED`** — same meaning
  and same handling as in `babysit-run`.
- **In doubt, same rule as `babysit-run`:** any fix that edits the Snakefile/config/params, any
  resource bump, any `oom_suspected` classification — always escalate via `needs_human.md` +
  `PushNotification`, regardless of confidence.

The user's only expected involvement is the push notification when something actionable
happens.
