#!/bin/bash
# The version generator. One command writes every declaration, so `version` has a
# single source even though the store spec requires it in three files.
# Hand-editing any one of them is what tools/parity.sh exists to catch.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
V="${1:?usage: tools/setversion.sh <major.minor.patch>}"
echo "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "not semver: $V" >&2; exit 2; }

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

# rebuild the egg so it can never lag the version it claims
rm -rf .eggbuild && mkdir -p .eggbuild/state
cp -R rapp_crispy/twin .eggbuild/twin
cp rapp_crispy/manifest.json .eggbuild/
printf 'Intentionally empty. A hatched RAPP Crispy starts with no meetings,\nno transcripts and no vocabulary.\n' > .eggbuild/state/README.md
python3 - "$V" <<'PY'
import json, sys
json.dump({"schema": "rapp-egg/1.0", "id": "rapp_crispy", "version": sys.argv[1],
           "runtime": "twin", "publisher": "@kody-w",
           "contains": ["twin/soul.md", "twin/agents/rapp_crispy_agent.py",
                        "manifest.json", "state/"],
           "state": "empty", "pii": "none",
           "note": ("Hatch cartridge only. No recordings, transcripts, vocabulary, "
                    "credentials or personal paths.")},
          open('.eggbuild/EGG.json', 'w'), indent=2)
PY
# Packed by the canonical deterministic packer, NOT by `zip`. `zip` stamps each
# entry with its mtime, so two packs of identical content produced different
# bytes and the published egg_sha256 matched nothing. Hard-fail rather than fall
# back: a silently non-reproducible egg is the bug this replaced.
PACK=""
for c in "$PWD/../rapp-tools/tools/packegg.py" "${RAPPTOOLS_HOME:-}/tools/packegg.py"; do
  [ -f "$c" ] && { PACK="$c"; break; }
done
if [ -z "$PACK" ]; then
  echo "cannot find packegg.py — clone kody-w/rapp-tools beside this repo, or set" >&2
  echo "RAPPTOOLS_HOME. Refusing to pack a non-reproducible egg with plain zip." >&2
  exit 1
fi
rm -f rapp_crispy/eggs/rapp_crispy.egg
python3 "$PACK" .eggbuild rapp_crispy/eggs/rapp_crispy.egg
rm -rf .eggbuild
echo "NOTE: run rapp-tools/tools/rebuild-eggs.sh to restamp the catalogue digest." 
