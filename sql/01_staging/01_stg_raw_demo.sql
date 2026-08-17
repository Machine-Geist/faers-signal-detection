-- =============================================================================
-- stg_demo — typed, cleaned pass-through of raw_demo
-- =============================================================================
-- Grain:    one row per case VERSION (primaryid). Unchanged from raw_demo.
-- Depends:  public.raw_demo
-- Feeds:    stg_demo_latest
--
-- Cleaning applied:
--   - blank strings -> NULL (FAERS uses '' for missing, not NULL, so
--     `IS NULL` filters silently miss them upstream of this view)
--   - date integers -> date, handling YYYYMMDD, YYYYMM, and YYYY-only values;
--     partial dates anchor to the earliest valid point (2025 -> 2025-01-01)
--
-- NOT applied here: deduplication (see 03_stg_demo_latest), age/weight unit
-- normalization (age_cod, wt_cod), outlier handling on age and wt.
--
-- Known limitation: the date CASE checks digit count, not calendar validity.
-- PostgreSQL's to_date silently rolls over impossible values — '20250230'
-- returns 2025-03-02 rather than erroring. Unresolved because no date column
-- feeds a published metric; fda_dt is used only as a tie-break in
-- stg_demo_latest, which never fires (no ambiguous caseid/caseversion pairs).
-- =============================================================================

CREATE OR REPLACE VIEW public.stg_demo AS
SELECT
    primaryid,
    caseid,
    caseversion,
    
    
    
    NULLIF(TRIM(i_f_code), '') AS i_f_code,
    
    
    
    CASE
        WHEN event_dt::text ~ '^\d{8}$' THEN TO_DATE(event_dt::text , 'YYYYMMDD')
        WHEN event_dt::text  ~ '^\d{6}$' THEN TO_DATE(event_dt::text  || '01', 'YYYYMMDD')
        WHEN event_dt::text  ~ '^\d{4}$' THEN TO_DATE(event_dt::text  || '0101', 'YYYYMMDD')
        ELSE NULL
    END AS event_dt,

    CASE
    	WHEN mfr_dt::text  ~ '^\d{8}$' THEN TO_DATE(mfr_dt::text , 'YYYYMMDD')
    	WHEN mfr_dt::text  ~ '^\d{6}$' THEN TO_DATE(mfr_dt::text  || '01', 'YYYYMMDD')
    	WHEN mfr_dt::text  ~ '^\d{4}$' THEN TO_DATE(mfr_dt::text  || '0101', 'YYYYMMDD')
    	ELSE NULL
	END AS mfr_dt,

	CASE
    	WHEN init_fda_dt::text  ~ '^\d{8}$' THEN TO_DATE(init_fda_dt::text , 'YYYYMMDD')
    	WHEN init_fda_dt::text  ~ '^\d{6}$' THEN TO_DATE(init_fda_dt::text  || '01', 'YYYYMMDD')
    	WHEN init_fda_dt::text  ~ '^\d{4}$' THEN TO_DATE(init_fda_dt::text  || '0101', 'YYYYMMDD')
    	ELSE NULL
	END AS init_fda_dt,

	CASE
    	WHEN fda_dt::text  ~ '^\d{8}$' THEN TO_DATE(fda_dt::text , 'YYYYMMDD')
    	WHEN fda_dt::text  ~ '^\d{6}$' THEN TO_DATE(fda_dt::text  || '01', 'YYYYMMDD')
    	WHEN fda_dt::text  ~ '^\d{4}$' THEN TO_DATE(fda_dt::text  || '0101', 'YYYYMMDD')
    	ELSE NULL
	END AS fda_dt,
	
	
    NULLIF(TRIM(rept_cod), '') AS rept_cod,
    
    
    NULLIF(TRIM(auth_num), '') AS auth_num,
    
    
    NULLIF(TRIM(mfr_num), '') AS mfr_num,
    
    
    NULLIF(TRIM(mfr_sndr), '') AS mfr_sndr,
	
    
    NULLIF(TRIM(lit_ref), '') AS lit_ref,
	
    age,
	
    
    NULLIF(TRIM(age_cod), '') AS age_cod,
    
    
    NULLIF(TRIM(age_grp), '') AS age_grp,
    
    
    NULLIF(TRIM(sex), '') AS sex,
    
    
    NULLIF(TRIM(e_sub), '') AS e_sub,
    
    wt,
    
    
    NULLIF(TRIM(wt_cod), '') AS wt_cod,
    
    
    
	CASE
    	WHEN rept_dt::text  ~ '^\d{8}$' THEN TO_DATE(rept_dt::text , 'YYYYMMDD')
    	WHEN rept_dt::text  ~ '^\d{6}$' THEN TO_DATE(rept_dt::text  || '01', 'YYYYMMDD')
    	WHEN rept_dt::text  ~ '^\d{4}$' THEN TO_DATE(rept_dt::text  || '0101', 'YYYYMMDD')
    	ELSE NULL
	END AS rept_dt,

    
    NULLIF(TRIM(to_mfr), '') AS to_mfr,
    
    
    NULLIF(TRIM(occp_cod), '') AS occp_cod,
   
    
    NULLIF(TRIM(reporter_country), '') AS reporter_country,
    
    
    NULLIF(TRIM(occr_country), '') AS occr_country,
    
    report_year,
    report_quarter,
    source_quarter
    

FROM public.raw_demo;