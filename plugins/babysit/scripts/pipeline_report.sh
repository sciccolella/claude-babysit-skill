#!/usr/bin/env bash
# Digest a finished/stalled pipeline run into pipeline_status.json (~200B,
# machine-readable) and report.md (~2KB, human-readable) so the babysitting
# agent never has to read the raw (possibly multi-GB) log.
#
# Usage: pipeline_report.sh RUNDIR STATUS
set -u

RUNDIR="${1:?usage: pipeline_report.sh RUNDIR STATUS}"
STATUS="${2:?usage: pipeline_report.sh RUNDIR STATUS}"

LOG="$RUNDIR/pipeline.log"
EXIT_FILE="$RUNDIR/pipeline.exit"
CMD_FILE="$RUNDIR/pipeline.cmd"
STARTED_FILE="$RUNDIR/started_at"
ATTEMPTS_FILE="$RUNDIR/attempts"

exit_code=""
[ -f "$EXIT_FILE" ] && exit_code="$(cat "$EXIT_FILE" 2>/dev/null || echo '')"

signal=""
case "$exit_code" in
    137) signal="SIGKILL" ;;
    143) signal="SIGTERM" ;;
    130) signal="SIGINT" ;;
esac

has_oom_marker=0
if [ -f "$LOG" ] && grep -qE 'Killed|oom-kill|Out of memory' "$LOG" 2>/dev/null; then
    has_oom_marker=1
fi

is_adopted=0
[ -f "$RUNDIR/adopted" ] && is_adopted=1

classification="unknown"
case "$STATUS" in
    SUCCESS) classification="success" ;;
    SUCCESS_INFERRED) classification="success_inferred" ;;
    FAILED_INFERRED) classification="failure_inferred" ;;
    ENDED_UNKNOWN) classification="ended_unknown" ;;
    DIED_UNCLEAN) classification="oom_suspected" ;;
    STALLED) classification="stalled" ;;
    NOTSTARTED) classification="launch_failure" ;;
    FAILED|FATAL_DETECTED)
        if [ "$exit_code" = "137" ] || { [ "$signal" = "SIGKILL" ] && [ "$has_oom_marker" -eq 1 ]; }; then
            classification="oom_suspected"
        elif [ "$exit_code" = "143" ]; then
            classification="sigterm"
        elif [ "$exit_code" = "130" ]; then
            classification="sigint"
        elif [ -f "$LOG" ] && grep -qE 'Error in rule ' "$LOG" 2>/dev/null; then
            classification="snakemake_job_failure"
        elif [ -f "$LOG" ] && grep -qE 'MissingInputException|WorkflowError' "$LOG" 2>/dev/null; then
            classification="snakemake_dag_error"
        else
            classification="generic_failure"
        fi
        ;;
esac
# exit 137 without a SIGKILL-derived signal string still means SIGKILL.
if [ "$exit_code" = "137" ] && [ -z "$signal" ]; then
    signal="SIGKILL"
fi

started_at=""
[ -f "$STARTED_FILE" ] && started_at="$(cat "$STARTED_FILE" 2>/dev/null || echo '')"
ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

duration_s=""
if [ -n "$started_at" ]; then
    s_epoch=$(date -u -d "$started_at" +%s 2>/dev/null || echo '')
    e_epoch=$(date -u -d "$ended_at" +%s 2>/dev/null || echo '')
    if [ -n "$s_epoch" ] && [ -n "$e_epoch" ]; then
        duration_s=$((e_epoch - s_epoch))
    fi
fi

attempt=1
if [ -f "$ATTEMPTS_FILE" ]; then
    a="$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo '')"
    case "$a" in ''|*[!0-9]*) : ;; *) attempt="$a" ;; esac
fi

# Snakemake's "Error in rule X:" block names the failing job's own log file —
# that's where the real diagnosis is, not the master log tail.
failing_rule=""
failing_job_log=""
if [ -f "$LOG" ]; then
    rule_line="$(grep -nE '^Error in rule ' "$LOG" 2>/dev/null | tail -1)"
    if [ -n "$rule_line" ]; then
        line_no="${rule_line%%:*}"
        failing_rule="$(printf '%s' "$rule_line" | sed -E 's/^[0-9]+:Error in rule ([^:]+):.*/\1/')"
        failing_job_log="$(tail -n +"$line_no" "$LOG" 2>/dev/null | head -n 15 \
            | grep -m1 -E '^\s*log:' | sed -E 's/^\s*log:\s*//; s/\s*\(check log.*\)\s*$//')"
    fi
fi

steps_done=""
steps_total=""
if [ -f "$LOG" ]; then
    progress_line="$(grep -oE '[0-9]+ of [0-9]+ steps? \([0-9.]+%\) done' "$LOG" 2>/dev/null | tail -1)"
    if [ -n "$progress_line" ]; then
        steps_done="$(printf '%s' "$progress_line" | grep -oE '^[0-9]+')"
        steps_total="$(printf '%s' "$progress_line" | grep -oE 'of [0-9]+' | grep -oE '[0-9]+')"
    fi
fi

jq -n \
    --arg status "$STATUS" \
    --arg exit_code "$exit_code" \
    --arg signal "$signal" \
    --arg classification "$classification" \
    --arg started_at "$started_at" \
    --arg ended_at "$ended_at" \
    --arg duration_s "$duration_s" \
    --arg failing_rule "$failing_rule" \
    --arg failing_job_log "$failing_job_log" \
    --arg steps_done "$steps_done" \
    --arg steps_total "$steps_total" \
    --arg attempt "$attempt" \
    --argjson adopted "$is_adopted" \
    '{
        status: $status,
        adopted: ($adopted == 1),
        exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end),
        signal: (if $signal == "" then null else $signal end),
        classification: $classification,
        started_at: (if $started_at == "" then null else $started_at end),
        ended_at: $ended_at,
        duration_s: (if $duration_s == "" then null else ($duration_s | tonumber) end),
        failing_rule: (if $failing_rule == "" then null else $failing_rule end),
        failing_job_log: (if $failing_job_log == "" then null else $failing_job_log end),
        steps_done: (if $steps_done == "" then null else ($steps_done | tonumber) end),
        steps_total: (if $steps_total == "" then null else ($steps_total | tonumber) end),
        attempt: ($attempt | tonumber)
    }' > "$RUNDIR/pipeline_status.json"

{
    echo "# Pipeline report"
    echo
    echo "STATUS: $STATUS"
    if [ "$is_adopted" -eq 1 ]; then
        echo "(adopted run — this session did not launch the process; exit status is inferred"
        echo " from the log's terminal lines, not a real exit code. Treat with proportionally"
        echo " less certainty than a launched run.)"
    fi
    [ -n "$exit_code" ] && echo "Exit code: $exit_code${signal:+ ($signal)}"
    echo "Classification: $classification"
    [ -n "$started_at" ] && echo "Started: $started_at"
    echo "Ended: $ended_at"
    [ -n "$duration_s" ] && echo "Duration: ${duration_s}s"
    [ -n "$steps_done" ] && echo "Progress: $steps_done of $steps_total steps done"
    echo "Attempt: $attempt"
    [ -f "$CMD_FILE" ] && echo "Command: $(cat "$CMD_FILE")"

    if [ -n "$failing_rule" ]; then
        echo
        echo "## Failing rule: $failing_rule"
        if [ -n "$failing_job_log" ] && [ -f "$failing_job_log" ]; then
            echo
            echo "### Tail of $failing_job_log"
            echo '```'
            tail -n 50 "$failing_job_log" 2>/dev/null
            echo '```'
        elif [ -n "$failing_job_log" ]; then
            echo
            echo "(job log referenced but not found: $failing_job_log)"
        fi
    fi

    if [ -f "$LOG" ]; then
        echo
        echo "## Last 50 lines of master log"
        echo '```'
        tail -n 50 "$LOG" 2>/dev/null
        echo '```'
    fi
} > "$RUNDIR/report.md"
