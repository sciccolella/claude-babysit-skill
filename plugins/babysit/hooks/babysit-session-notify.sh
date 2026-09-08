#!/bin/bash
# SessionStart hook: surfaces babysat pipelines (run_pipeline.sh/attach_pipeline.sh)
# under the new session's cwd, so a fresh or /clear'd session learns about a
# pipeline it inherited without anyone having to ask babysit-status first.
# Fires on "startup" and "clear" — not "resume" (session-resume-guard.sh
# already owns that source, and a resumed session already has the context).

set -euo pipefail

input="$(cat)"
source_val="$(jq -r '.source // empty' <<<"$input")"
case "$source_val" in
    startup|clear) ;;
    *) exit 0 ;;
esac

cwd="$(jq -r '.cwd // empty' <<<"$input")"
[ -n "$cwd" ] || exit 0

summary="$("${CLAUDE_PLUGIN_ROOT}/scripts/pipeline_peek.sh" --summary --cwd "$cwd" 2>/dev/null || true)"
[ -n "$summary" ] || exit 0

jq -n --arg summary "$summary" '
  {hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: ("Babysat pipeline(s) found under this directory:\n" + $summary + "\nRun /babysit-status for full detail.")
  }}
'
