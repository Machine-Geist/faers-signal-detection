/* ============================================================================
   00 — ref_masking_exclusions   (reference table)
   ============================================================================
   PURPOSE   Ingredients to exclude when testing for masking (competition bias).
   GRAIN     One row per ingredient.
   DEPENDS   Nothing.
   FEEDS     01_mart_case_strata (NO_MASK_DRUG stratum). 

   WHY THIS IS A TABLE AND NOT A HARDCODED LIST
   A single very high-volume drug inflates the background rate (cells c and d)
   for its own characteristic reactions, suppressing PRR for every other drug
   reporting them. Which drug dominates is a property of the data, and it will
   change as you add quarters. Keeping it here means rescaling is an INSERT,
   not a view rewrite.

 
============================================================================ */

CREATE TABLE IF NOT EXISTS public.ref_masking_exclusions (
    ingredient  text PRIMARY KEY,
    rationale   text NOT NULL,
    added_on    date NOT NULL DEFAULT current_date
);

INSERT INTO public.ref_masking_exclusions (ingredient, rationale)
VALUES ('DUPILUMAB',
        'Top ingredient at ~7.8% of PS cases; 91% periodic reporting, '
        'consistent with solicited reporting via patient support program')
ON CONFLICT (ingredient) DO NOTHING;

-- ON CONFLICT DO NOTHING makes this script safe to re-run. 

/* VERIFY -------------------------------------------------------------------
SELECT * FROM public.ref_masking_exclusions;
--------------------------------------------------------------------------- */
