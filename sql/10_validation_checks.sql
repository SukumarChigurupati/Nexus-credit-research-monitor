/* =============================================================================
   10_validation_checks.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Data-quality and reconciliation checks behind the dashboard:
              duplicates, orphan links, date anomalies and synthetic leakage.
   GRAIN      One row per check: check_name, result_value, expectation,
              check_status ('PASS', 'REVIEW' or 'INFO').
   USE        Run in Tableau (Custom SQL) or any read-only SQL client. Record the
              results in docs/tableau/nexus-dashboard-validation.md.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
real_instr AS (
    SELECT s.*
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    JOIN nexus.issuer i ON i.id = s.issuer_id AND i.is_synthetic = false
    WHERE s.is_synthetic = false
      AND s.instrument_type IN ('bond', 'loan')
      AND NOT (s.description LIKE '%SEC XBRL aggregate%'
               OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL))
),
checks AS (
    SELECT 1 AS check_order, 'Duplicate universe memberships (same universe + issuer)' AS check_name,
           (SELECT COUNT(*) FROM (
                SELECT collection_id, issuer_id FROM nexus.collection_membership
                GROUP BY 1, 2 HAVING COUNT(*) > 1) d) AS result_value,
           'must be 0' AS expectation
    UNION ALL
    SELECT 2, 'Possible duplicate issuers (same lower(legal_name))',
           (SELECT COUNT(*) FROM (
                SELECT lower(legal_name) FROM nexus.issuer WHERE is_synthetic = false
                GROUP BY 1 HAVING COUNT(*) > 1) d),
           'review if > 0'
    UNION ALL
    SELECT 3, 'Possible duplicate instruments (same issuer + maturity + coupon)',
           (SELECT COUNT(*) FROM (
                SELECT issuer_id, maturity_date, coupon FROM real_instr
                WHERE maturity_date IS NOT NULL
                GROUP BY 1, 2, 3 HAVING COUNT(*) > 1) d),
           'review if > 0'
    UNION ALL
    SELECT 4, 'Alert evidence ids that do not resolve to research_evidence',
           (SELECT COUNT(*)
              FROM nexus.alert_event a
              CROSS JOIN LATERAL jsonb_array_elements_text(a.evidence_ids) e(evidence_id)
              LEFT JOIN nexus.research_evidence re ON re.id::text = e.evidence_id
             WHERE re.id IS NULL),
           'must be 0'
    UNION ALL
    SELECT 5, 'Real securities whose provenance classification is synthetic',
           (SELECT COUNT(*) FROM nexus.security s
              JOIN nexus.provenance pv ON pv.id = s.provenance_id
             WHERE s.is_synthetic = false AND pv.classification = 'synthetic'),
           'must be 0'
    UNION ALL
    SELECT 6, 'Synthetic securities attached to real issuers (excluded from dashboard)',
           (SELECT COUNT(*) FROM nexus.security s
              JOIN nexus.issuer i ON i.id = s.issuer_id
             WHERE s.is_synthetic = true AND i.is_synthetic = false),
           'info'
    UNION ALL
    SELECT 7, 'Alerts with event date after detection date',
           (SELECT COUNT(*) FROM nexus.alert_event a
             WHERE a.as_of_date > (a.triggered_at AT TIME ZONE 'America/New_York')::date),
           'review if > 0'
    UNION ALL
    SELECT 8, 'Alerts flagged as historical backfill (excluded from "new")',
           (SELECT COUNT(*) FROM nexus.alert_event WHERE is_backfill = true),
           'info'
    UNION ALL
    SELECT 9, 'Dismissed alerts (excluded from "material")',
           (SELECT COUNT(*) FROM nexus.alert_event WHERE status = 'dismissed'),
           'info'
    UNION ALL
    SELECT 10, 'Alerts attributed to a third party (issuer_is_subject = false)',
           (SELECT COUNT(*) FROM nexus.alert_event WHERE issuer_is_subject = false),
           'info'
    UNION ALL
    SELECT 11, 'Debt instruments with a past maturity date (not a default signal)',
           (SELECT COUNT(*) FROM real_instr r CROSS JOIN params p WHERE r.maturity_date < p.as_of_date),
           'info'
    UNION ALL
    SELECT 12, 'Debt instruments with no maturity date',
           (SELECT COUNT(*) FROM real_instr WHERE maturity_date IS NULL),
           'info'
)
SELECT check_order,
       check_name,
       result_value,
       expectation,
       CASE WHEN expectation = 'info' THEN 'INFO'
            WHEN expectation = 'must be 0' AND result_value = 0 THEN 'PASS'
            WHEN expectation = 'review if > 0' AND result_value = 0 THEN 'PASS'
            ELSE 'REVIEW' END AS check_status
FROM checks
ORDER BY check_order
