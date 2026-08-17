-- =============================================================================
-- stg_rpsr — typed, cleaned pass-through of raw_rpsr
-- =============================================================================
-- Grain:    one row per report source per case version. Sparsely populated;
--           most cases have no rpsr row at all.
-- Depends:  public.raw_rpsr
-- Feeds:    nothing currently 
-- Cleaning applied:
--   - blank strings -> NULL
--
-- Built for completeness of the staging layer. Report source (FGN, SDY, LIT,
-- CSM, DT, OTH) was considered as a stratification variable but not used —
-- coverage is too sparse to stratify on without dropping most of the database.
-- =============================================================================


CREATE OR REPLACE VIEW public.stg_rpsr AS
SELECT

	primaryid,
	caseid,
	
	
	NULLIF(TRIM(rpsr_cod), '') AS rpsr_cod,
	
	report_year,
	report_quarter,
	source_quarter
	
FROM public.raw_rpsr;