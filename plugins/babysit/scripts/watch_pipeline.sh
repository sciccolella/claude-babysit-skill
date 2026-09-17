#!/usr/bin/env bash
# Poll a pipeline and exit at the earliest actionable moment: success, failure,
# unclean death, an early fatal marker, a stall, or a launch that never started.
#
# Works on rundirs created by run_pipeline.sh (full fidelity: a true exit code is
# recorded) and by attach_pipeline.sh (adopted: no exit code is obtainable, so
# outcomes are inferred from the log and reported as *_INFERRED).
#
# Usage: watch_pipeline.sh [--rundir DIR] [--interval SEC] [--stall-timeout SEC]
#                          [--scan-from start|eof]
#
# Exit codes / STATUS line (printed to stdout as the last line):
#   SUCCESS          0   pipeline.exit == 0
#   SUCCESS_INFERRED 0   adopted; log shows the matched profile's success terminal line
#   FAILED           1   pipeline.exit != 0
#   FAILED_INFERRED  1   adopted; log shows the matched profile's failure terminal line
#   FATAL_DETECTED   1   a narrow fatal marker (generic, or from the matched profile) matched
#   STALLED          2   log size unchanged for --stall-timeout seconds (advisory only)
#   NOTSTARTED       3   process was never observed alive (empty/bad RUNDIR)
#   DIED_UNCLEAN     4   process was alive, then vanished, with no exit file
#   ENDED_UNKNOWN    5   adopted; process ended with no terminal line either way (including:
#                        no profile matched, so no terminal-line pattern existed to check)
#
# Outcome inference for adopted/log-only runs (SUCCESS_INFERRED/FAILED_INFERRED/
# ENDED_UNKNOWN) is driven by a profile — see ../profiles/README.md — selected
# at launch/attach time and recorded in RUNDIR/profile. No profile matched is a
# supported, reported state (profile: null in pipeline_status.json), not an
# error; it only means outcome inference for that run has no terminal-line
# signal to go on, same as it always did before profiles existed.
set -u

RUNDIR=".pipeline-run"
INTERVAL=30
STALL_TIMEOUT=7200
SCAN_FROM=""

while [ $# -gt 0 ]; do
    case "$1" in
        --rundir) RUNDIR="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --stall-timeout) STALL_TIMEOUT="$2"; shift 2 ;;
        --scan-from) SCAN_FROM="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTER="$SCRIPT_DIR/pipeline_report.sh"
source "$SCRIPT_DIR/_profiles.sh"

# Lets pipeline_peek.sh tell "still running, being watched" apart from "still
# running, nothing will ever notify anyone" (watcher crashed / session died
# without re-arming it).
mkdir -p "$RUNDIR"
printf '%s' "$$" > "$RUNDIR/watcher.pid"

LOG="$RUNDIR/pipeline.log"
EXIT_FILE="$RUNDIR/pipeline.exit"
PID_FILE="$RUNDIR/pipeline.pid"
PIDSTART_FILE="$RUNDIR/pipeline.pidstart"
CMD_FILE="$RUNDIR/pipeline.cmd"
ADOPTED_FILE="$RUNDIR/adopted"

# launched | pid | log
MODE="launched"
[ -f "$ADOPTED_FILE" ] && MODE="$(cat "$ADOPTED_FILE" 2>/dev/null || echo pid)"

# Adopted rundirs default to scanning only new output: the log may already be
# gigabytes, and a historical "Error in rule" from a retry snakemake has since
# recovered from is stale news, not an event to wake anyone for.
if [ -z "$SCAN_FROM" ]; then
    case "$MODE" in
        launched) SCAN_FROM="start" ;;
        *)        SCAN_FROM="eof" ;;
    esac
fi

# Fatal markers deliberately narrow — never bare error|failed|exception|traceback.
# Common bioinformatics tools (e.g. hifiasm, snakemake) print those bare words in
# normal, non-fatal output, so a generic match would false-positive constantly.
# This generic tier applies to every pipeline regardless of profile.
FATAL_PATTERN='No space left on device|Out of memory|oom-kill|^Killed$'

PROFILE_FILE="$RUNDIR/profile"
profile_name=""
[ -f "$PROFILE_FILE" ] && profile_name="$(cat "$PROFILE_FILE" 2>/dev/null || echo '')"
load_profile "$profile_name"

# A matched profile adds its own fatal markers and terminal-line patterns (the
# latter used only for outcome inference on adopted/log-only runs, where a
# terminal summary line is the only signal available at all). No profile
# matched is a supported state, not an error: FAIL_TERMINAL/SUCCESS_TERMINAL
# then stay empty and log_matches() below treats an empty pattern as "never
# matches" rather than "matches everything".
[ -n "$PROFILE_FATAL_EXTRA" ] && FATAL_PATTERN="$PROFILE_FATAL_EXTRA|$FATAL_PATTERN"
FAIL_TERMINAL="$PROFILE_FAIL_TERMINAL"
SUCCESS_TERMINAL="$PROFILE_SUCCESS_TERMINAL"

keep_going=0
if [ -f "$CMD_FILE" ] && grep -qE -- '(^| )(--keep-going|-k)( |$)' "$CMD_FILE"; then
    keep_going=1
fi

expected_start=""
[ -f "$PIDSTART_FILE" ] && expected_start="$(cat "$PIDSTART_FILE" 2>/dev/null || echo '')"

proc_starttime() {
    local raw rest
    raw="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${raw##*) }"
    printf '%s' "$rest" | awk '{print $20}'
}

# kill -0 alone is not enough: on a 64-core box a recycled PID would keep the
# watcher waiting forever on a pipeline that already died. When a starttime was
# recorded, (pid, starttime) identifies the process instance uniquely.
alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -n "$expected_start" ]; then
        [ "$(proc_starttime "$pid")" = "$expected_start" ] || return 1
    fi
    return 0
}

log_matches() {
    [ -n "$1" ] || return 1
    [ -f "$LOG" ] || return 1
    grep -qE "$1" "$LOG" 2>/dev/null
}

# Classify an adopted run that has ended, from snakemake's terminal lines only.
classify_adopted_end() {
    if log_matches "$FAIL_TERMINAL"; then
        finish FAILED_INFERRED 1
    elif log_matches "$SUCCESS_TERMINAL"; then
        finish SUCCESS_INFERRED 0
    else
        finish ENDED_UNKNOWN 5
    fi
}

finish() {
    status="$1"
    exit_code="$2"
    "$REPORTER" "$RUNDIR" "$status" >/dev/null 2>&1 || true
    echo "STATUS=$status"
    exit "$exit_code"
}

# On our own termination (TaskStop, session end), never touch the pipeline.
on_term() {
    echo "STATUS=WATCHER_STOPPED"
    exit 130
}
trap on_term TERM INT

# For a launched run the log is truncated fresh at launch, and content written
# between launch and the first poll (a fast-failing command can emit a fatal
# marker within milliseconds) must not be skipped — so start at 0. For an adopted
# run, start at current EOF.
offset=0
if [ "$SCAN_FROM" = "eof" ] && [ -f "$LOG" ]; then
    offset=$(wc -c < "$LOG" 2>/dev/null || echo 0)
fi

last_size=0
[ -f "$LOG" ] && last_size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
last_growth_ts=$(date +%s)

while true; do
    if [ -f "$EXIT_FILE" ]; then
        rc="$(cat "$EXIT_FILE" 2>/dev/null || echo '')"
        case "$rc" in
            0) finish SUCCESS 0 ;;
            ''|*[!0-9]*) : ;;  # exit file mid-write somehow; treat as not-yet-final, retry
            *) finish FAILED 1 ;;
        esac
    fi

    if [ "$MODE" = "log" ]; then
        # No process to watch: the only terminal evidence is the log itself.
        if log_matches "$FAIL_TERMINAL"; then
            finish FAILED_INFERRED 1
        elif log_matches "$SUCCESS_TERMINAL"; then
            finish SUCCESS_INFERRED 0
        fi
    else
        pid=""
        [ -f "$PID_FILE" ] && pid="$(cat "$PID_FILE" 2>/dev/null || echo '')"

        # No pid file (or empty) means run_pipeline.sh never got as far as
        # backgrounding anything — a launch failure, not a death in flight.
        if [ -z "$pid" ]; then
            finish NOTSTARTED 3
        fi

        if ! alive "$pid"; then
            if [ "$MODE" = "launched" ]; then
                [ -f "$EXIT_FILE" ] || finish DIED_UNCLEAN 4
            else
                classify_adopted_end
            fi
        fi
    fi

    if [ -f "$LOG" ]; then
        size=$(wc -c < "$LOG" 2>/dev/null || echo 0)

        if [ "$keep_going" -eq 0 ] && [ "$size" -gt "$offset" ]; then
            chunk="$(tail -c +"$((offset + 1))" "$LOG" 2>/dev/null)"
            if printf '%s\n' "$chunk" | grep -qE "$FATAL_PATTERN"; then
                finish FATAL_DETECTED 1
            fi
        fi
        offset="$size"

        if [ "$size" -gt "$last_size" ]; then
            last_size="$size"
            last_growth_ts=$(date +%s)
        elif [ "$STALL_TIMEOUT" -gt 0 ]; then
            now=$(date +%s)
            if [ $((now - last_growth_ts)) -ge "$STALL_TIMEOUT" ]; then
                finish STALLED 2
            fi
        fi
    fi

    sleep "$INTERVAL"
done
