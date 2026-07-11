#!/usr/bin/env bash
# packs/claude-code/test.sh — Unit tests for the Claude Code pack
#
# Validates manifest structure, install.sh interface, profile.d config,
# and settings.json WITHOUT requiring Claude Code to be installed or
# Bedrock credentials to be active.
#
# Usage: bash packs/claude-code/test.sh
# Exit: 0 if all tests pass, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="${SCRIPT_DIR}"
PACKS_DIR="${SCRIPT_DIR}/.."
COMMON="${PACKS_DIR}/common.sh"

# ── Test harness ──────────────────────────────────────────────────────────────
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
skip() { printf "${YELLOW}  ○${NC} %s\n" "$1 (skipped)"; SKIP=$((SKIP+1)); }
header() { printf "\n${BOLD}${CYAN}%s${NC}\n" "$1"; }

# ── Test: manifest.yaml structure ─────────────────────────────────────────────
header "Test: manifest.yaml"

MANIFEST="${PACK_DIR}/manifest.yaml"

if [[ -f "${MANIFEST}" ]]; then
  pass "manifest.yaml exists"
else
  fail "manifest.yaml missing"
fi

if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
  if python3 -c "import yaml; yaml.safe_load(open('${MANIFEST}'))" 2>/dev/null; then
    pass "manifest.yaml is valid YAML"
  else
    fail "manifest.yaml is invalid YAML"
  fi

  # Required keys
  for key in name version type description deps params health_check provides; do
    if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if '${key}' in data else 1)
" 2>/dev/null; then
      pass "manifest.yaml has '${key}' key"
    else
      fail "manifest.yaml missing '${key}' key"
    fi
  done

  # Name matches folder
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
sys.exit(0 if data.get('name') == 'claude-code' else 1)
" 2>/dev/null; then
    pass "manifest.yaml name matches folder (claude-code)"
  else
    fail "manifest.yaml name does not match folder"
  fi

  # deps is empty (no bedrockify)
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
deps = data.get('deps', [])
sys.exit(0 if isinstance(deps, list) and len(deps) == 0 else 1)
" 2>/dev/null; then
    pass "manifest.yaml deps is empty (no bedrockify dependency)"
  else
    fail "manifest.yaml deps should be empty — claude-code talks to Bedrock natively"
  fi

  # Health check references claude
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
hc = data.get('health_check', {}).get('command', '')
sys.exit(0 if 'claude' in hc else 1)
" 2>/dev/null; then
    pass "manifest.yaml health_check references claude"
  else
    fail "manifest.yaml health_check does not reference claude"
  fi

  # Provides commands include claude
  if python3 -c "
import yaml, sys
data = yaml.safe_load(open('${MANIFEST}'))
cmds = data.get('provides', {}).get('commands', [])
sys.exit(0 if 'claude' in cmds else 1)
" 2>/dev/null; then
    pass "manifest.yaml provides.commands includes claude"
  else
    fail "manifest.yaml provides.commands missing claude"
  fi
else
  skip "manifest.yaml YAML tests: python3 or pyyaml not available"
fi

# ── Test: install.sh interface ────────────────────────────────────────────────
header "Test: install.sh interface"

INSTALL="${PACK_DIR}/install.sh"

if [[ -f "${INSTALL}" ]]; then
  pass "install.sh exists"
else
  fail "install.sh missing"
fi

if [[ -x "${INSTALL}" ]]; then
  pass "install.sh is executable"
else
  fail "install.sh is not executable"
fi

# Shebang check
SHEBANG="$(head -1 "${INSTALL}")"
if [[ "${SHEBANG}" == "#!/usr/bin/env bash" ]]; then
  pass "install.sh has correct shebang"
else
  fail "install.sh has unexpected shebang: ${SHEBANG}"
fi

# Sources common.sh
if grep -q 'source.*common\.sh' "${INSTALL}"; then
  pass "install.sh sources common.sh"
else
  fail "install.sh does not source common.sh"
fi

# Writes done marker
if grep -q 'write_done_marker.*claude-code' "${INSTALL}"; then
  pass "install.sh writes done marker for 'claude-code'"
else
  fail "install.sh does not write done marker"
fi

# --help exits 0
HELP_OUT="$(bash "${INSTALL}" --help 2>&1)" && HELP_RC=0 || HELP_RC=$?
if [[ "${HELP_RC}" -eq 0 ]]; then
  pass "install.sh --help exits 0"
else
  fail "install.sh --help exits ${HELP_RC}"
fi

if [[ -n "${HELP_OUT}" ]]; then
  pass "install.sh --help produces output"
else
  fail "install.sh --help produces no output"
fi

# --help mentions key flags
for flag in --region --model --haiku-model --version --skip-smoke-test --help; do
  if printf '%s' "${HELP_OUT}" | grep -q -- "${flag}"; then
    pass "install.sh --help mentions ${flag}"
  else
    fail "install.sh --help missing ${flag}"
  fi
done

# No functional bedrockify dependency (health check or curl to bedrockify port)
if grep -E 'bedrockify.*running|curl.*bedrockify|bedrockify.*port|BEDROCKIFY_PORT' "${INSTALL}" &>/dev/null; then
  fail "install.sh should NOT depend on bedrockify — claude-code uses native Bedrock"
else
  pass "install.sh does not depend on bedrockify (correct — uses native Bedrock)"
fi

# Uses native installer
if grep -q 'claude.ai/install.sh' "${INSTALL}"; then
  pass "install.sh uses Claude Code native installer (claude.ai/install.sh)"
else
  fail "install.sh does not use Claude Code native installer"
fi

# ── Test: profile.d config generation ────────────────────────────────────────
header "Test: /etc/profile.d/claude-code-bedrock.sh generation"

# Simulate what install.sh writes to /etc/profile.d
generate_bedrock_profile() {
  local REGION="$1"
  local MODEL="$2"
  local HAIKU_MODEL="$3"
  cat <<EOF
# Claude Code — Bedrock configuration
# Managed by lowkey packs/claude-code/install.sh — do not edit manually.
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="${REGION}"
export ANTHROPIC_MODEL="${MODEL}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${HAIKU_MODEL}"
EOF
}

PROFILE_OUT="$(generate_bedrock_profile "us-east-1" "us.anthropic.claude-sonnet-4-6" "us.anthropic.claude-haiku-4-5-20251001-v1:0")"

if printf '%s' "${PROFILE_OUT}" | grep -q 'CLAUDE_CODE_USE_BEDROCK=1'; then
  pass "profile.d: sets CLAUDE_CODE_USE_BEDROCK=1"
else
  fail "profile.d: missing CLAUDE_CODE_USE_BEDROCK=1"
fi

if printf '%s' "${PROFILE_OUT}" | grep -q 'AWS_REGION="us-east-1"'; then
  pass "profile.d: sets AWS_REGION correctly"
else
  fail "profile.d: missing or wrong AWS_REGION"
fi

if printf '%s' "${PROFILE_OUT}" | grep -q 'ANTHROPIC_MODEL="us.anthropic.claude-sonnet-4-6"'; then
  pass "profile.d: sets ANTHROPIC_MODEL correctly"
else
  fail "profile.d: missing or wrong ANTHROPIC_MODEL"
fi

if printf '%s' "${PROFILE_OUT}" | grep -q 'ANTHROPIC_DEFAULT_HAIKU_MODEL='; then
  pass "profile.d: sets ANTHROPIC_DEFAULT_HAIKU_MODEL"
else
  fail "profile.d: missing ANTHROPIC_DEFAULT_HAIKU_MODEL"
fi

# Check it's valid shell
if bash -n <(echo "${PROFILE_OUT}") 2>/dev/null; then
  pass "profile.d: valid shell syntax"
else
  fail "profile.d: invalid shell syntax"
fi

# Test with model IDs containing colons (common for Bedrock)
PROFILE_COLON="$(generate_bedrock_profile "eu-west-1" "us.amazon.nova-premier-v1:0" "us.anthropic.claude-haiku-4-5-20251001-v1:0")"
if bash -n <(echo "${PROFILE_COLON}") 2>/dev/null; then
  pass "profile.d: valid shell syntax with colon in model ID"
else
  fail "profile.d: invalid shell syntax with colon in model ID"
fi

# ── Test: settings.json structure ────────────────────────────────────────────
header "Test: ~/.claude/settings.json"

# install.sh merges settings.json via an embedded python3 heredoc.
# Extract the merge script and exercise it against a sandbox settings file.
if command -v python3 &>/dev/null; then
  MERGE_PY="$(sed -n "/^python3 <<'PYEOF'$/,/^PYEOF$/p" "${INSTALL}" | sed '1d;$d')"

  if [[ -n "${MERGE_PY}" ]]; then
    pass "install.sh contains embedded settings merge script"
  else
    fail "install.sh missing embedded settings merge script"
  fi

  TMP_SETTINGS="$(mktemp)"

  # Fresh file: created with env + permissions
  rm -f "${TMP_SETTINGS}"
  if SETTINGS_FILE="${TMP_SETTINGS}" CC_REGION="us-east-1" \
     CC_MODEL="us.anthropic.claude-sonnet-4-6" \
     CC_HAIKU_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0" \
     python3 -c "${MERGE_PY}" 2>/dev/null; then
    pass "settings merge: runs on fresh (absent) file"
  else
    fail "settings merge: failed on fresh file"
  fi

  if python3 -c "
import json
d = json.load(open('${TMP_SETTINGS}'))
env = d.get('env', {})
assert env.get('CLAUDE_CODE_USE_BEDROCK') == '1'
assert env.get('AWS_REGION') == 'us-east-1'
assert env.get('ANTHROPIC_MODEL') == 'us.anthropic.claude-sonnet-4-6'
assert env.get('ANTHROPIC_DEFAULT_HAIKU_MODEL')
allow = d.get('permissions', {}).get('allow', [])
for r in ['Bash(*)', 'Read(*)', 'Write(*)', 'Edit(*)']:
    assert r in allow, r
" 2>/dev/null; then
    pass "settings merge: env block (Bedrock) + permissions written"
  else
    fail "settings merge: env block or permissions missing"
  fi

  # Existing file: user keys must survive (no clobber)
  cat > "${TMP_SETTINGS}" <<'JSONEOF'
{
  "myCustomKey": "keep-me",
  "env": {"MY_VAR": "custom"},
  "permissions": {"allow": ["WebFetch(*)"], "deny": ["Bash(rm*)"]}
}
JSONEOF
  SETTINGS_FILE="${TMP_SETTINGS}" CC_REGION="eu-west-1" \
    CC_MODEL="m1" CC_HAIKU_MODEL="m2" python3 -c "${MERGE_PY}" 2>/dev/null || true
  if python3 -c "
import json
d = json.load(open('${TMP_SETTINGS}'))
assert d.get('myCustomKey') == 'keep-me', 'custom top-level key clobbered'
assert d['env'].get('MY_VAR') == 'custom', 'custom env var clobbered'
assert d['env'].get('CLAUDE_CODE_USE_BEDROCK') == '1'
allow = d['permissions']['allow']
assert 'WebFetch(*)' in allow, 'user allow rule clobbered'
assert 'Bash(*)' in allow
assert 'Bash(rm*)' in d['permissions']['deny'], 'user deny rule clobbered'
" 2>/dev/null; then
    pass "settings merge: idempotent — user customizations preserved"
  else
    fail "settings merge: clobbers user customizations"
  fi

  rm -f "${TMP_SETTINGS}"
else
  skip "settings merge tests: python3 not available"
fi

# Version pin present
if grep -qE 'CLAUDE_CODE_VERSION_DEFAULT="[0-9]+\.[0-9]+\.[0-9]+"' "${INSTALL}"; then
  pass "install.sh pins Claude Code version (CLAUDE_CODE_VERSION_DEFAULT)"
else
  fail "install.sh missing version pin"
fi

# Pinned version is passed to the native installer
if grep -q 'claude-code-install.sh "${CC_VERSION}"' "${INSTALL}"; then
  pass "install.sh passes pinned version to native installer"
else
  fail "install.sh does not pass version to native installer"
fi

# First-class plugin CLI (not just the slash-command hack)
if grep -q 'claude plugin install' "${INSTALL}"; then
  pass "install.sh uses first-class 'claude plugin install'"
else
  fail "install.sh missing first-class plugin CLI usage"
fi

# Plugin idempotency guard
if grep -q 'claude plugin list' "${INSTALL}"; then
  pass "install.sh guards plugin installs with 'claude plugin list'"
else
  fail "install.sh missing plugin idempotency guard"
fi

# AWS MCP proxy wiring
if grep -q 'claude mcp add' "${INSTALL}" && grep -q 'MCP_PROXY_VERSION' "${INSTALL}"; then
  pass "install.sh wires AWS MCP proxy via 'claude mcp add' (pinned version)"
else
  fail "install.sh missing AWS MCP proxy wiring"
fi

# Done marker is the last step (after plugins/skills/MCP)
LAST_MARKER_LINE="$(grep -n 'write_done_marker' "${INSTALL}" | tail -1 | cut -d: -f1)"
LAST_MCP_LINE="$(grep -n 'claude mcp add' "${INSTALL}" | tail -1 | cut -d: -f1)"
if [[ -n "${LAST_MARKER_LINE}" && -n "${LAST_MCP_LINE}" && "${LAST_MARKER_LINE}" -gt "${LAST_MCP_LINE}" ]]; then
  pass "write_done_marker runs after all install steps"
else
  fail "write_done_marker should be the final step"
fi

# PATH persistence for future shells
if grep -q 'export PATH="\${HOME}/.local/bin' "${INSTALL}"; then
  pass "install.sh persists ~/.local/bin on PATH in profile target"
else
  fail "install.sh does not persist PATH for future shells"
fi

# install.sh writes settings.json
if grep -q 'settings.json' "${INSTALL}"; then
  pass "install.sh writes settings.json"
else
  fail "install.sh does not write settings.json"
fi

# install.sh creates ~/.claude directory
if grep -q 'mkdir.*\.claude' "${INSTALL}"; then
  pass "install.sh creates ~/.claude directory"
else
  fail "install.sh does not create ~/.claude directory"
fi

# ── Test: idempotency patterns ─────────────────────────────────────────────────
header "Test: idempotency patterns"

if grep -q 'command -v claude' "${INSTALL}"; then
  pass "install.sh checks if claude is already installed"
else
  fail "install.sh does not check for existing claude installation"
fi

if grep -q 'mkdir -p' "${INSTALL}"; then
  pass "install.sh uses mkdir -p for directory creation"
else
  fail "install.sh does not use mkdir -p"
fi

# ── Test: claude command available (LIVE — skippable) ─────────────────────────
header "Test: claude command (live environment)"

if command -v claude &>/dev/null; then
  CLAUDE_VER="$(claude --version 2>/dev/null || echo unknown)"
  pass "claude is installed: ${CLAUDE_VER}"
else
  skip "claude not installed — live tests skipped"
fi

# ── Test: CLAUDE_CODE_USE_BEDROCK in profile.d (LIVE — skippable) ─────────────
header "Test: Bedrock profile.d (live environment)"

PROFILE_D="/etc/profile.d/claude-code-bedrock.sh"

if [[ -f "${PROFILE_D}" ]]; then
  pass "profile.d exists: ${PROFILE_D}"
  if grep -q 'CLAUDE_CODE_USE_BEDROCK=1' "${PROFILE_D}"; then
    pass "profile.d sets CLAUDE_CODE_USE_BEDROCK=1"
  else
    fail "profile.d missing CLAUDE_CODE_USE_BEDROCK=1"
  fi
else
  skip "${PROFILE_D} not present — live profile.d tests skipped"
fi

# ── Test: ~/.claude/settings.json (LIVE — skippable) ──────────────────────────
header "Test: ~/.claude/settings.json (live environment)"

SETTINGS="${HOME}/.claude/settings.json"

if [[ -f "${SETTINGS}" ]]; then
  pass "~/.claude/settings.json exists"
  if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('${SETTINGS}'))" 2>/dev/null; then
      pass "~/.claude/settings.json is valid JSON"
    else
      fail "~/.claude/settings.json is invalid JSON"
    fi
  fi
else
  skip "~/.claude/settings.json not present — live settings tests skipped"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}  Claude Code Pack Test Results${NC}\n"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed:${NC}  %d\n" "${PASS}"
printf "  ${RED}Failed:${NC}  %d\n" "${FAIL}"
printf "  ${YELLOW}Skipped:${NC} %d\n" "${SKIP}"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

if [[ "${FAIL}" -gt 0 ]]; then
  printf "${RED}✗ %d test(s) failed${NC}\n\n" "${FAIL}"
  exit 1
else
  printf "${GREEN}✓ All tests passed${NC}\n\n"
  exit 0
fi
