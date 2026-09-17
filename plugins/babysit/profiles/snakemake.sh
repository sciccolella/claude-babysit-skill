#!/usr/bin/env bash
# Snakemake profile. See ../scripts/_profiles.sh for the profile contract
# (what each PROFILE_* variable means and how a profile gets selected).

PROFILE_NAME="snakemake"

# Fire only on lines Snakemake emits when a job actually fails, never on the
# bare words a normal run also prints (see watch_pipeline.sh's generic tier
# for why "error|failed|exception" alone is deliberately never used).
PROFILE_PATTERN_JOB_FAILURE='Error in rule '
PROFILE_PATTERN_DAG_ERROR='MissingInputException|WorkflowError'
PROFILE_FATAL_EXTRA="${PROFILE_PATTERN_JOB_FAILURE}|Exiting because a job execution failed|${PROFILE_PATTERN_DAG_ERROR}"

# Terminal-only lines (finishing the run) — the only signal available for an
# adopted/log-only run, which is what makes inferring an outcome from them
# defensible at all.
PROFILE_FAIL_TERMINAL='Exiting because a job execution failed|^WorkflowError|^MissingInputException'
PROFILE_SUCCESS_TERMINAL='[0-9]+ of [0-9]+ steps \(100%\) done|^Nothing to be done'

PROFILE_PROGRESS_REGEX='[0-9]+ of [0-9]+ steps? \([0-9.]+%\) done'
PROFILE_PROGRESS_LABEL='steps'

PROFILE_CLASSIFY_JOB_FAILURE='snakemake_job_failure'
PROFILE_CLASSIFY_DAG_ERROR='snakemake_dag_error'

# $1 = command line (may be empty), $2 = log path (may be empty).
profile_detect() {
    case "$1" in *snakemake*) return 0 ;; esac
    case "$2" in *.snakemake.log) return 0 ;; esac
    return 1
}
