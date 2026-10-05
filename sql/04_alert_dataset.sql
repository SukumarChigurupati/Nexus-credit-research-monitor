/* =============================================================================
   04_alert_dataset.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Alert-level dataset for the event surveillance panel, the
              "new material alerts (7d)" KPI, sector/universe alert activity,
              and source-evidence links.
   GRAIN      One row per nexus.alert_event row for a real issuer.
              Key: alert_id. Evidence is summarised per alert through a
              LATERAL subquery, so evidence never duplicates alert rows.
   DATES      event_date     = alert_event.as_of_date (when the underlying
                               fact/filing is dated)
              detected_at    = alert_event.triggered_at (when Nexus detected it)
              detection_date = detected_at converted to America/New_York date
   STATUS     status values in the schema: new | acknowledged | dismissed.
              is_backfill = true marks historical discovery, not a new event.
              issuer_is_subject: true = issuer itself; false = third party
              (e.g. a customer's bankruptcy); NULL = not confirmed.
   RULES      is_displayable = Nexus' own rule (issuer_timeline_service):
                status <> 'dismissed' AND issuer_is_subject IS NOT false.
              is_material    = is_displayable AND severity IN (high, medium).
                (Business default - change to severity = 'high' if the desk
                 defines "material" more strictly.)
              is_new_material_7d = is_material AND NOT is_backfill AND
                detection_date within the last 7 days including today.
              alert_event.severity is already the AI-reviewed severity;
              research_evidence.review_status adds human review counts.
   FILTERS    Synthetic issuers excluded. Dismissed and backfill alerts are KEPT
              but flagged, so Tableau can show them separately if needed.
   TABLEAU    Data source table "Alerts", related to Issuers on issuer_id.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
a AS (
    SELECT al.*,
           (al.triggered_at AT TIME ZONE 'America/New_York')::date AS detection_date,
           (al.status <> 'dismissed' AND al.issuer_is_subject IS DISTINCT FROM false) AS is_displayable
    FROM nexus.alert_event al
)
SELECT a.id                                          AS alert_id,
       a.issuer_id::text                             AS issuer_id,
       i.legal_name                                  AS issuer_name,
       COALESCE(i.sector, 'Unknown')                 AS sector,
       a.category,
       initcap(replace(a.category, '_', ' '))        AS category_label,
       a.severity,
       CASE a.severity WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 END AS severity_rank,
       a.headline,
       a.status,
       a.detection_method,
       a.ai_assisted,
       a.confidence,
       a.is_backfill,
       CASE a.issuer_is_subject WHEN true THEN 'Issuer is subject'
                                WHEN false THEN 'Third party (not issuer)'
                                ELSE 'Attribution unconfirmed' END AS attribution,
       a.as_of_date                                  AS event_date,
       a.triggered_at                                AS detected_at,
       a.detection_date,
       a.detection_date - a.as_of_date               AS detection_lag_days,
       a.is_displayable,
       (a.is_displayable AND a.severity IN ('high', 'medium')) AS is_material,
       (a.is_displayable AND a.severity IN ('high', 'medium')
        AND a.is_backfill = false
        AND a.detection_date BETWEEN p.as_of_date - 6 AND p.as_of_date) AS is_new_material_7d,
       a.primary_evidence_provider,
       a.primary_source_label,
       a.primary_source_url,
       COALESCE(ev.evidence_count, 0)                AS evidence_count,
       COALESCE(ev.evidence_confirmed, 0)            AS evidence_confirmed,
       COALESCE(ev.evidence_rejected, 0)             AS evidence_rejected,
       COALESCE(ev.evidence_unreviewed, 0)           AS evidence_unreviewed,
       ev.evidence_types,
       'https://nexus-credit-intelligence.vercel.app/issuers/' || a.issuer_id::text AS nexus_issuer_url,
       p.as_of_date
FROM a
JOIN nexus.issuer i ON i.id = a.issuer_id
CROSS JOIN params p
LEFT JOIN LATERAL (
    SELECT COUNT(*)                                                  AS evidence_count,
           COUNT(*) FILTER (WHERE re.review_status = 'confirmed')   AS evidence_confirmed,
           COUNT(*) FILTER (WHERE re.review_status = 'rejected')    AS evidence_rejected,
           COUNT(*) FILTER (WHERE re.review_status = 'unreviewed')  AS evidence_unreviewed,
           string_agg(DISTINCT re.evidence_type, ', ')               AS evidence_types
    FROM jsonb_array_elements_text(a.evidence_ids) AS e(evidence_id)
    JOIN nexus.research_evidence re ON re.id::text = e.evidence_id
) ev ON true
WHERE i.is_synthetic = false
