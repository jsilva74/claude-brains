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
#   <spool>/<sid>__00001.txt   raw "[role] text" chunk for turn index 1
#   <spool>/<sid>.meta         one line: session cwd (project resolution)
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

# --- High-water mark: highest turn index already spooled for this session ---
# Two sources, and the mark file is the one that matters. Spooled turns are
# deleted once distilled, so on a session that hit /compact the files are gone
# while the transcript keeps growing: reading the mark from the files alone
# restarts at turn 1 and re-spools the whole conversation for the next distill
# to compress a second time. The mark file outlives that cleanup.
mark_file="${BRAINS_SPOOL_DIR}/${sid}.mark"
mark=0
if [ -r "$mark_file" ]; then
  mark="$(head -n1 "$mark_file" 2>/dev/null)"
  case "$mark" in ''|*[!0-9]*) mark=0 ;; esac
fi
for f in "${BRAINS_SPOOL_DIR}/${sid}__"*.txt; do
  [ -e "$f" ] || continue
  n="${f##*__}"; n="${n%.txt}"
  n=$((10#$n)) 2>/dev/null || n=0
  [ "$n" -gt "$mark" ] && mark="$n"
done

# --- Parse all turns to NDJSON; turn index == line number -------------------
tmp_nd="$(mktemp "${TMPDIR:-/tmp}/brains_nd.XXXXXX")" || exit 0
trap 'rm -f -- "$tmp_nd"' EXIT
brains_turns_ndjson "$transcript" > "$tmp_nd" 2>/dev/null
total="$(wc -l < "$tmp_nd" 2>/dev/null || echo 0)"; total=$((total + 0))

# Nothing new since the last spool.
[ "$total" -le "$mark" ] && exit 0

# --- Record session cwd once (atomic) --------------------------------------
if [ ! -f "$meta" ]; then
  mpart="${BRAINS_SPOOL_DIR}/.${sid}.meta.partial"
  if printf '%s\n' "$cwd" > "$mpart" 2>/dev/null; then
    mv -f "$mpart" "$meta" 2>/dev/null || rm -f -- "$mpart"
  fi
fi

# --- Spool new turns: write .partial then atomic rename --------------------
i="$mark"
while [ "$i" -lt "$total" ]; do
  i=$((i + 1))
  idx="$(printf '%05d' "$i")"
  fin="${BRAINS_SPOOL_DIR}/${sid}__${idx}.txt"
  [ -e "$fin" ] && continue   # self-heal idempotency: never rewrite a turn
  line="$(sed -n "${i}p" "$tmp_nd")"
  [ -z "$line" ] && continue
  part="${BRAINS_SPOOL_DIR}/.${sid}__${idx}.partial"
  if { printf '%s' "$line" | jq -r . 2>/dev/null; printf '\n'; } > "$part" 2>/dev/null; then
    mv -f "$part" "$fin" 2>/dev/null || rm -f -- "$part"
  else
    rm -f -- "$part"
  fi
done

# Persist how far this session has been spooled. Written last, so a crash
# mid-loop leaves the mark behind rather than ahead: the next Stop re-spools a
# few turns that already exist, which the `[ -e "$fin" ]` guard makes free.
printf '%s\n' "$total" > "${mark_file}.partial" 2>/dev/null \
  && mv -f "${mark_file}.partial" "$mark_file" 2>/dev/null \
  || rm -f -- "${mark_file}.partial"

exit 0
