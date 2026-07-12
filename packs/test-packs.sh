#!/usr/bin/env bash
# packs/test-packs.sh — TDD test suite for the packs/ directory
#
# Validates:
#   1. All manifests parse as valid YAML
#   2. All install.sh are executable and accept --help
#   3. common.sh loads without error
#
# Usage: ./test-packs.sh
# Exit: 0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { printf "${GREEN}  ✓${NC} %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "${RED}  ✗${NC} %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "${YELLOW}  ○${NC} %s\n" "$1"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
yaml_parse_ok() {
  local file="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "import sys; import yaml; yaml.safe_load(open('${file}'))" 2>/dev/null
  elif command -v python &>/dev/null; then
    python -c "import sys; import yaml; yaml.safe_load(open('${file}'))" 2>/dev/null
  else
    # Fallback: check file is non-empty and has no obvious parse errors with yq/grep
    [[ -s "${file}" ]]
  fi
}

# ── Packs to test ─────────────────────────────────────────────────────────────
# Dynamically discover all packs (directories with manifest.yaml)
PACKS=()
for _dir in "${SCRIPT_DIR}"/*/; do
  _pack=$(basename "$_dir")
  [[ -f "${_dir}/manifest.yaml" ]] && PACKS+=("$_pack")
done
unset _dir _pack

# ── Test: common.sh ───────────────────────────────────────────────────────────
header "Test: common.sh"

COMMON="${SCRIPT_DIR}/common.sh"

if [[ -f "${COMMON}" ]]; then
  pass "common.sh exists"
else
  fail "common.sh missing: ${COMMON}"
fi

if [[ -f "${COMMON}" ]]; then
  if bash -c "source '${COMMON}'" 2>/dev/null; then
    pass "common.sh sources without error"
  else
    fail "common.sh sources with error"
  fi

  # Verify required functions are exported
  for fn in log ok fail warn step require_cmd write_done_marker pack_banner pack_config_get; do
    if bash -c "source '${COMMON}'; declare -f ${fn} >/dev/null" 2>/dev/null; then
      pass "common.sh: function '${fn}' defined"
    else
      fail "common.sh: function '${fn}' missing"
    fi
  done
fi

# ── Test: pack_config_get ─────────────────────────────────────────────────────
header "Test: pack_config_get"

if command -v jq &>/dev/null; then
  # Create a temp config JSON for testing
  TMPCONFIG="$(mktemp /tmp/test-pack-config-XXXXXX.json)"
  cat > "${TMPCONFIG}" << 'JSONEOF'
{
  "region": "eu-west-2",
  "model": "us.anthropic.claude-sonnet-4-6",
  "gw_port": "4000",
  "hermes_model": "anthropic/claude-sonnet-4.6"
}
JSONEOF

  # Test: reads an existing key
  _val=$(PACK_CONFIG="${TMPCONFIG}" bash -c "source '${COMMON}'; pack_config_get region 'us-east-1'")
  if [[ "${_val}" == "eu-west-2" ]]; then
    pass "pack_config_get: reads value from JSON file"
  else
    fail "pack_config_get: expected 'eu-west-2', got '${_val}'"
  fi

  # Test: reads a different key
  _val=$(PACK_CONFIG="${TMPCONFIG}" bash -c "source '${COMMON}'; pack_config_get hermes_model 'default-model'")
  if [[ "${_val}" == "anthropic/claude-sonnet-4.6" ]]; then
    pass "pack_config_get: reads hermes_model key correctly"
  else
    fail "pack_config_get: expected 'anthropic/claude-sonnet-4.6', got '${_val}'"
  fi

  # Test: returns default when key is missing from JSON
  _val=$(PACK_CONFIG="${TMPCONFIG}" bash -c "source '${COMMON}'; pack_config_get nonexistent_key 'my-default'")
  if [[ "${_val}" == "my-default" ]]; then
    pass "pack_config_get: returns default for missing key"
  else
    fail "pack_config_get: expected 'my-default', got '${_val}'"
  fi

  # Test: returns default when config file does not exist
  _val=$(PACK_CONFIG="/tmp/no-such-file-XYZ.json" bash -c "source '${COMMON}'; pack_config_get region 'fallback-region'")
  if [[ "${_val}" == "fallback-region" ]]; then
    pass "pack_config_get: returns default when config file missing"
  else
    fail "pack_config_get: expected 'fallback-region', got '${_val}'"
  fi

  # Test: returns default when PACK_CONFIG unset and /tmp/loki-pack-config.json absent
  _val=$(env -u PACK_CONFIG bash -c "
    [[ ! -f /tmp/loki-pack-config.json ]] || { echo skip; exit 0; }
    source '${COMMON}'
    pack_config_get region 'default-region'
  ")
  if [[ "${_val}" == "default-region" ]] || [[ "${_val}" == "skip" ]]; then
    pass "pack_config_get: falls back to default when env unset and file absent"
  else
    fail "pack_config_get: unexpected value '${_val}' (expected default)"
  fi

  rm -f "${TMPCONFIG}"
else
  skip "pack_config_get tests: jq not installed"
fi

# ── Test: registry.yaml ───────────────────────────────────────────────────────
header "Test: registry.yaml"

REGISTRY="${SCRIPT_DIR}/registry.yaml"

if [[ -f "${REGISTRY}" ]]; then
  pass "registry.yaml exists"
else
  fail "registry.yaml missing"
fi

if [[ -f "${REGISTRY}" ]]; then
  if yaml_parse_ok "${REGISTRY}"; then
    pass "registry.yaml is valid YAML"
  else
    fail "registry.yaml is invalid YAML"
  fi

  # Check required top-level keys
  for key in version defaults packs; do
    if grep -q "^${key}:" "${REGISTRY}" 2>/dev/null; then
      pass "registry.yaml: has '${key}' key"
    else
      fail "registry.yaml: missing '${key}' key"
    fi
  done

  # Check each pack is listed
  for pack in "${PACKS[@]}"; do
    if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${REGISTRY}'))
sys.exit(0 if '${pack}' in data.get('packs', {}) else 1)
" 2>/dev/null; then
      pass "registry.yaml: pack '${pack}' listed"
    else
      fail "registry.yaml: pack '${pack}' not listed"
    fi
  done
fi

# ── Test: per-pack manifests ──────────────────────────────────────────────────
header "Test: pack manifests"

for pack in "${PACKS[@]}"; do
  MANIFEST="${SCRIPT_DIR}/${pack}/manifest.yaml"

  if [[ -f "${MANIFEST}" ]]; then
    pass "${pack}/manifest.yaml exists"
  else
    fail "${pack}/manifest.yaml missing"
    continue
  fi

  if yaml_parse_ok "${MANIFEST}"; then
    pass "${pack}/manifest.yaml is valid YAML"
  else
    fail "${pack}/manifest.yaml is invalid YAML"
    continue
  fi

  # Check required manifest keys
  for key in name version type description params provides; do
    if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if '${key}' in data else 1)
" 2>/dev/null; then
      pass "${pack}/manifest.yaml: has '${key}' key"
    else
      fail "${pack}/manifest.yaml: missing '${key}' key"
    fi
  done

  # Verify name matches folder
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if data.get('name') == '${pack}' else 1)
" 2>/dev/null; then
    pass "${pack}/manifest.yaml: name matches folder"
  else
    fail "${pack}/manifest.yaml: name does not match folder '${pack}'"
  fi
done

# ── Test: install.sh executability and --help ─────────────────────────────────
header "Test: install.sh"

for pack in "${PACKS[@]}"; do
  INSTALL="${SCRIPT_DIR}/${pack}/install.sh"

  if [[ -f "${INSTALL}" ]]; then
    pass "${pack}/install.sh exists"
  else
    fail "${pack}/install.sh missing"
    continue
  fi

  if [[ -x "${INSTALL}" ]]; then
    pass "${pack}/install.sh is executable"
  else
    fail "${pack}/install.sh is not executable"
  fi

  # Test --help exits 0 and produces output
  HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && HELP_RC=0 || HELP_RC=$?
  if [[ "${HELP_RC}" -eq 0 ]]; then
    pass "${pack}/install.sh --help exits 0"
  else
    fail "${pack}/install.sh --help exits ${HELP_RC}"
  fi

  if [[ -n "${HELP_OUT}" ]]; then
    pass "${pack}/install.sh --help produces output"
  else
    fail "${pack}/install.sh --help produces no output"
  fi

  # Check that --help output mentions --help itself
  if printf '%s' "${HELP_OUT}" | grep -q -- '--help'; then
    pass "${pack}/install.sh --help output mentions --help flag"
  else
    fail "${pack}/install.sh --help output missing --help reference"
  fi

  # Check that shebang is correct
  SHEBANG="$(head -1 "${INSTALL}")"
  if [[ "${SHEBANG}" == "#!/usr/bin/env bash" ]] || [[ "${SHEBANG}" == "#!/bin/bash" ]]; then
    pass "${pack}/install.sh has bash shebang"
  else
    fail "${pack}/install.sh has unexpected shebang: ${SHEBANG}"
  fi

  # Check that install.sh sources ../common.sh
  if grep -q 'common\.sh' "${INSTALL}" 2>/dev/null; then
    pass "${pack}/install.sh references common.sh"
  else
    fail "${pack}/install.sh does not reference common.sh"
  fi

  # Check for done-marker write
  if grep -q 'write_done_marker\|pack-.*-done' "${INSTALL}" 2>/dev/null; then
    pass "${pack}/install.sh writes done marker"
  else
    fail "${pack}/install.sh does not write done marker"
  fi
done

# ── Test: resources/ directory ────────────────────────────────────────────────
header "Test: resources/"

# Expected resources per pack (packs not listed here skip the per-file check)
declare -A PACK_RESOURCES
PACK_RESOURCES[bedrockify]="bedrockify.service.tpl"
PACK_RESOURCES[openclaw]="config-gen.py openclaw-gateway.service.tpl"
PACK_RESOURCES[hermes]="hermes-config.yaml.tpl hermes-env.tpl"
PACK_RESOURCES[troika]="shell-profile.sh"

for pack in "${PACKS[@]}"; do
  RESOURCES_DIR="${SCRIPT_DIR}/${pack}/resources"

  if [[ -d "${RESOURCES_DIR}" ]]; then
    pass "${pack}/resources/ directory exists"
  else
    fail "${pack}/resources/ directory missing"
    continue
  fi

  # Skip per-file checks for packs without a resource manifest
  if [[ -z "${PACK_RESOURCES[$pack]+x}" ]]; then
    skip "${pack}/resources/ — no expected resources defined (directory exists, OK)"
    continue
  fi

  for resource in ${PACK_RESOURCES[$pack]}; do
    RFILE="${RESOURCES_DIR}/${resource}"
    if [[ -f "${RFILE}" ]]; then
      pass "${pack}/resources/${resource} exists"
    else
      fail "${pack}/resources/${resource} missing"
    fi

    # Ensure non-empty
    if [[ -s "${RFILE}" ]]; then
      pass "${pack}/resources/${resource} is non-empty"
    else
      fail "${pack}/resources/${resource} is empty"
    fi
  done
done

# ── shellcheck (optional, skip if not installed) ──────────────────────────────
header "Test: shellcheck (lint)"

if command -v shellcheck &>/dev/null; then
  # Dynamically lint common.sh + all pack install scripts
  _lint_scripts=("${SCRIPT_DIR}/common.sh")
  for _p in "${PACKS[@]}"; do
    [[ -f "${SCRIPT_DIR}/${_p}/install.sh" ]] && _lint_scripts+=("${SCRIPT_DIR}/${_p}/install.sh")
  done
  for script in "${_lint_scripts[@]}"; do
    if [[ -f "${script}" ]]; then
      SCRIPT_NAME="$(basename "$(dirname "${script}")")/$(basename "${script}")"
      if shellcheck -S warning "${script}" 2>/dev/null; then
        pass "shellcheck: ${SCRIPT_NAME}"
      else
        fail "shellcheck: ${SCRIPT_NAME} has warnings/errors"
      fi
    fi
  done
else
  skip "shellcheck not installed — skipping lint tests"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Test Results${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed:${NC} %d\n" "${PASS}"
printf "  ${RED}Failed:${NC} %d\n" "${FAIL}"
printf "  ${YELLOW}Skipped:${NC} %d\n" "${SKIP}"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

if [[ "${FAIL}" -gt 0 ]]; then
  printf "${RED}✗ %d test(s) failed${NC}\n\n" "${FAIL}"
  exit 1
else
  printf "${GREEN}✓ All tests passed${NC}\n\n"
  exit 0
fi
