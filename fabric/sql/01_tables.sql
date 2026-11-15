-- =============================================================================
-- 01_tables.sql -- table definitions for Fabric Warehouse
--
-- Fabric Warehouse type rules applied throughout:
--   * varchar, not nvarchar  (nvarchar is not supported for persisted tables)
--   * decimal for money, never float or money
--   * date / datetime2(6), not datetime
--   * no IDENTITY columns; keys are natural keys
--   * primary and foreign keys are declared NOT ENFORCED (see 01b), so the
--     uniqueness they describe is guaranteed by the procedures, not the engine
--
-- Every fact and log table carries billing_period so a rerun deletes only its
-- own period and can never destroy a prior one.
-- =============================================================================

-- ------------------------------------------------------------------ staging --
-- All varchar so COPY INTO can never fail on a bad value. A bad value becomes
-- an exception row downstream instead of a silently dropped record, which is
-- what Alteryx's IgnoreErrors=True did on the holdings input.

DROP TABLE IF EXISTS stg.accounts;
CREATE TABLE stg.accounts (
    account_id          varchar(50),
    household_id        varchar(50),
    account_name        varchar(200),
    account_type        varchar(50),
    fee_schedule_code   varchar(50),
    open_date           varchar(30),
    close_date          varchar(30),
    status              varchar(50),
    advisor_id          varchar(50),
    domicile_state      varchar(10)
);

DROP TABLE IF EXISTS stg.households;
CREATE TABLE stg.households (
    household_id            varchar(50),
    household_name          varchar(200),
    billing_method          varchar(50),
    relationship_manager    varchar(50),
    onboard_date            varchar(30)
);

DROP TABLE IF EXISTS stg.holdings;
CREATE TABLE stg.holdings (
    account_id      varchar(50),
    as_of_date      varchar(30),
    ticker          varchar(50),
    asset_class     varchar(50),
    quantity        varchar(50),
    market_value    varchar(50),
    custodian       varchar(50)
);

DROP TABLE IF EXISTS stg.fee_schedule;
CREATE TABLE stg.fee_schedule (
    schedule_code       varchar(50),
    tier_seq            varchar(10),
    tier_min            varchar(50),
    tier_max            varchar(50),
    annual_rate_bps     varchar(20),
    minimum_fee_qtr     varchar(20),
    schedule_name       varchar(200)
);

-- The invoice file the Alteryx workflow produced, landed so parity is proved
-- in SQL rather than by eye.
DROP TABLE IF EXISTS stg.legacy_billing;
CREATE TABLE stg.legacy_billing (
    account_id          varchar(50),
    household_id        varchar(50),
    account_name        varchar(200),
    fee_schedule_code   varchar(50),
    billing_period      varchar(10),
    total_aum           varchar(50),
    annual_rate_bps     varchar(20),
    gross_fee           varchar(50),
    billable_fee        varchar(50),
    advisor_id          varchar(50)
);

-- ---------------------------------------------------------------- reference --

DROP TABLE IF EXISTS ref.billing_period;
CREATE TABLE ref.billing_period (
    billing_period      varchar(10)     NOT NULL,
    period_start        date            NOT NULL,
    period_end          date            NOT NULL,
    valuation_date      date            NOT NULL,
    days_in_period      int             NOT NULL,
    days_in_year        int             NOT NULL
);

-- tier_max NULL = the top, unbounded tier.
DROP TABLE IF EXISTS ref.fee_schedule;
CREATE TABLE ref.fee_schedule (
    schedule_code       varchar(20)     NOT NULL,
    tier_seq            int             NOT NULL,
    tier_min            decimal(18,2)   NOT NULL,
    tier_max            decimal(18,2)   NULL,
    annual_rate_bps     decimal(9,4)    NOT NULL,
    minimum_fee_qtr     decimal(18,2)   NOT NULL,
    schedule_name       varchar(100)    NULL
);

-- --------------------------------------------------------------------- core --

DROP TABLE IF EXISTS core.household;
CREATE TABLE core.household (
    billing_period          varchar(10)     NOT NULL,
    household_id            varchar(50)     NOT NULL,
    household_name          varchar(200)    NULL,
    billing_method          varchar(20)     NOT NULL,   -- ACCOUNT | HOUSEHOLD | UNKNOWN
    relationship_manager    varchar(50)     NULL
);

DROP TABLE IF EXISTS core.account;
CREATE TABLE core.account (
    billing_period      varchar(10)     NOT NULL,
    account_id          varchar(50)     NOT NULL,   -- trimmed, upper-cased
    account_id_source   varchar(50)     NULL,       -- exactly as the file gave it
    household_id        varchar(50)     NULL,
    account_name        varchar(200)    NULL,
    account_type        varchar(50)     NULL,
    fee_schedule_code   varchar(20)     NULL,
    open_date           date            NULL,
    close_date          date            NULL,
    status              varchar(50)     NULL,
    advisor_id          varchar(50)     NULL,
    is_billable         bit             NOT NULL
);

DROP TABLE IF EXISTS core.account_aum;
CREATE TABLE core.account_aum (
    billing_period      varchar(10)     NOT NULL,
    account_id          varchar(50)     NOT NULL,
    valuation_date      date            NOT NULL,
    market_value        decimal(18,2)   NOT NULL,
    position_count      int             NOT NULL,
    unpriced_positions  int             NOT NULL
);

DROP TABLE IF EXISTS core.fee_charge;
CREATE TABLE core.fee_charge (
    billing_period          varchar(10)     NOT NULL,
    account_id              varchar(50)     NOT NULL,
    household_id            varchar(50)     NULL,
    billing_entity          varchar(10)     NOT NULL,   -- ACCOUNT | HOUSEHOLD
    tiering_basis_aum       decimal(18,2)   NOT NULL,
    account_aum             decimal(18,2)   NOT NULL,
    days_billable           int             NOT NULL,
    days_in_period          int             NOT NULL,
    proration_factor        decimal(9,6)    NOT NULL,
    schedule_code           varchar(20)     NOT NULL,
    effective_rate_bps      decimal(9,2)    NOT NULL,
    gross_fee               decimal(18,2)   NOT NULL,
    minimum_fee_applied     decimal(18,2)   NOT NULL,
    billable_fee            decimal(18,2)   NOT NULL
);

-- -------------------------------------------------------------------- audit --

DROP TABLE IF EXISTS audit.exception_log;
CREATE TABLE audit.exception_log (
    billing_period  varchar(10)     NOT NULL,
    reason_code     varchar(40)     NOT NULL,
    severity        varchar(10)     NOT NULL,   -- BLOCKING | REVIEW | INFO
    entity_type     varchar(10)     NOT NULL,   -- ACCOUNT | HOLDING | HOUSEHOLD
    entity_id       varchar(50)     NULL,
    detail          varchar(400)    NULL,
    amount_at_risk  decimal(18,2)   NULL
);

DROP TABLE IF EXISTS audit.run_log;
CREATE TABLE audit.run_log (
    billing_period      varchar(10)     NOT NULL,
    run_started_utc     datetime2(6)    NOT NULL,
    run_finished_utc    datetime2(6)    NULL,
    outcome             varchar(20)     NOT NULL,   -- SUCCEEDED | FAILED
    accounts_billed     int             NULL,
    fees_billed         decimal(18,2)   NULL,
    blocking_exceptions int             NULL,
    unexplained_variances int           NULL,
    error_message       varchar(4000)   NULL
);

-- -------------------------------------------------------------------- recon --

DROP TABLE IF EXISTS recon.legacy_billing;
CREATE TABLE recon.legacy_billing (
    billing_period      varchar(10)     NOT NULL,
    account_id          varchar(50)     NOT NULL,
    legacy_row_count    int             NOT NULL,
    legacy_fee          decimal(18,2)   NOT NULL,
    legacy_aum          decimal(18,2)   NULL,
    legacy_rate_bps     int             NULL
);

DROP TABLE IF EXISTS recon.parity;
CREATE TABLE recon.parity (
    billing_period      varchar(10)     NOT NULL,
    account_id          varchar(50)     NOT NULL,
    outcome             varchar(12)     NOT NULL,   -- MATCH | DIFFERS | LEGACY_ONLY | TARGET_ONLY
    legacy_fee          decimal(18,2)   NULL,
    target_fee          decimal(18,2)   NULL,
    fee_variance        decimal(18,2)   NOT NULL,
    legacy_aum          decimal(18,2)   NULL,
    target_aum          decimal(18,2)   NULL,
    billing_entity      varchar(10)     NULL,
    schedule_code       varchar(20)     NULL,
    proration_factor    decimal(9,6)    NULL,
    reason_codes        varchar(1000)   NULL,
    attribution         varchar(200)    NOT NULL
);
