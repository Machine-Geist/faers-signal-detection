# Decisions

Every judgment call in this pipeline, what was chosen, what was rejected, and
why. Where a decision was tested against data, the measurement is here too —
including the times it went against the choice that seemed obvious.

Implementation detail lives in the section READMEs and the file headers. This
document is the index.

---

## Register

| # | Decision | Alternative | Rationale | Where |
|---|---|---|---|---|
| 1 | Restrict to `role_cod = 'PS'` | include SS | PS is the drug the reporter considered causally relevant | `02_marts/01` |
| 2 | Deduplicate to latest case version | count all versions | amended cases would double-count | `01_staging/03` |
| 3 | Fully deterministic tie-break | `caseversion DESC` alone | the same version can appear in two quarterly files | `01_staging/03` |
| 4 | `prod_ai` over `drugname` | free-text cleaning | 100% populated, 45% compression, FDA-validated | `01_staging/04` |
| 5 | Minimal `clean_ingredient()` | dosage / salt stripping | digits are identity, not noise | `01_staging/02` |
| 6 | Split combinations on backslash | keep as single entities | signals are properties of molecules | `01_staging/04` |
| 7 | Split *then* clean | clean then split | end-trimming is position-sensitive | `01_staging/04` |
| 8 | Skip salt/ester merging | curate 332 variants | needs RxNorm; measured at 7.08% and documented | `limitations.md §4` |
| 9 | Computed per-stratum N | hardcoded literal | stratified analysis requires it | `02_marts/02` |
| 10 | Universe defined once | per-mart filters | three marts would otherwise use three populations | `02_marts/01` |
| 11 | Evans' `a >= 3` as criterion, not filter | filter in the counts mart | preserves the low-count region where methods differ | `02_marts/05` |
| 12 | IC on raw counts | on Haldane-corrected cells | avoids applying a prior twice | `02_marts/06` |
| 13 | `is_sparse_background` at c < 5 | zero-cell test only | c=2 inflates PRR nearly as badly as c=0 | `02_marts/06` |
| 14 | Indication threshold 25% | 50% | lanadelumab at 49.7% and escapes a 50% cut; flags 3.3% of IC signals | `02_marts/06` |
| 15 | PRR display cap at 100 | uncapped | ≈p90; makes the axis readable, clipping flagged | `02_marts/06` |
| 16 | Rank on IC025 | PRR | AUC 0.812 vs 0.595; bounded and interpretable | `03_validation` |
| 17 | All thresholds in one `params` CTE | inline literals | the indication threshold is read in two places | `02_marts/06` |
| 18 | `OT` excluded from SERIOUS | include it | catch-all; materially loosens the definition | `02_marts/01` |
| 19 | Masking exclusions in a table | hardcoded list | which drug dominates is a property of the data | `02_marts/00` |
| 20 | Aggregate mart for validation | max across PTs | avoids testing 32 times and keeping the winner | `03_validation/03` |
| 21 | Tenofovir restricted to disoproxil | merge all forms | TAF is a distinct prodrug with a different safety profile | `03_validation/02` |
| 22 | Exposure exclusions in a separate table | a `match_type` value | the map is joined without a type filter | `03_validation/02` |
| 23 | Both outcome tiers scored | narrow only | turns the definition into a sensitivity analysis | `03_validation/01` |
| 24 | Matched-pair set for cross-stratum AUC | raw per-stratum | strata don't share a pair set | `03_validation/04` |
| 25 | CSV export, statistics in SQL | Tableau-side calculations | keeps every number in version control | `04_exports` |
| 26 | Assertions must be able to fail | reconstruct-and-verify | a check that always passes is a green light wired to nothing | `05_qc` |

---

## The six that carry the most weight

### Deduplicate to the latest case version, deterministically

FAERS ships one row per case *version*. A case amended three times appears three
times, sharing one `caseid` across three `primaryid` values. Counting without
collapsing inflates every downstream figure.

`caseversion DESC` alone is not enough. The same `(caseid, caseversion)` can
appear in more than one quarterly file, and `DISTINCT ON` with a partial
`ORDER BY` returns an arbitrary row — potentially a different one between runs,
which would make every published count unreproducible. The full chain is
`caseversion DESC, fda_dt DESC NULLS LAST, source_quarter DESC, primaryid DESC`.

Measured: **zero ambiguous pairs across both quarters.** The tie-break earns
nothing today and everything at more quarters.

The `UNIQUE` indexes on `caseid` and `primaryid` are the assertion. If dedup
fails, index creation fails loudly rather than silently producing duplicates.

### Define the analysis universe once

A case is eligible only if it has **both** a primary-suspect drug **and** a
reaction. Every mart inner-joins `mart_case_strata` to inherit that definition.

Without it, drug totals, reaction totals, and `N` are drawn from three different
populations and the contingency table mixes incompatible denominators. A case
missing either component can never land in any drug's `a` cell, so including it
only inflates `d` and biases every PRR downward.

Measured impact of the eligibility filter: **22 cases.** Essentially nil —
nearly every deduplicated case has both. Reported as a measured non-finding. The
per-stratum `N` was the part that mattered.

### Never combine the two +0.5 corrections

**Haldane-Anscombe** adds 0.5 to all four cells, but only when a cell is zero.
It's a computational fix for division by zero and applies to PRR, chi-square,
and ROR.

**IC's Bayesian prior** adds 0.5 to observed and expected, unconditionally. It's
a statistical prior asserting independence before seeing the data.

Feeding Haldane-corrected values into IC applies a prior twice, on exactly the
sparse pairs where the prior dominates. IC uses raw counts; the frequentist
measures use corrected cells.

### Aggregate before computing disproportionality, for validation

`mart_disproportionality_signals` is keyed on individual PTs. A reference pair
like "amlodipine → acute liver injury" spans up to 8 narrow-tier PTs × 4 salt
forms = 32 rows.

Taking the best IC025 among them is 32 tests keeping the winner. Every negative
control gets 32 chances to look like a signal, and specificity collapses for
reasons unrelated to the method being tested.

`mart_validation_signals` aggregates case counts first and computes
disproportionality once. Zero-count pairs are kept deliberately — for a negative
control, no co-occurrence is the correct answer, and dropping those rows would
inflate every metric.

### Restrict tenofovir to disoproxil forms

The prefix rule that correctly resolved 45 of 46 multi-form drugs pulled
`TENOFOVIR ALAFENAMIDE` in with `TENOFOVIR DISOPROXIL`.

TAF was developed **specifically because** TDF causes renal and bone toxicity.
That difference is the entire clinical rationale for the drug existing, so they
are not name variants of one another. OMOP's tenofovir pairs predate TAF
approval and refer to TDF. Merging would have diluted the TDF / bone-density
signal this pipeline independently found. Bare `TENOFOVIR` is dropped too, as
prodrug-ambiguous.

**One failure in 46, and no string rule finds it.** It needed pharmacology.
This is the decision that most clearly justifies the manual review layer
existing at all.

### An assertion must be able to fail

The first QC file contained a check that reconstructed the contingency cells and
confirmed they summed to `N`. Expanding it:

```
a + b + c + d
= case_count + (drug_total − case_count) + (reaction_total − case_count)
  + (N − drug_total − reaction_total + case_count)
= N
```

Every term cancels. The identity holds algebraically whatever the data says — on
correct data, corrupt data, or an empty table. The check passed because it could
not do otherwise.

`b`, `c`, and `d` are *derived from* the stored marginals, so reconstructing
them proves only that arithmetic works. The replacements compare each stored
value against the mart it was sourced from, which is a claim that can be false.

---

## Where measurement overturned the assumption

The most useful table in this document. Every row is a case where the plan was
reasonable and the data disagreed.

| Assumption | Measured | Consequence |
|---|---|---|
| FAERS drug names are severely fragmented | 5,634 distinct, `prod_ai` 100% populated and FDA-validated | Planned regex cleaner scrapped |
| Combination splitting is the main normalisation win | 5.1% of records; 3,089 → 2,837 ingredients | Deprioritised |
| Salt fragmentation is ~1–2% | **7.08%** | Skip-vs-curate revisited; still skipped, but knowingly |
| The universe eligibility fix matters | 22 cases | Reported as a measured non-finding |
| Stratification will improve discrimination | AUC 0.812 → 0.782 / 0.779 | **Hypothesis disconfirmed** |
| Masking by the dominant drug is material | 0.812 vs 0.811; identical drug and pair counts | Negligible in this reference set |
| Stratification removes zero-cell artifacts | 17 of 5,631 | It does not |
| Indication artifacts dominate the top of the ranking | 5 of the top 100 by IC025, against a 3.3% base rate | Not dominant, and no detectable enrichment |
| An uncertainty estimate is what separates the methods | ROR has a 95% CI and flags within 1% of PRR at 1–10 cases | It's the penalty size, not the presence of a CI |

The literature-driven assumption about drug-name fragmentation is worth
singling out: it describes pre-2014 data. Every PS record here has been
validated against FDA's product dictionary, and a dosage-stripping regex would
have been **actively harmful** — `INTERFERON BETA-1A` (1a and 1b are different
drugs), `POLYETHYLENE GLYCOL 3350` (molecular weight distinguishes it from PEG
400), `LUTETIUM LU-177`. The digits are identity, not noise.

---

## Two bugs worth owning

### The grain bug

`stg_drug_ingredient` initially read from `stg_drug` without restricting to the
latest case version: **844,047 rows against 816,264 distinct `(caseid,
ingredient)` pairs.** The 27,783-row gap was entirely `caseversion = 2` —
amended cases counted twice.

Fixed by joining `stg_demo_latest`. This is the bug that made `UNIQUE` indexes
standard on every materialized view afterwards. Every mart metric computed
before the fix was wrong, and nothing errored.

### The sorting error

An early claim — "38 of the top 40 signals are indication artifacts" — came from
a list sorted by `pct_indication_match DESC`. That ordering returns high-match
rows by construction, so the statement was true of the list and meaningless as a
claim about the signal ranking.

Measured against the actual IC025 ranking: **5 of the top 100.** Enriched
roughly 1.5x relative to the 3.3% base rate, but not dominant.

Sorting by the variable you are measuring and then describing the result as a
property of a different ranking is a real error. It was caught by re-running
against the correct ordering.

---

## Ordering and thresholding are different problems

The decision to rank on IC025 (#16) rests on AUC 0.812 versus 0.595 for PRR. The
shrinkage profile in `05_qc` shows the mechanism, and it is not what it first
appears.

| Case count | Pairs | PRR | ROR | IC025 |
|---|---|---|---|---|
| 1–10 | 490,005 | 61,334 | 60,934 | 44,932 |
| 11–20 | 19,431 | 11,807 | 12,767 | 11,993 |
| 100+ | 2,624 | 1,909 | 2,256 | 2,238 |

**IC025 is not uniformly stricter.** Below 10 cases it flags 37% fewer pairs
than PRR; above 10 cases it flags more at every count. The Bayesian penalty
moves sensitivity out of the region where one additional report swings the ratio
and into the region where the data can carry the claim.

**And having a confidence interval is not the differentiator.** ROR carries a
proper 95% CI and still flags within 1% of PRR in the sparse region — above
bucket 1 it is the most permissive of the three. What separates IC025 is how
hard it penalizes: `3.3(a+0.5)^−0.5` is a far higher bar at small `a` than "CI
lower bound above 1."

Yet ROR ranks at 0.768 while PRR ranks at 0.595, flagging nearly the same pairs.
Those coexist because AUC measures *ordering* and `ror_ci_lower` is a
well-behaved ordering statistic, while raw PRR explodes into six figures on
near-empty backgrounds and scatters true and false positives together at the top.

**PRR fails as a ranking metric. IC025's advantage over ROR is as a threshold.**
Neither claim is visible from the AUC figures alone.

---

## Thresholds are documented, not discovered

Share of IC signals flagged as indication artifacts at each cutoff:

| 10% | 25% | 50% | 90% |
|---|---|---|---|
| 3,834 | 2,307 | 1,234 | 459 |

Smooth decay, no natural break. **The data will not choose a cutoff.** 25% is
used because a genuine ADR should have near-zero indication overlap and 25%
catches near-miss artifacts — lanadelumab / hereditary angioedema sits at 49.7%
and escapes a 50% cut.

At 25%, 2,307 of 70,728 IC025 signals (3.3%) are flagged as artifacts. 
Tightening from 50% to 25% excludes an additional 1,073 signals, roughly 1.5% 
of the total - the cost of the tigher threshold.

All three tunable values live in one `params` CTE:

| Parameter | Value | Meaning |
|---|---|---|
| `indication_threshold` | 25 | at or above this, flag as artifact |
| `sparse_background_max` | 5 | `c` below this makes PRR and ROR unreliable |
| `prr_display_cap` | 100 | ≈p90; clips ~10% of values for plotting |

Centralized because `indication_threshold` is read by both
`is_likely_indication_artifact` and `is_review_candidate`. Written inline in
each, changing one and not the other would leave them silently disagreeing.
