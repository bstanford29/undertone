"""Read-only, transcript-free evidence for the two-week side-by-side trial."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sqlite3
import statistics
from contextlib import closing
from pathlib import Path
from urllib.parse import quote


_REQUIRED_COLUMNS = frozenset({"ts", "insert_mode", "guard_fired", "total_ms", "kind"})


def _read_rows(history: Path, since: dt.datetime, until: dt.datetime) -> list[tuple]:
    """Read the bounded evidence columns and always release the DB handle."""
    uri = "file:" + quote(str(history.resolve()), safe="/") + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True)) as db:
        columns = {row[1] for row in db.execute("PRAGMA table_info(dictations)")}
        if not columns:
            raise ValueError("History database is missing the dictations table")
        missing = sorted(_REQUIRED_COLUMNS - columns)
        if missing:
            raise ValueError(
                "History database schema is missing required dictations columns: "
                + ", ".join(missing)
            )
        return db.execute(
            "SELECT ts,insert_mode,guard_fired,total_ms FROM dictations WHERE ts>=? AND ts<? AND kind='dictation'",
            (since.timestamp(), until.timestamp()),
        ).fetchall()


def audit(history: Path, since: dt.datetime, until: dt.datetime) -> dict:
    if not history.is_file():
        raise ValueError("History database does not exist")
    if since.tzinfo is None or until.tzinfo is None or since >= until:
        raise ValueError("Use ordered timezone-aware dates")
    rows = _read_rows(history, since, until)
    days = {}
    for timestamp, mode, guard, elapsed in rows:
        day = dt.datetime.fromtimestamp(timestamp, since.tzinfo).date().isoformat()
        result = days.setdefault(day, {"dictations": 0, "inserted": 0, "paste": 0, "guard_fires": 0, "unverified_insertions": 0})
        result["dictations"] += 1
        if mode in {"ax", "type"}:
            result["inserted"] += 1
        elif mode == "paste":
            result["paste"] += 1
        else:
            result["unverified_insertions"] += 1
        result["guard_fires"] += bool(guard)
    observed_days = sorted(days)
    consecutive = 0
    longest = 0
    previous = None
    for day in observed_days:
        date = dt.date.fromisoformat(day)
        consecutive = consecutive + 1 if previous is not None and date - previous == dt.timedelta(days=1) else 1
        longest = max(longest, consecutive)
        previous = date
    violations = sum(d["paste"] + d["guard_fires"] + d["unverified_insertions"] for d in days.values())
    timings = [r[3] for r in rows if isinstance(r[3], (int, float))]
    return {"since": since.isoformat(), "until": until.isoformat(), "dictations": len(rows),
            "days": days, "longest_consecutive_days": longest,
            "median_loop_ms": statistics.median(timings) if timings else None,
            "trial_evidence_pass": longest >= 14 and violations == 0,
            "limitations": "Stored insertion modes are engine receipts, not independent target-app proof. Use alongside your existing dictation tool and get first-hand acceptance before retiring it. This tool never cancels or changes either app."}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", type=Path, default=Path.home() / ".undertone/history.sqlite")
    parser.add_argument("--since", required=True, help="ISO timestamp with timezone")
    parser.add_argument("--until", default=dt.datetime.now(dt.timezone.utc).isoformat())
    args = parser.parse_args()
    print(json.dumps(audit(args.history, dt.datetime.fromisoformat(args.since), dt.datetime.fromisoformat(args.until)), indent=2))


if __name__ == "__main__":
    main()
