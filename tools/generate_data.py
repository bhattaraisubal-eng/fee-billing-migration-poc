"""
Generate synthetic source data for the Advisory Fee Billing migration exercise.

Deterministic (seeded) so the dataset is reproducible. Deliberate ambiguities and
data-quality traps are planted at known account IDs -- see ANSWER_KEY.md.

Usage:  python3 tools/generate_data.py
Writes: data/input/{households,accounts,holdings,fee_schedule}.csv
"""

import csv
import os
import random
from datetime import date, timedelta

SEED = 20260930
QUARTER_END = date(2026, 9, 30)
QUARTER_START = date(2026, 7, 1)

OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "input")

random.seed(SEED)

# ---------------------------------------------------------------- fee schedule
# Tiers are expressed as [tier_min, tier_max) in USD, rate in annual basis points.
FEE_SCHEDULE = [
    # schedule_code, tier_seq, tier_min, tier_max, annual_rate_bps, minimum_fee_qtr, schedule_name
    ("STD",        1,          0,    1_000_000, 100, 250, "Standard Advisory"),
    ("STD",        2,  1_000_000,    5_000_000,  75, 250, "Standard Advisory"),
    ("STD",        3,  5_000_000,   10_000_000,  50, 250, "Standard Advisory"),
    ("STD",        4, 10_000_000,            0,  35, 250, "Standard Advisory"),
    ("INST",       1,          0,   10_000_000,  40,   0, "Institutional"),
    ("INST",       2, 10_000_000,   50_000_000,  25,   0, "Institutional"),
    ("INST",       3, 50_000_000,            0,  15,   0, "Institutional"),
    ("LEGACY2015", 1,          0,            0,  90,   0, "Grandfathered 2015"),
]

ADVISORS = ["ADV-101", "ADV-102", "ADV-103", "ADV-104", "ADV-105", "ADV-106"]

SECURITIES = [
    ("VTI",   "ETF"), ("VXUS",  "ETF"), ("BND",   "ETF"), ("AAPL",  "EQUITY"),
    ("MSFT",  "EQUITY"), ("BRK.B", "EQUITY"), ("TBILL-3M", "CASH_EQ"),
    ("MMKT-GOVT", "CASH_EQ"), ("MUNI-LADDER", "FIXED_INCOME"), ("AGG", "ETF"),
]

LAST_NAMES = [
    "Alvarez", "Brennan", "Castellanos", "Devereaux", "Eriksson", "Fontaine",
    "Gallagher", "Hartwell", "Ishikawa", "Jankowski", "Kaminski", "Lindqvist",
    "Maldonado", "Nakamura", "Oyelaran", "Pemberton", "Quintero", "Rasmussen",
    "Shaughnessy", "Thibodeaux", "Ubokwe", "Vasquez", "Whitlock", "Xiong",
    "Yarborough", "Zabrowski", "Antonelli", "Bergstrom", "Chaudhary", "Dimitrov",
    "Eastwood", "Falconer", "Ghosh", "Halvorsen", "Ikeda", "Jimenez",
    "Kowalczyk", "Larrabee", "Montgomery", "Nilsson", "Ostrander", "Petrakis",
    "Rinaldi", "Steadman", "Tulloch", "Underhill", "Villanueva", "Wainwright",
    "Yoshida", "Zimmerman", "Abernathy", "Bellweather", "Crowninshield",
    "Donnelly", "Engstrom", "Fairbanks", "Greenwald", "Hollingsworth",
    "Isaksen", "Juneau",
]

N_HOUSEHOLDS = 60


def quarter_days():
    return (QUARTER_END - QUARTER_START).days + 1


def build_households():
    """Households 1..60. billing_method says whether tiers should aggregate."""
    rows = []
    for i in range(1, N_HOUSEHOLDS + 1):
        hid = f"HH-{1000 + i}"
        name = f"{LAST_NAMES[(i - 1) % len(LAST_NAMES)]} Family"
        # Roughly a third of households are contracted for household-level tiering.
        method = "HOUSEHOLD" if i % 3 == 0 else "ACCOUNT"
        rows.append({
            "household_id": hid,
            "household_name": name,
            "billing_method": method,
            "relationship_manager": ADVISORS[i % len(ADVISORS)],
            "onboard_date": (date(2014, 1, 1) + timedelta(days=random.randint(0, 4200))).isoformat(),
        })
    # TRAP: one household is contracted HOUSEHOLD but the legacy flow never reads
    # this file at all, so the aggregation never happens anywhere.
    return rows


def build_accounts(households):
    """~150 accounts, 1-4 per household, plus planted edge-case accounts."""
    rows = []
    acct_seq = 1000

    for hh in households:
        n_acct = random.choices([1, 2, 3, 4], weights=[40, 35, 18, 7])[0]
        for _ in range(n_acct):
            acct_seq += 1
            acct_id = f"ACC-{acct_seq}"
            acct_type = random.choices(
                ["INDIVIDUAL", "JOINT", "IRA", "ROTH_IRA", "TRUST", "CORPORATE"],
                weights=[30, 20, 20, 10, 15, 5],
            )[0]
            schedule = "INST" if acct_type == "CORPORATE" and random.random() < 0.7 else "STD"
            rows.append({
                "account_id": acct_id,
                "household_id": hh["household_id"],
                "account_name": f"{hh['household_name'].replace(' Family', '')} {acct_type.title().replace('_', ' ')}",
                "account_type": acct_type,
                "fee_schedule_code": schedule,
                "open_date": (date(2015, 1, 1) + timedelta(days=random.randint(0, 4000))).isoformat(),
                "close_date": "",
                "status": "ACTIVE",
                "advisor_id": hh["relationship_manager"],
                "domicile_state": random.choice(["NY", "CT", "NJ", "MA", "CA", "TX", "FL", "IL"]),
            })

    by_id = {r["account_id"]: r for r in rows}

    # ---------------------------------------------------------------- TRAPS
    # T1  Account opened mid-quarter -- prorate or bill the full quarter?
    t1 = rows[7]["account_id"]
    by_id[t1]["open_date"] = "2026-08-19"

    # T2  Second mid-quarter open, opened on the last business day of the quarter.
    t2 = rows[23]["account_id"]
    by_id[t2]["open_date"] = "2026-09-29"

    # T3  Closed mid-quarter. Still held assets for 54 days -- is a final fee owed?
    t3 = rows[11]["account_id"]
    by_id[t3]["status"] = "CLOSED"
    by_id[t3]["close_date"] = "2026-08-24"

    # T4  Closed BEFORE the quarter started -- should not be billed at all.
    t4 = rows[31]["account_id"]
    by_id[t4]["status"] = "CLOSED"
    by_id[t4]["close_date"] = "2026-05-30"

    # T5  Fee schedule code that does not exist in fee_schedule.csv.
    t5 = rows[18]["account_id"]
    by_id[t5]["fee_schedule_code"] = "PREMIER"

    # T6  Grandfathered flat-rate schedule (legacy flow hard-codes STD tiers,
    #     so these get silently repriced).
    for idx in (5, 44, 77):
        by_id[rows[idx]["account_id"]]["fee_schedule_code"] = "LEGACY2015"

    # T7  Blank fee schedule code.
    t7 = rows[62]["account_id"]
    by_id[t7]["fee_schedule_code"] = ""

    # T8  Account ID carries a trailing space in the accounts file but not in
    #     holdings -- the join silently fails for this client.
    t8_old = rows[29]["account_id"]
    by_id[t8_old]["account_id"] = t8_old + " "

    # T9  Account with no holdings rows at all (funded late, or data gap).
    #     Flagged with _no_holdings so build_holdings skips it; the flag is
    #     stripped before the CSV is written.
    acct_seq += 1
    no_holdings_id = f"ACC-{acct_seq}"
    rows.append({
        "_no_holdings": True,
        "account_id": no_holdings_id,
        "household_id": households[4]["household_id"],
        "account_name": f"{households[4]['household_name'].replace(' Family', '')} Trust",
        "account_type": "TRUST",
        "fee_schedule_code": "STD",
        "open_date": "2026-09-15",
        "close_date": "",
        "status": "ACTIVE",
        "advisor_id": households[4]["relationship_manager"],
        "domicile_state": "NY",
    })

    # T10 Status value the flow's filter does not anticipate.
    t10 = rows[53]["account_id"]
    by_id[t10]["status"] = "PENDING_CLOSE"

    # T11 Duplicate account row (same account_id twice) -- join fans out.
    dup_src = dict(rows[9])
    dup_src["account_name"] = dup_src["account_name"] + " (dup)"
    rows.append(dup_src)

    return rows, {
        "mid_quarter_open": [t1, t2],
        "closed_in_quarter": [t3],
        "closed_before_quarter": [t4],
        "unknown_schedule": [t5],
        "legacy_schedule": [rows[5]["account_id"], rows[44]["account_id"], rows[77]["account_id"]],
        "blank_schedule": [t7],
        "whitespace_id": [t8_old + " "],
        "no_holdings": [no_holdings_id],
        "unexpected_status": [t10],
        "duplicate_account_row": [dup_src["account_id"]],
    }


def build_holdings(accounts):
    """Security-level positions. Requires a Summarize to roll up to account AUM."""
    rows = []
    for acct in accounts:
        acct_id = acct["account_id"].strip()
        if acct.get("_no_holdings"):
            continue  # T9: open account the custodian extract never covered
        if acct["status"] == "CLOSED" and acct["close_date"] < "2026-07-01":
            continue  # closed before the quarter: custodian reports nothing

        # Household wealth bands so tier boundaries actually get exercised.
        band = random.choices(
            ["small", "mid", "large", "xl"], weights=[45, 30, 18, 7]
        )[0]
        total = {
            "small": random.uniform(40_000, 900_000),
            "mid": random.uniform(950_000, 4_800_000),
            "large": random.uniform(5_100_000, 9_900_000),
            "xl": random.uniform(10_500_000, 48_000_000),
        }[band]

        n_pos = random.randint(3, 8)
        weights = [random.uniform(0.5, 3.0) for _ in range(n_pos)]
        wsum = sum(weights)
        picks = random.sample(SECURITIES, n_pos)
        for (ticker, asset_class), w in zip(picks, weights):
            mv = round(total * w / wsum, 2)
            rows.append({
                "account_id": acct_id,
                "as_of_date": QUARTER_END.isoformat(),
                "ticker": ticker,
                "asset_class": asset_class,
                "quantity": round(mv / random.uniform(20, 400), 4),
                "market_value": f"{mv:.2f}",
                "custodian": random.choice(["SCHWAB", "FIDELITY", "PERSHING"]),
            })

    by_acct = {}
    for r in rows:
        by_acct.setdefault(r["account_id"], []).append(r)
    active_ids = sorted(by_acct.keys())

    # ---------------------------------------------------------------- TRAPS
    traps = {}

    # T12 Holdings for an account that is not in accounts.csv -- the Alteryx
    #     inner join drops these silently and nobody gets billed.
    orphan_id = "ACC-9901"
    for ticker, asset_class in SECURITIES[:4]:
        rows.append({
            "account_id": orphan_id, "as_of_date": QUARTER_END.isoformat(),
            "ticker": ticker, "asset_class": asset_class, "quantity": 1500.0,
            "market_value": "612500.00", "custodian": "SCHWAB",
        })
    traps["orphan_holdings"] = [orphan_id]

    # T13 Position priced one day early -- the hard-coded date filter drops it,
    #     understating that account's AUM.
    stale_acct = active_ids[12]
    rows.append({
        "account_id": stale_acct, "as_of_date": "2026-09-29",
        "ticker": "MUNI-LADDER", "asset_class": "FIXED_INCOME", "quantity": 8200.0,
        "market_value": "842150.00", "custodian": "PERSHING",
    })
    traps["stale_as_of_date"] = [stale_acct]

    # T14 Exact duplicate position row -- double-counted by the Summarize.
    dup_target = active_ids[20]
    dup_row = dict(by_acct[dup_target][0])
    rows.append(dup_row)
    traps["duplicate_position"] = [dup_target]

    # T15 Short position / margin debit -> one negative row, account still net
    #     positive. Should the debit reduce billable AUM or be excluded?
    neg_acct = active_ids[33]
    neg_total = sum(float(r["market_value"]) for r in by_acct[neg_acct])
    rows.append({
        "account_id": neg_acct, "as_of_date": QUARTER_END.isoformat(),
        "ticker": "MARGIN-DEBIT", "asset_class": "LIABILITY", "quantity": -1.0,
        "market_value": f"{-round(neg_total * 0.28, 2):.2f}", "custodian": "FIDELITY",
    })
    traps["negative_position"] = [neg_acct]

    # T16 Account whose entire book nets to a negative balance.
    all_neg = active_ids[47]
    for r in by_acct[all_neg]:
        r["market_value"] = f"{-abs(float(r['market_value'])) * 1.4:.2f}"
    traps["net_negative_account"] = [all_neg]

    # T17 Null / empty market value.
    null_acct = active_ids[55]
    rows.append({
        "account_id": null_acct, "as_of_date": QUARTER_END.isoformat(),
        "ticker": "PRIVATE-FUND-LP", "asset_class": "ALTERNATIVE", "quantity": 1.0,
        "market_value": "", "custodian": "PERSHING",
    })
    traps["null_market_value"] = [null_acct]

    # T18 Zero-balance account -- still open, nothing in it. Minimum fee anyway?
    zero_acct = active_ids[61]
    for r in by_acct[zero_acct]:
        r["market_value"] = "0.00"
    traps["zero_balance"] = [zero_acct]

    # T19 Account landing just over a tier boundary -- blended vs cliff pricing
    #     differ by thousands of dollars here.
    cliff_acct = active_ids[8]
    pos = by_acct[cliff_acct]
    target = 1_012_000.00
    scale = target / sum(float(r["market_value"]) for r in pos)
    for r in pos:
        r["market_value"] = f"{float(r['market_value']) * scale:.2f}"
    traps["tier_boundary"] = [cliff_acct]

    # T20 Tiny account where the computed fee falls under the quarterly minimum.
    tiny_acct = active_ids[70]
    pos = by_acct[tiny_acct]
    target = 11_500.00
    scale = target / sum(float(r["market_value"]) for r in pos)
    for r in pos:
        r["market_value"] = f"{float(r['market_value']) * scale:.2f}"
    traps["below_minimum_fee"] = [tiny_acct]

    # T21 A cash-equivalent-only account -- should cash be fee-billable at all?
    cash_acct = active_ids[80]
    for r in by_acct[cash_acct]:
        r["ticker"] = "MMKT-GOVT"
        r["asset_class"] = "CASH_EQ"
    traps["cash_only_account"] = [cash_acct]

    rows.sort(key=lambda r: (r["account_id"], r["as_of_date"], r["ticker"]))
    return rows, traps


def write_csv(path, rows, fieldnames):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"  {os.path.relpath(path):<46} {len(rows):>6} rows")


def main():
    households = build_households()
    accounts, acct_traps = build_accounts(households)
    holdings, hold_traps = build_holdings(accounts)

    print(f"Quarter {QUARTER_START} .. {QUARTER_END} ({quarter_days()} days)\n")

    write_csv(os.path.join(OUT_DIR, "households.csv"), households,
              ["household_id", "household_name", "billing_method",
               "relationship_manager", "onboard_date"])

    write_csv(os.path.join(OUT_DIR, "accounts.csv"), accounts,
              ["account_id", "household_id", "account_name", "account_type",
               "fee_schedule_code", "open_date", "close_date", "status",
               "advisor_id", "domicile_state"])

    write_csv(os.path.join(OUT_DIR, "holdings.csv"), holdings,
              ["account_id", "as_of_date", "ticker", "asset_class", "quantity",
               "market_value", "custodian"])

    write_csv(os.path.join(OUT_DIR, "fee_schedule.csv"),
              [dict(zip(["schedule_code", "tier_seq", "tier_min", "tier_max",
                         "annual_rate_bps", "minimum_fee_qtr", "schedule_name"], r))
               for r in FEE_SCHEDULE],
              ["schedule_code", "tier_seq", "tier_min", "tier_max",
               "annual_rate_bps", "minimum_fee_qtr", "schedule_name"])

    traps = {**acct_traps, **hold_traps}
    print(f"\n{len(traps)} trap categories planted (see ANSWER_KEY.md)")


if __name__ == "__main__":
    main()
