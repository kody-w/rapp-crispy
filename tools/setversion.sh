#!/bin/bash
# Update active integration version declarations. The retired egg is immutable
# historical evidence and this script verifies, but never rewrites, its bytes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
V="${1:?usage: tools/setversion.sh <major.minor.patch>}"
echo "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "not semver: $V" >&2; exit 2; }
EGG="rapp_crispy/eggs/rapp_crispy.egg"
EGG_SHA256="f01295ae5c64ced135fbe33993b23b3d191045ecb46d66ea6fa0c6671ea55737"
verify_egg() {
  local actual
  actual=$(/usr/bin/shasum -a 256 "$EGG" | awk '{print $1}')
  [ "$actual" = "$EGG_SHA256" ] || {
    echo "retired egg drift: expected $EGG_SHA256, got $actual" >&2
    exit 1
  }
}
verify_egg

python3 - "$V" <<'PY'
import json, re, sys
v = sys.argv[1]
for p in ('rapp_crispy/manifest.json', 'rapp_crispy/index_entry.json'):
    d = json.load(open(p)); d['version'] = v
    json.dump(d, open(p, 'w'), indent=2); open(p, 'a').write('\n')
p = 'rapp_crispy/singleton/rapp_crispy_agent.py'
s = open(p).read()
s = re.sub(r'("version":\s*)"\d+\.\d+\.\d+"', lambda m: m.group(1) + f'"{v}"', s, count=1)
open(p, 'w').write(s)
print(f"version -> {v}  (manifest, index_entry, agent __manifest__)")
PY
cp rapp_crispy/singleton/rapp_crispy_agent.py rapp_crispy/twin/agents/rapp_crispy_agent.py

verify_egg
echo "retired egg unchanged ($EGG_SHA256)"
echo "NOTE: native product/build versions are maintained separately in native/."
