-- =============================================================================
-- stg_drug — typed, cleaned pass-through of raw_drug
-- =============================================================================
-- Grain:    one row per drug per case version (primaryid + drug_seq).
--           Unchanged from raw_drug.
-- Depends:  public.raw_drug
-- Feeds:    stg_drug_ingredient
--
-- Cleaning applied:
--   - blank strings -> NULL
--   - exp_dt parsed to date (stored as text in raw, unlike other date columns)
--
-- NOT applied here: drug name normalization, salt/ester resolution, role_cod
-- filtering, prod_ai splitting. All of that happens in stg_drug_ingredient so
-- it can be documented and varied in one place.
--
-- Note: dose_amt is int8 in the raw layer, so fractional doses are truncated
-- at load. Not consumed downstream.
-- =============================================================================

CREATE OR REPLACE VIEW public.stg_drug AS
SELECT
    primaryid,
    caseid,
    
    
    
    drug_seq,
    
   
    NULLIF(TRIM(role_cod), '') as role_cod,
    
    
    NULLIF(TRIM(drugname), '') AS drugname,
    
    
    NULLIF(TRIM(prod_ai), '') as prod_ai,
    
    
    val_vbm,
    
    
    
    NULLIF(TRIM(route), '') as route,
    
    
    NULLIF(TRIM(dose_vbm), '') as dose_vbm,
    
    
    
    cum_dose_chr,
    
    
    
    NULLIF(TRIM(cum_dose_unit), '') as cum_dose_unit,
    
    
    
    NULLIF(TRIM(dechal), '') as dechal,
    
    
    
    NULLIF(TRIM(rechal), '') as rechal,
    
    
    NULLIF(TRIM(lot_num), '') as lot_num,
    
    
    case 
    	when exp_dt ~ '^\d{8}$' then TO_DATE(exp_dt, 'YYYYMMDD')
    	when exp_dt ~ '^\d{6}$' then TO_DATE(exp_dt  || '01','YYYYMMDD')
    	when exp_dt ~ '^\d{4}$' then TO_DATE(exp_dt  || '0101','YYYYMMDD')
    	else null
    end as exp_dt,
     
    
    
    
    nda_num,
    
    
    dose_amt,
    
    
    
    NULLIF(TRIM(dose_unit), '') as dose_unit,
    
    
    NULLIF(TRIM(dose_form), '') as dose_form,
    
    
    
    
    NULLIF(TRIM(dose_freq), '') as dose_freq,
    
   
    report_year,
    
    
    report_quarter,
    
    
    source_quarter
    
    from public.raw_drug;
    