#!/usr/bin/env python3
"""Parse the verifier's rename plan into safe SQL for the brains DB.

Usage: parse-verify.py <text-file> <project_id> <allowed-file>

<allowed-file> holds one "title<TAB>missing-path" line per pair the verifier
itself detected. Anything outside it is refused: the model reads the memory
text and will otherwise volunteer a "rename" for something that was never
missing — that is how `sif.core.clock` became `sif.clock`.

The model answers one question only — "this path became that path" — and the
edit is a literal substitution done by SQLite's REPLACE(). It cannot lose a
detail, reword a sentence, or invent a date, which is exactly what happened
when the verifier was allowed to rewrite bodies itself.

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

# A path, and nothing but a path. Anything carrying quotes, spaces or SQL
# punctuation is not one, and has no business reaching a REPLACE().
PATH_RE = re.compile(r"^[A-Za-z0-9_.@+/-]{1,300}$")


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    text_path, pid = sys.argv[1], sys.argv[2]
    allowed_path = sys.argv[3] if len(sys.argv) > 3 else ""

    # (title, from) pairs this run actually found missing. No allowlist means
    # nothing is allowed: a caller that forgets to pass it gets a no-op, never
    # an unchecked rewrite.
    allowed = set()
    if allowed_path:
        try:
            with open(allowed_path, "r", encoding="utf-8") as fh:
                for line in fh:
                    t, _, f = line.rstrip("\n").partition("\t")
                    if t and f:
                        allowed.add((t, f))
        except OSError:
            pass

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

    match = re.search(r"\{.*\}", raw, re.DOTALL)
    if not match:
        return 0
    try:
        data = json.loads(match.group(0), strict=False)
    except (ValueError, TypeError):
        return 0
    if not isinstance(data, dict):
        return 0

    out = []
    renames = data.get("renames")
    if isinstance(renames, list):
        for item in renames[:40]:
            if not isinstance(item, dict):
                continue
            title = (item.get("title") or "").strip()[:200]
            old = (item.get("from") or "").strip()
            new = (item.get("to") or "").strip()
            if not title or not old or not new or old == new:
                continue
            if not PATH_RE.match(old) or not PATH_RE.match(new):
                continue
            if (title, old) not in allowed:
                continue
            # Guarded by `INSTR`: if the stored text does not literally contain
            # the old path, the model misquoted it and the row is left alone.
            out.append(
                f"UPDATE memories SET body=REPLACE(body, '{esc(old)}', '{esc(new)}'), "
                "updated_at=datetime('now') "
                f"WHERE project_id={pid_int} AND title='{esc(title)}' "
                f"AND archived_at IS NULL AND INSTR(body, '{esc(old)}') > 0;"
            )

    if out:
        print("\n".join(out))
    else:
        # Valid reply, nothing moved. The no-op lets the caller tell this apart
        # from a failed parse, which must not count as a completed check.
        print("-- verify: no renames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
