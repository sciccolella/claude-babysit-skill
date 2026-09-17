#!/usr/bin/env bash
# Shared profile-registry helpers. See ../profiles/README.md for the
# profile contract; this file only implements detection/loading.
set -u

# The plugin layout keeps profiles/ as a sibling of scripts/; a flat personal
# install (all scripts copied into one bin/ dir with no plugin nesting) can
# instead keep them in a profiles/ subdirectory next to the scripts. Try both;
# neither existing is a supported state too (PROFILES_DIR stays empty, and
# detect_profile/load_profile below already treat "no profiles found" as a
# no-op, same as "no profile matched").
_scripts_dir="$(dirname "${BASH_SOURCE[0]}")"
if [ -d "$_scripts_dir/../profiles" ]; then
    PROFILES_DIR="$(cd "$_scripts_dir/../profiles" && pwd)"
elif [ -d "$_scripts_dir/profiles" ]; then
    PROFILES_DIR="$(cd "$_scripts_dir/profiles" && pwd)"
else
    PROFILES_DIR=""
fi
unset _scripts_dir

# Try each profile's detector against a command line / log path; echo the
# first matching profile's name. Prints nothing and returns 1 if none match
# — callers treat that as "generic", never as an error.
detect_profile() {
    local cmd="$1" log="$2" f
    [ -n "$PROFILES_DIR" ] || return 1
    for f in "$PROFILES_DIR"/*.sh; do
        [ -f "$f" ] || continue
        if ( source "$f"; profile_detect "$cmd" "$log" ) 2>/dev/null; then
            basename "$f" .sh
            return 0
        fi
    done
    return 1
}

# Source a named profile's PROFILE_* variables into the current shell.
# Unknown, empty, or missing name is a no-op: every PROFILE_* variable is
# reset to empty, which every caller already treats as "nothing profile-
# specific to add" rather than an error.
load_profile() {
    local name="$1"
    PROFILE_NAME=""
    PROFILE_FATAL_EXTRA=""
    PROFILE_FAIL_TERMINAL=""
    PROFILE_SUCCESS_TERMINAL=""
    PROFILE_PROGRESS_REGEX=""
    PROFILE_PROGRESS_LABEL=""
    PROFILE_PATTERN_JOB_FAILURE=""
    PROFILE_PATTERN_DAG_ERROR=""
    PROFILE_CLASSIFY_JOB_FAILURE=""
    PROFILE_CLASSIFY_DAG_ERROR=""
    [ -n "$name" ] || return 0
    local f="$PROFILES_DIR/$name.sh"
    [ -f "$f" ] || return 0
    source "$f"
}
