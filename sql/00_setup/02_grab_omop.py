#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Retrieve the OMOP drug-outcome reference set and write it to CSV.

The OMOP reference set is the external ground truth used to validate this
pipeline's disproportionality signals. It is distributed as an .rda (R data)
file inside the OHDSI MethodEvaluation package; this script downloads it,
converts it to CSV, and verifies the contents match the published standard.

    Ryan PB, Schuemie MJ, Welebob E, Duke J, Valentine S, Hartzema AG.
    Defining a reference set to support methodological research in drug
    safety. Drug Safety. 2013;36(Suppl 1):S33-47.

Requires:  pip install pyreadr pandas
Usage:     python 02_grab_omop.py
Output:    omop_reference_set.csv  (import into public.omop_reference_set)
"""

import sys
import urllib.error
import urllib.request
from pathlib import Path

import pyreadr

# --- Configuration -----------------------------------------------------------

# Pin the source revision. "main" tracks the latest upstream state, which means
# the reference set can change without warning and silently invalidate every
# validation figure in the report. Replace with a commit SHA to freeze it:
#   https://github.com/OHDSI/MethodEvaluation/commits/main/data/omopReferenceSet.rda
GITHUB_REF = "main"

SOURCE_URL = (
    f"https://github.com/OHDSI/MethodEvaluation/raw/{GITHUB_REF}"
    "/data/omopReferenceSet.rda"
)

OUTPUT_DIR = Path(__file__).parent
RDA_PATH = OUTPUT_DIR / "omopReferenceSet.rda"
CSV_PATH = OUTPUT_DIR / "omop_reference_set.csv"

# Published contents of the reference set. A mismatch means upstream changed.
EXPECTED_TOTAL = 399
EXPECTED_POSITIVE = 165
EXPECTED_NEGATIVE = 234
EXPECTED_OUTCOMES = 4

KEEP_RDA = False  # set True to retain the intermediate .rda file


# --- Retrieval ---------------------------------------------------------------

def download(url: str, dest: Path) -> None:
    print(f"Downloading {url}")
    try:
        urllib.request.urlretrieve(url, dest)
    except urllib.error.HTTPError as e:
        sys.exit(
            f"ERROR: HTTP {e.code} fetching the reference set.\n"
            f"       The upstream path may have moved. Check:\n"
            f"       https://github.com/OHDSI/MethodEvaluation/tree/main/data"
        )
    except urllib.error.URLError as e:
        sys.exit(f"ERROR: could not reach GitHub ({e.reason}).")
    print(f"  -> {dest.name} ({dest.stat().st_size:,} bytes)")


def convert(rda: Path):
    result = pyreadr.read_r(str(rda))
    if "omopReferenceSet" not in result:
        sys.exit(
            f"ERROR: expected an 'omopReferenceSet' object in {rda.name}, "
            f"found: {list(result.keys())}"
        )
    return result["omopReferenceSet"]


# --- Validation --------------------------------------------------------------

def validate(df) -> bool:
    """Compare against the published reference set. Warn, do not fail."""
    total = len(df)
    positive = int((df["groundTruth"] == 1).sum())
    negative = int((df["groundTruth"] == 0).sum())
    outcomes = df["outcomeName"].nunique()
    drugs = df["exposureName"].nunique()

    print("\nContents:")
    print(f"  total pairs        {total:>5}   (expected {EXPECTED_TOTAL})")
    print(f"  positive controls  {positive:>5}   (expected {EXPECTED_POSITIVE})")
    print(f"  negative controls  {negative:>5}   (expected {EXPECTED_NEGATIVE})")
    print(f"  distinct outcomes  {outcomes:>5}   (expected {EXPECTED_OUTCOMES})")
    print(f"  distinct drugs     {drugs:>5}")

    ok = (
        total == EXPECTED_TOTAL
        and positive == EXPECTED_POSITIVE
        and negative == EXPECTED_NEGATIVE
        and outcomes == EXPECTED_OUTCOMES
    )
    if not ok:
        print(
            "\nWARNING: contents differ from the published reference set.\n"
            "         Upstream has changed since this pipeline was validated.\n"
            "         Validation metrics will not reproduce the reported\n"
            "         figures. Pin GITHUB_REF to a known commit to fix this.",
            file=sys.stderr,
        )
    return ok


# --- Main --------------------------------------------------------------------

def main() -> int:
    download(SOURCE_URL, RDA_PATH)
    df = convert(RDA_PATH)
    matches = validate(df)

    df.to_csv(CSV_PATH, index=False)
    print(f"\nWrote {CSV_PATH.name} ({len(df):,} rows)")
    print("Next: import into public.omop_reference_set (see README, step 6)")

    if not KEEP_RDA:
        RDA_PATH.unlink(missing_ok=True)

    return 0 if matches else 1


if __name__ == "__main__":
    sys.exit(main())
