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

# A project root with no marker file has no stable anchor: if CLAUDE_PROJECT_DIR
# is ever absent (detached worker, orphan spool recovery), identity falls back to
# the payload cwd — which the agent moves with `cd`, splitting one project into
# many. Warn instead of writing a file into someone's repo uninvited. Scratch
# directories are exempt: they are not projects and the notice would be noise.
warn=""
case "$cwd" in
  /tmp/*|/private/tmp/*|/var/folders/*) ;;
  *)
    if [ ! -e "$cwd/CLAUDE.md" ] && [ ! -d "$cwd/.claude" ]; then
      warn="⚠ claude-brains: ${cwd} não tem CLAUDE.md nem .claude/ — sem esse marcador a memória do projeto pode se fragmentar (cada subpasta vira um projeto separado, com recall parcial e decisões conflitantes que nunca se anulam). Correção: crie um CLAUDE.md na raiz do projeto."
    fi
    ;;
esac

project_id="$(brains_project_id_existing "$cwd")"
if [ -z "$project_id" ]; then
  # Nothing remembered yet — but a new project is exactly where the missing
  # marker matters most, so the warning still goes out.
  [ -n "$warn" ] && brains_emit_context "SessionStart" "$warn" "$warn"
  exit 0
fi

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
  ORDER BY created_at DESC LIMIT ${recent_n};
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
  ORDER BY created_at DESC;
")"
[ -z "$last_summary" ] && [ -z "$memories" ] && { [ -n "$warn" ] && brains_emit_context "SessionStart" "$warn" "$warn"; exit 0; }

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

[ -n "$warn" ] && context="${context}\n${warn}\n"
brains_emit_context "SessionStart" "$context" "$warn"
exit 0
