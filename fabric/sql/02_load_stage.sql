-- =============================================================================
-- 02_load_stage.sql -- land the quarter's files into staging
--
-- Replaces Alteryx Tools 1 and 2 (Input Data). Upload the CSVs to the
-- lakehouse first:
--
--   lh_billing / Files / billing / 2026Q3 / accounts.csv
--                                          households.csv
--                                          holdings.csv
--                                          fee_schedule.csv
--                                          legacy_billing.csv
--
-- Then replace <workspace> and <lakehouse> below with your workspace and
-- lakehouse names (or their GUIDs). Right-click a file in the lakehouse and
-- choose Properties to copy its exact ABFS/HTTPS path.
--
-- COPY INTO from a OneLake path is a preview feature of Fabric Warehouse and
-- authenticates as the signed-in Entra user; no credential clause is needed.
-- If it is unavailable in your tenant, use a pipeline Copy activity with the
-- same five sources and targets instead.
--
-- Truncate first so a rerun of the load cannot double the staging rows.
-- =============================================================================

TRUNCATE TABLE stg.accounts;
TRUNCATE TABLE stg.households;
TRUNCATE TABLE stg.holdings;
TRUNCATE TABLE stg.fee_schedule;
TRUNCATE TABLE stg.legacy_billing;

COPY INTO stg.accounts
FROM 'https://onelake.dfs.fabric.microsoft.com/<workspace>/<lakehouse>.Lakehouse/Files/billing/2026Q3/accounts.csv'
WITH (FILE_TYPE = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', FIELDQUOTE = '"');

COPY INTO stg.households
FROM 'https://onelake.dfs.fabric.microsoft.com/<workspace>/<lakehouse>.Lakehouse/Files/billing/2026Q3/households.csv'
WITH (FILE_TYPE = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', FIELDQUOTE = '"');

COPY INTO stg.holdings
FROM 'https://onelake.dfs.fabric.microsoft.com/<workspace>/<lakehouse>.Lakehouse/Files/billing/2026Q3/holdings.csv'
WITH (FILE_TYPE = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', FIELDQUOTE = '"');

COPY INTO stg.fee_schedule
FROM 'https://onelake.dfs.fabric.microsoft.com/<workspace>/<lakehouse>.Lakehouse/Files/billing/2026Q3/fee_schedule.csv'
WITH (FILE_TYPE = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', FIELDQUOTE = '"');

COPY INTO stg.legacy_billing
FROM 'https://onelake.dfs.fabric.microsoft.com/<workspace>/<lakehouse>.Lakehouse/Files/billing/2026Q3/legacy_billing.csv'
WITH (FILE_TYPE = 'CSV', FIRSTROW = 2, FIELDTERMINATOR = ',', FIELDQUOTE = '"');

-- Row counts to compare against the files before running the procedures.
-- Expected for the sample data: 121, 60, 655, 8, 116.
SELECT 'stg.accounts' AS table_name, COUNT(*) AS row_count FROM stg.accounts
UNION ALL SELECT 'stg.households', COUNT(*) FROM stg.households
UNION ALL SELECT 'stg.holdings', COUNT(*) FROM stg.holdings
UNION ALL SELECT 'stg.fee_schedule', COUNT(*) FROM stg.fee_schedule
UNION ALL SELECT 'stg.legacy_billing', COUNT(*) FROM stg.legacy_billing;
