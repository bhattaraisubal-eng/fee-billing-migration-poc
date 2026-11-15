-- =============================================================================
-- 04_fee_calc.sql -- the fee calculation
--
-- Four corrections to the legacy logic, each traced to a gap:
--   GAP-01  marginal (blended) tiers, not one rate on the whole balance
--   GAP-02  rates read from ref_fee_schedule by the account's own schedule code
--   GAP-03  households contracted for household tiering are aggregated
--   GAP-06/07  fees accrue on actual days held over actual days in the year
-- =============================================================================

DELETE FROM fact_fee_charge;

-- --------------------------------------------- days the account was billable ---
-- GAP-07: an account open for two days of the quarter is billed for two days.
-- GAP-16: an account closed mid-quarter is billed to its closure date.
DROP VIEW IF EXISTS v_account_days;
CREATE VIEW v_account_days AS
SELECT
    p.billing_period,
    a.account_id,
    a.household_id,
    a.fee_schedule_code,
    p.days_in_period,
    p.days_in_year,
    MAX(0, CAST(
        JULIANDAY(MIN(p.period_end, COALESCE(a.close_date, p.period_end)))
      - JULIANDAY(MAX(p.period_start, COALESCE(a.open_date, p.period_start)))
      + 1 AS INTEGER)) AS days_billable
FROM dim_account a
CROSS JOIN ref_billing_period p
WHERE a.is_billable = 1;

-- ------------------------------------------------- which entity sets the tier ---
-- GAP-03: households.csv was never read by the legacy workflow, so every
-- household was priced per account. Twenty of sixty are contracted otherwise.
--
-- Aggregation is applied only where every account in the household shares one
-- schedule code. A household spanning two schedules has no single tier ladder
-- to apply, so it is held for the business to resolve rather than guessed at.
DROP VIEW IF EXISTS v_billing_entity;
CREATE VIEW v_billing_entity AS
WITH billable AS (
    SELECT d.account_id, d.household_id, d.fee_schedule_code, d.billing_period,
           f.market_value AS account_aum
    FROM v_account_days d
    JOIN fact_account_aum f
      ON f.account_id = d.account_id AND f.billing_period = d.billing_period
    WHERE f.market_value > 0          -- GAP-05: nothing to tier on otherwise
),
hh AS (
    SELECT
        b.billing_period,
        b.household_id,
        COUNT(DISTINCT b.fee_schedule_code) AS schedule_variants,
        SUM(b.account_aum)                  AS household_aum
    FROM billable b
    GROUP BY b.billing_period, b.household_id
)
SELECT
    b.billing_period,
    b.account_id,
    b.household_id,
    b.fee_schedule_code,
    b.account_aum,
    CASE WHEN h.billing_method = 'HOUSEHOLD' AND hh.schedule_variants = 1
         THEN 'HOUSEHOLD' ELSE 'ACCOUNT' END                        AS billing_entity,
    CASE WHEN h.billing_method = 'HOUSEHOLD' AND hh.schedule_variants = 1
         THEN hh.household_aum ELSE b.account_aum END               AS tiering_basis_aum,
    CASE WHEN h.billing_method = 'HOUSEHOLD' AND hh.schedule_variants = 1
         THEN b.account_aum / hh.household_aum ELSE 1.0 END         AS allocation_share
FROM billable b
JOIN hh ON hh.household_id = b.household_id AND hh.billing_period = b.billing_period
LEFT JOIN dim_household h ON h.household_id = b.household_id;

-- --------------------------------------------------- blended tier arithmetic ---
-- The amount that falls in each tier is
--     max(0, min(basis, tier_max) - tier_min)
-- and the annual fee is the sum of those amounts at each tier's rate. tier_max
-- is NULL on the top tier, which stands for no upper bound.
DROP VIEW IF EXISTS v_annual_fee;
CREATE VIEW v_annual_fee AS
SELECT
    e.billing_period,
    e.account_id,
    e.household_id,
    e.billing_entity,
    e.account_aum,
    e.tiering_basis_aum,
    e.allocation_share,
    e.fee_schedule_code,
    SUM(
        MAX(0.0, MIN(e.tiering_basis_aum, COALESCE(r.tier_max, e.tiering_basis_aum))
                 - r.tier_min)
        * r.annual_rate_bps / 10000.0
    )                                           AS annual_fee_entity,
    MAX(r.minimum_fee_qtr)                      AS minimum_fee_qtr
FROM v_billing_entity e
JOIN ref_fee_schedule r ON r.schedule_code = e.fee_schedule_code
GROUP BY e.billing_period, e.account_id, e.household_id, e.billing_entity,
         e.account_aum, e.tiering_basis_aum, e.allocation_share, e.fee_schedule_code;

-- ------------------------------------------------------- accrue to the period ---
-- GAP-06: the legacy divisor was a fixed 4. Q3 is 92 of 365 days, which is
-- 25.21%, not 25%. Day count is now explicit so the formula matches the
-- advisory agreement rather than approximating it.
DROP VIEW IF EXISTS v_period_fee;
CREATE VIEW v_period_fee AS
SELECT
    af.billing_period,
    af.account_id,
    af.household_id,
    af.billing_entity,
    af.account_aum,
    af.tiering_basis_aum,
    af.fee_schedule_code,
    af.minimum_fee_qtr,
    d.days_billable,
    d.days_in_period,
    d.days_in_year,
    CAST(d.days_billable AS REAL) / d.days_in_period                AS proration_factor,
    af.annual_fee_entity * af.allocation_share
        * CAST(d.days_billable AS REAL) / d.days_in_year            AS gross_fee
FROM v_annual_fee af
JOIN v_account_days d
  ON d.account_id = af.account_id AND d.billing_period = af.billing_period;

-- ---------------------------------------------------------- the minimum fee ---
-- GAP-04/GAP-05: the minimum is applied at the billing entity, after the
-- zero-and-negative check, and prorated for a partial period. The legacy order
-- of operations charged $250 to accounts holding nothing, and made the
-- exceptions report structurally impossible to populate.
INSERT INTO fact_fee_charge (
    billing_period, account_id, household_id, billing_entity, tiering_basis_aum,
    account_aum, days_billable, days_in_period, proration_factor, schedule_code,
    effective_rate_bps, gross_fee, minimum_fee_applied, billable_fee
)
WITH entity_totals AS (
    SELECT
        billing_period,
        billing_entity,
        CASE WHEN billing_entity = 'HOUSEHOLD' THEN household_id ELSE account_id END
            AS entity_key,
        SUM(gross_fee)                                      AS entity_gross_fee,
        MAX(minimum_fee_qtr)                                AS minimum_fee_qtr,
        MAX(proration_factor)                               AS entity_proration,
        SUM(gross_fee)                                      AS alloc_basis
    FROM v_period_fee
    GROUP BY billing_period, billing_entity,
             CASE WHEN billing_entity = 'HOUSEHOLD' THEN household_id ELSE account_id END
),
topped AS (
    SELECT
        t.*,
        MAX(0.0, t.minimum_fee_qtr * t.entity_proration - t.entity_gross_fee)
            AS entity_topup
    FROM entity_totals t
)
SELECT
    pf.billing_period,
    pf.account_id,
    pf.household_id,
    pf.billing_entity,
    ROUND(pf.tiering_basis_aum, 2),
    ROUND(pf.account_aum, 2),
    pf.days_billable,
    pf.days_in_period,
    ROUND(pf.proration_factor, 6),
    pf.fee_schedule_code,
    -- Derived, not asserted: what rate the client actually paid on their assets.
    ROUND(CASE WHEN pf.account_aum > 0
               THEN (pf.gross_fee + CASE WHEN tp.alloc_basis > 0
                                         THEN tp.entity_topup * pf.gross_fee / tp.alloc_basis
                                         ELSE 0 END)
                    / pf.account_aum
                    * (CAST(pf.days_in_year AS REAL) / pf.days_billable)
                    * 10000.0
               ELSE 0 END, 2),
    ROUND(pf.gross_fee, 2),
    ROUND(CASE WHEN tp.alloc_basis > 0
               THEN tp.entity_topup * pf.gross_fee / tp.alloc_basis
               ELSE 0 END, 2),
    -- Rounded once, at the account, because the account is what gets invoiced.
    ROUND(pf.gross_fee + CASE WHEN tp.alloc_basis > 0
                              THEN tp.entity_topup * pf.gross_fee / tp.alloc_basis
                              ELSE 0 END, 2)
FROM v_period_fee pf
JOIN topped tp
  ON tp.billing_period = pf.billing_period
 AND tp.billing_entity = pf.billing_entity
 AND tp.entity_key = CASE WHEN pf.billing_entity = 'HOUSEHOLD'
                          THEN pf.household_id ELSE pf.account_id END;

-- A household contracted for aggregate tiering whose accounts span more than
-- one schedule: held at per-account pricing and raised, because choosing a
-- ladder for them would be inventing a contract term.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    e.billing_period, 'E22_HOUSEHOLD_SCHEDULE_MIXED', 'BLOCKING', 'HOUSEHOLD',
    e.household_id,
    'contracted for household tiering but its accounts carry ' ||
    COUNT(DISTINCT e.fee_schedule_code) ||
    ' different schedule codes; billed per account pending a decision',
    SUM(e.account_aum)
FROM v_billing_entity e
JOIN dim_household h ON h.household_id = e.household_id
WHERE h.billing_method = 'HOUSEHOLD'
GROUP BY e.billing_period, e.household_id
HAVING COUNT(DISTINCT e.fee_schedule_code) > 1;

-- Rounding drift. Allocating a household fee across its accounts and rounding
-- each one means the parts need not sum to the whole. Compared against the
-- unrounded household fee, so the control can actually fail; households where
-- a minimum top-up applied are excluded because the two sides would not be
-- comparable.
--
-- Open decision: absorb the drift as now, or allocate by largest remainder so
-- the parts always sum exactly. Largest remainder is the convention in billing
-- systems; it is left as a decision rather than assumed, because it changes
-- which client's invoice carries the odd cent.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
WITH unrounded AS (
    SELECT billing_period, household_id, SUM(gross_fee) AS household_fee
    FROM v_period_fee
    WHERE billing_entity = 'HOUSEHOLD'
    GROUP BY billing_period, household_id
),
allocated AS (
    SELECT billing_period, household_id,
           SUM(billable_fee)           AS allocated_fee,
           SUM(minimum_fee_applied)    AS topup
    FROM fact_fee_charge
    WHERE billing_entity = 'HOUSEHOLD'
    GROUP BY billing_period, household_id
)
SELECT
    a.billing_period, 'E23_HOUSEHOLD_ROUNDING_DRIFT', 'INFO', 'HOUSEHOLD',
    a.household_id,
    'allocated account fees sum to ' || PRINTF('%.4f', a.allocated_fee) ||
    ' against a household fee of ' || PRINTF('%.4f', u.household_fee) ||
    ' (drift ' || PRINTF('%+.4f', a.allocated_fee - u.household_fee) || ')',
    ROUND(a.allocated_fee - u.household_fee, 4)
FROM allocated a
JOIN unrounded u
  ON u.household_id = a.household_id AND u.billing_period = a.billing_period
WHERE a.topup = 0
  AND ABS(a.allocated_fee - u.household_fee) > 0.005;
