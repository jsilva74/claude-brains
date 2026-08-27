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
cwd="$(brains_anchor_dir "$cwd")"
prompt="$(brains_field '.prompt')"
[ -z "$prompt" ] && exit 0

project_id="$(brains_project_id_existing "$cwd")"
[ -z "$project_id" ] && exit 0

match="$(brains_fts_query "$prompt")"
[ -z "$match" ] && exit 0
ematch="$(brains_sql_escape "$match")"

# Rank by FTS relevance, weighted by type and recency; bm25 rank is negative,
# so a larger multiplier means a stronger hit and ORDER BY stays ascending.
hits="$(brains_sql "
  SELECT '- (' || m.type || ') ' || m.title || ': ' || m.body
  FROM memories_fts f
  JOIN memories m ON m.id = f.rowid
  WHERE m.project_id=${project_id} AND m.archived_at IS NULL AND f.memories_fts MATCH '${ematch}'
  ORDER BY f.rank
    * CASE m.type
        WHEN 'decision'   THEN 1.50
        WHEN 'gotcha'     THEN 1.25
        WHEN 'preference' THEN 1.15
        WHEN 'state'      THEN 0.90
        ELSE 1.00
      END
    * CASE
        WHEN m.created_at >= datetime('now','-7 days')  THEN 1.30
        WHEN m.created_at >= datetime('now','-30 days') THEN 1.15
        WHEN m.created_at >= datetime('now','-90 days') THEN 1.00
        ELSE 0.85
      END
  LIMIT 5;
")"

[ -z "$hits" ] && exit 0

context="$(
  printf '# 🧠 claude-brains — relevant memory\n%s\n' "$hits"
)"

brains_emit_context "UserPromptSubmit" "$context"
exit 0
