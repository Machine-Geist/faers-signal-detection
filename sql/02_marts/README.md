# 02_marts — Disproportionality Analysis

This is where the analysis happens. The staging layer made FAERS usable; this
layer asks the actual question: **is any drug-reaction pair reported more often
than the rest of the database would lead you to expect?**

Run `00_setup` and `01_staging` first.

| Script | Object | Type |
|---|---|---|
| `00_ref_masking_exclusions.sql` | `ref_masking_exclusions` | Table |
| `01_mart_case_strata.sql` | `mart_case_strata` | Materialized view |
| `02_mart_stratum_totals.sql` | `mart_stratum_totals` | Materialized view |
| `03_mart_drug_totals.sql` | `mart_drug_totals` | Materialized view |
| `04_mart_reaction_totals.sql` | `mart_reaction_totals` | Materialized view |
| `05_mart_drug_reaction_counts.sql` | `mart_drug_reaction_counts` | Materialized view |
| `05a_mart_indication_match.sql` | `mart_indication_match` | Materialized view |
| `06_mart_disproportionality_signals.sql` | `mart_disproportionality_signals` | Materialized view |
| `07_refresh_marts.sql` | — | Refresh script |

Run in numeric order on a first build. `07` is for subsequent quarters only.

Every file carries a `VERIFY` block at the bottom, commented out. Those are the
invariants — run them after a build.

---

## The model

Everything here assembles one 2×2 table per drug-reaction pair, per stratum:

```
                      | Reaction Y | Not Y |
       Ingredient X   |     a      |   b   |   a + b = drug_total
       Not X          |     c      |   d   |
                        a + c = reaction_total     a+b+c+d = N
```

Each script builds one piece:

- `03` produces `a + b` — how often the drug appears
- `04` produces `a + c` — how often the reaction appears
- `05` produces `a` — how often they appear together
- `02` produces `N` — the size of the population
- `06` derives `b`, `c`, `d` and computes the metrics

`01` is what makes the four pieces commensurable, and it's the most
consequential object in the layer.

### Why the universe has to be defined once

The four counts above are only comparable if they come from the same
population. `01_mart_case_strata` defines eligibility exactly once — a case
counts only if it has **both** a primary-suspect drug **and** a reaction — and
every other mart inherits it by inner-joining that view.

Skip this and the pieces silently disagree: drug totals drawn from cases with a
PS drug, reaction totals from all cases with a reaction, and `N` from every
deduplicated case. Three populations, one contingency table, and a background
rate that's wrong in a direction you can't see. A case missing either component
can never land in any drug's `a` cell, so including it only inflates `d`.

---

## The strata

`01` maps each eligible case to every stratum it belongs to, so a case usually
appears more than once. Grain is `(stratum, caseid)`.

| Stratum | Definition | Why |
|---|---|---|
| `ALL` | every eligible case | baseline |
| `EXPEDITED` | `rept_cod = 'EXP'` | 15-day reports, legally required when an event is serious *and* unexpected. Excludes the periodic channel that carries solicited, already-labeled events. |
| `SERIOUS` | ≥1 ICH-serious outcome code | restricts to clinically consequential cases |
| `NO_MASK_DRUG` | excludes cases naming any drug in `ref_masking_exclusions` | tests for masking (competition bias) |

Two judgment calls worth knowing about:

**`OT` is excluded from `SERIOUS`.** The ICH codes used are DE, LT, HO, DS, CA,
and RI. `OT` ("other serious") is a catch-all, and including it materially
loosens the definition.

**Masking exclusions live in a table, not in the SQL.** A single very
high-volume drug inflates the background rate for its own characteristic
reactions, suppressing PRR for every other drug reporting them. Which drug
dominates is a property of the data and changes as quarters are added, so
rescaling should be an `INSERT`, not a view rewrite.

**Stratification was tested and did not help.** It was a reasonable hypothesis
— that filtering to expedited or serious reports would sharpen the signal — and
the validation disconfirmed it. AUC fell on the matched pair set. The strata
remain in the pipeline because the negative result is part of the finding.

---

## The three metrics

`06` computes all three on every pair, which is the point: the comparison is the
deliverable, not any single number.

**PRR** — Proportional Reporting Ratio, `(a/(a+b)) / (c/(c+d))`. Signal under
Evans' criteria: PRR ≥ 2 **and** chi-square ≥ 4 **and** a ≥ 3.

**ROR** — Reporting Odds Ratio, `(a·d)/(b·c)`. Signal when the 95% CI lower
bound exceeds 1. This is a weaker criterion than Evans' — it asks whether the
ratio is significantly above 1, not whether it reaches 2 — so ROR flags more
pairs.

**IC / IC025** — Information Component, `log₂((a+0.5)/(E+0.5))` where
`E = (a+b)(a+c)/N`, with `IC025 = IC − 3.3(a+0.5)^−0.5 − 2(a+0.5)^−1.5`. IC025
approximates the 2.5th percentile of the posterior. Both penalty terms shrink as
`a` grows, which is why `is_ic_signal` carries no minimum case count: at a = 1
or a = 2 the penalty alone keeps IC025 below zero regardless of the ratio. Used
by the WHO Uppsala Monitoring Centre (Bate et al. 1998; Norén et al. 2006).

### Two corrections that must not be combined

**Haldane-Anscombe** adds 0.5 to all four cells, but only when some cell is
zero. It's a computational fix for division by zero, and it applies to PRR,
chi-square, and ROR.

**IC's Bayesian prior** adds 0.5 to observed and expected, always. It's a
statistical prior asserting independence before seeing the data.

Feeding Haldane-corrected values into IC would apply a prior twice, on exactly
the sparse pairs where the prior dominates. So IC uses raw `a` and raw expected;
the frequentist measures use the corrected cells.

---

## Why PRR is unusable at the top of the ranking

When `c` is 0, Haldane sets it to 0.5 and the background rate collapses to
roughly 6.6e-7, so PRR explodes into the millions. But `c = 1` or `c = 2`
produces nearly the same explosion — a zero-cell test alone doesn't catch it.
For 2025Q4–2026Q1, ETONOGESTREL / PREGNANCY WITH IMPLANT CONTRACEPTIVE reaches
PRR 122,529 with no zero cell at all.

Measured PRR distribution across IC signals with no zero cell:

| p50 | p90 | p99 | p99.9 | max |
|---|---|---|---|---|
| 11.05 | 106.38 | 1,487.95 | 15,660 | 566,964 |

Five orders of magnitude carrying no interpretive information — a PRR of 100 and
a PRR of 500,000 mean the same thing in practice ("extreme, driven by a
near-empty background"). IC025 has none of this behavior: bounded, log-scaled,
shrunk. **If one metric goes on an axis, it should be IC025, with PRR in the
tooltip.**

`06` handles this with three columns: `background_count` exposes `c` directly,
`is_sparse_background` flags small `c`, and `prr_display` caps the value for
plotting while `prr_capped` marks which points were clipped. Nothing is hidden —
`prr` retains the true value.

---

## Indication confounding

Lack of efficacy is a reportable event in most jurisdictions. When a drug fails
to control the condition it treats, a case gets filed with that condition coded
as the reaction — and the contingency table looks identical to a real adverse
reaction.

`05a_mart_indication_match` measures, for each pair, what share of its cases
list the reaction as the documented indication. For 2025Q4–2026Q1, indication
artifacts are 2,307 of 70,728 IC025 signals (3.3%) overall and 5 of the top 100
by IC025 — roughly 1.5× enriched at the top of the ranking, but not dominant
there.

Two mechanisms share this signature and the flag cannot separate them:

- **Lack of efficacy** — the drug treats the condition and the patient doesn't
  improve (sacituzumab/TNBC, imatinib/CML)
- **Co-morbidity** — the drug doesn't treat the condition; it's the clinical
  context (oxycodone/rheumatoid arthritis, where oxycodone treats RA pain and
  the case reports the RA worsening)

**The flag is a lower bound.** Matching is on exact MedDRA Preferred Term, so
clinically identical concepts coded differently are missed — antihemophilic
factor / HAEMARTHROSIS is almost certainly indication confounding but reads 3%,
because the indication is coded HAEMOPHILIA A. Catching those needs the MedDRA
hierarchy (PT → HLT → SOC), which is licensed and not used here.

Indications are also matched at **case** level, not drug level. `stg_indi` links
to a specific drug via `indi_drug_seq`, but `stg_drug_ingredient` can't carry
`drug_seq` — the grain changed when `prod_ai` was split. On polypharmacy cases
this can over-attribute.

### Choosing the threshold

Share of IC signals flagged at each cutoff:

| 10% | 20% | 25% | 30% | 50% | 75% | 90% |
|---|---|---|---|---|---|---|
| 3,834 | 2,679 | 2,307 | 1,881 | 1,234 | 750 | 459 |

Smooth decay, no natural break. The data will not choose a cutoff, so any value
is a documented judgment call rather than a discovered one. **25% is used here:**
a genuine ADR should have near-zero indication overlap, and 25% catches
near-miss artifacts — LANADELUMAB / HEREDITARY ANGIOEDEMA sits at 49.7% and
escapes a 50% cutoff — at a cost of about 1.5% of signals.

---

## Tunable parameters

Every judgment call in `06` lives in one `params` CTE at the top:

| Parameter | Value | Meaning |
|---|---|---|
| `indication_threshold` | 25 | `pct_indication_match` at or above this flags an artifact |
| `sparse_background_max` | 5 | `c` below this makes PRR and ROR unreliable |
| `prr_display_cap` | 100 | ≈p90; clips about 10% of values for plotting |

Declared once because `indication_threshold` is read by both
`is_likely_indication_artifact` and `is_review_candidate`. Written inline in
each, changing one and not the other would leave them silently disagreeing.

---

## The output

`mart_disproportionality_signals` is one row per `(stratum, ingredient,
reaction_pt)` carrying the cells, the three metrics, and the diagnostic flags.
The column that matters most is **`is_review_candidate`**: an IC025 signal, not
driven by its own indication, and not resting on an empty background. That's the
column that turns half a million candidate pairs into a reviewable queue.

```sql
SELECT ingredient, reaction_pt, case_count, background_count,
       ic025, prr, pct_indication_match
FROM public.mart_disproportionality_signals
WHERE stratum = 'ALL' AND is_review_candidate
ORDER BY ic025 DESC
LIMIT 100;
```

---

## Refreshing

After loading a new quarter, run `07_refresh_marts.sql`. **Order is
load-bearing** — refreshing a parent after its child leaves the child built on
stale data, and nothing errors when that happens. The refresh succeeds and the
numbers are quietly wrong.

The `mart_indication_match` step is the one to watch. `06` LEFT JOINs it, so a
stale indication mart yields `pct_indication_match = 0` for every new pair,
marking them all artifact-free by construction.

`CONCURRENTLY` requires a populated view, so omit it on the very first build.

Note that adding a quarter changes `N`, so every PRR, ROR, and IC025 shifts.
Published figures need regenerating, not appending to.
