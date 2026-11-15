-- =============================================================================
-- 03_aum.sql -- holdings to billable assets under management
--
-- The legacy workflow did this in one Summarize over a hard-coded date filter.
-- Three things went wrong there and are handled explicitly here: positions
-- priced a day early were dropped, an exact duplicate row was counted twice,
-- and a null market value silently contributed zero.
-- =============================================================================

DELETE FROM fact_account_aum;

-- GAP-19: collapse byte-identical position rows. Keeping the lowest source_row
-- makes the choice deterministic and reproducible across runs.
DROP VIEW IF EXISTS v_holdings_deduped;
CREATE VIEW v_holdings_deduped AS
WITH ranked AS (
    SELECT
        TRIM(UPPER(h.account_id))               AS account_id,
        TRIM(h.as_of_date)                      AS as_of_date,
        TRIM(UPPER(h.ticker))                   AS ticker,
        TRIM(UPPER(h.asset_class))              AS asset_class,
        h.market_value                          AS market_value_raw,
        h.source_row,
        ROW_NUMBER() OVER (
            PARTITION BY TRIM(UPPER(h.account_id)), TRIM(h.as_of_date),
                         TRIM(UPPER(h.ticker)), TRIM(h.market_value)
            ORDER BY h.source_row
        ) AS dup_seq
    FROM stg_holdings h
)
SELECT account_id, as_of_date, ticker, asset_class, market_value_raw, source_row
FROM ranked
WHERE dup_seq = 1;

-- GAP-15: one price per position, the most recent on or before the valuation
-- date and inside the period. A position stale-dated by the custodian is used
-- rather than discarded; discarding it understated one account by $842,150.
DROP VIEW IF EXISTS v_position_asof;
CREATE VIEW v_position_asof AS
WITH period AS (SELECT * FROM ref_billing_period),
priced AS (
    SELECT
        d.*,
        p.billing_period,
        p.valuation_date,
        ROW_NUMBER() OVER (
            PARTITION BY d.account_id, d.ticker
            ORDER BY d.as_of_date DESC, d.source_row
        ) AS price_seq
    FROM v_holdings_deduped d
    CROSS JOIN period p
    WHERE d.as_of_date <= p.valuation_date
      AND d.as_of_date >= p.period_start
)
SELECT
    billing_period, account_id, ticker, asset_class, as_of_date, valuation_date,
    CASE WHEN TRIM(COALESCE(market_value_raw, '')) = '' THEN NULL
         ELSE CAST(market_value_raw AS REAL) END AS market_value,
    TRIM(COALESCE(market_value_raw, '')) = ''    AS value_is_null
FROM priced
WHERE price_seq = 1;

-- ---------------------------------------------------------------- the fact ---
-- GAP-15 note: excluded_value carries what a null price kept out of the total,
-- so an understated account is visible instead of merely wrong.
INSERT INTO fact_account_aum
    (billing_period, account_id, valuation_date, market_value, position_count, excluded_value)
SELECT
    v.billing_period,
    v.account_id,
    v.valuation_date,
    COALESCE(SUM(CASE WHEN v.value_is_null = 0 THEN v.market_value END), 0),
    COUNT(*),
    SUM(CASE WHEN v.value_is_null = 1 THEN 1 ELSE 0 END)
FROM v_position_asof v
-- Only accounts the conform layer recognised. Orphans are logged below, not
-- joined away in silence.
JOIN dim_account a ON a.account_id = v.account_id
GROUP BY v.billing_period, v.account_id, v.valuation_date;

-- ============================ exceptions ====================================

-- GAP-11: holdings whose account is not in the account extract. The legacy
-- inner join dropped these and the revenue was never invoiced.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    v.billing_period, 'E01_HOLDING_WITHOUT_ACCOUNT', 'BLOCKING', 'ACCOUNT',
    v.account_id,
    COUNT(*) || ' positions totalling ' ||
    PRINTF('%.2f', SUM(COALESCE(v.market_value, 0))) ||
    ' have no matching account record; no fee can be raised',
    SUM(COALESCE(v.market_value, 0))
FROM v_position_asof v
LEFT JOIN dim_account a ON a.account_id = v.account_id
WHERE a.account_id IS NULL
GROUP BY v.billing_period, v.account_id;

-- GAP-13: a billable account the custodian extract does not cover at all.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    p.billing_period, 'E02_ACCOUNT_WITHOUT_HOLDINGS', 'BLOCKING', 'ACCOUNT',
    a.account_id,
    'account is billable but absent from the holdings extract; either unfunded or the extract is incomplete',
    NULL
FROM dim_account a
CROSS JOIN ref_billing_period p
WHERE a.is_billable = 1
  AND NOT EXISTS (SELECT 1 FROM fact_account_aum f
                  WHERE f.account_id = a.account_id
                    AND f.billing_period = p.billing_period);

-- GAP-19 duplicate positions collapsed
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    (SELECT billing_period FROM ref_billing_period),
    'E05_DUPLICATE_POSITION', 'REVIEW', 'HOLDING',
    TRIM(UPPER(account_id)),
    'ticker ' || TRIM(UPPER(ticker)) || ' appears ' || COUNT(*) ||
    ' times with an identical value on ' || TRIM(as_of_date) || '; counted once',
    CAST(TRIM(market_value) AS REAL) * (COUNT(*) - 1)
FROM stg_holdings
GROUP BY TRIM(UPPER(account_id)), TRIM(as_of_date), TRIM(UPPER(ticker)), TRIM(market_value)
HAVING COUNT(*) > 1;

-- GAP-20: a position with no price. Excluded from AUM and raised, rather than
-- contributing zero and underbilling the client without a word.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    v.billing_period, 'E06_POSITION_VALUE_NULL', 'BLOCKING', 'HOLDING',
    v.account_id,
    'ticker ' || v.ticker || ' (' || v.asset_class ||
    ') has no market value; excluded from billable AUM pending a price',
    NULL
FROM v_position_asof v
JOIN dim_account a ON a.account_id = v.account_id
WHERE v.value_is_null = 1;

-- GAP-15: price taken from a date other than the valuation date
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    v.billing_period, 'E11_PRICE_NOT_ON_VALUATION_DATE', 'REVIEW', 'HOLDING',
    v.account_id,
    'ticker ' || v.ticker || ' priced ' || v.as_of_date || ' not ' ||
    v.valuation_date || '; most recent price in the period was used',
    v.market_value
FROM v_position_asof v
JOIN dim_account a ON a.account_id = v.account_id
WHERE v.as_of_date <> v.valuation_date;

-- Open policy question: does a margin debit reduce billable AUM, or is AUM
-- billed gross of borrowing? Netted here, and surfaced for confirmation.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    v.billing_period, 'E15_NEGATIVE_POSITION', 'REVIEW', 'HOLDING',
    v.account_id,
    'ticker ' || v.ticker || ' carries a negative value of ' ||
    PRINTF('%.2f', v.market_value) || '; netted against billable AUM',
    ABS(v.market_value)
FROM v_position_asof v
JOIN dim_account a ON a.account_id = v.account_id
WHERE v.market_value < 0;

-- Open policy question: many advisory agreements exclude cash from the fee base.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    v.billing_period, 'E16_CASH_ONLY_ACCOUNT', 'REVIEW', 'ACCOUNT',
    v.account_id,
    'entire balance is cash or cash equivalents; billable only if the agreement includes cash',
    SUM(v.market_value)
FROM v_position_asof v
JOIN dim_account a ON a.account_id = v.account_id
GROUP BY v.billing_period, v.account_id
HAVING SUM(CASE WHEN v.asset_class = 'CASH_EQ' THEN 0 ELSE 1 END) = 0;

-- GAP-05: nothing to bill on. The legacy flow charged these the $250 minimum.
INSERT INTO exception_log
    (billing_period, reason_code, severity, entity_type, entity_id, detail, amount_at_risk)
SELECT
    f.billing_period,
    CASE WHEN f.market_value < 0 THEN 'E09_AUM_NEGATIVE' ELSE 'E09_AUM_ZERO' END,
    'REVIEW', 'ACCOUNT', f.account_id,
    'billable AUM is ' || PRINTF('%.2f', f.market_value) ||
    '; no fee raised and the minimum is not applied',
    NULL
FROM fact_account_aum f
JOIN dim_account a ON a.account_id = f.account_id AND a.is_billable = 1
WHERE f.market_value <= 0;
