# Fee billing on Microsoft Fabric

`FeeBilling_Quarterly_v7_FINAL.yxmd` migrated to a Fabric Lakehouse and
Warehouse. The logic is the same corrected logic as the SQLite proof in
`target/`, rewritten in T-SQL for Fabric Warehouse and verified against it
account by account.

**Status:** the T-SQL logic is verified locally. It has not yet run in a Fabric
tenant. See [Verification](#verification) for exactly what is proven and what is
not.

---

## 1. Reverse-engineering: every Alteryx tool and what replaces it

The workflow has 13 tools and a comment box. All of them are accounted for.

| Tool | Alteryx did | Defect | Fabric replacement | File |
|---|---|---|---|---|
| 1 | Input `accounts.csv` | — | Lakehouse `Files/` + `COPY INTO stg.accounts`, all varchar | `02_load_stage.sql` |
| 2 | Input `holdings.csv`, `IgnoreErrors=True` | Bad values coerced or dropped on read | `COPY INTO` into varchar staging; bad values become exceptions `E24`/`E25` | `02`, `04` |
| 3 | Filter `[as_of_date] = "2026-09-30"` | Hard-coded; dropped a stale-dated $842k position | Latest price in the period, `@valuation_date` parameter | `04`, `07` |
| 4 | Summarize to account AUM | Double-counted an exact duplicate row | Dedupe identical rows, sum all lots on the price date | `04` |
| 5 | Filter `[status] = "ACTIVE"` | Dropped closed-in-period and `PENDING_CLOSE` accounts | Explicit billability rule on dates and status | `03` |
| 6 | Join, J anchor only | Discarded unmatched records unlogged | Explicit joins; `E01`, `E02`, `E03` for every unmatched record | `03`, `04` |
| 7 | Formula: nested IF rate | Hard-coded rates, cliff tiers | `ref.fee_schedule`, marginal tiers by schedule code | `05` |
| 8 | Formula: `/ 4`, minimum $250 | Fixed divisor; minimum before the zero check | Days held / days in year; minimum after the zero check | `05` |
| 9 | Select 10 fields | — | `core.v_billing_output` view | `09` |
| 10 | Filter `[billable_fee] > 0` | Could never exclude anything | Zero and negative AUM handled before any fee; exceptions populate | `04`, `05` |
| 11 | Sort | — | Consumers sort; views carry no `ORDER BY` | `09` |
| 12 | Output `billing_2026Q3.csv` | — | `core.v_billing_output`, `releasable` flag, pipeline export | `09` |
| 13 | Output `exceptions_2026Q3.csv` | Always empty | `audit.v_exceptions_open`: 33 rows this quarter | `09` |
| 14 | Comment box (2019) | Household tiering "done in Ops spreadsheet"; ticket BIL-412 never done | GAP-03, GAP-02 and GAP-27 in `analysis/GAP_LOG.md` | — |

`households.csv` and `fee_schedule.csv` were in the input folder and no tool
read them. Both are inputs now.

## 2. Architecture

```
Fabric workspace: Fee Billing
│
├── Lakehouse  lh_billing
│     Files/billing/2026Q3/      accounts, households, holdings,
│                                fee_schedule, legacy_billing  (CSV)
│     Files/outbound/2026Q3/     billing export, written by the pipeline
│
├── Warehouse  wh_billing
│     stg    raw landing, all varchar          02_load_stage.sql
│     ref    fee schedule, billing periods     03
│     core   account, household, AUM, fees     03, 04, 05
│     audit  exception_log, run_log            every step
│     recon  legacy baseline, parity           06
│     etl    stored procedures                 03-07
│
├── Pipeline  pl_fee_billing_quarterly         (section 4)
│
└── Power BI  (optional) report on the three views in 09
```

A Warehouse rather than a Lakehouse plus notebooks, because the logic is set-
based SQL, Billing Operations can read T-SQL, and a stored procedure gives one
transactional entry point. The Lakehouse holds only files.

## 3. Deploy and run (about 45 minutes the first time)

**Create the items**
1. In a Fabric workspace, create a Lakehouse `lh_billing` and a Warehouse
   `wh_billing`.
2. In the lakehouse, create the folder `Files/billing/2026Q3/` and upload:
   - `data/input/accounts.csv`, `households.csv`, `holdings.csv`, `fee_schedule.csv`
   - `data/legacy_output/billing_2026Q3.csv`, **renamed to `legacy_billing.csv`**

**Build the warehouse objects.** Open the warehouse's SQL editor, or connect
from SSMS or VS Code with the warehouse's SQL connection string. Run in order:

| Order | File | Creates |
|---|---|---|
| 1 | `00_schemas.sql` | six schemas |
| 2 | `01_tables.sql` | 15 tables |
| 3 | `01b_constraints.sql` | declared keys, `NOT ENFORCED` |
| 4 | `03_etl_conform.sql` | `usp_load_reference`, `usp_conform` |
| 5 | `04_etl_build_aum.sql` | `usp_build_aum` |
| 6 | `05_etl_calc_fees.sql` | `usp_calc_fees` |
| 7 | `06_etl_reconcile.sql` | `usp_reconcile` |
| 8 | `07_etl_run_quarter.sql` | `usp_run_quarter` |
| 9 | `09_output_views.sql` | three output views |

The files use `GO` between objects, which SSMS and VS Code honour. If the Fabric
web editor rejects `GO`, run each `CREATE PROCEDURE` or `CREATE VIEW` block on
its own.

**Run the quarter**
1. Edit `02_load_stage.sql`: replace `<workspace>` and `<lakehouse>` in the five
   paths. Right-click a file in the lakehouse and choose Properties for the exact
   path. Run it, and check the counts: 121, 60, 655, 8, 116.
2. Run:
   ```sql
   EXEC etl.usp_run_quarter
        @billing_period = '2026Q3',
        @period_start   = '2026-07-01',
        @period_end     = '2026-09-30',
        @valuation_date = '2026-09-30';
   ```
   Expect one row back: 115 accounts, $717,153.72, 10 blocking exceptions,
   0 unexplained variances.
3. Run `08_checks.sql`. Every control should show 0 failures.
4. Prove the deployment, not just the logic:
   ```sql
   SELECT * FROM core.v_billing_output WHERE billing_period = '2026Q3';
   ```
   Download the result as CSV, then run locally:
   ```bash
   python3 tools/compare_fabric_output.py fabric_billing.csv
   ```
   It should print `MATCHED: every account and every fee agrees to the cent.`

## 4. Pipeline design: `pl_fee_billing_quarterly`

This replaces "Ops runs the workflow by hand on the first business day."

| # | Activity | Type | Detail |
|---|---|---|---|
| — | Parameters | — | `billing_period`, `period_start`, `period_end`, `valuation_date` |
| 1 | Load staging | Script | `02_load_stage.sql`, with the folder path built from `billing_period` |
| 2 | Run quarter | Stored procedure | `etl.usp_run_quarter`, the four parameters |
| 3 | Read gate | Lookup | latest `audit.run_log` row for the period |
| 4 | Gate | If condition | `unexplained_variances > 0` or `outcome <> 'SUCCEEDED'` |
| 4a | Stop | Fail | when the gate fails: no export, no invoices |
| 4b | Export | Copy data | `core.v_billing_output` where `releasable = 1` to `Files/outbound/<period>/billing.csv` |
| 5 | Notify | Teams or Outlook | counts of billed accounts and of BLOCKING and REVIEW exceptions, to Billing Ops |

**Trigger:** a quarterly schedule, or an event when the holdings file lands.
**Releasable** means no BLOCKING exception is open on the account. Held invoices
stay in the warehouse until Operations clears them, then a rerun exports them.

The pipeline is described here rather than exported as JSON. Pipeline JSON is
tied to a workspace and its connection IDs, so a hand-written definition would
not import cleanly. Build it in the pipeline canvas from this table; it takes
about 20 minutes.

## 5. Fabric-specific traps this code handles

These are where a straight port from Alteryx, or from SQL Server habits, goes
wrong.

1. **Trailing spaces are invisible to `=` and `LEN()`.** In T-SQL,
   `'ACC-1030 ' = 'ACC-1030'` is true. The defect that broke the Alteryx join
   would disappear from a naive key check, so the check also compares
   `DATALENGTH`.
2. **The warehouse collation is case-sensitive by default.** Keys are
   upper-cased before every join.
3. **Keys are `NOT ENFORCED`.** A duplicate can be inserted. Uniqueness comes from
   the dedupe in the procedures, and `08_checks.sql` verifies it after every run.
4. **Decimal scale gets cut back on large products.** When a decimal result would
   exceed 38 digits, the engine reduces the scale toward 6 places. Every fee
   expression multiplies before it divides so pennies survive on large balances.
5. **`_` is a wildcard in `LIKE`.** Every reason code contains underscores, so
   attribution uses exact-match flags rather than `LIKE '%E09_...%'`.
6. **There is no row order after `COPY INTO`.** "Keep the first duplicate" is
   defined by an explicit `ORDER BY`, not by position in the file.
7. **`TRY_CAST` fails quietly.** An unparseable date becomes `NULL`. Exceptions
   `E24` and `E25` record it, so a bad value cannot silently change a fee.
8. **Unsupported types.** No `nvarchar`, `money` or `datetime` in persisted
   tables; this code uses `varchar`, `decimal` and `date` / `datetime2(6)`.
9. **`COPY INTO` from a OneLake path is a preview feature.** If it is not
   available in your tenant, use a Copy activity with the same five sources.

## Verification

**Proven locally** (`python3 tools/verify_fabric_sql.py`):
- Every file parses as T-SQL.
- The table DDL and all five step procedures, transpiled from T-SQL to DuckDB
  and executed on the same extracts, reproduce the verified SQLite build:
  - the same 115 accounts
  - every fee to the cent, $717,153.72 in total
  - the same 33 exceptions by reason code
  - the same gap attribution on every account
  - zero unexplained variances
- All seven controls in `08_checks.sql` pass.

**Not proven until it runs in Fabric:**
- `COPY INTO` from OneLake paths, and the file paths themselves.
- The orchestrator `usp_run_quarter`. Its `TRY`/`CATCH` and transaction handling
  cannot be modelled by the transpiler, so it was reviewed, not executed.
- Fabric's own decimal arithmetic. DuckDB's differs, and the multiply-before-
  divide ordering is meant to make that irrelevant, but only a run confirms it.
- `DATALENGTH`. The harness substitutes an equivalent because DuckDB lacks the
  function.
- `GO` handling in the Fabric web editor.

Step 4 of section 3 closes all of these. `compare_fabric_output.py` checks the
deployed code's actual output, not its logic.

**What the cross-check found.** Writing the logic a second time exposed a bug in
the first build: it kept one lot per ticker and dropped the rest, and the
reconciliation had attributed the resulting variance to a different gap. Both
builds are fixed, and a test now rebuilds AUM independently from the holdings
file. The top-level README covers this under "A defect in my own first build".
