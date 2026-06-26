#!/usr/bin/env bash
# Initialize (or migrate-in-place) the claude-brains SQLite database.
# Idempotent — safe to run any time.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

if ! brains_have_sqlite; then
  echo "claude-brains: sqlite3 is required but not found in PATH." >&2
  exit 1
fi
if brains_ensure_db; then
  echo "claude-brains DB ready: $BRAINS_DB"
  if ! "$BRAINS_SQLITE" ":memory:" "CREATE VIRTUAL TABLE t USING fts5(x);" >/dev/null 2>&1; then
    echo "WARNING: this sqlite3 build lacks FTS5 — search/relevance will not work." >&2
  fi
else
  echo "claude-brains: failed to initialize DB at $BRAINS_DB" >&2
  exit 1
fi
