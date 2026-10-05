/* =============================================================================
   01_issuer_dataset.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Issuer-level dataset for overview KPIs and the Research Priority
              table. This is the BASE (left-most) table of the Tableau data
              model; the other datasets relate to it on issuer_id.
   GRAIN      One row per real (non-synthetic) issuer in nexus.issuer.
              Issuers with no securities, no alerts, no notes and no universe
              membership are KEPT (LEFT JOINs to pre-aggregated subqueries).
   JOIN SAFETY Every child table (security, collection_membership, alert_event,
              research_note) is aggregated to one row per issuer BEFORE it is
              joined, so securities x memberships x alerts can never multiply.
   AS-OF DATE One consistent as-of date: today's date in America/New_York.
   FILTERS    nexus.issuer.is_synthetic = false. Synthetic securities are
              excluded from instrument counts. Demo research notes
              (is_demo = true) and archived notes are excluded.
   NULLS      Unknown sector -> 'Unknown'. Counts default to 0. Dates stay NULL
              when there is no underlying record (never invented).
   PRIORITY   No credit-risk score. Four transparent, auditable reasons are
              flagged; priority_reason_count is just how many reasons apply.
   TABLEAU    Data source: Custom SQL "Issuers". Worksheets: KPI cards,
              Research Priority table, issuer drilldown header.
   NOTE       Tableau Custom SQL: paste WITHOUT a trailing semicolon.
   STATUS     Compiled against an empty schema built from the repository's
              SQLAlchemy models. NOT yet run against live Nexus data.
   ========================================================================== */
WITH params AS (
    SELECT (now() AT TIME ZONE 'America/New_York')::date AS as_of_date
),
debt_instruments AS (
    -- Instrument-level debt only. SEC XBRL aggregate rows are balance-sheet
    -- totals, not instruments, and are handled separately (agg_debt below).
    SELECT s.issuer_id, s.id AS security_id, s.maturity_date
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    WHERE s.is_synthetic = false
      AND s.instrument_type IN ('bond', 'loan')
      AND NOT (
            s.description LIKE '%SEC XBRL aggregate%'
         OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL)
      )
),
instr AS (
    SELECT d.issuer_id,
           COUNT(DISTINCT d.security_id)                                   AS debt_instrument_count,
           COUNT(DISTINCT d.security_id) FILTER (WHERE d.maturity_date IS NULL)
                                                                           AS instruments_unknown_maturity,
           COUNT(DISTINCT d.security_id) FILTER (
               WHERE d.maturity_date >= p.as_of_date
                 AND d.maturity_date <  (p.as_of_date + INTERVAL '12 months')::date)
                                                                           AS instruments_maturing_12m,
           MIN(d.maturity_date) FILTER (WHERE d.maturity_date >= p.as_of_date)
                                                                           AS next_maturity_date
    FROM debt_instruments d
    CROSS JOIN params p
    GROUP BY d.issuer_id
),
agg_debt AS (
    -- Latest SEC-reported aggregate long-term debt figure per issuer.
    -- Shown for context only; never summed with instrument data.
    SELECT DISTINCT ON (s.issuer_id)
           s.issuer_id,
           s.amount_outstanding AS sec_aggregate_debt_reported,
           pv.as_of_date        AS sec_aggregate_debt_as_of
    FROM nexus.security s
    JOIN nexus.provenance pv ON pv.id = s.provenance_id
    WHERE s.is_synthetic = false
      AND (s.description LIKE '%SEC XBRL aggregate%'
           OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL))
    ORDER BY s.issuer_id, pv.as_of_date DESC, pv.retrieved_at DESC
),
universes AS (
    SELECT cm.issuer_id,
           COUNT(DISTINCT c.id)                                      AS research_universe_count,
           string_agg(DISTINCT c.name, ' | ' ORDER BY c.name)        AS research_universe_names,
           MAX(cm.updated_at)                                        AS latest_membership_update_at
    FROM nexus.collection_membership cm
    JOIN nexus.collection c ON c.id = cm.collection_id
    WHERE c.collection_type = 'research_universe'
    GROUP BY cm.issuer_id
),
alerts AS (
    -- Displayable alerts use Nexus' own rule (issuer_timeline_service):
    -- not dismissed, and issuer attribution is not explicitly false.
    -- "Material" = displayable AND severity in (high, medium); severity on
    -- alert_event is already the AI-reviewed severity.
    SELECT a.issuer_id,
           COUNT(*) FILTER (WHERE a.status = 'new'
                              AND a.issuer_is_subject IS DISTINCT FROM false
                              AND a.severity IN ('high', 'medium'))              AS open_material_alerts,
           COUNT(*) FILTER (WHERE a.status <> 'dismissed'
                              AND a.issuer_is_subject IS DISTINCT FROM false
                              AND a.severity IN ('high', 'medium')
                              AND a.is_backfill = false
                              AND (a.triggered_at AT TIME ZONE 'America/New_York')::date
                                  BETWEEN p.as_of_date - 6 AND p.as_of_date)     AS new_material_alerts_7d,
           COUNT(*) FILTER (WHERE a.status <> 'dismissed'
                              AND a.issuer_is_subject IS DISTINCT FROM false
                              AND a.severity = 'high'
                              AND (a.triggered_at AT TIME ZONE 'America/New_York')::date
                                  >= p.as_of_date - 89)                          AS high_alerts_90d,
           MAX(a.as_of_date) FILTER (WHERE a.status <> 'dismissed'
                              AND a.issuer_is_subject IS DISTINCT FROM false)     AS latest_alert_event_date,
           MAX(a.triggered_at) FILTER (WHERE a.status <> 'dismissed'
                              AND a.issuer_is_subject IS DISTINCT FROM false)     AS latest_alert_detected_at
    FROM nexus.alert_event a
    CROSS JOIN params p
    GROUP BY a.issuer_id
),
latest_alert AS (
    SELECT DISTINCT ON (a.issuer_id)
           a.issuer_id,
           a.category           AS latest_alert_category,
           a.severity           AS latest_alert_severity,
           a.headline           AS latest_alert_headline,
           a.primary_source_url AS latest_alert_source_url
    FROM nexus.alert_event a
    WHERE a.status <> 'dismissed'
      AND a.issuer_is_subject IS DISTINCT FROM false
    ORDER BY a.issuer_id, a.triggered_at DESC, a.id
),
notes AS (
    SELECT rn.issuer_id,
           COUNT(*)          AS research_note_count,
           MAX(rn.updated_at) AS latest_research_note_at
    FROM nexus.research_note rn
    WHERE rn.is_demo = false
      AND rn.is_archived = false
    GROUP BY rn.issuer_id
),
base AS (
    SELECT i.id::text                             AS issuer_id,
           i.legal_name                           AS issuer_name,
           i.ticker,
           i.cik,
           COALESCE(i.sector, 'Unknown')          AS sector,
           pv.provider                            AS issuer_source_provider,
           COALESCE(u.research_universe_count, 0) AS research_universe_count,
           COALESCE(u.research_universe_names, 'Not in a research universe') AS research_universe_names,
           u.latest_membership_update_at,
           COALESCE(ins.debt_instrument_count, 0)        AS debt_instrument_count,
           COALESCE(ins.instruments_unknown_maturity, 0) AS instruments_unknown_maturity,
           COALESCE(ins.instruments_maturing_12m, 0)     AS instruments_maturing_12m,
           ins.next_maturity_date,
           ad.sec_aggregate_debt_reported,
           ad.sec_aggregate_debt_as_of,
           COALESCE(al.open_material_alerts, 0)   AS open_material_alerts,
           COALESCE(al.new_material_alerts_7d, 0) AS new_material_alerts_7d,
           COALESCE(al.high_alerts_90d, 0)        AS high_alerts_90d,
           al.latest_alert_event_date,
           al.latest_alert_detected_at,
           la.latest_alert_category,
           la.latest_alert_severity,
           la.latest_alert_headline,
           la.latest_alert_source_url,
           COALESCE(n.research_note_count, 0)     AS research_note_count,
           n.latest_research_note_at,
           p.as_of_date
    FROM nexus.issuer i
    JOIN nexus.provenance pv ON pv.id = i.provenance_id
    CROSS JOIN params p
    LEFT JOIN universes    u   ON u.issuer_id   = i.id
    LEFT JOIN instr        ins ON ins.issuer_id = i.id
    LEFT JOIN agg_debt     ad  ON ad.issuer_id  = i.id
    LEFT JOIN alerts       al  ON al.issuer_id  = i.id
    LEFT JOIN latest_alert la  ON la.issuer_id  = i.id
    LEFT JOIN notes        n   ON n.issuer_id   = i.id
    WHERE i.is_synthetic = false
)
SELECT b.*,
       CASE WHEN b.latest_research_note_at IS NULL THEN NULL
            ELSE b.as_of_date - (b.latest_research_note_at AT TIME ZONE 'America/New_York')::date
       END                                                         AS research_age_days,
       (b.new_material_alerts_7d > 0)                              AS reason_new_material_alert_7d,
       (b.open_material_alerts > 0)                                AS reason_open_material_alert,
       (b.instruments_maturing_12m > 0)                            AS reason_maturity_within_12m,
       (b.high_alerts_90d > 0
        AND (b.latest_research_note_at IS NULL
             OR b.latest_research_note_at < b.latest_alert_detected_at)) AS reason_research_stale_vs_alert,
       ( (b.new_material_alerts_7d > 0)::int
       + (b.open_material_alerts > 0)::int
       + (b.instruments_maturing_12m > 0)::int
       + (b.high_alerts_90d > 0
          AND (b.latest_research_note_at IS NULL
               OR b.latest_research_note_at < b.latest_alert_detected_at))::int
       )                                                           AS priority_reason_count,
       concat_ws('; ',
           CASE WHEN b.new_material_alerts_7d > 0 THEN 'New material alert (7d)' END,
           CASE WHEN b.open_material_alerts > 0 THEN 'Open material alert' END,
           CASE WHEN b.instruments_maturing_12m > 0 THEN 'Debt maturing within 12m' END,
           CASE WHEN b.high_alerts_90d > 0
                 AND (b.latest_research_note_at IS NULL
                      OR b.latest_research_note_at < b.latest_alert_detected_at)
                THEN 'No research note since latest high alert' END
       )                                                           AS priority_reasons,
       'https://nexus-credit-intelligence.vercel.app/issuers/' || b.issuer_id::text AS nexus_issuer_url
FROM base b
