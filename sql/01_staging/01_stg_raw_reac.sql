-- =============================================================================
-- stg_reac — typed, cleaned pass-through of raw_reac
-- =============================================================================
-- Grain:    one row per reaction PT per case version. Unchanged from raw_reac.
-- Depends:  public.raw_reac
-- Feeds:    the drug-reaction 2x2 contingency counts in the mart layer
--
-- Cleaning applied:
--   - blank strings -> NULL
--
-- pt is a MedDRA Preferred Term, already coded by FDA — no free text, no
-- normalization needed. This is why the reaction side of the analysis is
-- clean while the drug side required the prod_ai work in stg_drug_ingredient.
-- =============================================================================

CREATE OR REPLACE VIEW public.stg_reac AS
SELECT
	
	primaryid,
	caseid,
	
	
	
    NULLIF(TRIM(pt), '') AS pt,
    
    
    
    NULLIF(TRIM(drug_rec_act), '') AS drug_rec_act,
    
	
	report_year,
	report_quarter,
	source_quarter

FROM public.raw_reac;