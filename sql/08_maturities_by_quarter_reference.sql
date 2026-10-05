/* =============================================================================
   08_maturities_by_quarter_reference.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Reconciliation reference for the Maturity Wall worksheet:
              upcoming debt-instrument maturities by calendar quarter.
   GRAIN      One row per maturity quarter (future maturities only), plus one
              'Unknown maturity' row.
   MEASURE    Instrument COUNTS, not dollars: security has no currency column
              and real instrument rows carry no amount_outstanding, so a dollar
              maturity wall would not be reliable.
   SCOPE      Real issuers, non-synthetic, record_level = 'instrument',
              instrument_type in (bond, loan). Past maturity dates are
              excluded here (and are not treated as defaults anywhere).
   TABLEAU    Compare against the Maturity Wall bars with no filters applied.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
debt AS (
    SELECT s.id, s.issuer_id, s.maturity_date
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    JOIN nexus.issuer i ON i.id = s.issuer_id AND i.is_synthetic = false
    WHERE s.is_synthetic = false
      AND s.instrument_type IN ('bond', 'loan')
      AND NOT (s.description LIKE '%SEC XBRL aggregate%'
               OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL))
)
SELECT CASE WHEN d.maturity_date IS NULL THEN 'Unknown maturity'
            ELSE to_char(d.maturity_date, 'YYYY') || '-Q' || to_char(d.maturity_date, 'Q') END AS maturity_quarter_label,
       date_trunc('quarter', d.maturity_date)::date AS maturity_quarter_start,
       COUNT(*)                     AS instrument_count,
       COUNT(DISTINCT d.issuer_id)  AS issuer_count
FROM debt d
CROSS JOIN params p
WHERE d.maturity_date IS NULL OR d.maturity_date >= p.as_of_date
GROUP BY 1, 2
ORDER BY maturity_quarter_start NULLS LAST
