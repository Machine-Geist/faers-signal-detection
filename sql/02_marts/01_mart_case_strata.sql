/* ============================================================================
   01 — mart_case_strata
   ============================================================================
   PURPOSE   Defines the analysis universe and maps each eligible case to
             every stratum it belongs to.
   GRAIN     One row per (stratum, caseid). A case appears in several strata.
   DEPENDS   stg_demo_latest, stg_drug_ingredient, stg_reac, stg_outc,
             ref_masking_exclusions
   FEEDS     Every other mart.

   THE ANALYSIS UNIVERSE
   The universe is defined once here — a case is eligible only if it has
   BOTH a primary-suspect drug AND a reaction — and every downstream mart
   inherits it by inner-joining this view. Without a single shared
   definition, drug totals, reaction totals, and N would each be drawn from
   a different population, and each contingency table would mix three
   incompatible denominators.

   A case lacking either can never contribute to any contingency cell except
   d, so including it only distorts the background rate.

   THE STRATA
     ALL           baseline
     EXPEDITED     rept_cod='EXP'. 15-day reports, legally required when an
                   event is serious AND unexpected. Excludes the periodic
                   channel that carries solicited, already-labeled events —
                   which is 91% of dupilumab's volume.
     SERIOUS       at least one ICH-serious outcome code
     NO_MASK_DRUG  excludes cases mentioning any ref_masking_exclusions drug
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_case_strata CASCADE;

CREATE MATERIALIZED VIEW public.mart_case_strata AS
WITH universe AS (
    SELECT dl.caseid,
           dl.primaryid,
           dl.rept_cod
    FROM public.stg_demo_latest dl
    WHERE EXISTS (SELECT 1 FROM public.stg_drug_ingredient i
                  WHERE i.caseid = dl.caseid
                    AND i.role_cod = 'PS')
      AND EXISTS (SELECT 1 FROM public.stg_reac r
                  WHERE r.primaryid = dl.primaryid)
)
SELECT 'ALL'::text AS stratum, caseid, primaryid
FROM universe

UNION ALL

SELECT 'EXPEDITED', caseid, primaryid
FROM universe
WHERE rept_cod = 'EXP'

UNION ALL

/* ICH serious outcome codes:
     DE death            LT life-threatening    HO hospitalization
     DS disability       CA congenital anomaly  RI required intervention
   'OT' (other serious) is deliberately excluded — it is a catch-all and
   including it materially loosens the definition. */
SELECT 'SERIOUS', u.caseid, u.primaryid
FROM universe u
WHERE EXISTS (SELECT 1 FROM public.stg_outc o
              WHERE o.primaryid = u.primaryid
                AND o.outc_cod IN ('DE','LT','HO','DS','CA','RI'))

UNION ALL

SELECT 'NO_MASK_DRUG', u.caseid, u.primaryid
FROM universe u
WHERE NOT EXISTS (SELECT 1 FROM public.stg_drug_ingredient i
                  WHERE i.caseid = u.caseid
                    AND i.ingredient IN (SELECT ingredient
                                         FROM public.ref_masking_exclusions));

/* The UNIQUE index is a grain assertion. If (stratum, caseid) is ever not
   unique, this CREATE fails loudly instead of letting duplicated rows
   silently inflate every downstream count. It also enables
   REFRESH MATERIALIZED VIEW CONCURRENTLY. Put one on every matview. */
CREATE UNIQUE INDEX mart_case_strata_pk
    ON public.mart_case_strata (stratum, caseid);
CREATE INDEX mart_case_strata_primaryid
    ON public.mart_case_strata (stratum, primaryid);

/* VERIFY -------------------------------------------------------------------
-- Stratum sizes. EXPEDITED and SERIOUS must be proper subsets of ALL.
SELECT stratum, count(*) AS cases
FROM public.mart_case_strata GROUP BY 1 ORDER BY 2 DESC;

-- How much the eligibility filter removes: total deduplicated cases vs the
-- eligible universe. The gap is cases with no PS drug or no reaction.
SELECT (SELECT count(*) FROM public.stg_demo_latest)                        AS all_cases,
       (SELECT count(*) FROM public.mart_case_strata WHERE stratum='ALL')   AS eligible;
--------------------------------------------------------------------------- */
