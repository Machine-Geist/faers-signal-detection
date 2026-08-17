-- =============================================================================
-- stg_indi — typed, cleaned pass-through of raw_indi
-- =============================================================================
-- Grain:    one row per drug indication (primaryid + indi_drug_seq).
--           Unchanged from raw_indi.
-- Depends:  public.raw_indi
-- Feeds:    mart_indication_match
--
-- Cleaning applied:
--   - blank strings -> NULL
--
-- indi_pt is a MedDRA Preferred Term drawn from the same vocabulary as
-- reac.pt, which is what makes the indication-vs-reaction overlap check
-- possible downstream.
-- =============================================================================

CREATE OR REPLACE VIEW public.stg_indi AS
SELECT 
	primaryid,
	caseid,
	indi_drug_seq,
	
	
	NULLIF(TRIM(indi_pt),'') AS indi_pt,
	
	report_year,
	
	report_quarter,
	
	source_quarter
	
FROM public.raw_indi;
	