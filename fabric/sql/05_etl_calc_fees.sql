-- =============================================================================
-- 05_etl_calc_fees.sql -- the fee calculation
--
-- Replaces Alteryx Tool 7 (rate by nested IF), Tool 8 (fee and minimum),
-- Tool 9 (Select) and Tool 10 (Filter billable_fee > 0).
--
--   GAP-01  marginal tiers, not one rate on the whole balance
--   GAP-02  rates from ref.fee_schedule by the account's own schedule code
--   GAP-03  household tiering where the household is contracted for it
--   GAP-04  minimum applied after the zero check, so exceptions can populate
--   GAP-06  actual days over days_in_year, not a fixed divisor of 4
--   GAP-07  prorated for mid-period opens and closes
--
-- Decimal arithmetic note for Fabric / SQL Server: when a decimal result would
-- exceed 38 digits the engine cuts the scale back toward 6 places. Dividing
-- first and multiplying second therefore loses pennies on large balances.
-- Every expression below multiplies before it divides for that reason.
-- =============================================================================

DROP PROCEDURE IF EXISTS etl.usp_calc_fees;
GO
CREATE PROCEDURE etl.usp_calc_fees
    @billing_period varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM core.fee_charge WHERE billing_period = @billing_period;

    DROP TABLE IF EXISTS #span;
    DROP TABLE IF EXISTS #billable;
    DROP TABLE IF EXISTS #household_stats;
    DROP TABLE IF EXISTS #entity;
    DROP TABLE IF EXISTS #annual;
    DROP TABLE IF EXISTS #period_fee;
    DROP TABLE IF EXISTS #entity_total;

    -- --------------------------------------------- days the account was held --
    SELECT
        a.account_id,
        a.household_id,
        a.fee_schedule_code,
        p.days_in_period,
        p.days_in_year,
        CASE WHEN a.open_date IS NOT NULL AND a.open_date > p.period_start
             THEN a.open_date ELSE p.period_start END        AS effective_start,
        CASE WHEN a.close_date IS NOT NULL AND a.close_date < p.period_end
             THEN a.close_date ELSE p.period_end END         AS effective_end
    INTO #span
    FROM core.account a
    JOIN ref.billing_period p ON p.billing_period = a.billing_period
    WHERE a.billing_period = @billing_period
      AND a.is_billable = 1;

    -- Billable accounts with positive AUM: the only ones a fee can be raised on.
    SELECT
        s.account_id,
        s.household_id,
        s.fee_schedule_code,
        s.days_in_period,
        s.days_in_year,
        CASE WHEN DATEDIFF(day, s.effective_start, s.effective_end) + 1 > 0
             THEN DATEDIFF(day, s.effective_start, s.effective_end) + 1
             ELSE 0 END                                      AS days_billable,
        f.market_value                                       AS account_aum
    INTO #billable
    FROM #span s
    JOIN core.account_aum f
      ON f.account_id = s.account_id AND f.billing_period = @billing_period
    WHERE f.market_value > 0;

    -- ------------------------------------------- which entity sets the tier --
    SELECT
        b.household_id,
        COUNT(DISTINCT b.fee_schedule_code)  AS schedule_variants,
        SUM(b.account_aum)                   AS household_aum
    INTO #household_stats
    FROM #billable b
    GROUP BY b.household_id;

    -- Aggregate only where contracted AND every account shares one schedule.
    -- A household spanning two schedules has no single ladder to apply.
    SELECT
        b.*,
        CASE WHEN h.billing_method = 'HOUSEHOLD' AND hs.schedule_variants = 1
             THEN 'HOUSEHOLD' ELSE 'ACCOUNT' END             AS billing_entity,
        CASE WHEN h.billing_method = 'HOUSEHOLD' AND hs.schedule_variants = 1
             THEN hs.household_aum ELSE b.account_aum END    AS tiering_basis_aum,
        CASE WHEN h.billing_method = 'HOUSEHOLD' AND hs.schedule_variants = 1
             THEN b.household_id ELSE b.account_id END       AS entity_key
    INTO #entity
    FROM #billable b
    JOIN #household_stats hs ON hs.household_id = b.household_id
    LEFT JOIN core.household h
      ON h.household_id = b.household_id AND h.billing_period = @billing_period;

    -- ---------------------------------------------- marginal tier arithmetic --
    -- Amount in each tier = max(0, min(basis, tier_max) - tier_min).
    SELECT
        e.account_id,
        SUM(
            CASE WHEN e.tiering_basis_aum > r.tier_min
                 THEN (CASE WHEN r.tier_max IS NULL OR e.tiering_basis_aum < r.tier_max
                            THEN e.tiering_basis_aum ELSE r.tier_max END)
                      - r.tier_min
                 ELSE 0 END
            * r.annual_rate_bps / 10000
        )                                    AS annual_fee_entity,
        MAX(r.minimum_fee_qtr)               AS minimum_fee_qtr
    INTO #annual
    FROM #entity e
    JOIN ref.fee_schedule r ON r.schedule_code = e.fee_schedule_code
    GROUP BY e.account_id;

    -- ----------------------------------------------- accrue to the period ---
    -- Account share of the entity's annual fee, accrued on days held.
    -- annual * account_aum * days / (basis * days_in_year): multiply first.
    SELECT
        e.account_id,
        e.household_id,
        e.billing_entity,
        e.entity_key,
        e.account_aum,
        e.tiering_basis_aum,
        e.fee_schedule_code,
        e.days_billable,
        e.days_in_period,
        e.days_in_year,
        an.minimum_fee_qtr,
        an.annual_fee_entity * e.account_aum * e.days_billable
            / (e.tiering_basis_aum * e.days_in_year)        AS gross_fee
    INTO #period_fee
    FROM #entity e
    JOIN #annual an ON an.account_id = e.account_id;

    -- ------------------------------------------------------ the minimum fee ---
    -- Applied per billing entity, after the zero check, prorated for a partial
    -- period. Any shortfall is shared across the entity in proportion to fee.
    SELECT
        entity_key,
        billing_entity,
        SUM(gross_fee)                       AS entity_gross_fee,
        CASE WHEN MAX(minimum_fee_qtr) * MAX(days_billable) / MAX(days_in_period)
                  > SUM(gross_fee)
             THEN MAX(minimum_fee_qtr) * MAX(days_billable) / MAX(days_in_period)
                  - SUM(gross_fee)
             ELSE 0 END                      AS entity_topup
    INTO #entity_total
    FROM #period_fee
    GROUP BY entity_key, billing_entity;

    INSERT INTO core.fee_charge
        (billing_period, account_id, household_id, billing_entity,
         tiering_basis_aum, account_aum, days_billable, days_in_period,
         proration_factor, schedule_code, effective_rate_bps, gross_fee,
         minimum_fee_applied, billable_fee)
    SELECT
        @billing_period,
        pf.account_id,
        pf.household_id,
        pf.billing_entity,
        pf.tiering_basis_aum,
        pf.account_aum,
        pf.days_billable,
        pf.days_in_period,
        ROUND(CAST(pf.days_billable AS decimal(18,6)) / pf.days_in_period, 6),
        pf.fee_schedule_code,
        -- What the client actually paid on their assets, annualised.
        ROUND((pf.gross_fee + COALESCE(et.entity_topup * pf.gross_fee
                                       / NULLIF(et.entity_gross_fee, 0), 0))
              * pf.days_in_year * 10000
              / (pf.account_aum * pf.days_billable), 2),
        ROUND(pf.gross_fee, 2),
        ROUND(COALESCE(et.entity_topup * pf.gross_fee
                       / NULLIF(et.entity_gross_fee, 0), 0), 2),
        -- Rounded once, at the account, because the account is what is invoiced.
        ROUND(pf.gross_fee + COALESCE(et.entity_topup * pf.gross_fee
                                      / NULLIF(et.entity_gross_fee, 0), 0), 2)
    FROM #period_fee pf
    JOIN #entity_total et
      ON et.entity_key = pf.entity_key AND et.billing_entity = pf.billing_entity;

    -- ============================================================ exceptions ==

    -- Contracted for household tiering, but accounts carry mixed schedules:
    -- billed per account, held for a contract decision.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E22_HOUSEHOLD_SCHEDULE_MIXED', 'BLOCKING', 'HOUSEHOLD',
           hs.household_id,
           CONCAT('contracted for household tiering but its accounts carry ',
                  hs.schedule_variants,
                  ' different schedule codes; billed per account pending a decision'),
           hs.household_aum
    FROM #household_stats hs
    JOIN core.household h
      ON h.household_id = hs.household_id AND h.billing_period = @billing_period
    WHERE h.billing_method = 'HOUSEHOLD'
      AND hs.schedule_variants > 1;

    -- Rounding drift: allocated account fees against the unrounded household
    -- fee. Households where a minimum top-up applied are not comparable.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E23_HOUSEHOLD_ROUNDING_DRIFT', 'INFO', 'HOUSEHOLD',
           c.household_id,
           CONCAT('allocated account fees sum to ', CAST(SUM(c.billable_fee) AS varchar(30)),
                  ' against an unrounded household fee of ',
                  CAST(CAST(MAX(et.entity_gross_fee) AS decimal(18,4)) AS varchar(30))),
           SUM(c.billable_fee) - CAST(MAX(et.entity_gross_fee) AS decimal(18,2))
    FROM core.fee_charge c
    JOIN #entity_total et
      ON et.entity_key = c.household_id AND et.billing_entity = 'HOUSEHOLD'
    WHERE c.billing_period = @billing_period
      AND c.billing_entity = 'HOUSEHOLD'
      AND et.entity_topup = 0
    GROUP BY c.household_id
    HAVING ABS(SUM(c.billable_fee) - MAX(et.entity_gross_fee)) > 0.005;

    DROP TABLE IF EXISTS #span;
    DROP TABLE IF EXISTS #billable;
    DROP TABLE IF EXISTS #household_stats;
    DROP TABLE IF EXISTS #entity;
    DROP TABLE IF EXISTS #annual;
    DROP TABLE IF EXISTS #period_fee;
    DROP TABLE IF EXISTS #entity_total;
END;
GO
