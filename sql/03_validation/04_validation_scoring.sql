/* ============================================================================
   04 — Validation scoring   
   ============================================================================
   Scores mart_validation_signals against the OMOP reference set.
   Produces: confusion matrix, sensitivity/specificity/PPV, ROC sweep, AUC.

   Provenance lives in omop_reference_set itself, so no intermediate
   ref_validation_set table is needed -- the base view joins straight through
   the two maps.

   ** ABSENT PAIRS COUNT AS NEGATIVE PREDICTIONS **
   mart_validation_signals carries a=0 rows wherever both marginals exist in
   the stratum, so the inner join below is safe for the ALL-stratum metrics
   in queries 1-5. It is NOT safe to compare raw counts across strata: pairs
   whose marginals go to zero in a narrower stratum are absent rather than
   zero. Section 6 handles that with the matched-pair filter.
============================================================================ */

/* ============================================================================
   RESULTS  —  measured on 2025Q4-2026Q1
   ============================================================================
   Reproduce with the queries below. Recorded here so the file states what it
   found, not only how to find it.

   Two denominators are used and they are not interchangeable:
     - Classification metrics run on the full scored set (308 pairs at ALL).
     - Cross-stratum AUC runs on the MATCHED set (261 pairs: 114 positive,
       147 negative) -- pairs present in all four strata. See section 6.

   ---------------------------------------------------------------------------
   DISCRIMINATION (AUC, matched pair set, n = 114 pos / 147 neg)
   ---------------------------------------------------------------------------
                      BROAD TIER                NARROW TIER
     stratum      IC025    ROR    PRR       IC025    ROR    PRR
     ALL          0.812   0.768  0.595      0.787   0.740  0.576
     NO_MASK_DRUG 0.811   0.768  0.593      0.787   0.740  0.574
     EXPEDITED    0.782   0.714  0.504      0.756   0.675  0.478
     SERIOUS      0.779   0.704  0.493      0.730   0.681  0.480

   IC025 > ROR > PRR in all sixteen stratum x tier combinations. A method
   ordering that holds under every slice is a stronger result than one
   measured once.

   PRR is barely better than chance at baseline (0.595) and reaches it under
   stratification (0.504, 0.493). The Bayesian shrinkage that makes IC025
   conservative on sparse pairs is what makes it rank well; PRR's sensitivity
   to a near-empty background scatters true and false positives together at
   the top of the ranking.

   Tier stability: narrow scores 0.02-0.03 below broad on every method, with
   ordering unchanged. The hand-built outcome-group definition is not driving
   the result -- which matters, because those groupings are judgment calls
   made without MedDRA SMQ access (see 01_ref_outcome_groups.sql).

   ---------------------------------------------------------------------------
   CLASSIFICATION AT THE DEFAULT THRESHOLD (IC025 > 0, ALL, broad tier)
   ---------------------------------------------------------------------------
     True positives    45        Sensitivity   34%
     False positives    2        Precision     96%
     True negatives   175        Specificity   99%
     False negatives   86

   Highly specific, deliberately insensitive: when it fires it is almost
   always right, and it stays silent on two thirds of known positives. For
   triage this is the right side of the trade -- the output is a review queue
   and a queue that is 96% real is usable while a queue at 50%
   is not. Query 4 separates power failures (missed at low report volume)
   from method failures (missed at high volume).

   ---------------------------------------------------------------------------
   BOTH FALSE POSITIVES ARE CONFOUNDING BY INDICATION
   ---------------------------------------------------------------------------
     darbepoetin alfa / AKI    a=17  drug_total=374  IC025 0.24
     entecavir / AKI           a=10  drug_total= 68  IC025 1.36

   Neither is a failure of the disproportionality math. Both are drugs whose
   treated population has renal disease for reasons unrelated to the drug.

   DARBEPOETIN ALFA is an erythropoiesis-stimulating agent indicated for
   anaemia of chronic kidney disease. The exposed population is renally
   impaired by definition, so renal PTs co-occur with it at a rate that has
   nothing to do with toxicity. mart_indication_match does NOT flag this: the
   coded indication is ANAEMIA or CHRONIC KIDNEY DISEASE while the flagged
   reaction is RENAL IMPAIRMENT -- clinically the same context, different
   MedDRA PTs. This is the exact lower-bound limitation documented in 05a,
   demonstrated on a labeled negative control.

   ENTECAVIR is renally eliminated and requires dose adjustment in renal
   impairment, so renal function is monitored and documented in this
   population. Whether entecavir is causally nephrotoxic is not settled in
   the literature, which makes this a candidate for reference-set
   misclassification rather than a clean method failure (see caveat below).

   Neither is an artifact of the broad tier. Entecavir's 10 cases are mostly
   ACUTE KIDNEY INJURY (4) and RENAL IMPAIRMENT (4), both narrow-tier
   clinical diagnoses; only 2 come from lab PTs.

   AGGREGATION CUTS BOTH WAYS
   At PT level, 2 of entecavir's 4 renal PTs individually exceed IC025 > 0
   (0.72, 0.31); aggregating to the outcome group raises the signal to 1.36.
   For darbepoetin the opposite happens: its strongest single PT is RENAL
   IMPAIRMENT at 0.995, and aggregation pulls the pair down to 0.24 -- still
   over threshold, but weaker. Pooling raises the numerator and the outcome
   marginal together, so it is not a one-directional inflation. Aggregating
   before computing disproportionality remains the correct choice (see 
   03_mart_validation_signals.sql), but it changes which pairs cross the line, 
   and in both directions.

   ---------------------------------------------------------------------------
   STRATIFICATION: DISCONFIRMED
   ---------------------------------------------------------------------------
   Neither restricting to expedited reports nor to serious outcomes improved
   discrimination. On the matched pair set, IC025 AUC FELL from 0.812 at ALL
   to 0.782 (EXPEDITED) and 0.779 (SERIOUS).

   The hypothesis was reasonable: expedited reports exclude the periodic
   channel that carries solicited, already-labeled events, so filtering to
   them should sharpen the signal. The data says the loss of sample size
   outweighs the gain in report quality. PRR degrades worst under
   stratification, falling to chance -- it is the least robust method to
   reduced n as well as the weakest overall.

   MASKING: ALSO DISCONFIRMED
   NO_MASK_DRUG excludes every case mentioning dupilumab, the single highest-
   volume ingredient at ~7.8% of PS cases. AUC moved by 0.001 (0.812 ->
   0.811). Competition bias from one dominant reporter is not measurably
   distorting discrimination at this scale.

   Both strata remain in the pipeline. The negative results are part of the
   finding, and removing the strata would remove the evidence for them.

   ---------------------------------------------------------------------------
   REFERENCE-SET CAVEAT
   ---------------------------------------------------------------------------
   These figures are measured against a gold standard with a documented
   accuracy problem. Roughly 17% of the OMOP negative controls have been
   found misclassified or potentially misclassified (Hauben et al., Drug
   Safety 2016). Some of what is scored here as a false positive may be a
   real association mislabeled as a negative control, so 0.812 is more likely
   an underestimate than an overestimate.
============================================================================ */

CREATE OR REPLACE VIEW public.v_validation_base AS
SELECT DISTINCT
       r."exposureName"          AS ref_drug,
       om.outcome_group,
       s.tier,
       s.stratum,
       (r."groundTruth" = 1)     AS truth,
       s.case_count,
       s.drug_total,
       s.prr,
       s.ror_ci_lower,
       s.ic025,
       s.is_prr_signal,
       s.is_ror_signal,
       s.is_ic_signal
FROM public.omop_reference_set r
JOIN public.ref_outcome_map om
  ON om.omop_outcome_name = r."outcomeName"
JOIN public.mart_validation_signals s
  ON s.ref_drug      = r."exposureName"
 AND s.outcome_group = om.outcome_group;

/* DISTINCT because omop_reference_set can list the same (drug, outcome) more
   than once across comparator rows. Check for genuine label conflicts: */
-- SELECT ref_drug, outcome_group, count(DISTINCT truth)
-- FROM public.v_validation_base GROUP BY 1,2 HAVING count(DISTINCT truth) > 1;


/* --- 1. Confusion matrix and metrics, per method and tier ---------------
   TP flagged and truly positive | FP flagged but a negative control
   FN missed a positive          | TN correctly silent on a negative
   ---------------------------------------------------------------------- */
-- WITH m AS (
--   SELECT tier,'PRR (Evans)' AS method, truth, is_prr_signal AS flagged
--     FROM public.v_validation_base WHERE stratum='ALL'
--   UNION ALL SELECT tier,'ROR (CI>1)', truth, is_ror_signal
--     FROM public.v_validation_base WHERE stratum='ALL'
--   UNION ALL SELECT tier,'IC025 (>0)', truth, is_ic_signal
--     FROM public.v_validation_base WHERE stratum='ALL'
-- ), cm AS (
--   SELECT tier, method,
--          count(*) FILTER (WHERE truth AND flagged)         AS tp,
--          count(*) FILTER (WHERE NOT truth AND flagged)     AS fp,
--          count(*) FILTER (WHERE truth AND NOT flagged)     AS fn,
--          count(*) FILTER (WHERE NOT truth AND NOT flagged) AS tn
--   FROM m GROUP BY 1,2
-- )
-- SELECT tier, method, tp, fp, fn, tn,
--        ROUND(100.0*tp/NULLIF(tp+fn,0),1) AS sensitivity_pct,
--        ROUND(100.0*tn/NULLIF(tn+fp,0),1) AS specificity_pct,
--        ROUND(100.0*tp/NULLIF(tp+fp,0),1) AS ppv_pct,
--        ROUND(2.0*tp/NULLIF(2*tp+fp+fn,0),3) AS f1
-- FROM cm ORDER BY tier, method;


/* --- 2. AUC via the Mann-Whitney identity ------------------------------
   AUC = P(random positive scores above random negative)
       = (sum of positive ranks - n_pos(n_pos+1)/2) / (n_pos * n_neg)
   rank() averages ties, which is the correct treatment.
   0.5 = no discrimination. This is the headline number.
   ---------------------------------------------------------------------- */
-- WITH scored AS (
--   SELECT tier,'IC025' AS method, truth, COALESCE(ic025,-99) AS score
--     FROM public.v_validation_base WHERE stratum='ALL'
--   UNION ALL SELECT tier,'PRR', truth, COALESCE(prr,0)
--     FROM public.v_validation_base WHERE stratum='ALL'
--   UNION ALL SELECT tier,'ROR_CI_lower', truth, COALESCE(ror_ci_lower,0)
--     FROM public.v_validation_base WHERE stratum='ALL'
-- ), ranked AS (
--   SELECT tier, method, truth,
--          rank() OVER (PARTITION BY tier, method ORDER BY score) AS rnk
--   FROM scored
-- )
-- SELECT tier, method,
--        count(*) FILTER (WHERE truth)     AS n_pos,
--        count(*) FILTER (WHERE NOT truth) AS n_neg,
--        ROUND((sum(rnk) FILTER (WHERE truth)
--               - (count(*) FILTER (WHERE truth)
--                  * (count(*) FILTER (WHERE truth) + 1))/2.0)
--              / NULLIF(count(*) FILTER (WHERE truth)
--                       * count(*) FILTER (WHERE NOT truth),0), 3) AS auc
-- FROM ranked GROUP BY 1,2 ORDER BY tier, auc DESC;


/* --- 3. ROC sweep on IC025 (plot sensitivity vs 100 - specificity) ------ */
-- WITH t AS (SELECT generate_series(-3.0, 6.0, 0.25) AS thr)
-- SELECT t.thr,
--        ROUND(100.0*count(*) FILTER (WHERE b.truth AND b.ic025 >= t.thr)
--              / NULLIF(count(*) FILTER (WHERE b.truth),0),1)      AS sensitivity_pct,
--        ROUND(100.0*count(*) FILTER (WHERE NOT b.truth AND b.ic025 < t.thr)
--              / NULLIF(count(*) FILTER (WHERE NOT b.truth),0),1)  AS specificity_pct
-- FROM t CROSS JOIN public.v_validation_base b
-- WHERE b.stratum='ALL' AND b.tier='narrow'
-- GROUP BY t.thr ORDER BY t.thr;


/* --- 4. Missed positives: power failure or method failure? --------------
   The most instructive output. A positive missed on a drug with 40 reports
   is a power problem. Missed at 2,000 reports is a method problem.
   ---------------------------------------------------------------------- */
-- SELECT ref_drug, outcome_group, case_count, drug_total, prr, ic025
-- FROM public.v_validation_base
-- WHERE stratum='ALL' AND tier='narrow' AND truth AND NOT is_ic_signal
-- ORDER BY drug_total DESC;

/* --- 5. False positives: which negative controls fired, and why? -------- */
-- SELECT ref_drug, outcome_group, case_count, drug_total, prr, ic025
-- FROM public.v_validation_base
-- WHERE stratum='ALL' AND tier='narrow' AND NOT truth AND is_ic_signal
-- ORDER BY ic025 DESC;

/* --- 6. Does stratification improve discrimination? ----------------------
   The payoff for building four strata: a measured answer rather than an
   argument. If EXPEDITED or SERIOUS beats ALL, stratification earns its
   place.

   ** THE STRATA DO NOT SHARE A PAIR SET -- USE 6b, NOT 6a **
   mart_validation_signals builds its grid from observed marginals, so a
   reference drug with no eligible cases in a stratum drops out of that
   stratum entirely rather than scoring a=0 (see the header of 03). EXPEDITED
   and SERIOUS are fractions of ALL, so they lose low-volume pairs -- often
   the hardest ones. Comparing raw per-stratum AUC therefore compares
   different problems, and a stratum that quietly shed its difficult pairs
   posts a better number for a reason that has nothing to do with
   discrimination.

   6a below is the naive version, kept to show the artifact. 6b restricts to
   pairs present in all four strata and is the result that counts.

   RESULT: on the matched pair set, AUC FELL relative to ALL. Stratification
   is disconfirmed. For IC025, ALL AUC 0.812, EXPEDITED 0.782, SERIOUS
   0.779.
   ------------------------------------------------------------------------ */


/* --- 6a. NAIVE per-stratum AUC -- NOT COMPARABLE ACROSS STRATA -----------
   Each stratum scored on whatever pairs survived in it. Reported only to
   demonstrate the bias that 6b corrects.
   ------------------------------------------------------------------------ */
-- WITH scored AS (
--   SELECT stratum, tier, 'IC025' AS method, truth,
--          COALESCE(ic025, -99) AS score FROM public.v_validation_base
--   UNION ALL
--   SELECT stratum, tier, 'PRR', truth, COALESCE(prr, 0)
--     FROM public.v_validation_base
--   UNION ALL
--   SELECT stratum, tier, 'ROR_CI_lower', truth, COALESCE(ror_ci_lower, 0)
--     FROM public.v_validation_base
-- ), ranked AS (
--   SELECT stratum, tier, method, truth,
--          rank() OVER (PARTITION BY stratum, tier, method ORDER BY score) AS rnk
--   FROM scored
-- )
-- SELECT stratum, tier, method,
--        count(*) FILTER (WHERE truth)     AS n_pos,
--        count(*) FILTER (WHERE NOT truth) AS n_neg,
--        ROUND( (sum(rnk) FILTER (WHERE truth)
--                - (count(*) FILTER (WHERE truth)
--                   * (count(*) FILTER (WHERE truth) + 1)) / 2.0)
--               / NULLIF(count(*) FILTER (WHERE truth)
--                        * count(*) FILTER (WHERE NOT truth), 0), 3) AS auc
-- FROM ranked GROUP BY 1,2,3 ORDER BY tier, method, auc DESC;


/* --- 6b. MATCHED-PAIR AUC -- THE RESULT THAT COUNTS ----------------------
   Restricted to (ref_drug, outcome_group) combinations present in all four
   strata, so every stratum is scored on identical ground. Compare n_pos and
   n_neg against 6a to see how many pairs the naive version was silently
   dropping.
   ------------------------------------------------------------------------ */
-- WITH common AS (
--   SELECT * FROM public.v_validation_base
--   WHERE (ref_drug, outcome_group) IN (
--       SELECT ref_drug, outcome_group FROM public.v_validation_base
--       GROUP BY 1,2 HAVING count(DISTINCT stratum) = 4
--   )
-- ), scored AS (
--   SELECT stratum, tier, 'IC025' AS method, truth,
--          COALESCE(ic025, -99) AS score           FROM common
--   UNION ALL SELECT stratum, tier, 'PRR', truth, COALESCE(prr, 0) FROM common
--   UNION ALL SELECT stratum, tier, 'ROR_CI_lower', truth,
--          COALESCE(ror_ci_lower, 0)               FROM common
-- ), ranked AS (
--   SELECT stratum, tier, method, truth,
--          rank() OVER (PARTITION BY stratum, tier, method ORDER BY score) AS rnk
--   FROM scored
-- )
-- SELECT stratum, tier, method,
--        count(*) FILTER (WHERE truth)     AS n_pos,
--        count(*) FILTER (WHERE NOT truth) AS n_neg,
--        ROUND( (sum(rnk) FILTER (WHERE truth)
--                - (count(*) FILTER (WHERE truth)
--                   * (count(*) FILTER (WHERE truth) + 1)) / 2.0)
--               / NULLIF(count(*) FILTER (WHERE truth)
--                        * count(*) FILTER (WHERE NOT truth), 0), 3) AS auc
-- FROM ranked GROUP BY 1,2,3 ORDER BY tier, method, auc DESC;