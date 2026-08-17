-- =============================================================================
-- clean_ingredient(text) -> text
-- =============================================================================
-- Purpose:  Normalizes a single active-ingredient fragment from prod_ai.
-- Depends:  nothing
-- Feeds:    stg_drug_ingredient
--
-- Run order: must exist before 04_stg_drug_ingredient.
--
-- Applies:
--   - uppercase
--   - Greek-letter escape decoding (.ALPHA. -> ALPHA)
--   - whitespace collapse, and removal of space before hyphens
--     (TOCOPHEROL -ALPHA -> TOCOPHEROL-ALPHA)
--   - trims leading/trailing spaces, periods, commas, hyphens
--   - returns NULL for anything that cleans to empty
--
-- IMMUTABLE so the planner can inline it and it can be used in index
-- expressions.
--
-- Does NOT resolve salt or ester forms. CIPROFLOXACIN and CIPROFLOXACIN
-- HYDROCHLORIDE remain distinct. Measured and documented, not fixed.
-- =============================================================================


CREATE OR REPLACE FUNCTION clean_ingredient(raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT nullif(
    btrim(
      regexp_replace(
        regexp_replace(
          replace(replace(replace(replace(replace(
            upper(coalesce(raw, '')),
            '.ALPHA.', 'ALPHA '),
            '.BETA.',  'BETA '),
            '.GAMMA.', 'GAMMA '),
            '.DELTA.', 'DELTA '),
            '.OMEGA.', 'OMEGA '),
          '\s+', ' ', 'g'),
        '\s+-', '-', 'g'),
      ' .,-'),
  '')
$$;