/* =============================================================================
   03_universe_membership_dataset.sql  —  Nexus Credit Research Monitor
   -----------------------------------------------------------------------------
   PURPOSE    Research Universe coverage: which issuers are covered by which
              universe. Drives the Research Universe filter and the
              "issuers in selected universes" KPI.
   GRAIN      One row per (research universe, issuer) pair. Guaranteed unique
              by the uq_collection_membership_pair constraint
              (collection_id, issuer_id). Key: membership_id.
   MEANING    Membership = RESEARCH COVERAGE, not a statement about the
              issuer's current financial condition. Condition claims need a
              dated alert/evidence record (see 04_alert_dataset.sql).
   OVERLAP    An issuer can sit in several universes. Always count issuers with
              COUNTD([issuer_id]); never SUM a per-universe issuer count, or an
              issuer in two selected universes is counted twice.
   FILTERS    collection_type = 'research_universe' (watchlists and benchmarks
              excluded; change the IN list to include 'benchmark' if wanted).
              Synthetic issuers excluded.
   TIMESTAMPS rationale_as_of_date = date the membership rationale was true;
              membership_verified_at = collection.last_verified_at (universe-
              level verification run); added_at/updated_at = system write times
              (NOT analyst research activity).
   TABLEAU    Data source table "Memberships", related to Issuers on issuer_id.
   NOTE       Paste into Tableau Custom SQL WITHOUT a trailing semicolon.
   STATUS     Compiled against a schema built from the repository's models.
              NOT yet run against live Nexus data.
   ========================================================================== */
SELECT cm.id                                  AS membership_id,
       c.id                                   AS universe_id,
       c.name                                 AS universe_name,
       c.slug                                 AS universe_slug,
       c.collection_type                      AS universe_type,
       c.curation_method                      AS universe_curation_method,
       c.verification_status                  AS universe_verification_status,
       c.last_verified_at                     AS universe_last_verified_at,
       COALESCE(c.priority, 'unspecified')    AS universe_priority,
       cm.issuer_id::text                     AS issuer_id,
       i.legal_name                           AS issuer_name,
       COALESCE(i.sector, 'Unknown')          AS sector,
       cm.verification_status                 AS membership_verification_status,
       cm.rationale                           AS membership_rationale,
       cm.rationale_as_of_date,
       cm.system_seeded,
       cm.added_at                            AS membership_added_at,
       cm.updated_at                          AS membership_updated_at
FROM nexus.collection_membership cm
JOIN nexus.collection c ON c.id = cm.collection_id
JOIN nexus.issuer     i ON i.id = cm.issuer_id
WHERE c.collection_type IN ('research_universe')
  AND i.is_synthetic = false
