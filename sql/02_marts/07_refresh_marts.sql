/* ============================================================================
   07 — Refresh script
   ============================================================================
   Run after loading a new FAERS quarter.

   ORDER IS LOAD-BEARING. Dependencies flow strictly downward, and refreshing
   a parent after its child leaves the child built on stale data. Nothing
   errors when that happens — the refresh succeeds and the numbers are quietly
   wrong, which is the failure mode this ordering exists to prevent.

   Dependency chain:
     stg_demo_latest
       -> stg_drug_ingredient
            -> mart_case_strata
                 -> mart_stratum_totals
                 -> mart_drug_totals
                 -> mart_reaction_totals
                 -> mart_drug_reaction_counts
                 -> mart_indication_match
                      -> mart_disproportionality_signals

   CONCURRENTLY avoids locking readers while the refresh runs. It requires a
   UNIQUE index, which every matview here has. It is slower than a plain
   refresh and cannot be used on the very first build — the view must already
   be populated — so omit it the first time through.

   ref_masking_exclusions is a table, not a matview. It does not refresh. If
   the dominant reporting drug changes as quarters are added, INSERT the new
   ingredient there and re-run this script from the top.
============================================================================ */

-- ---------------------------------------------------------------------------
-- Staging layer first — the marts read from it.
-- ---------------------------------------------------------------------------
REFRESH MATERIALIZED VIEW CONCURRENTLY public.stg_demo_latest;
REFRESH MATERIALIZED VIEW CONCURRENTLY public.stg_drug_ingredient;

-- ---------------------------------------------------------------------------
-- Mart layer, in dependency order.
-- ---------------------------------------------------------------------------

-- Defines the analysis universe. Everything below inherits it.
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_case_strata;

-- The four contingency inputs. Independent of each other, all depend on
-- mart_case_strata.
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_stratum_totals;
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_drug_totals;
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_reaction_totals;
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_drug_reaction_counts;

-- Indication confounding. Must precede 06 — the LEFT JOIN there means a
-- stale indication mart yields pct_indication_match = 0 for every new pair,
-- silently marking them all as artifact-free.
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_indication_match;

-- The centerpiece. Depends on all of the above.
REFRESH MATERIALIZED VIEW CONCURRENTLY public.mart_disproportionality_signals;

-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------
-- A refresh replaces the contents but leaves planner statistics describing
-- the old data, which can produce bad plans on the next query.

ANALYZE public.stg_demo_latest;
ANALYZE public.stg_drug_ingredient;
ANALYZE public.mart_case_strata;
ANALYZE public.mart_stratum_totals;
ANALYZE public.mart_drug_totals;
ANALYZE public.mart_reaction_totals;
ANALYZE public.mart_drug_reaction_counts;
ANALYZE public.mart_indication_match;
ANALYZE public.mart_disproportionality_signals;


/* VERIFY -------------------------------------------------------------------

-- Every quarter loaded should appear here. If a newly loaded quarter is
-- missing, the refresh did not propagate.
SELECT source_quarter, count(*) AS cases
FROM public.stg_demo_latest GROUP BY 1 ORDER BY 1;

-- Nothing should be older than the raw tables. Any matview whose last
-- refresh predates the load is stale.
SELECT relname, last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND relname LIKE ANY (ARRAY['stg_%','mart_%'])
ORDER BY relname;

-- Sanity: the centerpiece must have a row for every pair in 05.
SELECT (SELECT count(*) FROM public.mart_drug_reaction_counts)      AS pairs,
       (SELECT count(*) FROM public.mart_disproportionality_signals) AS signals;

--------------------------------------------------------------------------- */
