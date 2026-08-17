-- =============================================================================
-- stg_demo_latest — deduplicated case master
-- =============================================================================
-- Grain:    one row per caseid. This is the case-level spine of the project.
-- Depends:  stg_demo
-- Feeds:    stg_drug_ingredient, every mart
--
-- WHY THIS EXISTS
-- FAERS ships one row per case VERSION, not per case. A case amended three
-- times appears three times, sharing one caseid across three primaryid values.
-- Counting cases without collapsing versions inflates every downstream count
-- and every disproportionality metric built on them.
--
-- TIE-BREAK CHAIN
-- DISTINCT ON returns the first row per caseid under the ORDER BY, so the
-- ordering IS the dedup rule:
--   caseversion    DESC            highest version wins
--   fda_dt         DESC NULLS LAST later FDA receipt date wins
--   source_quarter DESC            later quarterly release wins
--   primaryid      DESC            deterministic final fallback
--
-- The chain is fully deterministic by design. DISTINCT ON with a partial
-- ORDER BY can return different rows on different runs, which would make
-- every downstream figure unreproducible.
--
-- The two UNIQUE indexes are the test, not just an optimization: if either
-- fails to build, the dedup logic is wrong and the script errors out rather
-- than silently producing duplicates.
--
-- Materialized because every mart joins to it.
-- Refresh after loading a new quarter, BEFORE stg_drug_ingredient.
-- =============================================================================

DROP MATERIALIZED VIEW IF EXISTS public.stg_demo_latest CASCADE;

CREATE MATERIALIZED VIEW public.stg_demo_latest AS
SELECT DISTINCT ON (caseid) *
FROM public.stg_demo
ORDER BY caseid,
         caseversion    DESC,
         fda_dt         DESC NULLS LAST,
         source_quarter DESC,
         primaryid      DESC;

CREATE UNIQUE INDEX stg_demo_latest_caseid    ON public.stg_demo_latest (caseid);
CREATE UNIQUE INDEX stg_demo_latest_primaryid ON public.stg_demo_latest (primaryid);
CREATE INDEX        stg_demo_latest_rept_cod  ON public.stg_demo_latest (rept_cod);