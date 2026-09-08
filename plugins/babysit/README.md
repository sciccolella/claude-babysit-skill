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

## Workflow-agnostic vs. Snakemake-specific

**Launch, watch, and notify are workflow-agnostic** — `run_pipeline.sh` / `watch_pipeline.sh` /
`pipeline_report.sh` work for any long-running command, not just Snakemake. What *is*
Snakemake-specific:

- `attach_pipeline.sh --auto` discovery looks for a `snakemake` process and
  `.snakemake/log/*.snakemake.log`.
- Outcome inference for **adopted** runs (see below) reads Snakemake's own terminal summary
  lines (`N of N steps (100%) done` vs. `Exiting because a job execution failed`).
- A few failure-classification patterns in `pipeline_report.sh` (`snakemake_job_failure`,
  `snakemake_dag_error`) are Snakemake log grammar.

On another workflow engine (Nextflow, a bare script, a training loop) you still get the full
launch/watch/notify contract and death/stall detection — just coarser failure classification,
and `--auto` attach discovery won't find your process (use `--pid` or `--log` instead).

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
