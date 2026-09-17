#!/usr/bin/env bash
# Adopt a pipeline this session did not launch, materialising a rundir that
# watch_pipeline.sh and pipeline_report.sh consume unchanged.
#
# Usage:
#   attach_pipeline.sh [--rundir DIR] --auto
#   attach_pipeline.sh [--rundir DIR] --pid PID [--log FILE]
#   attach_pipeline.sh [--rundir DIR] --log FILE
#
# Fidelity is strictly lower than run_pipeline.sh, and deliberately so: the exit
# status of a process is delivered only to its parent, so a pipeline we did not
# spawn can never yield an authoritative exit code (waitid on a pidfd requires
# the target to be our child). Adopted runs therefore report SUCCESS_INFERRED /
# FAILED_INFERRED / ENDED_UNKNOWN, never SUCCESS / FAILED.
#
# PTRACE_ATTACH could read the true status via exit_group (ptrace_scope is 0 on
# this host) and is rejected on purpose: it stops the tracee, risks perturbing or
# killing a multi-hour run, and only buys a number the log already implies.
set -u

RUNDIR=".pipeline-attach"
PID=""
LOG_SRC=""
AUTO=0

while [ $# -gt 0 ]; do
    case "$1" in
        --rundir) RUNDIR="$2"; shift 2 ;;
        --pid)    PID="$2"; shift 2 ;;
        --log)    LOG_SRC="$2"; shift 2 ;;
        --auto)   AUTO=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

die() { echo "attach: $*" >&2; exit 65; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_profiles.sh"

# Field 22 of /proc/PID/stat is starttime, but comm (field 2) is parenthesised
# and may itself contain spaces and parens, so a naive $22 is wrong. Strip
# through the last ") " and index from there: overall field 22 == field 20 after.
proc_starttime() {
    local raw rest
    raw="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${raw##*) }"
    printf '%s' "$rest" | awk '{print $20}'
}

proc_start_epoch() {
    local st bt hz
    st="$(proc_starttime "$1")" || return 1
    [ -n "$st" ] || return 1
    bt="$(awk '/^btime/{print $2}' /proc/stat)"
    hz="$(getconf CLK_TCK)"
    [ -n "$bt" ] && [ -n "$hz" ] || return 1
    echo $(( bt + st / hz ))
}

if [ "$AUTO" -eq 1 ]; then
    if [ -z "$PID" ]; then
        # Exclude our own tooling so the watcher/attacher never adopt themselves.
        mapfile -t found < <(pgrep -u "$(id -u)" -f 'snakemake' 2>/dev/null \
            | while read -r p; do
                  c="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
                  case "$c" in
                      *attach_pipeline*|*watch_pipeline*|*run_pipeline*|*pipeline_report*) ;;
                      *) echo "$p" ;;
                  esac
              done)
        if [ "${#found[@]}" -eq 1 ]; then
            PID="${found[0]}"
        elif [ "${#found[@]}" -gt 1 ]; then
            echo "attach: several candidate processes — rerun with --pid PID:" >&2
            for p in "${found[@]}"; do
                printf '  %s  %s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" >&2
            done
            exit 65
        fi
    fi
    if [ -z "$LOG_SRC" ]; then
        # Snakemake writes this regardless of where the user redirected stdout,
        # which is what makes bare `snakemake` (no redirect) adoptable at all.
        LOG_SRC="$(ls -1t .snakemake/log/*.snakemake.log 2>/dev/null | head -1)"
    fi
    [ -n "$PID" ] || [ -n "$LOG_SRC" ] || die "--auto found no snakemake process and no .snakemake/log/*.snakemake.log"
fi

[ -n "$PID" ] || [ -n "$LOG_SRC" ] || die "need --pid, --log, or --auto"

MODE="log"
EXPECTED_START=""
if [ -n "$PID" ]; then
    case "$PID" in ''|*[!0-9]*) die "bad --pid: $PID" ;; esac
    kill -0 "$PID" 2>/dev/null || die "pid $PID is not running (or not ours)"
    MODE="pid"
    EXPECTED_START="$(proc_starttime "$PID" || echo '')"
fi

if [ -n "$LOG_SRC" ]; then
    [ -f "$LOG_SRC" ] || die "log not found: $LOG_SRC"
    LOG_ABS="$(cd "$(dirname "$LOG_SRC")" && pwd)/$(basename "$LOG_SRC")"
else
    LOG_ABS=""
fi

mkdir -p "$RUNDIR"
rm -f "$RUNDIR/pipeline.exit" "$RUNDIR/report.md" "$RUNDIR/needs_human.md" \
      "$RUNDIR/pipeline.log" "$RUNDIR/pipeline.pid" "$RUNDIR/pipeline.pidstart"

# Registry lets babysit-status find this rundir from any cwd later.
REGISTRY="$HOME/.claude/babysit_rundirs.list"
RUNDIR_ABS="$(cd "$RUNDIR" && pwd)"
mkdir -p "$(dirname "$REGISTRY")"
touch "$REGISTRY"
grep -qxF "$RUNDIR_ABS" "$REGISTRY" 2>/dev/null || echo "$RUNDIR_ABS" >> "$REGISTRY"

printf '%s' "$MODE" > "$RUNDIR/adopted"

cmd_for_detect=""
[ -n "$PID" ] && cmd_for_detect="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)"
printf '%s' "$(detect_profile "$cmd_for_detect" "$LOG_ABS")" > "$RUNDIR/profile"

if [ -n "$LOG_ABS" ]; then
    ln -s "$LOG_ABS" "$RUNDIR/pipeline.log"
fi

if [ -n "$PID" ]; then
    printf '%s' "$PID" > "$RUNDIR/pipeline.pid"
    [ -n "$EXPECTED_START" ] && printf '%s' "$EXPECTED_START" > "$RUNDIR/pipeline.pidstart"
    cmd="$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null)"
    [ -n "$cmd" ] && printf '%s\n' "$cmd" > "$RUNDIR/pipeline.cmd"
    if s_epoch="$(proc_start_epoch "$PID")"; then
        date -u -d "@$s_epoch" +%Y-%m-%dT%H:%M:%SZ > "$RUNDIR/started_at"
    fi
elif [ -n "$LOG_ABS" ]; then
    # No process: fall back to the log's birth time, where the filesystem has it.
    birth="$(stat -c %W "$LOG_ABS" 2>/dev/null || echo 0)"
    if [ "$birth" != "0" ] && [ "$birth" != "-" ]; then
        date -u -d "@$birth" +%Y-%m-%dT%H:%M:%SZ > "$RUNDIR/started_at"
    fi
fi

# Adopted runs have no launch history of their own. Start the retry budget at 1
# so a later auto-fix relaunch is counted as attempt 2, not attempt 1.
[ -f "$RUNDIR/attempts" ] || printf '%s' 1 > "$RUNDIR/attempts"

echo "attached mode=$MODE rundir=$RUNDIR${PID:+ pid=$PID}${LOG_ABS:+ log=$LOG_ABS}"
