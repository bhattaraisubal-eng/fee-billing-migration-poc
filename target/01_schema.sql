-- =============================================================================
-- 01_schema.sql -- target model for quarterly advisory fee billing
--
-- Layers:
--   stg_*   raw landing, every column text, nothing rejected
--   dim_*   conformed entities, keys normalised, duplicates resolved
--   fact_*  measures by account and billing period
--   ref_*   reference data the business owns
--   exception_log  every record that did not reach an invoice, with a reason
--
-- Written for SQL Server / Fabric semantics but executes on SQLite so the proof
-- of concept runs with no server. Portability notes are in target/PORTING.md.
-- =============================================================================

DROP TABLE IF EXISTS exception_log;
DROP TABLE IF EXISTS fact_fee_charge;
DROP TABLE IF EXISTS fact_account_aum;
DROP TABLE IF EXISTS dim_account;
DROP TABLE IF EXISTS dim_household;
DROP TABLE IF EXISTS ref_fee_schedule;
DROP TABLE IF EXISTS ref_billing_period;
DROP TABLE IF EXISTS stg_holdings;
DROP TABLE IF EXISTS stg_accounts;
DROP TABLE IF EXISTS stg_households;
DROP TABLE IF EXISTS stg_fee_schedule;
DROP TABLE IF EXISTS legacy_billing;

-- ----------------------------------------------------------------- staging ---
-- Text-typed on purpose. Landing a file must never fail on a bad value; the
-- value becomes an exception downstream instead of vanishing on read.

CREATE TABLE stg_accounts (
    account_id          TEXT,
    household_id        TEXT,
    account_name        TEXT,
    account_type        TEXT,
    fee_schedule_code   TEXT,
    open_date           TEXT,
    close_date          TEXT,
    status              TEXT,
    advisor_id          TEXT,
    domicile_state      TEXT,
    source_row          INTEGER
);

CREATE TABLE stg_households (
    household_id            TEXT,
    household_name          TEXT,
    billing_method          TEXT,
    relationship_manager    TEXT,
    onboard_date            TEXT,
    source_row              INTEGER
);

CREATE TABLE stg_holdings (
    account_id      TEXT,
    as_of_date      TEXT,
    ticker          TEXT,
    asset_class     TEXT,
    quantity        TEXT,
    market_value    TEXT,
    custodian       TEXT,
    source_row      INTEGER
);

CREATE TABLE stg_fee_schedule (
    schedule_code       TEXT,
    tier_seq            TEXT,
    tier_min            TEXT,
    tier_max            TEXT,
    annual_rate_bps     TEXT,
    minimum_fee_qtr     TEXT,
    schedule_name       TEXT,
    source_row          INTEGER
);

-- The legacy invoice file, loaded so parity can be proved in SQL rather than
-- by eye in a spreadsheet.
CREATE TABLE legacy_billing (
    account_id          TEXT,
    household_id        TEXT,
    account_name        TEXT,
    fee_schedule_code   TEXT,
    billing_period      TEXT,
    total_aum           REAL,
    annual_rate_bps     INTEGER,
    gross_fee           REAL,
    billable_fee        REAL,
    advisor_id          TEXT
);

-- --------------------------------------------------------------- reference ---

CREATE TABLE ref_billing_period (
    billing_period      TEXT PRIMARY KEY,
    period_start        TEXT NOT NULL,
    period_end          TEXT NOT NULL,
    valuation_date      TEXT NOT NULL,
    days_in_period      INTEGER NOT NULL,
    days_in_year        INTEGER NOT NULL
);

-- GAP-02: rates live here, not in a formula. Changing the published schedule is
-- a data change, not a code change.
-- tier_max = NULL means the top, unbounded tier.
CREATE TABLE ref_fee_schedule (
    schedule_code       TEXT NOT NULL,
    tier_seq            INTEGER NOT NULL,
    tier_min            REAL NOT NULL,
    tier_max            REAL,
    annual_rate_bps     REAL NOT NULL,
    minimum_fee_qtr     REAL NOT NULL,
    schedule_name       TEXT,
    PRIMARY KEY (schedule_code, tier_seq)
);

-- -------------------------------------------------------------- dimensions ---

CREATE TABLE dim_household (
    household_id            TEXT PRIMARY KEY,
    household_name          TEXT,
    billing_method          TEXT NOT NULL,   -- ACCOUNT | HOUSEHOLD
    relationship_manager    TEXT
);

CREATE TABLE dim_account (
    account_id          TEXT PRIMARY KEY,   -- normalised: trimmed, upper
    account_id_source   TEXT,               -- exactly as the file gave it
    household_id        TEXT,
    account_name        TEXT,
    account_type        TEXT,
    fee_schedule_code   TEXT,
    open_date           TEXT,
    close_date          TEXT,
    status              TEXT,
    advisor_id          TEXT,
    is_billable         INTEGER NOT NULL,   -- survived validation
    FOREIGN KEY (household_id) REFERENCES dim_household (household_id)
);

-- ------------------------------------------------------------------- facts ---

CREATE TABLE fact_account_aum (
    billing_period      TEXT NOT NULL,
    account_id          TEXT NOT NULL,
    valuation_date      TEXT NOT NULL,
    market_value        REAL NOT NULL,
    position_count      INTEGER NOT NULL,
    excluded_value      REAL NOT NULL DEFAULT 0,  -- priced outside the period
    PRIMARY KEY (billing_period, account_id)
);

CREATE TABLE fact_fee_charge (
    billing_period          TEXT NOT NULL,
    account_id              TEXT NOT NULL,
    household_id            TEXT,
    billing_entity          TEXT NOT NULL,   -- ACCOUNT | HOUSEHOLD
    tiering_basis_aum       REAL NOT NULL,   -- what the tiers were applied to
    account_aum             REAL NOT NULL,
    days_billable           INTEGER NOT NULL,
    days_in_period          INTEGER NOT NULL,
    proration_factor        REAL NOT NULL,
    schedule_code           TEXT NOT NULL,
    effective_rate_bps      REAL NOT NULL,   -- blended, derived not assumed
    gross_fee               REAL NOT NULL,
    minimum_fee_applied     REAL NOT NULL DEFAULT 0,
    billable_fee            REAL NOT NULL,
    PRIMARY KEY (billing_period, account_id)
);

-- GAP-04, GAP-10, GAP-14: the legacy workflow discards records at five points
-- with no trace. Nothing may leave this pipeline without a row here.
CREATE TABLE exception_log (
    billing_period  TEXT,
    reason_code     TEXT NOT NULL,
    severity        TEXT NOT NULL,   -- BLOCKING | REVIEW | INFO
    entity_type     TEXT NOT NULL,   -- ACCOUNT | HOLDING | HOUSEHOLD
    entity_id       TEXT,
    detail          TEXT,
    amount_at_risk  REAL
);

CREATE INDEX ix_exception_reason ON exception_log (reason_code);
CREATE INDEX ix_holdings_account ON stg_holdings (account_id);
