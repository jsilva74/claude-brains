## 1. Spool writer (Stop + flush)

- [x] 1.1 Create `scripts/spool-turn.sh`: read hook stdin JSON, resolve transcript/cwd/session_id (reuse `lib/db.sh` helpers); exit 0 silently on missing jq/transcript
- [x] 1.2 Parse transcript into ordered user/assistant text turns (reuse distill's jq filter); compute high-water mark = max idx among `spool/<session_id>__*.txt`
- [x] 1.3 For each turn with idx > mark, write `spool/.<session_id>__<idx>.partial` then atomic `mv` to `spool/<session_id>__<NNNNN>.txt` (zero-padded)
- [x] 1.4 Write `spool/<session_id>.meta` (cwd) once if absent, atomically
- [x] 1.5 Create `spool/` dir lazily; no error if turns empty
- [x] 1.6 Test: two invocations spool non-overlapping idx; re-invocation/resume writes no duplicate; killed mid-write leaves only `.partial` (assert distill ignores it)

## 2. Hook wiring

- [x] 2.1 Register `Stop` in `hooks/hooks.json` → `bash "${CLAUDE_PLUGIN_ROOT}/scripts/spool-turn.sh"`, short timeout
- [x] 2.2 Switch `SessionEnd` + `PreCompact` to: run `spool-turn.sh` (flush remaining delta) then dispatch the detached distill worker for the session
- [x] 2.3 Add `recover-spool.sh` to `SessionStart` alongside inject + version-check

## 3. distill: spool source + cleanup

- [x] 3.1 Rework `distill.sh` worker to build `claude -p` input from `cat spool/<session_id>__*.txt` (idx order), capped at 24 KB; resolve project from `<session_id>.meta` cwd
- [x] 3.2 Add explicit-session target form so flush/recovery can dispatch a specific session_id
- [x] 3.3 On usable JSON: write summary + memories (existing upserts) THEN `rm` `spool/<session_id>__*.txt` + `.meta`; on empty/garbage: leave spool intact
- [x] 3.4 Empty spool → skip `claude -p`; if spool empty but transcript present, fall back to legacy transcript-tail path (rollout safety)
- [x] 3.5 Test: distill consumes spool, writes summary, deletes spool; interrupted-after-write re-run upserts (no dup) then deletes; failed distill keeps spool

## 4. SessionStart orphan recovery

- [x] 4.1 Create `scripts/recover-spool.sh`: `ls` spool dir, group leftover files by session_id, skip the starting session
- [x] 4.2 Dispatch the detached distill worker per orphan session; return immediately (non-blocking boot/recall)
- [x] 4.3 Exit 0 silently on empty spool or missing dependency
- [x] 4.4 Test: a leftover-spool session (simulating race loss) is distilled on next SessionStart; current session skipped; empty spool = no-op

## 5. Housekeeping

- [x] 5.1 Prune spool files older than 7 days in `recover-spool.sh` (backstop for permanently-failing distills)
- [x] 5.2 Add spool stats to `/brains stats` (pending sessions / files) for observability
- [x] 5.3 Update plugin README + bump version in `plugin.json`

## 6. End-to-end verification

- [x] 6.1 Reproduce the bug: long session, kill the host before the SessionEnd distill finishes → spool persists, next SessionStart recovers it (zero loss)
- [x] 6.2 Happy path: clean exit → flush+dispatch distill consumes and deletes spool; next SessionStart finds no orphan (no double work)
- [x] 6.3 Crash-safety: kill spool writer mid-turn → only `.partial` left, no corrupt consume
- [x] 6.4 Idempotency: force re-consume of an already-distilled spool → no duplicate summary/memories
- [x] 6.5 No daemon/process left running after sessions end (`ps` clean); honors `no_daemon_architecture`
