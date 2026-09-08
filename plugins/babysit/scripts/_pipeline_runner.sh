#!/usr/bin/env bash
# Internal helper for run_pipeline.sh. Not meant to be invoked directly.
# Usage: _pipeline_runner.sh RUNDIR CMD...
set -u

RUNDIR="$1"; shift

{
    "$@"
} >>"$RUNDIR/pipeline.log" 2>&1
rc=$?

printf '%s' "$rc" > "$RUNDIR/pipeline.exit.tmp"
mv "$RUNDIR/pipeline.exit.tmp" "$RUNDIR/pipeline.exit"

exit "$rc"
