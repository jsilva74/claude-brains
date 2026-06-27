#!/usr/bin/env bash
# claude-brains spool recovery (SessionStart).
#
# A session whose distill lost the teardown race leaves its spool files on disk
# (distill only deletes them on success). This hook finds such orphans with a
# cheap directory glob — NOT a transcript scan — and dispatches the detached
# distill worker for each, turning a race loss into an at-most-one-session delay.
#
# Also prunes spool files older than a cutoff, as a backstop for sessions whose
# distill keeps failing. Never blocks: any failure exits 0.
set -uo pipefail

if [ -n "${CLAUDE_BRAINS_DISTILLING:-}" ]; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

# Read the starting session's id so we can skip it (its own Stop/SessionEnd
# will handle it). Input is optional — recovery still works without it.
brains_read_input 2>/dev/null || true
cur_sid="$(brains_field '.session_id' 2>/dev/null || true)"
cur_sid="$(brains_sid "$cur_sid")"

[ -d "$BRAINS_SPOOL_DIR" ] || exit 0

# --- Prune stale spool (backstop for permanently-failing distills) ----------
# Default 7 days; override with BRAINS_SPOOL_PRUNE_DAYS.
prune_days="${BRAINS_SPOOL_PRUNE_DAYS:-7}"
find "$BRAINS_SPOOL_DIR" -maxdepth 1 -type f -mtime "+${prune_days}" -delete 2>/dev/null || true

# --- Collect orphan session ids from spool filenames ------------------------
# A session is recoverable if it still has at least one __NNNNN.txt file.
orphans=""
for f in "${BRAINS_SPOOL_DIR}/"*__*.txt; do
  [ -e "$f" ] || continue
  base="${f##*/}"
  sid="${base%%__*}"
  [ -n "$sid" ] || continue
  [ "$sid" = "$cur_sid" ] && continue       # skip the starting session
  case " $orphans " in *" $sid "*) ;; *) orphans="$orphans $sid" ;; esac
done

[ -z "${orphans// }" ] && exit 0

# --- Dispatch a detached distill per orphan ---------------------------------
# Reuse distill.sh's launcher: it reads a hook-shaped payload on stdin and
# daemonizes the worker. The worker reads the spool by session_id, so an empty
# transcript_path is fine. cwd comes from the spooled .meta.
for sid in $orphans; do
  meta="${BRAINS_SPOOL_DIR}/${sid}.meta"
  cwd=""
  [ -r "$meta" ] && cwd="$(head -n1 "$meta" 2>/dev/null)"
  [ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

  if brains_has jq; then
    payload="$(jq -n --arg s "$sid" --arg c "$cwd" \
      '{hook_event_name:"SessionStart",session_id:$s,cwd:$c,transcript_path:""}')"
  else
    payload="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"${sid}\",\"cwd\":\"${cwd}\",\"transcript_path\":\"\"}"
  fi

  # Launcher returns in ~0.2s after detaching the worker; safe to loop.
  printf '%s' "$payload" | bash "${SCRIPT_DIR}/distill.sh" >/dev/null 2>&1 || true
done

exit 0
