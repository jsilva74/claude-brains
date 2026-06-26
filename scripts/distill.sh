#!/usr/bin/env bash
# claude-brains capture hook (SessionEnd / PreCompact).
# Compresses the session transcript into SQLite memories + a summary via a cheap
# headless `claude -p` call. Never blocks: any failure exits 0 silently.
set -uo pipefail

# Recursion guard: the headless `claude -p` below may itself fire this hook.
if [ -n "${CLAUDE_BRAINS_DISTILLING:-}" ]; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

brains_read_input
brains_have_sqlite || exit 0
brains_has claude   || exit 0
brains_has jq       || exit 0

transcript="$(brains_field '.transcript_path')"
cwd="$(brains_field '.cwd')"
session_id="$(brains_field '.session_id')"
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

[ -z "$transcript" ] && exit 0
[ -r "$transcript" ] || exit 0

brains_ensure_db || exit 0
project_id="$(brains_project_id "$cwd")"
[ -z "$project_id" ] && exit 0

# --- Build a compact transcript (last turns, text only) ------------------
# Portable mktemp (explicit template works on both GNU and BSD).
tmp_convo="$(mktemp "${TMPDIR:-/tmp}/brains_convo.XXXXXX")"
tmp_out="$(mktemp "${TMPDIR:-/tmp}/brains_out.XXXXXX")"
trap 'rm -f -- "$tmp_convo" "$tmp_out"' EXIT

tail -n 800 "$transcript" 2>/dev/null \
  | jq -r '
      select(.type == "user" or .type == "assistant")
      | .type as $role
      | (.message.content // .message)
      | if type == "array" then (map(select(.type == "text") | .text) | join("\n"))
        elif type == "string" then .
        else "" end
      | select(length > 0)
      | "[\($role)] \(.)"
    ' 2>/dev/null \
  | tail -c 24000 > "$tmp_convo"

# Skip trivial sessions — not worth a model call.
if [ "$(wc -c < "$tmp_convo" 2>/dev/null || echo 0)" -lt 400 ]; then
  exit 0
fi

# --- Existing memory titles for dedup guidance ---------------------------
existing="$(brains_sql "SELECT '- ' || type || ': ' || title FROM memories WHERE project_id=${project_id} ORDER BY updated_at DESC LIMIT 40;")"

# --- Assemble prompt -----------------------------------------------------
{
  cat "${SCRIPT_DIR}/distill-prompt.md"
  printf '\n\n## Existing memories (reuse titles to update)\n'
  if [ -n "$existing" ]; then printf '%s\n' "$existing"; else printf '(none yet)\n'; fi
  printf '\n## Session transcript (tail)\n'
  cat "$tmp_convo"
} > "${tmp_convo}.prompt"

# --- Headless distillation (cheap model, no tools, guarded) --------------
resp="$(
  CLAUDE_BRAINS_DISTILLING=1 claude -p \
    --model claude-haiku-4-5-20251001 \
    --output-format json \
    < "${tmp_convo}.prompt" 2>/dev/null
)"
rm -f -- "${tmp_convo}.prompt"
[ -z "$resp" ] && exit 0

printf '%s' "$resp" | jq -r '.result // empty' 2>/dev/null > "$tmp_out"
[ -s "$tmp_out" ] || exit 0

# --- Parse -> SQL -> DB --------------------------------------------------
python3 "${SCRIPT_DIR}/../lib/parse-distill.py" "$tmp_out" "$project_id" "$session_id" 2>/dev/null \
  | sqlite3 "$BRAINS_DB" 2>/dev/null || true

exit 0
