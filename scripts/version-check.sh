#!/usr/bin/env bash
# claude-brains auto update check (SessionStart).
# Throttled to once per 24h. Compares the installed VERSION against the latest
# git tag on GitHub. If newer, injects a one-line nudge to run `/plugin update`.
#
# Why a nudge and not a silent self-overwrite: marketplace plugins live in a
# Claude-Code-managed cache. Overwriting those files from a hook fights the
# plugin manager and breaks integrity checks. The CHECK is automatic; applying
# the update is the native one-command `/plugin update`.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

REPO="jsilva74/claude-brains"
LOCAL_VERSION="$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -z "$LOCAL_VERSION" ] && exit 0

brains_has curl || exit 0
mkdir -p "$BRAINS_STATE_DIR" 2>/dev/null || true
STAMP="${BRAINS_STATE_DIR}/last_update_check"

# Throttle: skip if checked within the last 24h.
now="$(date +%s)"
if [ -f "$STAMP" ]; then
  last="$(cat "$STAMP" 2>/dev/null || echo 0)"
  case "$last" in (*[!0-9]*|'') last=0 ;; esac
  if [ $((now - last)) -lt 86400 ]; then
    exit 0
  fi
fi
printf '%s' "$now" > "$STAMP" 2>/dev/null || true

# Latest release tag (strip a leading "v"). Fail open on any network issue.
latest="$(
  curl -fsSL --max-time 5 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name" *: *"v?([^"]+)".*/\1/'
)"
[ -z "$latest" ] && exit 0

# Nudge only when latest is strictly greater. Portable compare via python3
# (avoids `sort -V`, which is absent on older BSD/macOS sort).
if brains_has python3 && python3 - "$LOCAL_VERSION" "$latest" <<'PY'
import sys, re
def t(v): return tuple(int(x) for x in re.findall(r"\d+", v))
sys.exit(0 if t(sys.argv[2]) > t(sys.argv[1]) else 1)
PY
then
  brains_emit_context "SessionStart" \
    "🧠 claude-brains ${latest} available (installed ${LOCAL_VERSION}). Run \`/plugin update claude-brains\` to upgrade."
fi
exit 0
