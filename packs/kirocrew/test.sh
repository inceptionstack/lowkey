#!/usr/bin/env bash
# packs/kirocrew/test.sh — offline tests for kirocrew pack
# Validates manifest structure, install.sh syntax, arg parser, feature signals,
# Phase 1 + Phase 2 coverage, shell profile, systemd unit, and registry consistency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
REPO_DIR="$(cd "${PACK_DIR}/../.." && pwd)"

passed=0
failed=0
pass() { printf "  \033[0;32m✓\033[0m %s\n" "$1"; passed=$((passed+1)); }
fail() { printf "  \033[0;31m✗\033[0m %s\n" "$1"; failed=$((failed+1)); }
header() { printf "\n\033[1;36m── %s ──\033[0m\n" "$1"; }

# ── manifest.yaml ────────────────────────────────────────────────────────────
header "manifest.yaml"
MANIFEST="${PACK_DIR}/manifest.yaml"

if [[ -f "${MANIFEST}" ]]; then
  pass "manifest.yaml exists"
else
  fail "manifest.yaml missing"; exit 1
fi

if python3 -c "import yaml; yaml.safe_load(open('${MANIFEST}'))" 2>/dev/null; then
  pass "manifest.yaml is valid YAML"
else
  fail "manifest.yaml is invalid YAML"
fi

for key in name version type description deps requirements params health_check provides; do
  if python3 -c "import yaml; d=yaml.safe_load(open('${MANIFEST}')); exit(0 if '$key' in d else 1)" 2>/dev/null; then
    pass "manifest has '$key' key"
  else
    fail "manifest missing '$key' key"
  fi
done

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d['name'] == 'kirocrew', f\"name is {d['name']}\"
" 2>/dev/null; then
  pass "manifest name is kirocrew"
else
  fail "manifest name != kirocrew"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d.get('deps', []) == [], 'deps should be []'
" 2>/dev/null; then
  pass "manifest deps is empty (no kiro-cli dep)"
else
  fail "manifest deps should be empty"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
names = [p['name'] for p in d.get('params', [])]
assert 'from-secret' in names, f\"missing from-secret param (got {names})\"
" 2>/dev/null; then
  pass "manifest has 'from-secret' param"
else
  fail "manifest missing 'from-secret' param"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
names = [p['name'] for p in d.get('params', [])]
assert 'channel' in names, f\"missing channel param\"
" 2>/dev/null; then
  pass "manifest has 'channel' param"
else
  fail "manifest missing 'channel' param"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
names = [p['name'] for p in d.get('params', [])]
assert 'extras' in names
assert 'start-gateway' in names
assert 'gateway-port' in names
assert 'kirocrew-home' in names
" 2>/dev/null; then
  pass "manifest has all Phase 2 params (extras, start-gateway, gateway-port, kirocrew-home)"
else
  fail "manifest missing Phase 2 params"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
for p in d.get('params', []):
    assert 'default' in p, f\"param {p.get('name','?')} missing default\"
" 2>/dev/null; then
  pass "all params have defaults"
else
  fail "some params missing default"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
for p in d.get('params', []):
    if p['name'] == 'start-gateway':
        assert p['default'] == 'true', f\"start-gateway default is {p['default']}\"
" 2>/dev/null; then
  pass "start-gateway defaults to 'true'"
else
  fail "start-gateway default is not 'true'"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
cmds = d.get('provides', {}).get('commands', [])
assert 'kiro-cli' in cmds and 'kirocrew' in cmds
" 2>/dev/null; then
  pass "provides commands include kiro-cli and kirocrew"
else
  fail "provides.commands missing kiro-cli or kirocrew"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
svcs = d.get('provides', {}).get('services', [])
assert 'kirocrew-gateway' in svcs
" 2>/dev/null; then
  pass "provides services include kirocrew-gateway"
else
  fail "provides.services missing kirocrew-gateway"
fi

# ── install.sh ───────────────────────────────────────────────────────────────
header "install.sh"
INSTALL="${PACK_DIR}/install.sh"

if [[ -f "${INSTALL}" ]]; then
  pass "install.sh exists"
else
  fail "install.sh missing"; exit 1
fi

if [[ -x "${INSTALL}" ]]; then
  pass "install.sh is executable"
else
  fail "install.sh is NOT executable"
fi

if bash -n "${INSTALL}" 2>/dev/null; then
  pass "install.sh bash syntax OK"
else
  fail "install.sh has bash syntax errors"
fi

if grep -q "set -euo pipefail" "${INSTALL}"; then
  pass "install.sh uses set -euo pipefail"
else
  fail "install.sh missing set -euo pipefail"
fi

if grep -q 'source "${SCRIPT_DIR}/../common.sh"' "${INSTALL}"; then
  pass "install.sh sources common.sh"
else
  fail "install.sh does not source common.sh"
fi

if grep -q 'write_done_marker' "${INSTALL}"; then
  pass "install.sh calls write_done_marker"
else
  fail "install.sh does not call write_done_marker"
fi

if bash "${INSTALL}" --help >/dev/null 2>&1; then
  pass "install.sh --help exits 0"
else
  fail "install.sh --help does not exit 0"
fi

# ── version pin consistency ──────────────────────────────────────────────────
# The pinned KiroCrew version is stated in three independent places. They drift
# silently on a version bump, and a stale help/manifest value misleads operators
# into passing a channel/version pair that was never published (403 install).
header "version pin consistency"

PIN_MANIFEST="$(python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
print(next(p['default'] for p in d.get('params', []) if p['name'] == 'kirocrew-version'))
" 2>/dev/null || true)"

PIN_CODE="$(sed -n 's/.*pack_config_get kirocrew-version "\([^"]*\)".*/\1/p' "${INSTALL}" | head -1)"

PIN_HELP="$(bash "${INSTALL}" --help 2>/dev/null \
  | sed -n 's/.*--kirocrew-version .*\[default: \([^]]*\)\].*/\1/p' | head -1)"

if [[ -n "${PIN_MANIFEST}" && -n "${PIN_CODE}" && -n "${PIN_HELP}" ]]; then
  pass "pinned version is discoverable in manifest, code, and help"
else
  fail "could not extract pin (manifest='${PIN_MANIFEST}' code='${PIN_CODE}' help='${PIN_HELP}')"
fi

if [[ "${PIN_MANIFEST}" == "${PIN_CODE}" && "${PIN_CODE}" == "${PIN_HELP}" ]]; then
  pass "pin agrees across manifest, code fallback, and help (${PIN_CODE})"
else
  fail "pin disagrees: manifest='${PIN_MANIFEST}' code='${PIN_CODE}' help='${PIN_HELP}'"
fi

# ── arg parser exit codes ────────────────────────────────────────────────────
header "arg parser exit codes"

run_ec() { ( bash "${INSTALL}" "$@" >/dev/null 2>&1 ); echo $?; }

ec=$(run_ec --bogus)
[[ "$ec" == "2" ]] && pass "--bogus → exit 2" || fail "--bogus exit $ec (want 2)"

ec=$(run_ec --kiro-api-key)
[[ "$ec" == "2" ]] && pass "--kiro-api-key (no value) → exit 2" || fail "--kiro-api-key no-value exit $ec (want 2)"

ec=$(run_ec some_positional)
[[ "$ec" == "2" ]] && pass "positional arg → exit 2" || fail "positional exit $ec (want 2)"

ec=$(run_ec --kiro-api-key --from-secret foo)
[[ "$ec" == "2" ]] && pass "--kiro-api-key with flag-like value → exit 2" || fail "flag-like --kiro-api-key exit $ec"

ec=$(run_ec --model)
[[ "$ec" == "2" ]] && pass "--model (no value) → exit 2" || fail "--model no-value exit $ec (want 2)"

# CRITICAL: --model must be ACCEPTED (bootstrap passes it to all packs)
ec=$(run_ec --model kiro-cloud --help)
[[ "$ec" == "0" ]] && pass "--model kiro-cloud accepted (not rejected)" || fail "--model kiro-cloud rejected (exit $ec, want 0)"

ec=$(run_ec --region --something)
[[ "$ec" == "2" ]] && pass "--region with flag-like value → exit 2" || fail "flag-like --region exit $ec"

ec=$(run_ec --from-secret --bogus)
[[ "$ec" == "2" ]] && pass "--from-secret with flag-like value → exit 2" || fail "flag-like --from-secret exit $ec"

ec=$(run_ec --channel)
[[ "$ec" == "2" ]] && pass "--channel (no value) → exit 2" || fail "--channel no-value exit $ec (want 2)"

ec=$(run_ec --channel invalid)
[[ "$ec" == "2" ]] && pass "--channel invalid → exit 2" || fail "--channel invalid exit $ec (want 2)"

ec=$(run_ec --channel stable --help)
[[ "$ec" == "0" ]] && pass "--channel stable accepted" || fail "--channel stable rejected (exit $ec)"

ec=$(run_ec --channel nightly --help)
[[ "$ec" == "0" ]] && pass "--channel nightly accepted" || fail "--channel nightly rejected (exit $ec)"

ec=$(run_ec --channel insider --help)
[[ "$ec" == "0" ]] && pass "--channel insider accepted" || fail "--channel insider rejected (exit $ec)"

ec=$(run_ec --gateway-port abc)
[[ "$ec" == "2" ]] && pass "--gateway-port abc → exit 2" || fail "--gateway-port abc exit $ec (want 2)"

ec=$(run_ec --start-gateway maybe)
[[ "$ec" == "2" ]] && pass "--start-gateway maybe → exit 2" || fail "--start-gateway maybe exit $ec (want 2)"

# ── Phase 1 feature signals ─────────────────────────────────────────────────
header "Phase 1 feature signals"

if grep -q "KIRO_API_KEY" "${INSTALL}"; then
  pass "install.sh references KIRO_API_KEY (headless mode)"
else
  fail "install.sh missing KIRO_API_KEY"
fi

if grep -q '\-\-from\-secret' "${INSTALL}"; then
  pass "install.sh supports --from-secret"
else
  fail "install.sh missing --from-secret"
fi

if grep -q 'no-interactive' "${INSTALL}"; then
  pass "install.sh docs mention --no-interactive"
else
  fail "install.sh docs miss --no-interactive"
fi

if grep -qE 'KIROCLI_MAJOR *> *2|> 2 ' "${INSTALL}" || grep -q 'KIROCLI_MAJOR > 2' "${INSTALL}"; then
  pass "install.sh warns on kiro-cli v3+ (future compat)"
else
  fail "install.sh missing v3+ compat warning"
fi

if grep -q 'umask 077' "${INSTALL}"; then
  pass "install.sh uses umask 077 for env file"
else
  fail "install.sh missing umask 077"
fi

if grep -q 'chmod 600' "${INSTALL}"; then
  pass "install.sh chmod 600 on env file"
else
  fail "install.sh missing chmod 600"
fi

if grep -q 'install_aws_mcp_proxy' "${INSTALL}"; then
  pass "install.sh calls install_aws_mcp_proxy"
else
  fail "install.sh missing install_aws_mcp_proxy"
fi

if grep -q 'ensure_skills_clone' "${INSTALL}"; then
  pass "install.sh calls ensure_skills_clone"
else
  fail "install.sh missing ensure_skills_clone"
fi

# ── Phase 2 feature signals ─────────────────────────────────────────────────
header "Phase 2 feature signals"

if grep -q "download.crew.kiro.dev/cli.sh" "${INSTALL}"; then
  pass "install.sh references KiroCrew installer URL"
else
  fail "install.sh missing KiroCrew installer URL"
fi

if grep -q '\-\-channel' "${INSTALL}"; then
  pass "install.sh supports --channel"
else
  fail "install.sh missing --channel"
fi

if grep -q 'python3.10\|python3.11\|python3.12\|python3.13' "${INSTALL}"; then
  pass "install.sh checks Python ≥3.10 candidates"
else
  fail "install.sh missing Python version check"
fi

if grep -q 'kirocrew doctor' "${INSTALL}"; then
  pass "install.sh runs kirocrew doctor"
else
  fail "install.sh missing kirocrew doctor"
fi

if grep -q '\-t 0\|isatty\|TTY' "${INSTALL}"; then
  pass "install.sh has TTY guard for kirocrew setup"
else
  fail "install.sh missing TTY guard for setup"
fi

if grep -q 'pipx' "${INSTALL}"; then
  pass "install.sh handles pipx"
else
  fail "install.sh missing pipx handling"
fi

if grep -q 'kirocrew-gateway.service' "${INSTALL}"; then
  pass "install.sh references systemd service"
else
  fail "install.sh missing systemd service reference"
fi

if grep -q 'firewall-cmd' "${INSTALL}"; then
  pass "install.sh opens firewall port"
else
  fail "install.sh missing firewall-cmd"
fi

if grep -q 'Preload\|preload\|embedding.*model\|model.*download' "${INSTALL}"; then
  pass "install.sh has embedding model preload"
else
  fail "install.sh missing embedding model preload"
fi

# ── shell-profile.sh ─────────────────────────────────────────────────────────
header "resources/shell-profile.sh"
PROFILE="${PACK_DIR}/resources/shell-profile.sh"

if [[ -f "${PROFILE}" ]]; then
  pass "shell-profile.sh exists"
else
  fail "shell-profile.sh missing"
fi

# Must NOT contain a KIRO_API_KEY assignment (world-readable in /etc/profile.d)
if grep -qE '^[^#]*KIRO_API_KEY=[^}]' "${PROFILE}" 2>/dev/null; then
  fail "shell-profile.sh contains a KIRO_API_KEY assignment (leaks to world-readable)"
else
  pass "shell-profile.sh does not write KIRO_API_KEY (stays secret-free)"
fi

if grep -q 'kirocrew' "${PROFILE}"; then
  pass "shell-profile.sh references kirocrew command"
else
  fail "shell-profile.sh missing kirocrew reference"
fi

# Verify profile is installed with unique name (not kiro-cli.sh)
if grep -q 'kirocrew.sh' "${INSTALL}"; then
  pass "install.sh installs profile as kirocrew.sh (no collision)"
else
  fail "install.sh does not use unique profile filename"
fi

# ── systemd unit ─────────────────────────────────────────────────────────────
header "resources/kirocrew-gateway.service"
UNIT="${PACK_DIR}/resources/kirocrew-gateway.service"

if [[ -f "${UNIT}" ]]; then
  pass "kirocrew-gateway.service exists"
else
  fail "kirocrew-gateway.service missing"
fi

if grep -q '__PORT__' "${UNIT}"; then
  pass "unit has __PORT__ placeholder"
else
  fail "unit missing __PORT__ placeholder"
fi

if grep -q '__HOME__' "${UNIT}"; then
  pass "unit has __HOME__ placeholder"
else
  fail "unit missing __HOME__ placeholder"
fi

if grep -q '__BINPATH__' "${UNIT}"; then
  pass "unit has __BINPATH__ placeholder"
else
  fail "unit missing __BINPATH__ placeholder"
fi

if grep -q 'User=ec2-user' "${UNIT}"; then
  pass "unit runs as ec2-user"
else
  fail "unit not running as ec2-user"
fi

if grep -q 'NoNewPrivileges=true' "${UNIT}"; then
  pass "unit has NoNewPrivileges hardening"
else
  fail "unit missing NoNewPrivileges"
fi

if grep -q 'ProtectSystem=strict' "${UNIT}"; then
  pass "unit has ProtectSystem=strict"
else
  fail "unit missing ProtectSystem=strict"
fi

if grep -q 'ReadWritePaths=/home/ec2-user/.kiro' "${UNIT}"; then
  pass "unit ReadWritePaths covers ~/.kiro"
else
  fail "unit ReadWritePaths too narrow (should cover ~/.kiro)"
fi

# ── Registry consistency ─────────────────────────────────────────────────────
header "registry consistency"

if grep -q "^  kirocrew:" "${REPO_DIR}/packs/registry.yaml" 2>/dev/null; then
  pass "kirocrew listed in registry.yaml"
else
  fail "kirocrew NOT in registry.yaml"
fi

if python3 -c "
import json
d = json.load(open('${REPO_DIR}/packs/registry.json'))
assert 'kirocrew' in d.get('packs', {}), 'not in packs'
" 2>/dev/null; then
  pass "kirocrew listed in registry.json"
else
  fail "kirocrew NOT in registry.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n\033[1;36m────────────────────────────────────────\033[0m\n"
printf "  Passed: \033[0;32m%d\033[0m\n" "${passed}"
printf "  Failed: \033[0;31m%d\033[0m\n" "${failed}"
if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
