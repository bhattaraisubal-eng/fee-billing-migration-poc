-- =============================================================================
-- 09_output_views.sql -- what downstream consumers read
--
-- Replaces Alteryx Tools 11-13 (Sort, two Output Data). Instead of writing two
-- CSVs to a file share, the warehouse exposes views. Billing Operations, a
-- Power BI report, and the pipeline's export step all read the same objects,
-- so there is one definition of "the invoice file".
--
-- Views carry no ORDER BY (T-SQL does not allow it in a view without TOP);
-- consumers sort. The legacy Sort tool existed only to order a CSV.
-- =============================================================================

DROP VIEW IF EXISTS core.v_billing_output;
GO
CREATE VIEW core.v_billing_output AS
SELECT
    c.billing_period,
    c.account_id,
    c.household_id,
    a.account_name,
    a.advisor_id,
    c.billing_entity,
    c.schedule_code,
    c.account_aum,
    c.tiering_basis_aum,
    c.days_billable,
    c.days_in_period,
    c.effective_rate_bps,
    c.gross_fee,
    c.minimum_fee_applied,
    c.billable_fee,
    -- An invoice is releasable only if no BLOCKING exception is open on it.
    CASE WHEN EXISTS (SELECT 1 FROM audit.exception_log e
                      WHERE e.billing_period = c.billing_period
                        AND e.entity_id = c.account_id
                        AND e.severity = 'BLOCKING')
         THEN 0 ELSE 1 END AS releasable
FROM core.fee_charge c
JOIN core.account a
  ON a.account_id = c.account_id AND a.billing_period = c.billing_period;
GO

DROP VIEW IF EXISTS audit.v_exceptions_open;
GO
CREATE VIEW audit.v_exceptions_open AS
SELECT
    billing_period, severity, reason_code, entity_type, entity_id, detail,
    amount_at_risk,
    CASE severity WHEN 'BLOCKING' THEN 1 WHEN 'REVIEW' THEN 2 ELSE 3 END AS severity_rank
FROM audit.exception_log;
GO

DROP VIEW IF EXISTS recon.v_variance_by_cause;
GO
CREATE VIEW recon.v_variance_by_cause AS
SELECT billing_period, attribution, COUNT(*) AS accounts,
       SUM(fee_variance) AS net_variance
FROM recon.parity
WHERE outcome <> 'MATCH'
GROUP BY billing_period, attribution;
GO
