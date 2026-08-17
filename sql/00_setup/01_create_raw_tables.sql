-- =============================================================================
-- FAERS Disproportionality Analysis — Raw Layer DDL
-- =============================================================================
-- Creates the seven raw landing tables mirroring the FDA FAERS quarterly
-- ASCII extract files (DEMO, DRUG, INDI, OUTC, REAC, RPSR, THER).
--
-- Layer:     raw (landing) — no deduplication, no normalization, no constraints.
--            Loaded as-delivered from FDA. All cleaning happens in the staging
--            layer; this layer is intentionally faithful to the source files.
--
-- Source:    FDA Adverse Event Reporting System (FAERS) public quarterly files
--            https://fda.gov/drugs/fdas-adverse-event-reporting-system-faers
--            Public domain (CC0 1.0). Independent analysis, not FDA-affiliated.
--
-- Target:    PostgreSQL
-- Run order: 01 of the pipeline — run before any load or staging script.
--
-- Usage:
--   1. Run sections 1 -3.
--   2. Bulk load the quarterly FAERS files via DBeaver import and tag 
--	    provenance information (see README for instructions.)
--   3. Run section 4 and 5 at the bottom to create indexes and analyze.
--      Building indexes before a multi-million-row COPY is significantly
--      slower than building them once the data is in place.
--   4. If you decide to load additional quarters later, repeat steps 2 and 3.
--      Do not repeat step 1.
--
-- WARNING: The DROP block below is destructive and rebuilds the raw layer
--          from scratch. Comment it out if you are appending a new quarter
--          to an existing load rather than doing a full rebuild.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Provenance columns
-- -----------------------------------------------------------------------------
-- Every table carries three columns that are NOT native to the FAERS extract.
-- They are added during load so that multi-quarter data stays traceable to the
-- file it came from (see README for details):
--   report_year     - reporting year parsed from the source file
--   report_quarter  - reporting quarter parsed from the source file
--   source_quarter  - the FAERS quarterly release the row was loaded from
-- -----------------------------------------------------------------------------


-- =============================================================================
-- SECTION 1 — TEARDOWN
-- =============================================================================

DROP TABLE IF EXISTS public.raw_demo CASCADE;
DROP TABLE IF EXISTS public.raw_drug CASCADE;
DROP TABLE IF EXISTS public.raw_indi CASCADE;
DROP TABLE IF EXISTS public.raw_outc CASCADE;
DROP TABLE IF EXISTS public.raw_reac CASCADE;
DROP TABLE IF EXISTS public.raw_rpsr CASCADE;
DROP TABLE IF EXISTS public.raw_ther CASCADE;


-- =============================================================================
-- SECTION 2 — TABLE DEFINITIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- raw_demo — case demographics and administrative header
-- Grain: one row per case version (primaryid)
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_demo (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    caseversion         int4    NULL,
    i_f_code            text    NULL,
    event_dt            int4    NULL,
    mfr_dt              int4    NULL,
    init_fda_dt         int4    NULL,
    fda_dt              int4    NULL,
    rept_cod            text    NULL,
    auth_num            text    NULL,
    mfr_num             text    NULL,
    mfr_sndr            text    NULL,
    lit_ref             text    NULL,
    age                 int4    NULL,
    age_cod             text    NULL,
    age_grp             text    NULL,
    sex                 text    NULL,
    e_sub               text    NULL,
    wt                  float4  NULL,
    wt_cod              text    NULL,
    rept_dt             int4    NULL,
    to_mfr              text    NULL,
    occp_cod            text    NULL,
    reporter_country    text    NULL,
    occr_country        text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);

-- -----------------------------------------------------------------------------
-- raw_drug — drugs reported in each case
-- Grain: one row per drug per case version (primaryid + drug_seq)
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_drug (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    drug_seq            int8    NULL,
    role_cod            text    NULL,
    drugname            text    NULL,
    prod_ai             text    NULL,
    val_vbm             int8    NULL,
    route               text    NULL,
    dose_vbm            text    NULL,
    cum_dose_chr        float4  NULL,
    cum_dose_unit       text    NULL,
    dechal              text    NULL,
    rechal              text    NULL,
    lot_num             text    NULL,
    exp_dt              text    NULL,
    nda_num             int8    NULL,
    dose_amt            int8    NULL,
    dose_unit           text    NULL,
    dose_form           text    NULL,
    dose_freq           text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);

-- -----------------------------------------------------------------------------
-- raw_indi — indication (reason for use) per drug
-- Grain: one row per drug indication (primaryid + indi_drug_seq)
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_indi (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    indi_drug_seq       int8    NULL,
    indi_pt             text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);

-- -----------------------------------------------------------------------------
-- raw_outc — patient outcome codes
-- Grain: one row per outcome code per case version
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_outc (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    outc_cod            text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);

-- -----------------------------------------------------------------------------
-- raw_reac — reported reactions as MedDRA Preferred Terms
-- Grain: one row per reaction PT per case version
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_reac (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    pt                  text    NULL,
    drug_rec_act        text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);

-- -----------------------------------------------------------------------------
-- raw_rpsr — report source codes
-- Grain: one row per report source per case version
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_rpsr (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    rpsr_cod            text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);

-- -----------------------------------------------------------------------------
-- raw_ther — therapy start/end dates and duration per drug
-- Grain: one row per drug therapy record (primaryid + dsg_drug_seq)
-- -----------------------------------------------------------------------------
CREATE TABLE public.raw_ther (
    primaryid           int8    NULL,
    caseid              int8    NULL,
    dsg_drug_seq        int8    NULL,
    start_dt            int8    NULL,
    end_dt              int8    NULL,
    dur                 int8    NULL,
    dur_cod             text    NULL,
    report_year         int4    NULL,
    report_quarter      text    NULL,
    source_quarter      text    NULL
);


-- =============================================================================
-- SECTION 3 — DOCUMENTATION
-- =============================================================================
-- FAERS column names are heavily abbreviated. These comments are stored in the
-- catalog so the schema is self-describing in any client.

COMMENT ON TABLE public.raw_demo IS 'FAERS DEMO: case demographics and administrative header. One row per case version.';
COMMENT ON TABLE public.raw_drug IS 'FAERS DRUG: drugs reported per case. One row per drug per case version.';
COMMENT ON TABLE public.raw_indi IS 'FAERS INDI: indication for use per drug (MedDRA PT).';
COMMENT ON TABLE public.raw_outc IS 'FAERS OUTC: patient outcome codes per case version.';
COMMENT ON TABLE public.raw_reac IS 'FAERS REAC: reported reactions as MedDRA Preferred Terms.';
COMMENT ON TABLE public.raw_rpsr IS 'FAERS RPSR: report source codes per case version.';
COMMENT ON TABLE public.raw_ther IS 'FAERS THER: therapy start/end dates and duration per drug.';

COMMENT ON COLUMN public.raw_demo.primaryid   IS 'Unique identifier for a case VERSION. Changes when a case is amended.';
COMMENT ON COLUMN public.raw_demo.caseid      IS 'Case identifier, stable across versions. Deduplicate on this in staging.';
COMMENT ON COLUMN public.raw_demo.caseversion IS 'Version number of the case. Keep the highest per caseid.';
COMMENT ON COLUMN public.raw_demo.i_f_code    IS 'I = initial report, F = follow-up report.';
COMMENT ON COLUMN public.raw_demo.rept_cod    IS 'Report type: EXP (expedited), PER (periodic), DIR (direct).';
COMMENT ON COLUMN public.raw_demo.age_cod     IS 'Unit for age: DEC, YR, MON, WK, DY, HR. Must be normalized before use.';
COMMENT ON COLUMN public.raw_demo.wt_cod      IS 'Unit for weight: KG or LBS. Must be normalized before use.';
COMMENT ON COLUMN public.raw_demo.occp_cod    IS 'Reporter occupation: MD, PH, OT, LW, CN.';
COMMENT ON COLUMN public.raw_demo.event_dt    IS 'Date as YYYYMMDD integer; may be partial (YYYY or YYYYMM) or invalid.';

COMMENT ON COLUMN public.raw_drug.role_cod    IS 'Drug role: PS (primary suspect), SS (secondary suspect), C (concomitant), I (interacting).';
COMMENT ON COLUMN public.raw_drug.drugname    IS 'Verbatim reported name. Not normalized — salts, esters, and brands vary widely.';
COMMENT ON COLUMN public.raw_drug.prod_ai     IS 'Active ingredient as reported. Sparsely populated.';
COMMENT ON COLUMN public.raw_drug.dechal      IS 'Dechallenge: did the reaction abate when the drug was withdrawn? Y/N/U/D.';
COMMENT ON COLUMN public.raw_drug.rechal      IS 'Rechallenge: did the reaction recur when the drug was reintroduced? Y/N/U/D.';

COMMENT ON COLUMN public.raw_indi.indi_drug_seq IS 'Joins to raw_drug.drug_seq on the same primaryid.';
COMMENT ON COLUMN public.raw_outc.outc_cod      IS 'Outcome: DE (death), LT (life-threatening), HO (hospitalization), DS (disability), CA (congenital anomaly), RI (required intervention), OT (other).';
COMMENT ON COLUMN public.raw_reac.pt            IS 'MedDRA Preferred Term for the reported reaction.';
COMMENT ON COLUMN public.raw_ther.dsg_drug_seq  IS 'Joins to raw_drug.drug_seq on the same primaryid.';


-- =============================================================================
-- SECTION 4 — INDEXES
-- =============================================================================
-- Run AFTER the bulk load, not before. Every table is keyed on primaryid
-- (case version) and caseid (stable case), which are the two join paths used
-- throughout the staging and mart layers.

CREATE INDEX IF NOT EXISTS idx_demo_primaryid ON public.raw_demo USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_demo_caseid    ON public.raw_demo USING btree (caseid);

CREATE INDEX IF NOT EXISTS idx_drug_primaryid ON public.raw_drug USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_drug_caseid    ON public.raw_drug USING btree (caseid);

CREATE INDEX IF NOT EXISTS idx_indi_primaryid ON public.raw_indi USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_indi_caseid    ON public.raw_indi USING btree (caseid);

CREATE INDEX IF NOT EXISTS idx_outc_primaryid ON public.raw_outc USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_outc_caseid    ON public.raw_outc USING btree (caseid);

CREATE INDEX IF NOT EXISTS idx_reac_primaryid ON public.raw_reac USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_reac_caseid    ON public.raw_reac USING btree (caseid);

CREATE INDEX IF NOT EXISTS idx_rpsr_primaryid ON public.raw_rpsr USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_rpsr_caseid    ON public.raw_rpsr USING btree (caseid);

CREATE INDEX IF NOT EXISTS idx_ther_primaryid ON public.raw_ther USING btree (primaryid);
CREATE INDEX IF NOT EXISTS idx_ther_caseid    ON public.raw_ther USING btree (caseid);


-- =============================================================================
-- SECTION 5 — POST-LOAD
-- =============================================================================
-- Refresh planner statistics so the staging queries get sane query plans.

ANALYZE public.raw_demo;
ANALYZE public.raw_drug;
ANALYZE public.raw_indi;
ANALYZE public.raw_outc;
ANALYZE public.raw_reac;
ANALYZE public.raw_rpsr;
ANALYZE public.raw_ther;

-- =============================================================================
-- End of raw layer DDL
-- =============================================================================
