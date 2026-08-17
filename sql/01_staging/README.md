# 01_staging — Cleaning and Deduplication

Turns the raw FAERS landing tables into a typed, deduplicated layer the marts
can build on. Nothing here changes what the data *says* — it changes how it is
represented, and it resolves the one structural problem in FAERS that everything
downstream depends on: the same case appears multiple times, once per version.

Run `00_setup` before anything in this folder.

| Script | Object | Type |
|---|---|---|
| `01_stg_raw_demo.sql` | `stg_demo` | View |
| `01_stg_raw_drug.sql` | `stg_drug` | View |
| `01_stg_raw_indi.sql` | `stg_indi` | View |
| `01_stg_raw_outc.sql` | `stg_outc` | View |
| `01_stg_raw_reac.sql` | `stg_reac` | View |
| `01_stg_raw_rpsr.sql` | `stg_rpsr` | View |
| `01_stg_raw_ther.sql` | `stg_ther` | View |
| `02_clean_ingredient.sql` | `clean_ingredient()` | Function |
| `03_stg_demo_latest.sql` | `stg_demo_latest` | Materialized view |
| `04_stg_drug_ingredient.sql` | `stg_drug_ingredient` | Materialized view |

Run in numeric order. The `01_*` views are independent of each other, but `03`
depends on `stg_demo` and `04` depends on both `03` and `clean_ingredient()`.

---

## What each stage does

### `01_stg_raw_*.sql` — pass-through cleaning

One view per raw table, same grain, same row count. Each does two things:

- **Blank strings become NULL.** FAERS uses empty strings, not NULL, for missing
  text. Left as-is, `WHERE col IS NULL` silently misses them and `COUNT(col)`
  overcounts.
- **Date integers become dates.** FAERS stores dates as `YYYYMMDD` integers, and
  partial dates are common — a report may carry only a year, or a year and
  month. Partial values anchor to the earliest valid point, so `2025` becomes
  `2025-01-01`.

Deliberately *not* done here: deduplication, drug-name normalization, role
filtering, unit normalization on `age_cod`/`wt_cod`, outlier handling. Those are
judgment calls and belong further down where they can be documented and varied
in one place.

These are plain views, not materialized. They are thin, and the planner pushes
predicates through them into the indexed raw tables.

**Known limitation:** the date parsing checks digit *count*, not calendar
validity. PostgreSQL's `to_date` silently rolls over impossible values, so
`20250230` returns March 2nd rather than NULL. Left unresolved because no date
column feeds a published metric — `fda_dt` appears only as a tie-break in
`stg_demo_latest`, and that tie-break never fires.

### `02_clean_ingredient.sql` — ingredient normalization function

An `IMMUTABLE` scalar function that normalizes a single active-ingredient
fragment: uppercase, Greek-letter escape decoding (`.ALPHA.` → `ALPHA`),
whitespace collapse, edge trimming, and NULL for anything that cleans to empty.

Kept as a function rather than inline SQL so the normalization rule lives in one
place and can be tested on its own. Called by `04`.

Does not resolve salt or ester forms — see the limitation noted under `04`.

### `03_stg_demo_latest.sql` — deduplication

**This is the most consequential object in the layer.**

FAERS ships one row per case *version*. A case amended three times appears three
times, with three different `primaryid` values and one shared `caseid`. Counting
cases without collapsing versions inflates every downstream figure.

This keeps the latest version per `caseid` using `DISTINCT ON` with an explicit
tie-break chain:

```
caseversion    DESC   -- highest version wins
fda_dt         DESC NULLS LAST
source_quarter DESC   -- later quarter wins
primaryid      DESC   -- final deterministic fallback
```

The chain matters for reproducibility. `DISTINCT ON` without a fully
deterministic `ORDER BY` can return different rows across runs, which would make
every downstream count unstable. The `UNIQUE` indexes on `caseid` and
`primaryid` enforce that the dedup actually worked — if either fails to build,
the logic is wrong and the script errors rather than silently producing
duplicates.

Materialized because everything downstream joins to it.

### `04_stg_drug_ingredient.sql` — ingredient grain

Splits `prod_ai` on backslash (FAERS uses it to delimit combination products),
normalizes each fragment via `clean_ingredient()`, and produces one row per
`(caseid, primaryid, role_cod, ingredient)`.

`prod_ai` is used rather than `drugname` because it is FDA-validated and
populated for effectively all primary-suspect records, while `drugname` is
reporter-verbatim and fragments heavily across brands and misspellings.

The join to `stg_demo_latest` is load-bearing, not decorative: without it the
view carries every case version and duplicates ingredients for every amended
case.

**Known limitation:** salt and ester forms are not resolved. `CIPROFLOXACIN` and
`CIPROFLOXACIN HYDROCHLORIDE` remain separate ingredients, splitting counts for
the same moiety. See the project README for the measured impact.

---

## Refreshing

The two materialized views are snapshots. After loading a new FAERS quarter,
refresh in dependency order — `stg_drug_ingredient` joins to `stg_demo_latest`:

```sql
REFRESH MATERIALIZED VIEW public.stg_demo_latest;
REFRESH MATERIALIZED VIEW public.stg_drug_ingredient;
```

The `01_*` views need no refresh; they read through to the raw tables.

---

## Verifying the layer

```sql
-- Pass-through views must preserve row counts exactly.
SELECT (SELECT COUNT(*) FROM public.raw_demo) AS raw,
       (SELECT COUNT(*) FROM public.stg_demo) AS staged;

-- Dedup must be exact: rows = distinct caseid = distinct primaryid.
SELECT COUNT(*)                   AS rows,
       COUNT(DISTINCT caseid)     AS distinct_caseid,
       COUNT(DISTINCT primaryid)  AS distinct_primaryid
FROM public.stg_demo_latest;

-- No case should have two rows at its own highest version.
SELECT COUNT(*) AS ambiguous
FROM (
    SELECT caseid, caseversion
    FROM public.stg_demo
    GROUP BY caseid, caseversion
    HAVING COUNT(*) > 1
) t;

-- Blank strings must be gone.
SELECT COUNT(*) AS blanks
FROM public.stg_demo
WHERE sex = '' OR occp_cod = '' OR reporter_country = '';

-- Ingredient grain must match its unique index.
SELECT COUNT(*) AS rows,
       COUNT(DISTINCT (caseid, primaryid, role_cod, ingredient)) AS distinct_keys
FROM public.stg_drug_ingredient;
```

The first should match, the second should return three equal numbers, the next
two should return zero, and the last should return two equal numbers.
