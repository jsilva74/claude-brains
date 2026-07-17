#!/usr/bin/env python3
"""Parse the GC consolidator's JSON output into safe SQL for the brains DB.

Usage: parse-gc.py <text-file> <project_id>
Reads the model output (a JSON object with "archive" and "update" lists),
validates it, and prints SQL on stdout to be piped into `sqlite3 brains.db`.
Emits ONLY UPDATE statements — GC never inserts new memories and never
physically deletes (archiving is the soft-delete; purge happens elsewhere).
Prints nothing (exit 0) when there is nothing to do.
"""

import importlib.util
import json
import os
import re
import sys

_spec = importlib.util.spec_from_file_location(
    "parse_distill", os.path.join(os.path.dirname(__file__), "parse-distill.py")
)
assert _spec is not None and _spec.loader is not None
_pd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_pd)

esc = _pd.esc
unwrap_envelope = _pd.unwrap_envelope
VALID_TYPES = _pd.VALID_TYPES


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    text_path, pid = sys.argv[1], sys.argv[2]

    try:
        pid_int = int(pid)
    except ValueError:
        return 0

    try:
        with open(text_path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return 0

    raw = unwrap_envelope(raw)

    match = re.search(r"\{.*\}", raw, re.S)
    if not match:
        return 0
    try:
        data = json.loads(match.group(0), strict=False)
    except (ValueError, TypeError):
        return 0
    if not isinstance(data, dict):
        return 0

    out = []

    archive = data.get("archive")
    if isinstance(archive, list):
        for title in archive[:80]:
            if not isinstance(title, str):
                continue
            title = title.strip()[:200]
            if not title:
                continue
            out.append(
                "UPDATE memories SET archived_at=datetime('now') "
                f"WHERE project_id={pid_int} AND title='{esc(title)}' AND archived_at IS NULL;"
            )

    updates = data.get("update")
    if isinstance(updates, list):
        for mem in updates[:80]:
            if not isinstance(mem, dict):
                continue
            title = (mem.get("title") or "").strip()[:200]
            body = (mem.get("body") or "").strip()[:2000]
            if not title or not body:
                continue
            mtype = (mem.get("type") or "").strip().lower()
            type_sql = f", type='{esc(mtype)}'" if mtype in VALID_TYPES else ""
            out.append(
                f"UPDATE memories SET body='{esc(body)}'{type_sql}, updated_at=datetime('now') "
                f"WHERE project_id={pid_int} AND title='{esc(title)}' AND archived_at IS NULL;"
            )

    if out:
        print("\n".join(out))
    else:
        # Valid reply, empty plan. Emit a no-op so the caller can tell "clean
        # corpus" (advance bookkeeping) apart from "parse failed" (retry later).
        print("-- gc: nothing to consolidate")
    return 0


if __name__ == "__main__":
    sys.exit(main())
