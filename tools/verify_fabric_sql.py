"""
Execute the Fabric T-SQL logic locally and prove it matches the SQLite build.

Fabric Warehouse is not reachable from a laptop without a tenant, so this does
the next best thing:

  1. Parses every file in fabric/sql/ as T-SQL with sqlglot. A parse error is a
     syntax error Fabric would also reject.
  2. Transpiles the table DDL and every stored procedure body from T-SQL to
     DuckDB and executes them, in order, on the same source extracts.
  3. Compares the result account by account against build/fee_billing.db, the
     SQLite build that test_fee_math.py has already verified.

What this proves: the procedures' logic produces the same fees, exceptions and
attributions as the verified build. What it does not prove: Fabric-specific
runtime behaviour (COPY INTO, NOT ENFORCED constraints, transaction handling,
decimal scale rules). Those are covered by running fabric/sql/08_checks.sql in
Fabric and comparing exports with tools/compare_fabric_output.py.

Usage:  python3 tools/build_target.py         (once, to build the baseline)
        python3 tools/verify_fabric_sql.py
Needs:  pip install sqlglot duckdb
"""

import os
import re
import sqlite3
import sys

try:
    import duckdb
    import sqlglot
    from sqlglot.errors import ParseError
except ImportError:
    sys.exit("needs: pip install sqlglot duckdb")

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(BASE, "fabric", "sql")
IN_DIR = os.path.join(BASE, "data", "input")
LEGACY = os.path.join(BASE, "data", "legacy_output", "billing_2026Q3.csv")
BASELINE = os.path.join(BASE, "build", "fee_billing.db")

PERIOD = "2026Q3"
PROC_ORDER = [
    ("03_etl_conform.sql", "etl.usp_load_reference"),
    ("03_etl_conform.sql", "etl.usp_conform"),
    ("04_etl_build_aum.sql", "etl.usp_build_aum"),
    ("05_etl_calc_fees.sql", "etl.usp_calc_fees"),
    ("06_etl_reconcile.sql", "etl.usp_reconcile"),
]
RULE = "=" * 78
failures = []


def read(name):
    with open(os.path.join(SQL_DIR, name), encoding="utf-8") as fh:
        return fh.read()


def strip_comments(sql):
    return re.sub(r"--[^\n]*", "", sql)


def batches(sql):
    return [b.strip() for b in re.split(r"^\s*GO\s*$", sql, flags=re.M | re.I)
            if b.strip()]


def proc_body(sql, proc_name):
    """Pull the statements out of CREATE PROCEDURE ... AS BEGIN ... END."""
    for batch in batches(strip_comments(sql)):
        m = re.match(rf"CREATE\s+PROCEDURE\s+{re.escape(proc_name)}\b(.*)",
                     batch, flags=re.S | re.I)
        if not m:
            continue
        rest = m.group(1)
        start = re.search(r"\bAS\s+BEGIN\b", rest, flags=re.I)
        body = rest[start.end():]
        body = body[: body.rstrip().rstrip(";").rstrip().rfind("END")]
        body = re.sub(r"SET\s+NOCOUNT\s+ON\s*;", "", body, flags=re.I)
        return body
    raise ValueError(f"{proc_name} not found")


def to_duck(tsql, label):
    """Transpile T-SQL statements to DuckDB SQL, one string per statement."""
    out = []
    for expr in sqlglot.parse(tsql, read="tsql"):
        if expr is None:
            continue
        sql = expr.sql(dialect="duckdb")
        # T-SQL temp tables (#name) become DuckDB temporary tables.
        sql = re.sub(r"#(\w+)", r"tmp_\1", sql)
        out.append(sql)
    return out


def run(con, statements, label):
    for i, s in enumerate(statements, 1):
        try:
            con.execute(s)
        except Exception as e:  # noqa: BLE001
            print(f"\n  !! {label}, statement {i} failed: {e}\n  {s[:600]}")
            raise


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('  ' + detail) if detail else ''}")
    if not ok:
        failures.append(name)


def main():
    if not os.path.exists(BASELINE):
        sys.exit("build/fee_billing.db missing -- run tools/build_target.py first")

    # ------------------------------------------------------------ 1. parsing --
    print(RULE + "\n1. T-SQL PARSE (sqlglot, tsql dialect)\n" + RULE)
    for name in sorted(os.listdir(SQL_DIR)):
        if not name.endswith(".sql"):
            continue
        sql = strip_comments(read(name))
        errors = 0
        for b in batches(sql):
            m = re.match(r"CREATE\s+PROCEDURE\s+([\w.]+)", b, flags=re.I)
            target = proc_body(read(name), m.group(1)) if m else b
            # NOT ENFORCED and COPY INTO options are Fabric syntax sqlglot does
            # not model; they are checked by eye against the Fabric docs.
            if "NOT ENFORCED" in target.upper() or "COPY INTO" in target.upper():
                continue
            try:
                sqlglot.parse(target, read="tsql")
            except ParseError as e:
                errors += 1
                print(f"     {name}: {str(e).splitlines()[0]}")
        check(f"{name} parses as T-SQL", errors == 0)

    # ---------------------------------------------------------- 2. execution --
    print("\n" + RULE + "\n2. EXECUTE ON DUCKDB (transpiled from T-SQL)\n" + RULE)
    con = duckdb.connect()
    # Harness shim only: T-SQL DATALENGTH (bytes, trailing spaces counted) has
    # no DuckDB built-in. strlen() counts bytes the same way. Fabric runs the
    # real DATALENGTH; this macro exists so the same SQL text can execute here.
    con.execute("CREATE MACRO datalength(x) AS strlen(x)")
    for schema in ("stg", "ref", "core", "audit", "recon", "etl"):
        con.execute(f"CREATE SCHEMA {schema}")

    run(con, to_duck(strip_comments(read("01_tables.sql")), "01"), "01_tables.sql")
    print("  tables created")

    loads = {
        "stg.accounts": os.path.join(IN_DIR, "accounts.csv"),
        "stg.households": os.path.join(IN_DIR, "households.csv"),
        "stg.holdings": os.path.join(IN_DIR, "holdings.csv"),
        "stg.fee_schedule": os.path.join(IN_DIR, "fee_schedule.csv"),
        "stg.legacy_billing": LEGACY,
    }
    for table, path in loads.items():
        # The equivalent of COPY INTO a varchar table: every value as text,
        # empty strings preserved, whitespace preserved.
        con.execute(f"""
            INSERT INTO {table}
            SELECT * FROM read_csv('{path}', all_varchar = true, header = true,
                                   quote = '"', nullstr = '\\N')""")
        n = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"  {table:<20} {n:>5} rows (COPY INTO equivalent)")

    con.execute(f"""
        INSERT INTO ref.billing_period VALUES
        ('{PERIOD}', DATE '2026-07-01', DATE '2026-09-30', DATE '2026-09-30', 92, 365)""")

    for fname, proc in PROC_ORDER:
        body = proc_body(read(fname), proc).replace("@billing_period", f"'{PERIOD}'")
        stmts = to_duck(body, proc)
        run(con, stmts, proc)
        print(f"  {proc:<26} {len(stmts):>3} statements executed")

    # -------------------------------------------------------- 3. comparison --
    print("\n" + RULE + "\n3. COMPARE AGAINST THE VERIFIED SQLITE BUILD\n" + RULE)
    base = sqlite3.connect(BASELINE)

    fab_fees = {r[0]: r for r in con.execute(
        "SELECT account_id, billable_fee, account_aum, billing_entity, days_billable "
        "FROM core.fee_charge").fetchall()}
    ref_fees = {r[0]: r for r in base.execute(
        "SELECT account_id, billable_fee, account_aum, billing_entity, days_billable "
        "FROM fact_fee_charge").fetchall()}

    check("same set of accounts billed",
          set(fab_fees) == set(ref_fees),
          f"fabric {len(fab_fees)}, baseline {len(ref_fees)}")

    diffs = [(a, float(fab_fees[a][1]), ref_fees[a][1]) for a in fab_fees
             if a in ref_fees and abs(float(fab_fees[a][1]) - ref_fees[a][1]) > 0.01]
    check("every fee matches to the cent", not diffs,
          f"{len(diffs)} differ" if diffs else "")
    for a, f, r in diffs[:10]:
        print(f"         {a}: fabric {f:,.2f}  baseline {r:,.2f}")

    fab_total = float(con.execute("SELECT SUM(billable_fee) FROM core.fee_charge").fetchone()[0])
    ref_total = base.execute("SELECT SUM(billable_fee) FROM fact_fee_charge").fetchone()[0]
    check("total fees match", abs(fab_total - ref_total) < 0.01,
          f"fabric {fab_total:,.2f}, baseline {ref_total:,.2f}")

    entity_diffs = [a for a in fab_fees if a in ref_fees
                    and (fab_fees[a][3] != ref_fees[a][3] or fab_fees[a][4] != ref_fees[a][4])]
    check("billing entity and days billable match for every account", not entity_diffs)

    fab_exc = dict(con.execute(
        "SELECT reason_code, COUNT(*) FROM audit.exception_log GROUP BY reason_code").fetchall())
    ref_exc = dict(base.execute(
        "SELECT reason_code, COUNT(*) FROM exception_log GROUP BY reason_code").fetchall())
    check("exception log: same reason codes, same counts", fab_exc == ref_exc,
          "" if fab_exc == ref_exc else f"fabric {fab_exc} vs baseline {ref_exc}")

    fab_attr = dict(con.execute(
        "SELECT account_id, LEFT(attribution, 6) FROM recon.parity").fetchall())
    ref_attr = {a: (s[:6] if s.startswith("GAP-") else s[:6]) for a, s in base.execute(
        "SELECT account_id, attribution FROM v_parity").fetchall()}
    # Baseline labels policy gaps GAP-D; Fabric names them GAP-23/24.
    norm = lambda s: "GAP-D" if s in ("GAP-23", "GAP-24") else s.rstrip()
    attr_diffs = [a for a in fab_attr if norm(fab_attr[a]) != ref_attr.get(a, "")[:6].replace("GAP-D ", "GAP-D").rstrip()]
    check("every variance attributed to the same gap", not attr_diffs,
          f"{len(attr_diffs)} differ" if attr_diffs else "")
    for a in attr_diffs[:10]:
        print(f"         {a}: fabric {fab_attr[a]!r}  baseline {ref_attr.get(a)!r}")

    unexplained = con.execute(
        "SELECT COUNT(*) FROM recon.parity WHERE attribution = 'UNEXPLAINED'").fetchone()[0]
    check("zero unexplained variances (cutover gate)", unexplained == 0)

    # ------------------------------------------------- 4. the 08 control set --
    print("\n" + RULE + "\n4. RUN 08_checks.sql CONTROLS\n" + RULE)
    checks_sql = strip_comments(read("08_checks.sql"))
    checks_sql = re.sub(r"DECLARE\s+@billing_period[^;]*;", "", checks_sql, flags=re.I)
    checks_sql = checks_sql.replace("@billing_period", f"'{PERIOD}'")
    first = to_duck(checks_sql, "08")[0]
    for name, n in con.execute(first).fetchall():
        check(f"control: {name}", int(n) == 0, f"{n} failures" if n else "")

    print("\n" + RULE)
    if failures:
        print(f"{len(failures)} check(s) failed")
        print(RULE)
        return 1
    print("Fabric T-SQL reproduces the verified build exactly.")
    print(RULE)
    return 0


if __name__ == "__main__":
    sys.exit(main())
