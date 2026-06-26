#!/usr/bin/env bash
# claude-brains installer.
#
# The supported install path is the native Claude Code plugin marketplace:
#
#   /plugin marketplace add jsilva74/claude-brains
#   /plugin install claude-brains@claude-brains
#
# This script only prepares the local side (DB + dependency check) and prints
# those commands. It does NOT copy anything into Claude's plugin cache — the
# plugin manager owns that.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/db.sh"

echo "=== claude-brains install ==="
echo

missing=0
for dep in sqlite3 claude jq python3 curl; do
  if command -v "$dep" >/dev/null 2>&1; then
    echo "  ok   $dep"
  else
    echo "  MISS $dep"
    [ "$dep" = "curl" ] || missing=1
  fi
done
echo

if [ "$missing" -ne 0 ]; then
  echo "Missing required dependency. Install it and re-run." >&2
  exit 1
fi

bash "${SCRIPT_DIR}/scripts/db-init.sh" || exit 1

echo
echo "Dependencies OK. Install the plugin in Claude Code with:"
echo
echo "  /plugin marketplace add jsilva74/claude-brains"
echo "  /plugin install claude-brains@claude-brains"
echo
echo "The database is created automatically on the first capture."
