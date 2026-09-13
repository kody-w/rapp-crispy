#!/bin/bash
# Parity check — the same fact must not be stated twice and differ.
#
# Every real bug in this project came from one fact living in two places:
#   * `version` pinned in manifest.json, index_entry.json AND the agent's
#     __manifest__ — hand-bumped four times in one day
#   * the dictionary default path, different in the CLI and in the agent, so the
#     agent silently ran with no vocabulary and wrote the wrong name
#   * loopback detection, narrower in the agent than in the CLI, so the twin
#     reported "not installed" on a machine that had a usable device
#   * a capability FACT asserted in soul.md that live_status contradicted
#
# Detection is the weaker cure — `tools/setversion.sh` is the generator that
# stops version drift at the source. This catches what a generator cannot: hand
# edits, and two implementations of one behaviour drifting apart.
#
#   ./tools/parity.sh          check
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
head_(){ printf '\n\033[1;36m%s\033[0m\n' "$*"; }

AGENT=rapp_crispy/singleton/rapp_crispy_agent.py
TWIN=rapp_crispy/twin/agents/rapp_crispy_agent.py

head_ "version — one value, three declarations"
mv=$(python3 -c "import json;print(json.load(open('rapp_crispy/manifest.json'))['version'])")
iv=$(python3 -c "import json;print(json.load(open('rapp_crispy/index_entry.json'))['version'])")
av=$(python3 -c "
import ast
t=ast.parse(open('$AGENT').read())
for n in t.body:
    if isinstance(n,ast.Assign) and any(getattr(x,'id',None)=='__manifest__' for x in n.targets):
        print(ast.literal_eval(n.value)['version'])")
printf '       manifest=%s index_entry=%s agent=%s\n' "$mv" "$iv" "$av"
[ "$mv" = "$iv" ] && [ "$mv" = "$av" ] \
  && ok "all three agree ($mv)" \
  || bad "version drift — use ./tools/setversion.sh <semver>, never edit by hand"

head_ "the twin agent is a copy of the singleton, not a fork"
if cmp -s "$AGENT" "$TWIN"; then ok "twin/agents matches singleton byte-for-byte"
else bad "twin agent has diverged from the singleton — recopy it"; fi

head_ "retired egg — immutable historical bytes"
egg_sha=$(shasum -a 256 rapp_crispy/eggs/rapp_crispy.egg | awk '{print $1}')
expected_egg_sha=f01295ae5c64ced135fbe33993b23b3d191045ecb46d66ea6fa0c6671ea55737
if [ "$egg_sha" = "$expected_egg_sha" ]; then ok "retired egg digest unchanged"
else bad "retired egg drift — expected $expected_egg_sha, got $egg_sha"; fi
if [ "${1:-}" = "--legacy-egg" ]; then
  if python3 - <<'PY'
import json, zipfile
with zipfile.ZipFile("rapp_crispy/eggs/rapp_crispy.egg") as archive:
    assert archive.testzip() is None
    assert archive.namelist() == [
        "EGG.json", "manifest.json", "state/README.md", "twin/VERSION",
        "twin/agents/rapp_crispy_agent.py", "twin/requirements.txt", "twin/soul.md"
    ]
    descriptor = json.loads(archive.read("EGG.json"))
    assert descriptor["schema"] == "rapp-egg/1.0"
    assert descriptor["version"] == "1.4.0"
PY
  then ok "legacy egg is readable and retains its historical 1.4.0 descriptor"
  else bad "legacy egg structure changed"; fi
elif [ -z "${1:-}" ]; then
  printf '       SKIP deep archive inspection; digest protection is always enforced.\n'
else
  bad "unknown parity option: $1"
fi

head_ "native app version — separate from the parent-owned public catalog"
if python3 - <<'PY'
import pathlib, plistlib, re
root = pathlib.Path("native")
with (root / "Resources/Info.plist").open("rb") as handle:
    version = plistlib.load(handle)["CFBundleShortVersionString"]
project = re.search(r'MARKETING_VERSION: "([^"]+)"', (root / "project.yml").read_text()).group(1)
core = re.search(r'current = "([^"]+)"', (root / "Sources/RAPPCrispyCore/Meeting.swift").read_text()).group(1)
assert version == project == core == "1.5.1", (version, project, core)
PY
then ok "native plist, XcodeGen and core agree (1.5.1)"
else bad "native version drift"; fi

head_ "CLI and agent must resolve the same defaults"
# dictionary: both must prefer their OWN dir, then a sibling rapp-voice install
for f in crispy "$AGENT"; do
  grep -q 'rappcrispy' "$f" && grep -q 'rappvoice' "$f" \
    && ok "$(basename "$f"): dictionary falls back across both installs" \
    || bad "$(basename "$f"): dictionary lookup disagrees with its counterpart"
done
# loopback detection: the agent must not be narrower than the CLI
cli_pat=$(grep -o "LOOPBACK_PATTERN=\"\${LOOPBACK_PATTERN:-[^}]*}\"" crispy | sed 's/.*:-//;s/}"//')
# split on | only — tokens may contain spaces ("teams audio")
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  grep -qi -- "$tok" "$AGENT" \
    && ok "agent recognises loopback token '$tok'" \
    || bad "agent misses loopback token '$tok' that the CLI matches"
done < <(printf '%s\n' "$cli_pat" | tr '|' '\n')
# engine: exactly one place decides, and live is never DFN
grep -qi 'file-to-file' "$AGENT" && ok "agent records why live cannot use DFN3" \
  || bad "agent does not state the live/offline engine split"

head_ "prose must not assert what a tool computes"
if grep -qiE 'needs an administrator password to install\.|is not installed on this' rapp_crispy/twin/soul.md; then
  bad "soul.md asserts a capability fact — it must tell the model to CHECK live_status"
else
  grep -q 'live_status' rapp_crispy/twin/soul.md \
    && ok "soul.md defers capability questions to live_status" \
    || bad "soul.md does not point at live_status"
fi

printf '\n%s\n' "$([ $fail -eq 0 ] && printf '\033[1mparity clean\033[0m' || printf '\033[1;31mparity FAILED\033[0m')"
exit $fail
