/* =============================================================================
   99_optional_views_DO_NOT_RUN.sql  —  OPTIONAL, NOT EXECUTED
   -----------------------------------------------------------------------------
   Optional DDL for a future step. It has NOT been executed and must not be
   executed without the Nexus owner's approval: CLAUDE.md freezes the V1.0
   architecture and every schema change goes through an Alembic migration.

   1. A dedicated read-only role for Tableau (least privilege). Supabase
      session-pooler username becomes  nexus_readonly.<project_ref>.
   2. A view that centralises the instrument vs. SEC-aggregate classification
      so every query uses one definition.

   RLS NOTE: the nexus schema is not exposed through PostgREST, and Nexus
   application authorization is NOT inherited by Tableau. Whoever holds these
   database credentials can read every granted table. Grant only SELECT on the
   nexus schema.
   ========================================================================== */

-- 1. Read-only role (run by the project owner in the Supabase SQL Editor)
-- CREATE ROLE nexus_readonly WITH LOGIN PASSWORD '<strong password>';
-- GRANT USAGE ON SCHEMA nexus TO nexus_readonly;
-- GRANT SELECT ON ALL TABLES IN SCHEMA nexus TO nexus_readonly;
-- ALTER DEFAULT PRIVILEGES IN SCHEMA nexus GRANT SELECT ON TABLES TO nexus_readonly;

-- 2. Classification view (would need an Alembic migration in the nexus repo)
-- CREATE VIEW nexus.v_security_classified AS
-- SELECT s.*,
--        CASE WHEN s.description LIKE '%SEC XBRL aggregate%'
--               OR (pv.provider = 'sec_edgar' AND s.figi IS NULL AND s.cusip IS NULL AND s.isin IS NULL)
--             THEN 'issuer_aggregate' ELSE 'instrument' END AS record_level,
--        pv.provider AS source_provider
-- FROM nexus.security s
-- JOIN nexus.provenance pv ON pv.id = s.provenance_id;
