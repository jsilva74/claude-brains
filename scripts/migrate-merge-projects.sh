#!/usr/bin/env bash
# claude-brains: merge project rows that are really the same project.
#
# Before the anchor fix, project identity came from the hook payload's `.cwd`,
# which drifts whenever the agent `cd`s during a session. One repo therefore
# ended up split across many project rows, each holding a slice of the memory —
# so recall started from zero and reconciliation could never see the
# contradicting memory that lived in another slice.
#
# Dry-run by default; --apply writes (after backing the database up).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

brains_have_sqlite || { echo "sqlite3 not found"; exit 1; }
[ -f "$BRAINS_DB" ] || { echo "no database at $BRAINS_DB"; exit 1; }

# Migration-only anchor. Rule 2 (fall back to the nearest ancestor that is
# already a project row) exists for projects carrying no marker file at all —
# at runtime CLAUDE_PROJECT_DIR covers that case, but historical rows have no
# such record.
all_paths="$(brains_sql "SELECT path FROM projects WHERE path IS NOT NULL AND path <> '';")"

migrate_anchor() {
  local p="$1" d="$1" best=""
  while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
    if [ -e "$d/CLAUDE.md" ] || [ -d "$d/.claude" ]; then best="$d"; fi
    d="$(dirname "$d")"
  done
  if [ -z "$best" ]; then
    d="$(dirname "$p")"
    while [ -n "$d" ] && [ "$d" != "/" ] && [ "$d" != "$HOME" ]; do
      if printf '%s\n' "$all_paths" | grep -qxF "$d"; then best="$d"; break; fi
      d="$(dirname "$d")"
    done
  fi
  printf '%s' "${best:-$p}"
}

# --- Group every project row by its anchor -------------------------------
map="$(mktemp "${TMPDIR:-/tmp}/brains_map.XXXXXX")"
trap 'rm -f -- "$map"' EXIT
brains_sql "SELECT id || '|' || path FROM projects WHERE path IS NOT NULL AND path <> '';" \
| while IFS='|' read -r id path; do
    [ -z "$id" ] && continue
    printf '%s\t%s\t%s\n' "$(migrate_anchor "$path")" "$id" "$path"
  done | sort > "$map"

anchors="$(cut -f1 "$map" | sort -u)"
merged_groups=0; moved_mem=0; moved_sum=0; conflicts=0
plan="$(mktemp "${TMPDIR:-/tmp}/brains_plan.XXXXXX")"
# shellcheck disable=SC2064
trap "rm -f -- \"$map\" \"$plan\"" EXIT

printf '\n=== claude-brains project merge (%s) ===\n\n' "$([ "$APPLY" = 1 ] && echo APPLY || echo 'DRY RUN')"

while IFS= read -r a; do
  [ -z "$a" ] && continue
  ids="$(awk -F'\t' -v a="$a" '$1==a{print $2}' "$map")"
  n="$(printf '%s\n' "$ids" | grep -c . )"
  [ "$n" -le 1 ] && continue

  # Canonical row: the one whose path IS the anchor; otherwise the lowest id.
  canon="$(awk -F'\t' -v a="$a" '$1==a && $3==a{print $2; exit}' "$map")"
  [ -z "$canon" ] && canon="$(printf '%s\n' "$ids" | sort -n | head -n1)"
  others="$(printf '%s\n' "$ids" | grep -vx "$canon" | paste -sd, -)"
  [ -z "$others" ] && continue

  mem="$(brains_sql "SELECT COUNT(*) FROM memories  WHERE project_id IN (${others});")"
  sum="$(brains_sql "SELECT COUNT(*) FROM summaries WHERE project_id IN (${others});")"
  # UNIQUE(project_id,title) — a title already held by the canonical row would
  # abort the UPDATE, so those rows are archived instead of moved.
  clash="$(brains_sql "SELECT COUNT(*) FROM memories o WHERE o.project_id IN (${others})
             AND EXISTS (SELECT 1 FROM memories c WHERE c.project_id=${canon} AND c.title=o.title);")"

  merged_groups=$((merged_groups + 1))
  moved_mem=$((moved_mem + mem)); moved_sum=$((moved_sum + sum)); conflicts=$((conflicts + clash))
  printf '%s\n  canonical id=%s  <- ids %s\n  memories %s | summaries %s | title clashes %s\n\n' \
    "$a" "$canon" "$others" "$mem" "$sum" "$clash"
  printf '%s\t%s\n' "$canon" "$others" >> "$plan"
done <<< "$anchors"

if [ "$merged_groups" = 0 ]; then
  echo "Nothing to merge — every project row is already its own anchor."
  exit 0
fi

printf -- '--- totals: %s groups, %s memories, %s summaries, %s clashes ---\n' \
  "$merged_groups" "$moved_mem" "$moved_sum" "$conflicts"

if [ "$APPLY" != 1 ]; then
  printf '\nDry run. Re-run with --apply to write (a backup is taken first).\n'
  exit 0
fi

backup="${BRAINS_DB}.bak-$(date +%Y%m%d-%H%M%S)"
cp "$BRAINS_DB" "$backup" || { echo "backup failed — aborting"; exit 1; }
printf '\nBackup: %s\n' "$backup"

while IFS=$'\t' read -r canon others; do
  [ -z "$canon" ] && continue
  # Archive (never delete) the losing side of a title clash, then move the rest.
  brains_sql "UPDATE memories SET archived_at=COALESCE(archived_at, datetime('now'))
              WHERE project_id IN (${others})
                AND title IN (SELECT title FROM memories WHERE project_id=${canon});"
  brains_sql "UPDATE memories SET project_id=${canon}
              WHERE project_id IN (${others})
                AND title NOT IN (SELECT title FROM memories WHERE project_id=${canon});"
  # Clashing rows stay behind; park them on the canonical project as archived.
  brains_sql "UPDATE memories SET title = title || ' [merged-' || project_id || ']', project_id=${canon}
              WHERE project_id IN (${others});"
  brains_sql "UPDATE summaries SET project_id=${canon} WHERE project_id IN (${others});"
  brains_sql "DELETE FROM projects WHERE id IN (${others});"
  printf 'merged %s -> %s\n' "$others" "$canon"
done < "$plan"

brains_sql "INSERT INTO memories_fts(memories_fts) VALUES('rebuild');"
brains_sql "INSERT INTO summaries_fts(summaries_fts) VALUES('rebuild');"
printf '\nDone. Projects now: %s\n' "$(brains_sql "SELECT COUNT(*) FROM projects;")"
