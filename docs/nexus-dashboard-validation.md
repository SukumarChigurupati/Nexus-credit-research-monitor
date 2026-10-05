# Nexus Credit Research Monitor — Validation

## 1. What has been checked (and how)

| Check | Method | Result |
|---|---|---|
| All 10 queries compile with correct table/column names | Built an **empty local PostgreSQL 16 copy of the `nexus` schema** from the repository's SQLAlchemy models (17 tables, real constraints), then ran every query wrapped exactly as Tableau wraps Custom SQL: `SELECT * FROM (<query>) "Custom SQL Query"`. | **PASS** (10/10) |
| Grain uniqueness | `COUNT(*) = COUNT(DISTINCT key)` for datasets 01–04 on a test fixture | **PASS** |
| No join multiplication | Fixture issuer in 2 universes, with 4 securities and 5 alerts: dataset 01 returns 1 row; universe count = 2; alert counts unaffected | **PASS** |
| Issuers without securities kept | Fixture issuer with no securities or universes appears with 0 counts and `Unknown` sector | **PASS** |
| Synthetic exclusion | Synthetic issuer, synthetic loan and demo note excluded everywhere | **PASS** |
| SEC aggregate vs instrument separation | Aggregate row classified `issuer_aggregate`, excluded from maturity counts; amount shown separately | **PASS** |
| Alert status semantics | Dismissed, backfill, third-party (`issuer_is_subject = false`) and low-severity alerts each excluded from "new material (7d)" | **PASS** |
| KPI reconciliation | `07_kpi_reference` = sums of dataset 01 (new material alerts 7d = 1; maturing 12m = 1) | **PASS** |
| Overlap handling | `09` shows the alert in both universe rows and once in "(All - distinct)" | **PASS** |
| Past maturity | Labelled "Past maturity date (status not verified)", not default | **PASS** |

**Fixture limitation:** the fixture uses the container's UTC `current_date` for event dates, so check #7 (event date after detection date) flagged three fixture rows. That's a fixture artifact, but it shows the check works.

## 2. Live-data validation (Tableau, Oct 4–5, 2026)

Observed in Tableau against the live database:

| Check | Result |
|---|---|
| Issuers dataset row count vs `COUNTD(issuer_id)` KPI | 4,557 = 4,557 ✅ |
| Real debt instruments (excl. SEC aggregates, equity, synthetic) | 3,411 |
| Instruments maturing within 12 months | 163 (Oct 4) → 161 (Oct 5, after data refresh) |
| New material alerts, last 7 days | 0. Investigated: 6,235 of 6,410 alerts (97%) are historical backfill; the last non-backfill detection was Sept 18, 2026. The zero is real and flagged a pipeline-freshness question. |
| Issuers with ≥1 priority reason | 1,659 |
| Issuers in no research universe | 1,915 (42%), a coverage gap |
| Issuer drilldown | Bally's Corp: 2 instruments, 3 alerts, each linked to its source SEC filing ✅ |
| Fix applied | `issuer_id` cast to text in datasets 01–04 after a `text = uuid` type-mismatch error when filtering across relationships |

Remaining checks to run and record:

| # | Run | Record | Expected |
|---|---|---|---|
| L1 | `07_kpi_reference.sql` | all KPI values | Baseline for reconciliation |
| L2 | `10_validation_checks.sql` | each check_status | Checks 1, 4, 5 = PASS |
| L3 | `05_data_completeness.sql` | pct_passing for maturity, sector, attribution | Decides partial/ready status |
| L4 | `06_ingestion_freshness.sql` | freshness per provider | — |
| L5 | Tableau KPI cards, no filters | compare to L1 | Equal |
| L6 | Maturity Wall bars | compare to `08` | Equal |
| L7 | Heatmap, no filters | compare to `09` (universe rows) | Equal |
| L8 | Dataset grain: in Tableau, `COUNT` vs `COUNTD` of each key | — | Equal |

## 3. Known limitations

* No currency field on `security`, and no amounts on real instruments, so the maturity wall uses counts.
* Maturity coverage depends on OpenFIGI enrichment (unknown until L3).
* "Material" = high + medium severity is a business default, not a Nexus-defined term.
* `issuer_is_subject = NULL` alerts are shown, labelled "Attribution unconfirmed" (same as Nexus's own timeline rule).
* Freshness thresholds are copied from `core/freshness.py`. If that file changes, update `06`.
* Open material alerts include backfilled alerts that are still in status `new`. "New (7d)" excludes them.
