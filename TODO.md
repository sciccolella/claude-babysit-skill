# TODO

## Generalize `attach_pipeline.sh --auto` process discovery

`--auto` currently only knows how to *find* a running process for one tool:
`pgrep -u "$(id -u)" -f 'snakemake'` (see `plugins/babysit/scripts/attach_pipeline.sh`).
`--pid`/`--log` already cover any other tool explicitly, so this only affects the
zero-argument convenience path for a non-Snakemake pipeline.

From `scratchpad/babysit_snakemake_coupling_report.md` (item 2, deprioritized there too):

- Needs a heuristic for "the one long-running foreground-ish process the user probably
  means" — e.g. the single most-CPU-consuming non-shell process owned by the user that
  isn't this tooling's own scripts.
- Falls back to asking the user to disambiguate, exactly like today's multi-match case
  already does.
- Highest-effort item on that report, and the one most likely to need a human-in-the-loop
  fallback rather than a clean heuristic — hence lowest priority. Do this last, only if the
  `--pid`/`--log` workaround actually becomes friction in practice.
