#!/usr/bin/env bash
# claude-brains "learn-codebase": scan the current project's CODE and distill
# durable facts/decisions/gotchas into memory. Complements the session-based
# capture (which learns from conversations). Run via `/brains learn`.
#
# Usage: learn.sh [project-path]   (default: current directory)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

PROMPT="${SCRIPT_DIR}/learn-prompt.md"
PARSE="${SCRIPT_DIR}/../lib/parse-distill.py"
MODEL="${CLAUDE_BRAINS_MODEL:-claude-haiku-4-5-20251001}"
DIGEST_CAP=22000   # chars

proj="${1:-$PWD}"
proj="$(cd "$proj" 2>/dev/null && pwd)" || { echo "learn: invalid path"; exit 1; }

brains_have_sqlite || { echo "learn: sqlite3 not found"; exit 1; }
brains_has claude   || { echo "learn: claude CLI not found"; exit 1; }
brains_has jq       || { echo "learn: jq not found"; exit 1; }
brains_ensure_db    || { echo "learn: cannot open DB"; exit 1; }

pid="$(brains_project_id "$proj")"
[ -z "$pid" ] && { echo "learn: cannot resolve project"; exit 1; }

echo "claude-brains learn: scanning $proj ..."

# --- Build a bounded codebase digest -------------------------------------
digest="$(mktemp "${TMPDIR:-/tmp}/brains_digest.XXXXXX")"
trap 'rm -f -- "$digest"' EXIT

is_git=0
git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 && is_git=1

{
  printf '# PROJECT: %s\n' "$proj"
  printf 'git: %s\n' "$([ "$is_git" -eq 1 ] && echo yes || echo no)"

  # File list (tracked files if git, else find excluding heavy dirs).
  if [ "$is_git" -eq 1 ]; then
    files="$(git -C "$proj" ls-files 2>/dev/null)"
  else
    files="$(cd "$proj" && find . -type f \
      -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.venv/*' \
      -not -path '*/venv/*' -not -path '*/dist/*' -not -path '*/build/*' \
      -not -path '*/__pycache__/*' -not -path '*/.next/*' -not -path '*/target/*' \
      2>/dev/null | sed 's#^\./##')"
  fi
  total="$(printf '%s\n' "$files" | grep -c . )"
  printf 'file_count: %s\n\n' "$total"

  printf '## Languages (by extension, top)\n'
  printf '%s\n' "$files" | sed -n 's/.*\.\([A-Za-z0-9]\{1,8\}\)$/\1/p' \
    | sort | uniq -c | sort -rn | head -10 | sed 's/^/  /'

  printf '\n## Top-level layout\n'
  printf '%s\n' "$files" | awk -F/ 'NF>1{print $1"/"} NF==1{print $1}' \
    | sort | uniq -c | sort -rn | head -40 | sed 's/^/  /'

  # Key files to dump (capped).
  printf '\n## Key files\n'
  for pat in README README.md readme.md package.json pyproject.toml requirements.txt \
             Cargo.toml go.mod pom.xml build.gradle composer.json Gemfile \
             tsconfig.json vite.config.ts vite.config.js next.config.js next.config.mjs \
             docker-compose.yml docker-compose.yaml compose.yml Dockerfile Makefile \
             .env.example alembic.ini CLAUDE.md AGENTS.md; do
    f="$proj/$pat"
    if [ -f "$f" ]; then
      printf '\n### %s\n' "$pat"
      head -c 3000 "$f" 2>/dev/null
      printf '\n'
    fi
  done
} > "$digest"

# Cap total size (keep head — manifests/tree are highest signal).
if [ "$(wc -c <"$digest")" -gt "$DIGEST_CAP" ]; then
  head -c "$DIGEST_CAP" "$digest" > "${digest}.cap" && mv "${digest}.cap" "$digest"
fi

# --- Distill (isolated cwd so headless claude -p never pollutes a project) -
existing="$(brains_sql "SELECT '- '||type||': '||title FROM memories WHERE project_id=${pid} ORDER BY updated_at DESC LIMIT 60;")"
work="$(mktemp -d "${TMPDIR:-/tmp}/brains-learn.XXXXXX")"
{
  cat "$PROMPT"
  printf '\n\n## Existing memories (reuse titles to update)\n'
  [ -n "$existing" ] && printf '%s\n' "$existing" || printf '(none yet)\n'
  printf '\n## Codebase digest\n'
  cat "$digest"
} > "${work}/prompt.txt"

echo "claude-brains learn: distilling (model: $MODEL) ..."
resp="$(cd "$work" && CLAUDE_BRAINS_DISTILLING=1 claude -p --model "$MODEL" \
  --output-format json < "${work}/prompt.txt" 2>/dev/null)"
result="$(printf '%s' "$resp" | jq -r '.result // empty' 2>/dev/null)"

# Clean throwaway cwd + any temp project dir headless created.
rm -rf "$work" "${BRAINS_CONFIG_DIR}/projects"/*brains-learn* 2>/dev/null

if [ -z "$result" ]; then echo "learn: model returned nothing (rate limit? empty repo?)"; exit 1; fi

before="$(brains_sql "SELECT COUNT(*) FROM memories WHERE project_id=${pid};")"
printf '%s' "$result" > "${digest}.r"
python3 "$PARSE" "${digest}.r" "$pid" "learn-codebase" 2>/dev/null | "$BRAINS_SQLITE" "$BRAINS_DB" 2>/dev/null
rm -f "${digest}.r"
after="$(brains_sql "SELECT COUNT(*) FROM memories WHERE project_id=${pid};")"

echo "claude-brains learn: done. memories for this project: ${before} -> ${after}"
echo "  (run '/brains list' to review, '/brains search <q>' to query)"
