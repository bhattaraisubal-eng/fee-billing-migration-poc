-- =============================================================================
-- 06_etl_reconcile.sql -- legacy versus target, account by account
--
-- Every account where the two runs disagree is attributed to a numbered gap.
-- Anything that cannot be attributed is 'UNEXPLAINED', and one such row blocks
-- cutover (see 08_checks.sql).
--
-- Reason codes are matched exactly through per-account flags rather than with
-- LIKE, because '_' is a single-character wildcard in T-SQL LIKE patterns and
-- every reason code contains underscores.
-- =============================================================================

DROP PROCEDURE IF EXISTS etl.usp_reconcile;
GO
CREATE PROCEDURE etl.usp_reconcile
    @billing_period varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM recon.legacy_billing WHERE billing_period = @billing_period;
    DELETE FROM recon.parity         WHERE billing_period = @billing_period;

    DROP TABLE IF EXISTS #reason_list;
    DROP TABLE IF EXISTS #flags;
    DROP TABLE IF EXISTS #joined;

    -- The legacy invoice file, typed. A duplicated account appears as one row
    -- with legacy_row_count > 1, which is how double billing becomes visible.
    INSERT INTO recon.legacy_billing
        (billing_period, account_id, legacy_row_count, legacy_fee, legacy_aum,
         legacy_rate_bps)
    SELECT
        @billing_period,
        UPPER(TRIM(account_id)),
        COUNT(*),
        SUM(TRY_CAST(billable_fee AS decimal(18,2))),
        MAX(TRY_CAST(total_aum AS decimal(18,2))),
        MAX(TRY_CAST(annual_rate_bps AS int))
    FROM stg.legacy_billing
    WHERE TRIM(billing_period) = @billing_period
    GROUP BY UPPER(TRIM(account_id));

    -- Distinct reason codes per account, then one comma-separated list.
    SELECT DISTINCT entity_id AS account_id, reason_code
    INTO #reason_list
    FROM audit.exception_log
    WHERE billing_period = @billing_period AND entity_id IS NOT NULL;

    SELECT
        account_id,
        STRING_AGG(reason_code, ',')                                                AS reason_codes,
        MAX(CASE WHEN reason_code = 'E09_AUM_NEGATIVE'                THEN 1 ELSE 0 END) AS f_aum_negative,
        MAX(CASE WHEN reason_code = 'E09_AUM_ZERO'                    THEN 1 ELSE 0 END) AS f_aum_zero,
        MAX(CASE WHEN reason_code = 'E07_FEE_SCHEDULE_UNKNOWN'        THEN 1 ELSE 0 END) AS f_sched_unknown,
        MAX(CASE WHEN reason_code = 'E08_FEE_SCHEDULE_MISSING'        THEN 1 ELSE 0 END) AS f_sched_missing,
        MAX(CASE WHEN reason_code = 'E02_ACCOUNT_WITHOUT_HOLDINGS'    THEN 1 ELSE 0 END) AS f_no_holdings,
        MAX(CASE WHEN reason_code = 'E03_KEY_NEEDED_NORMALISING'      THEN 1 ELSE 0 END) AS f_key_fixed,
        MAX(CASE WHEN reason_code = 'E12_CLOSED_IN_PERIOD'            THEN 1 ELSE 0 END) AS f_closed_in_period,
        MAX(CASE WHEN reason_code = 'E10_STATUS_UNEXPECTED'           THEN 1 ELSE 0 END) AS f_status_unexpected,
        MAX(CASE WHEN reason_code = 'E11_PRICE_NOT_ON_VALUATION_DATE' THEN 1 ELSE 0 END) AS f_stale_price,
        MAX(CASE WHEN reason_code = 'E05_DUPLICATE_POSITION'          THEN 1 ELSE 0 END) AS f_dup_position,
        MAX(CASE WHEN reason_code = 'E06_POSITION_VALUE_NULL'         THEN 1 ELSE 0 END) AS f_null_price
    INTO #flags
    FROM #reason_list
    GROUP BY account_id;

    SELECT
        COALESCE(l.account_id, t.account_id)   AS account_id,
        l.legacy_fee,
        l.legacy_row_count,
        l.legacy_aum,
        l.legacy_rate_bps,
        t.billable_fee                         AS target_fee,
        t.account_aum                          AS target_aum,
        t.effective_rate_bps                   AS target_rate_bps,
        t.billing_entity,
        t.schedule_code,
        t.proration_factor,
        t.minimum_fee_applied
    INTO #joined
    FROM (SELECT * FROM recon.legacy_billing WHERE billing_period = @billing_period) l
    FULL OUTER JOIN
         (SELECT * FROM core.fee_charge WHERE billing_period = @billing_period) t
      ON t.account_id = l.account_id;

    INSERT INTO recon.parity
        (billing_period, account_id, outcome, legacy_fee, target_fee,
         fee_variance, legacy_aum, target_aum, billing_entity, schedule_code,
         proration_factor, reason_codes, attribution)
    SELECT
        @billing_period,
        j.account_id,
        CASE
            WHEN j.legacy_fee IS NULL THEN 'TARGET_ONLY'
            WHEN j.target_fee IS NULL THEN 'LEGACY_ONLY'
            WHEN ABS(j.target_fee - j.legacy_fee) <= 0.01 THEN 'MATCH'
            ELSE 'DIFFERS'
        END,
        j.legacy_fee,
        j.target_fee,
        COALESCE(j.target_fee, 0) - COALESCE(j.legacy_fee, 0),
        j.legacy_aum,
        j.target_aum,
        j.billing_entity,
        j.schedule_code,
        j.proration_factor,
        f.reason_codes,
        -- Most specific first; the first matching clause wins.
        CASE
            WHEN j.legacy_fee IS NOT NULL AND j.target_fee IS NOT NULL
                 AND ABS(j.target_fee - j.legacy_fee) <= 0.01
                THEN 'no change'

            -- Invoiced by legacy, held back by the target
            WHEN j.target_fee IS NULL AND f.f_aum_negative = 1
                THEN 'GAP-05 minimum fee was charged on a negative balance'
            WHEN j.target_fee IS NULL AND f.f_aum_zero = 1
                THEN 'GAP-05 minimum fee was charged on a zero balance'
            WHEN j.target_fee IS NULL AND f.f_sched_unknown = 1
                THEN 'GAP-23 priced on STD despite an unrecognised schedule code'
            WHEN j.target_fee IS NULL AND f.f_sched_missing = 1
                THEN 'GAP-24 priced on STD despite having no schedule code'
            WHEN j.target_fee IS NULL AND f.f_no_holdings = 1
                THEN 'GAP-13 account has no holdings; held for the extract to be checked'

            -- Never invoiced by legacy
            WHEN j.legacy_fee IS NULL AND f.f_key_fixed = 1
                THEN 'GAP-12 join failed on an untrimmed key; client was never billed'
            WHEN j.legacy_fee IS NULL AND f.f_closed_in_period = 1
                THEN 'GAP-16 account closed mid-period; no final fee was raised'
            WHEN j.legacy_fee IS NULL AND f.f_status_unexpected = 1
                THEN 'GAP-17 status outside the ACTIVE filter; revenue silently stopped'
            WHEN j.legacy_fee IS NULL
                THEN 'GAP-10 record discarded by the legacy join with no audit trail'

            -- Both invoiced, amounts differ
            WHEN j.legacy_row_count > 1
                THEN 'GAP-18 duplicate account row double-billed the client'
            WHEN j.billing_entity = 'HOUSEHOLD'
                THEN 'GAP-03 household tiering applied as contracted'
            WHEN j.schedule_code <> 'STD'
                THEN 'GAP-02 priced on the account''s own schedule instead of STD'
            WHEN j.proration_factor < 0.999
                THEN 'GAP-07 fee prorated to the days actually held'
            WHEN f.f_stale_price = 1
                THEN 'GAP-15 stale-priced position included in AUM'
            WHEN f.f_dup_position = 1
                THEN 'GAP-19 duplicate position no longer double-counted'
            WHEN f.f_null_price = 1
                THEN 'GAP-20 unpriced position excluded rather than treated as zero'
            WHEN j.minimum_fee_applied > 0
                THEN 'GAP-04 minimum fee applied after the zero check, and prorated'
            WHEN j.legacy_rate_bps <> ROUND(j.target_rate_bps, 0)
                THEN 'GAP-01 marginal tiers replace one rate on the whole balance'
            WHEN ABS(j.target_fee - j.legacy_fee) < 25
                THEN 'GAP-06 day count replaces the fixed quarter divisor'
            ELSE 'UNEXPLAINED'
        END
    FROM #joined j
    LEFT JOIN #flags f ON f.account_id = j.account_id;

    DROP TABLE IF EXISTS #reason_list;
    DROP TABLE IF EXISTS #flags;
    DROP TABLE IF EXISTS #joined;
END;
GO
