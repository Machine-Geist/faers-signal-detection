/* ============================================================================
   01 — Tableau Public export queries
   ============================================================================
   PURPOSE   Produces the flat CSV extracts behind the published dashboard.
   DEPENDS   mart_disproportionality_signals, mart_stratum_totals,
             mart_drug_totals, mart_case_strata, stg_demo_latest,
             stg_drug_ingredient, v_validation_base
   FEEDS     Tableau Public workbook

   Run each query, then in DBeaver right-click the result grid ->
   "Export resultset..." -> CSV. (Postgres COPY TO writes server-side and needs
   superuser or pg_read_server_files membership; the grid export avoids that
   entirely and keeps the repo runnable by anyone who cloned it.)

   ** RUN THEM ALL IN ONE SITTING. ** Every number on the dashboard should come
   from the same snapshot, or the KPI tiles will disagree with the charts.

   Suggested folder: /tableau/data/

   THE UNIVERSE
   Every export below is scoped to the eligible universe defined in
   mart_case_strata -- cases with BOTH a primary-suspect drug AND a reaction.
   Any query that reaches around that filter will produce counts that disagree
   with the rest of the dashboard.
============================================================================ */


/* ---------------------------------------------------------------------------
   1. signals.csv          ~90,000 rows        TAB 1 + TAB 3
   ---------------------------------------------------------------------------
   Every pair flagged by at least one method, ALL stratum only. Restricting to
   one stratum keeps the extract small and the scatter honest -- stratum
   belongs in a filter, not on the same canvas.
   --------------------------------------------------------------------------- */
SELECT ingredient, reaction_pt, case_count, drug_total, reaction_total,
       background_count, expected_count,
       prr, prr_display, prr_capped, ror, ror_ci_lower, ic025, chi_square,
       pct_indication_match,
       is_prr_signal, is_ror_signal, is_ic_signal, n_methods_flagged,
       has_zero_cell, is_sparse_background, is_likely_indication_artifact,
       is_review_candidate
FROM public.mart_disproportionality_signals
WHERE stratum = 'ALL'
  AND (is_ic_signal OR is_prr_signal OR is_ror_signal);


/* ---------------------------------------------------------------------------
   2. funnel.csv           6 rows              TAB 1 KPIs + TAB 3 funnel
   ---------------------------------------------------------------------------
   Attrition from every deduplicated case down to the review queue.

   Stage 0 and stage 1 are DIFFERENT populations and the distinction matters:
   stg_demo_latest is every deduplicated case, while mart_stratum_totals.n_cases
   is the ELIGIBLE universe (PS drug AND reaction). The gap between them is the
   eligibility filter, and showing it is the point of a funnel.
   --------------------------------------------------------------------------- */
SELECT 0 AS stage_order, 'Deduplicated cases' AS stage,
       (SELECT count(*) FROM public.stg_demo_latest) AS n
UNION ALL SELECT 1, 'Eligible cases (PS drug + reaction)',
       (SELECT n_cases FROM public.mart_stratum_totals WHERE stratum='ALL')
UNION ALL SELECT 2, 'Candidate drug-event pairs',
       count(*) FROM public.mart_disproportionality_signals WHERE stratum='ALL'
UNION ALL SELECT 3, 'IC025 signals',
       count(*) FROM public.mart_disproportionality_signals
       WHERE stratum='ALL' AND is_ic_signal
UNION ALL SELECT 4, 'After removing zero-cell artifacts',
       count(*) FROM public.mart_disproportionality_signals
       WHERE stratum='ALL' AND is_ic_signal AND NOT (zero_b OR zero_c)
UNION ALL SELECT 5, 'Review candidates (indication-filtered)',
       count(*) FROM public.mart_disproportionality_signals
       WHERE stratum='ALL' AND is_review_candidate
ORDER BY stage_order;


/* ---------------------------------------------------------------------------
   3. roc.csv              ~1,500 rows         TAB 2 ROC curves
   ---------------------------------------------------------------------------
   One point per distinct observed score, per method per tier. Running
   true/false positive counts down the descending score order are exactly the
   ROC construction.

   RANGE, NOT ROWS -- THIS MATTERS
   ROWS accumulates one row at a time, so tied scores get different cumulative
   counts depending on arbitrary ordering within the tie. RANGE treats tied
   rows as one peer group and gives them all the cumulative total through the
   end of that group, which is the correct treatment and is what makes the
   curve reproducible.

   Ties are not rare here: COALESCE(ic025, -99) collapses every null to one
   score, and PRR piles up at 0. This also matches the tie handling in query 4,
   where rank() averages ties -- the curve and the AUC it implies are computed
   the same way.

   SELECT DISTINCT because tied rows now yield identical points.
   --------------------------------------------------------------------------- */
WITH scored AS (
    SELECT tier,'IC025' AS method, truth, COALESCE(ic025,-99) AS score
      FROM public.v_validation_base WHERE stratum='ALL'
    UNION ALL SELECT tier,'ROR', truth, COALESCE(ror_ci_lower,0)
      FROM public.v_validation_base WHERE stratum='ALL'
    UNION ALL SELECT tier,'PRR', truth, COALESCE(prr,0)
      FROM public.v_validation_base WHERE stratum='ALL'
),
tot AS (
    SELECT tier, method,
           count(*) FILTER (WHERE truth)     AS n_pos,
           count(*) FILTER (WHERE NOT truth) AS n_neg
    FROM scored GROUP BY 1,2
),
running AS (
    SELECT tier, method, score,
           sum(CASE WHEN truth THEN 1 ELSE 0 END)
               OVER (PARTITION BY tier, method ORDER BY score DESC
                     RANGE UNBOUNDED PRECEDING) AS cum_tp,
           sum(CASE WHEN truth THEN 0 ELSE 1 END)
               OVER (PARTITION BY tier, method ORDER BY score DESC
                     RANGE UNBOUNDED PRECEDING) AS cum_fp
    FROM scored
)
SELECT DISTINCT
       r.tier, r.method, r.score,
       ROUND(100.0 * r.cum_tp / t.n_pos, 2)         AS sensitivity_pct,
       ROUND(100.0 * r.cum_fp / t.n_neg, 2)         AS fpr_pct,
       ROUND(100.0 - 100.0 * r.cum_fp / t.n_neg, 2) AS specificity_pct
FROM running r JOIN tot t USING (tier, method)
ORDER BY tier, method, fpr_pct, sensitivity_pct;


/* ---------------------------------------------------------------------------
   4. auc.csv              24 rows             TAB 2 AUC bars
   ---------------------------------------------------------------------------
   Like-for-like: restricted to pairs scored in all four strata (114 pos /
   147 neg). The `common` CTE filters ONCE -- putting a WHERE on the last
   UNION branch only filters that branch, which is a real trap.

   The matched-pair restriction is not optional. mart_validation_signals builds
   its grid from observed marginals, so a reference drug with no eligible cases
   in a stratum vanishes from it rather than scoring a=0. Measured here, 144
   reference drugs appear in ALL but only 129 in EXPEDITED and 130 in SERIOUS.
   Comparing raw per-stratum AUC would compare different problems.
   --------------------------------------------------------------------------- */
WITH common AS (
    SELECT * FROM public.v_validation_base
    WHERE (ref_drug, outcome_group) IN (
        SELECT ref_drug, outcome_group FROM public.v_validation_base
        GROUP BY 1,2 HAVING count(DISTINCT stratum) = 4)
),
scored AS (
    SELECT stratum, tier,'IC025' AS method, truth,
           COALESCE(ic025,-99) AS score                        FROM common
    UNION ALL SELECT stratum, tier,'ROR', truth,
           COALESCE(ror_ci_lower,0)                            FROM common
    UNION ALL SELECT stratum, tier,'PRR', truth,
           COALESCE(prr,0)                                     FROM common
),
ranked AS (
    SELECT stratum, tier, method, truth,
           rank() OVER (PARTITION BY stratum, tier, method ORDER BY score) AS rnk
    FROM scored
)
SELECT stratum, tier, method,
       count(*) FILTER (WHERE truth)     AS n_pos,
       count(*) FILTER (WHERE NOT truth) AS n_neg,
       ROUND((sum(rnk) FILTER (WHERE truth)
              - (count(*) FILTER (WHERE truth)
                 * (count(*) FILTER (WHERE truth)+1))/2.0)
             / NULLIF(count(*) FILTER (WHERE truth)
                      * count(*) FILTER (WHERE NOT truth),0), 3) AS auc
FROM ranked GROUP BY 1,2,3
ORDER BY tier, method, auc DESC;


/* ---------------------------------------------------------------------------
   5. confusion.csv        6 rows              TAB 2 confusion matrix
   --------------------------------------------------------------------------- */
WITH m AS (
    SELECT tier,'IC025' AS method, truth, is_ic_signal AS flagged
      FROM public.v_validation_base WHERE stratum='ALL'
    UNION ALL SELECT tier,'ROR', truth, is_ror_signal
      FROM public.v_validation_base WHERE stratum='ALL'
    UNION ALL SELECT tier,'PRR', truth, is_prr_signal
      FROM public.v_validation_base WHERE stratum='ALL'
)
SELECT tier, method,
       count(*) FILTER (WHERE truth AND flagged)         AS true_positive,
       count(*) FILTER (WHERE NOT truth AND flagged)     AS false_positive,
       count(*) FILTER (WHERE truth AND NOT flagged)     AS false_negative,
       count(*) FILTER (WHERE NOT truth AND NOT flagged) AS true_negative,
       ROUND(100.0*count(*) FILTER (WHERE truth AND flagged)
             / NULLIF(count(*) FILTER (WHERE truth),0),1)      AS sensitivity_pct,
       ROUND(100.0*count(*) FILTER (WHERE NOT truth AND NOT flagged)
             / NULLIF(count(*) FILTER (WHERE NOT truth),0),1)  AS specificity_pct,
       ROUND(100.0*count(*) FILTER (WHERE truth AND flagged)
             / NULLIF(count(*) FILTER (WHERE flagged),0),1)    AS ppv_pct
FROM m GROUP BY 1,2 ORDER BY 1,2;


/* ---------------------------------------------------------------------------
   6. validation_pairs.csv  ~2,500 rows        TAB 2 missed-positives scatter
   ---------------------------------------------------------------------------
   The chart that separates the two failure modes: low drug_total = power
   failure; high drug_total with ic025 < 0 = profile dilution.
   --------------------------------------------------------------------------- */
SELECT ref_drug, outcome_group, tier, stratum,
       CASE WHEN truth THEN 'Positive control'
            ELSE 'Negative control' END AS control_type,
       case_count, drug_total, prr, ror_ci_lower, ic025,
       is_prr_signal, is_ror_signal, is_ic_signal,
       CASE WHEN truth AND is_ic_signal     THEN 'True positive'
            WHEN truth AND NOT is_ic_signal THEN 'Missed (false negative)'
            WHEN NOT truth AND is_ic_signal THEN 'False alarm'
            ELSE 'Correctly ignored' END AS outcome_label
FROM public.v_validation_base;


/* ---------------------------------------------------------------------------
   7. indication_bands.csv  5 rows             TAB 3
   ---------------------------------------------------------------------------
   Mean IC025 per indication-match band, showing whether artifacts cluster at
   the top of the ranking.

   case_count >= 5 is a DISPLAY filter, not an analytical one. pct_indication
   _match is a ratio, so a pair with 1 case is necessarily 0% or 100% and a
   handful of them would dominate the band averages with no information behind
   them. The marts layer deliberately keeps low-count pairs -- IC025 handles
   them through shrinkage -- so this filter applies here and nowhere else.

   Bands are cut at 25% to align with the indication_threshold in
   mart_disproportionality_signals. They differ from the bands in the VERIFY
   block of 05a_mart_indication_match, which are cut at 10% for exploration.
   --------------------------------------------------------------------------- */
SELECT CASE WHEN pct_indication_match >= 90 THEN '90-100%'
            WHEN pct_indication_match >= 50 THEN '50-89%'
            WHEN pct_indication_match >= 25 THEN '25-49%'
            WHEN pct_indication_match >   0 THEN '1-24%'
            ELSE '0%' END AS indication_match_band,
       count(*)            AS signals,
       ROUND(avg(ic025),2) AS mean_ic025,
       sum(case_count)     AS total_cases
FROM public.mart_disproportionality_signals
WHERE stratum = 'ALL' AND is_ic_signal AND case_count >= 5
GROUP BY 1 ORDER BY 1 DESC;


/* ---------------------------------------------------------------------------
   8. reporting_pathway.csv  ~60 rows          TAB 3
   ---------------------------------------------------------------------------
   Dupilumab at 91% periodic beside acetaminophen at 60% expedited is the
   solicited-reporting story in one picture.

   Joins mart_case_strata so these counts sit in the same universe as every
   other export. Without it the totals here would exceed drug_total elsewhere
   on the dashboard for the same ingredient.
   --------------------------------------------------------------------------- */
SELECT i.ingredient,
       dl.rept_cod,
       count(DISTINCT i.caseid) AS cases,
       ROUND(100.0 * count(DISTINCT i.caseid)
             / sum(count(DISTINCT i.caseid)) OVER (PARTITION BY i.ingredient), 1)
           AS pct_of_drug
FROM public.stg_drug_ingredient i
JOIN public.mart_case_strata cs
  ON cs.caseid = i.caseid
 AND cs.stratum = 'ALL'
JOIN public.stg_demo_latest dl
  ON dl.caseid = i.caseid
WHERE i.role_cod = 'PS'
  AND i.ingredient IN (
      SELECT ingredient FROM public.mart_drug_totals
      WHERE stratum = 'ALL' ORDER BY drug_total DESC LIMIT 15)
GROUP BY 1,2
ORDER BY 1,3 DESC;


/* ---------------------------------------------------------------------------
   9. shrinkage_profile.csv  11 rows           TAB 3 (optional)
   ---------------------------------------------------------------------------
   Where PRR and IC025 disagree, as a function of case count. The divergence
   at low counts is the shrinkage penalty doing its job.

   width_bucket sends everything above 100 to bucket 11, so that row spans a
   far wider range than the ten 10-wide buckets below it. Labeled '100+'
   explicitly rather than showing a misleading min-max range.
   --------------------------------------------------------------------------- */
SELECT width_bucket(case_count, 1, 100, 10) AS bucket,
       CASE WHEN width_bucket(case_count, 1, 100, 10) = 11
            THEN '100+'
            ELSE min(case_count) || '-' || max(case_count)
       END                                   AS count_range,
       count(*)                              AS pairs,
       count(*) FILTER (WHERE is_prr_signal) AS prr_flagged,
       count(*) FILTER (WHERE is_ic_signal)  AS ic_flagged
FROM public.mart_disproportionality_signals
WHERE stratum = 'ALL'
GROUP BY 1 ORDER BY 1;


/* ---------------------------------------------------------------------------
   10. stratum_summary.csv   4 rows            TAB 1 KPI context
   --------------------------------------------------------------------------- */
SELECT s.stratum, t.n_cases,
       count(*)                                      AS pairs,
       count(*) FILTER (WHERE s.is_ic_signal)        AS ic_signals,
       count(*) FILTER (WHERE s.is_review_candidate) AS review_candidates
FROM public.mart_disproportionality_signals s
JOIN public.mart_stratum_totals t USING (stratum)
GROUP BY 1,2 ORDER BY 2 DESC;