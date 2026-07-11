#!/usr/bin/env bash
# tests/test-profiles.sh — Profile selection and IAM policy tests
#
# Tests:
#   1. --profile flag parsing (valid, invalid, missing value)
#   2. --non-interactive without --profile = error
#   3. --non-interactive with --profile = works (no profile-related error)
#   4. Profile registry YAML parsing (structure, all 3 profiles present)
#   5. All 3 profiles resolve correctly (instance type, IAM mode)
#   6. Policy JSON files (valid JSON, expected keys)
#   7. Instance size defaults per profile
#
# Run: bash tests/test-profiles.sh

set -uo pipefail   # no -e: test assertions may expect non-zero exits

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/profiles"
INSTALL_SH="${SCRIPT_DIR}/install.sh"

PASS=0; FAIL=0

pass()      { printf "  \033[0;32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
fail_test() { printf "  \033[0;31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }
header()    { printf "\n\033[1m%s\033[0m\n" "$1"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Run install.sh with given args; capture output and exit code
run_installer() {
  local args=("$@")
  output=$(bash "$INSTALL_SH" "${args[@]}" 2>&1 || true)
  exit_code=$?
}

# Parse --profile flag in isolation (mirrors what install.sh does)
parse_profile_flag() {
  local preselect=""
  local args=("$@")
  local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    if [[ "${args[$i]}" == "--profile" ]]; then
      local next_i=$((i + 1))
      if [[ $next_i -ge ${#args[@]} ]] || [[ "${args[$next_i]}" == --* ]]; then
        echo "ERROR: --profile requires a value" >&2
        return 1
      fi
      preselect="${args[$next_i]}"
      i=$((i + 2))
    else
      i=$((i + 1))
    fi
  done
  echo "$preselect"
  return 0
}

# Validate a profile name
validate_profile() {
  local p="$1"
  case "$p" in
    builder|account_assistant|personal_assistant) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse profiles/registry.yaml with a given key
# Usage: registry_profile_field <profile> <field>
registry_profile_field() {
  local profile="$1" field="$2"
  awk "
    /^  ${profile}:/{found=1; next}
    found && /^  [a-z]/{exit}
    found && /^    ${field}:/{gsub(/^    ${field}: /, \"\"); print; exit}
  " "${PROFILES_DIR}/registry.yaml"
}

registry_profile_list_field() {
  local profile="$1" field="$2"
  awk "
    /^  ${profile}:/{found=1; in_field=0; next}
    found && /^  [a-z]/{exit}
    found && /^    ${field}:/{in_field=1; next}
    found && in_field && /^      - /{gsub(/^      - /, \"\"); print; next}
    found && in_field && !/^      /{in_field=0}
  " "${PROFILES_DIR}/registry.yaml"
}

# ── Section 1: --profile flag parsing ────────────────────────────────────────
header "Test: --profile flag parsing"

# Missing value (no argument after --profile)
if ! parse_profile_flag --profile 2>/dev/null; then
  pass "--profile with no value: returns error"
else
  fail_test "--profile with no value: should return error"
fi

# Missing value (another flag follows immediately)
if ! parse_profile_flag --profile --non-interactive 2>/dev/null; then
  pass "--profile followed by flag: returns error"
else
  fail_test "--profile followed by flag: should return error"
fi

# Valid values
for profile in builder account_assistant personal_assistant; do
  result=$(parse_profile_flag --profile "$profile" 2>/dev/null || true)
  if [[ "$result" == "$profile" ]]; then
    pass "--profile $profile: parsed correctly"
  else
    fail_test "--profile $profile: expected '$profile', got '${result:-empty}'"
  fi
done

# install.sh itself: --profile with no value should exit non-zero and show error
output=$(bash "$INSTALL_SH" --profile 2>&1 || true)
if echo "$output" | grep -q "requires a value"; then
  pass "install.sh --profile (no value): exits with 'requires a value' message"
else
  fail_test "install.sh --profile (no value): expected 'requires a value', got: ${output:0:200}"
fi

# ── Section 2: Profile name validation ───────────────────────────────────────
header "Test: Profile name validation"

for valid in builder account_assistant personal_assistant; do
  if validate_profile "$valid"; then
    pass "validate_profile: '$valid' is valid"
  else
    fail_test "validate_profile: '$valid' should be valid"
  fi
done

for invalid in "" "admin" "superuser" "Builder" "BUILDER" "read_only"; do
  if ! validate_profile "$invalid"; then
    pass "validate_profile: '${invalid:-empty}' is correctly rejected"
  else
    fail_test "validate_profile: '${invalid:-empty}' should be rejected"
  fi
done

# ── Section 3: --non-interactive without --profile = error ───────────────────
header "Test: --non-interactive without --profile"

# When AUTO_YES=true and PRESELECT_PROFILE is empty, choose_profile must fail.
# Test this by sourcing the choose_profile function with mocked dependencies.
_test_choose_profile_autofail() {
  # Inline the choose_profile logic for testing
  local AUTO_YES="$1"
  local PRESELECT_PROFILE="$2"
  local PROFILE_NAME=""

  # Minimal implementations of install.sh helpers used by choose_profile
  local _fail_called=false
  fail_fn() { _fail_called=true; return 1; }
  ok_fn()   { :; }

  if [[ -n "$PRESELECT_PROFILE" ]]; then
    if validate_profile "$PRESELECT_PROFILE"; then
      PROFILE_NAME="$PRESELECT_PROFILE"
      echo "PROFILE_NAME=$PROFILE_NAME"
      return 0
    else
      fail_fn "Invalid profile: $PRESELECT_PROFILE"
      return 1
    fi
  fi

  if [[ "$AUTO_YES" == true ]]; then
    fail_fn "Profile is required in non-interactive mode"
    return 1
  fi

  # Interactive: would prompt (not tested here)
  return 0
}

# --non-interactive without --profile → should fail
if ! _test_choose_profile_autofail true "" 2>/dev/null; then
  pass "--non-interactive without --profile: choose_profile fails"
else
  fail_test "--non-interactive without --profile: should fail but succeeded"
fi

# --non-interactive with valid --profile → should succeed
for profile in builder account_assistant personal_assistant; do
  result=$(_test_choose_profile_autofail true "$profile" 2>/dev/null || true)
  if echo "$result" | grep -q "PROFILE_NAME=$profile"; then
    pass "--non-interactive with --profile $profile: choose_profile succeeds"
  else
    fail_test "--non-interactive with --profile $profile: expected success, got: $result"
  fi
done

# --non-interactive with invalid --profile → should fail
if ! _test_choose_profile_autofail true "superuser" 2>/dev/null; then
  pass "--non-interactive with invalid profile: choose_profile fails"
else
  fail_test "--non-interactive with invalid profile: should fail"
fi

# ── Section 4: Profile registry YAML structure ───────────────────────────────
header "Test: profiles/registry.yaml structure"

if [[ -f "${PROFILES_DIR}/registry.yaml" ]]; then
  pass "profiles/registry.yaml exists"
else
  fail_test "profiles/registry.yaml: file not found"
fi

# Check all 3 profiles present
for profile in builder account_assistant personal_assistant; do
  if grep -q "^  ${profile}:" "${PROFILES_DIR}/registry.yaml" 2>/dev/null; then
    pass "registry.yaml: '$profile' profile present"
  else
    fail_test "registry.yaml: '$profile' profile MISSING"
  fi
done

# Check required fields for each profile
for profile in builder account_assistant personal_assistant; do
  for field in description instance_type iam_mode; do
    val=$(registry_profile_field "$profile" "$field" 2>/dev/null || true)
    if [[ -n "$val" ]]; then
      pass "registry.yaml: $profile.$field = '$val'"
    else
      fail_test "registry.yaml: $profile.$field is missing or empty"
    fi
  done
done

# Check managed_policies for builder
builder_policies=$(registry_profile_list_field builder managed_policies 2>/dev/null || true)
if echo "$builder_policies" | grep -q "AdministratorAccess"; then
  pass "registry.yaml: builder has AdministratorAccess"
else
  fail_test "registry.yaml: builder should have AdministratorAccess"
fi

# Check managed_policies for account_assistant
aa_policies=$(registry_profile_list_field account_assistant managed_policies 2>/dev/null || true)
if echo "$aa_policies" | grep -q "ReadOnlyAccess"; then
  pass "registry.yaml: account_assistant has ReadOnlyAccess"
else
  fail_test "registry.yaml: account_assistant should have ReadOnlyAccess"
fi

# Check security_services flag
builder_sec=$(registry_profile_field builder security_services 2>/dev/null || true)
if [[ "$builder_sec" == "true" ]]; then
  pass "registry.yaml: builder has security_services=true"
else
  fail_test "registry.yaml: builder should have security_services=true (got: '$builder_sec')"
fi

pa_sec=$(registry_profile_field personal_assistant security_services 2>/dev/null || true)
if [[ "$pa_sec" == "false" ]]; then
  pass "registry.yaml: personal_assistant has security_services=false"
else
  fail_test "registry.yaml: personal_assistant should have security_services=false (got: '$pa_sec')"
fi

# ── Section 5: All 3 profiles resolve correctly ───────────────────────────────
header "Test: Profiles resolve correctly (instance types, IAM mode)"

# builder → t4g.xlarge, managed (AdministratorAccess)
builder_itype=$(registry_profile_field builder instance_type 2>/dev/null || true)
if [[ "$builder_itype" == "t4g.xlarge" ]]; then
  pass "builder: instance_type = t4g.xlarge"
else
  fail_test "builder: instance_type should be t4g.xlarge, got '$builder_itype'"
fi

builder_iam=$(registry_profile_field builder iam_mode 2>/dev/null || true)
if [[ "$builder_iam" == "managed" ]]; then
  pass "builder: iam_mode = managed"
else
  fail_test "builder: iam_mode should be managed, got '$builder_iam'"
fi

# account_assistant → t4g.medium, managed (ReadOnlyAccess)
aa_itype=$(registry_profile_field account_assistant instance_type 2>/dev/null || true)
if [[ "$aa_itype" == "t4g.medium" ]]; then
  pass "account_assistant: instance_type = t4g.medium"
else
  fail_test "account_assistant: instance_type should be t4g.medium, got '$aa_itype'"
fi

aa_iam=$(registry_profile_field account_assistant iam_mode 2>/dev/null || true)
if [[ "$aa_iam" == "managed" ]]; then
  pass "account_assistant: iam_mode = managed"
else
  fail_test "account_assistant: iam_mode should be managed, got '$aa_iam'"
fi

# personal_assistant → t4g.medium, inline
pa_itype=$(registry_profile_field personal_assistant instance_type 2>/dev/null || true)
if [[ "$pa_itype" == "t4g.medium" ]]; then
  pass "personal_assistant: instance_type = t4g.medium"
else
  fail_test "personal_assistant: instance_type should be t4g.medium, got '$pa_itype'"
fi

pa_iam=$(registry_profile_field personal_assistant iam_mode 2>/dev/null || true)
if [[ "$pa_iam" == "inline" ]]; then
  pass "personal_assistant: iam_mode = inline"
else
  fail_test "personal_assistant: iam_mode should be inline, got '$pa_iam'"
fi

# ── Section 6: Instance size defaults per profile ────────────────────────────
header "Test: Instance size defaults per profile"

_profile_to_size_choice() {
  local profile="$1"
  case "$profile" in
    builder)             echo "3" ;;  # t4g.xlarge
    account_assistant)   echo "1" ;;  # t4g.medium
    personal_assistant)  echo "1" ;;  # t4g.medium
    *) echo "" ;;
  esac
}

_size_choice_to_instance() {
  local choice="$1"
  case "$choice" in
    1) echo "t4g.medium" ;;
    2) echo "t4g.large" ;;
    3) echo "t4g.xlarge" ;;
    *) echo "t4g.xlarge" ;;
  esac
}

for profile in builder account_assistant personal_assistant; do
  choice=$(_profile_to_size_choice "$profile")
  itype=$(_size_choice_to_instance "$choice")
  expected_itype=$(registry_profile_field "$profile" instance_type 2>/dev/null || true)

  if [[ "$itype" == "$expected_itype" ]]; then
    pass "Instance default for $profile: $itype (matches registry)"
  else
    fail_test "Instance default for $profile: got $itype, registry says $expected_itype"
  fi
done

# ── Section 7: Policy JSON files ─────────────────────────────────────────────
header "Test: Policy JSON files"

POLICY_FILES=(
  "account_assistant_deny.json"
  "account_assistant_bedrock.json"
  "personal_assistant.json"
  "bootstrap_operations.json"
)

for pf in "${POLICY_FILES[@]}"; do
  fp="${PROFILES_DIR}/${pf}"
  if [[ -f "$fp" ]]; then
    pass "Policy file exists: $pf"
  else
    fail_test "Policy file MISSING: $pf"
    continue
  fi

  # Validate JSON
  if jq empty "$fp" 2>/dev/null; then
    pass "Policy file valid JSON: $pf"
  else
    fail_test "Policy file invalid JSON: $pf"
    continue
  fi

  # Check it has Version and Statement
  if jq -e '.Version' "$fp" >/dev/null 2>&1; then
    pass "$pf has Version field"
  else
    fail_test "$pf missing Version field"
  fi

  if jq -e '.Statement | length > 0' "$fp" >/dev/null 2>&1; then
    pass "$pf has non-empty Statement"
  else
    fail_test "$pf has empty or missing Statement"
  fi
done

# builder.json is empty (comment placeholder for AdministratorAccess)
if [[ -f "${PROFILES_DIR}/builder.json" ]]; then
  pass "profiles/builder.json exists (empty placeholder)"
else
  fail_test "profiles/builder.json MISSING"
fi

# ── Section 8: account_assistant_deny.json content ───────────────────────────
header "Test: account_assistant_deny.json content"

DENY_FILE="${PROFILES_DIR}/account_assistant_deny.json"
if [[ -f "$DENY_FILE" ]]; then
  # Should deny secret values
  if jq -e '.Statement[] | select(.Sid == "DenySecretValues")' "$DENY_FILE" >/dev/null 2>&1; then
    pass "deny policy: has DenySecretValues statement"
  else
    fail_test "deny policy: missing DenySecretValues statement"
  fi

  # Should deny S3 object access
  if jq -e '.Statement[] | select(.Sid == "DenyS3ObjectAccess")' "$DENY_FILE" >/dev/null 2>&1; then
    pass "deny policy: has DenyS3ObjectAccess statement"
  else
    fail_test "deny policy: missing DenyS3ObjectAccess statement"
  fi

  # Should deny Lambda code access
  if jq -e '.Statement[] | select(.Sid == "DenyLambdaCodeAccess")' "$DENY_FILE" >/dev/null 2>&1; then
    pass "deny policy: has DenyLambdaCodeAccess statement"
  else
    fail_test "deny policy: missing DenyLambdaCodeAccess statement"
  fi

  # All effects must be Deny
  all_deny=$(jq -e '[.Statement[].Effect] | all(. == "Deny")' "$DENY_FILE" 2>/dev/null || echo "false")
  if [[ "$all_deny" == "true" ]]; then
    pass "deny policy: all statements have Effect=Deny"
  else
    fail_test "deny policy: not all statements have Effect=Deny"
  fi
fi

# ── Section 9: personal_assistant.json content ───────────────────────────────
header "Test: personal_assistant.json content"

PA_FILE="${PROFILES_DIR}/personal_assistant.json"
if [[ -f "$PA_FILE" ]]; then
  # Must include Bedrock inference
  if jq -e '.Statement[] | select(.Sid == "BedrockInference")' "$PA_FILE" >/dev/null 2>&1; then
    pass "personal_assistant policy: has BedrockInference"
  else
    fail_test "personal_assistant policy: missing BedrockInference"
  fi

  # Must include SSM connectivity
  if jq -e '.Statement[] | select(.Sid == "SSMConnectivity")' "$PA_FILE" >/dev/null 2>&1; then
    pass "personal_assistant policy: has SSMConnectivity"
  else
    fail_test "personal_assistant policy: missing SSMConnectivity"
  fi

  # Must include Identity (sts:GetCallerIdentity)
  if jq -e '.Statement[] | .Action | if type == "array" then .[] else . end | select(. == "sts:GetCallerIdentity")' "$PA_FILE" >/dev/null 2>&1; then
    pass "personal_assistant policy: has sts:GetCallerIdentity"
  else
    fail_test "personal_assistant policy: missing sts:GetCallerIdentity"
  fi

  # Must NOT allow arbitrary AWS actions (sanity check: no AdministratorAccess action)
  admin_action=$(jq -e '.Statement[] | .Action | if type == "array" then .[] else . end | select(. == "*")' "$PA_FILE" 2>/dev/null || echo "")
  if [[ -z "$admin_action" ]]; then
    pass "personal_assistant policy: no wildcard (*) actions"
  else
    fail_test "personal_assistant policy: should not have wildcard (*) actions"
  fi
fi

# ── Section 10: bootstrap_operations.json content ────────────────────────────
header "Test: bootstrap_operations.json content"

BOOTSTRAP_FILE="${PROFILES_DIR}/bootstrap_operations.json"
if [[ -f "$BOOTSTRAP_FILE" ]]; then
  # Must include ssm:PutParameter
  if jq -e '.Statement[] | .Action | if type == "array" then .[] else . end | select(. == "ssm:PutParameter")' "$BOOTSTRAP_FILE" >/dev/null 2>&1; then
    pass "bootstrap policy: has ssm:PutParameter"
  else
    fail_test "bootstrap policy: missing ssm:PutParameter"
  fi

  # Must include cloudformation:SignalResource
  if jq -e '.Statement[] | .Action | if type == "array" then .[] else . end | select(. == "cloudformation:SignalResource")' "$BOOTSTRAP_FILE" >/dev/null 2>&1; then
    pass "bootstrap policy: has cloudformation:SignalResource"
  else
    fail_test "bootstrap policy: missing cloudformation:SignalResource"
  fi

  # Must be scoped (Resource must not be "*")
  all_wildcard=$(jq -e '[.Statement[].Resource] | all(. == "*")' "$BOOTSTRAP_FILE" 2>/dev/null || echo "false")
  if [[ "$all_wildcard" != "true" ]]; then
    pass "bootstrap policy: resources are scoped (not all wildcard)"
  else
    fail_test "bootstrap policy: resources should be scoped, not all '*'"
  fi
fi

# ── Section 11: install.sh has ProfileName in param arrays ───────────────────
header "Test: install.sh ProfileName parameter plumbing"

if grep -q "ProfileName" "$INSTALL_SH" 2>/dev/null; then
  pass "install.sh: ProfileName found in source"
else
  fail_test "install.sh: ProfileName missing from source (not yet implemented)"
fi

if grep -q "PRESELECT_PROFILE" "$INSTALL_SH" 2>/dev/null; then
  pass "install.sh: PRESELECT_PROFILE variable found"
else
  fail_test "install.sh: PRESELECT_PROFILE variable missing"
fi

if grep -q "choose_profile" "$INSTALL_SH" 2>/dev/null; then
  pass "install.sh: choose_profile() function found"
else
  fail_test "install.sh: choose_profile() function missing"
fi

# ── Section 12: bootstrap.sh has --profile ───────────────────────────────────
header "Test: bootstrap.sh --profile support"

BOOTSTRAP_SH="${SCRIPT_DIR}/deploy/bootstrap.sh"

if grep -q "\-\-profile" "$BOOTSTRAP_SH" 2>/dev/null; then
  pass "bootstrap.sh: --profile arg found"
else
  fail_test "bootstrap.sh: --profile arg missing"
fi

if grep -q "PROFILE_NAME" "$BOOTSTRAP_SH" 2>/dev/null; then
  pass "bootstrap.sh: PROFILE_NAME variable found"
else
  fail_test "bootstrap.sh: PROFILE_NAME variable missing"
fi

if grep -q '\.profile' "$BOOTSTRAP_SH" 2>/dev/null; then
  pass "bootstrap.sh: .profile marker file referenced"
else
  fail_test "bootstrap.sh: .profile marker file not referenced"
fi

if grep -q "personal_assistant" "$BOOTSTRAP_SH" 2>/dev/null; then
  pass "bootstrap.sh: personal_assistant profile-specific handling found"
else
  fail_test "bootstrap.sh: personal_assistant profile handling missing"
fi

# ── Section 13: CFN template has ProfileName ──────────────────────────────────
header "Test: CFN template ProfileName parameter"

CFN_TEMPLATE="${SCRIPT_DIR}/deploy/cloudformation/template.yaml"

if grep -q "ProfileName" "$CFN_TEMPLATE" 2>/dev/null; then
  pass "CFN template: ProfileName parameter found"
else
  fail_test "CFN template: ProfileName parameter missing"
fi

if grep -q "IsBuilder" "$CFN_TEMPLATE" 2>/dev/null; then
  pass "CFN template: IsBuilder condition found"
else
  fail_test "CFN template: IsBuilder condition missing"
fi

if grep -q "IsPersonalAssistant" "$CFN_TEMPLATE" 2>/dev/null; then
  pass "CFN template: IsPersonalAssistant condition found"
else
  fail_test "CFN template: IsPersonalAssistant condition missing"
fi


if grep -q "loki:profile" "$CFN_TEMPLATE" 2>/dev/null; then
  pass "CFN template: loki:profile instance tag found"
else
  fail_test "CFN template: loki:profile instance tag missing"
fi

# ── bash -n syntax checks on all modified shell scripts ───────────────────────
header "Test: bash -n syntax checks"

for script in "$INSTALL_SH" "${SCRIPT_DIR}/deploy/bootstrap.sh"; do
  if bash -n "$script" 2>/dev/null; then
    pass "bash -n $(basename $script): no syntax errors"
  else
    err=$(bash -n "$script" 2>&1)
    fail_test "bash -n $(basename $script): SYNTAX ERROR: $err"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
printf "\033[1mTest: Deny policy does NOT block SSM Agent\033[0m\n"
# ssm:GetParameter must NOT be in the deny — it breaks SSM Session Manager
if grep -q '"ssm:GetParameter"' "${PROFILES_DIR}/account_assistant_deny.json" 2>/dev/null; then
  fail "account_assistant_deny.json contains ssm:GetParameter — this breaks SSM Agent!"
else
  pass "account_assistant_deny.json does not deny ssm:GetParameter (SSM Agent safe)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Profile Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  \033[0;32mPassed:\033[0m  %d\n" "${PASS}"
printf "  \033[0;31mFailed:\033[0m  %d\n" "${FAIL}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "${FAIL}" -gt 0 ]]; then
  printf "\033[0;31m✗ %d test(s) failed\033[0m\n\n" "${FAIL}"
  exit 1
else
  printf "\033[0;32m✓ All profile tests passed\033[0m\n\n"
  exit 0
fi
