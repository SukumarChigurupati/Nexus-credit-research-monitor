/* =============================================================================
   09_alert_activity_by_sector_universe_reference.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Reconciliation reference for the "Material alert activity by
              sector and research universe" worksheet.
   GRAIN      One row per (sector, universe) pair, plus one row per sector with
              universe_name = '(All - distinct)'.
   WINDOW     Material, non-backfill alerts DETECTED in the last 90 days
              (America/New_York).
   OVERLAP    An issuer in two universes contributes its alerts to BOTH universe
              rows. That is correct per universe, but the universe rows must NOT
              be added together. The '(All - distinct)' row is the de-duplicated
              sector total, and it is what the sector-only view should show.
   TABLEAU    Compare against the heatmap with no filters applied
              (Tableau: COUNTD([alert_id]) by Sector x Universe).
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
material AS (
    SELECT a.id AS alert_id, a.issuer_id, a.severity,
           COALESCE(i.sector, 'Unknown') AS sector
    FROM nexus.alert_event a
    JOIN nexus.issuer i ON i.id = a.issuer_id AND i.is_synthetic = false
    CROSS JOIN params p
    WHERE a.status <> 'dismissed'
      AND a.issuer_is_subject IS DISTINCT FROM false
      AND a.severity IN ('high', 'medium')
      AND a.is_backfill = false
      AND (a.triggered_at AT TIME ZONE 'America/New_York')::date >= p.as_of_date - 89
),
with_universe AS (
    SELECT m.*, COALESCE(u.universe_name, 'Not in a research universe') AS universe_name
    FROM material m
    LEFT JOIN (
        SELECT cm.issuer_id, c.name AS universe_name
        FROM nexus.collection_membership cm
        JOIN nexus.collection c ON c.id = cm.collection_id
        WHERE c.collection_type = 'research_universe'
    ) u ON u.issuer_id = m.issuer_id
)
SELECT sector,
       universe_name,
       COUNT(DISTINCT alert_id)                                  AS material_alerts_90d,
       COUNT(DISTINCT alert_id) FILTER (WHERE severity = 'high') AS high_alerts_90d,
       COUNT(DISTINCT issuer_id)                                 AS issuers_with_alerts
FROM with_universe
GROUP BY sector, universe_name
UNION ALL
SELECT sector,
       '(All - distinct)' AS universe_name,
       COUNT(DISTINCT alert_id),
       COUNT(DISTINCT alert_id) FILTER (WHERE severity = 'high'),
       COUNT(DISTINCT issuer_id)
FROM material
GROUP BY sector
ORDER BY sector, universe_name
