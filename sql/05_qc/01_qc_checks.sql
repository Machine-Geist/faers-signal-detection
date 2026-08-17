/* ============================================================================
   01 — QC checks
   ============================================================================
   PURPOSE   Assertions over the built pipeline. Run after every build and
             every refresh.
   DEPENDS   mart_disproportionality_signals, mart_drug_totals,
             mart_reaction_totals, mart_stratum_totals,
             mart_drug_reaction_counts, mart_case_strata, stg_demo_latest

   Checks  1-6   cross-mart reconciliation and structural impossibilities.
                 Returned as ONE table, one row per check. Every violations
                 count must be zero.
   Checks  7-9   grain and containment. Each returns its own result set;
                 pass criteria stated at each.
   Checks 10-11  analysis outputs, not assertions. No pass/fail.

   A pipeline without assertions is a pipeline whose bugs surface months
   later, in a chart, with no way to tell when they started.

   WHY THESE CHECKS AND NOT OTHERS
   An assertion is only worth writing if it can fail. Reconstructing b, c, and
   d from the stored marginals and confirming they sum to N proves nothing --
   they are DERIVED from those marginals, so the identity holds algebraically
   whatever the data says. The checks below compare each stored value against
   the mart it was sourced from, which is a claim that can actually be false.
============================================================================ */


/* ---------------------------------------------------------------------------
   CHECKS 1-6 — every violations count must be ZERO
   ---------------------------------------------------------------------------
   One statement, one result table. A full pass is a single glance.
   --------------------------------------------------------------------------- */

SELECT '1. drug_total disagrees with mart_drug_totals' AS check_name,
       count(*) AS violations
FROM public.mart_disproportionality_signals s
JOIN public.mart_drug_totals d
  ON d.stratum = s.stratum AND d.ingredient = s.ingredient
WHERE s.drug_total <> d.drug_total

UNION ALL
SELECT '2. reaction_total disagrees with mart_reaction_totals',
       count(*)
FROM public.mart_disproportionality_signals s
JOIN public.mart_reaction_totals r
  ON r.stratum = s.stratum AND r.reaction_pt = s.reaction_pt
WHERE s.reaction_total <> r.reaction_total

UNION ALL
SELECT '3. n_cases_in_stratum disagrees with mart_stratum_totals',
       count(*)
FROM public.mart_disproportionality_signals s
JOIN public.mart_stratum_totals t
  ON t.stratum = s.stratum
WHERE s.n_cases_in_stratum <> t.n_cases

UNION ALL
/* Negative d means the marginals exceed N -- the drug and reaction marts are
   drawing from different populations. This is the failure the shared universe
   in mart_case_strata exists to prevent. */
SELECT '4. negative d cell',
       count(*)
FROM public.mart_disproportionality_signals
WHERE n_cases_in_stratum - drug_total - reaction_total + case_count < 0

UNION ALL
/* A pair count cannot exceed either marginal. Catches fan-out in the
   drug x reaction join. */
SELECT '5. pair count exceeds a marginal',
       count(*)
FROM public.mart_disproportionality_signals
WHERE case_count > drug_total OR case_count > reaction_total

UNION ALL
/* Every candidate pair must survive into the signals mart. A shortfall means
   a join in 06 is dropping rows -- most likely the PT normalization
   expression drifting out of sync between marts 04 and 05.

   abs() because a difference in EITHER direction is a failure: more signals
   than candidate pairs would mean 06 is fanning out. */
SELECT '6. row count differs between 05 and 06',
       abs( (SELECT count(*) FROM public.mart_drug_reaction_counts)
          - (SELECT count(*) FROM public.mart_disproportionality_signals) );


/* ---------------------------------------------------------------------------
   CHECK 7 — subset strata cannot exceed ALL
   ---------------------------------------------------------------------------
   PASS: zero rows returned.
   --------------------------------------------------------------------------- */
SELECT '7. stratum larger than ALL' AS check_name, stratum, n_cases
FROM public.mart_stratum_totals
WHERE n_cases > (SELECT n_cases FROM public.mart_stratum_totals
                 WHERE stratum = 'ALL');


/* ---------------------------------------------------------------------------
   CHECK 8 — deduplication must be exact
   ---------------------------------------------------------------------------
   PASS: all three counts equal.

   This duplicates the UNIQUE index assertion in 02_stg_demo_latest.sql
   deliberately. That index fails at BUILD time; this check fails at ANY time,
   including after a refresh that ran out of order.
   --------------------------------------------------------------------------- */
SELECT '8. dedup grain' AS check_name,
       count(*)                  AS rows,
       count(DISTINCT caseid)    AS distinct_caseid,
       count(DISTINCT primaryid) AS distinct_primaryid
FROM public.stg_demo_latest;


/* ---------------------------------------------------------------------------
   CHECK 9 — no orphan cases in any stratum
   ---------------------------------------------------------------------------
   PASS: violations = 0. A non-zero count means mart_case_strata references
   cases absent from the deduplicated master, i.e. stg_demo_latest was
   refreshed after its dependants.
   --------------------------------------------------------------------------- */
SELECT '9. orphan stratum cases' AS check_name, count(*) AS violations
FROM public.mart_case_strata cs
WHERE NOT EXISTS (SELECT 1 FROM public.stg_demo_latest dl
                  WHERE dl.caseid = cs.caseid);


/* ---------------------------------------------------------------------------
   10. SHRINKAGE PROFILE — a result, not a pass/fail
   ---------------------------------------------------------------------------
   Where the three methods disagree, as a function of case count. Measured on
   2025Q4-2026Q1, ALL stratum.

     bucket   cases    pairs     PRR      ROR     IC025
        1      1-10  490,005   61,334   60,934   44,932
        2     11-20   19,431   11,807   12,767   11,993
       11      100+    2,624    1,909    2,256    2,238

   TWO FINDINGS, AND THEY ARE ABOUT DIFFERENT THINGS

   1. IC025 REDISTRIBUTES SENSITIVITY, IT IS NOT UNIFORMLY STRICTER.
      In the 1-10 bucket -- 490,005 pairs, 94% of the total -- PRR flags 37%
      more than IC025. From bucket 2 upward, IC025 flags more than PRR at
      every case count. The Bayesian penalty moves sensitivity out of the
      region where one additional report swings the ratio and into the region
      where the data can carry the claim.

   2. AN UNCERTAINTY ESTIMATE IS NOT WHAT SEPARATES THEM.
      ROR has a proper 95% confidence interval and still flags 60,934 pairs
      at 1-10 cases -- within 1% of PRR. Above bucket 1 it is the MOST
      permissive of the three. So the difference is not whether a method
      quantifies uncertainty; it is how hard it penalizes. IC025's
      3.3(a+0.5)^-0.5 term is a far higher bar at small `a` than "CI lower
      bound above 1".

   WHY ROR CAN BE THIS PERMISSIVE AND STILL RANK WELL
   ROR flags almost the same pairs as PRR yet scores AUC 0.768 against PRR's
   0.595. Those coexist because thresholding and ranking are different
   problems. AUC measures ordering across the whole score range, and
   ror_ci_lower is a well-behaved ordering statistic. Raw PRR is not -- it
   explodes into the hundreds of thousands on near-empty backgrounds,
   scattering true and false positives together at the top of the ranking.

   PRR's failure is as a RANKING metric. IC025's advantage over ROR is as a
   THRESHOLD. This table is what separates the two claims; neither is visible
   from the AUC figures alone.

   Note bucket 11 is the overflow bucket: width_bucket's upper bound is
   exclusive, so a case_count of exactly 100 lands there rather than in
   bucket 10.
   --------------------------------------------------------------------------- */

SELECT width_bucket(case_count, 1, 100, 10) AS bucket,
       CASE WHEN width_bucket(case_count, 1, 100, 10) = 11
            THEN '100+'
            ELSE min(case_count) || '-' || max(case_count)
       END                                   AS count_range,
       count(*)                              AS pairs,
       count(*) FILTER (WHERE is_prr_signal) AS prr_flagged,
       count(*) FILTER (WHERE is_ror_signal) AS ror_flagged,
       count(*) FILTER (WHERE is_ic_signal)  AS ic_flagged
FROM public.mart_disproportionality_signals
WHERE stratum = 'ALL'
GROUP BY 1 ORDER BY 1;


/* ---------------------------------------------------------------------------
   11. STRATUM COMPARISON — a result, not a pass/fail
   ---------------------------------------------------------------------------
   Which signals survive when the periodic reporting channel is removed.

     Top of the list     signals that STRENGTHEN once periodic volume is
                         removed; candidate unmasked signals, and the more
                         interesting output.
     Bottom of the list  signals that WEAKEN under expedited-only reporting;
                         candidate solicited-reporting artifacts.

   Ranked on IC025, not PRR. PRR is uncapped and spans five orders of
   magnitude, so a PRR delta is dominated by whichever pair happens to have
   the emptiest background -- the exact behavior that makes PRR unusable for
   ranking anywhere else in this project. IC025 is bounded and shrunk.

   Pairs ABSENT from EXPEDITED are excluded rather than coalesced to zero.
   Absent means the pair had no expedited cases at all, which is missing data,
   not a collapsed signal. Merging the two makes the ranking meaningless.
   The companion query below returns that set separately.
   --------------------------------------------------------------------------- */
SELECT a.ingredient, a.reaction_pt,
       a.case_count AS n_all,  a.ic025 AS ic025_all,  a.prr AS prr_all,
       e.case_count AS n_exp,  e.ic025 AS ic025_exp,  e.prr AS prr_exp,
       ROUND(e.ic025 - a.ic025, 3) AS ic025_delta,
       a.pct_indication_match
FROM public.mart_disproportionality_signals a
JOIN public.mart_disproportionality_signals e
  ON e.ingredient  = a.ingredient
 AND e.reaction_pt = a.reaction_pt
 AND e.stratum     = 'EXPEDITED'
WHERE a.stratum = 'ALL'
  AND a.is_ic_signal
  AND a.case_count >= 5
ORDER BY ic025_delta DESC;

/* 11b. Companion: signals present in ALL with NO expedited cases at all.
   Not the same as weakening -- there is no expedited reporting to compare. */
-- SELECT a.ingredient, a.reaction_pt, a.case_count, a.ic025
-- FROM public.mart_disproportionality_signals a
-- WHERE a.stratum = 'ALL' AND a.is_ic_signal AND a.case_count >= 5
--   AND NOT EXISTS (
--       SELECT 1 FROM public.mart_disproportionality_signals e
--       WHERE e.stratum = 'EXPEDITED'
--         AND e.ingredient = a.ingredient
--         AND e.reaction_pt = a.reaction_pt)
-- ORDER BY a.ic025 DESC;
