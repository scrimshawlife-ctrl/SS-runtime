#!/usr/bin/env bash
# SS-specs parity guard (D-061, D-065).
#
# The runtime bundles its contracts and fixtures under
# Sources/SurveillanceCore/Resources/{contracts,fixtures}. D-061 makes the
# specification the authority those bundles must byte-match, and this guard
# makes that rule executable: it checks out SS-specs at the pinned commit and
# byte-compares every bundled file, failing on any mismatch or on any file
# absent at the pin.
#
# Fail conditions:
#   1. any identity source (SPEC_BASELINE.md, ContractVersions.swift,
#      SPEC_PIN.txt, asset-catalog-001.json) disagrees with the pin — the pin
#      must move in all places at once or the bundle's own loader would fail
#      closed, so a one-place move is a bug, not a preference;
#   2. a bundled contract or fixture differs from the spec copy by even one
#      byte;
#   3. a file SS-specs names at the pin is not bundled here.
#
# Known exception (asserted, not blind):
#   * The runtime asset-catalog-001.json differs from the spec copy in exactly
#     one field, specificationCommit. D-065 records why: the spec copy keeps
#     the adoption source (the commit whose entries were adopted), while the
#     runtime copy tracks the pinned spec commit, which AssetCatalog validation
#     requires to equal ContractVersions.specificationCommit. The guard proves
#     the exception is exactly that one field and nothing more: it compares
#     the two files after blanking that field, so a second divergence fails.
set -euo pipefail
cd "$(dirname "$0")/.."

PIN="$(awk '/^SS-specs commit/{print $3}' Sources/SurveillanceCore/Resources/SPEC_PIN.txt)"
if [[ ! "$PIN" =~ ^[0-9a-f]{40}$ ]]; then
  echo "parity: SPEC_PIN.txt does not carry a 40-hex commit: '${PIN}'"
  exit 1
fi
echo "parity: pin is $PIN"

status=0

# 1. Identity agreement across all pin sources.
grep -q "$PIN" SPEC_BASELINE.md || { echo "parity: SPEC_BASELINE.md does not record the pinned commit"; status=1; }
grep -q "specificationCommit = \"$PIN\"" Sources/SurveillanceCore/ContractVersions.swift || {
  echo "parity: ContractVersions.swift disagrees with the pin"
  status=1
}
python3 - "$PIN" <<'PY' || status=1
import json, sys
pin = sys.argv[1]
doc = json.load(open("Sources/SurveillanceCore/Resources/contracts/asset-catalog-001.json"))
got = doc.get("specificationCommit")
if got != pin:
    print(f"parity: asset-catalog-001.json specificationCommit is {got!r}, pin is {pin}")
    sys.exit(1)
PY

# 2 + 3. Byte parity against SS-specs at the pin (both directions).
rm -rf /tmp/spec-parity-check
git init -q /tmp/spec-parity-check
git -C /tmp/spec-parity-check remote add origin https://github.com/scrimshawlife-ctrl/SS-specs.git
git -C /tmp/spec-parity-check fetch -q --depth 1 origin "$PIN"
git -C /tmp/spec-parity-check checkout -q FETCH_HEAD

while IFS= read -r bundled; do
  rel="${bundled#Sources/SurveillanceCore/Resources/}"
  spec="spec-parity-check/$rel"
  if [ ! -f "/tmp/$spec" ]; then
    echo "parity: bundled $rel is absent at the pinned spec commit $PIN"
    status=1
    continue
  fi
  if [ "$rel" = "contracts/asset-catalog-001.json" ]; then
    # The one documented exception, asserted exactly: byte-identical after
    # blanking the specificationCommit field on both sides.
    blank() {
      python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
d['specificationCommit'] = '*'
sys.stdout.write(json.dumps(d, sort_keys=True, separators=(',', ':')))
" "$1"
    }
    if [ "$(blank "$bundled")" != "$(blank "/tmp/$spec")" ]; then
      echo "parity: $rel differs from the spec copy beyond the documented specificationCommit exception"
      status=1
    fi
  elif ! cmp -s "$bundled" "/tmp/$spec"; then
    echo "parity: bundled $rel differs from SS-specs@$PIN (one-byte drift fails by design)"
    status=1
  fi
done < <(find Sources/SurveillanceCore/Resources/contracts Sources/SurveillanceCore/Resources/fixtures -type f -name '*.json' | sort)

while IFS= read -r specfile; do
  if [ ! -f "Sources/SurveillanceCore/Resources/$specfile" ]; then
    echo "parity: spec $specfile exists at the pin but is not bundled"
    status=1
  fi
done < <(cd /tmp/spec-parity-check && find contracts fixtures -type f -name '*.json' | sort)

if [ "$status" -eq 0 ]; then
  echo "parity: OK — every bundled contract and fixture byte-matches SS-specs@$PIN"
else
  echo "parity: FAILED"
fi
exit "$status"
