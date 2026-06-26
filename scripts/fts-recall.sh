#!/usr/bin/env bash
# claude-brains relevance hook (UserPromptSubmit).
# FTS5-matches the user's prompt against stored memories and injects the top hits.
# This is the "auto-recall relevant context" behaviour, scoped to the project.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

brains_read_input
brains_have_sqlite || exit 0
[ -f "$BRAINS_DB" ] || exit 0

cwd="$(brains_field '.cwd')"
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
prompt="$(brains_field '.prompt')"
[ -z "$prompt" ] && exit 0

project_id="$(brains_project_id_existing "$cwd")"
[ -z "$project_id" ] && exit 0

match="$(brains_fts_query "$prompt")"
[ -z "$match" ] && exit 0
ematch="$(brains_sql_escape "$match")"

# Rank by FTS relevance; keep it tight so we don't bloat every prompt.
hits="$(brains_sql "
  SELECT '- (' || m.type || ') ' || m.title || ': ' || m.body
  FROM memories_fts f
  JOIN memories m ON m.id = f.rowid
  WHERE m.project_id=${project_id} AND f.memories_fts MATCH '${ematch}'
  ORDER BY rank LIMIT 5;
")"

[ -z "$hits" ] && exit 0

context="$(
  printf '# 🧠 claude-brains — relevant memory\n%s\n' "$hits"
)"

brains_emit_context "UserPromptSubmit" "$context"
exit 0
