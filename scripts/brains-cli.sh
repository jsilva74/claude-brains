#!/usr/bin/env bash
# claude-brains management CLI. Backs the /brains slash command and is usable
# standalone. Subcommands operate on the global SQLite store.
#
#   brains-cli.sh status [path]      Counts + last summary for a project (default: cwd)
#   brains-cli.sh search <query>     FTS5 search across all memories
#   brains-cli.sh list [path]        List memories for a project
#   brains-cli.sh forget <title>     Archive a memory by exact title (current project)
#   brains-cli.sh archived [path]    List archived memories for a project
#   brains-cli.sh restore <title>    Un-archive a memory by exact title (current project)
#   brains-cli.sh gc [path]          Force memory consolidation now (ignores the auto gate)
#   brains-cli.sh summaries [path]   Recent session summaries for a project
#   brains-cli.sh projects           List known projects
#   brains-cli.sh stats              Global totals + DB size
#   brains-cli.sh update             Show how to update the plugin
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db.sh
. "${SCRIPT_DIR}/../lib/db.sh"

brains_have_sqlite || { echo "claude-brains: sqlite3 not found."; exit 1; }
brains_ensure_db   || { echo "claude-brains: could not open DB at $BRAINS_DB"; exit 1; }

cmd="${1:-status}"; shift || true
# Same anchor the hooks use, so `/brains` from a subdirectory still resolves
# to the project the memories were filed under.
cwd="$(brains_anchor_dir "$PWD")"

pid_for() { brains_project_id_existing "$1"; }

case "$cmd" in
  status)
    target="${1:-$cwd}"
    pid="$(pid_for "$target")"
    echo "claude-brains  ·  DB: $BRAINS_DB"
    echo "project: $target"
    if [ -z "$pid" ]; then echo "(no memory stored for this project yet)"; exit 0; fi
    mc="$(brains_sql "SELECT COUNT(*) FROM memories WHERE project_id=$pid AND archived_at IS NULL;")"
    sc="$(brains_sql "SELECT COUNT(*) FROM summaries WHERE project_id=$pid;")"
    echo "memories: ${mc:-0}   summaries: ${sc:-0}"
    echo
    echo "last summary:"
    brains_sql "SELECT summary FROM summaries WHERE project_id=$pid ORDER BY created_at DESC LIMIT 1;"
    ;;
  search)
    q="$*"; [ -z "$q" ] && { echo "usage: search <query>"; exit 1; }
    match="$(brains_fts_query "$q")"; [ -z "$match" ] && { echo "(query too short)"; exit 0; }
    ematch="$(brains_sql_escape "$match")"
    brains_sql "
      SELECT p.slug || '  [' || m.type || ']  ' || m.title || ': ' || m.body
      FROM memories_fts f
      JOIN memories m ON m.id=f.rowid
      JOIN projects p ON p.id=m.project_id
      WHERE m.archived_at IS NULL AND f.memories_fts MATCH '$ematch'
      ORDER BY rank LIMIT 20;"
    ;;
  list)
    target="${1:-$cwd}"; pid="$(pid_for "$target")"
    [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    brains_sql "SELECT '[' || type || '] ' || title || ': ' || body FROM memories WHERE project_id=$pid AND archived_at IS NULL ORDER BY created_at DESC;"
    ;;
  forget)
    title="$*"; [ -z "$title" ] && { echo "usage: forget <exact title>"; exit 1; }
    pid="$(pid_for "$cwd")"; [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    etitle="$(brains_sql_escape "$title")"
    # Soft-delete: recoverable via `restore` until the 30-day purge.
    brains_sql "UPDATE memories SET archived_at=datetime('now') WHERE project_id=$pid AND title='$etitle' AND archived_at IS NULL;"
    echo "forgot (archived, restorable for 30 days): $title"
    ;;
  gc)
    target="${1:-$cwd}"; pid="$(pid_for "$target")"
    [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    before="$(brains_sql "SELECT COUNT(*) FROM memories WHERE project_id=$pid AND archived_at IS NULL;")"
    echo "running GC on $target (${before:-0} active memories)..."
    bash "${SCRIPT_DIR}/gc.sh" "$pid"
    after="$(brains_sql "SELECT COUNT(*) FROM memories WHERE project_id=$pid AND archived_at IS NULL;")"
    echo "done: ${before:-0} -> ${after:-0} active memories"
    ;;
  archived)
    target="${1:-$cwd}"; pid="$(pid_for "$target")"
    [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    out="$(brains_sql "SELECT archived_at || '  [' || type || '] ' || title FROM memories WHERE project_id=$pid AND archived_at IS NOT NULL ORDER BY archived_at DESC;")"
    if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(no archived memories)"; fi
    ;;
  restore)
    title="$*"; [ -z "$title" ] && { echo "usage: restore <exact title>"; exit 1; }
    pid="$(pid_for "$cwd")"; [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    etitle="$(brains_sql_escape "$title")"
    brains_sql "UPDATE memories SET archived_at=NULL WHERE project_id=$pid AND title='$etitle' AND archived_at IS NOT NULL;"
    echo "restored: $title"
    ;;
  summaries)
    target="${1:-$cwd}"; pid="$(pid_for "$target")"
    [ -z "$pid" ] && { echo "(no summaries for this project)"; exit 0; }
    brains_sql "SELECT created_at || '  ' || summary FROM summaries WHERE project_id=$pid ORDER BY created_at DESC LIMIT 20;"
    ;;
  projects)
    brains_sql "SELECT p.slug || '  (mem:' || COUNT(m.id) || ')' FROM projects p LEFT JOIN memories m ON m.project_id=p.id AND m.archived_at IS NULL GROUP BY p.id ORDER BY p.slug;"
    ;;
  stats)
    echo "DB: $BRAINS_DB"
    [ -f "$BRAINS_DB" ] && echo "size: $(du -h "$BRAINS_DB" | cut -f1)"
    echo "projects:  $(brains_sql 'SELECT COUNT(*) FROM projects;')"
    echo "memories:  $(brains_sql 'SELECT COUNT(*) FROM memories WHERE archived_at IS NULL;') active, $(brains_sql 'SELECT COUNT(*) FROM memories WHERE archived_at IS NOT NULL;') archived"
    echo "summaries: $(brains_sql 'SELECT COUNT(*) FROM summaries;')"
    # Spool = sessions captured on disk but not yet distilled (pending recovery).
    if [ -d "$BRAINS_SPOOL_DIR" ]; then
      pend_files=$(find "$BRAINS_SPOOL_DIR" -maxdepth 1 -name '*__*.txt' 2>/dev/null | wc -l | tr -d ' ')
      pend_sess=$(find "$BRAINS_SPOOL_DIR" -maxdepth 1 -name '*.meta' 2>/dev/null | wc -l | tr -d ' ')
      echo "spool:     ${pend_sess} pending session(s), ${pend_files} turn file(s)"
    fi
    ;;
  learn)
    # Scan the current project's codebase and seed memories from it.
    exec bash "${SCRIPT_DIR}/learn.sh" "${1:-$cwd}"
    ;;
  update)
    echo "Update claude-brains with the native plugin manager:"
    echo "  /plugin update claude-brains"
    echo "(SessionStart auto-checks for new releases once per day and nudges you.)"
    ;;
  *)
    echo "claude-brains commands: status | search <q> | list | forget <title> | archived | restore <title> | gc | summaries | projects | stats | learn | update"
    ;;
esac
