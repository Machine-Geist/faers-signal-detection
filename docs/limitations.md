# Limitations

Every known weakness in this pipeline, what it costs, and why it was left
unresolved. Ordered by how much it constrains what the output can be used for.

Nothing here was discovered by a reviewer. Each was found during the build,
measured where measurement was possible, and left in place as a documented
trade-off rather than a silent one.

---

## 1. Disproportionality is not causation

The foundational constraint, and the one everything else sits under.

A disproportionality signal means a drug-reaction pair appears in FAERS more
often than the rest of the database would lead you to expect. It does not mean
the drug caused the reaction. Reporting patterns are shaped by media attention,
litigation, time since approval, manufacturer patient-support programmes, and
the reporter's own causal beliefs — all of which move the numerator without
anything happening to a patient.

**The deliverable is a ranked review queue, not a set of conclusions.** Every
downstream claim in this project is about detection performance, never about
pharmacology.

---

## 2. No exposure denominator

FAERS records reports, not patients. There is no way to know how many people
took a drug, so a "rate" cannot be computed. Disproportionality substitutes the
rest of the database as a comparator, which controls for nothing about the
exposed population.

This is why a drug prescribed exclusively to a sick population produces signals
for that population's baseline morbidity. **Both false positives in the
validation are exactly this** — darbepoetin alfa and entecavir, both flagged for
acute kidney injury, both given to patients with renal disease for reasons
unrelated to the drug.

Not fixable within FAERS. Resolving it requires a claims or EHR database with a
denominator, which is a different project.

---

## 3. Two quarters only

2025Q4–2026Q1. Consequences:

- No time-series and no emerging-signal detection
- No notoriety-bias analysis — signals driven by a news cycle look identical to
  signals driven by biology
- Low-volume drugs are underpowered; several validation misses are drugs with
  one or two total reports

The pipeline is quarter-agnostic and the setup README documents the append
path. The constraint is scope, not design.

Note that adding quarters changes `N`, so every PRR, ROR, and IC025 shifts.
Nothing appends — the analysis is pinned to a fixed denominator.

---

## 4. Salt and ester forms are not resolved

`clean_ingredient()` normalizes case, whitespace, and FDA's Greek-letter
escapes. It does not merge `CIPROFLOXACIN` with `CIPROFLOXACIN HYDROCHLORIDE`.

**Measured: 332 variants, 7.08% of PS drug records.** Prediction before
measuring was 1–2%, so this is the limitation whose size was most badly
underestimated.

Splitting one moiety across several ingredient names splits its case counts,
lowering `a` and weakening every signal for that moiety.

**Why not fixed:** reliable merging needs RxNorm ingredient / precise-ingredient
relationships or FDA UNII active-moiety mapping. A string rule cannot do it —
sodium phosphate and potassium phosphate are different substances that share a
prefix, and a naive salt-stripping rule would merge them. The validation layer
demonstrates this concretely: the prefix rule there produced exactly one wrong
merge in 46 multi-form drugs, and catching it needed pharmacology, not string
logic.

Decided knowingly after measurement, not by default.

---

## 5. The MedDRA hierarchy is unavailable

FAERS ships Preferred Terms. The hierarchy above them — HLT, HLGT, SOC — and the
Standardised MedDRA Queries built on it require a licence.

**Four separate limitations trace to this single fact:**

- Outcome groups for validation are hand-built rather than SMQ-derived (§9)
- Indication matching is exact-PT only, so clinically identical concepts coded
  differently are missed (§6)
- Non-ADR terms — medication errors, product quality complaints, drug diversion
  — cannot be filtered by SOC and remain in the signal set (§8)
- Class-level analysis is not possible

The most consequential single unavailable resource in the project.

---

## 6. Indication matching is a lower bound

`mart_indication_match` flags a pair when the reaction is also the drug's
documented indication — the signature of lack-of-efficacy reporting, which is
legally reportable in most jurisdictions and produces a contingency table
identical to a real adverse reaction.

Matching is on **exact Preferred Term**, so it catches only identical coding.

The clearest miss: **antihemophilic factor / HAEMARTHROSIS reads 3%.** Joint
bleeding in a haemophilia patient is almost certainly indication confounding,
but the indication is coded `HAEMOPHILIA A` and the reaction `HAEMARTHROSIS`.
Different PTs, same clinical fact.

The validation false positives make the same point on labelled data:
darbepoetin alfa's indication is `ANAEMIA` or `CHRONIC KIDNEY DISEASE` while the
flagged reaction is `RENAL IMPAIRMENT` — not caught, despite being textbook
confounding by indication.

**So the true prevalence of indication confounding is higher than measured, by
an unknown amount.** Resolving it needs the MedDRA hierarchy.

### The flag also cannot separate two mechanisms

| Mechanism | Example |
|---|---|
| Lack of efficacy — drug treats the condition, patient doesn't improve | sacituzumab / TNBC, imatinib / CML |
| Co-morbidity — drug doesn't treat the condition, it's the clinical context | oxycodone / rheumatoid arthritis |

Both matter for review triage, and they mean different things. The flag returns
one number for both.

---

## 7. Indication matching is at case level, not drug level

`stg_indi` links an indication to a specific drug via `indi_drug_seq`.
`stg_drug_ingredient` cannot carry `drug_seq` — the grain changed when `prod_ai`
was split into ingredients — so the match is made at case level.

On a polypharmacy case, one drug's indication can be attributed to another drug
on the same case. Over-attribution, direction known, magnitude not measured.

---

## 8. Artifact classes identified but not handled

Three patterns found during artifact review, characterised but not filtered:

**Co-medication confounding.** Emtricitabine flags signals it inherits from
co-formulated tenofovir. The co-formulation means the two are almost never
reported apart, so disproportionality cannot separate them.

**Procedure confounding.** Five peritoneal-dialysis solution components all flag
bacterial peritonitis. The peritonitis is a complication of the procedure, not
of any component.

**Non-ADR MedDRA terms.** Medication errors, product quality complaints, and
drug diversion are coded as reactions and behave like signals. Filterable by
SOC, which is licensed (§5).

Each would be a separate mart with its own reference data. Documented as scope,
not oversight.

---

## 9. Outcome groups for validation are hand-built

`ref_outcome_groups` maps MedDRA PTs to OMOP's four clinical outcomes because
SMQs are unavailable. Every assignment is a clinical judgment call, recorded as
a table row with a written rationale, including 33 documented exclusions.

**Mitigation:** both tiers are scored. Narrow (clinical diagnoses) lands 0.02–
0.03 below broad on every method with the ordering unchanged, so the groupings
are not driving the result. That stability is evidence, not proof.

**One known mismatch left in place:** OMOP's concept is "Acute Liver Failure,"
the severe end of the spectrum. `ACUTE_LIVER_INJURY` here is broader, including
`JAUNDICE` and `HEPATIC CYTOLYSIS`. Tightening it would mean rebuilding the
group around a different clinical concept. Disclosed rather than fixed.

---

## 10. The reference set has documented accuracy problems

**~17% of OMOP's negative controls are misclassified or potentially
misclassified** — 21 pairs failing OMOP's own adjudication criteria and 19 more
with case-report or observational evidence of association (Hauben, Aronson &
Ferner, *Drug Safety* 2016). The classification criteria are also asymmetric
with respect to case-report evidence.

Some pairs scored here as false positives may be real associations mislabelled
as negatives. **AUC 0.812 is therefore more likely an underestimate than an
overestimate.**

---

## 11. The reference set was built for a different data type

OMOP was designed for claims-based effect estimation, where an exposure
denominator exists. A pair that is detectable in claims can be undetectable in
spontaneous reports by construction.

This bounds what the validation can prove. It measures whether this pipeline
ranks like a claims-derived ground truth — a reasonable proxy, not the same
question as whether it finds real adverse reactions.

---

## 12. The reference set has aged

Built in 2013, scored here against 2025–26 data. **91 of 399 pairs are
unmappable**, predominantly withdrawn or obsolete products: trovafloxacin,
valdecoxib, rosiglitazone, pemoline, nefazodone.

Their absence is a finding about benchmark drift, not a gap to chase. Coverage
is 308 of 399 pairs — 131 positive, 177 negative.

---

## 13. Strata do not share a pair set

`mart_validation_signals` builds its grid from observed marginals, so a
reference drug with no eligible cases in a stratum vanishes from that stratum
rather than scoring `a = 0`.

**Measured: 144 reference drugs appear in ALL, 130 in SERIOUS, 129 in
EXPEDITED** — roughly 10% dropout.

Raw per-stratum metrics are therefore not comparable. Handled by the
matched-pair filter in `04_validation_scoring.sql`, which restricts the
cross-stratum comparison to the 261 pairs present in all four strata (114
positive, 147 negative). Any per-stratum figure computed without that filter is
comparing different problems.

The cleaner fix — building the grid from the reference set rather than from
observed marginals — is documented in `03`'s header and not implemented.

---

## 14. Sensitivity is 34%

At the default IC025 > 0 threshold on the broad tier: 45 true positives, 2 false
positives, 175 true negatives, 86 false negatives. Precision 96%, specificity
99%, **sensitivity 34%**.

Two thirds of known positives are missed. Measured, the misses fall into two
groups:

- **50 of 86 have zero co-occurrences.** The drug and the reaction never
appear together anywhere in these two quarters. No method at any threshold
can detect a pair that isn't in the data. This group would shrink
substantially with more quarters loaded.
- **36 were reported together but no more than expected.** Some are
high-volume drugs whose signal is diluted across a large existing reaction
profile — clozapine has 23 liver-injury co-occurrences across 3,214 reports
and still scores IC025 −2.28; infliximab has 107 across 5,388. That dilution
is a real property of disproportionality rather than an implementation flaw,
and more data would help it less.

For a triage queue this is the right error profile: reviewer time is the scarce
resource, and a queue that is 96% real is usable while a queue at 50% is not.
But the pipeline is a filter, not a detector, and it should not be described as
one.

---

## 15. Data-type and parsing issues in the raw layer

Minor, documented, and not reaching any published number.

**`dose_amt` is `int8`.** FAERS ships fractional doses; an integer type
truncates them at load. Not consumed downstream.

**Date parsing checks digit count, not calendar validity.** PostgreSQL's
`to_date` silently rolls over impossible values — `20250230` returns March 2nd
rather than NULL. No date column feeds a published metric; `fda_dt` appears only
as a tie-break in `stg_demo_latest`, and that tie-break never fires (zero
ambiguous `caseid`/`caseversion` pairs across both quarters).

**321 records carry `role_cod = 'DN'`**, Negligible volume, excluded from the 
PS-restricted analysis, noted.

---

## 16. Single-analyst project

Every clinical judgment call — outcome group membership, tier assignment,
exclusion rationale, the salt-form audit — was made by one person without
independent review. There is no inter-rater reliability figure because there was
one rater.

The mitigation is transparency rather than consensus: every decision is a table
row with a written rationale, so a reader can disagree with any specific
assignment and see exactly what changing it would affect.

---

## What would resolve these

Roughly in order of value per unit of effort:

| Limitation | Requires |
|---|---|
| §4 salt/ester | RxNorm or FDA UNII active-moiety mapping |
| §5, §6, §8 | MedDRA licence (hierarchy + SMQs) |
| §3 time-series | 8+ quarters loaded |
| §7 drug-level indication | Redesign of `stg_drug_ingredient` grain |
| §13 pair-set dropout | Build the validation grid from the reference set |
| §2 denominator | A different data source entirely |
| §16 single analyst | A second reviewer |
