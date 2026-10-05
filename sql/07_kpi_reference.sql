/* =============================================================================
   07_kpi_reference.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Reconciliation reference: the dashboard's headline KPI totals
              computed directly from the canonical tables, independent of the
              Tableau data model. Each Tableau KPI card (with no filters
              applied) must equal the matching column here.
   GRAIN      Exactly one row.
   DEFINITIONS (same rules as datasets 01-04)
     real_issuers                 issuer.is_synthetic = false
     issuers_in_research_universes distinct real issuers with >= 1 membership
                                  in a collection_type = 'research_universe'
     real_securities_all          non-synthetic security rows (any type/level)
     real_debt_instruments        instrument-level bonds/loans (excludes SEC
                                  aggregate rows and equity)
     instruments_maturing_12m     debt instruments with as_of <= maturity < as_of + 12 months
     new_material_alerts_7d       not dismissed, attribution not false,
                                  severity high/medium, not backfill,
                                  detected (America/New_York) in last 7 days
   TABLEAU    Not a worksheet; run as Custom SQL (or in any SQL client) and
              compare against the KPI cards during validation.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
real_issuer AS (
    SELECT id FROM nexus.issuer WHERE is_synthetic = false
),
real_sec AS (
    SELECT s.id, s.issuer_id, s.instrument_type, s.maturity_date,
           CASE WHEN s.description LIKE '%SEC XBRL aggregate%'
                  OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL)
                THEN 'issuer_aggregate' ELSE 'instrument' END AS record_level
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    JOIN real_issuer ri ON ri.id = s.issuer_id
    WHERE s.is_synthetic = false
)
SELECT
    p.as_of_date,
    (SELECT COUNT(*) FROM real_issuer)                                    AS real_issuers,
    (SELECT COUNT(DISTINCT cm.issuer_id)
       FROM nexus.collection_membership cm
       JOIN nexus.collection c ON c.id = cm.collection_id
       JOIN real_issuer ri ON ri.id = cm.issuer_id
      WHERE c.collection_type = 'research_universe')                      AS issuers_in_research_universes,
    (SELECT COUNT(*) FROM nexus.collection
      WHERE collection_type = 'research_universe')                        AS research_universes,
    (SELECT COUNT(*) FROM real_sec)                                       AS real_securities_all,
    (SELECT COUNT(*) FROM real_sec
      WHERE record_level = 'instrument' AND instrument_type IN ('bond', 'loan')) AS real_debt_instruments,
    (SELECT COUNT(*) FROM real_sec
      WHERE record_level = 'issuer_aggregate')                            AS sec_aggregate_debt_rows,
    (SELECT COUNT(*) FROM real_sec
      WHERE record_level = 'instrument' AND instrument_type IN ('bond', 'loan')
        AND maturity_date >= p.as_of_date
        AND maturity_date <  (p.as_of_date + INTERVAL '12 months')::date) AS instruments_maturing_12m,
    (SELECT COUNT(*)
       FROM nexus.alert_event a
       JOIN real_issuer ri ON ri.id = a.issuer_id
      WHERE a.status <> 'dismissed'
        AND a.issuer_is_subject IS DISTINCT FROM false
        AND a.severity IN ('high', 'medium')
        AND a.is_backfill = false
        AND (a.triggered_at AT TIME ZONE 'America/New_York')::date
            BETWEEN p.as_of_date - 6 AND p.as_of_date)                    AS new_material_alerts_7d
FROM params p
