-- =============================================================================
-- 00_schemas.sql -- Fabric Warehouse: wh_billing
--
-- Run each block separately in the Fabric SQL editor, or the whole file in
-- SSMS / VS Code (mssql), which honour the GO separator.
--
--   stg     raw landing, every column varchar, nothing rejected on load
--   ref     reference data the business owns (fee schedule, billing periods)
--   core    conformed entities and facts, keyed by billing period
--   audit   exception log and run log
--   recon   legacy baseline and the parity reconciliation
--   etl     stored procedures
-- =============================================================================

CREATE SCHEMA stg;
GO
CREATE SCHEMA ref;
GO
CREATE SCHEMA core;
GO
CREATE SCHEMA audit;
GO
CREATE SCHEMA recon;
GO
CREATE SCHEMA etl;
GO
