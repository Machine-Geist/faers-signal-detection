/* ============================================================================
   05 — mart_drug_reaction_counts
   ============================================================================
   PURPOSE   Co-occurrence count of each ingredient with each reaction.
             This is the `a` cell of the contingency table.
   GRAIN     One row per (stratum, ingredient, reaction_pt).
   DEPENDS   stg_drug_ingredient, stg_reac, mart_case_strata
   FEEDS     06_mart_disproportionality_signals

   POTENTIAL FAN-OUT
   Joining drugs and reactions on the same case produces a cross product:
   a case with 20 ingredients and 30 reactions yields 600 intermediate rows,
   then multiplies again by the number of strata the case belongs to.
   count(DISTINCT i.caseid) collapses this correctly — count(*) would return
   a plausible-looking number wrong by a factor of 20 or more, with nothing
   to flag it.



   NO MINIMUM pair_count FILTER — DELIBERATE
   A minimum count here would conflate two different things: a computational
   filter (which pairs to evaluate) and a signal criterion (which evaluated
   pairs qualify). Evans' a >= 3 rule is the latter, and lives in 06 as part
   of is_prr_signal.

   It matters because IC025 exists precisely to handle low counts through
   Bayesian shrinkage. Filtering them out here would discard the region where
   IC025 differs most from PRR — which is the comparison worth reporting.
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_drug_reaction_counts CASCADE;

CREATE MATERIALIZED VIEW public.mart_drug_reaction_counts AS
SELECT cs.stratum,
       i.ingredient,
       upper(btrim(r.pt))       AS reaction_pt,   -- must match file 04
       count(DISTINCT i.caseid) AS pair_count
FROM public.stg_drug_ingredient i
JOIN public.mart_case_strata cs
  ON cs.caseid = i.caseid
JOIN public.stg_reac r
  ON r.primaryid = i.primaryid
WHERE i.role_cod = 'PS'
  AND btrim(coalesce(r.pt, '')) <> ''
GROUP BY cs.stratum, i.ingredient, upper(btrim(r.pt));

CREATE UNIQUE INDEX mart_drug_reaction_counts_pk
    ON public.mart_drug_reaction_counts (stratum, ingredient, reaction_pt);

/* VERIFY -------------------------------------------------------------------
-- Row volume by stratum. 
SELECT stratum, count(*) AS pairs,
       count(*) FILTER (WHERE pair_count >= 3) AS pairs_ge3
FROM public.mart_drug_reaction_counts GROUP BY 1 ORDER BY 2 DESC;

-- A pair count can never exceed either marginal.
SELECT count(*) AS impossible
FROM public.mart_drug_reaction_counts p
JOIN public.mart_drug_totals d     USING (stratum, ingredient)
JOIN public.mart_reaction_totals t USING (stratum, reaction_pt)
WHERE p.pair_count > d.drug_total OR p.pair_count > t.reaction_total;
--------------------------------------------------------------------------- */
