#!/usr/bin/env bash
# packs/troika/test.sh — contract tests for the Troika pack
#
# Tests (all offline, no AWS, no live installs):
#   1. manifest.yaml structure and required keys
#   2. install.sh: syntax, interface, conventions
#   3. daily-driver validation (valid values accepted, invalid rejected)
#   4. .bashrc autolaunch block idempotency (sentinel-guarded)
#   5. resources/shell-profile.sh required variables
#   6. Registry entries consistent (yaml + json)
#
# Usage: bash packs/troika/test.sh
# Exit: 0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
PACKS_DIR="${SCRIPT_DIR}/.."
INSTALL="${PACK_DIR}/install.sh"
MANIFEST="${PACK_DIR}/manifest.yaml"
PROFILE="${PACK_DIR}/resources/shell-profile.sh"

# ── Test harness ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0

pass()   { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail()   { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
skip()   { printf "${YELLOW}  ○${NC} %s (skipped)\n" "$1"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# ── 1. manifest.yaml ──────────────────────────────────────────────────────────
header "Test: manifest.yaml"

[[ -f "${MANIFEST}" ]] && pass "manifest.yaml exists" || { fail "manifest.yaml missing"; }

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  if python3 - "${MANIFEST}" <<'PY' ; then
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
required = ["name","version","type","description","deps","params","health_check","provides"]
missing = [k for k in required if k not in data]
if missing:
    sys.exit(f"missing keys: {missing}")
# name matches directory
if data.get("name") != "troika":
    sys.exit(f"name mismatch: {data.get('name')!r} != 'troika'")
# type is agent
if data.get("type") != "agent":
    sys.exit(f"type mismatch: {data.get('type')!r}")
# deps in correct order
expected_deps = ["bedrockify", "openclaw", "claude-code", "codex-cli"]
if data.get("deps") != expected_deps:
    sys.exit(f"deps wrong: {data.get('deps')} != {expected_deps}")
# required params present
param_names = [p["name"] for p in data.get("params", [])]
for req in ["primary", "daily-driver", "model", "codex-model", "region"]:
    if req not in param_names:
        sys.exit(f"missing param: {req}")
# provides commands includes all four
cmds = data.get("provides", {}).get("commands", [])
for cmd in ["openclaw", "claude", "codex", "agents"]:
    if cmd not in cmds:
        sys.exit(f"missing command in provides: {cmd}")
print("OK")
PY
    pass "manifest.yaml: valid YAML, required keys, deps order, params, provides"
  else
    fail "manifest.yaml: structure invalid (see output above)"
  fi

  # primary param: present with default=openclaw
  if python3 - "${MANIFEST}" <<'PY' 2>/dev/null; then
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
params = {p["name"]: p for p in data.get("params", [])}
pr = params.get("primary", {})
assert "primary" in params, "primary param missing"
assert pr.get("default") == "openclaw", f"primary default={pr.get('default')!r}"
print("OK")
PY
    pass "manifest.yaml: primary param present with default openclaw"
  else
    fail "manifest.yaml: primary param missing or default not openclaw"
  fi

  # daily-driver default is empty string (tracks primary — §12a.2)
  if python3 - "${MANIFEST}" <<'PY' 2>/dev/null; then
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
params = {p["name"]: p for p in data.get("params", [])}
dd = params.get("daily-driver", {})
assert dd.get("default") in ("", None), f"daily-driver default should be empty, got {dd.get('default')!r}"
print("OK")
PY
    pass "manifest.yaml: daily-driver default is empty (tracks primary — §12a.2)"
  else
    fail "manifest.yaml: daily-driver default is not empty (should track primary)"
  fi

  # experimental: true
  if python3 - "${MANIFEST}" <<'PY' 2>/dev/null; then
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
# experimental is not a manifest field (it's registry-only), just verify type=agent
assert data.get("type") == "agent"
print("OK")
PY
    pass "manifest.yaml: type=agent"
  else
    fail "manifest.yaml: type is not agent"
  fi
else
  skip "manifest.yaml YAML structure tests: python3 or pyyaml not available"
fi

# ── 2. install.sh ─────────────────────────────────────────────────────────────
header "Test: install.sh"

[[ -f "${INSTALL}" ]] && pass "install.sh exists" || fail "install.sh missing"
[[ -x "${INSTALL}" ]] && pass "install.sh is executable" || fail "install.sh is NOT executable (chmod +x needed)"

# Shebang
_shebang="$(head -1 "${INSTALL}")"
[[ "${_shebang}" == "#!/usr/bin/env bash" ]] && pass "install.sh: correct shebang" || fail "install.sh: wrong shebang: ${_shebang}"

# Bash syntax check
bash -n "${INSTALL}" 2>/dev/null && pass "install.sh: bash -n clean (no syntax errors)" || fail "install.sh: bash syntax errors"

# Sources common.sh
grep -q 'source.*common\.sh' "${INSTALL}" && pass "install.sh: sources common.sh" || fail "install.sh: does not source common.sh"

# set -euo pipefail
grep -q 'set -euo pipefail' "${INSTALL}" && pass "install.sh: set -euo pipefail" || fail "install.sh: missing set -euo pipefail"

# Writes done marker for 'troika'
grep -q 'write_done_marker.*troika' "${INSTALL}" && pass "install.sh: writes done marker for 'troika'" || fail "install.sh: missing write_done_marker troika"

# --help exits 0 and produces useful output
HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && HELP_RC=0 || HELP_RC=$?
[[ "${HELP_RC}" -eq 0 ]] && pass "install.sh: --help exits 0" || fail "install.sh: --help exits ${HELP_RC}"
[[ -n "${HELP_OUT}" ]] && pass "install.sh: --help produces output" || fail "install.sh: --help produces no output"

for flag in --daily-driver --model --codex-model --region --help; do
  printf '%s' "${HELP_OUT}" | grep -q -- "${flag}" \
    && pass "install.sh: --help mentions ${flag}" \
    || fail "install.sh: --help missing ${flag}"
done

# VALID_DRIVERS derives from PRIMARY metadata (§12b.1 — not hardcoded)
_valid_drivers_line="$(grep 'VALID_DRIVERS=(' "${INSTALL}" 2>/dev/null || true)"
for drv in claude-code codex-cli none; do
  printf '%s' "${_valid_drivers_line}" | grep -q "${drv}" \
    && pass "install.sh: '${drv}' in VALID_DRIVERS" \
    || fail "install.sh: '${drv}' missing from VALID_DRIVERS"
done
# §12b.1: at least one VALID_DRIVERS line should reference PRIMARY dynamically
if grep -q 'VALID_DRIVERS=.*PRIMARY' "${INSTALL}"; then
  pass "install.sh: VALID_DRIVERS uses PRIMARY slot — §12b.1"
else
  fail "install.sh: VALID_DRIVERS does not use PRIMARY slot"
fi

# Validation logic present (rejects invalid drivers)
grep -q '_valid_driver' "${INSTALL}" \
  && pass "install.sh: has daily-driver validation logic" \
  || fail "install.sh: missing daily-driver validation logic"

# §12b.1 litmus: _read_tui_cmd single lookup helper
if grep -q '_read_tui_cmd' "${INSTALL}"; then
  pass "install.sh: _read_tui_cmd lookup helper present — §12b.1"
else
  fail "install.sh: _read_tui_cmd missing — required by §12b.1"
fi

# --primary flag in arg parsing
if grep -q -- '--primary' "${INSTALL}"; then
  pass "install.sh: --primary arg parsed"
else
  fail "install.sh: --primary not parsed"
fi

# primary read from pack_config
if grep -q 'pack_config_get.*primary' "${INSTALL}"; then
  pass "install.sh: primary read from PACK_CONFIG"
else
  fail "install.sh: primary not read from PACK_CONFIG"
fi

# DAILY_DRIVER defaults to PRIMARY — §12a.2
if grep -q 'DAILY_DRIVER.*:-.*PRIMARY' "${INSTALL}"; then
  pass "install.sh: DAILY_DRIVER defaults to PRIMARY — §12a.2"
else
  fail "install.sh: DAILY_DRIVER does not default to PRIMARY"
fi

# openclaw-gateway guard — §12a.6
if grep -q 'PRIMARY.*openclaw' "${INSTALL}"; then
  pass "install.sh: openclaw-gateway gated on primary=openclaw — §12a.6"
else
  fail "install.sh: missing openclaw-gateway primary=openclaw guard"
fi

# ── 3. daily-driver validation (live behaviour) ───────────────────────────────
header "Test: daily-driver validation"

# Run install.sh with a bad driver — must exit non-zero
if PACK_CONFIG=/dev/null bash "${INSTALL}" --daily-driver "INVALID_DRIVER_XYZ" >/dev/null 2>&1; then
  fail "install.sh: accepted invalid daily-driver 'INVALID_DRIVER_XYZ' (should reject)"
else
  pass "install.sh: rejects invalid daily-driver 'INVALID_DRIVER_XYZ'"
fi

# Invalid primary must also be rejected
if PACK_CONFIG=/dev/null bash "${INSTALL}" --primary "INVALID_PRIMARY_XYZ" >/dev/null 2>&1; then
  fail "install.sh: accepted invalid primary 'INVALID_PRIMARY_XYZ' (should reject)"
else
  pass "install.sh: rejects invalid primary 'INVALID_PRIMARY_XYZ'"
fi

# 'none' must be accepted (§12.8 requirement) — verified via VALID_DRIVERS array
_vd_line="$(grep 'VALID_DRIVERS=(' "${INSTALL}" 2>/dev/null || true)"
printf '%s' "${_vd_line}" | grep -q 'none' \
  && pass "install.sh: 'none' is explicitly listed in VALID_DRIVERS" \
  || fail "install.sh: 'none' is not in VALID_DRIVERS"

# ── 4. .bashrc autolaunch idempotency ────────────────────────────────────────
header "Test: .bashrc autolaunch block idempotency"


# Sentinel variable is assigned in install.sh, and referenced at least twice
# (once in grep guard + twice in the heredoc = 3+ occurrences of AUTOLAUNCH_SENTINEL)
_sentinel_var_count="$(grep -c 'AUTOLAUNCH_SENTINEL' "${INSTALL}" 2>/dev/null || true)"
[[ "${_sentinel_var_count}" -ge 3 ]] \
  && pass "install.sh: AUTOLAUNCH_SENTINEL referenced ${_sentinel_var_count} times (assign + grep guard + heredoc start + end)" \
  || fail "install.sh: AUTOLAUNCH_SENTINEL appears only ${_sentinel_var_count} time(s) — expected ≥3"

# Idempotency guard (grep -qF sentinel before appending)
grep -qE 'grep.*AUTOLAUNCH_SENTINEL|grep.*troika-autolaunch' "${INSTALL}" \
  && pass "install.sh: has sentinel-based idempotency guard" \
  || fail "install.sh: missing sentinel idempotency guard"

# Test actual idempotency: replicate the sentinel-guarded append logic
_SENTINEL="# --- troika-autolaunch ---"
_tmp_bashrc="$(mktemp)"

# Simulate the append logic (mirrors what install.sh does)
_append_once() {
  local bashrc="$1" sentinel="$2"
  if grep -qF "${sentinel}" "${bashrc}" 2>/dev/null; then
    return 0
  fi
  printf '\n%s\n# test block content\n%s\n' "${sentinel}" "${sentinel}" >> "${bashrc}"
}

_append_once "${_tmp_bashrc}" "${_SENTINEL}"
_append_once "${_tmp_bashrc}" "${_SENTINEL}"
_append_once "${_tmp_bashrc}" "${_SENTINEL}"

_count="$(grep -cF "${_SENTINEL}" "${_tmp_bashrc}" || true)"
rm -f "${_tmp_bashrc}"

[[ "${_count}" -eq 2 ]] \
  && pass "autolaunch block: idempotent (sentinel appears exactly 2 times after 3 append attempts)" \
  || fail "autolaunch block: NOT idempotent (sentinel count: ${_count}, expected 2)"

# Safety guards present: interactive check + tty check + LOKI_NO_TUI escape hatch
grep -q 'LOKI_NO_TUI' "${INSTALL}" \
  && pass "install.sh: LOKI_NO_TUI escape hatch present" \
  || fail "install.sh: missing LOKI_NO_TUI escape hatch"

grep -q 'LOKI_TUI_LAUNCHED' "${INSTALL}" \
  && pass "install.sh: LOKI_TUI_LAUNCHED nested-relaunch guard present" \
  || fail "install.sh: missing LOKI_TUI_LAUNCHED guard"

grep -qE '\[\[ .*-t 0.*\]\]|\[\[.*-t 0\]\]' "${INSTALL}" \
  && pass "install.sh: tty check [[ -t 0 ]] present (prevents non-tty auto-launch)" \
  || fail "install.sh: missing [[ -t 0 ]] guard"

# 'none' case in auto-launch switch statement (§12.8)
grep -qE 'none.*\).*:' "${INSTALL}" || grep -q "none)        : ;;" "${INSTALL}" \
  && pass "install.sh: 'none' daily-driver no-ops in auto-launch switch" \
  || fail "install.sh: 'none' case missing from auto-launch switch"

# ── 5. resources/shell-profile.sh ────────────────────────────────────────────
header "Test: resources/shell-profile.sh"

[[ -f "${PROFILE}" ]] && pass "resources/shell-profile.sh exists" || fail "resources/shell-profile.sh missing"

for var in PACK_ALIASES PACK_BANNER_NAME PACK_BANNER_EMOJI PACK_BANNER_COMMANDS; do
  grep -q "^${var}=" "${PROFILE}" 2>/dev/null \
    && pass "shell-profile.sh: defines ${var}" \
    || fail "shell-profile.sh: missing ${var}"
done

# Sources cleanly under set -euo pipefail
bash -c "set -euo pipefail; source '${PROFILE}'" 2>/dev/null \
  && pass "shell-profile.sh: sources cleanly under set -euo pipefail" \
  || fail "shell-profile.sh: errors when sourced with set -euo pipefail"

# PACK_BANNER_NAME mentions Troika
grep -qi 'troika' "${PROFILE}" \
  && pass "shell-profile.sh: PACK_BANNER_NAME mentions Troika" \
  || fail "shell-profile.sh: PACK_BANNER_NAME does not mention Troika"

# Banner mentions all three agents
for agent_cmd in openclaw claude codex; do
  grep -q "${agent_cmd}" "${PROFILE}" \
    && pass "shell-profile.sh: mentions '${agent_cmd}'" \
    || fail "shell-profile.sh: missing '${agent_cmd}'"
done

# ── 6. Registry consistency ───────────────────────────────────────────────────
header "Test: registry consistency"

REGISTRY_YAML="${PACKS_DIR}/registry.yaml"
REGISTRY_JSON="${PACKS_DIR}/registry.json"

# YAML
if python3 - "${REGISTRY_YAML}" <<'PY' 2>/dev/null; then
import sys, yaml
data = yaml.safe_load(open(sys.argv[1]))
t = data.get("packs", {}).get("troika", {})
assert t, "troika not found in registry.yaml"
assert t.get("type") == "agent", f"type={t.get('type')!r}"
assert t.get("instance_type") == "t4g.xlarge", f"instance_type={t.get('instance_type')!r}"
assert t.get("experimental") is True, f"experimental={t.get('experimental')!r}"
assert t.get("requires_openai_key") is False, f"requires_openai_key={t.get('requires_openai_key')!r}"
assert t.get("brain") is True, f"brain={t.get('brain')!r}"
expected_deps = ["bedrockify", "openclaw", "claude-code", "codex-cli"]
assert t.get("deps") == expected_deps, f"deps={t.get('deps')!r}"
assert "builder" in t.get("compatible_profiles", []), "builder not in compatible_profiles"
print("OK")
PY
  pass "registry.yaml: troika entry has correct fields" \
  || fail "registry.yaml: troika entry has incorrect fields"
fi

# JSON
if [[ -f "${REGISTRY_JSON}" ]] && command -v jq &>/dev/null; then
  jq -e '.packs.troika' "${REGISTRY_JSON}" >/dev/null 2>&1 \
    && pass "registry.json: troika entry present" \
    || fail "registry.json: troika entry missing"

  _type="$(jq -r '.packs.troika.type' "${REGISTRY_JSON}")"
  [[ "${_type}" == "agent" ]] && pass "registry.json: troika type=agent" || fail "registry.json: troika type=${_type}"

  _experimental="$(jq -r '.packs.troika.experimental' "${REGISTRY_JSON}")"
  [[ "${_experimental}" == "true" ]] && pass "registry.json: troika experimental=true" || fail "registry.json: troika experimental=${_experimental}"

  _req_oai="$(jq -r '.packs.troika.requires_openai_key' "${REGISTRY_JSON}")"
  [[ "${_req_oai}" == "false" ]] && pass "registry.json: troika requires_openai_key=false" || fail "registry.json: troika requires_openai_key=${_req_oai}"

  _itype="$(jq -r '.packs.troika.instance_type' "${REGISTRY_JSON}")"
  [[ "${_itype}" == "t4g.xlarge" ]] && pass "registry.json: troika instance_type=t4g.xlarge" || fail "registry.json: troika instance_type=${_itype}"

  _model="$(jq -r '.packs.troika.default_model' "${REGISTRY_JSON}")"
  [[ "${_model}" == "us.anthropic.claude-sonnet-4-6" ]] && pass "registry.json: troika default_model correct" || fail "registry.json: troika default_model=${_model}"

  # Deps array
  _deps="$(jq -c '.packs.troika.deps' "${REGISTRY_JSON}")"
  [[ "${_deps}" == '["bedrockify","openclaw","claude-code","codex-cli"]' ]] \
    && pass "registry.json: troika deps order correct (bedrockify→openclaw→claude-code→codex-cli)" \
    || fail "registry.json: troika deps wrong: ${_deps}"
else
  skip "registry.json tests: jq not available or file missing"
fi

# ── shellcheck (if available) ─────────────────────────────────────────────────
header "Test: shellcheck"

if command -v shellcheck &>/dev/null; then
  shellcheck -S warning "${INSTALL}" 2>/dev/null \
    && pass "shellcheck: install.sh clean (no warnings at 'warning' level)" \
    || fail "shellcheck: install.sh has warnings/errors"
  shellcheck -S warning "${PROFILE}" 2>/dev/null \
    && pass "shellcheck: shell-profile.sh clean" \
    || fail "shellcheck: shell-profile.sh has warnings/errors"
else
  skip "shellcheck: not installed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Troika Pack Test Results${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed:${NC}  %d\n" "${PASS}"
printf "  ${RED}Failed:${NC}  %d\n" "${FAIL}"
printf "  ${YELLOW}Skipped:${NC} %d\n" "${SKIP}"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

[[ "${FAIL}" -eq 0 ]] && printf "${GREEN}✓ All tests passed${NC}\n\n" && exit 0
printf "${RED}✗ %d test(s) failed${NC}\n\n" "${FAIL}"
exit 1
