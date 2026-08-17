/* ============================================================================
   03 — mart_drug_totals
   ============================================================================
   PURPOSE   Cases mentioning each ingredient as primary suspect.
             This is the (a + b) row marginal of the contingency table.
   GRAIN     One row per (stratum, ingredient).
   DEPENDS   stg_drug_ingredient, mart_case_strata
   FEEDS     06_mart_disproportionality_signals

   RATIONALE
     - Keys on `ingredient` (normalized, combination products split) rather
       than raw `drugname`. This recovers statistical power lost to
       name fragmentation.
     - Inner-joins mart_case_strata, so it counts only eligible cases (those
       with a PS drug and a reaction).
     - Carries a stratum dimension.

   count(DISTINCT i.caseid) is required, not stylistic: one ingredient can
   appear more than once in a case via multiple combination products.
   count(*) would double-count those.
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_drug_totals CASCADE;

CREATE MATERIALIZED VIEW public.mart_drug_totals AS
SELECT cs.stratum,
       i.ingredient,
       count(DISTINCT i.caseid) AS drug_total
FROM public.stg_drug_ingredient i
JOIN public.mart_case_strata cs
  ON cs.caseid = i.caseid
WHERE i.role_cod = 'PS'
GROUP BY cs.stratum, i.ingredient;

CREATE UNIQUE INDEX mart_drug_totals_pk
    ON public.mart_drug_totals (stratum, ingredient);

/* VERIFY -------------------------------------------------------------------
-- Top ingredients in the baseline stratum. For 2025Q4-2026Q1 Dupilumab should
   lead.

SELECT ingredient, drug_total
FROM public.mart_drug_totals WHERE stratum = 'ALL'
ORDER BY drug_total DESC LIMIT 25;

-- No drug total may exceed its stratum's N.
SELECT d.stratum, count(*) AS impossible
FROM public.mart_drug_totals d
JOIN public.mart_stratum_totals s USING (stratum)
WHERE d.drug_total > s.n_cases
GROUP BY 1;
--------------------------------------------------------------------------- */
