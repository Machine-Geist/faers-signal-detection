/* ============================================================================
   06 — mart_disproportionality_signals          ** THE CENTERPIECE **
   ============================================================================
   PURPOSE   Builds a 2x2 contingency table per drug-reaction pair within each
             stratum and computes three families of disproportionality measure,
             plus the diagnostic flags that turn raw output into a triage list.
   GRAIN     One row per (stratum, ingredient, reaction_pt).
   DEPENDS   mart_drug_reaction_counts, mart_drug_totals, mart_reaction_totals,
             mart_stratum_totals, mart_indication_match
   FEEDS     Tableau CSV export; all analysis queries.

   ---------------------------------------------------------------------------
   THE CONTINGENCY TABLE
   ---------------------------------------------------------------------------
                         | Reaction Y | Not Y |
          Ingredient X   |     a      |   b   |   a + b = drug_total
          Not X          |     c      |   d   |
                           a+c = reaction_total       a+b+c+d = N

     a = pair_count
     b = drug_total     - a      b = 0 when the drug ONLY ever reports Y
     c = reaction_total - a      c = 0 when Y ONLY ever occurs with this drug
     d = N - drug_total - reaction_total + a

   ---------------------------------------------------------------------------
   TWO CORRECTIONS THAT MUST NOT BE COMBINED
   ---------------------------------------------------------------------------
   HALDANE-ANSCOMBE (+0.5 to all four cells, ONLY when some cell is zero)
     A computational fix for division by zero. Applies to PRR, chi-square,
     and ROR. Conditional.

   IC's BAYESIAN PRIOR (+0.5 to observed and expected, ALWAYS)
     A statistical prior asserting independence before seeing data.
     Unconditional. Applies only to IC.

   Feeding Haldane-corrected values into IC would apply a prior twice, on
   exactly the sparse pairs where the prior dominates. So: IC uses RAW a and
   RAW expected; the frequentist measures use the corrected cells.

   ---------------------------------------------------------------------------
   ** SPARSE BACKGROUND — WHY PRR IS UNUSABLE AT THE TOP OF THE RANKING **
   ---------------------------------------------------------------------------
   When c is 0, Haldane sets it to 0.5 and the background rate becomes
   0.5/N ~ 6.6e-7, so PRR explodes into the millions. But c = 1 or c = 2
   produces nearly the same explosion, so a zero-cell test alone is not
   enough. For 2025Q4-2026Q1 ETONOGESTREL / PREGNANCY WITH IMPLANT 
   CONTRACEPTIVE reaches PRR 122,529 with no zero cell at all.

   For 2025Q4-2026Q1 measured PRR distribution across IC signals with 
   no zero cell:
       p50 = 11.05    p90 = 106.38    p99 = 1,487.95
       p99.9 = 15,660    max = 566,964
   The upper tail spans five orders of magnitude and carries no interpretive
   information -- a PRR of 100 and a PRR of 500,000 mean the same thing in
   practice ("extreme, driven by a near-empty background").

   IC025 has none of this behaviour: it is bounded, log-scaled, and shrunk.
   
   Handled here by three columns: background_count exposes c directly,
   is_sparse_background flags small c, and prr_display caps the value for
   plotting with prr_capped marking which points were clipped.

   ---------------------------------------------------------------------------
   ** INDICATION CONFOUNDING **
   ---------------------------------------------------------------------------
   Lack of efficacy is a reportable event, so a drug that fails to control
   its target condition generates cases with that condition coded as the
   reaction. The contingency table is identical to a real adverse reaction.

   pct_indication_match (from mart_indication_match) is the share of a pair's
   cases where the reaction is also the documented indication.

   For 2025Q4-2026Q1: indication artifacts are 2,307 of 70,728 IC025 signals 
   (3.3%) overall, and 5 of the top 100 by IC025 — roughly 1.5× enriched at 
   the top of the ranking, but not dominant there.

   Threshold sensitivity (share of IC signals flagged at each cutoff):
       10% -> 3,834    20% -> 2,679    25% -> 2,307    30% -> 1,881
       50% -> 1,234    75% ->   750    90% ->   459
   Smooth decay, no natural break -- the data will not choose a cutoff, so
   any value is a documented judgment call rather than a discovered one.
   25% is used here: a genuine ADR should have near-zero indication overlap,
   and 25% catches near-miss artifacts (LANADELUMAB / HEREDITARY ANGIOEDEMA
   sits at 49.7% and escaped a 50% cutoff) at a cost of ~1.5% of signals.

   The flag is a LOWER BOUND -- it matches exact MedDRA PTs only, so
   clinically identical concepts coded differently are missed (ANTIHEMOPHILIC
   FACTOR / HAEMARTHROSIS reads 3% because the indication is coded
   HAEMOPHILIA A).

   ---------------------------------------------------------------------------
   THE THREE METHODS
   ---------------------------------------------------------------------------
   PRR  = (a/(a+b)) / (c/(c+d))
     Proportional Reporting Ratio. Evans: PRR >= 2 AND chi-square >= 4 AND a >= 3.

   ROR  = (a*d) / (b*c)
     Reporting Odds Ratio. Signal when the 95% CI lower bound exceeds 1.
     A WEAKER criterion than PRR's: it asks whether the ratio is
     significantly above 1, not whether it reaches 2. Hence more ROR signals.

   IC   = log2( (a + 0.5) / (E + 0.5) ),   E = (a+b)(a+c)/N
   IC025 = IC - 3.3(a+0.5)^-0.5 - 2(a+0.5)^-1.5
     Information Component; IC025 is the approximate 2.5th percentile of its
     posterior. Both penalty terms shrink as `a` grows, so sparse pairs are
     pulled toward the null. This is why is_ic_signal carries NO minimum case
     count -- the penalty is the guard. At a=1 or a=2 the penalty is large
     enough that IC025 can never exceed 0 regardless of the ratio.
     (Bate et al. 1998; Noren et al. 2006. Used by WHO Uppsala Monitoring
     Centre. FDA's MGPS/EBGM uses the same shrinkage idea with a more complex
     prior requiring numerical fitting.)
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_disproportionality_signals CASCADE;

CREATE MATERIALIZED VIEW public.mart_disproportionality_signals AS

/* --- Step 0: tunable parameters, declared ONCE --------------------------
   Every judgment call in this view lives here. The indication threshold is
   read by both is_likely_indication_artifact and is_review_candidate; if it
   were written inline in each, changing one and not the other would leave
   them silently disagreeing. A one-row CTE cross-joined at the end costs
   nothing and makes that class of error impossible.
   ---------------------------------------------------------------------- */
WITH params AS (
    SELECT 25::numeric   AS indication_threshold,  -- see sensitivity table above
           5::numeric    AS sparse_background_max, -- c below this: PRR unreliable
           100::numeric  AS prr_display_cap        -- ~p90; clips ~10% for plotting
),

/* --- Step 1: assemble the four cells ------------------------------------ */
contingency AS (
    SELECT
        prc.stratum,
        prc.ingredient,
        prc.reaction_pt,
        st.n_cases::numeric                                        AS n_total,
        dt.drug_total::numeric                                     AS drug_total,
        rt.reaction_total::numeric                                 AS reaction_total,
        prc.pair_count::numeric                                    AS a,
        (dt.drug_total     - prc.pair_count)::numeric              AS b,
        (rt.reaction_total - prc.pair_count)::numeric              AS c,
        (st.n_cases - dt.drug_total
                    - rt.reaction_total + prc.pair_count)::numeric AS d,
        COALESCE(im.indication_cases, 0)                           AS indication_cases,
        COALESCE(im.pct_indication_match, 0)                       AS pct_indication_match
    FROM public.mart_drug_reaction_counts prc
    JOIN public.mart_drug_totals dt
      ON dt.stratum    = prc.stratum
     AND dt.ingredient = prc.ingredient
    JOIN public.mart_reaction_totals rt
      ON rt.stratum     = prc.stratum
     AND rt.reaction_pt = prc.reaction_pt
    JOIN public.mart_stratum_totals st
      ON st.stratum = prc.stratum
    /* LEFT JOIN: a pair with no indication rows at all must still appear,
       with a match rate of 0 rather than vanishing from the mart. */
    LEFT JOIN public.mart_indication_match im
      ON im.stratum     = prc.stratum
     AND im.ingredient  = prc.ingredient
     AND im.reaction_pt = prc.reaction_pt
),

/* --- Step 2: expected count, and the conditional Haldane correction ----- */
corrected AS (
    SELECT
        ct.*,
        (drug_total * reaction_total) / NULLIF(n_total, 0)         AS n_exp,
        CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN a + 0.5 ELSE a END AS a_c,
        CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN b + 0.5 ELSE b END AS b_c,
        CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN c + 0.5 ELSE c END AS c_c,
        CASE WHEN a=0 OR b=0 OR c=0 OR d=0 THEN d + 0.5 ELSE d END AS d_c
    FROM contingency ct
),

/* --- Step 3: the metrics ------------------------------------------------ */
metrics AS (
    SELECT
        stratum, ingredient, reaction_pt,
        a::bigint                AS case_count,
        n_total::bigint          AS n_cases_in_stratum,
        drug_total::bigint       AS drug_total,
        reaction_total::bigint   AS reaction_total,
        ROUND(n_exp, 3)          AS expected_count,
        indication_cases::bigint AS indication_cases,
        pct_indication_match     AS pct_indication_match,

        /* The background cell, exposed directly. A reviewer seeing
           "this reaction occurs 232 times, all 232 with this drug"
           understands an extreme PRR immediately. */
        c::bigint AS background_count,

        /* zero-cell diagnostics, carried forward as flags */
        (b = 0) AS zero_b,
        (c = 0) AS zero_c,

        ROUND( (a_c / NULLIF(a_c + b_c, 0))
               / NULLIF(c_c / NULLIF(c_c + d_c, 0), 0), 3)          AS prr,

        /* Pearson chi-square, 1 df. 3.84 is the exact 0.05 critical value;
           Evans rounds to 4, slightly conservative. */
        ROUND( (n_total * POWER(a_c*d_c - b_c*c_c, 2))
               / NULLIF((a_c+b_c)*(c_c+d_c)*(a_c+c_c)*(b_c+d_c), 0), 3)
                                                                    AS chi_square,

        ROUND( (a_c * d_c) / NULLIF(b_c * c_c, 0), 3)               AS ror,
        SQRT(1.0/a_c + 1.0/b_c + 1.0/c_c + 1.0/d_c)                 AS se_ln_ror,

        /* IC: raw a, raw expected, its own unconditional +0.5 */
        ROUND( LN((a + 0.5) / NULLIF(n_exp + 0.5, 0)) / LN(2.0), 3) AS ic
    FROM corrected
),

/* --- Step 4: interval bounds -------------------------------------------
   This CTE exists because ror_ci_lower is needed both as an output column
   and inside is_ror_signal. Postgres will not let you reference a column
   alias in the SELECT that defines it, so computing it one layer earlier
   means it is calculated once and the two uses cannot drift apart.
   ---------------------------------------------------------------------- */
bounds AS (
    SELECT
        m.*,
        ROUND( EXP(LN(NULLIF(ror, 0)) - 1.96 * se_ln_ror), 3)  AS ror_ci_lower,
        ROUND( EXP(LN(NULLIF(ror, 0)) + 1.96 * se_ln_ror), 3)  AS ror_ci_upper,
        ROUND( ic - 3.3 * POWER(case_count + 0.5, -0.5)
                  - 2.0 * POWER(case_count + 0.5, -1.5), 3)    AS ic025
    FROM metrics m
)

/* --- Step 5: signal flags, diagnostics, and display columns ------------ */
SELECT
    b.*,

    /* --- SIGNAL CRITERIA --- */
    (b.prr >= 2 AND b.chi_square >= 4 AND b.case_count >= 3) AS is_prr_signal,
    (b.ror_ci_lower > 1 AND b.case_count >= 3)               AS is_ror_signal,
    (b.ic025 > 0)                                            AS is_ic_signal,

    /* Booleans cast to int and summed: 0-3.*/
    ((b.prr >= 2 AND b.chi_square >= 4 AND b.case_count >= 3)::int
     + (b.ror_ci_lower > 1 AND b.case_count >= 3)::int
     + (b.ic025 > 0)::int)                                   AS n_methods_flagged,

    /* --- SPARSITY DIAGNOSTICS ---
       zero_c: reaction reported ONLY with this ingredient. Often a
               diagnostic finding, indication, or mechanism-of-action lab
               value rather than an adverse reaction.
       zero_b: ingredient reported ONLY with this reaction. Usually a very
               low-volume drug whose entire case series shares one event. */
    b.zero_c                       AS is_zero_c_cell,
    b.zero_b                       AS is_zero_b_cell,
    (b.zero_b OR b.zero_c)         AS has_zero_cell,
    (b.background_count < p.sparse_background_max) AS is_sparse_background,

    /* TRUE when PRR and ROR can be read at face value. Requires a non-empty
       AND non-trivial background -- c=2 inflates PRR nearly as badly as c=0. */
    (NOT (b.zero_b OR b.zero_c)
     AND b.background_count >= p.sparse_background_max) AS frequentist_reliable,

    /* --- INDICATION CONFOUNDING --- */
    (b.pct_indication_match >= p.indication_threshold)
                                   AS is_likely_indication_artifact,

    /* --- THE TRIAGE FILTER ---
       A signal by the shrinkage-based method, not driven by its own
       indication, and not resting on an empty background. This is the
       column that turns 527,841 candidate pairs (from 2025Q4-2026Q1)
        into a reviewable queue. */
    (b.ic025 > 0
     AND b.pct_indication_match < p.indication_threshold
     AND NOT (b.zero_b OR b.zero_c))              AS is_review_candidate,

    /* --- DISPLAY COLUMNS ---
       PRR spans five orders of magnitude, so plot prr_display and mark
       prr_capped points as off-scale rather than at their literal position.
       Nothing is hidden: prr retains the true value. */
    LEAST(b.prr, p.prr_display_cap) AS prr_display,
    (b.prr > p.prr_display_cap)     AS prr_capped

FROM bounds b
CROSS JOIN params p;

/* No ORDER BY: materialized views have no inherent order, and sorting costs
   a full sort on every refresh. The indexes below
   serve the common ones. Note ic025 DESC, not prr DESC. */

CREATE UNIQUE INDEX mart_disproportionality_signals_pk
    ON public.mart_disproportionality_signals (stratum, ingredient, reaction_pt);
CREATE INDEX mart_disproportionality_signals_ing
    ON public.mart_disproportionality_signals (stratum, ingredient);
CREATE INDEX mart_disproportionality_signals_pt
    ON public.mart_disproportionality_signals (stratum, reaction_pt);
CREATE INDEX mart_disproportionality_signals_rank
    ON public.mart_disproportionality_signals (stratum, is_ic_signal, ic025 DESC);
CREATE INDEX mart_disproportionality_signals_worklist
    ON public.mart_disproportionality_signals (stratum, is_review_candidate, ic025 DESC);

ANALYZE public.mart_disproportionality_signals;


/* VERIFY -------------------------------------------------------------------

-- Signal counts by stratum, with all diagnostic flags
SELECT stratum,
       count(*)                                          AS pairs,
       count(*) FILTER (WHERE is_prr_signal)             AS prr_signals,
       count(*) FILTER (WHERE is_ror_signal)             AS ror_signals,
       count(*) FILTER (WHERE is_ic_signal)              AS ic_signals,
       count(*) FILTER (WHERE has_zero_cell)             AS zero_cell,
       count(*) FILTER (WHERE is_sparse_background)      AS sparse_background,
       count(*) FILTER (WHERE is_likely_indication_artifact) AS indication_artifacts,
       count(*) FILTER (WHERE is_review_candidate)       AS review_candidates
FROM public.mart_disproportionality_signals GROUP BY 1 ORDER BY 2 DESC;

-- THE TRIAGE WORKLIST. This is the deliverable.
SELECT ingredient, reaction_pt, case_count, background_count,
       ic025, prr, pct_indication_match
FROM public.mart_disproportionality_signals
WHERE stratum = 'ALL' AND is_review_candidate
ORDER BY ic025 DESC LIMIT 100;

-- Funnel for the writeup: how many pairs survive each filter.
SELECT count(*)                                     AS candidate_pairs,
       count(*) FILTER (WHERE is_ic_signal)         AS ic_signals,
       count(*) FILTER (WHERE is_ic_signal
                          AND NOT (zero_b OR zero_c))    AS minus_zero_cell,
       count(*) FILTER (WHERE is_review_candidate)  AS review_queue
FROM public.mart_disproportionality_signals WHERE stratum = 'ALL';

-- Where the filters actually bite: the top of the ranking, not the bulk.
WITH ranked AS (
  SELECT *, row_number() OVER (ORDER BY ic025 DESC) AS rnk
  FROM public.mart_disproportionality_signals
  WHERE stratum = 'ALL' AND is_ic_signal
)
SELECT count(*) FILTER (WHERE rnk <= 100)                              AS top100,
       count(*) FILTER (WHERE rnk <= 100 AND has_zero_cell)            AS zero_cell,
       count(*) FILTER (WHERE rnk <= 100 AND is_likely_indication_artifact)
                                                                       AS indication,
       count(*) FILTER (WHERE rnk <= 100 AND NOT is_review_candidate)  AS removed
FROM ranked;

-- Confirm the 25% threshold caught the near-miss that 50% let through.
SELECT ingredient, reaction_pt, pct_indication_match,
       is_likely_indication_artifact, is_review_candidate
FROM public.mart_disproportionality_signals
WHERE stratum='ALL' AND ingredient='LANADELUMAB'
  AND reaction_pt='HEREDITARY ANGIOEDEMA';

-- How much of the PRR axis is clipped for display.
SELECT count(*) FILTER (WHERE prr_capped) AS capped,
       count(*)                           AS total,
       round(100.0*count(*) FILTER (WHERE prr_capped)/count(*), 1) AS pct_capped
FROM public.mart_disproportionality_signals
WHERE stratum='ALL' AND is_review_candidate;

--------------------------------------------------------------------------- */
