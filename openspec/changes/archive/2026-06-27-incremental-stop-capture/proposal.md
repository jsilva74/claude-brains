## Why

Capture today depends on the `SessionEnd` hook, which fires during host teardown. The detached distill worker (`setsid` + double-fork) runs a ~25s `claude -p` and races the host's active kill of the shell process-group: sometimes it wins, sometimes it loses and the whole session is dropped silently. The `sif` session this morning (transcript `2d913130`, 363 turns) produced zero entries for exactly this reason while `rp-digital` captured the same morning by winning the race. The failure is intermittent by construction and the user cannot tell a session was lost.

`no_daemon_architecture` forbids claude-mem's persistent `worker-service.cjs`, so we cannot move capture into an always-running process. But the loss is not inherent: the expensive part (the model call) is what loses the race, not the data. If the raw conversation is persisted cheaply **while the host is alive** — turn by turn — then distillation can be eventual and the session can never be lost.

## What Changes

- Add a **`Stop` hook** that, after each assistant turn, writes the raw transcript delta (the new `[role] text` chunks) to an on-disk **spool** as plain files. This is a sub-millisecond `printf`-to-file with an atomic `tmp → rename`, no model call, host alive — no race.
- **distill consumes the spool as its single source** (`cat spool-of-session | claude -p`), no longer re-reading the transcript tail. On success it writes summary + memories to SQLite and **deletes that session's spool files**.
- `SessionEnd`/`PreCompact` change from "distill the transcript" to **flush the remaining delta to the spool, then dispatch the detached distill**. The flush is a fast file write that almost always beats teardown; even if it loses, only the single last turn is at risk, never the session.
- `SessionStart` **recovers orphans cheaply**: glob the spool directory (a tiny `ls`, not a transcript scan) for any session that still has spool files and is not the one starting, and dispatch its distill detached. This is what turns a race-lost session into an at-most-one-session-delayed capture.

Benchmark backing the disk choice: in a real hook (fresh subprocess), `printf`→file ≈ 0.4 ms/call vs `sqlite3` CLI insert ≈ 9 ms/call (~23× slower) — plus disk avoids write-lock contention with the concurrent recall/fts hooks and needs no schema migration.

## Capabilities

### New Capabilities
- `stop-spool-capture`: Per-turn raw spooling to disk via the `Stop` hook (atomic write, self-healing delta), distillation that consumes the spool as single source and cleans it up, and cheap `SessionStart` orphan recovery via spool-dir glob. Covers the spool layout, crash-safety guarantees, idempotent consume+delete, and the SessionEnd/PreCompact flush.

### Modified Capabilities
<!-- specs/ is empty; capture is not yet specced, so this is a new capability, not a delta. -->

## Impact

- **Hooks** (`hooks/hooks.json`): add `Stop`; `SessionStart` gains an orphan-recovery command; `SessionEnd`/`PreCompact` switch to flush+dispatch.
- **Scripts**: new `scripts/spool-turn.sh` (Stop + flush). `scripts/distill.sh` reworked to read a session's spool glob, write to DB, then delete the glob; gains an explicit-session target for dispatch. New `scripts/recover-spool.sh` (SessionStart orphan glob → dispatch).
- **Spool store**: new `~/.claude/brains/spool/` directory. Files: `<session_id>__<idx>.txt` (raw turn chunks) + `<session_id>.meta` (cwd/project). Ephemeral; deleted on successful distill.
- **Schema**: none. `summaries`/`memories` untouched.
- **Dependencies**: none new — bash + jq + python3 + claude CLI + sqlite3 (now only for the distilled store, not the hot path). No daemon (honors `no_daemon_architecture`).
- **Backward compat**: additive. A first run with an empty spool falls back to the legacy transcript-tail path so no session is lost during rollout.
