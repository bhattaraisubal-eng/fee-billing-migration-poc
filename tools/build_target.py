"""
Build the target database and run the parity reconciliation.

Loads the source extracts and the legacy invoice file into SQLite, executes the
target SQL in order, then prints the reconciliation. Writes the billing output,
the exception log, the reconciliation and the defect log as CSVs so the results
are reviewable without a SQL client.

Usage:  python3 tools/build_target.py
Writes: data/target_output/*.csv
        build/fee_billing.db
"""

import csv
import os
import sqlite3
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_DIR = os.path.join(BASE, "build")
DB_PATH = os.path.join(DB_DIR, "fee_billing.db")
IN_DIR = os.path.join(BASE, "data", "input")
LEGACY_DIR = os.path.join(BASE, "data", "legacy_output")
OUT_DIR = os.path.join(BASE, "data", "target_output")

SQL_STEPS = [
    ("target/01_schema.sql", "schema"),
    ("target/02_conform.sql", "conform staging to dimensions"),
    ("target/03_aum.sql", "build billable AUM"),
    ("target/04_fee_calc.sql", "calculate fees"),
    ("testing/05_parity.sql", "reconcile against legacy"),
]

STAGING_LOADS = [
    ("stg_accounts", os.path.join(IN_DIR, "accounts.csv"),
     ["account_id", "household_id", "account_name", "account_type",
      "fee_schedule_code", "open_date", "close_date", "status", "advisor_id",
      "domicile_state"]),
    ("stg_households", os.path.join(IN_DIR, "households.csv"),
     ["household_id", "household_name", "billing_method",
      "relationship_manager", "onboard_date"]),
    ("stg_holdings", os.path.join(IN_DIR, "holdings.csv"),
     ["account_id", "as_of_date", "ticker", "asset_class", "quantity",
      "market_value", "custodian"]),
    ("stg_fee_schedule", os.path.join(IN_DIR, "fee_schedule.csv"),
     ["schedule_code", "tier_seq", "tier_min", "tier_max", "annual_rate_bps",
      "minimum_fee_qtr", "schedule_name"]),
]

RULE = "=" * 78


def load_staging(conn):
    for table, path, cols in STAGING_LOADS:
        with open(path, newline="", encoding="utf-8") as fh:
            rows = [
                tuple(r[c] for c in cols) + (i,)
                for i, r in enumerate(csv.DictReader(fh), start=2)
            ]
        placeholders = ",".join("?" * (len(cols) + 1))
        conn.executemany(
            f"INSERT INTO {table} ({','.join(cols)},source_row) VALUES ({placeholders})",
            rows,
        )
        print(f"  {table:<22} {len(rows):>5} rows")

    legacy_path = os.path.join(LEGACY_DIR, "billing_2026Q3.csv")
    with open(legacy_path, newline="", encoding="utf-8") as fh:
        rows = [
            (r["account_id"], r["household_id"], r["account_name"],
             r["fee_schedule_code"], r["billing_period"], float(r["total_aum"]),
             int(r["annual_rate_bps"]), float(r["gross_fee"]),
             float(r["billable_fee"]), r["advisor_id"])
            for r in csv.DictReader(fh)
        ]
    conn.executemany(
        "INSERT INTO legacy_billing VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
    print(f"  {'legacy_billing':<22} {len(rows):>5} rows")


def run_sql_file(conn, rel_path):
    with open(os.path.join(BASE, rel_path), encoding="utf-8") as fh:
        conn.executescript(fh.read())


def dump(conn, sql, path, params=()):
    cur = conn.execute(sql, params)
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(cols)
        w.writerows(rows)
    return len(rows)


def table(conn, sql, headers=None, money_cols=()):
    cur = conn.execute(sql)
    cols = headers or [d[0] for d in cur.description]
    rows = cur.fetchall()
    if not rows:
        print("  (none)")
        return rows
    widths = [len(c) for c in cols]
    shown = []
    for r in rows:
        cells = []
        for i, v in enumerate(r):
            if v is None:
                s = ""
            elif isinstance(v, float):
                s = f"{v:,.2f}"
            elif isinstance(v, int) and cols[i].lower() in money_cols:
                s = f"{v:,}"
            else:
                s = str(v)
            cells.append(s)
            widths[i] = max(widths[i], len(s))
        shown.append(cells)
    print("  " + "  ".join(c.ljust(widths[i]) for i, c in enumerate(cols)))
    print("  " + "  ".join("-" * widths[i] for i in range(len(cols))))
    for cells in shown:
        print("  " + "  ".join(
            cells[i].rjust(widths[i]) if _numeric(cells[i]) else cells[i].ljust(widths[i])
            for i in range(len(cells))))
    return rows


def _numeric(s):
    return bool(s) and s.replace(",", "").replace(".", "").replace("-", "").isdigit()


def main():
    os.makedirs(DB_DIR, exist_ok=True)
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON")

    print(RULE)
    print("BUILD")
    print(RULE)
    run_sql_file(conn, SQL_STEPS[0][0])
    load_staging(conn)
    for rel_path, label in SQL_STEPS[1:]:
        run_sql_file(conn, rel_path)
        print(f"  {label}")
    conn.commit()

    # ---------------------------------------------------------------- results
    print(f"\n{RULE}\nTARGET RUN\n{RULE}")
    table(conn, """
        SELECT billing_entity              AS "tiered at",
               COUNT(*)                    AS accounts,
               ROUND(SUM(account_aum), 2)  AS "billable aum",
               ROUND(SUM(billable_fee), 2) AS "fees"
        FROM fact_fee_charge GROUP BY billing_entity
        UNION ALL
        SELECT 'TOTAL', COUNT(*), ROUND(SUM(account_aum), 2), ROUND(SUM(billable_fee), 2)
        FROM fact_fee_charge
    """)

    print(f"\n{RULE}\nEXCEPTION LOG  (the legacy workflow reported none)\n{RULE}")
    table(conn, """
        SELECT severity, reason_code AS reason, COUNT(*) AS n,
               ROUND(SUM(amount_at_risk), 2) AS "amount at risk"
        FROM exception_log
        GROUP BY severity, reason_code
        ORDER BY CASE severity WHEN 'BLOCKING' THEN 1 WHEN 'REVIEW' THEN 2 ELSE 3 END,
                 reason_code
    """)

    print(f"\n{RULE}\nPARITY: LEGACY vs TARGET\n{RULE}")
    table(conn, """
        SELECT outcome, accounts, legacy_total AS "legacy $",
               target_total AS "target $", variance
        FROM v_parity_summary
        ORDER BY CASE outcome WHEN 'MATCH' THEN 1 WHEN 'DIFFERS' THEN 2
                              WHEN 'LEGACY_ONLY' THEN 3 ELSE 4 END
    """)

    legacy_total, target_total = conn.execute("""
        SELECT ROUND(SUM(COALESCE(legacy_fee,0)),2), ROUND(SUM(COALESCE(target_fee,0)),2)
        FROM v_parity""").fetchone()
    print(f"\n  legacy invoiced   ${legacy_total:>12,.2f}")
    print(f"  target invoiced   ${target_total:>12,.2f}")
    print(f"  net change        ${target_total - legacy_total:>12,.2f}"
          f"   ({(target_total / legacy_total - 1) * 100:+.1f}%)")

    print(f"\n{RULE}\nEVERY VARIANCE, BY CAUSE\n{RULE}")
    table(conn, """
        SELECT attribution AS cause, accounts, net_variance AS "net $"
        FROM v_variance_by_cause
    """)

    print(f"\n{RULE}\nDEFECT LOG: UNEXPLAINED VARIANCES\n{RULE}")
    defects = table(conn, """
        SELECT account_id, outcome, legacy_fee AS "legacy $",
               target_fee AS "target $", fee_variance AS "variance",
               reason_codes
        FROM v_defects
    """)

    # ------------------------------------------------------------- csv output
    print(f"\n{RULE}\nOUTPUT FILES\n{RULE}")
    outputs = [
        ("billing_2026Q3.csv", """
            SELECT account_id, household_id, billing_entity, schedule_code,
                   billing_period, account_aum, tiering_basis_aum, days_billable,
                   days_in_period, effective_rate_bps, gross_fee,
                   minimum_fee_applied, billable_fee
            FROM fact_fee_charge ORDER BY household_id, account_id"""),
        ("exceptions_2026Q3.csv", """
            SELECT billing_period, severity, reason_code, entity_type, entity_id,
                   detail, amount_at_risk
            FROM exception_log
            ORDER BY CASE severity WHEN 'BLOCKING' THEN 1 WHEN 'REVIEW' THEN 2
                                   ELSE 3 END, reason_code, entity_id"""),
        ("parity_2026Q3.csv", """
            SELECT account_id, outcome, legacy_fee, target_fee, fee_variance,
                   legacy_aum, target_aum, legacy_rate_bps, target_rate_bps,
                   billing_entity, schedule_code, proration_factor,
                   attribution, reason_codes
            FROM v_parity ORDER BY ABS(fee_variance) DESC, account_id"""),
        ("defects_2026Q3.csv", "SELECT * FROM v_defects"),
        ("variance_by_cause_2026Q3.csv", "SELECT * FROM v_variance_by_cause"),
    ]
    for name, sql in outputs:
        n = dump(conn, sql, os.path.join(OUT_DIR, name))
        print(f"  data/target_output/{name:<32} {n:>5} rows")

    conn.close()

    print(f"\n{RULE}")
    if defects:
        print(f"RESULT: {len(defects)} unexplained variance(s). NOT ready for cutover.")
        print(RULE)
        return 1
    print("RESULT: every variance attributed to a signed-off decision. Parity proved.")
    print(RULE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
