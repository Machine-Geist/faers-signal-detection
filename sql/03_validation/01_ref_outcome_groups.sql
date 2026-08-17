/* ============================================================================
   01 — ref_outcome_groups : custom MedDRA PT groupings
   ============================================================================
   PURPOSE   Maps MedDRA Preferred Terms to the broader clinical outcomes used
             by published reference sets.
   GRAIN     One row per (outcome_group, reaction_pt, tier).
   DEPENDS   mart_reaction_totals (for validation)
   FEEDS     02_validation_mappings.sql, 03_mart_validation_signals.sql

   ---------------------------------------------------------------------------
   WHY THIS IS NEEDED
   ---------------------------------------------------------------------------
   The OMOP reference set defines outcomes as clinical concepts -- acute liver
   injury, acute kidney injury, acute MI, GI bleeding. FAERS codes reactions as
   MedDRA Preferred Terms, and one clinical concept maps to DOZENS of PTs. No
   single PT carries enough volume to serve as the outcome.

   MedDRA ships Standardised MedDRA Queries (SMQs) -- validated PT groupings
   for exactly this purpose -- but MedDRA is licensed and SMQs are not
   available here. This table is a hand-built substitute. That is a legitimate
   and common practice; it just has to be transparent, which is why every
   decision including EXCLUSIONS is recorded as a row.

   ---------------------------------------------------------------------------
   TIERS
   ---------------------------------------------------------------------------
   narrow    Clinical diagnoses only. Specific, defensible, lower volume.
   broad     narrow PLUS laboratory abnormalities. Higher volume, looser
             definition -- a transaminase elevation is a finding, not a
             diagnosis, and is often not clinically significant.
   excluded  Reviewed and rejected. Recorded so that "considered and rejected"
             is distinguishable from "never looked at".

   Score both tiers. If AUC is stable across them, the outcome definition does
   not drive the conclusion. If it is not, that instability is itself a result.

   ---------------------------------------------------------------------------
   ** TIER ASSIGNMENTS ARE JUDGMENT CALLS **
   The tier assignments below are a starting point based on the PTs present in
   this dataset. These are clinical judgment calls made without MedDRA license 
   access, every rationale is recorded, and a reader can disagree with any 
   specific assignment.
   
============================================================================ */

CREATE TABLE IF NOT EXISTS public.ref_outcome_groups (
    outcome_group text NOT NULL,
    reaction_pt   text NOT NULL,
    tier          text NOT NULL CHECK (tier IN ('narrow','broad','excluded')),
    rationale     text NOT NULL,
    PRIMARY KEY (outcome_group, reaction_pt)
);

CREATE INDEX IF NOT EXISTS ref_outcome_groups_lookup
    ON public.ref_outcome_groups (outcome_group, tier);


/* --- ACUTE LIVER INJURY ------------------------------------------------- */
INSERT INTO public.ref_outcome_groups (outcome_group, reaction_pt, tier, rationale) VALUES
 ('ACUTE_LIVER_INJURY','LIVER INJURY','narrow','Core clinical diagnosis'),
 ('ACUTE_LIVER_INJURY','DRUG-INDUCED LIVER INJURY','narrow','Core; explicitly drug-attributed'),
 ('ACUTE_LIVER_INJURY','HEPATOTOXICITY','narrow','Core clinical diagnosis'),
 ('ACUTE_LIVER_INJURY','HEPATIC FAILURE','narrow','Severe end of the spectrum'),
 ('ACUTE_LIVER_INJURY','ACUTE HEPATIC FAILURE','narrow','Severe, explicitly acute'),
 ('ACUTE_LIVER_INJURY','HEPATIC CYTOLYSIS','narrow','Hepatocellular injury pattern'),
 ('ACUTE_LIVER_INJURY','HEPATITIS','narrow','Included despite possible viral aetiology; inflates the group with non-drug-induced cases.'),
 ('ACUTE_LIVER_INJURY','JAUNDICE','narrow','Clinical manifestation of hepatic dysfunction'),
 ('ACUTE_LIVER_INJURY','HEPATIC ENZYME INCREASED','broad','Lab finding, not a diagnosis'),
 ('ACUTE_LIVER_INJURY','TRANSAMINASES INCREASED','broad','Lab finding'),
 ('ACUTE_LIVER_INJURY','LIVER FUNCTION TEST INCREASED','broad','Lab finding'),
 ('ACUTE_LIVER_INJURY','LIVER FUNCTION TEST ABNORMAL','broad','Lab finding'),
 ('ACUTE_LIVER_INJURY','HEPATIC FUNCTION ABNORMAL','broad','Nonspecific; may be lab-driven'),
 ('ACUTE_LIVER_INJURY','HYPERBILIRUBINAEMIA','broad','Lab finding'),
 ('ACUTE_LIVER_INJURY','LIVER DISORDER','broad','Too nonspecific for the narrow tier'),
 ('ACUTE_LIVER_INJURY','METASTASES TO LIVER','excluded','Oncologic progression, not drug injury. Including it would make every oncology drug a hepatotoxin.'),
 ('ACUTE_LIVER_INJURY','HEPATIC CIRRHOSIS','excluded','Chronic; outcome of interest is acute'),
 ('ACUTE_LIVER_INJURY','HEPATIC STEATOSIS','excluded','Chronic/metabolic, distinct mechanism')
ON CONFLICT (outcome_group, reaction_pt) DO NOTHING;


/* --- ACUTE KIDNEY INJURY ------------------------------------------------ */
INSERT INTO public.ref_outcome_groups (outcome_group, reaction_pt, tier, rationale) VALUES
 ('ACUTE_KIDNEY_INJURY','ACUTE KIDNEY INJURY','narrow','Anchor term'),
 ('ACUTE_KIDNEY_INJURY','RENAL FAILURE','narrow','Core clinical diagnosis'),
 ('ACUTE_KIDNEY_INJURY','RENAL IMPAIRMENT','narrow','Core, though acuity is not specified in the term -- flagged'),
 ('ACUTE_KIDNEY_INJURY','TUBULOINTERSTITIAL NEPHRITIS','narrow','Classic drug-induced renal injury pattern'),
 ('ACUTE_KIDNEY_INJURY','NEPHROPATHY TOXIC','narrow','Explicitly toxic aetiology'),
 ('ACUTE_KIDNEY_INJURY','RENAL TUBULAR NECROSIS','narrow','Specific injury pattern'),
 ('ACUTE_KIDNEY_INJURY','BLOOD CREATININE INCREASED','broad','Lab finding, not a diagnosis'),
 ('ACUTE_KIDNEY_INJURY','RENAL DISORDER','broad','Too nonspecific for the narrow tier'),
 ('ACUTE_KIDNEY_INJURY','NEPHROLITHIASIS','excluded','Kidney stones; mechanistically unrelated to AKI'),
 ('ACUTE_KIDNEY_INJURY','CHRONIC KIDNEY DISEASE','excluded','Chronic; outcome of interest is acute'),
 ('ACUTE_KIDNEY_INJURY','END STAGE RENAL DISEASE','excluded','Chronic endpoint'),
 ('ACUTE_KIDNEY_INJURY','KIDNEY INFECTION','excluded','Infectious aetiology'),
 ('ACUTE_KIDNEY_INJURY','PYELONEPHRITIS','excluded','Infectious aetiology'),
 ('ACUTE_KIDNEY_INJURY','RENAL PAIN','excluded','Symptom, not injury'),
 ('ACUTE_KIDNEY_INJURY','ADRENAL INSUFFICIENCY','excluded','Regex artifact -- ADRENAL contains RENAL. Not a renal outcome.')
ON CONFLICT (outcome_group, reaction_pt) DO NOTHING;

/* --- UPPER GI BLEEDING ------------------------------------------------ */
INSERT INTO public.ref_outcome_groups (outcome_group, reaction_pt, tier, rationale) VALUES
 ('UPPER_GI_BLEEDING','GASTROINTESTINAL HAEMORRHAGE','narrow','Core term'),
 ('UPPER_GI_BLEEDING','UPPER GASTROINTESTINAL HAEMORRHAGE','narrow','Core; exactly the OMOP outcome'),
 ('UPPER_GI_BLEEDING','HAEMATEMESIS','narrow','Vomiting blood — unambiguous upper GI'),
 ('UPPER_GI_BLEEDING','MELAENA','narrow','Black tarry stool — unambiguous upper GI'),
 ('UPPER_GI_BLEEDING','ULCER HAEMORRHAGE','narrow','Bleeding explicitly stated'),
 ('UPPER_GI_BLEEDING','GASTRIC ULCER','broad','Lesion without stated bleeding'),
 ('UPPER_GI_BLEEDING','DUODENAL ULCER PERFORATION','broad','Perforation is a distinct complication from haemorrhage'),
 ('UPPER_GI_BLEEDING','HAEMATOCHEZIA','excluded','Lower GI bleeding. OMOP outcome is UPPER GI; broadening would break correspondence with the ground truth.'),
 ('UPPER_GI_BLEEDING','RECTAL HAEMORRHAGE','excluded','Lower GI bleeding — same reason'),
 ('UPPER_GI_BLEEDING','DIARRHOEA HAEMORRHAGIC','excluded','Lower GI'),
 ('UPPER_GI_BLEEDING','HAEMORRHAGE','excluded','Site unspecified; cannot attribute to upper GI'),
 ('UPPER_GI_BLEEDING','INTERNAL HAEMORRHAGE','excluded','Site unspecified'),
 ('UPPER_GI_BLEEDING','SHOCK HAEMORRHAGIC','excluded','Consequence of bleeding, site unspecified'),
 ('UPPER_GI_BLEEDING','OESOPHAGITIS','excluded','Inflammation, not bleeding'),
 ('UPPER_GI_BLEEDING','EOSINOPHILIC OESOPHAGITIS','excluded','Allergic condition, not bleeding. Also a dupilumab indication (556 cases at 97.8% indication match) — would import a known artifact into the ground truth.'),
 ('UPPER_GI_BLEEDING','COLITIS ULCERATIVE','excluded','IBD, not bleeding. Major indication artifact (vedolizumab, 2,369 cases at 98.3%).'),
 ('UPPER_GI_BLEEDING','GASTROINTESTINAL DISORDER','excluded','Too nonspecific'),
 ('UPPER_GI_BLEEDING','IMPAIRED GASTRIC EMPTYING','excluded','Motility, unrelated mechanism'),
 ('UPPER_GI_BLEEDING','GASTROINTESTINAL PAIN','excluded','Symptom'),
 ('UPPER_GI_BLEEDING','GASTROINTESTINAL INFECTION','excluded','Infectious aetiology'),
 ('UPPER_GI_BLEEDING','ULCER','excluded','Site unspecified — could be skin, oral, or GI'),
 ('UPPER_GI_BLEEDING','SKIN ULCER','excluded','Wrong organ system'),
 ('UPPER_GI_BLEEDING','MOUTH ULCERATION','excluded','Wrong site')
ON CONFLICT (outcome_group, reaction_pt) DO NOTHING;
 
/* --- ACUTE MI -------------------------------------------------------- */
INSERT INTO public.ref_outcome_groups (outcome_group, reaction_pt, tier, rationale) VALUES
 ('ACUTE_MI','MYOCARDIAL INFARCTION','narrow','Anchor term'),
 ('ACUTE_MI','ACUTE MYOCARDIAL INFARCTION','narrow','Core; explicitly acute'),
 ('ACUTE_MI','CORONARY ARTERY OCCLUSION','broad','Plausible MI mechanism but infarction not stated'),
 ('ACUTE_MI','TROPONIN INCREASED','broad','Biomarker; elevated in many non-MI states'),
 ('ACUTE_MI','ANGINA PECTORIS','excluded','Ischaemia without infarction; OMOP outcome is acute MI'),
 ('ACUTE_MI','CORONARY ARTERY DISEASE','excluded','Chronic condition, not an acute event'),
 ('ACUTE_MI','TRANSIENT ISCHAEMIC ATTACK','excluded','Cerebrovascular, not coronary'),
 ('ACUTE_MI','CEREBRAL HAEMORRHAGE','excluded','CNS; different organ system'),
 ('ACUTE_MI','CEREBRAL INFARCTION','excluded','Stroke; different vascular bed'),
 ('ACUTE_MI','ISCHAEMIC STROKE','excluded','Stroke; different vascular bed'),
 ('ACUTE_MI','OPTIC ISCHAEMIC NEUROPATHY','excluded','Ocular; different vascular bed')
ON CONFLICT (outcome_group, reaction_pt) DO NOTHING;


/* --- VALIDATION --------------------------------------------------------- */

/* Every PT listed must actually exist, spelled identically. A typo silently
   drops the term from the outcome group and understates every metric. */
-- SELECT g.outcome_group, g.reaction_pt
-- FROM public.ref_outcome_groups g
-- WHERE NOT EXISTS (SELECT 1 FROM public.mart_reaction_totals r
--                   WHERE r.stratum='ALL' AND r.reaction_pt = g.reaction_pt);

/* Volume behind each outcome group, per tier. This is the power check:
   an outcome group with too few cases cannot support validation regardless
   of how well the reference pairs are curated. */
-- SELECT g.outcome_group,
--        count(*) FILTER (WHERE g.tier = 'narrow') AS narrow_pts,
--        count(*) FILTER (WHERE g.tier IN ('narrow','broad')) AS broad_pts,
--        sum(r.reaction_total) FILTER (WHERE g.tier = 'narrow') AS narrow_cases,
--        sum(r.reaction_total) FILTER (WHERE g.tier IN ('narrow','broad')) AS broad_cases
-- FROM public.ref_outcome_groups g
-- JOIN public.mart_reaction_totals r ON r.stratum='ALL' AND r.reaction_pt = g.reaction_pt
-- WHERE g.tier <> 'excluded'
-- GROUP BY 1 ORDER BY 1;

/* Documented exclusions */
-- SELECT outcome_group, reaction_pt, rationale
-- FROM public.ref_outcome_groups WHERE tier = 'excluded' ORDER BY 1,2;
