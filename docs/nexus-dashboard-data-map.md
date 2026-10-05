# Nexus Credit Research Monitor — Data Map

Business question: **Which issuers need attention, what changed, and which debt instruments are affected?**

## 0. Evidence levels used in this document

| Label | Meaning |
|---|---|
| **REPO** | Derived from the repository: SQLAlchemy models (`backend/app/models/`), enums (`backend/app/core/types.py`), Alembic migrations 0001–0020, `CLAUDE.md`, ADRs. |
| **LIVE-CATALOG** | Seen in the live database catalog through Tableau's table list (screenshots, 2026-10-04): `nexus.*` tables exist, alongside other applications' schemas. |
| **UNVERIFIED** | Not yet checked against live rows. Coverage percentages and row counts are unknown until `05_data_completeness.sql` and `07_kpi_reference.sql` are run against live data. |

## 1. Database and schema

| Item | Value | Evidence |
|---|---|---|
| Platform | Supabase-managed PostgreSQL | REPO (ADR-001) |
| Database name | `postgres` (Supabase default; *not* `nexus`) | LIVE (Tableau connection succeeded with database `postgres`) |
| Nexus schema | `nexus` (every Nexus table, view and sequence; nothing in `public`) | REPO (ADR-013, `db/base.py`) + LIVE-CATALOG |
| Shared project | Yes. The Supabase project also hosts at least one other, unrelated application in other schemas; only `nexus.*` objects are used. | REPO (ADR-013) + LIVE-CATALOG |
| Connection used by Tableau | Supabase session pooler, port 5432, SSL required, read access (connection details kept private) | LIVE |
| Existing views | **None.** `morning_brief_view` (migration 0012) was a page-view log table and was dropped in 0013. No reusable SQL views exist. | REPO |
| PostgREST/RLS | `nexus` is not exposed to PostgREST; the app reaches data only through FastAPI. Application authorization (`policy_check`, `AUTH_ENABLED=false`) is **not** inherited by a direct database login. | REPO |

## 2. Tables used by the dashboard

All tables are in schema `nexus`. Primary keys are UUIDs (`gen_random_uuid()`).

### 2.1 `nexus.issuer` — the company being researched
* **Row** = one issuer (legal entity). **PK** `id`. **FK** `provenance_id → provenance.id`.
* Columns: `legal_name text NOT NULL`, `cik text NULL` (unique when present), `lei`, `ticker`, `sic`, `sector text NULL`, `is_synthetic bool NOT NULL default false`, `synthetic_reason text NULL` (only if synthetic).
* No created/updated timestamps; ingestion time comes from `provenance.retrieved_at`.
* **Real vs synthetic:** `is_synthetic = false`.

### 2.2 `nexus.security` — debt/equity records for an issuer
* **Row** = one security record. **PK** `id`. **FK** `issuer_id → issuer.id` (one issuer : many securities), `provenance_id → provenance.id`.
* Indexes: `ix_security_issuer_id`; unique partial indexes on `cusip`, `isin`, `figi` (when not null).
* Columns: `instrument_type text NOT NULL` ∈ {bond, loan, equity}; `seniority` ∈ {first_lien, second_lien, senior_unsecured, subordinated, preferred, common} or NULL; `lien_position`, `secured`, `cusip`, `isin`, `figi`, `description NOT NULL`, `maturity_date date NULL`, `coupon numeric NULL`, `amount_outstanding numeric NULL`, `benchmark`, `spread`, `is_synthetic`, `synthetic_reason`.
* **No currency column.**
* **Two different kinds of rows live in this table** (REPO: `providers/sec_edgar/normalizer.py`, `providers/openfigi/normalizer.py`):

| Kind | How to recognise | Has maturity? | Has amount? |
|---|---|---|---|
| SEC XBRL **issuer-level aggregate** debt total | provider `sec_edgar`, no FIGI/CUSIP/ISIN, description contains "SEC XBRL aggregate; not a specific instrument" | No | Yes (fetched with unit `USD` in code, but the unit is not stored) |
| OpenFIGI **instrument** (specific bond issue) | provider `openfigi`, has `figi` | Yes (parsed from ticker) | **No** |
| Synthetic demo loans | `is_synthetic = true` | Yes | Yes |

  The SQL package classifies these as `record_level = 'issuer_aggregate' | 'instrument'`.

### 2.3 `nexus.collection` and `nexus.collection_membership` — Research Universes
* `collection` **row** = one universe/watchlist/benchmark. **PK** `id`. `collection_type` ∈ {research_universe, watchlist, benchmark}; `name`, `slug`, `curation_method` ∈ {manual_curated, system_seeded, user_created}; `verification_status` ∈ {verified, partial, unverified}; `last_verified_at`; `priority` ∈ {critical, high, medium, low} or NULL.
* `collection_membership` **row** = one issuer in one collection. **PK** `id`; **unique** `(collection_id, issuer_id)`; FKs to `collection` and `issuer`. Columns: `rationale NOT NULL`, `rationale_as_of_date`, `verification_status`, `system_seeded`, `added_at`, `updated_at`.
* Relationship: issuer **many-to-many** universe through membership.
* **Meaning:** membership is a coverage decision, never a current-status assertion (model docstring). Condition claims need dated evidence.

### 2.4 `nexus.alert_event` — what changed
* **Row** = one alert (an evidence bundle turned into an event). **PK** `id`; **FK** `issuer_id`, `provenance_id`. Indexes on `issuer_id`, `status`, `bundle_key`.
* `category` (evidence-type value, e.g. `going_concern`), `severity` ∈ {low, medium, high} — already the **AI-reviewed effective severity** (`universe_classification_service.effective_reviews`), `headline`, `explanation`, `evidence_ids jsonb` (list of `research_evidence.id` strings), `primary_evidence_provider`, `primary_source_label`, `primary_source_url`, `detection_method` ∈ {deterministic, ai_assisted}, `ai_assisted`, `confidence`.
* **Dates:** `as_of_date` = **event date** (date of the underlying filing/fact); `triggered_at timestamptz` = **detection time**.
* **Status:** `status` ∈ {new, acknowledged, dismissed}; `is_backfill` = historical discovery, not a new event; `issuer_is_subject` true / false (third party) / NULL (unconfirmed).
* **Nexus's own display rule** (`issuer_timeline_service`): show when `status <> 'dismissed' AND issuer_is_subject IS NOT false`.

### 2.5 `nexus.research_evidence` — supporting evidence
* **Row** = one matched excerpt. **PK** `id`; FKs `issuer_id`, `filing_id → sec_filing`, `docket_entry_id → court_docket_entry`, `provenance_id`.
* `evidence_type` (32 allowed values), `severity` (raw rule severity), `evidence_provider`, `confidence`, `review_status` ∈ {unreviewed, confirmed, rejected}, `created_at`.
* Linked to alerts through `alert_event.evidence_ids` (one alert : many evidence rows). `evidence_excerpt` is not exported to Tableau.

### 2.6 `nexus.research_note` — analyst research
* **Row** = one research note. **PK** `id`; FK `issuer_id`, optional `security_id`.
* `thesis_status` ∈ {draft, active, monitoring, invalidated, resolved}; `conviction`; `is_demo`; `is_archived`; `created_at`, `updated_at`.
* **Research freshness** = `updated_at` of the latest non-demo, non-archived note. Note bodies (bull/base/bear case) are not exported.

### 2.7 `nexus.provenance` — lineage for every fact
* **Row** = one source fact. `provider` (14 allowed values, e.g. sec_edgar, openfigi, courtlistener, fred, synthetic), `source_record_id`, `source_url`, `as_of_date` (when the fact was true), `retrieved_at` (when Nexus fetched it), `transformation` ∈ {reported, calculated}, `classification` ∈ {public, licensed, synthetic, ai_extracted}.
* Freshness (live/cached/stale) is **computed, never stored** (`core/freshness.py`).

### 2.8 Ingestion status tables
* `nexus.filing_monitor_run` — one row per SEC filing-monitor run: `started_at`, `completed_at`, `status`, `mode` ∈ {baseline, delta, backfill}, counts.
* `nexus.issuer_enrichment_status` — one row per (issuer, provider): `status` (pending … complete, no_data, failed_*), `last_attempt_at`, `last_success_at`.

## 3. Timestamp meanings (do not mix them)

| Timestamp | Meaning |
|---|---|
| `alert_event.as_of_date` | Event date |
| `alert_event.triggered_at` | Detection time |
| `research_note.updated_at` | Analyst research update |
| `collection.last_verified_at`, `collection_membership.rationale_as_of_date` | Membership verification |
| `collection_membership.added_at/updated_at` | System write time |
| `provenance.retrieved_at` | Ingestion time |
| `provenance.as_of_date` | Source fact date |

**Dashboard as-of date:** `(now() AT TIME ZONE 'America/New_York')::date`, used identically in every query.

## 4. Dashboard component support

| Component | Status | Notes / fallback |
|---|---|---|
| Distinct issuers in selected universes | **Ready** | `COUNTD(issuer_id)` over memberships. |
| Distinct real securities tracked | **Ready** | Report instruments and SEC aggregate rows separately. |
| New material alerts (7d) | **Ready** | "Material" = high + medium severity (business default; adjustable). |
| Instruments maturing within 12 months | **Partially supported** | Only OpenFIGI-identified instruments carry maturities; coverage UNVERIFIED. |
| Maturities by quarter | **Partially supported (counts only)** | Real instruments have no `amount_outstanding`, and there is no currency column, so a dollar maturity wall is **blocked**. Instrument counts are used instead. |
| Alert activity by sector and universe | **Ready** | Depends on `issuer.sector` coverage (UNVERIFIED); NULL is shown as `Unknown`. |
| Research priority table | **Ready** | Transparent reasons, not a risk score. |
| Data freshness and completeness | **Ready** | Datasets 05 and 06. |
| Issuer and evidence links | **Ready** | `primary_source_url` (can be NULL); Nexus issuer URL `https://nexus-credit-intelligence.vercel.app/issuers/<issuer_id>`. |
| Dollar amounts by currency | **Blocked** | No currency field; SEC aggregate amounts are context only and are never summed with instruments. |

## 5. Join rules

* Base grain is the issuer. Child tables relate on `issuer_id` as separate Tableau relationship tables, so there are no physical joins between securities, memberships and alerts, and therefore no row multiplication.
* Dataset 01 pre-aggregates every child table to one row per issuer before joining, and keeps issuers with no securities.
* **Overlapping universes:** an issuer in two universes appears in both universe rows. Totals must use `COUNTD`, never a sum of per-universe counts.
* A past maturity date is labelled "status not verified", not default.
