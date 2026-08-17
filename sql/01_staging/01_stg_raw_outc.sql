-- =============================================================================
-- stg_outc — typed, cleaned pass-through of raw_outc
-- =============================================================================
-- Grain:    one row per outcome code per case version. A case with both a
--           hospitalization and a death carries two rows.
-- Depends:  public.raw_outc
-- Feeds:    SERIOUS stratum in the mart layer
--
-- Cleaning applied:
--   - blank strings -> NULL
--
-- outc_cod values: DE (death), LT (life-threatening), HO (hospitalization),
-- DS (disability), CA (congenital anomaly), RI (required intervention),
-- OT (other). Because the grain is one row per code, any join to case-level
-- data must aggregate first or it will fan out.
-- =============================================================================

CREATE OR REPLACE VIEW public.stg_outc AS 
SELECT
	primaryid,
	caseid,
	
	
    NULLIF(TRIM(outc_cod), '') AS outc_cod,
	
	report_year,
	report_quarter,
	source_quarter
	
FROM public.raw_outc;