#!/usr/bin/env bash
# claude-brains management CLI. Backs the /brains slash command and is usable
# standalone. Subcommands operate on the global SQLite store.
#
#   brains-cli.sh status [path]      Counts + last summary for a project (default: cwd)
#   brains-cli.sh search <query>     FTS5 search across all memories
#   brains-cli.sh list [path]        List memories for a project
#   brains-cli.sh forget <title>     Delete a memory by exact title (current project)
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
cwd="$PWD"

pid_for() { brains_project_id_existing "$1"; }

case "$cmd" in
  status)
    target="${1:-$cwd}"
    pid="$(pid_for "$target")"
    echo "claude-brains  ·  DB: $BRAINS_DB"
    echo "project: $target"
    if [ -z "$pid" ]; then echo "(no memory stored for this project yet)"; exit 0; fi
    mc="$(brains_sql "SELECT COUNT(*) FROM memories WHERE project_id=$pid;")"
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
      WHERE f.memories_fts MATCH '$ematch'
      ORDER BY rank LIMIT 20;"
    ;;
  list)
    target="${1:-$cwd}"; pid="$(pid_for "$target")"
    [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    brains_sql "SELECT '[' || type || '] ' || title || ': ' || body FROM memories WHERE project_id=$pid ORDER BY updated_at DESC;"
    ;;
  forget)
    title="$*"; [ -z "$title" ] && { echo "usage: forget <exact title>"; exit 1; }
    pid="$(pid_for "$cwd")"; [ -z "$pid" ] && { echo "(no memory for this project)"; exit 0; }
    etitle="$(brains_sql_escape "$title")"
    brains_sql "DELETE FROM memories WHERE project_id=$pid AND title='$etitle';"
    echo "forgot: $title"
    ;;
  summaries)
    target="${1:-$cwd}"; pid="$(pid_for "$target")"
    [ -z "$pid" ] && { echo "(no summaries for this project)"; exit 0; }
    brains_sql "SELECT created_at || '  ' || summary FROM summaries WHERE project_id=$pid ORDER BY created_at DESC LIMIT 20;"
    ;;
  projects)
    brains_sql "SELECT p.slug || '  (mem:' || COUNT(m.id) || ')' FROM projects p LEFT JOIN memories m ON m.project_id=p.id GROUP BY p.id ORDER BY p.slug;"
    ;;
  stats)
    echo "DB: $BRAINS_DB"
    [ -f "$BRAINS_DB" ] && echo "size: $(du -h "$BRAINS_DB" | cut -f1)"
    echo "projects:  $(brains_sql 'SELECT COUNT(*) FROM projects;')"
    echo "memories:  $(brains_sql 'SELECT COUNT(*) FROM memories;')"
    echo "summaries: $(brains_sql 'SELECT COUNT(*) FROM summaries;')"
    ;;
  update)
    echo "Update claude-brains with the native plugin manager:"
    echo "  /plugin update claude-brains"
    echo "(SessionStart auto-checks for new releases once per day and nudges you.)"
    ;;
  *)
    echo "claude-brains commands: status | search <q> | list | forget <title> | summaries | projects | stats | update"
    ;;
esac
