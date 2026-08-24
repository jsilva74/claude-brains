# 🧠 claude-brains

Lightweight persistent memory for [Claude Code](https://claude.com/claude-code).

It compresses each session into a local **SQLite + FTS5** store and recalls the
relevant bits automatically in future sessions — the _core_ of session memory
(compression + recall) **without** a background daemon, server, auth layer, job
queue, or per-tool observer.

## What it does

- **Capture** — after every assistant turn (`Stop`), the raw turn is spooled to
  disk as plain files — a sub-millisecond write while the host is alive, so it
  can't be lost to the session-teardown race. On `SessionEnd`/`PreCompact` the
  remaining turns are flushed and a cheap headless `claude -p` distills the
  spool into:
  - a short **summary** (a resumable handoff note), and
  - 0–8 durable **memories** (`decision` / `fact` / `preference` / `gotcha` / `state`).
    On success the session's spool is deleted. A session too small to be worth a
    model call (a finished spool under the trivial-size threshold) is also deleted
    without distilling — that's a terminal state, not a retryable failure, so it
    isn't re-dispatched on every future `SessionStart`. If the distill loses the
    teardown race, the spool stays on disk and the next `SessionStart` recovers it
    — so a session is never lost, only condensed slightly later.
- **Recall** — on `SessionStart`, the last summary + top memories for the project
  are injected. On every `UserPromptSubmit`, an FTS5 match surfaces the memories
  relevant to what you just asked.
- **Dedup & bounded** — memories are keyed by `(project, title)` and upserted, so
  the store stays curated instead of growing without limit.
- **Self-maintaining** — the store keeps itself fresh, all outside the session's
  hot path (pure-SQL hooks stay microsecond-fast):
  - the distiller marks memories the session proved outdated (`obsolete`) and
    they are archived in the same model call — no extra cost;
  - only the newest 5 `state` memories stay active per project (older ones are
    ephemeral by nature and get archived);
  - when a project accumulates enough (>120 active memories, rate-limited to at
    most once per 5 distills), an automatic **GC** pass consolidates duplicates
    and archives superseded entries — one bounded `claude -p` call in the same
    detached worker;
  - nothing a model decides is ever deleted: archiving is a soft-delete,
    recoverable via `/brains restore` for 30 days before the physical purge.

## Storage

Everything lives in one file: `~/.claude/brains/brains.db` (WAL mode).

```
projects(id, slug, path, created_at)
memories(id, project_id, type, title, body, created_at, updated_at, archived_at)   + memories_fts
summaries(id, project_id, session_id, summary, created_at)            + summaries_fts
```

`slug` mirrors Claude Code's project-dir convention (every `/` → `-`), mapping
1:1 to project paths.

Project identity comes from the session's **anchor**, not from the hook payload's
`cwd`. The Bash tool keeps its working directory between calls, so an agent that
runs `cd backend` mid-session moves `cwd` — and hooks firing afterwards would
credit the memory to a subdirectory, splitting one project into many. The anchor
is `CLAUDE_PROJECT_DIR`, falling back to the highest ancestor holding `CLAUDE.md`
or `.claude/`.

Databases written before v1.4.0 carry that split. `scripts/migrate-merge-projects.sh`
reports the merge plan (dry-run) and applies it with `--apply`, backing the
database up first and archiving — never deleting — on a title clash.

## Platform support

| OS      | Status                                                          |
| :------ | :-------------------------------------------------------------- |
| macOS   | ✅ native                                                       |
| Linux   | ✅ native                                                       |
| Windows | ✅ via **WSL** or **Git Bash** (a POSIX `bash` must be on PATH) |

The hooks are POSIX shell scripts, so Windows needs a bash environment (WSL or
Git Bash). Native `cmd`/PowerShell-only setups are not supported.

## Dependencies

`bash` · `sqlite3` (≥3.9, with FTS5) · `claude` CLI · `jq` · `python3` · `curl`
(optional, for update checks).

Install `sqlite3` if missing: `apt install sqlite3` (Debian/Ubuntu),
`brew install sqlite` (macOS, already present by default), or the SQLite tools
bundle on Windows. Everything is resolved with a hardened PATH; the plugin
no-ops silently if a required tool is absent, so it never blocks a session.

## Install

```
/plugin marketplace add jsilva74/claude-brains
/plugin install claude-brains@claude-brains
```

That's it. The database is created automatically on the first capture, and
recall starts on your next session in a project (nothing to recall before then).

Optionally, run a one-time dependency check:

```
bash install.sh    # verifies sqlite3/claude/jq/python3 are present — not required
```

## Update

`SessionStart` checks for a newer release at most once per day and, if one exists,
injects a one-line nudge. Apply it with the native plugin manager:

```
/plugin update claude-brains
```

> Marketplace plugins live in a Claude-Code-managed cache, so the plugin does not
> overwrite its own files — the _check_ is automatic, the _apply_ is one command.

## Manage — `/brains`

```
/brains status            counts + last summary for the current project
/brains search <query>    FTS5 search across all projects
/brains list              list this project's memories
/brains forget <title>    archive a memory by exact title (restorable for 30 days)
/brains archived          list this project's archived memories
/brains restore <title>   un-archive a memory by exact title
/brains gc                force a memory-consolidation pass now (ignores the auto gate)
/brains summaries         recent session summaries
/brains learn             scan the current project's codebase and seed memories from it
/brains projects          all known projects
/brains stats             global totals + DB size
/brains update            how to update
```

## Configuration

- `CLAUDE_CONFIG_DIR` — overrides the base dir (default `~/.claude`); the DB lives
  under `<config-dir>/brains/`.
- Capture model — set in `scripts/distill.sh` (a fast, cheap model by default).
- `BRAINS_BUSY_MS` — how long a connection waits for a concurrent writer before
  giving up (default 5000ms). Set per connection, since the pragma cannot live
  in the schema; without it a losing writer drops its work until the next retry.
- Maintenance tuning (env vars, all optional): `BRAINS_STATE_KEEP` (active `state`
  memories kept per project, default 5), `BRAINS_GC_THRESHOLD` (active-memory
  count that arms the auto-GC, default 120), `BRAINS_GC_MIN_DISTILLS` /
  `BRAINS_GC_MAX_DISTILLS` (GC rate limits, defaults 5 / 25), `BRAINS_GC_SLICE`
  (oldest memories per GC pass, default 80), `BRAINS_GC_MAX_BATCHES`
  (batches in one decision-driven sweep, default 4).
- Recall tuning: `BRAINS_RECALL_RECENT` / `BRAINS_RECALL_RELEVANT` (memories
  injected at session start — newest N plus M matched by relevance, defaults
  10 / 15), `BRAINS_RECONCILE_WINDOW` (memories shown to the distiller as
  archival candidates, default 150; anything outside it can never be marked
  obsolete).

## Uninstall

```
/plugin uninstall claude-brains@claude-brains
bash uninstall.sh --purge    # also delete the database
```

## License

MIT
