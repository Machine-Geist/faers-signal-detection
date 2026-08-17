# data/

Exported CSVs behind the published dashboard. **Derived data, not source data** —
everything here is regenerable from the FAERS quarterly files by running the
pipeline in `sql/`.

Committed so that every figure quoted in this repository can be checked without
loading 6 GB of source data and running 24 scripts.

---

## What's here

### Summary tables — committed uncompressed

Small enough to read directly on GitHub, which renders CSVs as browsable tables.
Between them these contain every headline number cited in the project READMEs.

| File | Rows | Contents |
|---|---|---|
| `funnel.csv` | 6 | Attrition from deduplicated cases to the review queue |
| `auc.csv` | 24 | AUC by method × tier × stratum, matched pair set |
| `confusion.csv` | 6 | Confusion matrix and metrics by method and tier |
| `indication_bands.csv` | 5 | Signals and mean IC025 by indication-match band |
| `shrinkage_profile.csv` | 11 | Method agreement as a function of case count |
| `stratum_summary.csv` | 4 | Cases, pairs, and signals per stratum |
| `reporting_pathway.csv` | 54 | Reporting channel split for the top 15 ingredients by case count |

### Full extracts — committed gzipped

| File | Rows | Contents |
|---|---|---|
| `signals.csv.gz` | ~90,000 | Every pair flagged by at least one method, ALL stratum |
| `roc.csv.gz` | ~1,500 | ROC curve points by method and tier |
| `validation_pairs.csv.gz` | ~2,500 | Every scored OMOP reference pair with its outcome label |

`signals.csv` is the project's actual output — the ranked, artifact-filtered
review queue.

**Reading them:**

```bash
gunzip -k signals.csv.gz          # keeps the .gz
```

Or read directly without extracting — pandas, R, and most data tools handle
gzip natively:

```python
import pandas as pd
df = pd.read_csv('data/signals.csv.gz')
```

---

## What's not here

**The FAERS source files.** Several GB per quarter, published by FDA, and not
this project's to redistribute. Acquisition and load instructions are in
[`sql/00_setup/00_README_setup.md`](../sql/00_setup/00_README_setup.md) — that
is the single source of truth for where the data comes from and how it is
loaded.

**The OMOP reference set.** Retrieved by `sql/00_setup/02_grab_omop.py` from the
OHDSI MethodEvaluation package.

If you clone this repo and want to rebuild from scratch, start at
`sql/00_setup/`.

---

## Regenerating

These are produced by `sql/04_exports/01_tableau_exports.sql` — one query per
file, exported via DBeaver's result grid.

**Run all ten in one sitting.** Every number on the dashboard should come from
the same snapshot, or the KPI tiles stop matching the charts.

---

## Scope

All figures are measured on **FAERS 2025Q4–2026Q1**, `ALL` stratum unless a
column says otherwise.

Adding a quarter changes `N`, so every PRR, ROR, and IC025 shifts. Nothing here
appends — the analysis is pinned to a fixed denominator and has to be
regenerated whole.

---

## Disclaimer

FAERS data is published by the U.S. Food and Drug Administration and is in the
public domain (CC0 1.0). This is an independent analysis, not affiliated with or
endorsed by the FDA.

Disproportionality signals indicate that a drug-reaction pair is reported more
often than expected relative to the rest of the database. **They do not
establish causation.** FAERS reports are voluntary and unverified, contain
duplicates, and have no exposure denominator. Nothing here is medical advice.
