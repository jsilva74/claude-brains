# 🧠 claude-brains

Lightweight persistent memory for [Claude Code](https://claude.com/claude-code).

It compresses each session into a local **SQLite + FTS5** store and recalls the
relevant bits automatically in future sessions — the *core* of session memory
(compression + recall) **without** a background daemon, server, auth layer, job
queue, or per-tool observer.

## What it does

- **Capture** — on `SessionEnd` and `PreCompact`, a cheap headless `claude -p`
  reads the transcript tail and distills it into:
  - a short **summary** (a resumable handoff note), and
  - 0–8 durable **memories** (`decision` / `fact` / `preference` / `gotcha` / `state`).
- **Recall** — on `SessionStart`, the last summary + top memories for the project
  are injected. On every `UserPromptSubmit`, an FTS5 match surfaces the memories
  relevant to what you just asked.
- **Dedup & bounded** — memories are keyed by `(project, title)` and upserted, so
  the store stays curated instead of growing without limit.

## Storage

Everything lives in one file: `~/.claude/brains/brains.db` (WAL mode).

```
projects(id, slug, path, created_at)
memories(id, project_id, type, title, body, created_at, updated_at)   + memories_fts
summaries(id, project_id, session_id, summary, created_at)            + summaries_fts
```

`slug` mirrors Claude Code's project-dir convention (every `/` → `-`), mapping
1:1 to project paths.

## Platform support

| OS | Status |
| :--- | :--- |
| macOS | ✅ native |
| Linux | ✅ native |
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
> overwrite its own files — the *check* is automatic, the *apply* is one command.

## Manage — `/brains`

```
/brains status            counts + last summary for the current project
/brains search <query>    FTS5 search across all projects
/brains list              list this project's memories
/brains forget <title>    delete a memory by exact title
/brains summaries         recent session summaries
/brains projects          all known projects
/brains stats             global totals + DB size
/brains update            how to update
```

## Configuration

- `CLAUDE_CONFIG_DIR` — overrides the base dir (default `~/.claude`); the DB lives
  under `<config-dir>/brains/`.
- Capture model — set in `scripts/distill.sh` (a fast, cheap model by default).

## Uninstall

```
/plugin uninstall claude-brains@claude-brains
bash uninstall.sh --purge    # also delete the database
```

## License

MIT
