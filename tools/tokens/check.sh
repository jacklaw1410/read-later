#!/bin/sh
# Fail when a generated token file is older than design/tokens.json.
# Run before a commit that touches design/, or in CI.
set -eu
cd "$(dirname "$0")/../.."
python3 tools/tokens/generate.py --check
python3 - <<'PY'
import xml.etree.ElementTree as ET
ET.parse("design/generated/Tokens.xaml")
print("xaml: well-formed")
PY
