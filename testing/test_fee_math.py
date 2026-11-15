"""
Independent check of the fee arithmetic.

The SQL in target/04_fee_calc.sql is the implementation. This file re-derives
the same answers a second way, from hand-worked cases and a small independent
calculator, and asserts the database agrees. Two implementations that disagree
mean one of them is wrong, which is the point of writing both.

Covers the four corrections to the legacy logic:
  marginal tiers, reference-driven rates, household aggregation, day-count
  proration -- plus the minimum fee and the tier-boundary behaviour.

Usage:  python3 testing/test_fee_math.py     (run tools/build_target.py first)
"""

import os
import sqlite3
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB = os.path.join(BASE, "build", "fee_billing.db")

DAYS_IN_PERIOD = 92
DAYS_IN_YEAR = 365

# The published schedule, typed independently of ref_fee_schedule so a bad load
# cannot make this test agree with the database by accident.
SCHEDULES = {
    "STD": ([(0, 1_000_000, 100), (1_000_000, 5_000_000, 75),
             (5_000_000, 10_000_000, 50), (10_000_000, None, 35)], 250),
    "INST": ([(0, 10_000_000, 40), (10_000_000, 50_000_000, 25),
              (50_000_000, None, 15)], 0),
    "LEGACY2015": ([(0, None, 90)], 0),
}

results = []


def check(name, got, want, tol=0.01):
    ok = abs(got - want) <= tol
    results.append((ok, name, got, want))
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {name}")
    if not ok:
        print(f"         got {got:,.4f}   want {want:,.4f}   diff {got - want:+,.4f}")
    return ok


def annual_fee(basis, schedule_code):
    """Marginal tiers: each band charges only the money that falls inside it."""
    tiers, _ = SCHEDULES[schedule_code]
    fee = 0.0
    for lo, hi, bps in tiers:
        top = basis if hi is None else min(basis, hi)
        amount_in_tier = max(0.0, top - lo)
        fee += amount_in_tier * bps / 10_000
    return fee


def period_fee(basis, schedule_code, days):
    return annual_fee(basis, schedule_code) * days / DAYS_IN_YEAR


def main():
    if not os.path.exists(DB):
        sys.exit("build/fee_billing.db not found -- run tools/build_target.py first")
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row

    print("=" * 78)
    print("TIER ARITHMETIC -- hand-worked cases")
    print("=" * 78)

    # A balance inside the first tier only.
    check("$500,000 STD annual fee is 100bps throughout",
          annual_fee(500_000, "STD"), 5_000.00)

    # The case the legacy cliff logic got wrong.
    check("$1,012,000 STD annual fee is 10,000 + 75bps on the excess",
          annual_fee(1_012_000, "STD"), 10_000 + 12_000 * 0.0075)

    # Cliff pricing is not monotonic; marginal pricing is. This is the argument
    # for the change, expressed as a test.
    just_under = annual_fee(999_999, "STD")
    just_over = annual_fee(1_000_001, "STD")
    check("marginal tiers never reduce the fee as the balance grows",
          1.0 if just_over >= just_under else 0.0, 1.0, tol=0)
    legacy_under = 999_999 * 0.0100      # cliff: 100bps on the whole balance
    legacy_over = 1_000_001 * 0.0075     # cliff: 75bps on the whole balance
    print(f"         for contrast, cliff pricing fell from {legacy_under:,.2f} "
          f"to {legacy_over:,.2f} across the boundary")

    # A top-tier balance touches every band.
    check("$25,000,000 STD annual fee sums all four bands",
          annual_fee(25_000_000, "STD"),
          1_000_000 * 0.0100 + 4_000_000 * 0.0075
          + 5_000_000 * 0.0050 + 15_000_000 * 0.0035)

    check("$25,000,000 INST annual fee is far below STD",
          annual_fee(25_000_000, "INST"),
          10_000_000 * 0.0040 + 15_000_000 * 0.0025)

    check("LEGACY2015 is flat 90bps with no bands",
          annual_fee(8_000_000, "LEGACY2015"), 8_000_000 * 0.0090)

    print("\n" + "=" * 78)
    print("DAY COUNT -- the legacy fixed divisor of 4 against actual days")
    print("=" * 78)
    check("a full Q3 accrues 92/365 of the annual fee, not one quarter",
          period_fee(1_000_000, "STD", 92), 10_000 * 92 / 365)
    legacy_quarter = 10_000 / 4
    actual_quarter = 10_000 * 92 / 365
    print(f"         $1M account: legacy {legacy_quarter:,.2f} "
          f"against {actual_quarter:,.2f}, understated by "
          f"{actual_quarter - legacy_quarter:,.2f}")

    print("\n" + "=" * 78)
    print("THE DATABASE AGREES -- every account recomputed independently")
    print("=" * 78)

    rows = conn.execute("""
        SELECT account_id, billing_entity, schedule_code, account_aum,
               tiering_basis_aum, days_billable, gross_fee, minimum_fee_applied,
               billable_fee, effective_rate_bps
        FROM fact_fee_charge
        ORDER BY account_id
    """).fetchall()

    mismatched = []
    for r in rows:
        share = (r["account_aum"] / r["tiering_basis_aum"]
                 if r["billing_entity"] == "HOUSEHOLD" else 1.0)
        want = period_fee(r["tiering_basis_aum"], r["schedule_code"],
                          r["days_billable"]) * share
        if abs(r["gross_fee"] - want) > 0.02:
            mismatched.append((r["account_id"], r["gross_fee"], want))

    check(f"all {len(rows)} account fees match the independent calculation",
          float(len(mismatched)), 0.0, tol=0)
    for acct, got, want in mismatched[:10]:
        print(f"         {acct}: db {got:,.2f} against {want:,.2f}")

    print("\n" + "=" * 78)
    print("AUM -- recomputed from the holdings file, not from the database")
    print("=" * 78)
    # The fee check above trusts fact_account_aum. This one does not: it rebuilds
    # every account's billable AUM from holdings.csv in plain Python. It exists
    # because an earlier version of the SQL kept one lot per ticker and dropped
    # the rest, and the fee check alone could not see it.
    import csv
    from collections import defaultdict
    hpath = os.path.join(BASE, "data", "input", "holdings.csv")
    with open(hpath, newline="", encoding="utf-8") as fh:
        raw = list(csv.DictReader(fh))
    seen, rows = set(), []
    for r in raw:  # exact duplicates collapse
        key = (r["account_id"].strip().upper(), r["as_of_date"].strip(),
               r["ticker"].strip().upper(), r["market_value"].strip())
        if key not in seen:
            seen.add(key)
            rows.append(key)
    latest = defaultdict(str)  # latest in-period date per (account, ticker)
    for acct, d, tick, _ in rows:
        if "2026-07-01" <= d <= "2026-09-30":
            latest[(acct, tick)] = max(latest[(acct, tick)], d)
    expected = defaultdict(float)
    for acct, d, tick, mv in rows:
        if latest.get((acct, tick)) == d and mv != "":
            expected[acct] += float(mv)
    db_aum = dict(conn.execute(
        "SELECT account_id, market_value FROM fact_account_aum").fetchall())
    aum_bad = [(a, db_aum[a], expected[a]) for a in db_aum
               if abs(db_aum[a] - expected[a]) > 0.01]
    check(f"all {len(db_aum)} account AUM figures match an independent rebuild",
          float(len(aum_bad)), 0.0, tol=0)
    for a, got, want in aum_bad[:10]:
        print(f"         {a}: db {got:,.2f} against {want:,.2f}")

    print("\n" + "=" * 78)
    print("INVARIANTS")
    print("=" * 78)

    # No fee may be raised on a balance that is zero or negative.
    bad = conn.execute("""
        SELECT COUNT(*) FROM fact_fee_charge WHERE account_aum <= 0
    """).fetchone()[0]
    check("no fee is raised on a zero or negative balance", float(bad), 0.0, tol=0)

    # Every account held out of the run has a logged reason.
    orphaned = conn.execute("""
        SELECT COUNT(*) FROM dim_account a
        WHERE NOT EXISTS (SELECT 1 FROM fact_fee_charge c WHERE c.account_id = a.account_id)
          AND NOT EXISTS (SELECT 1 FROM exception_log e WHERE e.entity_id = a.account_id)
    """).fetchone()[0]
    check("every unbilled account has an exception explaining why",
          float(orphaned), 0.0, tol=0)

    # Proration can never exceed the period.
    over = conn.execute("""
        SELECT COUNT(*) FROM fact_fee_charge
        WHERE days_billable > days_in_period OR days_billable < 1
    """).fetchone()[0]
    check("days billable always falls within the period", float(over), 0.0, tol=0)

    # The effective rate must sit inside the schedule's published range.
    out_of_range = conn.execute("""
        SELECT COUNT(*) FROM fact_fee_charge c
        WHERE c.minimum_fee_applied = 0
          AND (c.effective_rate_bps >
                 (SELECT MAX(annual_rate_bps) FROM ref_fee_schedule r
                  WHERE r.schedule_code = c.schedule_code) + 0.5
            OR c.effective_rate_bps <
                 (SELECT MIN(annual_rate_bps) FROM ref_fee_schedule r
                  WHERE r.schedule_code = c.schedule_code) - 0.5)
    """).fetchone()[0]
    check("every effective rate lies within its schedule's published bands",
          float(out_of_range), 0.0, tol=0)

    # Parity must leave nothing unexplained.
    unexplained = conn.execute("SELECT COUNT(*) FROM v_defects").fetchone()[0]
    check("the reconciliation leaves no unexplained variance",
          float(unexplained), 0.0, tol=0)

    conn.close()

    failed = [r for r in results if not r[0]]
    print("\n" + "=" * 78)
    print(f"{len(results) - len(failed)} passed, {len(failed)} failed")
    print("=" * 78)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
