-- =============================================================================
-- 01b_constraints.sql -- declared keys
--
-- Fabric Warehouse accepts PRIMARY KEY, UNIQUE and FOREIGN KEY only with
-- NOT ENFORCED. They document intent and help the optimiser; they do not stop
-- a duplicate from being inserted. Uniqueness is therefore guaranteed by the
-- procedures (the dedupe in etl.usp_conform and etl.usp_build_aum) and checked
-- after every run by 08_checks.sql. Do not read these as a safety net.
-- =============================================================================

ALTER TABLE ref.billing_period
    ADD CONSTRAINT pk_billing_period PRIMARY KEY NONCLUSTERED (billing_period) NOT ENFORCED;

ALTER TABLE ref.fee_schedule
    ADD CONSTRAINT pk_fee_schedule PRIMARY KEY NONCLUSTERED (schedule_code, tier_seq) NOT ENFORCED;

ALTER TABLE core.household
    ADD CONSTRAINT pk_household PRIMARY KEY NONCLUSTERED (billing_period, household_id) NOT ENFORCED;

ALTER TABLE core.account
    ADD CONSTRAINT pk_account PRIMARY KEY NONCLUSTERED (billing_period, account_id) NOT ENFORCED;

ALTER TABLE core.account_aum
    ADD CONSTRAINT pk_account_aum PRIMARY KEY NONCLUSTERED (billing_period, account_id) NOT ENFORCED;

ALTER TABLE core.fee_charge
    ADD CONSTRAINT pk_fee_charge PRIMARY KEY NONCLUSTERED (billing_period, account_id) NOT ENFORCED;

ALTER TABLE recon.parity
    ADD CONSTRAINT pk_parity PRIMARY KEY NONCLUSTERED (billing_period, account_id) NOT ENFORCED;
