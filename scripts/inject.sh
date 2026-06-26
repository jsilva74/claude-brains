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
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

project_id="$(brains_project_id_existing "$cwd")"
[ -z "$project_id" ] && exit 0   # nothing remembered for this project yet

last_summary="$(brains_sql "SELECT summary FROM summaries WHERE project_id=${project_id} ORDER BY created_at DESC LIMIT 1;")"

memories="$(brains_sql "
  SELECT '- (' || type || ') ' || title || ': ' || body
  FROM memories WHERE project_id=${project_id}
  ORDER BY updated_at DESC LIMIT 25;
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
