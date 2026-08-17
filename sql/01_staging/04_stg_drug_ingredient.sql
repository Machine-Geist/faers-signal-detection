-- =============================================================================
-- stg_drug_ingredient — case-to-ingredient mapping
-- =============================================================================
-- Grain:    one row per (caseid, primaryid, role_cod, ingredient).
-- Depends:  stg_drug, stg_demo_latest, clean_ingredient()
-- Feeds:    the drug side of every disproportionality calculation
--
-- WHAT IT DOES
-- FAERS delimits combination products in prod_ai with a backslash, so a single
-- drug row can name several active ingredients. This splits on that delimiter,
-- normalizes each fragment via clean_ingredient(), and drops anything that
-- cleans to nothing.
--
-- THE JOIN TO stg_demo_latest IS LOAD-BEARING
-- Without it the view carries every case version, not just the latest, and
-- ingredients duplicate for every amended case. That produced tens of
-- thousands of spurious rows before it was caught — the grain bug that had to
-- be fixed before any mart metric meant anything.
--
-- prod_ai is used rather than drugname because it is FDA-validated: it is
-- populated for effectively all primary-suspect records, while drugname is
-- reporter-verbatim and fragments heavily across brands and misspellings.
--
-- KNOWN LIMITATION
-- Salt and ester forms are not resolved. CIPROFLOXACIN and CIPROFLOXACIN
-- HYDROCHLORIDE remain distinct ingredients, splitting counts for the same
-- moiety. Measured and documented rather than fixed; see the project README.
--
-- Materialized. Refresh AFTER stg_demo_latest.
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS public.stg_drug_ingredient CASCADE;

CREATE MATERIALIZED VIEW public.stg_drug_ingredient AS

SELECT DISTINCT
       d.caseid,
       d.primaryid,
       d.role_cod,
       public.clean_ingredient(i) AS ingredient
FROM public.stg_drug d
JOIN public.stg_demo_latest dl ON dl.primaryid = d.primaryid
CROSS JOIN LATERAL unnest(string_to_array(d.prod_ai, E'\\')) AS i
WHERE public.clean_ingredient(i) IS NOT NULL;

CREATE UNIQUE INDEX stg_drug_ingredient_pk
    ON public.stg_drug_ingredient (caseid, primaryid, role_cod, ingredient);
CREATE INDEX stg_drug_ingredient_ing  ON public.stg_drug_ingredient (ingredient);
CREATE INDEX stg_drug_ingredient_case ON public.stg_drug_ingredient (caseid);