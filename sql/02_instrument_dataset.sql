/* =============================================================================
   02_instrument_dataset.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Security-level dataset for the maturity wall, the securities list
              in the issuer drilldown, and the "real securities tracked" KPI.
   GRAIN      One row per real (non-synthetic) row in nexus.security whose
              issuer is also real. Primary key: security_id.
   RECORD LEVEL  record_level separates two different things the security
              table stores:
                'instrument'       = a specific bond/loan issue (e.g. OpenFIGI
                                     rows with a FIGI, maturity and coupon)
                'issuer_aggregate' = an SEC XBRL balance-sheet debt TOTAL
                                     (description says "SEC XBRL aggregate;
                                     not a specific instrument"); it has no
                                     maturity and must never be charted as an
                                     instrument.
   AMOUNTS    nexus.security has NO currency column, and real instrument rows
              from OpenFIGI carry no amount_outstanding. amount_is_summable is
              therefore always false: the maturity wall uses INSTRUMENT COUNTS.
   MATURITY   A past maturity date does NOT indicate default; it is labelled
              'Past maturity date (status not verified)'.
   AS-OF DATE Today in America/New_York.
   FILTERS    s.is_synthetic = false AND i.is_synthetic = false. Equity rows are
              kept but flagged is_debt = false (filter them out in Tableau).
   TABLEAU    Data source table "Instruments", related to Issuers on issuer_id.
              Worksheets: Maturity Wall, Issuer drilldown securities list.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
sec AS (
    SELECT s.*,
           pv.provider       AS source_provider,
           pv.source_url     AS source_url,
           pv.as_of_date     AS source_as_of_date,
           pv.retrieved_at   AS source_retrieved_at,
           pv.classification AS source_classification,
           CASE WHEN s.description LIKE '%SEC XBRL aggregate%'
                  OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL)
                THEN 'issuer_aggregate' ELSE 'instrument' END AS record_level
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    WHERE s.is_synthetic = false
)
SELECT s.id                                        AS security_id,
       s.issuer_id::text                           AS issuer_id,
       i.legal_name                                AS issuer_name,
       COALESCE(i.sector, 'Unknown')               AS sector,
       s.record_level,
       s.instrument_type,
       (s.instrument_type IN ('bond', 'loan'))     AS is_debt,
       s.description                               AS security_description,
       COALESCE(s.seniority, 'unknown')            AS seniority,
       s.secured,
       s.figi,
       s.cusip,
       s.isin,
       s.coupon,
       s.maturity_date,
       date_trunc('quarter', s.maturity_date)::date AS maturity_quarter_start,
       CASE WHEN s.maturity_date IS NULL THEN 'Unknown'
            ELSE to_char(s.maturity_date, 'YYYY') || '-Q' || to_char(s.maturity_date, 'Q')
       END                                         AS maturity_quarter_label,
       s.maturity_date - p.as_of_date              AS days_to_maturity,
       CASE
           WHEN s.record_level = 'issuer_aggregate'                       THEN 'Not applicable (aggregate)'
           WHEN s.maturity_date IS NULL                                   THEN 'Unknown maturity'
           WHEN s.maturity_date <  p.as_of_date                           THEN 'Past maturity date (status not verified)'
           WHEN s.maturity_date <  (p.as_of_date + INTERVAL '3 months')::date  THEN '1. Within 3 months'
           WHEN s.maturity_date <  (p.as_of_date + INTERVAL '12 months')::date THEN '2. 3-12 months'
           WHEN s.maturity_date <  (p.as_of_date + INTERVAL '3 years')::date   THEN '3. 1-3 years'
           WHEN s.maturity_date <  (p.as_of_date + INTERVAL '5 years')::date   THEN '4. 3-5 years'
           ELSE '5. 5+ years'
       END                                         AS maturity_bucket,
       (s.record_level = 'instrument'
        AND s.instrument_type IN ('bond', 'loan')
        AND s.maturity_date >= p.as_of_date
        AND s.maturity_date <  (p.as_of_date + INTERVAL '12 months')::date) AS matures_within_12m,
       s.amount_outstanding                        AS amount_outstanding_reported,
       CASE WHEN s.amount_outstanding IS NULL THEN 'Not reported'
            ELSE 'Reported (currency not stored)' END AS amount_status,
       false                                       AS amount_is_summable,
       s.source_provider,
       s.source_url,
       s.source_as_of_date,
       s.source_retrieved_at,
       s.source_classification,
       p.as_of_date
FROM sec s
JOIN nexus.issuer i ON i.id = s.issuer_id
CROSS JOIN params p
WHERE i.is_synthetic = false
