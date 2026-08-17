# 03_validation — Does It Actually Work?

The mart layer produces signals. This layer answers the question that makes
them worth anything: **when the pipeline flags a drug-reaction pair, is it
right?**

Signals are scored against the OMOP reference set — an external,
literature-adjudicated list of drug-outcome pairs where the answer is already
known. Nothing here feeds the dashboard or changes a published mart number.
This layer exists to measure the pipeline, not to extend it.

Run `00_setup`, `01_staging`, and `02_marts` first.

| Script | Object | Type |
|---|---|---|
| `01_ref_outcome_groups.sql` | `ref_outcome_groups` | Table |
| `02_validation_mappings.sql` | `ref_outcome_map`, `ref_exposure_map`, `ref_exposure_exclusions` | Tables |
| `03_mart_validation_signals.sql` | `mart_validation_signals` | Materialized view |
| `04_validation_scoring.sql` | `v_validation_base` + scoring queries | View |

Run in numeric order. Scoring queries in `04` are commented out — uncomment and
run individually.

---

## The benchmark

The OMOP reference set (Ryan et al., *Drug Safety* 2013) contains 399
drug-outcome pairs: 165 positive controls where the drug is believed to cause
the outcome, and 234 negative controls where it isn't. Four outcomes: acute
liver injury, acute kidney injury, acute myocardial infarction, and upper GI
bleeding.

Scoring against it is straightforward in principle — flag the positives, stay
silent on the negatives — and the entire difficulty is that OMOP and FAERS
don't speak the same language. Two vocabulary problems have to be solved before
a single metric can be computed, and both are judgment-heavy enough that they
get their own files.

---

## Problem 1: outcomes (`01_ref_outcome_groups`)

OMOP names outcomes as clinical concepts. FAERS codes reactions as MedDRA
Preferred Terms, and one clinical concept spans dozens of PTs. No single PT
carries enough volume to stand in for "acute liver injury."

MedDRA ships Standardised MedDRA Queries — validated PT groupings built for
exactly this — but MedDRA is licensed and SMQs aren't available here.
`ref_outcome_groups` is a hand-built substitute. That's legitimate and common
practice; it just has to be transparent, which is why every decision is a row
in a table with a written rationale, including the rejections.

Three tiers:

| Tier | Contents |
|---|---|
| `narrow` | Clinical diagnoses only. Specific, defensible, lower volume. |
| `broad` | `narrow` plus lab abnormalities. Higher volume, looser definition. |
| `excluded` | Reviewed and rejected, with reasons. |

Recording exclusions as rows rather than omissions is the point of the design:
it makes "considered and rejected" distinguishable from "never looked at." Some
are mechanical (`ADRENAL INSUFFICIENCY` was a regex artifact — ADRENAL contains
RENAL). Some are clinical (`METASTASES TO LIVER` would make every oncology drug
a hepatotoxin). Two are there specifically to keep known artifacts out of the
ground truth: `EOSINOPHILIC OESOPHAGITIS` and `COLITIS ULCERATIVE` are both
indication artifacts already measured in `mart_indication_match`, and including
them would import a contaminated signal into the benchmark.

Both tiers are scored, so the whole validation doubles as a sensitivity
analysis on the outcome definition.

---

## Problem 2: drug names (`02_validation_mappings`)

OMOP names drugs at the active-moiety level. FAERS `prod_ai` often carries the
salt or ester form. OMOP's "Amlodipine" is AMLODIPINE, AMLODIPINE BESYLATE,
AMLODIPINE MALEATE, and AMLODIPINE MESYLATE in FAERS — 2,055 cases across all
forms versus 39 for the base name alone.

Getting this wrong doesn't produce a slightly worse number; it produces
guaranteed false negatives. SERTRALINE and ESCITALOPRAM have **no exact match
at all** in this dataset — 1,742 and 711 records recovered entirely through
salt forms. Unmapped, both would have scored zero cases and counted as misses.

The file is structured so the mechanical and the judgmental stay separate:

- **B1 auto-populates** by prefix match. Safe in this direction because the OMOP
  name is the moiety — `AMLODIPINE BESYLATE` starts with `AMLODIPINE`. Held for
  45 of 46 multi-form drugs.
- **B2–B4 apply reviewed corrections** as explicit statements afterwards.
- **Section C records rejected candidates** in a separate table.

Running the file top to bottom reproduces the reviewed state exactly. The
ordering is what makes that work: a re-run re-inserts the rows B2 deleted, then
B2 deletes them again.

### The one the string rule got wrong

The prefix rule merged seven tenofovir forms spanning two distinct prodrugs.
Tenofovir alafenamide (TAF) exists **because** tenofovir disoproxil (TDF)
causes renal and bone toxicity — lower plasma exposure, better safety profile.
That difference is the entire clinical rationale for the drug's existence, so
they are not name variants of one another. OMOP's tenofovir pairs predate TAF
approval and refer to TDF. Merging them would have diluted the TENOFOVIR
DISOPROXIL / BONE DENSITY DECREASED signal this pipeline independently found.

Bare `TENOFOVIR` is dropped too, as prodrug-ambiguous. Costs volume; every
retained record is unambiguously TDF.

No string rule finds this. It needed pharmacology.

### Why exclusions live in their own table

`ref_outcome_groups` stores exclusions as a tier because `03` filters on tier
explicitly. `ref_exposure_map` is joined **without** a `match_type` filter, so
an 'excluded' row there would silently be treated as a real mapping. A separate
table makes that bug impossible.

The largest trap in the candidate set was `Epoetin Alfa → DARBEPOETIN ALFA` —
374 records, and an engineered longer-acting analog rather than a name variant.
A fuzzy matcher would likely accept it. The exclusion is independently
confirmed downstream: darbepoetin alfa appears in the results as its own
reference drug with exactly those 374 records, having never been folded into
epoetin alfa.

---

## The multiple-testing trap (`03_mart_validation_signals`)

Scoring can't reuse `mart_disproportionality_signals`, and the reason is the
most important methodological decision in this layer.

That mart is keyed on individual PTs. A reference pair like "amlodipine → acute
liver injury" is spread across 8 narrow-tier PTs and up to 4 salt forms — as
many as 32 rows. Taking the best IC025 among them is running 32 tests and
keeping the winner. Every negative control gets 32 chances to look like a
signal, and specificity collapses for reasons that have nothing to do with the
method being tested.

So `03` recomputes the same math at the grain the reference set actually lives
at — one aggregated drug, one aggregated outcome — by aggregating case counts
**first** and computing disproportionality **once**:

```
a    = distinct cases mentioning ANY mapped ingredient AND ANY group PT
a+b  = distinct cases mentioning ANY mapped ingredient
a+c  = distinct cases reporting ANY group PT
```

Zero-count pairs are kept deliberately. For a negative control, no
co-occurrence is the *correct* answer, and dropping those rows would inflate
every metric.

**One documented limit:** the grid is built from observed marginals, so a
reference drug with no eligible cases in a stratum vanishes from it rather than
scoring a=0. Measured here, 144 reference drugs appear in ALL but only 129 in
EXPEDITED and 130 in SERIOUS — about 10% dropout. Raw per-stratum metrics are
therefore not comparable, and section 6 of `04` handles it with a matched-pair
filter. Full detail in `03`'s header.

---

## Results

Measured on 2025Q4–2026Q1. AUC figures use the matched pair set (261 pairs: 114
positive, 147 negative); classification metrics use the full ALL-stratum set.

### Discrimination

| Stratum | IC025 (broad) | ROR | PRR | IC025 (narrow) |
|---|---|---|---|---|
| ALL | **0.812** | 0.768 | 0.595 | 0.787 |
| NO_MASK_DRUG | 0.811 | 0.768 | 0.593 | 0.787 |
| EXPEDITED | 0.782 | 0.714 | 0.504 | 0.756 |
| SERIOUS | 0.779 | 0.704 | 0.493 | 0.730 |

**IC025 > ROR > PRR in all sixteen stratum × tier combinations.** An ordering
that holds under every slice is stronger evidence than one measured once.

PRR is barely better than chance at baseline and reaches it under
stratification. The Bayesian shrinkage that makes IC025 conservative on sparse
pairs is what makes it rank well; PRR's sensitivity to a near-empty background
scatters true and false positives together at the top.

Narrow scores 0.02–0.03 below broad on every method with ordering unchanged, so
the hand-built outcome groupings aren't driving the result — which matters,
given they're judgment calls made without SMQ access.

### Classification (IC025 > 0, ALL, broad)

| | |
|---|---|
| True positives | 45 |
| False positives | 2 |
| True negatives | 175 |
| False negatives | 86 |
| **Sensitivity** | **34%** |
| **Precision** | **96%** |
| Specificity | 99% |

Highly specific, deliberately insensitive. The output is a review queue for
humans, and a queue that's 96% real is usable while a queue at 50% is not.

### Both false positives are confounding by indication

`darbepoetin alfa / AKI` (a=17) and `entecavir / AKI` (a=10). Neither is a
failure of the math — both are drugs whose treated population has renal disease
for reasons unrelated to the drug.

Darbepoetin alfa treats anaemia of chronic kidney disease, so the exposed
population is renally impaired by definition. `mart_indication_match` does not
catch it: the coded indication is ANAEMIA or CHRONIC KIDNEY DISEASE while the
flagged reaction is RENAL IMPAIRMENT — same clinical context, different MedDRA
PTs. That is the exact lower-bound limitation documented in `05a`, demonstrated
on a labeled negative control.

Entecavir is renally eliminated and requires dose adjustment in renal
impairment, so renal function is monitored in that population. Whether it is
causally nephrotoxic is unsettled, which makes it a candidate for reference-set
misclassification rather than a method failure.

### Two disconfirmed hypotheses

**Stratification did not help.** AUC fell from 0.812 to 0.782 (EXPEDITED) and
0.779 (SERIOUS). The hypothesis was reasonable — expedited reports exclude the
periodic channel carrying solicited, already-labeled events — but the loss of
sample size outweighs the gain in report quality.

**Masking did not matter.** Excluding dupilumab, the single highest-volume
ingredient at ~7.8% of PS cases, moved AUC by 0.001. Stronger than that: ALL
and NO_MASK_DRUG are identical on drugs, pairs, and zero-count pairs in every
tier. The exclusion removes no reference drug and creates no new zero-count
pair, so competition bias from one dominant reporter has essentially no
structural effect on this reference set.

Both strata stay in the pipeline. The negative results are part of the finding,
and removing the strata would remove the evidence for them.

---

## The benchmark has its own problems

Three caveats that cut against reading these numbers too literally, all in the
direction of understating performance.

**The negative controls are partly wrong.** Roughly 17% of OMOP's negative
controls have been found misclassified or potentially misclassified (Hauben et
al., *Drug Safety* 2016) — 21 pairs failing OMOP's own adjudication criteria
and 19 more with case-report or observational evidence of association. Some
scored false positives may be real associations mislabeled as negatives, so
0.812 is more likely an underestimate than an overestimate.

**The reference set is aged.** It was built in 2013 and is scored here against
2025–26 data. Several reference drugs are simply absent — alatrofloxacin
(withdrawn 1999), pemoline, rosiglitazone, nefazodone. Their absence is a
finding about benchmark drift, not a gap to chase.

**One outcome definition doesn't line up.** OMOP's concept is "Acute Liver
Failure," the severe end; `ACUTE_LIVER_INJURY` is broader, including JAUNDICE
and HEPATIC CYTOLYSIS. Left as-is and disclosed — tightening it would mean
rebuilding the outcome group around a different clinical concept.

---

## Rebuilding

The reference tables are static; only the mart depends on FAERS data. After
loading a new quarter and running `02_marts/07_refresh_marts.sql`:

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_validation_signals;
ANALYZE public.mart_validation_signals;
```

Re-run `02_validation_mappings.sql` as well if new salt forms appeared — B1
picks up mappings that didn't exist before, and the file is safe to re-run.

Every result above shifts when the data changes. These figures are pinned to
2025Q4–2026Q1.
