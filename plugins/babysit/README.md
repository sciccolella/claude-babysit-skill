# babysit (plugin detail)

## Scripts

| Script | Role |
|---|---|
| `scripts/run_pipeline.sh` | Launches a command under `setsid`, records its true exit code. |
| `scripts/_pipeline_runner.sh` | Internal exec wrapper used by `run_pipeline.sh`. |
| `scripts/watch_pipeline.sh` | Zero-token poller; classifies the outcome and calls the reporter when the pipeline ends or stalls. |
| `scripts/pipeline_report.sh` | Writes `pipeline_status.json` + `report.md` for a finished/stalled run. |
| `scripts/attach_pipeline.sh` | Adopts an already-running process and/or log file. |
| `scripts/pipeline_peek.sh` | Synchronous status across every registered rundir. |

All six are relocatable — they resolve their siblings via `BASH_SOURCE`, not a hardcoded
install path, and track liveness through pidfiles in the rundir, never through the script's own
path. The only absolute path used anywhere is `$HOME/.claude/babysit_rundirs.list` — a shared
registry so `babysit-status` can find every pipeline from any directory, on any session.

## Workflow-agnostic core vs. pluggable profiles

**Launch, watch, and notify are fully workflow-agnostic** — `run_pipeline.sh` /
`watch_pipeline.sh` / `pipeline_report.sh` work for any long-running command, and the real
exit-code path, disk-full/OOM/`Killed` fatal markers, and byte-growth stall detection never
depend on which tool is running.

Tool-specific behavior — outcome inference for **adopted/log-only** runs (no exit code exists
there), progress-line parsing, and failure-classification naming — comes from a **profile**,
picked automatically at launch/attach time from the command line and log shape, and recorded in
`RUNDIR/profile`. See `profiles/README.md` for the profile contract and `profiles/snakemake.sh`
for the only profile shipped today.

"No profile matched" is a supported, visible state, not silent degradation: `profile: null` in
`pipeline_status.json`, and `report.md`/`pipeline_peek.sh` say so explicitly. On another workflow
engine (Nextflow, a bare script, a training loop) with no matching profile, you still get the
full launch/watch/notify contract and death/stall detection — just generic failure
classification and no progress line, until a profile is added for it (drop a new file in
`profiles/`, no code changes elsewhere needed).

`attach_pipeline.sh --auto` process discovery is separate from profiles and still
Snakemake-only (`pgrep -f snakemake`) — see `TODO.md`. `--pid`/`--log` already cover adopting
any other tool explicitly.

## Status vocabulary

- **`SUCCESS` / `FAILED` / `DIED_UNCLEAN` / `FATAL_DETECTED` / `NOTSTARTED` / `STALLED`** —
  from `babysit-run`, backed by a real exit code this session's own child process produced.
- **`SUCCESS_INFERRED` / `FAILED_INFERRED` / `ENDED_UNKNOWN`** — from `babysit-attach` only.
  A process this session did not spawn can never yield a real exit code (no `waitid` on a pidfd
  it doesn't own), and `PTRACE_ATTACH` is deliberately not used — it stops the tracee and risks
  perturbing or killing a run that may be hours into real work, just to obtain a number the log
  already implies. So adopted outcomes are **inferred** from the log's own terminal lines and
  are never reported as bare `SUCCESS`/`FAILED`. This is the toolkit's central honesty
  guarantee: always say "inferred from the log, not a confirmed exit code" when relaying these.

## Escalation contract

On a `FAILED` / `DIED_UNCLEAN` / `FATAL_DETECTED` re-invocation:

- **Confident, mechanical, no semantic change to the workflow** (stale lock file, incomplete
  output metadata, confirmed-cleared disk, a transient network fetch) → auto-fix, relaunch,
  re-arm the watcher, and notify stating exactly what changed. Never silent.
- **Anything else** — including *any* edit to workflow/config/params, a tool-version change, a
  resource bump, or an `oom_suspected` classification — always escalates: write
  `needs_human.md` with the question, then notify. `oom_suspected` is always in-doubt because
  the underlying signal (`exit 137` with no exit file) is indistinguishable from a manual
  `kill -9`.
- **Retry budget**: `pipeline_status.json.attempt >= 2` (i.e. this would be attempt 3) always
  escalates, regardless of confidence.

See the three `skills/*/SKILL.md` files for the exact per-skill behavior.
