-- =============================================================================
-- 04_etl_build_aum.sql -- positions to billable assets under management
--
-- Replaces Alteryx Tool 3 (Filter as_of_date = "2026-09-30") and Tool 4
-- (Summarize). Three legacy failures are handled explicitly:
--   GAP-15  a position priced a day early was dropped by the hard-coded date
--   GAP-19  an exact duplicate row was counted twice by the Summarize
--   GAP-20  a null market value contributed zero with no error
-- =============================================================================

DROP PROCEDURE IF EXISTS etl.usp_build_aum;
GO
CREATE PROCEDURE etl.usp_build_aum
    @billing_period varchar(10)
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM core.account_aum WHERE billing_period = @billing_period;

    DROP TABLE IF EXISTS #holding;
    DROP TABLE IF EXISTS #position;

    -- Typed and ranked so byte-identical rows can be collapsed (GAP-19).
    SELECT
        UPPER(TRIM(h.account_id))                       AS account_id,
        TRY_CAST(TRIM(h.as_of_date) AS date)            AS as_of_date,
        TRIM(h.as_of_date)                              AS as_of_raw,
        UPPER(TRIM(h.ticker))                           AS ticker,
        UPPER(TRIM(h.asset_class))                      AS asset_class,
        TRIM(h.market_value)                            AS market_value_raw,
        TRY_CAST(NULLIF(TRIM(h.market_value), '') AS decimal(18,2)) AS market_value,
        ROW_NUMBER() OVER (
            PARTITION BY UPPER(TRIM(h.account_id)), TRIM(h.as_of_date),
                         UPPER(TRIM(h.ticker)), TRIM(h.market_value)
            ORDER BY h.custodian, h.quantity
        )                                               AS dup_seq
    INTO #holding
    FROM stg.holdings h;

    -- One price per position: the latest on or before the valuation date and
    -- inside the period (GAP-15). The legacy flow kept only exact-date rows.
    SELECT
        r.account_id, r.ticker, r.asset_class, r.as_of_date, r.market_value,
        CASE WHEN r.market_value IS NULL THEN 1 ELSE 0 END AS value_is_null,
        p.valuation_date
    INTO #position
    FROM (
        SELECT
            d.*,
            -- RANK, not ROW_NUMBER: several lots of one ticker on the same
            -- date are separate positions and all of them count.
            RANK() OVER (
                PARTITION BY d.account_id, d.ticker
                ORDER BY d.as_of_date DESC
            ) AS price_seq
        FROM #holding d
        CROSS JOIN ref.billing_period bp
        WHERE bp.billing_period = @billing_period
          AND d.dup_seq = 1
          AND d.as_of_date <= bp.valuation_date
          AND d.as_of_date >= bp.period_start
    ) r
    CROSS JOIN ref.billing_period p
    WHERE p.billing_period = @billing_period
      AND r.price_seq = 1;

    -- ------------------------------------------------------------- the fact --
    INSERT INTO core.account_aum
        (billing_period, account_id, valuation_date, market_value,
         position_count, unpriced_positions)
    SELECT
        @billing_period,
        pos.account_id,
        pos.valuation_date,
        COALESCE(SUM(CASE WHEN pos.value_is_null = 0 THEN pos.market_value END), 0),
        COUNT(*),
        SUM(pos.value_is_null)
    FROM #position pos
    JOIN core.account a
      ON a.account_id = pos.account_id AND a.billing_period = @billing_period
    GROUP BY pos.account_id, pos.valuation_date;

    -- ============================================================ exceptions ==

    -- GAP-11 holdings with no account record: the Alteryx join discarded these.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E01_HOLDING_WITHOUT_ACCOUNT', 'BLOCKING', 'ACCOUNT',
           pos.account_id,
           CONCAT(COUNT(*), ' positions totalling ',
                  CAST(SUM(COALESCE(pos.market_value, 0)) AS varchar(30)),
                  ' have no matching account record; no fee can be raised'),
           SUM(COALESCE(pos.market_value, 0))
    FROM #position pos
    WHERE NOT EXISTS (SELECT 1 FROM core.account a
                      WHERE a.billing_period = @billing_period
                        AND a.account_id = pos.account_id)
    GROUP BY pos.account_id;

    -- GAP-13 billable account absent from the holdings extract
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E02_ACCOUNT_WITHOUT_HOLDINGS', 'BLOCKING', 'ACCOUNT',
           a.account_id,
           'account is billable but absent from the holdings extract; either unfunded or the extract is incomplete',
           NULL
    FROM core.account a
    WHERE a.billing_period = @billing_period
      AND a.is_billable = 1
      AND NOT EXISTS (SELECT 1 FROM core.account_aum f
                      WHERE f.billing_period = @billing_period
                        AND f.account_id = a.account_id);

    -- GAP-28 several lots of one ticker on the price date: summed, and raised
    -- because a second lot can also be a custodian restatement.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E26_MULTIPLE_LOTS_SAME_TICKER', 'REVIEW', 'HOLDING',
           pos.account_id,
           CONCAT('ticker ', pos.ticker, ' has ', COUNT(*), ' positions on ',
                  CONVERT(varchar(10), pos.as_of_date, 23),
                  ' with different values; summed as separate lots'),
           SUM(pos.market_value)
    FROM #position pos
    JOIN core.account a
      ON a.account_id = pos.account_id AND a.billing_period = @billing_period
    GROUP BY pos.account_id, pos.ticker, pos.as_of_date
    HAVING COUNT(*) > 1;

    -- GAP-19 duplicate positions collapsed
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E05_DUPLICATE_POSITION', 'REVIEW', 'HOLDING',
           account_id,
           CONCAT('ticker ', ticker, ' appears ', MAX(dup_seq),
                  ' times with an identical value on ', as_of_raw, '; counted once'),
           MAX(market_value) * (MAX(dup_seq) - 1)
    FROM #holding
    GROUP BY account_id, as_of_raw, ticker, market_value_raw
    HAVING MAX(dup_seq) > 1;

    -- A position date that would not parse; it cannot be placed in any period.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E25_POSITION_DATE_UNPARSEABLE', 'BLOCKING', 'HOLDING',
           account_id,
           CONCAT('ticker ', ticker, ' has as_of_date "', as_of_raw, '"; position ignored'),
           market_value
    FROM #holding
    WHERE as_of_date IS NULL AND dup_seq = 1;

    -- GAP-20 unpriced position: excluded and raised, never treated as zero
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E06_POSITION_VALUE_NULL', 'BLOCKING', 'HOLDING',
           pos.account_id,
           CONCAT('ticker ', pos.ticker, ' (', pos.asset_class,
                  ') has no market value; excluded from billable AUM pending a price'),
           NULL
    FROM #position pos
    JOIN core.account a
      ON a.account_id = pos.account_id AND a.billing_period = @billing_period
    WHERE pos.value_is_null = 1;

    -- GAP-15 price taken from a date other than the valuation date
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E11_PRICE_NOT_ON_VALUATION_DATE', 'REVIEW', 'HOLDING',
           pos.account_id,
           CONCAT('ticker ', pos.ticker, ' priced ',
                  CONVERT(varchar(10), pos.as_of_date, 23), ' not ',
                  CONVERT(varchar(10), pos.valuation_date, 23),
                  '; most recent price in the period was used'),
           pos.market_value
    FROM #position pos
    JOIN core.account a
      ON a.account_id = pos.account_id AND a.billing_period = @billing_period
    WHERE pos.as_of_date <> pos.valuation_date;

    -- GAP-21 open policy: margin debits netted against AUM, pending confirmation
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E15_NEGATIVE_POSITION', 'REVIEW', 'HOLDING',
           pos.account_id,
           CONCAT('ticker ', pos.ticker, ' carries a negative value of ',
                  CAST(pos.market_value AS varchar(30)), '; netted against billable AUM'),
           ABS(pos.market_value)
    FROM #position pos
    JOIN core.account a
      ON a.account_id = pos.account_id AND a.billing_period = @billing_period
    WHERE pos.market_value < 0;

    -- GAP-22 open policy: is cash fee-billable?
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period, 'E16_CASH_ONLY_ACCOUNT', 'REVIEW', 'ACCOUNT',
           pos.account_id,
           'entire balance is cash or cash equivalents; billable only if the agreement includes cash',
           SUM(pos.market_value)
    FROM #position pos
    JOIN core.account a
      ON a.account_id = pos.account_id AND a.billing_period = @billing_period
    GROUP BY pos.account_id
    HAVING SUM(CASE WHEN pos.asset_class = 'CASH_EQ' THEN 0 ELSE 1 END) = 0;

    -- GAP-05 nothing to bill on. Alteryx charged these the $250 minimum.
    INSERT INTO audit.exception_log
        (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
    SELECT @billing_period,
           CASE WHEN f.market_value < 0 THEN 'E09_AUM_NEGATIVE' ELSE 'E09_AUM_ZERO' END,
           'REVIEW', 'ACCOUNT', f.account_id,
           CONCAT('billable AUM is ', CAST(f.market_value AS varchar(30)),
                  '; no fee raised and the minimum is not applied'),
           NULL
    FROM core.account_aum f
    JOIN core.account a
      ON a.account_id = f.account_id AND a.billing_period = f.billing_period
    WHERE f.billing_period = @billing_period
      AND a.is_billable = 1
      AND f.market_value <= 0;

    DROP TABLE IF EXISTS #holding;
    DROP TABLE IF EXISTS #position;
END;
GO
