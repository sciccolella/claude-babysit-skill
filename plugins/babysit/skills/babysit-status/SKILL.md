---
name: babysit-status
description: "Get a synchronous status report of pipelines under babysit-run/babysit-attach — what's running, what finished, what's stalled or unwatched, and whether anything needs a decision. Use when the user asks what's running, asks for a status update, asks to check on a pipeline, or asks what's missing/left to do. Read-only: does not launch, relaunch, or touch any pipeline, and does not end the turn waiting for anything."
---

# /babysit-status [--rundir DIR]

Wraps `pipeline_peek.sh` (`${CLAUDE_PLUGIN_ROOT}/scripts/`). Unlike `babysit-run`/`babysit-attach`, this is a normal
synchronous command: run it, read the output, answer the user, done. No `run_in_background`,
no ending the turn early, no watcher involved.

It exists because the other two skills only report *once*, at the end (success, failure,
stall). There was no way to ask "what's happening right now" without waiting for that
wake-up. This fills that gap, and also surfaces failure modes the terminal report can't:
a pipeline that's still running but has no watcher armed for it anymore (session died,
watcher was killed, nobody re-armed it), or one that died with no report at all.

A `SessionStart` hook (`hooks/babysit-session-notify.sh` in this plugin) already runs a cwd-scoped
version of this automatically on every new or `/clear`'d session — if a rundir exists under the
new session's cwd, its status is injected into context without anyone asking. So this skill is
for the cases that hook doesn't cover: pipelines outside the current cwd (`--all`), a specific
named rundir, or a manual re-check mid-conversation.

## Usage

- No argument / "what's running" / "check on my pipelines" →
  `"${CLAUDE_PLUGIN_ROOT}/scripts/pipeline_peek.sh" --all`.
  Every pipeline ever launched via `run_pipeline.sh` or attached via `attach_pipeline.sh`
  (from any directory, any session) registers itself in `~/.claude/babysit_rundirs.list`, so
  this works even if the current session never touched that pipeline. Entries whose rundir no
  longer exists are pruned automatically.
- A specific pipeline / directory named →
  `"${CLAUDE_PLUGIN_ROOT}/scripts/pipeline_peek.sh" --rundir <dir>` (default rundir
  names are `.pipeline-run` for launched, `.pipeline-attach` for attached — check both if the
  user just names a project directory and you don't know which was used).

## Reading the output

Per rundir, the report is one of two shapes:

- **`FINISHED: STATUS (classification) at TIME, attempt N`** — a watcher already ran the
  reporter; this is ground truth, not inferred. If `needs_human.md` is also flagged, there's
  an unanswered question — surface it now rather than waiting for another notification.
- **Not yet finalized** — process alive/dead, watcher alive/dead, log size and how long ago
  it last grew, and a parsed progress line (`N of M steps done`) if the log has one. Three
  states matter most here:
  - `process: alive` + `watcher: running` — normal, nothing to do.
  - `*** UNWATCHED ***` — the process is still going but nothing will notify anyone when it
    ends. Tell the user; ask if they want you to re-arm a watcher
    (`"${CLAUDE_PLUGIN_ROOT}/scripts/watch_pipeline.sh" --rundir <dir>` via `Bash` with
    `run_in_background: true`) — don't do
    it silently, since they may have killed the watcher on purpose.
  - `*** died without a report ***` — the process is gone, no `pipeline_status.json` exists,
    and no watcher is running to have caught it. Read the log tail yourself and report what
    you can; don't fabricate a status the system never recorded.

This command never launches, relaunches, kills, or modifies a pipeline — say what's true and
stop. Auto-fix / escalation logic belongs to `babysit-run`/`babysit-attach`'s re-invocation
handling, not to this one.
