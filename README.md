# babysit

A Claude Code plugin that lets Claude launch (or adopt) a long-running pipeline — a Snakemake
workflow, a training run, anything that takes hours to days — and walk away. A detached watcher
polls for free; Claude is woken **exactly once**, on the first actionable event (success,
failure, unclean death, stall, or launch failure), and reads a small pre-digested report instead
of a multi-GB log.

No more "run this and let me know when it's done" prompting that either blocks the session or
gets forgotten.

## Requirements

**Linux only.** Depends on `/proc`, `pgrep`, `setsid`, GNU coreutils (`stat -c`, `date -d`), and
`jq`. macOS is not supported today — the process-liveness and stall-detection logic would need a
different implementation there.

## Install

```
/plugin marketplace add sciccolella/claude-babysit-skill
/plugin install babysit@babysit
```

## What's in it

Three skills, one hook, six scripts (`plugins/babysit/scripts/`) — see
[`plugins/babysit/README.md`](plugins/babysit/README.md) for the full contract: the status
vocabulary, what auto-fixes vs. what always escalates to a human, and exactly what's
Snakemake-specific vs. workflow-agnostic.

- **`babysit-run`** — launch a new pipeline under a watcher.
- **`babysit-attach`** — adopt a pipeline that's *already* running (started by hand, or by a
  session that died or got `/clear`'d).
- **`babysit-status`** — synchronous "what's running right now" check, across every pipeline
  ever launched or attached, from any directory.

A `SessionStart` hook also surfaces any pipeline registered under the new session's cwd
automatically, so a fresh or `/clear`'d session picks it back up without anyone asking.

## License

MIT — see [LICENSE](LICENSE).
