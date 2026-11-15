-- =============================================================================
-- 02_conform.sql -- staging to conformed dimensions
--
-- Every decision below traces to a numbered gap in analysis/GAP_LOG.md. Where
-- the legacy workflow dropped a record, this layer keeps it and writes a reason.
-- =============================================================================

-- ------------------------------------------------- the period being billed ---
DELETE FROM ref_billing_period;
INSERT INTO ref_billing_period
    (billing_period, period_start, period_end, valuation_date, days_in_period, days_in_year)
VALUES
    -- GAP-08: the period is a parameter, not a literal edited into a filter.
    ('2026Q3', '2026-07-01', '2026-09-30', '2026-09-30', 92, 365);

-- ------------------------------------------------------ the fee schedule -----
-- GAP-02: typed from the published schedule. tier_max 0 in the source file
-- means "no upper bound" and becomes NULL here so the tier maths is explicit.
DELETE FROM ref_fee_schedule;
INSERT INTO ref_fee_schedule
    (schedule_code, tier_seq, tier_min, tier_max, annual_rate_bps, minimum_fee_qtr, schedule_name)
SELECT
    TRIM(UPPER(schedule_code)),
    CAST(tier_seq AS INTEGER),
    CAST(tier_min AS REAL),
    CASE WHEN CAST(tier_max AS REAL) = 0 THEN NULL ELSE CAST(tier_max AS REAL) END,
    CAST(annual_rate_bps AS REAL),
    CAST(minimum_fee_qtr AS REAL),
    schedule_name
FROM stg_fee_schedule;

-- ---------------------------------------------------------- dim_household ----
DELETE FROM dim_household;
INSERT INTO dim_household (household_id, household_name, billing_method, relationship_manager)
SELECT
    TRIM(UPPER(household_id)),
    TRIM(household_name),
    -- An unreadable billing method must not silently become per-account
    -- pricing, which is the more expensive option for the client.
    CASE WHEN TRIM(UPPER(billing_method)) IN ('ACCOUNT', 'HOUSEHOLD')
         THEN TRIM(UPPER(billing_method))
         ELSE 'UNKNOWN' END,
    TRIM(relationship_manager)
FROM stg_households;

INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    'E20_BILLING_METHOD_UNREADABLE', 'BLOCKING', 'HOUSEHOLD', household_id,
    'billing_method is not ACCOUNT or HOUSEHOLD; tiering basis undetermined', NULL
FROM dim_household
WHERE billing_method = 'UNKNOWN';

-- ------------------------------------------------------------ dim_account ----
-- GAP-12: keys are trimmed and upper-cased. The legacy join failed on a single
-- trailing space and that client was never billed.
-- GAP-18: duplicate account rows are collapsed to one, keeping the first
-- occurrence, and reported. The legacy join fanned out and double-billed.
DELETE FROM dim_account;
INSERT INTO dim_account (
    account_id, account_id_source, household_id, account_name, account_type,
    fee_schedule_code, open_date, close_date, status, advisor_id, is_billable
)
WITH normalised AS (
    SELECT
        TRIM(UPPER(account_id))                                   AS account_id,
        account_id                                                AS account_id_source,
        TRIM(UPPER(household_id))                                 AS household_id,
        TRIM(account_name)                                        AS account_name,
        TRIM(UPPER(account_type))                                 AS account_type,
        NULLIF(TRIM(UPPER(fee_schedule_code)), '')                AS fee_schedule_code,
        NULLIF(TRIM(open_date), '')                               AS open_date,
        NULLIF(TRIM(close_date), '')                              AS close_date,
        TRIM(UPPER(status))                                       AS status,
        TRIM(advisor_id)                                          AS advisor_id,
        source_row,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(UPPER(account_id)) ORDER BY source_row
        )                                                         AS dup_seq
    FROM stg_accounts
),
period AS (SELECT * FROM ref_billing_period)
SELECT
    n.account_id, n.account_id_source, n.household_id, n.account_name,
    n.account_type, n.fee_schedule_code, n.open_date, n.close_date, n.status,
    n.advisor_id,
    CASE
        -- GAP-D: a code that is absent or not in the published schedule cannot
        -- be priced. Defaulting it to STD is what the legacy flow did, and it
        -- silently repriced grandfathered and institutional clients.
        WHEN n.fee_schedule_code IS NULL THEN 0
        WHEN NOT EXISTS (SELECT 1 FROM ref_fee_schedule r
                         WHERE r.schedule_code = n.fee_schedule_code) THEN 0
        -- Closed before the period opened: correctly not billable, and now for
        -- a stated reason rather than as a side effect of a status filter.
        WHEN n.close_date IS NOT NULL AND n.close_date < p.period_start THEN 0
        -- Opened after the period closed.
        WHEN n.open_date IS NOT NULL AND n.open_date > p.period_end THEN 0
        -- GAP-16, GAP-17: CLOSED inside the period still owes a final prorated
        -- fee, and PENDING_CLOSE is a live account. The legacy equality filter
        -- on 'ACTIVE' silently stopped revenue for both.
        WHEN n.status IN ('ACTIVE', 'CLOSED', 'PENDING_CLOSE') THEN 1
        ELSE 0
    END AS is_billable
FROM normalised n
CROSS JOIN period p
WHERE n.dup_seq = 1;

-- ---- exceptions raised while conforming accounts ----------------------------

-- GAP-18 duplicate account rows
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    'E04_DUPLICATE_ACCOUNT_ROW', 'BLOCKING', 'ACCOUNT',
    TRIM(UPPER(account_id)),
    'account appears ' || COUNT(*) || ' times in the source extract; collapsed to one',
    NULL
FROM stg_accounts
GROUP BY TRIM(UPPER(account_id))
HAVING COUNT(*) > 1;

-- GAP-12 key hygiene: normalisation changed the key
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    'E03_KEY_NEEDED_NORMALISING', 'REVIEW', 'ACCOUNT', account_id,
    'source key was ' || '"' || account_id_source || '"' ||
    '; joined after trim and upper', NULL
FROM dim_account
WHERE account_id_source <> account_id;

-- GAP-D unknown or missing fee schedule
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    CASE WHEN a.fee_schedule_code IS NULL
         THEN 'E08_FEE_SCHEDULE_MISSING'
         ELSE 'E07_FEE_SCHEDULE_UNKNOWN' END,
    'BLOCKING', 'ACCOUNT', a.account_id,
    'fee_schedule_code ' ||
    COALESCE('"' || a.fee_schedule_code || '"', '(empty)') ||
    ' is not in the published schedule; account held out of the run',
    NULL
FROM dim_account a
WHERE a.fee_schedule_code IS NULL
   OR NOT EXISTS (SELECT 1 FROM ref_fee_schedule r
                  WHERE r.schedule_code = a.fee_schedule_code);

-- GAP-17 a status value the pipeline was not designed for
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    'E10_STATUS_UNEXPECTED', 'REVIEW', 'ACCOUNT', account_id,
    'status "' || status || '" is outside the agreed set; treated as billable pending confirmation',
    NULL
FROM dim_account
WHERE status NOT IN ('ACTIVE', 'CLOSED');

-- GAP-16 closed inside the period: a final fee is owed
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    p.billing_period, 'E12_CLOSED_IN_PERIOD', 'INFO', 'ACCOUNT', a.account_id,
    'closed ' || a.close_date || '; final fee prorated to the closure date',
    NULL
FROM dim_account a CROSS JOIN ref_billing_period p
WHERE a.close_date IS NOT NULL
  AND a.close_date BETWEEN p.period_start AND p.period_end;

-- GAP-07 opened inside the period: prorated, not billed a full quarter
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    p.billing_period, 'E13_OPENED_IN_PERIOD', 'INFO', 'ACCOUNT', a.account_id,
    'opened ' || a.open_date || '; fee prorated from that date',
    NULL
FROM dim_account a CROSS JOIN ref_billing_period p
WHERE a.open_date IS NOT NULL
  AND a.open_date BETWEEN p.period_start AND p.period_end;

-- Correctly out of scope, but recorded. The design rule is that no account
-- leaves the run without a stated reason, and "it was right to exclude it" is
-- still a reason. The legacy workflow excluded these by accident, as a side
-- effect of a status filter, which is why nobody could tell a correct exclusion
-- from a silent revenue leak.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    p.billing_period, 'E14_OUT_OF_PERIOD', 'INFO', 'ACCOUNT', a.account_id,
    CASE WHEN a.close_date < p.period_start
         THEN 'closed ' || a.close_date || ', before the period opened; no fee due'
         ELSE 'opened ' || a.open_date || ', after the period closed; no fee due' END,
    NULL
FROM dim_account a
CROSS JOIN ref_billing_period p
WHERE a.is_billable = 0
  AND ((a.close_date IS NOT NULL AND a.close_date < p.period_start)
    OR (a.open_date IS NOT NULL AND a.open_date > p.period_end));

-- Household referenced by an account but absent from the household extract
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    'E21_HOUSEHOLD_NOT_FOUND', 'BLOCKING', 'ACCOUNT', a.account_id,
    'household_id "' || a.household_id || '" is not in the household extract', NULL
FROM dim_account a
WHERE a.household_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dim_household h WHERE h.household_id = a.household_id);
