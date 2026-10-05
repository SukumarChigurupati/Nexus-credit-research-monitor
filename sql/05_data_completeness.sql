/* =============================================================================
   05_data_completeness.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Field-coverage profile for the Data Quality panel: how complete
              the fields the dashboard depends on actually are.
   GRAIN      One row per (subject, check). Columns: subject, check_name,
              records_in_scope, records_passing, pct_passing, note.
   SCOPE      Real (non-synthetic) records only, matching the dashboard.
   TABLEAU    Separate data source "Data Completeness" (not related to the
              others). Worksheet: Data Quality table / bar chart.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH real_issuer AS (
    SELECT i.* FROM nexus.issuer i WHERE i.is_synthetic = false
),
real_sec AS (
    SELECT s.*,
           CASE WHEN s.description LIKE '%SEC XBRL aggregate%'
                  OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL)
                THEN 'issuer_aggregate' ELSE 'instrument' END AS record_level
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    JOIN real_issuer ri ON ri.id = s.issuer_id
    WHERE s.is_synthetic = false
),
debt_instr AS (
    SELECT * FROM real_sec
    WHERE record_level = 'instrument' AND instrument_type IN ('bond', 'loan')
),
checks AS (
    SELECT 'Issuer' AS subject, 'Sector populated' AS check_name,
           COUNT(*) AS records_in_scope, COUNT(*) FILTER (WHERE sector IS NOT NULL) AS records_passing,
           'Unknown sector shown as Unknown' AS note
    FROM real_issuer
    UNION ALL
    SELECT 'Issuer', 'Ticker populated', COUNT(*), COUNT(*) FILTER (WHERE ticker IS NOT NULL), ''
    FROM real_issuer
    UNION ALL
    SELECT 'Issuer', 'CIK populated', COUNT(*), COUNT(*) FILTER (WHERE cik IS NOT NULL), 'Needed for SEC linkage'
    FROM real_issuer
    UNION ALL
    SELECT 'Issuer', 'In at least one research universe', COUNT(*),
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM nexus.collection_membership cm
               JOIN nexus.collection c ON c.id = cm.collection_id
               WHERE cm.issuer_id = real_issuer.id AND c.collection_type = 'research_universe')),
           'Coverage, not condition'
    FROM real_issuer
    UNION ALL
    SELECT 'Issuer', 'Has at least one debt instrument', COUNT(*),
           COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM debt_instr d WHERE d.issuer_id = real_issuer.id)),
           'Issuers without instruments are still shown'
    FROM real_issuer
    UNION ALL
    SELECT 'Issuer', 'Has a non-demo research note', COUNT(*),
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM nexus.research_note rn
               WHERE rn.issuer_id = real_issuer.id AND rn.is_demo = false AND rn.is_archived = false)),
           'Drives research freshness'
    FROM real_issuer
    UNION ALL
    SELECT 'Debt instrument', 'Maturity date populated', COUNT(*),
           COUNT(*) FILTER (WHERE maturity_date IS NOT NULL), 'Drives maturity wall'
    FROM debt_instr
    UNION ALL
    SELECT 'Debt instrument', 'Coupon populated', COUNT(*), COUNT(*) FILTER (WHERE coupon IS NOT NULL), ''
    FROM debt_instr
    UNION ALL
    SELECT 'Debt instrument', 'Amount outstanding populated', COUNT(*),
           COUNT(*) FILTER (WHERE amount_outstanding IS NOT NULL), 'No currency column: amounts not summed'
    FROM debt_instr
    UNION ALL
    SELECT 'Debt instrument', 'Currency populated', COUNT(*), 0,
           'security table has no currency field'
    FROM debt_instr
    UNION ALL
    SELECT 'Debt instrument', 'Seniority populated', COUNT(*), COUNT(*) FILTER (WHERE seniority IS NOT NULL), ''
    FROM debt_instr
    UNION ALL
    SELECT 'Debt instrument', 'Has an identifier (FIGI/CUSIP/ISIN)', COUNT(*),
           COUNT(*) FILTER (WHERE figi IS NOT NULL OR cusip IS NOT NULL OR isin IS NOT NULL), ''
    FROM debt_instr
    UNION ALL
    SELECT 'Alert', 'Issuer attribution confirmed (not NULL)', COUNT(*),
           COUNT(*) FILTER (WHERE a.issuer_is_subject IS NOT NULL), 'NULL = attribution unconfirmed'
    FROM nexus.alert_event a JOIN real_issuer ri ON ri.id = a.issuer_id
    UNION ALL
    SELECT 'Alert', 'Primary source URL populated', COUNT(*),
           COUNT(*) FILTER (WHERE a.primary_source_url IS NOT NULL), 'Evidence link available'
    FROM nexus.alert_event a JOIN real_issuer ri ON ri.id = a.issuer_id
    UNION ALL
    SELECT 'Alert', 'Has at least one evidence id', COUNT(*),
           COUNT(*) FILTER (WHERE jsonb_array_length(a.evidence_ids) > 0), ''
    FROM nexus.alert_event a JOIN real_issuer ri ON ri.id = a.issuer_id
)
SELECT subject,
       check_name,
       records_in_scope,
       records_passing,
       CASE WHEN records_in_scope = 0 THEN NULL
            ELSE round(100.0 * records_passing / records_in_scope, 1) END AS pct_passing,
       note
FROM checks
