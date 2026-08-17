-- =============================================================================
-- stg_ther — typed, cleaned pass-through of raw_ther
-- =============================================================================
-- Grain:    one row per drug therapy record (primaryid + dsg_drug_seq).
--           Unchanged from raw_ther.
-- Depends:  public.raw_ther
-- Feeds:    nothing currently 
--
-- Cleaning applied:
--   - blank strings -> NULL
--   - start_dt and end_dt parsed to date, same partial-date handling as
--     stg_demo
--
-- Built for completeness. Time-to-onset analysis (event_dt minus start_dt)
-- was scoped out: it needs both dates present and valid on the same case,
-- and disproportionality does not depend on it.
--
-- Same to_date rollover limitation as stg_demo applies to these columns.
-- =============================================================================

CREATE OR REPLACE VIEW public.stg_ther AS
SELECT

	primaryid,
	caseid,
	
	dsg_drug_seq,
	
	
	
	CASE
    	WHEN start_dt::text  ~ '^\d{8}$' THEN TO_DATE(start_dt::text , 'YYYYMMDD')
    	WHEN start_dt::text  ~ '^\d{6}$' THEN TO_DATE(start_dt::text  || '01', 'YYYYMMDD')
    	WHEN start_dt::text  ~ '^\d{4}$' THEN TO_DATE(start_dt::text  || '0101', 'YYYYMMDD')
    	ELSE NULL
	END AS start_dt,
	
	CASE
    	WHEN end_dt::text  ~ '^\d{8}$' THEN TO_DATE(end_dt::text , 'YYYYMMDD')
    	WHEN end_dt::text  ~ '^\d{6}$' THEN TO_DATE(end_dt::text  || '01', 'YYYYMMDD')
    	WHEN end_dt::text  ~ '^\d{4}$' THEN TO_DATE(end_dt::text  || '0101', 'YYYYMMDD')
    	ELSE NULL
	END AS end_dt,
	
	dur,
	
	
	NULLIF(TRIM(dur_cod),'') AS dur_cod,
	
	report_year,
	report_quarter,
	source_quarter


FROM public.raw_ther;