# Legacy workflow: `FeeBilling_Quarterly_v7_FINAL.yxmd`

What Ops handed over. Author left the firm in 2023; no other documentation exists.
This file records only **what the workflow does**, not what it should do — the
analysis of that belongs in the as-is assessment and gap log.

- **Owner of record:** R. Kaminski (departed)
- **Schedule:** run manually by Ops on the first business day after quarter end
- **Inputs:** two CSVs from `\\corpfs01\Ops\Billing\input\`
- **Outputs:** `billing_2026Q3.csv`, `exceptions_2026Q3.csv`

## Tool-by-tool

| Tool ID | Type | Configuration as found |
|---|---|---|
| 1 | Input Data | `accounts.csv`, header row, 254-char field length |
| 2 | Input Data | `holdings.csv`, header row, **IgnoreErrors = True** |
| 3 | Filter | `[as_of_date] = "2026-09-30"` — date is hard-coded, edited each quarter |
| 4 | Summarize | Group by `account_id`; Sum `market_value` → `total_aum`; Count `ticker` → `position_count` |
| 5 | Filter | `[status] = "ACTIVE"` |
| 6 | Join | `account_id` = `account_id`. Only the **J (inner)** anchor is connected; L and R anchors are unconnected |
| 7 | Formula | `annual_rate_bps` = nested IF on `[total_aum]`: `<1M → 100`, `<5M → 75`, `<10M → 50`, else `35` |
| 8 | Formula | `gross_fee` = `Round([total_aum] * [annual_rate_bps] / 10000 / 4, 0.01)`<br>`billable_fee` = `IIF([gross_fee] < 250, 250, [gross_fee])`<br>`billing_period` = `"2026Q3"` |
| 9 | Select | Keeps 10 fields for the billing layout; drops `position_count`, `open_date`, `close_date`, `status`, `account_type`, `domicile_state` |
| 10 | Filter | `[billable_fee] > 0` |
| 11 | Sort | `household_id`, then `account_id`, ascending |
| 12 | Output Data | True branch → `billing_2026Q3.csv` |
| 13 | Output Data | False branch → `exceptions_2026Q3.csv` |
| 14 | Comment box | See below |

## Flow shape

```
accounts.csv ──▶ [5] Filter status=ACTIVE ──┐
                                            ├──▶ [6] Join on account_id (J only)
holdings.csv ─▶ [3] Filter as_of ─▶ [4] Summarize ──┘
                                            │
                                            ▼
                        [7] rate ─▶ [8] fee + minimum ─▶ [9] Select
                                            │
                                            ▼
                                 [10] Filter billable_fee > 0
                                      │              │
                                   True│              │False
                                      ▼              ▼
                            [11] Sort ─▶ billing   exceptions
```

## Comment box found on the canvas (Tool 14), verbatim

> NOTE 2019-04-11 (RK): household-level tiering is handled downstream by Ops in
> the billing recon workbook. Do NOT aggregate here. Minimum fee waiver list is
> maintained manually — see Ops shared drive. TODO: pull rates from
> fee_schedule.csv instead of hard-coding (ticket BIL-412)

## Observations recorded without interpretation

- `households.csv` and `fee_schedule.csv` exist in the input folder but **are not
  referenced by any tool** in this workflow.
- The rates in Tool 7 are literal values, not a lookup.
- Tool 6 discards unmatched records from both sides with no logging.
- There is no proration logic anywhere in the workflow.
- The quarter divisor in Tool 8 is a fixed `4`.
- Ticket BIL-412 is referenced but was never located in the tracker.

---

### A note on provenance (keep this in the repo; it is the honest framing)

This `.yxmd` was authored by hand for the exercise rather than exported from
Alteryx Designer. It is structurally faithful XML — plugin names, anchors,
connections, and formula expressions are real — so it reads and parses exactly
like a production file, which is the point: on a real migration you inherit the
XML, not a tutorial. It has **not** been round-tripped through Designer, so do
not claim it was. If you install the 30-day Designer trial, rebuild this flow
tool-for-tool there, re-save, and swap the file in; then it is genuinely an
Alteryx export and you can say so.
