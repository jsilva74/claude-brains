#!/usr/bin/env bash
# claude-brains spool writer (Stop / SessionEnd flush / PreCompact flush).
#
# Persists the raw transcript delta — every user/assistant turn newer than what
# is already spooled — to disk as plain files, while the host is alive. This is
# the teardown-race defense: a cheap `printf`-to-file with an atomic rename, no
# `claude -p`, completing synchronously inside the hook. distill later consumes
# the spool as its single source.
#
# Layout (flat, session-prefixed):
#   <spool>/<sid>__0000042.txt  raw "[role] text" chunk for transcript line 42
#   <spool>/<sid>.meta          one line: session cwd (project resolution)
#   <spool>/<sid>.mark          one line: "v2 <line>" high-water mark
#
# Turns are indexed by their line number in the transcript, which is append-only
# and therefore stable: a given turn keeps the same index for the whole session.
#
# Never blocks: any failure exits 0.
set -uo pipefail

# Recursion guard: the headless `claude -p` in distill may re-fire Stop.
if [ -n "${CLAUDE_BRAINS_DISTILLING:-}" ]; then
  cat >/dev/null 2>&1 || true
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

# jq is the only hard requirement here (no model call, no sqlite).
brains_has jq || { cat >/dev/null 2>&1 || true; exit 0; }

brains_read_input
transcript="$(brains_field '.transcript_path')"
cwd="$(brains_field '.cwd')"
session_id="$(brains_field '.session_id')"
cwd="$(brains_anchor_dir "$cwd")"

[ -z "$session_id" ] && exit 0
[ -n "$transcript" ] && [ -r "$transcript" ] || exit 0

mkdir -p "$BRAINS_SPOOL_DIR" 2>/dev/null || exit 0
sid="$(brains_sid "$session_id")"
meta="${BRAINS_SPOOL_DIR}/${sid}.meta"
mark_file="${BRAINS_SPOOL_DIR}/${sid}.mark"

# --- High-water mark: highest transcript line already spooled ---------------
# The mark file is authoritative and carries a schema tag. A pre-v2 mark counted
# turns within a sliding window, an index that cannot be mapped onto line
# numbers, so its spool is discarded and rebuilt from the transcript: rebuilding
# costs a re-read, keeping it would mean silent duplicates and gaps.
mark=0
if [ -r "$mark_file" ]; then
  read -r tag val < "$mark_file" 2>/dev/null || { tag=""; val=""; }
  if [ "$tag" = "v2" ]; then
    case "$val" in ''|*[!0-9]*) mark=0 ;; *) mark="$val" ;; esac
  else
    rm -f -- "${BRAINS_SPOOL_DIR}/${sid}__"*.txt "$mark_file" 2>/dev/null
    mark=0
  fi
fi
# Fallback when the mark file is missing: recover it from the spooled files.
# Safe now that the index is the (stable) transcript line number.
if [ "$mark" -eq 0 ]; then
  for f in "${BRAINS_SPOOL_DIR}/${sid}__"*.txt; do
    [ -e "$f" ] || continue
    n="${f##*__}"; n="${n%.txt}"
    n=$((10#$n)) 2>/dev/null || n=0
    [ "$n" -gt "$mark" ] && mark="$n"
  done
fi

# --- Parse all turns to "<line>\t<json>" ------------------------------------
tmp_nd="$(mktemp "${TMPDIR:-/tmp}/brains_nd.XXXXXX")" || exit 0
trap 'rm -f -- "$tmp_nd"' EXIT
brains_turns_ndjson "$transcript" > "$tmp_nd" 2>/dev/null
[ -s "$tmp_nd" ] || exit 0

# --- Record session cwd once (atomic) --------------------------------------
# Written once and never rewritten: the project a session belongs to does not
# change, and re-deriving it mid-session is exactly how a `cd` would hijack it.
if [ ! -f "$meta" ]; then
  mpart="${BRAINS_SPOOL_DIR}/.${sid}.meta.partial"
  if printf '%s\n' "$cwd" > "$mpart" 2>/dev/null; then
    mv -f "$mpart" "$meta" 2>/dev/null || rm -f -- "$mpart"
  fi
else
  # Written once means its mtime freezes at the first turn, while `.mark` is
  # rewritten every turn. The spool prune deletes by mtime, so a session living
  # past the prune window would lose `.meta` with its turns still on disk — and
  # project resolution would fall back to guessing again. Keep it as young as
  # the spool it describes. Content is untouched.
  touch "$meta" 2>/dev/null || true
fi

# --- Spool new turns: write .partial then atomic rename --------------------
high="$mark"
while IFS=$'\t' read -r ln payload; do
  case "$ln" in ''|*[!0-9]*) continue ;; esac
  [ "$ln" -le "$mark" ] && continue
  idx="$(printf '%07d' "$ln")"
  fin="${BRAINS_SPOOL_DIR}/${sid}__${idx}.txt"
  [ "$ln" -gt "$high" ] && high="$ln"
  [ -e "$fin" ] && continue   # self-heal idempotency: never rewrite a turn
  [ -z "$payload" ] && continue
  part="${BRAINS_SPOOL_DIR}/.${sid}__${idx}.partial"
  if { printf '%s' "$payload" | jq -r . 2>/dev/null; printf '\n'; } > "$part" 2>/dev/null; then
    mv -f "$part" "$fin" 2>/dev/null || rm -f -- "$part"
  else
    rm -f -- "$part"
  fi
done < "$tmp_nd"

# Persist how far this session has been spooled. Written last, so a crash
# mid-loop leaves the mark behind rather than ahead: the next Stop re-spools a
# few turns that already exist, which the `[ -e "$fin" ]` guard makes free.
[ "$high" -le "$mark" ] && exit 0
printf 'v2 %s\n' "$high" > "${mark_file}.partial" 2>/dev/null \
  && mv -f "${mark_file}.partial" "$mark_file" 2>/dev/null \
  || rm -f -- "${mark_file}.partial"

exit 0
