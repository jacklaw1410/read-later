#!/usr/bin/env python3
"""Validate contract fixtures and fixture block plans.

Checks:
1. Every contracts/fixtures/*.valid.json passes its schema.
   The schema is chosen by file-name prefix:
   block-plan.* -> contracts/block-plan.v1.json,
   pack-manifest.* -> contracts/pack-manifest.v1.json.
2. Every contracts/fixtures/invalid/*.invalid.json FAILS its schema.
   An invalid fixture that passes is an error: it proves nothing.
3. Every fixtures/pages/*.html with a sibling *.blockplan.json gets that
   plan validated against the block-plan schema, and the plan's `source`
   and `source_sha256` must match the HTML file on disk.
4. Every entry in fixtures/manifest.json must exist on disk with a
   matching sha256.

Exits non-zero on the first failure class found, printing the file and
the JSON pointer for each problem. Python 3.12, `jsonschema` package.
"""

import hashlib
import json
import sys
from pathlib import Path

try:
    import jsonschema
    from jsonschema import Draft202012Validator
except ImportError:
    print("error: the `jsonschema` package is missing. Install it first:")
    print("  pip install jsonschema")
    sys.exit(2)

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS_DIR = ROOT / "contracts"
FIXTURES_DIR = ROOT / "fixtures"

SCHEMAS = {
    "block-plan": CONTRACTS_DIR / "block-plan.v1.json",
    "pack-manifest": CONTRACTS_DIR / "pack-manifest.v1.json",
}

failures: list[str] = []


def pointer(error: jsonschema.ValidationError) -> str:
    parts = [str(p) for p in error.absolute_path]
    return "/" + "/".join(parts) if parts else "/"


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except json.JSONDecodeError as e:
        return None, f"{path}: invalid JSON: {e}"
    except OSError as e:
        return None, f"{path}: unreadable: {e}"


def check_valid(schema_name: str, path: Path, validator: Draft202012Validator) -> None:
    doc, err = load_json(path)
    if err:
        failures.append(err)
        return
    for error in validator.iter_errors(doc):
        failures.append(f"{path}: {pointer(error)}: {error.message}")


def check_invalid(schema_name: str, path: Path, validator: Draft202012Validator) -> None:
    doc, err = load_json(path)
    if err:
        failures.append(err)
        return
    errors = list(validator.iter_errors(doc))
    if not errors:
        failures.append(f"{path}: invalid fixture PASSED validation; it must be rejected")


def main() -> int:
    validators = {}
    for name, schema_path in SCHEMAS.items():
        schema, err = load_json(schema_path)
        if err:
            failures.append(err)
            continue
        validators[name] = Draft202012Validator(schema)

    if failures:
        return report()

    fixture_dir = CONTRACTS_DIR / "fixtures"
    for path in sorted(fixture_dir.glob("*.json")):
        # Match "<contract>.<label>.json" against the contract prefix.
        matched = next((c for c in SCHEMAS if path.stem == c or path.stem.startswith(c + ".")), None)
        if matched is None:
            failures.append(f"{path}: no schema matches this fixture name")
            continue
        check_valid(matched, path, validators[matched])

    invalid_dir = fixture_dir / "invalid"
    if invalid_dir.is_dir():
        for path in sorted(invalid_dir.glob("*.json")):
            matched = next((c for c in SCHEMAS if path.stem == c or path.stem.startswith(c + ".")), None)
            if matched is None:
                failures.append(f"{path}: no schema matches this fixture name")
                continue
            check_invalid(matched, path, validators[matched])

    # Sibling block plans beside the committed pages. Absence is fine:
    # plans land with the extractor, which is not implemented yet.
    pages_dir = FIXTURES_DIR / "pages"
    block_validator = validators.get("block-plan")
    for html_path in sorted(pages_dir.glob("*.html")):
        plan_path = html_path.with_suffix(".blockplan.json")
        if not plan_path.exists():
            continue
        doc, err = load_json(plan_path)
        if err:
            failures.append(err)
            continue
        for error in block_validator.iter_errors(doc):
            failures.append(f"{plan_path}: {pointer(error)}: {error.message}")
        raw = html_path.read_bytes()
        digest = hashlib.sha256(raw).hexdigest()
        if doc.get("source") != html_path.name:
            failures.append(
                f"{plan_path}: /source: {doc.get('source')!r} does not match {html_path.name!r}"
            )
        if doc.get("source_sha256") != digest:
            failures.append(
                f"{plan_path}: /source_sha256: digest does not match {html_path.name}"
            )

    # The pages manifest must describe exactly what is on disk.
    manifest_path = FIXTURES_DIR / "manifest.json"
    manifest, err = load_json(manifest_path)
    if err:
        failures.append(err)
    else:
        for entry in manifest.get("pages", []):
            page_path = FIXTURES_DIR / entry.get("file", "")
            if not page_path.exists():
                failures.append(f"{manifest_path}: /pages: missing file {entry.get('file')!r}")
                continue
            digest = hashlib.sha256(page_path.read_bytes()).hexdigest()
            if digest != entry.get("sha256"):
                failures.append(
                    f"{manifest_path}: /pages: sha256 mismatch for {entry.get('file')!r}"
                )

    return report()


def report() -> int:
    if failures:
        print(f"{len(failures)} validation failure(s):")
        for f in failures:
            print(f"  {f}")
        return 1
    print("contracts OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
