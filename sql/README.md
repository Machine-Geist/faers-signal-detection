# sql/

Six sections, run in numeric order. Each has its own README covering what it
builds and why.

| Section | Builds | What it does |
|---|---|---|
| [`00_setup`](00_setup/) | 7 raw tables, OMOP reference table | Loads FAERS quarterly files and the validation benchmark |
| [`01_staging`](01_staging/) | 7 views, 2 materialized views, 1 function | Types, cleans, and deduplicates to one row per case |
| [`02_marts`](02_marts/) | 1 table, 7 materialized views | Builds the contingency tables and computes PRR, ROR, IC025 |
| [`03_validation`](03_validation/) | 3 tables, 1 materialized view, 1 view | Scores the pipeline against the OMOP reference set |
| [`04_exports`](04_exports/) | 10 CSV extracts | Flattens results for Tableau Public |
| [`05_qc`](05_qc/) | — | Assertions and diagnostics |

---

## Architecture

```
raw          faithful landing tables, no cleaning
  ↓
staging      types, blank→NULL, deduplication, ingredient normalization
  ↓
marts        analysis universe, contingency counts, disproportionality metrics
  ↓
validation   the same math at reference-set grain, scored against ground truth
  ↓
exports      flat CSVs for the dashboard
```

Each layer does one thing. Cleaning never happens in raw, judgment calls never
happen in staging, and no statistic is computed outside SQL.

---

## Running it

First build, in order:

1. `00_setup` — create tables, load FAERS files, tag with source quarter, build
   indexes, retrieve and load the OMOP reference set
2. `01_staging` — run `01_stg_*`, then `02_clean_ingredient`, then `03` and `04`
3. `02_marts` — run `00` through `06` in numeric order
4. `03_validation` — run `01` through `04`
5. `04_exports` — run all ten queries in one sitting, export each to CSV
6. `05_qc` — run the assertions; checks 1–9 must pass

Adding a later quarter: import the new files, tag them, then run
`02_marts/07_refresh_marts.sql`, which refreshes everything downstream in
dependency order. Do not re-run the `CREATE` statements.

Full instructions are in each section's README. Start with
[`00_setup/README.md`](00_setup/README.md).

---

## Conventions

Every file opens with a header stating **PURPOSE**, **GRAIN**, **DEPENDS**, and
**FEEDS**, and most end with a commented `VERIFY` block — the queries that
confirm the object built correctly.

Every materialized view carries a `UNIQUE` index on its stated grain. Those
indexes are assertions, not optimizations: if the grain is wrong, the index
fails to build and the script errors rather than silently producing duplicated
rows. That convention exists because an early version of `stg_drug_ingredient`
produced 27,783 spurious rows by carrying superseded case versions, and nothing
errored.

All object references are schema-qualified. All tunable thresholds live in one
`params` CTE in `02_marts/06`.

---

## Reading order

For understanding the analysis rather than running it:

1. [`02_marts/README.md`](02_marts/) — the contingency model and the three
   metrics
2. [`03_validation/README.md`](03_validation/) — whether it works, and the two
   vocabulary problems that had to be solved first
3. [`../docs/decisions.md`](../docs/decisions.md) — every judgment call, and the
   times measurement overturned one
4. [`../docs/limitations.md`](../docs/limitations.md) — what the output cannot
   support

The single most consequential object is `01_staging/03_stg_demo_latest.sql`.
FAERS ships one row per case *version*, and everything downstream depends on
collapsing those correctly.
