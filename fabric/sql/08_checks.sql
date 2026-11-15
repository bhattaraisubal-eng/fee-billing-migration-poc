-- =============================================================================
-- 08_checks.sql -- post-run controls
--
-- The Fabric equivalent of testing/test_fee_math.py's invariants. Every row
-- returned with failures > 0 is a reason not to release invoices. A pipeline
-- runs this after etl.usp_run_quarter and fails on any non-zero count.
--
-- Fabric Warehouse declares keys NOT ENFORCED, so the uniqueness checks here
-- are the only thing that actually guarantees one fee per account.
-- =============================================================================

DECLARE @billing_period varchar(10) = '2026Q3';

SELECT check_name, failures
FROM (
    SELECT 'one fee row per account' AS check_name,
           COUNT(*) - COUNT(DISTINCT account_id) AS failures
    FROM core.fee_charge WHERE billing_period = @billing_period

    UNION ALL
    SELECT 'one account row per account',
           COUNT(*) - COUNT(DISTINCT account_id)
    FROM core.account WHERE billing_period = @billing_period

    UNION ALL
    SELECT 'no fee on a zero or negative balance', COUNT(*)
    FROM core.fee_charge
    WHERE billing_period = @billing_period AND account_aum <= 0

    UNION ALL
    SELECT 'days billable within the period', COUNT(*)
    FROM core.fee_charge
    WHERE billing_period = @billing_period
      AND (days_billable < 1 OR days_billable > days_in_period)

    UNION ALL
    SELECT 'every unbilled account has a logged reason', COUNT(*)
    FROM core.account a
    WHERE a.billing_period = @billing_period
      AND NOT EXISTS (SELECT 1 FROM core.fee_charge c
                      WHERE c.billing_period = a.billing_period AND c.account_id = a.account_id)
      AND NOT EXISTS (SELECT 1 FROM audit.exception_log e
                      WHERE e.billing_period = a.billing_period AND e.entity_id = a.account_id)

    UNION ALL
    SELECT 'effective rate inside the schedule bands', COUNT(*)
    FROM core.fee_charge c
    WHERE c.billing_period = @billing_period
      AND c.minimum_fee_applied = 0
      AND (c.effective_rate_bps > (SELECT MAX(annual_rate_bps) FROM ref.fee_schedule r
                                    WHERE r.schedule_code = c.schedule_code) + 0.5
        OR c.effective_rate_bps < (SELECT MIN(annual_rate_bps) FROM ref.fee_schedule r
                                    WHERE r.schedule_code = c.schedule_code) - 0.5)

    UNION ALL
    SELECT 'unexplained variances against legacy (cutover gate)', COUNT(*)
    FROM recon.parity
    WHERE billing_period = @billing_period AND attribution = 'UNEXPLAINED'
) checks
ORDER BY failures DESC, check_name;

-- Headline numbers. Sample data should show 115 accounts, 717,153.72 billed,
-- 10 blocking exceptions, 0 unexplained.
SELECT
    (SELECT COUNT(*)          FROM core.fee_charge WHERE billing_period = @billing_period) AS accounts_billed,
    (SELECT SUM(billable_fee) FROM core.fee_charge WHERE billing_period = @billing_period) AS fees_billed,
    (SELECT SUM(legacy_fee)   FROM recon.legacy_billing WHERE billing_period = @billing_period) AS legacy_fees,
    (SELECT COUNT(*) FROM audit.exception_log
      WHERE billing_period = @billing_period AND severity = 'BLOCKING')                     AS blocking_exceptions,
    (SELECT COUNT(*) FROM recon.parity
      WHERE billing_period = @billing_period AND attribution = 'UNEXPLAINED')               AS unexplained;

-- Every variance by cause, largest first.
SELECT attribution, COUNT(*) AS accounts, SUM(fee_variance) AS net_variance
FROM recon.parity
WHERE billing_period = @billing_period AND outcome <> 'MATCH'
GROUP BY attribution
ORDER BY ABS(SUM(fee_variance)) DESC;
