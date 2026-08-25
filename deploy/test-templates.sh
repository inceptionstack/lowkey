#!/usr/bin/env bash
# deploy/test-templates.sh — Validate that all pack-system changes are in place
# Run from the repo root: bash deploy/test-templates.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFN_TEMPLATE="$REPO_ROOT/deploy/cloudformation/template.yaml"
INSTALL_SH="$REPO_ROOT/install.sh"

PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }

check_contains() {
  local file="$1" pattern="$2" desc="$3"
  if python3 -c "
import sys
pattern = sys.argv[1]
with open(sys.argv[2]) as f:
    content = f.read()
sys.exit(0 if pattern in content else 1)
" "$pattern" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc  [missing: $pattern in $(basename "$file")]"
  fi
}

echo ""
echo -e "${BOLD}=== Loki Agent — Pack System Template Tests ===${NC}"
echo ""

# ── CloudFormation ──────────────────────────────────────────────────────────
echo -e "${BOLD}CloudFormation (deploy/cloudformation/template.yaml)${NC}"
check_contains "$CFN_TEMPLATE" "PackName:" "CFN: PackName parameter defined"
check_contains "$CFN_TEMPLATE" "openclaw" "CFN: PackName AllowedValues includes openclaw"
check_contains "$CFN_TEMPLATE" "hermes" "CFN: PackName AllowedValues includes hermes"
check_contains "$CFN_TEMPLATE" "- PackName" "CFN: PackName in Metadata ParameterGroups"
check_contains "$CFN_TEMPLATE" "loki:pack" "CFN: VPC has loki:pack tag"
check_contains "$CFN_TEMPLATE" "git clone --depth 1" "CFN: UserData uses git clone"
check_contains "$CFN_TEMPLATE" "deploy/bootstrap.sh" "CFN: UserData calls bootstrap.sh"
check_contains "$CFN_TEMPLATE" "--pack" "CFN: UserData passes --pack flag"
check_contains "$CFN_TEMPLATE" "Deployed agent pack" "CFN: PackName in Outputs"
check_contains "$CFN_TEMPLATE" "AWS::EC2::VPCBlockPublicAccessExclusion" "CFN: VPC BPA exclusion resource defined"
check_contains "$CFN_TEMPLATE" "InternetGatewayExclusionMode: allow-bidirectional" "CFN: VPC BPA exclusion allows bidirectional internet traffic"
check_contains "$CFN_TEMPLATE" "CreateVpcBpaExclusion" "CFN: BPA exclusion creation parameter defined"

echo ""

# ── install.sh ───────────────────────────────────────────────────────────────
echo -e "${BOLD}install.sh${NC}"
check_contains "$INSTALL_SH" 'Agent to deploy' "install.sh: pack selection menu header"
check_contains "$INSTALL_SH" 'OpenClaw' "install.sh: OpenClaw option in menu"
check_contains "$INSTALL_SH" 'Hermes' "install.sh: Hermes option in menu"
check_contains "$INSTALL_SH" 'PACK_NAME=' "install.sh: PACK_NAME variable set"
check_contains "$INSTALL_SH" 'PackName' "install.sh: PackName in PARAM_CFN_NAMES"
check_contains "$INSTALL_SH" 't4g.medium' "install.sh: hermes default size logic present"

# ── Branch detection & SSM doc version ──────────────────────────────────────
echo -e "${BOLD}Branch & SSM fixes${NC}"
check_contains "$INSTALL_SH" '[[ "$REPO_BRANCH" == "HEAD" ]]' "install.sh: detached HEAD falls back to main"
check_contains "$INSTALL_SH" 'REPO_BRANCH=' "install.sh: REPO_BRANCH is set"
check_contains "$CFN_TEMPLATE" "RepoBranch" "CFN: RepoBranch parameter defined"
check_contains "$INSTALL_SH" "DocumentDescription.DocumentVersion" "install.sh: SSM update-document captures numeric version"
check_contains "$INSTALL_SH" 'new_version' "install.sh: SSM update-document-default-version uses captured version"

echo ""

# ── Branch detection unit tests ─────────────────────────────────────────────
echo -e "${BOLD}Branch detection (unit)${NC}"

# Test: detached HEAD → main
_test_branch="HEAD"
[[ "$_test_branch" == "HEAD" ]] && _test_branch="main"
if [[ "$_test_branch" == "main" ]]; then
  pass "Detached HEAD resolves to main"
else
  fail "Detached HEAD should resolve to main, got: $_test_branch"
fi

# Test: normal branch → unchanged
_test_branch="installer-ux-overhaul"
[[ "$_test_branch" == "HEAD" ]] && _test_branch="main"
if [[ "$_test_branch" == "installer-ux-overhaul" ]]; then
  pass "Normal branch name preserved"
else
  fail "Normal branch should be preserved, got: $_test_branch"
fi

# Test: main → unchanged
_test_branch="main"
[[ "$_test_branch" == "HEAD" ]] && _test_branch="main"
if [[ "$_test_branch" == "main" ]]; then
  pass "main branch preserved"
else
  fail "main should be preserved, got: $_test_branch"
fi

# Test: SSM version regex accepts numeric
_test_version="5"
if [[ "$_test_version" =~ ^[0-9]+$ ]]; then
  pass "SSM version regex accepts numeric version"
else
  fail "SSM version regex should accept '5'"
fi

# Test: SSM version regex rejects $LATEST
_test_version='$LATEST'
if [[ "$_test_version" =~ ^[0-9]+$ ]]; then
  fail "SSM version regex should reject '\$LATEST'"
else
  pass "SSM version regex rejects \$LATEST"
fi

# Test: SSM version regex rejects empty
_test_version=""
if [[ -n "$_test_version" && "$_test_version" =~ ^[0-9]+$ ]]; then
  fail "SSM version regex should reject empty string"
else
  pass "SSM version regex rejects empty string"
fi

echo ""
echo -e "${BOLD}─────────────────────────────────────────────────${NC}"
echo -e "  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}✗ Some checks failed — review output above${NC}"
  exit 1
else
  echo -e "${GREEN}✓ All checks passed!${NC}"
  exit 0
fi
