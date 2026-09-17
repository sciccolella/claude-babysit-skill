#!/usr/bin/env bash
# Launch an arbitrary command under a detached process group, recording its
# true exit code for watch_pipeline.sh to poll.
#
# Usage: run_pipeline.sh [--rundir DIR] -- CMD [ARGS...]
set -u

RUNDIR=".pipeline-run"

while [ $# -gt 0 ]; do
    case "$1" in
        --rundir)
            RUNDIR="$2"; shift 2 ;;
        --)
            shift; break ;;
        *)
            break ;;
    esac
done

if [ $# -eq 0 ]; then
    echo "usage: run_pipeline.sh [--rundir DIR] -- CMD [ARGS...]" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/_pipeline_runner.sh"
source "$SCRIPT_DIR/_profiles.sh"

mkdir -p "$RUNDIR"

# Registry lets babysit-status find this rundir from any cwd later.
REGISTRY="$HOME/.claude/babysit_rundirs.list"
RUNDIR_ABS="$(cd "$RUNDIR" && pwd)"
mkdir -p "$(dirname "$REGISTRY")"
touch "$REGISTRY"
grep -qxF "$RUNDIR_ABS" "$REGISTRY" 2>/dev/null || echo "$RUNDIR_ABS" >> "$REGISTRY"

# Stale state from a prior attempt must never be misread as this run's result.
rm -f "$RUNDIR/pipeline.exit" "$RUNDIR/report.md" "$RUNDIR/needs_human.md"
: > "$RUNDIR/pipeline.log"

attempts_file="$RUNDIR/attempts"
prev_attempts=0
[ -f "$attempts_file" ] && prev_attempts="$(cat "$attempts_file" 2>/dev/null || echo 0)"
case "$prev_attempts" in ''|*[!0-9]*) prev_attempts=0 ;; esac
printf '%s' "$((prev_attempts + 1))" > "$attempts_file"

printf '%s\n' "$*" > "$RUNDIR/pipeline.cmd"
date -u +%Y-%m-%dT%H:%M:%SZ > "$RUNDIR/started_at"
printf '%s' "$(detect_profile "$*" "")" > "$RUNDIR/profile"

setsid "$RUNNER" "$RUNDIR" "$@" </dev/null >>"$RUNDIR/pipeline.log" 2>&1 &
pgid=$!
disown "$pgid" 2>/dev/null

printf '%s' "$pgid" > "$RUNDIR/pipeline.pid"

echo "launched pid=$pgid rundir=$RUNDIR attempt=$((prev_attempts + 1))"
