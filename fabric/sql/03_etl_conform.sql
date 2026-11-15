-- =============================================================================
-- 03_etl_conform.sql -- reference data and conformed dimensions
--
-- Replaces Alteryx Tool 5 (Filter status = "ACTIVE") and the implicit key
-- handling of Tool 6 (Join). Every record the legacy flow dropped silently is
-- kept here, or logged with a reason.
--
-- Fabric-specific behaviour this code relies on:
--   * The default warehouse collation is case-sensitive, so keys are
--     upper-cased before any join.
--   * T-SQL '=' ignores trailing spaces ('A1 ' = 'A1' is true), and so does
--     LEN(). The key-hygiene check therefore compares DATALENGTH as well, or it
--     could never see the trailing-space defect that broke the Alteryx join.
--   * Row order in a table is not guaranteed, so "keep the first duplicate"
--     is defined by an explicit ORDER BY, never by file order.
-- =============================================================================

DROP PROCEDURE IF EXISTS etl.usp_load_reference;
GO
CREATE PROCEDURE etl.usp_load_reference
AS
BEGIN
    SET NOCOUNT ON;

    -- GAP-02: rates live in a table, not in a Formula tool. The top tier's
    -- tier_max of 0 in the file means "no upper bound" and becomes NULL.
    DELETE FROM ref.fee_schedule;

    INSERT INTO ref.fee_schedule
        (schedule_code, tier_seq, tier_min, tier_max, annual_rate_bps,
         minimum_fee_qtr, schedule_name)
    SELECT
        UPPER(TRIM(schedule_code)),
        TRY_CAST(tier_seq AS int),
        TRY_CAST(tier_min AS decimal(18,2)),
        CASE WHEN TRY_CAST(tier_max AS decimal(18,2)) = 0 THEN NULL
             ELSE TRY_CAST(tier_max AS decimal(18,2)) END,
        TRY_CAST(annual_rate_bps AS decimal(9,4)),
        TRY_CAST(minimum_fee_qtr AS decimal(18,2)),
        TRIM(schedule_name)
    FROM stg.fee_schedule;
END;
GO

DROP PROCEDURE IF EXISTS etl.usp_conform;
GO
CREATE PROCEDURE etl.usp_conform
    @billing_period varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM core.household WHERE billing_period = @billing_period;
    DELETE FROM core.account   WHERE billing_period = @billing_period;

    -- ------------------------------------------------------------ households --
    -- GAP-03: households.csv was never read by the Alteryx workflow.
    INSERT INTO core.household
        (billing_period, household_id, household_name, billing_method,
         relationship_manager)
    SELECT
        @billing_period,
        UPPER(TRIM(household_id)),
        TRIM(household_name),
        CASE WHEN UPPER(TRIM(billing_method)) IN ('ACCOUNT', 'HOUSEHOLD')
             THEN UPPER(TRIM(billing_method)) ELSE 'UNKNOWN' END,
        TRIM(relationship_manager)
    FROM stg.households;

    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E20_BILLING_METHOD_UNREADABLE', 'BLOCKING', 'HOUSEHOLD',
           household_id,
           'billing_method is not ACCOUNT or HOUSEHOLD; tiering basis undetermined',
           NULL
    FROM core.household
    WHERE billing_period = @billing_period AND billing_method = 'UNKNOWN';

    -- -------------------------------------------------------------- accounts --
    -- GAP-12 keys trimmed and upper-cased; GAP-18 duplicates collapsed to one.
    WITH normalised AS (
        SELECT
            UPPER(TRIM(account_id))                           AS account_id,
            account_id                                        AS account_id_source,
            UPPER(TRIM(household_id))                         AS household_id,
            TRIM(account_name)                                AS account_name,
            UPPER(TRIM(account_type))                         AS account_type,
            NULLIF(UPPER(TRIM(fee_schedule_code)), '')        AS fee_schedule_code,
            TRY_CAST(NULLIF(TRIM(open_date), '') AS date)     AS open_date,
            TRY_CAST(NULLIF(TRIM(close_date), '') AS date)    AS close_date,
            UPPER(TRIM(status))                               AS status,
            TRIM(advisor_id)                                  AS advisor_id,
            ROW_NUMBER() OVER (
                PARTITION BY UPPER(TRIM(account_id))
                ORDER BY TRIM(account_name), account_id, household_id
            )                                                 AS dup_seq
        FROM stg.accounts
    )
    INSERT INTO core.account
        (billing_period, account_id, account_id_source, household_id,
         account_name, account_type, fee_schedule_code, open_date, close_date,
         status, advisor_id, is_billable)
    SELECT
        @billing_period,
        n.account_id, n.account_id_source, n.household_id, n.account_name,
        n.account_type, n.fee_schedule_code, n.open_date, n.close_date,
        n.status, n.advisor_id,
        CASE
            -- GAP-23/24: cannot be priced without a recognised schedule.
            WHEN n.fee_schedule_code IS NULL THEN 0
            WHEN NOT EXISTS (SELECT 1 FROM ref.fee_schedule r
                             WHERE r.schedule_code = n.fee_schedule_code) THEN 0
            WHEN n.close_date IS NOT NULL AND n.close_date < p.period_start THEN 0
            WHEN n.open_date  IS NOT NULL AND n.open_date  > p.period_end   THEN 0
            -- GAP-16/17: closed in-period and PENDING_CLOSE still owe a fee.
            WHEN n.status IN ('ACTIVE', 'CLOSED', 'PENDING_CLOSE') THEN 1
            ELSE 0
        END
    FROM normalised n
    CROSS JOIN ref.billing_period p
    WHERE p.billing_period = @billing_period
      AND n.dup_seq = 1;

    -- ------------------------------------------------------------ exceptions --

    -- GAP-18 duplicate account rows
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E04_DUPLICATE_ACCOUNT_ROW', 'BLOCKING', 'ACCOUNT',
           UPPER(TRIM(account_id)),
           CONCAT('account appears ', COUNT(*),
                  ' times in the source extract; collapsed to one'),
           NULL
    FROM stg.accounts
    GROUP BY UPPER(TRIM(account_id))
    HAVING COUNT(*) > 1;

    -- GAP-12 key needed normalising. DATALENGTH, because '=' ignores trailing spaces.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E03_KEY_NEEDED_NORMALISING', 'REVIEW', 'ACCOUNT',
           account_id,
           CONCAT('source key was "', account_id_source, '"; joined after trim and upper'),
           NULL
    FROM core.account
    WHERE billing_period = @billing_period
      AND (account_id_source <> account_id
           OR DATALENGTH(account_id_source) <> DATALENGTH(account_id));

    -- A date that would not parse. TRY_CAST returns NULL, so without this the
    -- account would silently lose its open or close date.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E24_DATE_UNPARSEABLE', 'BLOCKING', 'ACCOUNT',
           UPPER(TRIM(s.account_id)),
           CONCAT('open_date "', s.open_date, '" or close_date "', s.close_date,
                  '" is not a valid date'),
           NULL
    FROM stg.accounts s
    WHERE (NULLIF(TRIM(s.open_date), '')  IS NOT NULL AND TRY_CAST(TRIM(s.open_date)  AS date) IS NULL)
       OR (NULLIF(TRIM(s.close_date), '') IS NOT NULL AND TRY_CAST(TRIM(s.close_date) AS date) IS NULL);

    -- GAP-23/24 unknown or missing fee schedule
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period,
           CASE WHEN a.fee_schedule_code IS NULL THEN 'E08_FEE_SCHEDULE_MISSING'
                ELSE 'E07_FEE_SCHEDULE_UNKNOWN' END,
           'BLOCKING', 'ACCOUNT', a.account_id,
           CONCAT('fee_schedule_code "', COALESCE(a.fee_schedule_code, ''),
                  '" is not in the published schedule; account held out of the run'),
           NULL
    FROM core.account a
    WHERE a.billing_period = @billing_period
      AND (a.fee_schedule_code IS NULL
           OR NOT EXISTS (SELECT 1 FROM ref.fee_schedule r
                          WHERE r.schedule_code = a.fee_schedule_code));

    -- GAP-17 status outside the agreed set
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E10_STATUS_UNEXPECTED', 'REVIEW', 'ACCOUNT', account_id,
           CONCAT('status "', status,
                  '" is outside the agreed set; treated as billable pending confirmation'),
           NULL
    FROM core.account
    WHERE billing_period = @billing_period
      AND status NOT IN ('ACTIVE', 'CLOSED');

    -- GAP-16 closed inside the period
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E12_CLOSED_IN_PERIOD', 'INFO', 'ACCOUNT', a.account_id,
           CONCAT('closed ', CONVERT(varchar(10), a.close_date, 23),
                  '; final fee prorated to the closure date'),
           NULL
    FROM core.account a
    JOIN ref.billing_period p ON p.billing_period = a.billing_period
    WHERE a.billing_period = @billing_period
      AND a.close_date BETWEEN p.period_start AND p.period_end;

    -- GAP-07 opened inside the period
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E13_OPENED_IN_PERIOD', 'INFO', 'ACCOUNT', a.account_id,
           CONCAT('opened ', CONVERT(varchar(10), a.open_date, 23),
                  '; fee prorated from that date'),
           NULL
    FROM core.account a
    JOIN ref.billing_period p ON p.billing_period = a.billing_period
    WHERE a.billing_period = @billing_period
      AND a.open_date BETWEEN p.period_start AND p.period_end;

    -- Correctly out of scope, but recorded: no account leaves without a reason.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E14_OUT_OF_PERIOD', 'INFO', 'ACCOUNT', a.account_id,
           CASE WHEN a.close_date < p.period_start
                THEN CONCAT('closed ', CONVERT(varchar(10), a.close_date, 23),
                            ', before the period opened; no fee due')
                ELSE CONCAT('opened ', CONVERT(varchar(10), a.open_date, 23),
                            ', after the period closed; no fee due') END,
           NULL
    FROM core.account a
    JOIN ref.billing_period p ON p.billing_period = a.billing_period
    WHERE a.billing_period = @billing_period
      AND a.is_billable = 0
      AND ((a.close_date IS NOT NULL AND a.close_date < p.period_start)
        OR (a.open_date  IS NOT NULL AND a.open_date  > p.period_end));

    -- Account references a household that is not in the household extract
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E21_HOUSEHOLD_NOT_FOUND', 'BLOCKING', 'ACCOUNT', a.account_id,
           CONCAT('household_id "', a.household_id, '" is not in the household extract'),
           NULL
    FROM core.account a
    WHERE a.billing_period = @billing_period
      AND a.household_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM core.household h
                      WHERE h.billing_period = a.billing_period
                        AND h.household_id = a.household_id);
END;
GO
