/* ============================================================================
   02 — mart_stratum_totals
   ============================================================================
   PURPOSE   N for each stratum — the denominator of every contingency table.
   GRAIN     One row per stratum.
   DEPENDS   mart_case_strata
   FEEDS     06_mart_disproportionality_signals

   WHY THIS TINY VIEW EXISTS
   Two reasons N cannot be a literal:

     1. Each stratum has its own N. EXPEDITED is a fraction of ALL. A single
        hardcoded N would make every chi-square in every non-ALL stratum wrong.

     2. Even for ALL, N is not the count of all deduplicated cases — it is
        the count of ELIGIBLE cases. Including cases with no PS drug or no
        reaction inflates d and biases the background rate.

   Four rows, but it is the denominator of every metric in the project.
     
============================================================================ */

DROP MATERIALIZED VIEW IF EXISTS public.mart_stratum_totals CASCADE;

CREATE MATERIALIZED VIEW public.mart_stratum_totals AS
SELECT stratum,
       count(DISTINCT caseid) AS n_cases
FROM public.mart_case_strata
GROUP BY stratum;

CREATE UNIQUE INDEX mart_stratum_totals_pk
    ON public.mart_stratum_totals (stratum);

/* VERIFY -------------------------------------------------------------------
-- ALL must be the largest stratum; every other stratum is a subset of it.
SELECT * FROM public.mart_stratum_totals ORDER BY n_cases DESC;

-- Cross-check: each stratum's N must match its row count in mart_case_strata.
SELECT s.stratum, s.n_cases, count(c.caseid) AS strata_rows
FROM public.mart_stratum_totals s
JOIN public.mart_case_strata c USING (stratum)
GROUP BY s.stratum, s.n_cases
HAVING s.n_cases <> count(c.caseid);
--------------------------------------------------------------------------- */