# 00_setup — Environment and Data Load

Everything needed to get from an empty PostgreSQL instance to a loaded raw layer
plus the OMOP validation reference set. Run these in order before anything in
the staging or mart folders.

| Script | Type | What it does |
|---|---|---|
| `01_create_raw_tables.sql` | SQL | Creates the 7 FAERS raw tables, comments, and indexes |
| `02_grab_omop.py` | Python | Downloads the OMOP reference set from the OHDSI package |
| `03_create_omop_reference.sql` | SQL | Creates the OMOP reference table, comments, and indexes |

---

## Prerequisites

- **PostgreSQL 14+** running locally. This project uses a dedicated database
  named `faers` in the default `public` schema.
- **DBeaver Community Edition** as the SQL client and CSV import tool.
- **Python 3.9+** for `02_grab_omop.py`. Install dependencies with
  `pip install -r requirements.txt`.
- **~6 GB free disk** for two quarters of FAERS data plus indexes.

Create the database before doing anything else:

```sql
CREATE DATABASE faers;
```

Then connect DBeaver to it: **Database → New Database Connection → PostgreSQL**,
host `localhost`, port `5432`, database `faers`.

> If you installed PostgreSQL configured not to auto-start, remember to start the
> service before each session.

---

## Step 1 — Download the FAERS quarterly files

### Where to get them

FDA renamed this program to the **Adverse Event Monitoring System (AEMS)** in
March 2026. The data is unchanged; only the branding and page location moved.
The extract files are still published under the FAERS name.

- Landing page: [AEMS Latest Quarterly Data Files](https://www.fda.gov/drugs/fda-adverse-event-monitoring-system-aems/fda-adverse-event-monitoring-system-aems-latest-quarterly-data-files)
- Direct file browser: [FAERS Quarterly Data Extract Files](https://fis.fda.gov/extensions/FPD-QDE-FAERS/FPD-QDE-FAERS.html)

Download the **ASCII** version, not XML. This project used:

- `faers_ascii_2025Q4.zip`
- `faers_ascii_2026Q1.zip`

Each archive contains an `ASCII/` folder with seven `$`-delimited `.txt` files
and a readme (`ASC_NTS.pdf`) describing every field.

| File | Table | Contents |
|---|---|---|
| `DEMO25Q4.txt` | `raw_demo` | Case demographics and administrative header |
| `DRUG25Q4.txt` | `raw_drug` | Drugs reported per case |
| `REAC25Q4.txt` | `raw_reac` | Reactions as MedDRA Preferred Terms |
| `OUTC25Q4.txt` | `raw_outc` | Patient outcome codes |
| `INDI25Q4.txt` | `raw_indi` | Indication for use per drug |
| `THER25Q4.txt` | `raw_ther` | Therapy start/end dates per drug |
| `RPSR25Q4.txt` | `raw_rpsr` | Report source codes |

> **Quarterly files are not cumulative.** Each release contains only the reports
> processed in that quarter. Loading two quarters means loading both archives.

### Create the tables

Open `01_create_raw_tables.sql` in DBeaver and run **Sections 1–3 only**
(teardown, table definitions, documentation). Stop before Section 4.

Indexes are deliberately held back until after the load — building indexes
during a multi-million-row import is substantially slower than building them once
the data is in place.

---

## Step 2 — Load the FAERS files in DBeaver

Repeat for each of the seven files, per quarter.

1. In the **Database Navigator**, expand `faers → Schemas → public → Tables`.
2. Right-click the target table (e.g. `raw_demo`) → **Import Data**.
3. Source: **CSV**. Browse to the `.txt` file.
4. On the **Importer settings** page, set:

   | Setting | Value | Why |
   |---|---|---|
   | Column delimiter | `$` | FAERS uses dollar-sign delimiting, not comma |
   | Header position | `top` | First row contains column names |
   | Encoding | `UTF-8` | FAERS extracts are plain ASCII, which UTF-8 reads natively |
   | NULL value mark | *(leave empty)* | Blanks are cleaned to NULL in the staging layer, not here |
   | Quote character | *(none)* | FAERS does not quote fields; a quote char causes mis-parsing |


5. On the **Tables mapping** page, confirm every source column maps to an
   existing target column. The three provenance columns
   (`report_year`, `report_quarter`, `source_quarter`) will show as unmapped —
   this is expected, they are populated in step 3.


6. Run the import. `DRUG` is the largest file and takes the longest.

## Step 3 — Tag the loaded rows with their source quarter

The three provenance columns are **not** part of the FAERS extract. They are
added here so that multi-quarter data stays traceable to the file it came from,
which matters for the `source_quarter` tie-break in `stg_demo_latest`.

Immediately after importing a quarter, and **before importing the next one**,
run:

```sql
-- Adjust report_year, report_quarter, and source_quarter literals to match the quarter you just loaded.
UPDATE public.raw_demo SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
UPDATE public.raw_drug SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
UPDATE public.raw_indi SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
UPDATE public.raw_outc SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
UPDATE public.raw_reac SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
UPDATE public.raw_rpsr SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
UPDATE public.raw_ther SET report_year = 2025, report_quarter = 'Q4', source_quarter = '2025Q4' WHERE source_quarter IS NULL;
```

The `WHERE source_quarter IS NULL` guard is what makes this safe to re-run —
already-tagged rows from a previous quarter are untouched.

## Step 4 — Build the indexes

Once **all** quarters are loaded and tagged, run **Sections 4 and 5** of
`01_create_raw_tables.sql` (indexes, then `ANALYZE`).

### Verify the load

```sql
SELECT source_quarter, COUNT(*) FROM public.raw_demo GROUP BY 1 ORDER BY 1;
SELECT COUNT(*) FROM public.raw_demo WHERE source_quarter IS NULL;  -- expect 0
```

Every table should have rows for every quarter, and no untagged rows anywhere.

---

## Step 5 — Retrieve the OMOP reference set

```bash
python 02_grab_omop.py
```

This pulls the **OMOP drug-outcome reference standard** — the external ground
truth used to validate the pipeline's disproportionality signals. It is *not*
FAERS data and is not downloaded from FDA.

The set contains 399 drug-outcome pairs: 165 positive controls (the drug is
believed to cause the outcome) and 234 negative controls, across four health
outcomes of interest — acute liver injury, acute kidney injury, acute myocardial
infarction, and upper gastrointestinal bleeding.

> Ryan PB, Schuemie MJ, Welebob E, Duke J, Valentine S, Hartzema AG. Defining a
> reference set to support methodological research in drug safety.
> *Drug Safety.* 2013;36(Suppl 1):S33-47.

The script writes omop_reference_set.csv next to the script, and prints the row 
counts for verification.

---

## Step 6 — Create the OMOP table and load the CSV

1. Run `03_create_omop_reference.sql` **Sections 1–4** (teardown, table,
   documentation, indexes). This table is 399 rows, so index-before-load costs
   nothing.
2. Import the CSV from step 5 into `public.omop_reference_set` using the same
   DBeaver **Import Data** flow, but with a **comma** delimiter this time.
3. Run Section 5 (uncomment the validation query first).

Expected result:

| total_pairs | positive_controls | negative_controls | distinct_outcomes |
|---|---|---|---|
| 399 | 165 | 234 | 4 |

A mismatch means `02_grab_omop.py` pulled a different revision of the set.

> **Note on column names.** This table uses quoted camelCase
> (`"exposureName"`, `"groundTruth"`) preserved verbatim from the upstream OHDSI
> package. PostgreSQL folds unquoted identifiers to lowercase, so every
> downstream reference must keep the double quotes.

---

## Adding an additional quarter later

The setup scripts are written so a new quarter is an **append**, not a rebuild.
To load, say, `2026Q2` onto an existing database:

### In `01_create_raw_tables.sql` — comment out most of it

| Section | Action | Reason |
|---|---|---|
| **1 — Teardown** | **Comment out** | `DROP TABLE` would destroy the quarters already loaded |
| **2 — Table definitions** | **Comment out** | Tables already exist; `CREATE TABLE` errors out |
| **3 — Documentation** | **Comment out** | Comments are already in the catalog |
| **4 — Indexes** | **Run** | `CREATE INDEX IF NOT EXISTS` makes this safe to re-run |
| **5 — Post-load** | **Run** | `ANALYZE` refreshes planner stats after the new rows land |

When adding an additional quarter: do not run Sections 1-3 of `01`. 
Instead, import the seven files for the new quarter, run the provenance `UPDATE` 
block with the new quarter's literals, then run Sections 4 and 5 at the bottom 
of `01`.

Indexes do not need rebuilding after an append — PostgreSQL maintains them on 
every insert. Only planner statistics go stale, which is what the ANALYZE in 
Section 5 refreshes.

Leaving the existing indexes in place during the import is a deliberate
trade-off — dropping and rebuilding them would be faster for a large append, but
it risks leaving the database un-indexed if the rebuild fails partway.

### Do not re-run `02` or `03`

The OMOP reference set is a fixed published standard. It does not change when
you add a FAERS quarter, and re-running `03` would drop and reload it for no
reason.

### Refresh everything downstream

New raw rows are invisible until the materialized views are rebuilt. After the
append:

```sql
REFRESH MATERIALIZED VIEW public.stg_demo_latest;
REFRESH MATERIALIZED VIEW public.stg_drug_ingredient;
```

Then run the mart refresh script (`07`) and the QC checks (`99`).

> Note that adding a quarter changes the denominator `N` in every
> disproportionality calculation, so **all previously reported PRR, ROR, and
> IC025 values will shift.** Any figures quoted in the report or dashboard need
> to be regenerated, not just appended to.

---

## Data source and disclaimer

FAERS data is published by the U.S. Food and Drug Administration and is in the
public domain (CC0 1.0). The OMOP reference set is distributed via the OHDSI
MethodEvaluation package.

This is an independent analysis and is not affiliated with or endorsed by the
FDA. Disproportionality signals indicate that a drug-reaction pair is reported
more often than expected relative to the rest of the database — they do not
establish causation. FAERS reports are voluntary and unverified, contain
duplicates, and have no exposure denominator. Nothing in this project is medical
advice.
