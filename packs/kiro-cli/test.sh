#!/usr/bin/env bash
# packs/kiro-cli/test.sh — offline tests for kiro-cli pack
# Validates manifest structure, install.sh syntax, v2 auth features,
# arg parser strictness, and secure on-disk handling of KIRO_API_KEY.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"

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
  fail "manifest.yaml missing"
  exit 1
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
assert d['name'] == 'kiro-cli', f\"name is {d['name']}\"
" 2>/dev/null; then
  pass "manifest name is kiro-cli"
else
  fail "manifest name != kiro-cli"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d['version'].startswith('2.'), f\"version is {d['version']}, expected 2.x\"
" 2>/dev/null; then
  pass "manifest version is 2.x"
else
  fail "manifest version is not 2.x"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
names = [p['name'] for p in d.get('params', [])]
assert 'from-secret' in names, f\"missing from-secret param (got {names})\"
" 2>/dev/null; then
  pass "manifest has 'from-secret' v2 auth param"
else
  fail "manifest missing 'from-secret' param"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
for p in d.get('params', []):
    assert 'default' in p, f\"param {p.get('name','?')} missing default\"
" 2>/dev/null; then
  pass "all params have default"
else
  fail "some params missing default"
fi

if python3 -c "
import yaml
d = yaml.safe_load(open('${MANIFEST}'))
assert d.get('deps', []) == [], 'deps should be []'
" 2>/dev/null; then
  pass "manifest deps is empty (no bedrockify)"
else
  fail "manifest deps should be empty"
fi

# ── install.sh ───────────────────────────────────────────────────────────────
header "install.sh"
INSTALL="${PACK_DIR}/install.sh"

if [[ -f "${INSTALL}" ]]; then
  pass "install.sh exists"
else
  fail "install.sh missing"
  exit 1
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

# ── arg parser (exit codes) ──────────────────────────────────────────────────
header "arg parser exit codes (review fixes)"

# Helper: run install.sh with given args, capture exit code
run_ec() { ( bash "${INSTALL}" "$@" >/dev/null 2>&1 ); echo $?; }

ec=$(run_ec --bogus)
[[ "$ec" == "2" ]] && pass "--bogus → exit 2" || fail "--bogus exit $ec (want 2)"

ec=$(run_ec --kiro-api-key)
[[ "$ec" == "2" ]] && pass "--kiro-api-key (no value) → exit 2" || fail "--kiro-api-key no-value exit $ec (want 2)"

ec=$(run_ec some_positional)
[[ "$ec" == "2" ]] && pass "positional arg → exit 2" || fail "positional exit $ec (want 2)"

# Review HIGH #2: --kiro-api-key with flag-like value must be rejected,
# not silently accept '--from-secret' as the key.
ec=$(run_ec --kiro-api-key --from-secret foo)
[[ "$ec" == "2" ]] && pass "--kiro-api-key with flag-like value → exit 2" || fail "flag-like --kiro-api-key exit $ec"

# Review HIGH #2: --model with no value must fail-fast, not silently drop.
ec=$(run_ec --model)
[[ "$ec" == "2" ]] && pass "--model (no value) → exit 2" || fail "--model no-value exit $ec (want 2)"

# Review HIGH #2: --region with flag-like value must be rejected.
ec=$(run_ec --region --something)
[[ "$ec" == "2" ]] && pass "--region with flag-like value → exit 2" || fail "flag-like --region exit $ec"

# Review HIGH #2: --from-secret with flag-like value must be rejected.
ec=$(run_ec --from-secret --bogus)
[[ "$ec" == "2" ]] && pass "--from-secret with flag-like value → exit 2" || fail "flag-like --from-secret exit $ec"

# Review HIGH #3: mutex conflict is a parser-level failure → exit 2, not 1.
ec=$(run_ec --kiro-api-key foo --from-secret bar)
[[ "$ec" == "2" ]] && pass "mutex (--kiro-api-key + --from-secret) → exit 2" || fail "mutex conflict exit $ec (want 2, got $ec)"

# ── v2 feature signals in install.sh ─────────────────────────────────────────
header "v2 feature signals"

if grep -q "KIRO_API_KEY" "${INSTALL}"; then
  pass "install.sh mentions KIRO_API_KEY (headless mode)"
else
  fail "install.sh does not reference KIRO_API_KEY"
fi

if grep -q '\-\-from\-secret' "${INSTALL}"; then
  pass "install.sh supports --from-secret (Secrets Manager resolve)"
else
  fail "install.sh missing --from-secret"
fi

if grep -q 'no-interactive' "${INSTALL}"; then
  pass "install.sh docs mention --no-interactive (v2 headless flag)"
else
  fail "install.sh docs miss --no-interactive"
fi

# Review MEDIUM #2: explicit v3+ forward-compat warn.
if grep -qE 'KIROCLI_MAJOR *> *2|> 2 ' "${INSTALL}"; then
  pass "install.sh warns on kiro-cli v3+ (future compat)"
else
  fail "install.sh missing v3+ compat warning"
fi

# Review MEDIUM #3: help must NOT promise the key is written to
# /etc/profile.d/... (it actually lives in ~/.kiro/env with 0600 perms).
if grep -q '/etc/profile.d/kiro-cli.sh.*KIRO_API_KEY\|KIRO_API_KEY.*/etc/profile.d/kiro-cli.sh' "${INSTALL}"; then
  fail "install.sh help claims key goes to /etc/profile.d/kiro-cli.sh (lie)"
else
  pass "install.sh help does not lie about key location"
fi

# ── secure on-disk handling (review MEDIUM #1) ───────────────────────────────
header "secure on-disk handling of KIRO_API_KEY"

# Check the install.sh writes to ~/.kiro/env with 0600 — static check
if grep -q 'chmod 600.*KIRO_ENV_FILE\|KIRO_ENV_FILE.*chmod 600' "${INSTALL}" \
   || grep -qE 'chmod 600 "\$\{?KIRO_ENV_FILE\}?"' "${INSTALL}"; then
  pass "install.sh chmods ~/.kiro/env to 600"
else
  fail "install.sh does not chmod ~/.kiro/env to 600"
fi

# Check umask 077 is used around the write
if grep -q 'umask 077' "${INSTALL}"; then
  pass "install.sh uses umask 077 when writing the env file"
else
  fail "install.sh missing umask 077 guard"
fi

# Check %q is used for safe shell escaping of the key
if grep -qE 'printf .export KIRO_API_KEY=%q' "${INSTALL}"; then
  pass "install.sh uses %q to escape KIRO_API_KEY value"
else
  fail "install.sh does not use %q escaping"
fi

# Check the shell profile (world-readable /etc/profile.d/kiro-cli.sh)
# does NOT contain the literal 'KIRO_API_KEY=' assignment. The profile
# can *mention* KIRO_API_KEY (checking if set, etc.), but must never
# write an assignment.
PROFILE="${PACK_DIR}/resources/shell-profile.sh"
if [[ -f "${PROFILE}" ]]; then
  if grep -qE '^[^#]*KIRO_API_KEY=(\"|\x27|[^ =])' "${PROFILE}"; then
    fail "shell-profile.sh contains a KIRO_API_KEY assignment (leaks to world-readable /etc/profile.d)"
  else
    pass "shell-profile.sh does not write KIRO_API_KEY (stays secret-free)"
  fi
fi

# Check install.sh uses a source-marker for idempotent .bash_profile append
if grep -q 'lowkey-kiro-cli-env-source' "${INSTALL}"; then
  pass "install.sh uses exact marker for idempotent .bash_profile append"
else
  fail "install.sh missing stable idempotency marker"
fi

# Check --from-secret path uses JSON output (not --output text) so empty
# SecretString doesn't become literal 'None' (HIGH #4).
if grep -q 'output json' "${INSTALL}"; then
  pass "install.sh uses --output json for Secrets Manager (guards against 'None' bug)"
else
  fail "install.sh still uses --output text for Secrets Manager"
fi

# ── shell-profile.sh ─────────────────────────────────────────────────────────
header "resources/shell-profile.sh"

if [[ -f "${PROFILE}" ]]; then
  pass "shell-profile.sh exists"
else
  fail "shell-profile.sh missing"
fi

# Review MEDIUM #3: profile must be auth-mode-aware, not hardcode "interactive required"
if grep -q 'KIRO_API_KEY.*\|.kiro/env' "${PROFILE}" 2>/dev/null; then
  pass "shell-profile.sh is auth-mode-aware (checks ~/.kiro/env / KIRO_API_KEY)"
else
  fail "shell-profile.sh still hardcodes interactive-login assumption"
fi

if grep -q 'kiro-cli --no-interactive' "${PROFILE}" 2>/dev/null; then
  pass "shell-profile.sh documents --no-interactive usage"
else
  fail "shell-profile.sh missing --no-interactive hint"
fi

# ── deploy flow wiring (review HIGH #1) ──────────────────────────────────────
header "deploy flow wiring for --from-secret"

REPO_DIR="$(cd "${PACK_DIR}/../.." && pwd)"

# install.sh top-level: KiroFromSecret in PARAM arrays
if grep -q 'KiroFromSecret' "${REPO_DIR}/install.sh"; then
  pass "install.sh (top-level) declares KiroFromSecret CFN param"
else
  fail "install.sh (top-level) missing KiroFromSecret"
fi

# install.sh top-level: --kiro-from-secret CLI flag
if grep -q 'kiro-from-secret' "${REPO_DIR}/install.sh"; then
  pass "install.sh (top-level) accepts --kiro-from-secret"
else
  fail "install.sh (top-level) missing --kiro-from-secret flag"
fi

# bootstrap.sh: --kiro-from-secret flag
if grep -q 'kiro-from-secret' "${REPO_DIR}/deploy/bootstrap.sh"; then
  pass "bootstrap.sh accepts --kiro-from-secret"
else
  fail "bootstrap.sh does not accept --kiro-from-secret"
fi

# bootstrap.sh: from-secret key written into PACK_CONFIG JSON
if grep -q '"from-secret"' "${REPO_DIR}/deploy/bootstrap.sh"; then
  pass "bootstrap.sh writes from-secret into PACK_CONFIG"
else
  fail "bootstrap.sh does not write from-secret into PACK_CONFIG"
fi

# CFN template: KiroFromSecret param
if grep -q 'KiroFromSecret' "${REPO_DIR}/deploy/cloudformation/template.yaml"; then
  pass "CFN template declares KiroFromSecret parameter"
else
  fail "CFN template missing KiroFromSecret parameter"
fi

# ── Registry consistency ──────────────────────────────────────────────────────
header "registry consistency"

if grep -q "^  kiro-cli:" "${REPO_DIR}/packs/registry.yaml" 2>/dev/null; then
  pass "kiro-cli listed in registry.yaml"
else
  fail "kiro-cli NOT in registry.yaml"
fi

if python3 -c "
import json
d = json.load(open('${REPO_DIR}/packs/registry.json'))
assert 'kiro-cli' in d.get('packs', {}), 'not in packs'
" 2>/dev/null; then
  pass "kiro-cli listed in registry.json"
else
  fail "kiro-cli NOT in registry.json"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf "\n\033[1;36m────────────────────────────────────────\033[0m\n"
printf "  Passed: \033[0;32m%d\033[0m\n" "${passed}"
printf "  Failed: \033[0;31m%d\033[0m\n" "${failed}"
if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
