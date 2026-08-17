/* ============================================================================
   05a — mart_indication_match
   ============================================================================
   PURPOSE   For every drug-reaction pair, what share of the cases behind it
             list that same reaction as the documented INDICATION -- the
             reason the drug was prescribed.
   GRAIN     One row per (stratum, ingredient, reaction_pt).
   DEPENDS   stg_drug_ingredient, stg_reac, stg_indi, mart_case_strata
   FEEDS     06_mart_disproportionality_signals

   ---------------------------------------------------------------------------
   WHY THIS EXISTS
   ---------------------------------------------------------------------------
   Lack of efficacy is a REPORTABLE EVENT in most jurisdictions. When a drug
   fails to control the condition it treats, a case is filed with that
   condition coded as the reaction. Disproportionality math cannot tell this
   apart from a genuine adverse reaction -- the contingency table looks
   identical.

   For 2025Q4-2026Q1: indication artifacts are 2,307 of 70,728 IC025 signals 
   (3.3%) overall, and 5 of the top 100 by IC025 — roughly 1.5× enriched at 
   the top of the ranking, but not dominant there. The dashboard uses the 
   ≥ 5 subset - pct_indication_match is a ratio, so a 1-case pair is 
   necessarily 0% or 100%. The result is the dashboard shows 1,365 signals as
   indication artifacts above the 25 % threshold.

   TWO DISTINCT MECHANISMS, IDENTICAL DATA SIGNATURE
   
     Lack of efficacy      drug treats the condition; patient does not
                           improve (sacituzumab/TNBC, imatinib/CML)
                           
     Co-morbidity          drug does NOT treat the condition, it is the
                           clinical context (oxycodone/rheumatoid arthritis,
                           where oxycodone treats RA pain and the case
                           reports the RA worsening)
                           
   The indication match flag cannot distinguish them.

   ---------------------------------------------------------------------------
   ** THIS IS A LOWER BOUND **
   ---------------------------------------------------------------------------
   Matching is on EXACT MedDRA Preferred Term. Clinically identical concepts
   coded differently are missed -- e.g. antihemophilic factor / HAEMARTHROSIS
   is almost certainly indication confounding, but the indication is coded
   HAEMOPHILIA A, so no match. Catching those needs the MedDRA hierarchy
   (PT -> HLT -> SOC), which is licensed and not used here.

   Indications are matched at CASE level, not drug level. stg_indi links to a
   specific drug via indi_drug_seq, but stg_drug_ingredient does not carry
   drug_seq (it cannot -- the grain changed when prod_ai was split). For
   primary-suspect drugs the case-level indication is usually the PS drug's
   indication, but on polypharmacy cases this can over-attribute.
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_indication_match CASCADE;

CREATE MATERIALIZED VIEW public.mart_indication_match AS

/* Deduplicated indication set. Built as its own CTE rather than a correlated
   EXISTS: one hash join beats a per-row subquery across tens of millions of
   candidate rows. */
WITH indi AS (
    SELECT DISTINCT
           primaryid,
           upper(btrim(indi_pt)) AS indi_pt
    FROM public.stg_indi
    WHERE btrim(coalesce(indi_pt, '')) <> ''
),

/* Same fan-out as mart_drug_reaction_counts: ingredients x reactions x
   strata per case. count(DISTINCT caseid) collapses it correctly. */
pair_cases AS (
    SELECT cs.stratum,
           i.ingredient,
           upper(btrim(r.pt)) AS reaction_pt,
           i.caseid,
           (ind.primaryid IS NOT NULL) AS indication_matches
    FROM public.stg_drug_ingredient i
    JOIN public.mart_case_strata cs
      ON cs.caseid = i.caseid
    JOIN public.stg_reac r
      ON r.primaryid = i.primaryid
    LEFT JOIN indi ind
      ON ind.primaryid = i.primaryid
     AND ind.indi_pt   = upper(btrim(r.pt))
    WHERE i.role_cod = 'PS'
      AND btrim(coalesce(r.pt, '')) <> ''
)

SELECT stratum,
       ingredient,
       reaction_pt,
       count(DISTINCT caseid)                                  AS pair_cases,
       count(DISTINCT caseid) FILTER (WHERE indication_matches) AS indication_cases,
       ROUND(100.0 * count(DISTINCT caseid) FILTER (WHERE indication_matches)
             / NULLIF(count(DISTINCT caseid), 0), 1)           AS pct_indication_match
FROM pair_cases
GROUP BY stratum, ingredient, reaction_pt;

CREATE UNIQUE INDEX mart_indication_match_pk
    ON public.mart_indication_match (stratum, ingredient, reaction_pt);

ANALYZE public.mart_indication_match;

/* VERIFY -------------------------------------------------------------------

-- pair_cases must equal pair_count in mart_drug_reaction_counts for every
-- row. If it does not, one of the two joins is fanning out.
SELECT count(*) AS mismatches
FROM public.mart_indication_match m
JOIN public.mart_drug_reaction_counts p USING (stratum, ingredient, reaction_pt)
WHERE m.pair_cases <> p.pair_count;

-- Distribution across bands. Most pairs sit at 0%; the 90-100% band is the
-- unambiguous artifact population.
SELECT CASE WHEN pct_indication_match >= 90 THEN '90-100%'
            WHEN pct_indication_match >= 50 THEN '50-89%'
            WHEN pct_indication_match >= 10 THEN '10-49%'
            WHEN pct_indication_match >   0 THEN '1-9%'
            ELSE '0%' END AS band,
       count(*) AS pairs, sum(pair_cases) AS cases
FROM public.mart_indication_match WHERE stratum = 'ALL'
GROUP BY 1 ORDER BY 1 DESC;

--------------------------------------------------------------------------- */
