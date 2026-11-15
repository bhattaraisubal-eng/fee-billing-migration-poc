"""
Faithful re-implementation of FeeBilling_Quarterly_v7_FINAL.yxmd.

This exists so the migration has a reproducible legacy baseline to reconcile
against without needing an Alteryx licence on every machine. It mirrors Alteryx
engine semantics deliberately, including the behaviours that are arguably wrong:

  * Filter comparisons are string comparisons on the raw CSV text.
  * Join is an inner join on the untrimmed, case-sensitive account_id.
  * Only the J anchor is connected, so unmatched rows from both sides vanish
    with no record anywhere.
  * Summarize Sum skips nulls rather than returning null.
  * Duplicate keys on either side of the Join fan out.
  * Tier rates are the literal values from Tool 7, not fee_schedule.csv.
  * The minimum-fee IIF in Tool 8 runs BEFORE the > 0 filter in Tool 10.

Do not "fix" anything here. This file's only job is to reproduce what Ops runs
today. Corrections belong in the target SQL build.

Usage:  python3 tools/run_legacy_workflow.py
Writes: data/legacy_output/{billing,exceptions}_2026Q3.csv
        data/legacy_output/run_log.txt
"""

import csv
import os

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IN_DIR = os.path.join(BASE, "data", "input")
OUT_DIR = os.path.join(BASE, "data", "legacy_output")

AS_OF_HARDCODED = "2026-09-30"   # Tool 3
BILLING_PERIOD = "2026Q3"        # Tool 8

BILLING_FIELDS = [
    "account_id", "household_id", "account_name", "fee_schedule_code",
    "billing_period", "total_aum", "annual_rate_bps", "gross_fee",
    "billable_fee", "advisor_id",
]

log_lines = []


def log(tool, msg):
    line = f"{tool:<28} {msg}"
    log_lines.append(line)
    print(line)


def read_csv(name):
    with open(os.path.join(IN_DIR, name), newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def alteryx_round(value, places=0.01):
    """Alteryx Round(x, 0.01) -- round half away from zero, not banker's."""
    import decimal
    d = decimal.Decimal(str(value)).quantize(
        decimal.Decimal("0.01"), rounding=decimal.ROUND_HALF_UP
    )
    return float(d)


def to_number(raw):
    """Input Data with IgnoreErrors=True: unparseable text becomes null."""
    if raw is None:
        return None
    s = raw.strip()
    if s == "":
        return None
    try:
        return float(s)
    except ValueError:
        return None


def tool_7_rate(total_aum):
    """Tool 7. Nested IF, hard-coded, cliff pricing on the whole balance."""
    if total_aum < 1_000_000:
        return 100
    elif total_aum < 5_000_000:
        return 75
    elif total_aum < 10_000_000:
        return 50
    else:
        return 35


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # ---- Tool 1 / Tool 2 : Input Data -----------------------------------
    accounts = read_csv("accounts.csv")
    holdings = read_csv("holdings.csv")
    log("[1] Input accounts.csv", f"{len(accounts)} records")
    log("[2] Input holdings.csv", f"{len(holdings)} records")

    # ---- Tool 3 : Filter [as_of_date] = "2026-09-30" ---------------------
    h_true = [r for r in holdings if r["as_of_date"] == AS_OF_HARDCODED]
    h_false = len(holdings) - len(h_true)
    log("[3] Filter as_of_date", f"T: {len(h_true)}  F: {h_false} (F anchor unconnected)")

    # ---- Tool 4 : Summarize ---------------------------------------------
    agg = {}
    for r in h_true:
        key = r["account_id"]                      # no trim: Alteryx does not trim
        slot = agg.setdefault(key, {"total_aum": None, "position_count": 0})
        mv = to_number(r["market_value"])
        if mv is not None:                         # Sum skips nulls
            slot["total_aum"] = (slot["total_aum"] or 0.0) + mv
        if r["ticker"].strip() != "":              # Count skips nulls
            slot["position_count"] += 1
    summarized = [
        {"account_id": k, "total_aum": v["total_aum"], "position_count": v["position_count"]}
        for k, v in agg.items()
    ]
    log("[4] Summarize", f"{len(summarized)} records (grouped from {len(h_true)})")

    # ---- Tool 5 : Filter [status] = "ACTIVE" ----------------------------
    a_true = [r for r in accounts if r["status"] == "ACTIVE"]
    log("[5] Filter status=ACTIVE",
        f"T: {len(a_true)}  F: {len(accounts) - len(a_true)} (F anchor unconnected)")

    # ---- Tool 6 : Join on account_id, J anchor only ---------------------
    right_index = {}
    for r in summarized:
        right_index.setdefault(r["account_id"], []).append(r)

    joined = []
    left_unmatched = 0
    matched_right_keys = set()
    for a in a_true:
        matches = right_index.get(a["account_id"], [])
        if not matches:
            left_unmatched += 1
            continue
        matched_right_keys.add(a["account_id"])
        for m in matches:
            row = dict(a)
            row["total_aum"] = m["total_aum"]
            row["position_count"] = m["position_count"]
            joined.append(row)
    right_unmatched = len(right_index) - len(matched_right_keys)
    log("[6] Join account_id",
        f"J: {len(joined)}  L dropped: {left_unmatched}  R dropped: {right_unmatched}")

    # ---- Tool 7 / Tool 8 : Formula --------------------------------------
    for row in joined:
        aum = row["total_aum"]
        if aum is None:
            aum = 0.0                              # null arithmetic -> treated as 0
        row["total_aum"] = aum
        row["annual_rate_bps"] = tool_7_rate(aum)
        row["gross_fee"] = alteryx_round(aum * row["annual_rate_bps"] / 10000 / 4)
        row["billable_fee"] = 250.0 if row["gross_fee"] < 250 else row["gross_fee"]
        row["billing_period"] = BILLING_PERIOD
    log("[7] Formula rate", f"{len(joined)} records")
    log("[8] Formula fee + minimum", f"{len(joined)} records")

    # ---- Tool 9 : Select -------------------------------------------------
    shaped = [{f: row.get(f, "") for f in BILLING_FIELDS} for row in joined]
    log("[9] Select", f"{len(shaped)} records, {len(BILLING_FIELDS)} fields")

    # ---- Tool 10 : Filter [billable_fee] > 0 -----------------------------
    billable = [r for r in shaped if float(r["billable_fee"]) > 0]
    exceptions = [r for r in shaped if not float(r["billable_fee"]) > 0]
    log("[10] Filter billable_fee>0", f"T: {len(billable)}  F: {len(exceptions)}")

    # ---- Tool 11 : Sort --------------------------------------------------
    billable.sort(key=lambda r: (r["household_id"], r["account_id"]))

    # ---- Tool 12 / Tool 13 : Output Data ---------------------------------
    for fname, rows in (("billing_2026Q3.csv", billable),
                        ("exceptions_2026Q3.csv", exceptions)):
        path = os.path.join(OUT_DIR, fname)
        with open(path, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=BILLING_FIELDS)
            w.writeheader()
            for r in rows:
                out = dict(r)
                for money in ("total_aum", "gross_fee", "billable_fee"):
                    out[money] = f"{float(out[money]):.2f}"
                w.writerow(out)
        log(f"[out] {fname}", f"{len(rows)} records written")

    total_billed = sum(float(r["billable_fee"]) for r in billable)
    summary = (
        f"\nRun summary\n"
        f"  accounts in:          {len(accounts)}\n"
        f"  holdings in:          {len(holdings)}\n"
        f"  accounts billed:      {len(billable)}\n"
        f"  exceptions:           {len(exceptions)}\n"
        f"  total fees invoiced:  ${total_billed:,.2f}\n"
    )
    print(summary)
    log_lines.append(summary)

    with open(os.path.join(OUT_DIR, "run_log.txt"), "w", encoding="utf-8") as fh:
        fh.write("FeeBilling_Quarterly_v7_FINAL.yxmd -- simulated run\n")
        fh.write("=" * 64 + "\n")
        fh.write("\n".join(log_lines) + "\n")


if __name__ == "__main__":
    main()
