-- =============================================================================
-- 07_etl_run_quarter.sql -- the single entry point
--
-- One call runs the quarter end to end, inside one transaction, and records
-- the outcome in audit.run_log whether it succeeds or fails. This is what a
-- Fabric pipeline's Stored procedure activity calls.
--
-- GAP-08: the period is a parameter. The Alteryx workflow hard-coded
-- "2026-09-30" in a Filter and "2026Q3" in a Formula, edited by hand each
-- quarter; a typo there produced an empty invoice run with no error.
--
--   EXEC etl.usp_run_quarter
--        @billing_period = '2026Q3',
--        @period_start   = '2026-07-01',
--        @period_end     = '2026-09-30',
--        @valuation_date = '2026-09-30';
-- =============================================================================

DROP PROCEDURE IF EXISTS etl.usp_run_quarter;
GO
CREATE PROCEDURE etl.usp_run_quarter
    @billing_period varchar(10),
    @period_start   date,
    @period_end     date,
    @valuation_date date,
    @days_in_year   int = 365       -- GAP-06: 365, or actual/actual if agreed
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @started datetime2(6) = SYSUTCDATETIME();

    -- Refuse a period that cannot be right before touching anything.
    IF @period_end < @period_start OR @valuation_date NOT BETWEEN @period_start AND @period_end
    BEGIN
        THROW 50001, 'Invalid period: end before start, or valuation date outside the period.', 1;
    END;

    IF NOT EXISTS (SELECT 1 FROM stg.accounts) OR NOT EXISTS (SELECT 1 FROM stg.holdings)
    BEGIN
        THROW 50002, 'Staging is empty. Run the load (02_load_stage.sql) before the quarter.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM ref.billing_period WHERE billing_period = @billing_period;
        INSERT INTO ref.billing_period
            (billing_period, period_start, period_end, valuation_date,
             days_in_period, days_in_year)
        VALUES
            (@billing_period, @period_start, @period_end, @valuation_date,
             DATEDIFF(day, @period_start, @period_end) + 1, @days_in_year);

        -- A rerun replaces this period's exceptions, never another period's.
        DELETE FROM audit.exception_log WHERE billing_period = @billing_period;

        EXEC etl.usp_load_reference;
        EXEC etl.usp_conform     @billing_period = @billing_period;
        EXEC etl.usp_build_aum   @billing_period = @billing_period;
        EXEC etl.usp_calc_fees   @billing_period = @billing_period;
        EXEC etl.usp_reconcile   @billing_period = @billing_period;

        COMMIT TRANSACTION;

        INSERT INTO audit.run_log
            (billing_period, run_started_utc, run_finished_utc, outcome,
             accounts_billed, fees_billed, blocking_exceptions,
             unexplained_variances, error_message)
        SELECT
            @billing_period, @started, SYSUTCDATETIME(), 'SUCCEEDED',
            (SELECT COUNT(*) FROM core.fee_charge WHERE billing_period = @billing_period),
            (SELECT SUM(billable_fee) FROM core.fee_charge WHERE billing_period = @billing_period),
            (SELECT COUNT(*) FROM audit.exception_log
              WHERE billing_period = @billing_period AND severity = 'BLOCKING'),
            (SELECT COUNT(*) FROM recon.parity
              WHERE billing_period = @billing_period AND attribution = 'UNEXPLAINED'),
            NULL;

        -- The run's headline, returned to the caller (and to the pipeline).
        SELECT TOP 1 * FROM audit.run_log
        WHERE billing_period = @billing_period
        ORDER BY run_started_utc DESC;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        INSERT INTO audit.run_log
            (billing_period, run_started_utc, run_finished_utc, outcome, error_message)
        VALUES
            (@billing_period, @started, SYSUTCDATETIME(), 'FAILED',
             CONCAT(ERROR_NUMBER(), ': ', ERROR_MESSAGE()));

        THROW;
    END CATCH;
END;
GO
