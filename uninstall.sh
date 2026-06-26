#!/usr/bin/env bash
# claude-brains uninstaller.
# Removes the plugin via the native manager (printed) and optionally the data.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/db.sh"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "Remove the plugin from Claude Code with:"
echo "  /plugin uninstall claude-brains@claude-brains"
echo

if [ "$PURGE" -eq 1 ]; then
  if [ -d "$BRAINS_DIR" ]; then
    rm -rf -- "$BRAINS_DIR"
    echo "Purged data dir: $BRAINS_DIR"
  else
    echo "No data dir to purge ($BRAINS_DIR not found)."
  fi
else
  echo "Memory data kept at: $BRAINS_DIR"
  echo "Run with --purge to delete it."
fi
