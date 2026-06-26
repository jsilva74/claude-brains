#!/usr/bin/env python3
"""Parse the distiller's JSON output into safe SQL for the brains DB.

Usage: parse-distill.py <text-file> <project_id> <session_id>
Reads the model output (which should be a JSON object), tolerantly extracts the
first {...} block, validates it, and prints SQL statements on stdout to be piped
into `sqlite3 brains.db`. Prints nothing (exit 0) when there is nothing to store.
"""
import json
import re
import sys

VALID_TYPES = {"decision", "fact", "preference", "gotcha", "state"}


def esc(s: str) -> str:
    return str(s).replace("'", "''")


def unwrap_envelope(raw: str) -> str:
    """Return the `.result` payload if `raw` is a `claude -p --output-format json`
    envelope; otherwise return `raw` unchanged.

    `strict=False` lets unescaped control characters (U+0000-U+001F) inside the
    payload through instead of aborting the whole parse — the failure mode that
    silently dropped captures before.
    """
    try:
        env = json.loads(raw, strict=False)
    except (ValueError, TypeError):
        return raw
    if isinstance(env, dict) and isinstance(env.get("result"), str):
        return env["result"]
    return raw


def main() -> int:
    if len(sys.argv) < 4:
        return 0
    text_path, pid, sid = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        pid_int = int(pid)
    except ValueError:
        return 0

    try:
        with open(text_path, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return 0

    # Unwrap the `claude -p` envelope, then tolerantly extract the first {...}.
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

    summary = (data.get("summary") or "").strip()
    if summary:
        out.append(
            "INSERT INTO summaries(project_id, session_id, summary) "
            f"VALUES({pid_int}, '{esc(sid)}', '{esc(summary)}');"
        )

    memories = data.get("memories")
    if isinstance(memories, list):
        for mem in memories[:8]:
            if not isinstance(mem, dict):
                continue
            mtype = (mem.get("type") or "fact").strip().lower()
            if mtype not in VALID_TYPES:
                mtype = "fact"
            title = (mem.get("title") or "").strip()
            body = (mem.get("body") or "").strip()
            if not title or not body:
                continue
            # Bound runaway values.
            title = title[:200]
            body = body[:2000]
            out.append(
                "INSERT INTO memories(project_id, type, title, body) "
                f"VALUES({pid_int}, '{esc(mtype)}', '{esc(title)}', '{esc(body)}') "
                "ON CONFLICT(project_id, title) DO UPDATE SET "
                "body=excluded.body, type=excluded.type, updated_at=datetime('now');"
            )

    if out:
        print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
