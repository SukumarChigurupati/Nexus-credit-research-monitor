# Nexus Credit Research Monitor — Tableau Build Guide

**Tool:** Tableau Desktop (Free Edition), PostgreSQL connector plus the PostgreSQL JDBC driver (`postgresql-42.7.x.jar` in `C:\Program Files\Tableau\Drivers`).

**Data:** Supabase PostgreSQL, database `postgres`, schema `nexus`. Read-only.

## 1. Connection

| Field | Value |
|---|---|
| Server | `<your-region>.pooler.supabase.com` (session pooler, **not** the 6543 transaction pooler) |
| Port | `5432` |
| Database | `postgres` |
| Username | `nexus_readonly.<project_ref>` (a read-only role; never the admin login) |
| Require SSL | checked |

**Selecting the right schema.** The Table list shows every schema in the shared Supabase project. Only use `nexus.*` objects. Every query in `sql/tableau/` is fully qualified (`nexus.issuer`, …), so Custom SQL never depends on the search path.

**Permissions and RLS.** Tableau does **not** inherit Nexus application authorization (FastAPI, `policy_check`). A database login sees whatever the role is granted. Use a role with `USAGE` on `nexus` and `SELECT` only (`sql/tableau/99_optional_views_DO_NOT_RUN.sql`). The `nexus` schema has no RLS policies in the migrations; it is protected by not being exposed to PostgREST.

## 2. Data sources

### 2.1 Main data source "Nexus Monitor" (relationship model)

| Logical table | SQL file | Grain | Relationship |
|---|---|---|---|
| **Issuers** (base) | `01_issuer_dataset.sql` | 1 row / issuer | — |
| Instruments | `02_instrument_dataset.sql` | 1 row / security | Issuers.issuer_id = Instruments.issuer_id |
| Memberships | `03_universe_membership_dataset.sql` | 1 row / issuer–universe | Issuers.issuer_id = Memberships.issuer_id |
| Alerts | `04_alert_dataset.sql` | 1 row / alert | Issuers.issuer_id = Alerts.issuer_id |

Steps:
1. Double-click **New Custom SQL**, paste file 01 (no trailing `;`), click OK, and rename the table **Issuers**.
2. Drag **New Custom SQL** onto the canvas next to Issuers, paste file 02, and rename it **Instruments**. In the relationship box, choose `issuer_id` = `issuer_id`.
3. Repeat for file 03 (**Memberships**) and file 04 (**Alerts**). Each relates to **Issuers** (not to each other).
4. Under each relationship's **Performance Options**, set the Issuers side to *One / All records match* and the child side to *Many / Some records match*.

Relationships keep each table at its own grain. Tableau queries only the tables a worksheet needs, so securities × memberships × alerts never multiply.

### 2.2 Separate data sources
* **Data Completeness:** `05_data_completeness.sql`
* **Freshness:** `06_ingestion_freshness.sql`
* **Validation (optional sheet):** `10_validation_checks.sql`

Reference queries `07`–`09` are used for reconciliation (see the validation doc), not as worksheets.

**Live vs extract:** start Live. Before an interview demo, create an extract (Data → Extract Data) so the demo works without depending on the database, and state the extract time on the dashboard.

## 3. Calculated fields (main data source)

| Name | Formula |
|---|---|
| KPI Issuers | `COUNTD([Issuer Id])` *(Issuers table)* |
| KPI Debt Instruments | `COUNTD(IF [Record Level]="instrument" AND [Is Debt] THEN [Security Id] END)` |
| KPI Maturing 12m | `COUNTD(IF [Matures Within 12m] THEN [Security Id] END)` |
| KPI New Material Alerts 7d | `COUNTD(IF [Is New Material 7d] THEN [Alert Id] END)` |
| Material Alerts | `COUNTD(IF [Is Material] AND NOT [Is Backfill] THEN [Alert Id] END)` |
| Research Age Label | `IF ISNULL([Research Age Days]) THEN "No research note" ELSE STR([Research Age Days]) + " days" END` |

Always count with `COUNTD` on the key, never `SUM` a count column from a child table.

## 4. Filters

| Filter | Field | Apply to |
|---|---|---|
| Research Universe | Memberships · Universe Name | All worksheets using this data source |
| Sector | Issuers · Sector | All worksheets using this data source |
| Alert detection window | Alerts · Detection Date (relative: last 90 days) | Alert worksheets only |

**Overlapping universes:** when two universes are selected, an issuer in both is counted once by `COUNTD([Issuer Id])`. The heatmap's universe columns can each include the same alert; don't add the columns together.

**Universe filter caveat:** filtering on Universe Name removes issuers with no membership. That is correct for "issuers in selected universes", but leave the filter on *(All)* to see uncovered issuers.

## 5. Worksheets

1. **KPI cards** (four sheets): each shows one KPI calc as a large number (Text mark), with the title as the label.
2. **Maturity Wall:** Instruments. Filters: Record Level = instrument, Is Debt = True, Maturity Bucket excludes "Unknown maturity", "Past maturity date…" and "Not applicable". Columns: `QUARTER(Maturity Date)` (continuous date value); Rows: `COUNTD(Security Id)`; bar mark. Caption: *"Instrument counts. Dollar amounts not shown: real instruments carry no amount and the source has no currency field."*
3. **Alert Activity Heatmap:** Rows: Alerts.Sector; Columns: Memberships.Universe Name; Color and Label: `Material Alerts`. Filter: detection date in the last 90 days.
4. **Research Priority Table:** Issuers. Rows: Issuer Name, Research Universe Names, Sector, Priority Reasons, Next Maturity Date, Latest Alert Category, Latest Alert Severity, Research Age Label. Sort by Priority Reason Count (descending). Optional filter: Priority Reason Count ≥ 1.
5. **Event Feed:** Alerts. Filter: Is Displayable = True. Rows: Detection Date (exact date), Event Date, Issuer Name, Category Label, Severity, Attribution, Primary Source Label, Evidence Count. Sort by Detection Date (descending).
6. **Issuer Securities:** Instruments. Rows: Security Description, Record Level, Maturity Date, Coupon, Maturity Bucket, Source Provider.
7. **Data Quality:** Data Completeness source. Rows: Subject, Check Name; Columns: `SUM(Pct Passing)` bar; tooltip: Note.
8. **Data Freshness:** Freshness source. Text table of Area, Item, Last Success At, Age Hours, Freshness Status.

## 6. Dashboard and navigation

Layout (1366×768): KPI strip across the top; Maturity Wall and Heatmap in the middle; Research Priority Table below; Event Feed and Issuer Securities on the right; Data Quality and Freshness on a second dashboard tab.

Actions:
* **Filter action** (Select): source Research Priority Table → targets Event Feed, Issuer Securities, Maturity Wall; field `Issuer Id`. Clearing the selection shows all values.
* **URL action** "Open evidence": source Event Feed → `<Primary Source Url>`.
* **URL action** "Open in Nexus": source Research Priority Table → `<Nexus Issuer Url>`.

Footer text: *"Data as of <As Of Date> (America/New_York). Real records only; synthetic/demo data excluded. Universe membership indicates research coverage, not financial condition."*
