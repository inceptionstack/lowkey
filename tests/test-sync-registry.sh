#!/usr/bin/env bash
# tests/test-sync-registry.sh — validate packs/registry.yaml → registry.json generator
#
# Covers:
#   - real repo: YAML and JSON stay in sync (no drift)
#   - --check mode detects drift and exits non-zero
#   - --check mode passes when JSON is regenerated
#   - Unicode (em-dash, etc.) is preserved literally, not \uXXXX-escaped
#   - per-pack fields (default_model, requires_openai_key, ports, deps arrays) round-trip
#   - missing or invalid YAML fails cleanly
#   - exits non-zero if jq / python3 disagree on the resulting JSON
#   - generated JSON is valid JSON (jq parse)
#   - generated JSON has stable byte-for-byte output (determinism)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${SCRIPT_DIR}"
SYNC="${REPO}/scripts/sync-registry"
YAML="${REPO}/packs/registry.yaml"
JSON="${REPO}/packs/registry.json"

# ── Colours / counters ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; C=""; N=""
fi
PASS=0
FAIL=0

header() { echo ""; echo "${C}── $* ──${N}"; }
pass()   { echo "  ${G}✓${N} $*"; PASS=$((PASS+1)); }
fail()   { echo "  ${R}✗${N} $*"; FAIL=$((FAIL+1)); }

# ── Prereqs ──────────────────────────────────────────────────────────────────
header "Preflight"
if [[ ! -x "$SYNC" ]]; then
  fail "scripts/sync-registry missing or not executable"
  echo "Results: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
pass "scripts/sync-registry is executable"

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not available"
  exit 1
fi
pass "python3 present"

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not available"
  exit 1
fi
pass "jq present"

if ! python3 -c "import yaml" 2>/dev/null; then
  # CI (ubuntu-latest) usually has PyYAML via python3-yaml or pip.
  # Developers may not. Try pip install with a few strategies before failing.
  echo "  ${Y}!${N} PyYAML not importable — attempting pip install"
  pip install --user --quiet pyyaml >/dev/null 2>&1 \
    || pip3 install --user --quiet pyyaml >/dev/null 2>&1 \
    || sudo apt-get install -y python3-yaml >/dev/null 2>&1 \
    || sudo pip install --quiet pyyaml >/dev/null 2>&1 \
    || true
  if ! python3 -c "import yaml" 2>/dev/null; then
    fail "PyYAML not available (pip install pyyaml)"
    exit 1
  fi
fi
pass "PyYAML importable"

# ── Sandbox setup ────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$REPO" "$WORK/repo"
SB="$WORK/repo"

# ── Test 1: repo state is already in sync ────────────────────────────────────
header "Test 1 — repo HEAD has registry.json in sync with registry.yaml"
if bash "$SB/scripts/sync-registry" --check >/dev/null 2>&1; then
  pass "--check exits 0 on unmodified repo"
else
  fail "--check flagged drift on unmodified repo (registry.json wasn't regenerated before commit?)"
fi

# ── Test 2: regenerate produces identical output to committed JSON ───────────
header "Test 2 — regenerate is byte-for-byte identical to committed JSON"
cp "$SB/packs/registry.json" "$WORK/committed.json"
bash "$SB/scripts/sync-registry" >/dev/null
if diff -u "$WORK/committed.json" "$SB/packs/registry.json" >/dev/null; then
  pass "regenerated JSON == committed JSON (deterministic)"
else
  fail "regenerated JSON differs from committed (regenerate it: bash scripts/sync-registry)"
  diff -u "$WORK/committed.json" "$SB/packs/registry.json" | head -30 || true
fi

# ── Test 3: --check detects drift when JSON is edited ────────────────────────
header "Test 3 — --check detects hand-edited JSON"
cp "$SB/packs/registry.json" "$WORK/backup.json"
# Break the JSON: change codex-cli description
python3 -c "
import json
p='$SB/packs/registry.json'
d=json.load(open(p))
d['packs']['codex-cli']['description']='TAMPERED'
json.dump(d, open(p,'w'), indent=2, ensure_ascii=False)
"
if bash "$SB/scripts/sync-registry" --check >/dev/null 2>&1; then
  fail "--check did NOT detect hand-tampered JSON"
else
  pass "--check correctly rejected tampered JSON"
fi
cp "$WORK/backup.json" "$SB/packs/registry.json"

# ── Test 4: --check detects missing field ────────────────────────────────────
header "Test 4 — --check detects missing field in JSON"
python3 -c "
import json
p='$SB/packs/registry.json'
d=json.load(open(p))
d['packs']['codex-cli'].pop('default_model', None)
json.dump(d, open(p,'w'), indent=2, ensure_ascii=False)
"
if bash "$SB/scripts/sync-registry" --check >/dev/null 2>&1; then
  fail "--check did NOT detect missing default_model field"
else
  pass "--check rejected JSON missing default_model"
fi
cp "$WORK/backup.json" "$SB/packs/registry.json"

# ── Test 5: --check detects deleted JSON file ────────────────────────────────
header "Test 5 — --check handles missing JSON file"
rm "$SB/packs/registry.json"
if bash "$SB/scripts/sync-registry" --check >/dev/null 2>&1; then
  fail "--check passed when registry.json was missing"
else
  pass "--check correctly failed on missing registry.json"
fi
cp "$WORK/backup.json" "$SB/packs/registry.json"

# ── Test 6: generated JSON is valid JSON ─────────────────────────────────────
header "Test 6 — generated JSON parses with jq"
bash "$SB/scripts/sync-registry" >/dev/null
if jq '.' "$SB/packs/registry.json" >/dev/null 2>&1; then
  pass "jq parses generated registry.json"
else
  fail "jq failed to parse generated registry.json"
fi

# ── Test 7: Unicode preservation (em-dash) ───────────────────────────────────
header "Test 7 — Unicode characters preserved literally (not \\uXXXX escaped)"
# Pack descriptions contain em-dashes. They must be literal bytes.
if grep -F '—' "$SB/packs/registry.json" >/dev/null 2>&1; then
  pass "em-dash (—) preserved as literal UTF-8"
else
  fail "em-dash NOT found in generated JSON (ensure_ascii=False not set?)"
fi
# Also confirm \u escape form is NOT used
if grep -q '\\u2014' "$SB/packs/registry.json"; then
  fail "em-dash was \\u-escaped (regression — ensure_ascii=False was dropped)"
else
  pass "no \\u-escaped characters in output"
fi

# ── Test 8: codex-cli pack round-trips with all expected fields ──────────────
header "Test 8 — codex-cli entry has expected fields"
check_field() {
  local field="$1" expected="$2"
  local got
  got=$(jq -r --arg f "$field" '.packs["codex-cli"][$f]' "$SB/packs/registry.json")
  if [[ "$got" == "$expected" ]]; then
    pass "codex-cli.$field = $expected"
  else
    fail "codex-cli.$field expected '$expected' got '$got'"
  fi
}
check_field type agent
check_field default_model "gpt-5.4"
check_field requires_openai_key true
check_field experimental true
check_field instance_type "t4g.medium"
check_field data_volume_gb 0
check_field brain false

# ── Test 9: YAML → JSON data equality (deep compare) ─────────────────────────
header "Test 9 — YAML and JSON represent identical data (deep equality)"
RESULT=$(python3 <<PY
import sys, yaml, json
y = yaml.safe_load(open("$SB/packs/registry.yaml"))
j = json.load(open("$SB/packs/registry.json"))
if y == j:
    print("EQUAL")
else:
    print("DIFFER")
    # Emit first few differing keys for debug
    def diff(a, b, path="root"):
        out = []
        if type(a) != type(b):
            out.append(f"type mismatch at {path}: {type(a).__name__} vs {type(b).__name__}")
            return out
        if isinstance(a, dict):
            for k in set(a) | set(b):
                if k not in a: out.append(f"missing in YAML at {path}.{k}")
                elif k not in b: out.append(f"missing in JSON at {path}.{k}")
                else: out.extend(diff(a[k], b[k], f"{path}.{k}"))
        elif isinstance(a, list):
            if len(a) != len(b): out.append(f"list len mismatch at {path}: {len(a)} vs {len(b)}")
            for i, (x, y_) in enumerate(zip(a, b)):
                out.extend(diff(x, y_, f"{path}[{i}]"))
        else:
            if a != b: out.append(f"{path}: {a!r} != {b!r}")
        return out
    for line in diff(y, j)[:10]:
        print("  " + line)
PY
)
if [[ "$RESULT" == "EQUAL" ]]; then
  pass "YAML and JSON are deeply equal"
else
  fail "YAML and JSON differ"
  echo "$RESULT" | sed 's/^/    /'
fi

# ── Test 10: adding a new pack to YAML requires regeneration ─────────────────
header "Test 10 — adding a new pack to YAML is detected by --check"
cp "$WORK/backup.json" "$SB/packs/registry.json"
cp "$SB/packs/registry.yaml" "$WORK/backup.yaml"

cat >> "$SB/packs/registry.yaml" <<'EOF'

  synthetic-test-pack:
    type: agent
    description: "Synthetic test pack — added by test-sync-registry.sh"
    deps: []
    instance_type: t4g.medium
    root_volume_gb: 40
    data_volume_gb: 0
    ports: {}
    brain: false
    claude_code: false
    experimental: true
EOF

if bash "$SB/scripts/sync-registry" --check >/dev/null 2>&1; then
  fail "--check did NOT detect new YAML-only pack"
else
  pass "--check rejected YAML-only pack addition"
fi

# Regenerate, confirm pack is now in JSON
bash "$SB/scripts/sync-registry" >/dev/null
SYN=$(jq -r '.packs["synthetic-test-pack"].description // empty' "$SB/packs/registry.json")
if [[ -n "$SYN" ]]; then
  pass "synthetic-test-pack appears in regenerated JSON"
else
  fail "synthetic-test-pack missing from regenerated JSON"
fi

# Restore
cp "$WORK/backup.yaml" "$SB/packs/registry.yaml"
cp "$WORK/backup.json" "$SB/packs/registry.json"

# ── Test 11: list (deps) round-trips correctly ───────────────────────────────
header "Test 11 — deps arrays round-trip from YAML to JSON"
OC_DEPS=$(jq -c '.packs.openclaw.deps' "$SB/packs/registry.json")
if [[ "$OC_DEPS" == '["bedrockify"]' ]]; then
  pass "openclaw.deps = [\"bedrockify\"] preserved as JSON array"
else
  fail "openclaw.deps wrong: got $OC_DEPS"
fi

# ── Test 12: empty object (ports: {}) round-trips ────────────────────────────
header "Test 12 — empty ports object round-trips"
PORTS=$(jq -c '.packs["codex-cli"].ports' "$SB/packs/registry.json")
if [[ "$PORTS" == "{}" ]]; then
  pass "codex-cli.ports = {} preserved as empty object"
else
  fail "codex-cli.ports wrong: got $PORTS"
fi

# ── Test 13: invalid YAML fails cleanly ──────────────────────────────────────
header "Test 13 — invalid YAML fails with non-zero exit"
cp "$SB/packs/registry.yaml" "$WORK/bkup2.yaml"
echo "this is: not: valid: yaml: [nor:" >> "$SB/packs/registry.yaml"
if bash "$SB/scripts/sync-registry" >/dev/null 2>&1; then
  fail "sync-registry accepted invalid YAML"
else
  pass "sync-registry rejected invalid YAML with non-zero exit"
fi
cp "$WORK/bkup2.yaml" "$SB/packs/registry.yaml"

# ── Test 14: compatible_profiles list round-trips ────────────────────────────
header "Test 14 — roundhouse.compatible_profiles list round-trips"
# Roundhouse has compatible_profiles: [builder]
RH=$(jq -c '.packs.roundhouse.compatible_profiles' "$SB/packs/registry.json")
if [[ "$RH" == '["builder"]' ]]; then
  pass "roundhouse.compatible_profiles preserved"
else
  fail "roundhouse.compatible_profiles wrong: got $RH"
fi

# ── Test 15: defaults section present ────────────────────────────────────────
header "Test 15 — top-level 'defaults' section present and complete"
for key in ami_filter arch os instance_type root_volume_gb data_volume_gb bedrock_region; do
  val=$(jq -r ".defaults.$key // empty" "$SB/packs/registry.json")
  if [[ -n "$val" ]]; then
    pass "defaults.$key present ($val)"
  else
    fail "defaults.$key missing"
  fi
done

# ── Test 16: every pack listed in YAML is listed in JSON ─────────────────────
header "Test 16 — every YAML pack is in JSON (and vice versa)"
Y_PACKS=$(python3 -c "import yaml; print('\n'.join(sorted(yaml.safe_load(open('$SB/packs/registry.yaml'))['packs'].keys())))")
J_PACKS=$(jq -r '.packs | keys[]' "$SB/packs/registry.json" | sort)
if [[ "$Y_PACKS" == "$J_PACKS" ]]; then
  pass "YAML packs == JSON packs ($(echo "$Y_PACKS" | wc -l) packs)"
else
  fail "pack set mismatch"
  diff <(echo "$Y_PACKS") <(echo "$J_PACKS") | sed 's/^/    /'
fi

# ── Test 17: sync is idempotent ──────────────────────────────────────────────
header "Test 17 — repeated sync is idempotent"
bash "$SB/scripts/sync-registry" >/dev/null
HASH1=$(sha256sum "$SB/packs/registry.json" | cut -d' ' -f1)
bash "$SB/scripts/sync-registry" >/dev/null
HASH2=$(sha256sum "$SB/packs/registry.json" | cut -d' ' -f1)
bash "$SB/scripts/sync-registry" >/dev/null
HASH3=$(sha256sum "$SB/packs/registry.json" | cut -d' ' -f1)
if [[ "$HASH1" == "$HASH2" && "$HASH2" == "$HASH3" ]]; then
  pass "3 runs produce byte-identical JSON"
else
  fail "sync is not idempotent: $HASH1 vs $HASH2 vs $HASH3"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "${C}────────────────────────────────────────${N}"
echo "  Passed: ${G}${PASS}${N}"
echo "  Failed: ${R}${FAIL}${N}"
echo "${C}────────────────────────────────────────${N}"
if (( FAIL > 0 )); then
  echo "${R}✗ sync-registry tests FAILED${N}"
  exit 1
fi
echo "${G}✓ sync-registry generation is correct and drift-safe${N}"
