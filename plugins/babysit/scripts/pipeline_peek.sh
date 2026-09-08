#!/usr/bin/env bash
# Synchronous, read-only snapshot of one or all known pipelines. Never writes
# report.md/pipeline_status.json (those are the watcher's terminal-state
# contract) — this only prints a live picture of what's happening right now,
# including cases the watcher's own report can't show: a pipeline still
# running, or one nothing is watching anymore.
#
# Usage: pipeline_peek.sh --rundir DIR
#        pipeline_peek.sh --all
#        pipeline_peek.sh --summary --cwd DIR
set -u

REGISTRY="$HOME/.claude/babysit_rundirs.list"

MODE_ARG=""
RUNDIR=""
CWD_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --rundir)  RUNDIR="$2"; MODE_ARG="one"; shift 2 ;;
        --all)     MODE_ARG="all"; shift ;;
        --summary) MODE_ARG="summary"; shift ;;
        --cwd)     CWD_ARG="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done
[ -n "$MODE_ARG" ] || { echo "usage: pipeline_peek.sh --rundir DIR | --all | --summary --cwd DIR" >&2; exit 64; }
if [ "$MODE_ARG" = "summary" ] && [ -z "$CWD_ARG" ]; then
    echo "usage: pipeline_peek.sh --summary --cwd DIR" >&2; exit 64
fi

proc_starttime() {
    local raw rest
    raw="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    rest="${raw##*) }"
    printf '%s' "$rest" | awk '{print $20}'
}

alive_pid() {
    local pid="$1" expected="$2"
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -n "$expected" ]; then
        [ "$(proc_starttime "$pid")" = "$expected" ] || return 1
    fi
    return 0
}

epoch_of() { date -u -d "$1" +%s 2>/dev/null || echo ''; }

human_dur() {
    local s="$1" d h m
    [ -n "$s" ] || { echo "?"; return; }
    d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60))
    if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
    elif [ "$h" -gt 0 ]; then printf '%dh%dm' "$h" "$m"
    else printf '%dm' "$m"
    fi
}

peek_one() {
    local rundir="$1"
    [ -d "$rundir" ] || { echo "== $rundir =="; echo "  (rundir gone — vanished since last check)"; echo; return; }

    local mode="launched"
    [ -f "$rundir/adopted" ] && mode="$(cat "$rundir/adopted" 2>/dev/null || echo pid)"

    local cmd=""
    [ -f "$rundir/pipeline.cmd" ] && cmd="$(cat "$rundir/pipeline.cmd" 2>/dev/null || echo '')"

    local started_at="" started_epoch="" now_epoch elapsed=""
    [ -f "$rundir/started_at" ] && started_at="$(cat "$rundir/started_at" 2>/dev/null || echo '')"
    now_epoch=$(date -u +%s)
    if [ -n "$started_at" ]; then
        started_epoch="$(epoch_of "$started_at")"
        [ -n "$started_epoch" ] && elapsed=$((now_epoch - started_epoch))
    fi

    echo "== $rundir =="
    echo "  mode: $mode"
    [ -n "$cmd" ] && echo "  command: $cmd"
    [ -n "$started_at" ] && echo "  started: $started_at (running ${elapsed:+$(human_dur "$elapsed")})"

    # Already finalized by a watcher exit — this is the ground truth, full stop.
    if [ -f "$rundir/pipeline_status.json" ]; then
        local status classification ended_at attempt adopted
        status="$(jq -r '.status' "$rundir/pipeline_status.json" 2>/dev/null)"
        classification="$(jq -r '.classification' "$rundir/pipeline_status.json" 2>/dev/null)"
        ended_at="$(jq -r '.ended_at' "$rundir/pipeline_status.json" 2>/dev/null)"
        attempt="$(jq -r '.attempt' "$rundir/pipeline_status.json" 2>/dev/null)"
        adopted="$(jq -r '.adopted' "$rundir/pipeline_status.json" 2>/dev/null)"
        echo "  FINISHED: $status ($classification) at $ended_at, attempt $attempt${adopted:+, adopted=$adopted}"
        if [ -f "$rundir/needs_human.md" ]; then
            echo "  *** needs_human.md present — a question is waiting for you ***"
        fi
        echo
        return
    fi

    # Not finalized: figure out if the process is actually alive, and whether
    # anything is watching it.
    local pid="" pidstart="" is_alive=0
    [ -f "$rundir/pipeline.pid" ] && pid="$(cat "$rundir/pipeline.pid" 2>/dev/null || echo '')"
    [ -f "$rundir/pipeline.pidstart" ] && pidstart="$(cat "$rundir/pipeline.pidstart" 2>/dev/null || echo '')"
    if [ -n "$pid" ] && alive_pid "$pid" "$pidstart"; then
        is_alive=1
    fi

    local wpid="" watcher_alive=0
    if [ -f "$rundir/watcher.pid" ]; then
        wpid="$(cat "$rundir/watcher.pid" 2>/dev/null || echo '')"
        [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && watcher_alive=1
    fi

    if [ "$mode" = "log" ]; then
        # No process at all in this mode; only the log can say anything.
        echo "  process: n/a (log-only attach)"
    elif [ "$is_alive" -eq 1 ]; then
        echo "  process: alive (pid $pid)"
    elif [ -n "$pid" ]; then
        echo "  process: NOT alive (pid $pid) — but no pipeline_status.json yet"
        echo "  *** died without a report — the watcher that should have caught this isn't running ***"
    else
        echo "  process: no pid recorded"
    fi

    if [ "$watcher_alive" -eq 1 ]; then
        echo "  watcher: running (pid $wpid)"
    else
        if [ "$mode" != "log" ] && [ "$is_alive" -eq 1 ]; then
            echo "  *** UNWATCHED — pipeline is running but no watcher is armed; nothing will notify you ***"
        else
            echo "  watcher: not running"
        fi
    fi

    if [ -f "$rundir/pipeline.log" ]; then
        local log size mtime stale progress
        log="$rundir/pipeline.log"
        size=$(wc -c < "$log" 2>/dev/null || echo 0)
        mtime=$(stat -c %Y "$log" 2>/dev/null || echo 0)
        stale=$((now_epoch - mtime))
        progress="$(grep -oE '[0-9]+ of [0-9]+ steps? \([0-9.]+%\) done' "$log" 2>/dev/null | tail -1)"
        echo "  log: ${size}B, last write $(human_dur "$stale") ago"
        [ -n "$progress" ] && echo "  progress: $progress"
    fi

    if [ -f "$rundir/needs_human.md" ]; then
        echo "  *** needs_human.md present — a question is waiting for you ***"
    fi
    echo
}

# One compact line per rundir, for injecting into a session's context (e.g.
# from a SessionStart hook) — must stay small even with several matches, and
# the caller decides whether to print anything at all if there are zero.
peek_summary() {
    local rundir="$1"
    [ -d "$rundir" ] || return

    local now_epoch elapsed="" started_at started_epoch
    now_epoch=$(date -u +%s)
    if [ -f "$rundir/started_at" ]; then
        started_at="$(cat "$rundir/started_at" 2>/dev/null || echo '')"
        if [ -n "$started_at" ]; then
            started_epoch="$(epoch_of "$started_at")"
            [ -n "$started_epoch" ] && elapsed=$((now_epoch - started_epoch))
        fi
    fi

    if [ -f "$rundir/pipeline_status.json" ]; then
        local status classification
        status="$(jq -r '.status' "$rundir/pipeline_status.json" 2>/dev/null)"
        classification="$(jq -r '.classification' "$rundir/pipeline_status.json" 2>/dev/null)"
        echo "$rundir: FINISHED $status ($classification)"
        return
    fi

    local pid="" pidstart="" is_alive=0
    [ -f "$rundir/pipeline.pid" ] && pid="$(cat "$rundir/pipeline.pid" 2>/dev/null || echo '')"
    [ -f "$rundir/pipeline.pidstart" ] && pidstart="$(cat "$rundir/pipeline.pidstart" 2>/dev/null || echo '')"
    [ -n "$pid" ] && alive_pid "$pid" "$pidstart" && is_alive=1

    local wpid="" watcher_alive=0
    if [ -f "$rundir/watcher.pid" ]; then
        wpid="$(cat "$rundir/watcher.pid" 2>/dev/null || echo '')"
        [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null && watcher_alive=1
    fi

    local dur=""
    [ -n "$elapsed" ] && dur=" ($(human_dur "$elapsed"))"

    if [ "$is_alive" -eq 1 ] && [ "$watcher_alive" -eq 1 ]; then
        echo "$rundir: running$dur, watched"
    elif [ "$is_alive" -eq 1 ]; then
        echo "$rundir: *** UNWATCHED ***$dur — nothing will notify you when it finishes"
    elif [ -n "$pid" ]; then
        echo "$rundir: *** died without a report ***"
    else
        echo "$rundir: no pid recorded"
    fi
}

if [ "$MODE_ARG" = "one" ]; then
    [ -n "$RUNDIR" ] || { echo "usage: pipeline_peek.sh --rundir DIR" >&2; exit 64; }
    peek_one "$RUNDIR"
    exit 0
fi

# --all / --summary: prune registry entries whose directory no longer exists,
# then report on what's left.
[ -f "$REGISTRY" ] || { [ "$MODE_ARG" = "all" ] && echo "no known pipelines (registry empty: $REGISTRY)"; exit 0; }

kept=()
while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    [ -d "$dir" ] && kept+=("$dir")
done < "$REGISTRY"

if [ "${#kept[@]}" -eq 0 ]; then
    : > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
    [ "$MODE_ARG" = "all" ] && echo "no known pipelines"
    exit 0
fi

printf '%s\n' "${kept[@]}" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

if [ "$MODE_ARG" = "summary" ]; then
    cwd_abs="$(cd "$CWD_ARG" 2>/dev/null && pwd)"
    [ -n "$cwd_abs" ] || exit 0
    for dir in "${kept[@]}"; do
        case "$dir" in
            "$cwd_abs"|"$cwd_abs"/*) peek_summary "$dir" ;;
        esac
    done
    exit 0
fi

for dir in "${kept[@]}"; do
    peek_one "$dir"
done
