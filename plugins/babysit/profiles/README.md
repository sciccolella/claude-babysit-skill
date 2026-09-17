# Profiles

A profile narrows outcome-inference and progress-reporting to one pipeline
tool's log/output shape. The tool-agnostic core (real exit-code path,
disk-full/OOM/`Killed` fatal markers, byte-growth stall detection) never
depends on a profile matching, and "no profile matched" is a supported,
named state — not an error — reported as `profile: null` in
`pipeline_status.json` and "no profile matched" in `report.md`/`peek`.

To add one, drop a `<name>.sh` file here defining:

- `PROFILE_NAME` — should match the filename (without `.sh`).
- `profile_detect() { }` — takes `$1` = command line (may be empty),
  `$2` = log path (may be empty); return 0 if this profile applies.
- `PROFILE_FATAL_EXTRA` — optional regex of tool-specific fatal markers,
  OR'd into `watch_pipeline.sh`'s generic fatal-pattern set. Keep it as
  narrow as the generic set (see `watch_pipeline.sh`'s own comment on why
  bare `error|failed|exception` is never used).
- `PROFILE_FAIL_TERMINAL` / `PROFILE_SUCCESS_TERMINAL` — optional regexes
  matched only against a *terminal* summary line, used solely for
  outcome-inference on adopted/log-only runs (no exit code exists there).
- `PROFILE_PROGRESS_REGEX` / `PROFILE_PROGRESS_LABEL` — optional: a regex
  whose match is shown verbatim as the progress line in `pipeline_peek.sh`
  and `pipeline_report.sh`.
- `PROFILE_PATTERN_JOB_FAILURE` / `PROFILE_PATTERN_DAG_ERROR` and
  `PROFILE_CLASSIFY_JOB_FAILURE` / `PROFILE_CLASSIFY_DAG_ERROR` — optional:
  if a failure log matches the pattern, `pipeline_report.sh` uses the given
  classification name instead of a generic `fatal_pattern_matched:<profile>`.

All variables are optional — an empty/unset one is a no-op everywhere it's
consulted. See `snakemake.sh` for a complete worked example.
