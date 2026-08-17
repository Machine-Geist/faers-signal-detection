/* ============================================================================
   03 — mart_validation_signals : disproportionality at reference-set grain
   ============================================================================
   PURPOSE   Recomputes the same disproportionality math at the grain the
             reference set actually lives at: one aggregated drug, one
             aggregated outcome.
   GRAIN     One row per (stratum, tier, ref_drug, outcome_group).
   DEPENDS   ref_exposure_map, ref_outcome_groups, stg_drug_ingredient,
             stg_reac, mart_case_strata, mart_stratum_totals
   FEEDS     04_validation_scoring.sql

   ---------------------------------------------------------------------------
   ** WHY A SEPARATE MART — THE MULTIPLE TESTING TRAP **
   ---------------------------------------------------------------------------
   mart_disproportionality_signals is keyed on individual MedDRA PTs. A
   reference pair like "amlodipine -> acute liver injury" is spread across 8
   narrow-tier PTs and up to 4 FAERS salt forms -- as many as 32 rows.

   Taking the best IC025 among them would be running 32 tests and keeping the
   winner. A negative control gets 32 chances to look like a signal, and
   specificity collapses for a reason that has nothing to do with the method.

   Instead: aggregate case counts first, compute disproportionality ONCE.
     a  = distinct cases mentioning ANY mapped ingredient AND ANY group PT
     a+b = distinct cases mentioning ANY mapped ingredient
     a+c = distinct cases reporting ANY group PT
   count(DISTINCT caseid) throughout handles a case that reports two PTs from
   the same group, or two salt forms of the same drug.

   ---------------------------------------------------------------------------
   ** ZERO-COUNT PAIRS MUST EXIST **
   A reference pair with no co-occurrences is a legitimate observation. For a
   negative control it is the correct answer, and dropping it would inflate
   every metric. The grid CTE cross-joins the observed drug and outcome
   marginals and LEFT JOINs the counts, so a=0 rows are present rather than
   silently missing.

   THE LIMIT OF THAT GUARANTEE
   The grid is built from OBSERVED totals, not from the reference set itself.
   A pair survives as a=0 only when both marginals are non-zero in that
   stratum. If a reference drug has no eligible cases in a stratum it never
   enters drug_totals, and every pair involving it disappears from that
   stratum entirely -- not as a=0, but as no row at all. The same applies to
   an outcome group with no cases in a stratum.

   In ALL this is unlikely to bite: the four outcome groups are high-volume
   and most reference drugs appear. In EXPEDITED and SERIOUS, which are
   fractions of ALL, low-volume reference drugs can drop out. The consequence
   is that the strata are scored on DIFFERENT pair sets, and a stratum that
   silently lost its hardest pairs would post a better AUC for a reason that
   has nothing to do with discrimination.

   MEASURED, 2025Q4-2026Q1 (see the first VERIFY query below)
       stratum        drugs   pairs
       ALL              144     576
       NO_MASK_DRUG     144     576
       SERIOUS          130     520
       EXPEDITED        129     516
   Roughly 10% of reference drugs have no eligible cases in the narrower
   strata and vanish rather than scoring a=0. The dropout is real, not
   hypothetical.

   This is handled downstream rather than here: the matched-pair query in
   04_validation_scoring.sql restricts the cross-stratum comparison to pairs
   present in all four strata, so the strata are compared on identical
   ground. Any per-stratum metric computed WITHOUT that filter is not
   comparable across strata.

   Building the grid from ref_exposure_map x ref_outcome_map x strata x tiers
   instead would make every reference pair appear in every stratum as a true
   a=0. That is the cleaner construction and worth doing if this is revisited;
   it was not done here because the matched-pair filter already recovers the
   comparison that depends on it.

   TIERS: narrow (clinical diagnoses) and broad (plus lab abnormalities) are
   both built, so the whole validation can be reported as a sensitivity
   analysis rather than a single definition.
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_validation_signals CASCADE;

CREATE MATERIALIZED VIEW public.mart_validation_signals AS

WITH tier_def AS (
    SELECT 'narrow'::text AS tier UNION ALL SELECT 'broad'
),

/* PT membership per tier. broad = narrow + broad. */
outcome_pt AS (
    SELECT t.tier, g.outcome_group, g.reaction_pt
    FROM tier_def t
    JOIN public.ref_outcome_groups g
      ON (t.tier = 'narrow' AND g.tier = 'narrow')
      OR (t.tier = 'broad'  AND g.tier IN ('narrow','broad'))
),

/* Cases exposed to each reference drug, any salt form. */
drug_cases AS (
    SELECT DISTINCT cs.stratum, m.omop_exposure_name AS ref_drug, i.caseid
    FROM public.ref_exposure_map m
    JOIN public.stg_drug_ingredient i
      ON i.ingredient = m.faers_ingredient
     AND i.role_cod   = 'PS'
    JOIN public.mart_case_strata cs
      ON cs.caseid = i.caseid
),

/* Cases reporting each outcome group, any member PT. */
outcome_cases AS (
    SELECT DISTINCT op.tier, op.outcome_group, cs.stratum, cs.caseid
    FROM outcome_pt op
    JOIN public.stg_reac r
      ON upper(btrim(r.pt)) = op.reaction_pt
    JOIN public.mart_case_strata cs
      ON cs.primaryid = r.primaryid
),

drug_totals AS (
    SELECT stratum, ref_drug, count(*) AS drug_total
    FROM drug_cases GROUP BY 1,2
),

outcome_totals AS (
    SELECT tier, stratum, outcome_group, count(*) AS outcome_total
    FROM outcome_cases GROUP BY 1,2,3
),

pair_counts AS (
    SELECT oc.tier, dc.stratum, dc.ref_drug, oc.outcome_group,
           count(*) AS a
    FROM drug_cases dc
    JOIN outcome_cases oc
      ON oc.caseid  = dc.caseid
     AND oc.stratum = dc.stratum
    GROUP BY 1,2,3,4
),

/* Every combination, so zero-count pairs survive. */
grid AS (
    SELECT ot.tier, ot.stratum, dt.ref_drug, ot.outcome_group,
           dt.drug_total, ot.outcome_total, st.n_cases::numeric AS n_total
    FROM outcome_totals ot
    JOIN drug_totals dt        ON dt.stratum = ot.stratum
    JOIN public.mart_stratum_totals st ON st.stratum = ot.stratum
),

contingency AS (
    SELECT g.tier, g.stratum, g.ref_drug, g.outcome_group,
           g.n_total,
           g.drug_total::numeric                       AS drug_total,
           g.outcome_total::numeric                    AS outcome_total,
           COALESCE(p.a, 0)::numeric                   AS a,
           (g.drug_total    - COALESCE(p.a,0))::numeric AS b,
           (g.outcome_total - COALESCE(p.a,0))::numeric AS c,
           (g.n_total - g.drug_total - g.outcome_total
                      + COALESCE(p.a,0))::numeric       AS d
    FROM grid g
    LEFT JOIN pair_counts p
           ON p.tier          = g.tier
          AND p.stratum       = g.stratum
          AND p.ref_drug      = g.ref_drug
          AND p.outcome_group = g.outcome_group
),

corrected AS (
    SELECT ct.*,
           (drug_total * outcome_total) / NULLIF(n_total,0)         AS n_exp,
           CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN a+0.5 ELSE a END AS a_c,
           CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN b+0.5 ELSE b END AS b_c,
           CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN c+0.5 ELSE c END AS c_c,
           CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN d+0.5 ELSE d END AS d_c
    FROM contingency ct
),

metrics AS (
    SELECT tier, stratum, ref_drug, outcome_group,
           a::bigint            AS case_count,
           drug_total::bigint   AS drug_total,
           outcome_total::bigint AS outcome_total,
           n_total::bigint      AS n_cases_in_stratum,
           ROUND(n_exp, 3)      AS expected_count,
           ROUND((a_c/NULLIF(a_c+b_c,0)) / NULLIF(c_c/NULLIF(c_c+d_c,0),0), 3) AS prr,
           ROUND((n_total * POWER(a_c*d_c - b_c*c_c, 2))
                 / NULLIF((a_c+b_c)*(c_c+d_c)*(a_c+c_c)*(b_c+d_c),0), 3)       AS chi_square,
           ROUND((a_c*d_c)/NULLIF(b_c*c_c,0), 3)                               AS ror,
           SQRT(1.0/a_c + 1.0/b_c + 1.0/c_c + 1.0/d_c)                         AS se_ln_ror,
           /* IC on RAW counts with its own +0.5 prior -- never the Haldane
              cells, which would double-apply the prior on sparse pairs. */
           ROUND(LN((a + 0.5)/NULLIF(n_exp + 0.5,0)) / LN(2.0), 3)             AS ic
    FROM corrected
),

bounds AS (
    SELECT m.*,
           ROUND(EXP(LN(NULLIF(ror,0)) - 1.96*se_ln_ror), 3) AS ror_ci_lower,
           ROUND(ic - 3.3*POWER(case_count+0.5, -0.5)
                    - 2.0*POWER(case_count+0.5, -1.5), 3)    AS ic025
    FROM metrics m
)

SELECT b.*,
       (prr >= 2 AND chi_square >= 4 AND case_count >= 3) AS is_prr_signal,
       (ror_ci_lower > 1 AND case_count >= 3)             AS is_ror_signal,
       (ic025 > 0)                                        AS is_ic_signal
FROM bounds b;

CREATE UNIQUE INDEX mart_validation_signals_pk
    ON public.mart_validation_signals (stratum, tier, ref_drug, outcome_group);

ANALYZE public.mart_validation_signals;


/* VERIFY -------------------------------------------------------------------

-- Row count and stratum coverage. The product ref_drugs x 4 outcomes x 2
-- tiers x 4 strata is the UPPER bound, not the expected value -- pairs drop
-- out of a stratum when either marginal is zero there (see header).
SELECT stratum, tier,
       count(*)                                AS pairs,
       count(DISTINCT ref_drug)                AS drugs,
       count(*) FILTER (WHERE case_count = 0)  AS zero_count_pairs
FROM public.mart_validation_signals
GROUP BY 1,2 ORDER BY 1,2;

-- Grid cells surviving in all four strata. NOTE this counts every
-- (drug, outcome) combination, not just OMOP-labeled reference pairs --
-- the labeled subset is smaller and is what section 6 of 04 scores on.
SELECT count(*) AS matched_grid_cells
FROM (SELECT ref_drug, outcome_group
      FROM public.mart_validation_signals WHERE tier='broad'
      GROUP BY 1,2 HAVING count(DISTINCT stratum) = 4) t;

-- Cells must sum to N (tolerance 2 for Haldane).
SELECT count(*) AS violations
FROM public.mart_validation_signals
WHERE abs((case_count + (drug_total - case_count)
           + (outcome_total - case_count)
           + (n_cases_in_stratum - drug_total - outcome_total + case_count))
          - n_cases_in_stratum) > 2;

-- Sanity: aggregation should raise exposure counts vs the PT-level mart.
-- Amlodipine is the clearest example of the salt-mapping effect.
SELECT ref_drug, tier, outcome_group, case_count, drug_total,
       outcome_total, prr, ic025
FROM public.mart_validation_signals
WHERE stratum = 'ALL' AND ref_drug ILIKE 'amlodipine'
ORDER BY outcome_group, tier;

--------------------------------------------------------------------------- */
