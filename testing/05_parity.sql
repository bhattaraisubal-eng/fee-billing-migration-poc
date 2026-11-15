-- =============================================================================
-- 05_parity.sql -- legacy versus target reconciliation
--
-- A migration is not proved by matching totals. It is proved by accounting for
-- every account where the two runs disagree, and showing that each difference
-- is a decision someone signed off rather than a regression nobody noticed.
--
-- The test that matters is the last one in this file: zero unexplained
-- variances. A difference with no attribution is a defect.
-- =============================================================================

DROP VIEW IF EXISTS v_legacy_by_account;
CREATE VIEW v_legacy_by_account AS
SELECT
    TRIM(UPPER(account_id))     AS account_id,
    billing_period,
    COUNT(*)                    AS legacy_row_count,
    SUM(billable_fee)           AS legacy_fee,
    MAX(total_aum)              AS legacy_aum,
    MAX(annual_rate_bps)        AS legacy_rate_bps
FROM legacy_billing
GROUP BY TRIM(UPPER(account_id)), billing_period;

-- Reason codes raised against an account, collapsed to one row so the
-- reconciliation can cite them.
DROP VIEW IF EXISTS v_account_reasons;
CREATE VIEW v_account_reasons AS
SELECT
    entity_id                                   AS account_id,
    GROUP_CONCAT(DISTINCT reason_code)          AS reason_codes
FROM exception_log
WHERE entity_id IS NOT NULL
GROUP BY entity_id;

DROP VIEW IF EXISTS v_parity;
CREATE VIEW v_parity AS
WITH joined AS (
    SELECT
        COALESCE(l.account_id, t.account_id)                AS account_id,
        COALESCE(l.billing_period, t.billing_period)        AS billing_period,
        l.legacy_fee,
        l.legacy_row_count,
        l.legacy_aum,
        l.legacy_rate_bps,
        t.billable_fee                                      AS target_fee,
        t.account_aum                                       AS target_aum,
        t.effective_rate_bps                                AS target_rate_bps,
        t.billing_entity,
        t.schedule_code,
        t.proration_factor,
        t.minimum_fee_applied
    FROM v_legacy_by_account l
    FULL OUTER JOIN fact_fee_charge t
      ON t.account_id = l.account_id
     AND t.billing_period = l.billing_period
)
SELECT
    j.*,
    r.reason_codes,
    CASE
        WHEN j.legacy_fee IS NULL THEN 'TARGET_ONLY'
        WHEN j.target_fee IS NULL THEN 'LEGACY_ONLY'
        WHEN ABS(j.target_fee - j.legacy_fee) <= 0.01 THEN 'MATCH'
        ELSE 'DIFFERS'
    END                                                     AS outcome,
    ROUND(COALESCE(j.target_fee, 0) - COALESCE(j.legacy_fee, 0), 2) AS fee_variance,
    -- ------------------------------------------------------------------------
    -- Attribution. Ordered most specific first; the first matching clause wins.
    -- Every clause names the gap whose resolution causes the difference.
    -- ------------------------------------------------------------------------
    CASE
        WHEN j.legacy_fee IS NOT NULL AND j.target_fee IS NOT NULL
             AND ABS(j.target_fee - j.legacy_fee) <= 0.01
            THEN 'no change'

        -- Records the legacy run invoiced that the target holds back
        WHEN j.target_fee IS NULL AND r.reason_codes LIKE '%E09_AUM_NEGATIVE%'
            THEN 'GAP-05 minimum fee was charged on a negative balance'
        WHEN j.target_fee IS NULL AND r.reason_codes LIKE '%E09_AUM_ZERO%'
            THEN 'GAP-05 minimum fee was charged on a zero balance'
        WHEN j.target_fee IS NULL AND r.reason_codes LIKE '%E07_FEE_SCHEDULE_UNKNOWN%'
            THEN 'GAP-D account priced on STD despite an unrecognised schedule code'
        WHEN j.target_fee IS NULL AND r.reason_codes LIKE '%E08_FEE_SCHEDULE_MISSING%'
            THEN 'GAP-D account priced on STD despite having no schedule code'
        WHEN j.target_fee IS NULL AND r.reason_codes LIKE '%E02_ACCOUNT_WITHOUT_HOLDINGS%'
            THEN 'GAP-13 account has no holdings; held for the extract to be checked'

        -- Records the legacy run never invoiced at all
        WHEN j.legacy_fee IS NULL AND r.reason_codes LIKE '%E03_KEY_NEEDED_NORMALISING%'
            THEN 'GAP-12 join failed on an untrimmed key; client was never billed'
        WHEN j.legacy_fee IS NULL AND r.reason_codes LIKE '%E12_CLOSED_IN_PERIOD%'
            THEN 'GAP-16 account closed mid-period; no final fee was raised'
        WHEN j.legacy_fee IS NULL AND r.reason_codes LIKE '%E10_STATUS_UNEXPECTED%'
            THEN 'GAP-17 status outside the ACTIVE filter; revenue silently stopped'
        WHEN j.legacy_fee IS NULL
            THEN 'GAP-10 record discarded by the legacy join with no audit trail'

        -- Both runs invoiced, amounts differ
        WHEN j.legacy_row_count > 1
            THEN 'GAP-18 duplicate account row double-billed the client'
        WHEN j.billing_entity = 'HOUSEHOLD'
            THEN 'GAP-03 household tiering applied as contracted'
        WHEN j.schedule_code <> 'STD'
            THEN 'GAP-02 priced on the account''s own schedule instead of STD'
        WHEN j.proration_factor < 0.999
            THEN 'GAP-07 fee prorated to the days actually held'
        WHEN r.reason_codes LIKE '%E11_PRICE_NOT_ON_VALUATION_DATE%'
            THEN 'GAP-15 stale-priced position included in AUM'
        WHEN r.reason_codes LIKE '%E05_DUPLICATE_POSITION%'
            THEN 'GAP-19 duplicate position no longer double-counted'
        WHEN r.reason_codes LIKE '%E06_POSITION_VALUE_NULL%'
            THEN 'GAP-20 unpriced position excluded rather than treated as zero'
        WHEN j.minimum_fee_applied > 0
            THEN 'GAP-04 minimum fee applied after the zero check, and prorated'
        WHEN j.legacy_rate_bps <> ROUND(j.target_rate_bps)
            THEN 'GAP-01 marginal tiers replace one rate on the whole balance'
        WHEN ABS(j.target_fee - j.legacy_fee) < 25
            THEN 'GAP-06 day count replaces the fixed quarter divisor'
        ELSE 'UNEXPLAINED'
    END                                                     AS attribution
FROM joined j
LEFT JOIN v_account_reasons r ON r.account_id = j.account_id;

-- ----------------------------------------------------------------- summaries ---

DROP VIEW IF EXISTS v_parity_summary;
CREATE VIEW v_parity_summary AS
SELECT
    outcome,
    COUNT(*)                            AS accounts,
    ROUND(SUM(COALESCE(legacy_fee, 0)), 2)  AS legacy_total,
    ROUND(SUM(COALESCE(target_fee, 0)), 2)  AS target_total,
    ROUND(SUM(fee_variance), 2)             AS variance
FROM v_parity
GROUP BY outcome;

DROP VIEW IF EXISTS v_variance_by_cause;
CREATE VIEW v_variance_by_cause AS
SELECT
    attribution,
    COUNT(*)                        AS accounts,
    ROUND(SUM(fee_variance), 2)     AS net_variance
FROM v_parity
WHERE outcome <> 'MATCH'
GROUP BY attribution
ORDER BY ABS(SUM(fee_variance)) DESC;

-- The defect log. Any row here is a variance the migration cannot explain, and
-- is a blocker for cutover.
DROP VIEW IF EXISTS v_defects;
CREATE VIEW v_defects AS
SELECT
    account_id, outcome, legacy_fee, target_fee, fee_variance,
    legacy_aum, target_aum, schedule_code, reason_codes
FROM v_parity
WHERE attribution = 'UNEXPLAINED'
ORDER BY ABS(fee_variance) DESC;
