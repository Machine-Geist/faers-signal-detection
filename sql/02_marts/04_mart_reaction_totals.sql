/* ============================================================================
   04 — mart_reaction_totals
   ============================================================================
   PURPOSE   Cases reporting each MedDRA Preferred Term.
             This is the (a + c) column marginal of the contingency table.
   GRAIN     One row per (stratum, reaction_pt).
   DEPENDS   stg_reac, mart_case_strata
   FEEDS     06_mart_disproportionality_signals

   THE UNIVERSE JOIN
   Joining mart_case_strata restricts this to the same universe the drug
   totals use. Counting every case with a reaction, including those with no
   primary-suspect drug, would inflate c — those cases can never appear in
   any drug's `a` cell. That raises the background rate c/(c+d) and biases
   every PRR downward.
   
   
   PT NORMALIZATION — COUPLED EXPRESSION
   upper(btrim(r.pt)) also appears in 05_mart_drug_reaction_counts.sql. The
   two MUST match exactly or the join in 06 silently drops rows. Change one,
   change the other in the same commit.

   =========================================================================== */

DROP MATERIALIZED VIEW IF EXISTS public.mart_reaction_totals CASCADE;

CREATE MATERIALIZED VIEW public.mart_reaction_totals AS
SELECT cs.stratum,
       upper(btrim(r.pt))        AS reaction_pt,
       count(DISTINCT cs.caseid) AS reaction_total
FROM public.stg_reac r
JOIN public.mart_case_strata cs
  ON cs.primaryid = r.primaryid
WHERE btrim(coalesce(r.pt, '')) <> ''
GROUP BY cs.stratum, upper(btrim(r.pt));

CREATE UNIQUE INDEX mart_reaction_totals_pk
    ON public.mart_reaction_totals (stratum, reaction_pt);

/* VERIFY -------------------------------------------------------------------
SELECT reaction_pt, reaction_total
FROM public.mart_reaction_totals WHERE stratum = 'ALL'
ORDER BY reaction_total DESC LIMIT 25;

-- Did normalization actually collapse anything? Non-zero means raw PT had
-- case or whitespace variants.
SELECT count(DISTINCT pt)                 AS raw_pt,
       count(DISTINCT upper(btrim(pt)))   AS normalized_pt
FROM public.stg_reac;
--------------------------------------------------------------------------- */
