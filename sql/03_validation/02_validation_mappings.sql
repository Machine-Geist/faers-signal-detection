/* ============================================================================
   02 — Validation mappings: OMOP names -> FAERS entities
   ============================================================================
   PURPOSE   Resolve the two vocabularies. OMOP names outcomes with its own
             labels and drugs at the active-moiety level; FAERS uses MedDRA PTs
             and prod_ai strings that often carry the salt or ester form.
   DEPENDS   omop_reference_set, mart_drug_totals
   NOTE      outcome_group values in Section A must match ref_outcome_groups
             (01). Not enforceable by FK -- that table is keyed on
             (outcome_group, reaction_pt), so outcome_group alone is not unique.
   FEEDS     03_mart_validation_signals.sql

   ** SCOPE NOTE **
   These maps are used ONLY by the validation layer. They do not modify
   stg_drug_ingredient or any published mart, so no previously reported number
   changes. Name resolution is corrected where it demonstrably matters -- the
   ~120 reference drugs -- rather than across the whole pipeline. The 7.08%
   global salt fragmentation remains a documented limitation.

   ** STRUCTURE **
   Section A  outcome name map
   Section B  exposure map: table, auto-populate, then REVIEWED CORRECTIONS
   Section C  documented exclusions (a separate table -- see the note there)
   Section D  audit queries

   Auto-populate runs first and is purely mechanical; every judgment is
   applied afterwards as an explicit statement. Run the whole file top to
   bottom and the reviewed state is reproduced exactly. Never hand-edit the
   tables outside this script.
============================================================================ */


/* ===========================================================================
   SECTION A — Outcome name map
   ===========================================================================
   Four rows. Note the DEFINITIONAL MISMATCH on liver: OMOP says "Acute Liver
   Failure" (the severe end) while ACUTE_LIVER_INJURY is broader, including
   JAUNDICE and HEPATIC CYTOLYSIS. Left as-is and disclosed; tightening it
   would mean rebuilding the outcome group around a different concept.
   =========================================================================== */
CREATE TABLE IF NOT EXISTS public.ref_outcome_map (
    omop_outcome_name text PRIMARY KEY,
    outcome_group     text NOT NULL,
    note              text
);

/* Run FIRST and copy the exact strings -- 'OMOP Acute myocardial Infarction  1'
   contains a DOUBLE SPACE, and an invisible whitespace difference silently
   drops 102 pairs. */
-- SELECT DISTINCT "outcomeName", length("outcomeName") FROM public.omop_reference_set;

INSERT INTO public.ref_outcome_map (omop_outcome_name, outcome_group, note) VALUES
 ('OMOP Acute Liver Failure 1','ACUTE_LIVER_INJURY',
  'OMOP concept is liver FAILURE; our group is liver INJURY, which is broader. Disclosed mismatch.'),
 ('OMOP Acute Renal Failure 1','ACUTE_KIDNEY_INJURY','Direct correspondence'),
 ('OMOP Acute myocardial Infarction  1','ACUTE_MI','Direct correspondence. Source string has a double space.'),
 ('HOI Upper GI #3','UPPER_GI_BLEEDING','Direct correspondence; our group is scoped to UPPER GI to match')
ON CONFLICT (omop_outcome_name) DO NOTHING;

/* MUST return zero rows before proceeding. */
-- SELECT DISTINCT r."outcomeName"
-- FROM public.omop_reference_set r
-- WHERE NOT EXISTS (SELECT 1 FROM public.ref_outcome_map m
--                   WHERE m.omop_outcome_name = r."outcomeName");


/* ===========================================================================
   SECTION B — Exposure (drug) name map
   ===========================================================================
   ONE-TO-MANY by design. OMOP 'Amlodipine' resolves to AMLODIPINE,
   AMLODIPINE BESYLATE, AMLODIPINE MALEATE and AMLODIPINE MESYLATE. Exposure
   is cases mentioning ANY of them (2,055), not the base form alone (39).

   Picking only the largest form would be just as wrong as picking the base:
   the point is to reconstitute total exposure to the active moiety.

   Measured impact: fluticasone 71 -> 3,691; amlodipine 39 -> 2,055; and
   SERTRALINE and ESCITALOPRAM had NO exact match at all (1,742 and 711
   records recovered entirely through salt forms). Without this mapping those
   two would have scored zero cases and been guaranteed false negatives.
   =========================================================================== */
CREATE TABLE IF NOT EXISTS public.ref_exposure_map (
    omop_exposure_name text NOT NULL,   -- as it appears in omop_reference_set
    faers_ingredient   text NOT NULL,   -- must exist in mart_drug_totals
    match_type         text NOT NULL
                       CHECK (match_type IN ('exact','salt_ester','manual')),
    drug_total         integer,         -- volume at time of mapping
    note               text,            -- reasoning for reviewed decisions
    PRIMARY KEY (omop_exposure_name, faers_ingredient)
);

ALTER TABLE public.ref_exposure_map ADD COLUMN IF NOT EXISTS note text;

CREATE INDEX IF NOT EXISTS ref_exposure_map_ing
    ON public.ref_exposure_map (faers_ingredient);


/* --- B1. Auto-populate the mechanical matches -----------------------------
   'exact'      identical after upper/btrim
   'salt_ester' FAERS name is the OMOP name plus trailing words -- the salt or
                ester form of the same active moiety

   The prefix rule is safe in THIS direction because the OMOP name is the
   moiety: 'AMLODIPINE BESYLATE' starts with 'AMLODIPINE'. It would NOT be
   safe in reverse. It held for 45 of 46 multi-form drugs; the single failure
   (tenofovir) is corrected in B2.
   --------------------------------------------------------------------------- */
INSERT INTO public.ref_exposure_map (omop_exposure_name, faers_ingredient, match_type, drug_total)
SELECT DISTINCT
       r."exposureName",
       d.ingredient,
       CASE WHEN d.ingredient = upper(btrim(r."exposureName")) THEN 'exact'
            ELSE 'salt_ester' END,
       d.drug_total
FROM public.omop_reference_set r
JOIN public.mart_drug_totals d
  ON d.stratum = 'ALL'
 AND (d.ingredient = upper(btrim(r."exposureName"))
      OR d.ingredient LIKE upper(btrim(r."exposureName")) || ' %')
ON CONFLICT (omop_exposure_name, faers_ingredient) DO NOTHING;


/* --- B2. REVIEWED CORRECTION: tenofovir (FALSE MERGE) ---------------------
   The prefix rule pulled together seven forms across TWO DISTINCT PRODRUGS:
       TENOFOVIR DISOPROXIL FUMARATE (1015)   TDF
       TENOFOVIR ALAFENAMIDE FUMARATE (550)   TAF
       TENOFOVIR ALAFENAMIDE          (212)   TAF
       TENOFOVIR                      (159)   ambiguous
       TENOFOVIR DISOPROXIL           ( 39)   TDF
       + two singleton disoproxil salts

   TAF was developed SPECIFICALLY BECAUSE TDF causes renal and bone toxicity:
   lower plasma exposure, better safety profile. That difference is the entire
   clinical rationale for the drug existing, so the two are not name variants
   of one another. OMOP's tenofovir pairs predate TAF approval and refer to
   TDF. Merging would also dilute the TENOFOVIR DISOPROXIL / BONE DENSITY
   DECREASED signal independently surfaced by this pipeline.

   Bare 'TENOFOVIR' (159) is dropped too: prodrug-ambiguous. Costs volume,
   but every retained record is unambiguously TDF.

   This is the only false merge among 46 multi-form drugs, and it was
   detectable only with pharmacological knowledge -- no string rule finds it.
   --------------------------------------------------------------------------- */
DELETE FROM public.ref_exposure_map
WHERE omop_exposure_name ILIKE 'tenofovir'
  AND faers_ingredient NOT LIKE '%DISOPROXIL%';

UPDATE public.ref_exposure_map
SET note = 'Restricted to tenofovir DISOPROXIL. Alafenamide (TAF) is a distinct '
        || 'prodrug developed for lower renal/bone toxicity; merging would dilute '
        || 'the TDF signal. Bare "TENOFOVIR" also excluded as prodrug-ambiguous. '
        || 'OMOP pairs predate TAF approval.'
WHERE omop_exposure_name ILIKE 'tenofovir';


/* --- B3. REVIEWED CORRECTION: adenosine ----------------------------------
   ADENOSINE PHOSPHATE (AMP) is a different molecule, not a salt of adenosine.
   Only 1 record, so no material effect -- corrected for consistency with the
   active-moiety rule rather than for impact.
   --------------------------------------------------------------------------- */
DELETE FROM public.ref_exposure_map
WHERE omop_exposure_name ILIKE 'adenosine'
  AND faers_ingredient = 'ADENOSINE PHOSPHATE';

UPDATE public.ref_exposure_map
SET note = 'ADENOSINE PHOSPHATE (AMP) excluded: a distinct molecule, not a salt form.'
WHERE omop_exposure_name ILIKE 'adenosine';


/* --- B4. REVIEWED DECISIONS: merges kept, with reasoning recorded ---------
   Both are ester families where the forms differ pharmacokinetically but --
   unlike TDF/TAF -- no documented safety divergence is the reason the
   variants exist. Merged, and the judgment is recorded so a reader can
   disagree with it explicitly.
   --------------------------------------------------------------------------- */
UPDATE public.ref_exposure_map
SET note = 'Propionate and furoate esters merged. They differ in potency and '
        || 'receptor affinity, but neither exists because of a safety difference '
        || 'in the other, so the active moiety is the right grain here. '
        || 'Judgment call; contrast with tenofovir, which was NOT merged.'
WHERE omop_exposure_name ILIKE 'fluticasone';

UPDATE public.ref_exposure_map
SET note = 'Hemihydrate, acetate, valerate and cypionate esters merged. Valerate '
        || 'and cypionate are depot forms with quite different PK; merged on '
        || 'active-moiety grounds. Judgment call, disclosed.'
WHERE omop_exposure_name ILIKE 'estradiol';


/* --- B5. MANUAL ADDITIONS -------------------------------------------------
   Reference drugs the automatic rules missed because FAERS names them
   differently. Each verified individually against mart_drug_totals.
   --------------------------------------------------------------------------- */
INSERT INTO public.ref_exposure_map
    (omop_exposure_name, faers_ingredient, match_type, drug_total, note)
VALUES
 ('Estrogens, Conjugated (USP)','ESTROGENS, CONJUGATED','manual',304,
  'Punctuation and USP suffix only; same product'),
 ('lithium citrate','LITHIUM','manual',140,
  'Lithium ion is the active moiety; citrate is an inert counter-ion'),
 ('lithium citrate','LITHIUM CARBONATE','manual',64,
  'Same active moiety, different inert salt'),
 ('Factor VIIa','COAGULATION FACTOR VIIA RECOMBINANT HUMAN','manual',44,
  'Same product under the fuller FAERS name'),
 ('Epoetin Alfa','EPOETIN ALFA-EPBX','manual',40,
  'Biosimilar suffix; same active substance')
ON CONFLICT (omop_exposure_name, faers_ingredient) DO NOTHING;


/* ===========================================================================
   SECTION C — Documented exclusions
   ===========================================================================
   Candidates that a fuzzy or embedding-based matcher would plausibly have 
   accepted, and which are wrong for pharmacological reasons a string cannot 
   see, plus a small number of correct correspondences dropped for insufficient 
   volume. Recorded so that "considered and rejected" is distinguishable from
   "never looked at".

   ** WHY A SEPARATE TABLE, unlike ref_outcome_groups **
   ref_outcome_groups stores exclusions as a tier because 03 filters on tier
   explicitly. ref_exposure_map is joined WITHOUT a match_type filter, so an
   'excluded' row there would silently be treated as a real mapping. Keeping
   exclusions in a separate table makes that bug impossible.
   =========================================================================== */
CREATE TABLE IF NOT EXISTS public.ref_exposure_exclusions (
    omop_exposure_name text NOT NULL,
    rejected_candidate text NOT NULL,
    drug_total         integer,
    rationale          text NOT NULL,
    PRIMARY KEY (omop_exposure_name, rejected_candidate)
);

INSERT INTO public.ref_exposure_exclusions
    (omop_exposure_name, rejected_candidate, drug_total, rationale)
VALUES
 ('Tenofovir','TENOFOVIR ALAFENAMIDE FUMARATE',550,
  'TAF is a distinct prodrug with a deliberately different renal/bone safety profile'),
 ('Tenofovir','TENOFOVIR ALAFENAMIDE',212,'Same reason as the fumarate form'),
 ('Tenofovir','TENOFOVIR',159,'Prodrug-ambiguous; cannot be attributed to TDF or TAF'),
 ('Adenosine','ADENOSINE PHOSPHATE',1,'AMP is a distinct molecule, not a salt of adenosine'),
 ('Epoetin Alfa','DARBEPOETIN ALFA',374,
  'Different drug. An engineered longer-acting analog, not a name variant. '
  'The largest trap in the candidate set -- a fuzzy matcher would likely accept it.'),
 ('Epoetin Alfa','METHOXY POLYETHYLENE GLYCOL-EPOETIN BETA',132,
  'Different drug (epoetin beta, pegylated)'),
 ('Factor VIIa','COAGULATION FACTOR VIII/VON WILLEBRAND',120,
  'Factor VIII is not Factor VIIa'),
 ('Factor VIIa','COAGULATION FACTOR VII HUMAN',19,
  'Factor VII is the zymogen; VIIa is the activated form'),
 ('Estrogens, Conjugated (USP)','ESTROGENS, ESTERIFIED',7,
  'Esterified estrogens are a different preparation from conjugated estrogens'),
 ('ferrous gluconate','FERROUS SULFATE',8,
  'Same iron moiety but too few records to matter; left unmapped for simplicity'),
 ('Mefenamate','MEFENAMIC ACID',4,
  'Correct correspondence but only 4 records; below any detection threshold')
ON CONFLICT (omop_exposure_name, rejected_candidate) DO NOTHING;


/* ===========================================================================
   SECTION D — Audit queries
   =========================================================================== */

/* D1. Multi-form drugs. Confirm every listed form is the same active moiety.
       After the corrections above, tenofovir should show ONLY disoproxil. */
-- SELECT omop_exposure_name,
--        count(*) AS n_forms,
--        sum(drug_total) AS combined_records,
--        string_agg(faers_ingredient || ' (' || drug_total || ')', ' | '
--                   ORDER BY drug_total DESC) AS forms
-- FROM public.ref_exposure_map
-- GROUP BY 1 HAVING count(*) > 1
-- ORDER BY sum(drug_total) DESC;

/* D2. Volume recovered by salt/ester mapping -- writeup material. */
-- SELECT omop_exposure_name,
--        sum(drug_total) FILTER (WHERE match_type = 'exact') AS exact_only,
--        sum(drug_total)                                     AS all_forms,
--        sum(drug_total)
--          - COALESCE(sum(drug_total) FILTER (WHERE match_type='exact'),0) AS recovered
-- FROM public.ref_exposure_map
-- GROUP BY 1 HAVING count(*) FILTER (WHERE match_type <> 'exact') > 0
-- ORDER BY recovered DESC LIMIT 30;

/* D3. Still-unmatched reference drugs. Expect obsolete products --
       alatrofloxacin (withdrawn 1999), pemoline, rosiglitazone, nefazodone.
       Their absence is a FINDING about a 2013 reference set aged against
       2025-26 data, not a gap to chase. */
-- SELECT DISTINCT r."exposureName", r."groundTruth"
-- FROM public.omop_reference_set r
-- WHERE NOT EXISTS (SELECT 1 FROM public.ref_exposure_map m
--                   WHERE m.omop_exposure_name = r."exposureName")
-- ORDER BY 1;

/* D4. Final coverage. Baseline was 121/165 positive and 158/234 negative
       on exact match alone. */
-- SELECT r."groundTruth",
--        count(*) AS pairs,
--        count(*) FILTER (WHERE EXISTS (
--            SELECT 1 FROM public.ref_exposure_map m
--            WHERE m.omop_exposure_name = r."exposureName")) AS mapped
-- FROM public.omop_reference_set r GROUP BY 1;

/* D5. Every reviewed decision in one place -- paste into the writeup. */
-- SELECT omop_exposure_name, 'INCLUDED' AS decision, faers_ingredient AS ingredient,
--        drug_total, note AS rationale
-- FROM public.ref_exposure_map WHERE note IS NOT NULL
-- UNION ALL
-- SELECT omop_exposure_name, 'EXCLUDED', rejected_candidate, drug_total, rationale
-- FROM public.ref_exposure_exclusions
-- ORDER BY 1, 2 DESC;

/* D6. Guard: nothing may appear in both tables. Must return zero rows. */
-- SELECT m.omop_exposure_name, m.faers_ingredient
-- FROM public.ref_exposure_map m
-- JOIN public.ref_exposure_exclusions e
--   ON lower(e.omop_exposure_name) = lower(m.omop_exposure_name)
--  AND e.rejected_candidate = m.faers_ingredient;
