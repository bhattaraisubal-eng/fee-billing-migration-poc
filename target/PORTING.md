# Porting the proof to SQL Server, Azure SQL or Fabric

> **Fabric is done.** See [`fabric/README.md`](../fabric/README.md) for the
> completed port. This file remains as the general guide for SQL Server and
> Azure SQL.

The build runs on SQLite so the proof of concept needs no server and no licence:
clone, run one command, see the result. The SQL is written in set-based ANSI
style — CTEs, window functions, `CASE`, `FULL OUTER JOIN` — so the move is
mechanical rather than a rewrite. This file lists what actually changes.

The target platform is an **assumption**, not a given. "Microsoft" could mean
Azure SQL, Synapse, Fabric with a warehouse or lakehouse, or SQL Server on
premises. The logic is the same in all of them; orchestration is not.

## Direct substitutions

| SQLite | T-SQL | Notes |
|---|---|---|
| `JULIANDAY(a) - JULIANDAY(b)` | `DATEDIFF(day, b, a)` | Used in `v_account_days`. T-SQL counts boundaries crossed, so the `+ 1` in the day count is still needed but verify it against one hand-worked case |
| `MAX(x, y)` / `MIN(x, y)` scalar form | `IIF(x > y, x, y)` or `GREATEST` / `LEAST` on Azure SQL and Fabric | SQLite overloads `MAX`/`MIN` as both scalar and aggregate. T-SQL does not. This appears in the tier arithmetic and the day count and is the single most common porting error |
| `PRINTF('%.2f', x)` | `FORMAT(x, 'N2')` or `CONVERT(varchar, CAST(x AS decimal(18,2)))` | Exception detail strings only, never arithmetic |
| `GROUP_CONCAT(DISTINCT x)` | `STRING_AGG(DISTINCT x, ',')` | Used in `v_account_reasons` |
| `CAST(x AS REAL)` | `TRY_CAST(x AS decimal(18,2))` | See money types below |
| `TEXT` dates | `date` | Staging stays text; conform with `TRY_CONVERT(date, x, 23)` |
| `CREATE VIEW` | unchanged | Or materialise as tables if the optimiser prefers it at volume |

## Money must not be floating point

The proof uses `REAL` because SQLite has no decimal type. In the target, every
monetary column becomes **`decimal(18, 2)`** and every rate **`decimal(9, 4)`**.
Fee calculation on binary floating point accumulates error that shows up as
one-cent invoice disputes, and `ROUND` on a float is not reliably half-up.

Rounding also differs. SQLite `ROUND` is half-away-from-zero; T-SQL `ROUND` is
too, but `CAST` to decimal truncates. The intent throughout is half-up on the
final account fee, rounded once. `testing/test_fee_math.py` asserts this, so
re-run it against the ported build rather than assuming.

## What has no SQLite equivalent and should be added

These were left out to keep the proof runnable, not because they are optional.

- **Constraints.** Foreign keys declared but unenforced here; enforce them.
  `CHECK (billable_fee >= 0)`, `CHECK (days_billable BETWEEN 0 AND days_in_period)`.
- **Temporal history on `dim_account`.** A system-versioned table, or effective
  dating on the fee schedule, so a schedule change is a dated row and a prior
  period can be recalculated as it stood. Fee billing is retroactively
  auditable by nature and this proof is not.
- **Idempotent reruns.** Each script starts with `DELETE`. In the target, key
  the run (`billing_run_id`) and delete only that run's rows, so a rerun cannot
  destroy a prior period.
- **Transactional boundary.** Wrap the build in one transaction so a failure
  mid-pipeline cannot leave a half-populated invoice table.
- **Orchestration.** The build order lives in a Python script here. In the
  target that is a Data Factory or Fabric pipeline, with the billing period as
  a parameter rather than a literal — see GAP-08.

## Fabric-specific

- Lakehouse SQL endpoints are read-only; the write path is Spark or a warehouse.
  If the target is a lakehouse, staging lands as Delta tables and the
  transformation layer moves to a warehouse or to notebooks.
- `MERGE` support and identity columns differ between warehouse and lakehouse.
  Keyed `DELETE` plus `INSERT`, as used here, works in both.

## Order of work

1. Port the schema with proper decimal types and constraints
2. Port `02` to `05` with the substitutions above
3. Re-run `testing/test_fee_math.py` against the ported build — the independent
   calculator is platform-agnostic and is the check that the port preserved the
   arithmetic
4. Re-run the parity reconciliation and confirm zero unexplained variances
5. Only then wire up orchestration

Step 3 is the one worth insisting on. A port that changes a fee by a cent has
changed a client's invoice.
