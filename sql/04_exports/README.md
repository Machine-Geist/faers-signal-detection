# 04_exports — Dashboard Extracts

The bridge from PostgreSQL to Tableau Public. Ten flat CSV extracts, one query
each, feeding a three-tab published dashboard.

**Live dashboard:** [FAERS Adverse Event Signal Detection](https://public.tableau.com/app/profile/nathan.mcwain/viz/FAERSAdverseEventSignalDetection/1_SignalExplorer#1)

Run `00_setup` through `03_validation` first — every query here reads from
objects those sections build.

| Script | Output |
|---|---|
| `01_tableau_exports.sql` | 10 CSV extracts |

---

## Why CSVs and not a live connection

Tableau Public cannot connect to a local PostgreSQL instance. It only publishes
workbooks with extracted data, so the pipeline has to end in flat files
regardless.

That constraint turns out to be useful. Each extract is a single query with a
stated purpose, so anyone reading this file can see exactly what number ended up
on which chart — no hidden Tableau-side calculations doing analytical work the
repo doesn't show. All the statistics happen in SQL; Tableau does layout,
filtering, and interaction.

Export via DBeaver's result grid (**right-click → Export resultset → CSV**)
rather than `COPY TO`, which writes server-side and needs superuser or
`pg_read_server_files` membership. The grid export works for anyone who cloned
the repo.

---

## The extracts

| # | File | Rows | Feeds |
|---|---|---|---|
| 1 | `signals.csv` | ~90,000 | Tab 1 scatter, Tab 3 |
| 2 | `funnel.csv` | 6 | Intended for Tab 1 KPIs, Tab 3 funnel, though not used |
| 3 | `roc.csv` | ~1,500 | Tab 2 ROC curves |
| 4 | `auc.csv` | 24 | Tab 2 AUC bars |
| 5 | `confusion.csv` | 6 | Tab 2 confusion matrix |
| 6 | `validation_pairs.csv` | ~2,500 | Tab 2 missed-positives scatter |
| 7 | `indication_bands.csv` | 5 | Tab 3 |
| 8 | `reporting_pathway.csv` | ~60 | Tab 3 |
| 9 | `shrinkage_profile.csv` | 11 |Intended for Tab 3 though not used |
| 10 | `stratum_summary.csv` | 4 | Intended for Tab 1 KPI context though not used |

**Run them all in one sitting.** Every number on the dashboard should come from
the same snapshot. Mixed snapshots are how KPI tiles quietly stop matching the
charts they sit next to.

---

## Three things worth knowing about these queries

**Everything is scoped to the eligible universe.** Every extract inherits
`mart_case_strata` — cases with both a primary-suspect drug and a reaction. A
query that reaches around that filter produces counts that disagree with the
rest of the dashboard for the same ingredient.

**Extract 1 is ALL-stratum only.** Stratum belongs in a filter, not on the same
canvas.

**Extract 4 uses the matched pair set, not the raw per-stratum one.**
`mart_validation_signals` builds its grid from observed marginals, so a
reference drug with no eligible cases in a stratum vanishes from it rather than
scoring a=0 — 144 reference drugs appear in ALL but only 129 in EXPEDITED and
130 in SERIOUS. Comparing raw per-stratum AUC would compare different problems.
The `common` CTE restricts to the 261 pairs present in all four strata.

---

## The dashboard

Three tabs, each answering a different question.

**Tab 1 — Signal Explorer.** What did the pipeline find? An IC025 scatter with
parameter-driven drilldown: select an ingredient and the detail views follow.
Defaults to medroxyprogesterone acetate / meningioma, a confirmed true positive,
so the landing state demonstrates the tool working rather than showing an empty
prompt.

**Tab 2 — Does It Work?** The validation layer made visible: ROC curves, AUC by
method and stratum, the confusion matrix, and the missed-positives scatter that
separates power failures from method failures.

**Tab 3 — Three Things Measured.** The methodological findings — how the three
metrics diverge, where indication confounding concentrates, and what the
reporting-pathway split reveals about solicited reporting.

### Design notes

- **IC025 selected as primary ranking metric.** Dashboard visualizations support
  using this as the ranking metric, though ROR and PRR are included where 
  appropriate and to promote discussion.
- **Titles state findings, not chart contents.** "IC025 separates signals better
  than PRR across all reports" rather than "ROC curve by method."
- **Worksheet tabs are hidden on publish.** Viewers see the three dashboards,
  not the fifteen sheets behind them.

---

## Refreshing

After loading a new quarter and running the mart and validation refreshes:

1. Re-run all ten queries in one sitting.
2. Export each to `/tableau/data/` with the filenames above.
3. Refresh the extracts in Tableau and republish.

Adding a quarter changes `N`, so **every PRR, ROR, and IC025 shifts.** Nothing
here appends — the dashboard is pinned to a fixed snapshot and has to be
regenerated whole. Any figure quoted in the report or in dashboard captions
needs regenerating too.

---

## Disclaimer

> FAERS public data, 2025Q4–2026Q1. Independent analysis, not affiliated with or
> endorsed by the FDA. Disproportionality signals indicate that a drug-reaction
> pair is reported more often than expected relative to the rest of the
> database — they do not establish causation. FAERS reports are voluntary and
> unverified, contain duplicates, and have no exposure denominator. Not medical
> advice.
