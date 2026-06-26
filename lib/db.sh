#!/usr/bin/env bash
# claude-brains — shared library: paths, schema, db helpers.
# Sourced by every hook script. No side effects beyond defining vars/functions
# and (via brains_ensure_db) creating the database on first use.

# --- PATH hardening ------------------------------------------------------
# Claude Code hooks can run with a stripped-down PATH. Make sure the standard
# system locations are present so sqlite3/jq/python3/claude resolve.
for _d in /usr/bin /bin /usr/local/bin /opt/homebrew/bin "$HOME/.local/bin"; do
  case ":$PATH:" in *":$_d:"*) ;; *) [ -d "$_d" ] && PATH="$PATH:$_d" ;; esac
done
unset _d
export PATH

# Resolve sqlite3 to an absolute binary once (don't trust PATH at call time).
BRAINS_SQLITE="$(command -v sqlite3 2>/dev/null || true)"
[ -z "$BRAINS_SQLITE" ] && [ -x /usr/bin/sqlite3 ] && BRAINS_SQLITE="/usr/bin/sqlite3"

# --- Paths ---------------------------------------------------------------
BRAINS_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BRAINS_DIR="${BRAINS_CONFIG_DIR}/brains"
BRAINS_DB="${BRAINS_DIR}/brains.db"
BRAINS_STATE_DIR="${BRAINS_DIR}/state"

# Resolve plugin root (where this lib lives) so scripts can find siblings.
# shellcheck disable=SC2128
BRAINS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAINS_ROOT="$(cd "${BRAINS_LIB_DIR}/.." && pwd)"

# --- Dependency check ----------------------------------------------------
brains_has() { command -v "$1" >/dev/null 2>&1; }

# sqlite3 is mandatory. Everything degrades to a no-op without it so hooks
# never block a session.
brains_have_sqlite() { [ -n "$BRAINS_SQLITE" ] && [ -x "$BRAINS_SQLITE" ]; }

# --- SQL escaping --------------------------------------------------------
# Escape a value for single-quoted SQL literals (double the quotes).
brains_sql_escape() { printf '%s' "${1//\'/\'\'}"; }

# --- Schema --------------------------------------------------------------
brains_schema_sql() {
  cat <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS projects (
  id         INTEGER PRIMARY KEY,
  slug       TEXT UNIQUE NOT NULL,
  path       TEXT,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS memories (
  id         INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  type       TEXT NOT NULL CHECK (type IN ('decision','fact','preference','gotcha','state')),
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  UNIQUE (project_id, title)
);

CREATE TABLE IF NOT EXISTS summaries (
  id         INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  session_id TEXT,
  summary    TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_memories_project ON memories(project_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_summaries_project ON summaries(project_id, created_at DESC);

-- Full-text search (external-content tables kept in sync via triggers).
CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
  title, body, content='memories', content_rowid='id'
);
CREATE VIRTUAL TABLE IF NOT EXISTS summaries_fts USING fts5(
  summary, content='summaries', content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;
CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
END;
CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
  INSERT INTO memories_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
END;

CREATE TRIGGER IF NOT EXISTS summaries_ai AFTER INSERT ON summaries BEGIN
  INSERT INTO summaries_fts(rowid, summary) VALUES (new.id, new.summary);
END;
CREATE TRIGGER IF NOT EXISTS summaries_ad AFTER DELETE ON summaries BEGIN
  INSERT INTO summaries_fts(summaries_fts, rowid, summary) VALUES ('delete', old.id, old.summary);
END;

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
SQL
}

# Create db + dirs if missing. Idempotent. Safe to call from any hook.
brains_ensure_db() {
  brains_have_sqlite || return 1
  mkdir -p "$BRAINS_DIR" "$BRAINS_STATE_DIR" 2>/dev/null || true
  if [ ! -f "$BRAINS_DB" ]; then
    brains_schema_sql | "$BRAINS_SQLITE" "$BRAINS_DB" >/dev/null 2>&1 || return 1
  else
    # Cheap re-apply of CREATE IF NOT EXISTS keeps schema current across updates.
    brains_schema_sql | "$BRAINS_SQLITE" "$BRAINS_DB" >/dev/null 2>&1 || true
  fi
  return 0
}

# Run a SQL statement, discard errors. Usage: brains_sql "SELECT ..."
brains_sql() { "$BRAINS_SQLITE" "$BRAINS_DB" "$1" 2>/dev/null; }

# --- Project resolution --------------------------------------------------
# slug mirrors Claude Code's project dir convention: every "/" becomes "-".
brains_slug_for() {
  local p="$1"
  printf '%s' "${p//\//-}"
}

# Ensure a project row exists for the given absolute path; echo its id.
brains_project_id() {
  local path="$1"
  [ -z "$path" ] && return 1
  local slug; slug="$(brains_slug_for "$path")"
  local eslug; eslug="$(brains_sql_escape "$slug")"
  local epath; epath="$(brains_sql_escape "$path")"
  brains_sql "INSERT OR IGNORE INTO projects(slug, path) VALUES('$eslug', '$epath');"
  brains_sql "SELECT id FROM projects WHERE slug='$eslug' LIMIT 1;"
}

# Look up an existing project id without creating it. Empty if none.
brains_project_id_existing() {
  local path="$1"
  [ -z "$path" ] && return 1
  local eslug; eslug="$(brains_sql_escape "$(brains_slug_for "$path")")"
  brains_sql "SELECT id FROM projects WHERE slug='$eslug' LIMIT 1;"
}

# --- FTS query builder ---------------------------------------------------
# Turn free text into a safe FTS5 MATCH expression: quoted tokens OR-joined.
# Echoes empty string when no usable tokens (caller should skip the query).
brains_fts_query() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs '[:alnum:]' '\n' \
    | awk 'length($0) >= 4 && !seen[$0]++ { printf "\"%s\" ", $0; n++ } END { exit (n==0) }' \
    | awk '{ gsub(/ +$/, ""); gsub(/" "/, "\" OR \""); print }'
}

# --- Hook JSON output ----------------------------------------------------
# Emit a SessionStart/UserPromptSubmit additionalContext payload.
# Args: <hookEventName> <context-text>. Uses jq when available for safe JSON.
brains_emit_context() {
  local event="$1" text="$2"
  [ -z "$text" ] && return 0
  if brains_has jq; then
    jq -n --arg e "$event" --arg c "$text" \
      '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
  else
    # Minimal manual JSON escaping fallback.
    local esc="${text//\\/\\\\}"; esc="${esc//\"/\\\"}"; esc="${esc//$'\n'/\\n}"; esc="${esc//$'\t'/\\t}"
    printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}' "$event" "$esc"
  fi
}

# Read hook stdin JSON into BRAINS_INPUT once; extract fields via brains_field.
brains_read_input() { BRAINS_INPUT="$(cat)"; }
brains_field() {
  local key="$1"
  if brains_has jq; then
    printf '%s' "$BRAINS_INPUT" | jq -r "$key // empty" 2>/dev/null
  fi
}
