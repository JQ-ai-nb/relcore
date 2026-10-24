"""Independent SQLite oracle for the bundled examples.

This is deliberately not a MoonBit test: SQLite is a separate engine, so a
semantic regression in Relcore cannot silently agree with itself. It checks the
same numbers that the README and docs claim.
"""

import csv
import json
import sqlite3
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_csv(conn, table, path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise AssertionError(f"{path} has no rows")
    columns = list(rows[0].keys())
    conn.execute(f"CREATE TABLE {table} ({', '.join(columns)})")
    placeholders = ", ".join("?" for _ in columns)
    conn.executemany(
        f"INSERT INTO {table} VALUES ({placeholders})",
        [[row[column] for column in columns] for row in rows],
    )
    return len(rows)


def scalar(conn, sql):
    return conn.execute(sql).fetchone()[0]


def run_cli(plan, extra=()):
    result = subprocess.run(
        ["node", "bin/relcore.mjs", plan, *extra],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return result


def main():
    conn = sqlite3.connect(":memory:")
    load_csv(conn, "orders", ROOT / "examples/orders.csv")
    load_csv(conn, "customers", ROOT / "examples/customers.csv")

    checks = []

    # 1. Baseline join on customer: 7 output rows, max fanout 2.
    rows = scalar(conn, "SELECT COUNT(*) FROM orders o JOIN customers c ON o.customer = c.customer")
    fanout = scalar(
        conn,
        """
        SELECT MAX(cnt) FROM (
          SELECT o.order_id, COUNT(*) AS cnt
          FROM orders o JOIN customers c ON o.customer = c.customer
          GROUP BY o.order_id
        )
        """,
    )
    assert rows == 7, rows
    assert fanout == 2, fanout
    report = run_cli("examples/plan-tenant-fanout.json")
    assert report.returncode == 1, report.stderr
    payload = json.loads(report.stdout)
    assert payload["rows"] == rows, payload
    assert payload["stats"][-1]["max_fanout"] == fanout, payload
    checks.append("fanout")

    # 2. Composite key: 5 rows, no fanout.
    rows = scalar(
        conn,
        """
        SELECT COUNT(*) FROM orders o
        JOIN customers c ON o.customer = c.customer AND o.tenant = c.tenant
        """,
    )
    assert rows == 5, rows
    report = run_cli("examples/plan-tenant-safe.json")
    assert report.returncode == 0, report.stderr
    payload = json.loads(report.stdout)
    assert payload["ok"] is True, payload
    assert payload["rows"] == rows, payload
    checks.append("composite-key")

    # 3. Revenue by segment after amount > 10.
    expected = conn.execute(
        """
        SELECT c.segment, ROUND(SUM(CAST(o.amount AS REAL)), 2) AS revenue, COUNT(o.order_id)
        FROM orders o
        JOIN customers c ON o.customer = c.customer AND o.tenant = c.tenant
        WHERE CAST(o.amount AS REAL) > 10
        GROUP BY c.segment
        ORDER BY revenue DESC
        """
    ).fetchall()
    assert expected == [("enterprise", 61.75, 3), ("smb", 49.75, 1)], expected
    report = run_cli("examples/plan-revenue-by-segment.json", ["--md"])
    assert report.returncode == 0, report.stderr
    assert "| enterprise | 61.75 | 3 |" in report.stdout, report.stdout
    assert "| smb | 49.75 | 1 |" in report.stdout, report.stdout
    checks.append("revenue")

    # 4. Plan comparison: baseline 7, candidate 5, retained 5, lost 2.
    report = run_cli("examples/compare-tenant-keys.json")
    assert report.returncode == 1, report.stderr
    payload = json.loads(report.stdout)
    assert payload["baseline_rows"] == 7, payload
    assert payload["candidate_rows"] == 5, payload
    assert payload["row_diff"] == {"retained": 5, "lost": 2, "gained": 0}, payload
    assert payload["first_divergence"]["index"] == 2, payload
    checks.append("compare")

    print(f"oracle: {len(checks)} checks passed ({', '.join(checks)})")


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(f"oracle failed: {error}", file=sys.stderr)
        sys.exit(1)
