#!/usr/bin/env python3
"""
pubchem_structure_resolver.py

Fetch a chemically meaningful structure from PubChem.

Purpose
-------
Some PubChem entries are not single, finite molecules. Polymers, mixtures, and
material-like records may contain wildcard attachment points, which often appear
as '?' or open polymer endpoints in 2D drawings.

This script does two things:

  1. For discrete compounds:
     - fetches the PubChem record,
     - prints core identifiers,
     - downloads an SDF,
     - renders a PNG.

  2. For generic/polymeric records:
     - flags the record as generic,
     - renders the generic structure if possible,
     - resolves known special cases to chemically meaningful component
       structures.

Known special case
------------------
povidone-iodine / iodopovidone / betadine / batikon / baticon / batticon

For this case, the script resolves:
  - iodine (CID 807),
  - N-vinyl-2-pyrrolidone (CID 6917),
  - an approximate repeat-unit SMILES for the PVP backbone:
      [*]CC(N1CCCC(=O)1)[*]

Examples
--------
python pubchem_structure_resolver.py "aspirin"
python pubchem_structure_resolver.py "povidone-iodine"
python pubchem_structure_resolver.py "betadine"
python pubchem_structure_resolver.py "N-vinyl-2-pyrrolidone"
python pubchem_structure_resolver.py "807" --namespace cid
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import pubchempy as pcp
import requests
from rdkit import Chem
from rdkit.Chem import Draw


PUBCHEM_SDF_URL = (
  "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/{cid}/SDF"
  "?record_type=2d"
)

SPECIAL_CASES = {
  "povidone-iodine": {
    "components": [
      {"name": "iodine", "cid": 807},
      {"name": "N-vinyl-2-pyrrolidone", "cid": 6917},
    ],
    "repeat_unit_smiles": "[*]CC(N1CCCC(=O)1)[*]",
    "repeat_unit_name": "poly(N-vinyl-2-pyrrolidone)_repeat_unit",
  },
  "povidone iodine": "povidone-iodine",
  "iodopovidone": "povidone-iodine",
  "betadine": "povidone-iodine",
  "batikon": "povidone-iodine",
  "baticon": "povidone-iodine",
  "batticon": "povidone-iodine",
}


def normalize_text(text: str) -> str:
  """Normalize a query string for dictionary lookup."""
  return re.sub(r"\s+", " ", text.strip().lower())


def slugify(text: str) -> str:
  """Make a filesystem-safe stem."""
  text = text.strip().lower()
  text = re.sub(r"[^a-z0-9._-]+", "_", text)
  text = re.sub(r"_+", "_", text)
  return text.strip("_") or "pubchem_record"


def resolve_special_case_key(query: str) -> str | None:
  """Return canonical special-case key, if known."""
  key = normalize_text(query)
  if key not in SPECIAL_CASES:
    return None

  value = SPECIAL_CASES[key]
  if isinstance(value, str):
    return value

  return key


def fetch_compound(identifier: str, namespace: str) -> pcp.Compound:
  """Fetch a PubChem compound by name or CID."""
  if namespace == "cid":
    cid = int(identifier)
    return pcp.Compound.from_cid(cid)

  compounds = pcp.get_compounds(identifier, "name")
  if not compounds:
    raise LookupError(f"No PubChem compound found for: {identifier!r}")

  return compounds[0]


def best_smiles(compound: pcp.Compound) -> str | None:
  """
  Return the best available SMILES representation.

  PubChemPy 1.0.5 prefers:
    - smiles
    - connectivity_smiles
  Older compatibility names are checked as fallback.
  """
  for attr in (
    "smiles",
    "connectivity_smiles",
    "isomeric_smiles",
    "canonical_smiles",
  ):
    value = getattr(compound, attr, None)
    if value:
      return str(value)

  return None


def is_generic_or_polymeric(
  compound: pcp.Compound,
  smiles: str | None,
) -> bool:
  """
  Heuristic detection of generic/material/polymer-like structures.

  The strongest signal is a wildcard attachment point '*' in the SMILES.
  """
  if smiles and "*" in smiles:
    return True

  formula = str(getattr(compound, "molecular_formula", "") or "")
  if re.search(r"[nx]", formula):
    return True

  iupac_name = str(getattr(compound, "iupac_name", "") or "").lower()
  generic_words = (
    "polymer",
    "homopolymer",
    "copolymer",
    "mixture",
    "complex",
  )
  if any(word in iupac_name for word in generic_words):
    return True

  return False


def write_text(path: Path, text: str) -> None:
  """Write UTF-8 text to a file."""
  path.write_text(text, encoding="utf-8")


def download_sdf(cid: int, out_path: Path) -> str:
  """Download a 2D SDF for a PubChem CID and save it."""
  url = PUBCHEM_SDF_URL.format(cid=cid)
  response = requests.get(url, timeout=30)
  response.raise_for_status()
  sdf_text = response.text
  write_text(out_path, sdf_text)
  return sdf_text


def render_mol_to_png(mol: Chem.Mol, out_path: Path, size=(900, 600)) -> None:
  """Render an RDKit molecule to PNG."""
  if mol is None:
    raise ValueError("RDKit molecule is None; cannot render.")
  Draw.MolToFile(mol, str(out_path), size=size)


def render_smiles_to_png(smiles: str, out_path: Path) -> None:
  """Build an RDKit molecule from SMILES and render it."""
  mol = Chem.MolFromSmiles(smiles)
  if mol is None:
    raise ValueError(f"Could not parse SMILES: {smiles}")
  render_mol_to_png(mol, out_path)


def build_summary(compound: pcp.Compound, query: str) -> str:
  """Create a plain-text summary of the PubChem record."""
  smiles = best_smiles(compound)

  lines = [
    f"Query              : {query}",
    f"CID                : {compound.cid}",
    f"IUPAC name         : {compound.iupac_name}",
    f"Molecular formula  : {compound.molecular_formula}",
    f"Molecular weight   : {compound.molecular_weight}",
    f"SMILES             : {smiles}",
    f"InChI              : {compound.inchi}",
    f"InChIKey           : {compound.inchikey}",
    f"Generic/polymeric? : {is_generic_or_polymeric(compound, smiles)}",
  ]
  return "\n".join(lines) + "\n"


def save_discrete_record(
  compound: pcp.Compound,
  stem: str,
  outdir: Path,
) -> None:
  """Save SDF, PNG, and summary for a discrete or generic record."""
  summary_path = outdir / f"{stem}.summary.txt"
  sdf_path = outdir / f"{stem}.pubchem.sdf"
  png_path = outdir / f"{stem}.pubchem.png"

  write_text(summary_path, build_summary(compound, stem))

  sdf_text = None
  try:
    sdf_text = download_sdf(int(compound.cid), sdf_path)
  except Exception as exc:
    print(f"[warn] Could not download SDF for CID {compound.cid}: {exc}",
          file=sys.stderr)

  if sdf_text:
    mol = Chem.MolFromMolBlock(sdf_text, sanitize=True, removeHs=False)
    if mol is not None:
      render_mol_to_png(mol, png_path)
      return

  smiles = best_smiles(compound)
  if smiles:
    render_smiles_to_png(smiles, png_path)


def save_component_by_cid(
  cid: int,
  name: str,
  outdir: Path,
) -> None:
  """Fetch a component compound by CID and save its structure files."""
  compound = pcp.Compound.from_cid(cid)
  stem = slugify(name)
  save_discrete_record(compound, stem, outdir)


def save_repeat_unit(
  smiles: str,
  name: str,
  outdir: Path,
) -> None:
  """Save a polymer repeat-unit representation from a SMILES string."""
  stem = slugify(name)
  summary_path = outdir / f"{stem}.summary.txt"
  png_path = outdir / f"{stem}.png"
  smi_path = outdir / f"{stem}.smiles.txt"

  write_text(summary_path, f"Name   : {name}\nSMILES : {smiles}\n")
  write_text(smi_path, smiles + "\n")
  render_smiles_to_png(smiles, png_path)


def resolve_special_case(query: str, outdir: Path) -> bool:
  """
  Resolve known material-like entries into meaningful component structures.

  Returns True if a special case was handled.
  """
  key = resolve_special_case_key(query)
  if key is None:
    return False

  payload = SPECIAL_CASES[key]
  if isinstance(payload, str):
    payload = SPECIAL_CASES[payload]

  note = (
    "This PubChem entry is materially/polymerically generic.\n"
    "Saved chemically meaningful components and a repeat-unit depiction.\n"
  )
  write_text(outdir / "special_case_note.txt", note)

  for item in payload["components"]:
    save_component_by_cid(item["cid"], item["name"], outdir)

  save_repeat_unit(
    payload["repeat_unit_smiles"],
    payload["repeat_unit_name"],
    outdir,
  )

  return True


def parse_args() -> argparse.Namespace:
  """Parse command-line arguments."""
  parser = argparse.ArgumentParser(
    description=(
      "Fetch a meaningful chemical structure from PubChem. Handles ordinary "
      "compounds directly, and known polymeric/material-like records via "
      "components or repeat units."
    )
  )

  parser.add_argument(
    "query",
    help="PubChem name/text query or CID, depending on --namespace.",
  )

  parser.add_argument(
    "--namespace",
    choices=("name", "cid"),
    default="name",
    help="Interpret query as a compound name or CID. Default: name",
  )

  parser.add_argument(
    "-o",
    "--outdir",
    default="pubchem_structure_output",
    help="Output directory. Default: ./pubchem_structure_output",
  )

  return parser.parse_args()


def main() -> int:
  """CLI entry point."""
  args = parse_args()
  outdir = Path(args.outdir).expanduser().resolve()
  outdir.mkdir(parents=True, exist_ok=True)

  # First resolve any known polymer/material special case.
  handled = False
  if args.namespace == "name":
    handled = resolve_special_case(args.query, outdir)

  try:
    compound = fetch_compound(args.query, args.namespace)
  except Exception as exc:
    print(f"[error] Could not fetch PubChem record: {exc}", file=sys.stderr)
    return 1

  stem = slugify(args.query)
  try:
    save_discrete_record(compound, stem, outdir)
  except Exception as exc:
    print(f"[error] Failed while saving main record: {exc}", file=sys.stderr)
    return 1

  smiles = best_smiles(compound)
  generic = is_generic_or_polymeric(compound, smiles)

  print(build_summary(compound, args.query), end="")
  print(f"Output directory   : {outdir}")

  if generic:
    print(
      "\n[info] This looks like a generic/polymeric/material-like record, "
      "not a single finite molecule."
    )

  if handled:
    print(
      "[info] Special-case resolution was applied. Component structures and "
      "repeat-unit files were also written."
    )

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
