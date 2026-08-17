-- =============================================================================
-- FAERS Disproportionality Analysis — OMOP Reference Set DDL
-- =============================================================================
-- Creates the landing table for the OMOP drug-outcome reference standard, used
-- to validate the disproportionality signals produced by this pipeline against
-- an external, literature-adjudicated ground truth.
--
-- Layer:     reference (external) — not derived from FAERS. Loaded as-delivered
--            from the OHDSI MethodEvaluation package.
--
-- Source:    OMOP reference set, distributed via the OHDSI MethodEvaluation R
--            package. Retrieved by 02_grab_omop.py.
--            https://ohdsi.github.io/MethodEvaluation/reference/omopReferenceSet.html
--
-- Citation:  Ryan PB, Schuemie MJ, Welebob E, Duke J, Valentine S, Hartzema AG.
--            Defining a reference set to support methodological research in
--            drug safety. Drug Safety. 2013;36(Suppl 1):S33-47.
--
-- Contents:  399 drug-outcome pairs — 165 positive controls (drug believed to
--            cause the outcome) and 234 negative controls (believed not to) —
--            across four health outcomes of interest: acute liver injury,
--            acute kidney injury, acute myocardial infarction, and upper
--            gastrointestinal bleeding.
--
-- Target:    PostgreSQL
-- Run order: 03 of the pipeline.
--              01 - create FAERS raw tables
--              02 - 02_grab_omop.py retrieves the reference set
--              03 - this script, then load the retrieved file (see README)
--
-- NOTE ON IDENTIFIER CASE:
--   Column names are quoted camelCase, preserved verbatim from the upstream
--   OHDSI package so that the loaded table matches the published reference set
--   one-to-one. PostgreSQL folds unquoted identifiers to lowercase, so every
--   downstream reference must keep the double quotes:  "exposureName", not
--   exposureName. This is deliberate — it keeps provenance obvious and avoids a
--   silent rename between the cited source and this table.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — TEARDOWN
-- =============================================================================

DROP TABLE IF EXISTS public.omop_reference_set CASCADE;


-- =============================================================================
-- SECTION 2 — TABLE DEFINITION
-- =============================================================================
-- Grain: one row per drug-outcome control pair.

CREATE TABLE public.omop_reference_set (
    "exposureId"        int8    NULL,
    "exposureName"      text    NULL,
    "outcomeId"         int8    NULL,
    "outcomeName"       text    NULL,
    "groundTruth"       int8    NULL,
    "indicationId"      int8    NULL,
    "indicationName"    text    NULL,
    "comparatorId"      int8    NULL,
    "comparatorName"    text    NULL,
    "comparatorType"    text    NULL
);


-- =============================================================================
-- SECTION 3 — DOCUMENTATION
-- =============================================================================

COMMENT ON TABLE public.omop_reference_set IS
    'OMOP drug-outcome reference standard (Ryan et al., Drug Safety 2013). External ground truth for validating disproportionality signal detection. 399 pairs: 165 positive, 234 negative controls across 4 outcomes.';

COMMENT ON COLUMN public.omop_reference_set."exposureId"     IS 'OMOP concept ID for the drug (exposure).';
COMMENT ON COLUMN public.omop_reference_set."exposureName"   IS 'Drug ingredient name. Join key to FAERS requires normalization — FAERS drugname is verbatim and unnormalized.';
COMMENT ON COLUMN public.omop_reference_set."outcomeId"      IS 'OMOP concept ID for the outcome condition.';
COMMENT ON COLUMN public.omop_reference_set."outcomeName"    IS 'One of four health outcomes of interest: acute liver injury, acute kidney injury, acute myocardial infarction, upper GI bleeding. Maps to MedDRA PTs via a manual crosswalk, not a 1:1 match.';
COMMENT ON COLUMN public.omop_reference_set."groundTruth"    IS 'Control label: 1 = positive control (drug believed to cause outcome), 0 = negative control. This is the target for validation metrics.';
COMMENT ON COLUMN public.omop_reference_set."indicationId"   IS 'Concept ID of the primary indication for the drug. Used when nesting analysis within indication to control for confounding by indication.';
COMMENT ON COLUMN public.omop_reference_set."indicationName" IS 'Text label for the primary indication.';
COMMENT ON COLUMN public.omop_reference_set."comparatorId"   IS 'Concept ID of the comparator drug, for cohort-method designs. Not used in disproportionality analysis.';
COMMENT ON COLUMN public.omop_reference_set."comparatorName" IS 'Text label for the comparator drug.';
COMMENT ON COLUMN public.omop_reference_set."comparatorType" IS 'How the comparator was selected. Not used in disproportionality analysis.';


-- =============================================================================
-- SECTION 4 — INDEXES
-- =============================================================================
-- The table is small (399 rows), so the planner will usually prefer a
-- sequential scan regardless. These exist to support the name-based join to
-- normalized FAERS drug and reaction terms in the validation scripts.

CREATE INDEX idx_omop_exposure_name ON public.omop_reference_set USING btree ("exposureName");
CREATE INDEX idx_omop_outcome_name  ON public.omop_reference_set USING btree ("outcomeName");
CREATE INDEX idx_omop_ground_truth  ON public.omop_reference_set USING btree ("groundTruth");


-- =============================================================================
-- SECTION 5 — POST-LOAD VALIDATION
-- =============================================================================
-- Run after loading. Expected: 399 total, 165 positive, 234 negative, 4 outcomes.
-- A mismatch means 02_grab_omop.py pulled a different revision of the set.

-- SELECT
--     COUNT(*)                                             AS total_pairs,
--     COUNT(*) FILTER (WHERE "groundTruth" = 1)            AS positive_controls,
--     COUNT(*) FILTER (WHERE "groundTruth" = 0)            AS negative_controls,
--     COUNT(DISTINCT "outcomeName")                        AS distinct_outcomes,
--     COUNT(DISTINCT "exposureName")                       AS distinct_drugs
-- FROM public.omop_reference_set;

ANALYZE public.omop_reference_set;


-- =============================================================================
-- KNOWN LIMITATION OF THIS REFERENCE STANDARD
-- =============================================================================
-- The OMOP negative controls have been challenged in the literature. Hauben et
-- al. (Drug Safety, 2016) reviewed the 2013 negative control set and reported
-- that roughly 17% were misclassified or potentially misclassified — 21 pairs
-- failed OMOP's own adjudication criteria, and a further 19 had case reports or
-- observational evidence of an association. The classification criteria are
-- also asymmetric with respect to case-report evidence.
--
-- Practical effect: validation metrics computed against this set (AUC,
-- sensitivity, specificity) are attenuated. Some "false positives" produced by
-- the pipeline may be real associations mislabeled as negative controls. Cite
-- this when reporting performance rather than presenting the AUC as clean.
--
--   Hauben M, Aronson JK, Ferner RE. Evidence of misclassification of
--   drug-event associations classified as gold standard 'negative controls' by
--   the Observational Medical Outcomes Partnership (OMOP).
--   Drug Safety. 2016;39(5):421-32.
-- =============================================================================
