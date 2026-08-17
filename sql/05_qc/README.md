# 05_qc — Assertions and Diagnostics

Checks that run after every build and every refresh. Nothing here produces
output for the dashboard; this section exists to catch the class of bug that
does not announce itself.

Run last, after `00_setup` through `04_exports`.

| Script | Contents |
|---|---|
| `01_qc_checks.sql` | 9 assertions, 2 analysis outputs |

---

## Why this section exists

The failures that matter in a pipeline like this one are silent. A join that
fans out doesn't error — it returns plausible numbers that are wrong by a
factor of twenty. A stale materialized view doesn't error — it returns last
quarter's answer. A normalization expression that drifts out of sync between
two marts doesn't error — it quietly drops rows from an inner join.

Every one of those produces a chart that looks fine. The only defense is
assertions that state what must be true and fail loudly when it isn't.

This pipeline has already been bitten once: the grain bug in
`stg_drug_ingredient` produced tens of thousands of spurious rows because the
view carried every case version rather than the latest. It was caught by a row
count that didn't match expectation, not by anything erroring.

---

## An assertion must be able to fail

The first version of this file contained a check that reconstructed the
contingency cells and confirmed they summed to N. It looked rigorous. It was
worthless.

```
a =  case_count
b =  drug_total - case_count
c =  reaction_total - case_count
d =  n - drug_total - reaction_total + case_count
```

Sum those and every term cancels except `n`. The identity holds algebraically
whatever is in the table — on correct data, on corrupt data, on an empty
table. The check passed because it could not do anything else.

The problem was that `b`, `c`, and `d` are *derived from* the stored
marginals, so reconstructing them proves only that arithmetic works. The
replacement checks compare each stored value against the mart it was sourced
from, which is a claim that can actually be false.

**A green light wired to nothing is worse than no light.** Before adding a
check here, work out what would have to go wrong for it to fail. If nothing
would, it isn't a check.

---

## What each assertion catches

### Cross-mart reconciliation (1–3)

Every marginal in `mart_disproportionality_signals` must match the mart it
came from. These catch a stale refresh: if `mart_drug_totals` was rebuilt but
`mart_disproportionality_signals` was not, check 1 fires. This is the most
likely real-world failure, because it happens whenever a refresh runs out of
dependency order.

### Structural impossibilities (4–5)

A negative `d` cell means the marginals exceed N — the drug and reaction marts
are drawing from different populations, which is exactly the failure the
shared universe in `mart_case_strata` exists to prevent.

A pair count exceeding either marginal means the drug × reaction join is
fanning out. Both are impossible in correct data by construction.

### Row survival (6)

Every candidate pair in `mart_drug_reaction_counts` must appear in
`mart_disproportionality_signals`. A shortfall points at the coupled PT
normalization expression — `upper(btrim(r.pt))` appears in both mart `04` and
mart `05`, and if they drift apart the join in `06` silently drops rows. That
coupling is flagged in both files, and this check is what would catch it.

Wrapped in `abs()`, because a difference in either direction fails — more
signals than candidate pairs would mean `06` is fanning out.

### Grain and containment (7–9)

Subset strata cannot exceed `ALL`. Deduplication must be exact — rows, distinct
`caseid`, and distinct `primaryid` all equal in `stg_demo_latest`. No case in
any stratum may be missing from the deduplicated master.

The dedup check duplicates the `UNIQUE` index assertion in
`02_stg_demo_latest.sql`, deliberately. That index fails at build time; this
check fails at any time, including after a refresh.

---

## The two analysis outputs

Checks 10 and 11 are results, not assertions. They live here because they are
diagnostics rather than dashboard content.

**Shrinkage profile** — where the three methods disagree as a function of case
count. This is the strongest single piece of reasoning in the repo, and it
supports two claims the AUC figures cannot.

First, IC025 *redistributes* sensitivity rather than being uniformly stricter:
below 10 cases PRR flags 37% more, and above 10 cases IC025 flags more at
every count.

Second, having an uncertainty estimate is not what separates the methods. ROR
carries a proper 95% confidence interval and still flags within 1% of PRR in
the sparse region — above that it is the most permissive of the three. What
distinguishes IC025 is how hard it penalizes, not that it quantifies
uncertainty at all.

Together these separate two different failures: PRR fails as a *ranking*
metric, which is why its AUC is 0.595 while ROR — flagging nearly the same
pairs — reaches 0.768. IC025's advantage over ROR is as a *threshold*. The
full argument is in the file's comment block.

**Stratum comparison** — which signals strengthen when the periodic reporting
channel is removed. Signals that strengthen are candidate unmasked signals; the
ones that weaken are candidate solicited-reporting artifacts. Ranked on IC025
rather than PRR, because a PRR delta is dominated by whichever pair has the
emptiest background.

---

## When a check fails

| Check | Most likely cause | First thing to try |
|---|---|---|
| 1–3 marginals disagree | Refresh ran out of dependency order | Re-run `02_marts/07_refresh_marts.sql` top to bottom |
| 4 negative d | A mart is bypassing `mart_case_strata` | Check every mart inner-joins the universe |
| 5 pair exceeds marginal | `count(*)` where `count(DISTINCT caseid)` was needed | Inspect the drug × reaction join in mart `05` |
| 6 rows lost | PT normalization drifted between marts `04` and `05` | Diff the two `upper(btrim(...))` expressions |
| 7 stratum > ALL | A stratum is not a subset of the universe | Inspect the `UNION ALL` branches in mart `01` |
| 8 dedup grain | `DISTINCT ON` ordering is not deterministic | Check the tie-break chain in `02_stg_demo_latest.sql` |
| 9 orphan cases | `stg_demo_latest` refreshed after `mart_case_strata` | Refresh in dependency order |

Four of the seven trace back to refresh ordering, which is why
`07_refresh_marts.sql` states its dependency chain explicitly.

---

## Running these

Checks 1–6 return a single table, one row per check, so a full pass is one
glance. The remaining assertions and the two analysis outputs run as separate
statements.

Run after:

- a first build
- loading a new quarter and refreshing
- any change to a staging view or mart definition
- before exporting CSVs for the dashboard

That last one matters most. Every number a viewer sees passes through
`04_exports`, and a failed assertion caught before export is a non-event —
caught after publication, it is a correction.
