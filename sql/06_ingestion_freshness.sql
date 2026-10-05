/* =============================================================================
   06_ingestion_freshness.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Data freshness panel: when each data provider last delivered
              data, the last SEC filing-monitor run, and per-provider issuer
              enrichment status.
   GRAIN      One row per (area, item):
                area = 'Provider data'      item = provenance.provider
                area = 'Filing monitor'     item = latest run (one row)
                area = 'Issuer enrichment'  item = provider || ' / ' || status
   FRESHNESS  Nexus never stores freshness; it computes it from retrieved_at
              and a per-provider TTL (backend/app/core/freshness.py). The same
              thresholds are reproduced here:
                sec_edgar  live <= 24h,  cached <= 7d
                fred       live <= 1d,   cached <= 30d
                openfigi   live <= 30d,  cached <= 180d
                finra_trace live <= 15m, cached <= 4h
                synthetic  never stale
                default    live <= 1h,   cached <= 24h
   TIMESTAMPS retrieved_at = when Nexus fetched data (ingestion time), NOT when
              the fact was true (as_of_date) and NOT analyst research activity.
   TABLEAU    Separate data source "Freshness". Worksheet: Data Freshness table.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
WITH provider_latest AS (
    SELECT pv.provider,
           MAX(pv.retrieved_at) AS last_retrieved_at,
           MAX(pv.as_of_date)   AS latest_source_as_of_date,
           COUNT(*)             AS provenance_records
    FROM nexus.provenance pv
    GROUP BY pv.provider
),
provider_rows AS (
    SELECT 'Provider data'::text AS area,
           pl.provider           AS item,
           pl.last_retrieved_at  AS last_success_at,
           round((EXTRACT(EPOCH FROM (now() - pl.last_retrieved_at)) / 3600.0)::numeric, 1) AS age_hours,
           CASE
             WHEN pl.provider = 'synthetic' THEN 'live'
             WHEN now() - pl.last_retrieved_at <= CASE pl.provider
                    WHEN 'sec_edgar'   THEN INTERVAL '24 hours'
                    WHEN 'fred'        THEN INTERVAL '1 day'
                    WHEN 'openfigi'    THEN INTERVAL '30 days'
                    WHEN 'finra_trace' THEN INTERVAL '15 minutes'
                    ELSE INTERVAL '1 hour' END THEN 'live'
             WHEN now() - pl.last_retrieved_at <= CASE pl.provider
                    WHEN 'sec_edgar'   THEN INTERVAL '7 days'
                    WHEN 'fred'        THEN INTERVAL '30 days'
                    WHEN 'openfigi'    THEN INTERVAL '180 days'
                    WHEN 'finra_trace' THEN INTERVAL '4 hours'
                    ELSE INTERVAL '24 hours' END THEN 'cached'
             ELSE 'stale'
           END                   AS freshness_status,
           pl.provenance_records AS record_count,
           'Latest source as-of date: ' || COALESCE(pl.latest_source_as_of_date::text, 'unknown') AS detail
    FROM provider_latest pl
),
monitor_rows AS (
    SELECT 'Filing monitor'::text AS area,
           'Latest run (' || r.mode || ')' AS item,
           COALESCE(r.completed_at, r.started_at) AS last_success_at,
           round((EXTRACT(EPOCH FROM (now() - COALESCE(r.completed_at, r.started_at))) / 3600.0)::numeric, 1) AS age_hours,
           r.status AS freshness_status,
           r.alerts_created::bigint AS record_count,
           'Issuers checked: ' || r.issuers_checked || ', filings processed: ' || r.filings_processed
               || ', errors: ' || r.errors_count AS detail
    FROM (
        SELECT * FROM nexus.filing_monitor_run
        ORDER BY started_at DESC
        LIMIT 1
    ) r
),
enrichment_rows AS (
    SELECT 'Issuer enrichment'::text AS area,
           es.provider || ' / ' || es.status AS item,
           MAX(es.last_success_at) AS last_success_at,
           round((EXTRACT(EPOCH FROM (now() - MAX(es.last_success_at))) / 3600.0)::numeric, 1) AS age_hours,
           es.status AS freshness_status,
           COUNT(DISTINCT es.issuer_id)::bigint AS record_count,
           'Issuers in this status' AS detail
    FROM nexus.issuer_enrichment_status es
    JOIN nexus.issuer i ON i.id = es.issuer_id AND i.is_synthetic = false
    GROUP BY es.provider, es.status
)
SELECT * FROM provider_rows
UNION ALL
SELECT * FROM monitor_rows
UNION ALL
SELECT * FROM enrichment_rows
