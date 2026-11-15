"""
Compare a billing export from Fabric against the verified baseline.

After running etl.usp_run_quarter in Fabric, export the invoice view to CSV:

    SELECT * FROM core.v_billing_output WHERE billing_period = '2026Q3';

(In the Fabric SQL editor, run the query and use Download > CSV; or have the
pipeline's Copy activity write it to the lakehouse.) Then:

    python3 tools/compare_fabric_output.py path/to/fabric_billing.csv

It checks every account and every fee against data/target_output/
billing_2026Q3.csv, the output of the build that test_fee_math.py verifies.
A clean result here is the proof that the deployed Fabric code, not just its
logic, matches.
"""

import csv
import os
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(BASE, "data", "target_output", "billing_2026Q3.csv")


def load(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        sys.exit(f"{path} is empty")
    cols = {c.lower(): c for c in rows[0]}
    for need in ("account_id", "billable_fee"):
        if need not in cols:
            sys.exit(f"{path} has no {need} column; columns are {list(rows[0])}")
    out = {}
    for r in rows:
        acct = r[cols["account_id"]].strip().upper()
        if acct in out:
            sys.exit(f"{path}: {acct} appears more than once -- one fee per account is violated")
        out[acct] = float(r[cols["billable_fee"]])
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    fabric, baseline = load(sys.argv[1]), load(BASELINE)

    missing = sorted(set(baseline) - set(fabric))
    extra = sorted(set(fabric) - set(baseline))
    diffs = sorted((a, fabric[a], baseline[a]) for a in set(fabric) & set(baseline)
                   if abs(fabric[a] - baseline[a]) > 0.005)

    print(f"Fabric:   {len(fabric):>4} accounts  ${sum(fabric.values()):>14,.2f}")
    print(f"Baseline: {len(baseline):>4} accounts  ${sum(baseline.values()):>14,.2f}\n")
    for label, items in (("missing from Fabric", missing), ("only in Fabric", extra)):
        if items:
            print(f"{len(items)} {label}: {', '.join(items[:15])}")
    for a, f, b in diffs[:25]:
        print(f"  {a}: fabric {f:,.2f}  baseline {b:,.2f}  diff {f - b:+,.2f}")

    if missing or extra or diffs:
        print(f"\nNOT MATCHED: {len(missing)} missing, {len(extra)} extra, "
              f"{len(diffs)} fee differences")
        return 1
    print("MATCHED: every account and every fee agrees to the cent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
