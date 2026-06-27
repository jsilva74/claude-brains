## ADDED Requirements

### Requirement: Per-turn raw spooling on Stop

The system SHALL, on the `Stop` hook after each assistant turn, write the raw transcript delta (new user/assistant text turns since the last spooled turn) to the on-disk spool, while the host is alive. The write MUST NOT invoke `claude -p` and MUST complete synchronously within the hook (no detached worker needed), so it cannot be lost to a teardown race.

#### Scenario: Assistant turn completes

- **WHEN** the `Stop` hook fires for a session with a valid transcript and cwd
- **THEN** each new text turn since the last spooled index is written to `~/.claude/brains/spool/<session_id>__<idx>.txt`
- **AND** no `claude -p` process is started

#### Scenario: Session metadata recorded once

- **WHEN** the first `Stop` of a session spools a turn and no `<session_id>.meta` exists
- **THEN** a `<session_id>.meta` file is written with the session cwd (so distill can resolve the project without the transcript)

#### Scenario: Empty delta

- **WHEN** the `Stop` hook fires but no new text turn exists since the last spooled index
- **THEN** nothing is written and the hook exits 0

#### Scenario: Missing dependency

- **WHEN** `Stop` fires but jq or the transcript is unavailable
- **THEN** the hook exits 0 silently without blocking the session

### Requirement: Atomic, crash-safe spool writes

Each spool file MUST be written to a temporary name and then atomically renamed to its final name, so that a process killed mid-write never leaves a partial file under a name that distill would consume.

#### Scenario: Killed mid-write

- **WHEN** the spooling process is killed while writing a turn file
- **THEN** the partial data remains under a temporary/`.partial` name and is ignored by distill
- **AND** no consumed turn file is ever partially written

### Requirement: Self-healing delta prevents gaps

Each `Stop` SHALL spool every turn after the highest already-spooled index for the session (derived from existing spool filenames), so that a turn missed by a skipped or killed `Stop` is captured by the next `Stop`.

#### Scenario: A Stop was missed

- **WHEN** one `Stop` did not run for a turn and a later `Stop` fires
- **THEN** the later `Stop` spools all turns after the last spooled index, including the previously missed one

#### Scenario: No duplication

- **WHEN** `Stop` fires repeatedly or the session is resumed
- **THEN** a turn already present in the spool (same `<session_id>__<idx>`) is not written again

### Requirement: Distill consumes the spool as single source

`distill.sh` SHALL build its `claude -p` input from a session's spool files (`<session_id>__*.txt`, in index order) rather than the transcript tail. On a successful parse it MUST write the summary + memories and delete that session's spool files (turn files and `.meta`) so they are not consumed again.

#### Scenario: Successful distill

- **WHEN** distill runs for a session with spool files and the model returns usable JSON
- **THEN** the summary and memories are written to SQLite keyed to that `session_id`
- **AND** that session's spool files are deleted

#### Scenario: Failed distill leaves spool intact

- **WHEN** distill runs but the model returns no usable JSON
- **THEN** the spool files are NOT deleted, so a later trigger can retry

#### Scenario: Idempotent re-consume

- **WHEN** distill is interrupted after writing to SQLite but before deleting the spool, and runs again
- **THEN** the re-write upserts the same memories/summary (no duplicate) and then deletes the spool

#### Scenario: Empty spool

- **WHEN** distill runs for a session with no spool files
- **THEN** no `claude -p` call is made and it exits 0

#### Scenario: Rollout fallback

- **WHEN** distill runs and the spool is empty but a transcript is available (e.g. first run after upgrade, before any Stop spooled)
- **THEN** it falls back to the legacy transcript-tail path so the session is still captured

### Requirement: SessionEnd and PreCompact flush then dispatch

`SessionEnd` and `PreCompact` SHALL flush the remaining transcript delta to the spool (the same fast file write as `Stop`) and then dispatch the detached distill for the session. The flush is the teardown-resilient guarantee; the detached distill is best-effort.

#### Scenario: Clean exit

- **WHEN** `SessionEnd` fires and the detached distill wins the teardown race
- **THEN** the session's spool is consumed and deleted, and the next `SessionStart` finds no orphan for it

#### Scenario: Distill loses the race

- **WHEN** `SessionEnd` fires but the detached distill is killed before finishing
- **THEN** the session's spool files remain on disk intact for orphan recovery (no data loss)

### Requirement: Cheap SessionStart orphan recovery

The system SHALL, on `SessionStart`, list the spool directory (a directory glob, NOT a transcript scan) for sessions that still have spool files and are not the session currently starting, and dispatch the detached distill for each. This MUST be non-blocking so boot and recall are not delayed.

#### Scenario: Race-lost session recovered

- **WHEN** a prior session left spool files because its distill lost the teardown race, and a later `SessionStart` fires
- **THEN** orphan recovery dispatches the detached distill for that session, condensing it into the store

#### Scenario: Current session excluded

- **WHEN** orphan recovery runs and the starting session already has spool files
- **THEN** the starting session is skipped (its own Stop/SessionEnd will handle it)

#### Scenario: No orphans

- **WHEN** `SessionStart` fires and the spool directory has no other sessions' files
- **THEN** recovery is a no-op and exits 0

#### Scenario: Non-blocking

- **WHEN** orphan recovery is triggered at `SessionStart`
- **THEN** it returns immediately and recall injection proceeds without waiting
