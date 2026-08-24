#!/usr/bin/env bash
# claude-brains recall hook (SessionStart).
# Injects the last session summary + most relevant memories for this project.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

brains_read_input
brains_have_sqlite || exit 0
[ -f "$BRAINS_DB" ] || exit 0

cwd="$(brains_field '.cwd')"
cwd="$(brains_anchor_dir "$cwd")"

project_id="$(brains_project_id_existing "$cwd")"
[ -z "$project_id" ] && exit 0   # nothing remembered for this project yet

last_summary="$(brains_sql "SELECT summary FROM summaries WHERE project_id=${project_id} ORDER BY created_at DESC LIMIT 1;")"

# Recall is hybrid: recency alone silently drops most of a mature project's
# corpus (a 200-memory project showed 88% never surfacing). Take the newest N
# for continuity, then fill the rest by FTS relevance against the last summary
# so older-but-pertinent memories can still come back.
recent_n="${BRAINS_RECALL_RECENT:-10}";    case "$recent_n" in ''|*[!0-9]*) recent_n=10 ;; esac
relevant_n="${BRAINS_RECALL_RELEVANT:-15}"; case "$relevant_n" in ''|*[!0-9]*) relevant_n=15 ;; esac

recent="$(brains_sql "
  SELECT id FROM memories
  WHERE project_id=${project_id} AND archived_at IS NULL
  ORDER BY updated_at DESC LIMIT ${recent_n};
" | paste -sd, -)"
[ -z "$recent" ] && recent="0"

relevant=""
if [ -n "$last_summary" ]; then
  match="$(brains_fts_query "$last_summary")"
  if [ -n "$match" ]; then
    ematch="$(brains_sql_escape "$match")"
    relevant="$(brains_sql "
      SELECT m.id FROM memories_fts f JOIN memories m ON m.id = f.rowid
      WHERE m.project_id=${project_id} AND m.archived_at IS NULL
        AND m.id NOT IN (${recent}) AND f.memories_fts MATCH '${ematch}'
      ORDER BY rank LIMIT ${relevant_n};
    " | paste -sd, -)"
  fi
fi
[ -z "$relevant" ] && relevant="0"

memories="$(brains_sql "
  SELECT '- (' || type || ') ' || title || ': ' || body
  FROM memories
  WHERE project_id=${project_id} AND archived_at IS NULL
    AND id IN (${recent},${relevant})
  ORDER BY updated_at DESC;
")"
[ -z "$last_summary" ] && [ -z "$memories" ] && exit 0

context="$(
  printf '# 🧠 claude-brains — memory for this project\n\n'
  if [ -n "$last_summary" ]; then
    printf '## Where we left off\n%s\n\n' "$last_summary"
  fi
  if [ -n "$memories" ]; then
    printf '## Remembered facts & decisions\n%s\n' "$memories"
  fi
  printf '\n_(Recalled from claude-brains. Background context — verify before relying on file/flag names.)_\n'
)"

brains_emit_context "SessionStart" "$context"
exit 0
