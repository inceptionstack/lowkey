#!/usr/bin/env bash
# tests/test-account-rename.sh — tests for maybe_rename_account() and helpers
# Run: bash tests/test-account-rename.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${SCRIPT_DIR}/install.sh"

PASS=0
FAIL=0

# ---- Helpers ----------------------------------------------------------------
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    missing: $needle"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    should not contain: $needle"; FAIL=$((FAIL + 1))
  fi
}

# ---- Extract functions from install.sh for unit testing ---------------------
# We source specific functions by extracting them. This avoids running the
# entire installer which has side effects.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Extract the functions we need into a sourceable file
cat > "$TMPDIR/functions.sh" << 'EXTRACT'
#!/usr/bin/env bash
set -euo pipefail

# Minimal stubs for dependencies
NC="" BOLD="" DIM="" RED="" GREEN="" YELLOW="" CYAN="" BLUE="" MAGENTA=""
GUM="echo"
ACCOUNT_ID="123456789012"
DEPLOY_REGION="us-east-1"
AUTO_YES=false
AUTO_RENAME_ACCOUNT=false
DISABLE_ACCOUNT_RENAME=false

# Stub ok/info/warn to capture output
_OUTPUT=""
ok()   { _OUTPUT+="[ok] $*"$'\n'; }
info() { _OUTPUT+="[info] $*"$'\n'; }
warn() { _OUTPUT+="[warn] $*"$'\n'; }

# Stub telemetry
_TELEM_EVENTS=()
_telem_event() {
  _TELEM_EVENTS+=("$1|$2")
}

# Stub AWS CLI — override per test
_AWS_ACCOUNT_INFO_RESULT=""
_AWS_ACCOUNT_INFO_EXIT=0
_AWS_ACCOUNT_PUT_EXIT=0
_AWS_SSM_GET_EXIT=1  # default: param not found
_AWS_SSM_PUT_EXIT=0
aws() {
  case "$1 $2" in
    "account get-account-information")
      if [[ $_AWS_ACCOUNT_INFO_EXIT -ne 0 ]]; then return $_AWS_ACCOUNT_INFO_EXIT; fi
      echo "$_AWS_ACCOUNT_INFO_RESULT"
      ;;
    "account put-account-name")
      return $_AWS_ACCOUNT_PUT_EXIT
      ;;
    "ssm get-parameter")
      return $_AWS_SSM_GET_EXIT
      ;;
    "ssm put-parameter")
      return $_AWS_SSM_PUT_EXIT
      ;;
    "account help")
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

EXTRACT

# Initialize module-level variables used by extracted functions
echo '_RENAME_WAS_TRUNCATED=false' >> "$TMPDIR/functions.sh"
echo '_RENAME_FINAL_NAME=""' >> "$TMPDIR/functions.sh"
echo '_RENAME_PROPOSED=""' >> "$TMPDIR/functions.sh"

# Now extract the actual functions from install.sh
# _sanitize_account_name
sed -n '/^_sanitize_account_name() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
# _emit_rename_telemetry
sed -n '/^_emit_rename_telemetry() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
# _account_already_prefixed
sed -n '/^_account_already_prefixed() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
# _build_proposed_name
sed -n '/^_build_proposed_name() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
# _resolve_final_name
sed -n '/^_resolve_final_name() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
# _apply_account_rename
sed -n '/^_apply_account_rename() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
# maybe_rename_account
sed -n '/^maybe_rename_account() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"

# ============================================================================
echo "── AWS CLI version checks ──"
# ============================================================================

# Extract version-check functions
sed -n '/^MIN_AWS_CLI_MAJOR=/,/^_AWS_CLI_MINOR=/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
sed -n '/^_parse_aws_cli_version() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"
sed -n '/^_aws_cli_is_current() {/,/^}/p' "$INSTALL_SH" >> "$TMPDIR/functions.sh"

test_parse_version_v2() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/2.33.15 Python/3.9.25 Linux/6.1 source/aarch64"; }
  _parse_aws_cli_version
  assert_eq "major" "2" "$_AWS_CLI_MAJOR"
  assert_eq "minor" "33" "$_AWS_CLI_MINOR"
}; test_parse_version_v2

test_parse_version_v1() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/1.27.5 Python/3.8.10 Linux/5.15"; }
  _parse_aws_cli_version
  assert_eq "major" "1" "$_AWS_CLI_MAJOR"
  assert_eq "minor" "27" "$_AWS_CLI_MINOR"
}; test_parse_version_v1

test_parse_version_min() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/2.8.0 Python/3.9"; }
  _parse_aws_cli_version
  assert_eq "major" "2" "$_AWS_CLI_MAJOR"
  assert_eq "minor" "8" "$_AWS_CLI_MINOR"
}; test_parse_version_min

test_parse_version_garbled() {
  source "$TMPDIR/functions.sh"
  aws() { echo "not-aws-cli output"; }
  _parse_aws_cli_version
  assert_eq "major empty" "" "$_AWS_CLI_MAJOR"
  assert_eq "minor empty" "" "$_AWS_CLI_MINOR"
}; test_parse_version_garbled

test_is_current_v2_33() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/2.33.15 Python/3.9"; }
  if _aws_cli_is_current; then
    echo "  ✓ v2.33 is current"; PASS=$((PASS + 1))
  else
    echo "  ✗ v2.33 should be current"; FAIL=$((FAIL + 1))
  fi
}; test_is_current_v2_33

test_is_current_v2_8() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/2.8.0 Python/3.9"; }
  if _aws_cli_is_current; then
    echo "  ✓ v2.8 is current (exactly minimum)"; PASS=$((PASS + 1))
  else
    echo "  ✗ v2.8 should be current"; FAIL=$((FAIL + 1))
  fi
}; test_is_current_v2_8

test_is_current_v2_7_not() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/2.7.99 Python/3.9"; }
  if _aws_cli_is_current; then
    echo "  ✗ v2.7 should NOT be current"; FAIL=$((FAIL + 1))
  else
    echo "  ✓ v2.7 correctly not current"; PASS=$((PASS + 1))
  fi
}; test_is_current_v2_7_not

test_is_current_v1_not() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/1.27.5 Python/3.8"; }
  if _aws_cli_is_current; then
    echo "  ✗ v1.x should NOT be current"; FAIL=$((FAIL + 1))
  else
    echo "  ✓ v1.x correctly not current"; PASS=$((PASS + 1))
  fi
}; test_is_current_v1_not

test_is_current_garbled_not() {
  source "$TMPDIR/functions.sh"
  aws() { echo "garbage"; }
  if _aws_cli_is_current; then
    echo "  ✗ garbled should NOT be current"; FAIL=$((FAIL + 1))
  else
    echo "  ✓ garbled correctly not current"; PASS=$((PASS + 1))
  fi
}; test_is_current_garbled_not

test_is_current_v3() {
  source "$TMPDIR/functions.sh"
  aws() { echo "aws-cli/3.0.0 Python/3.12"; }
  if _aws_cli_is_current; then
    echo "  ✓ v3.x is current (major > min)"; PASS=$((PASS + 1))
  else
    echo "  ✗ v3.x should be current"; FAIL=$((FAIL + 1))
  fi
}; test_is_current_v3

# ============================================================================
echo "── _sanitize_account_name ──"
# ============================================================================

test_sanitize_passthrough() {
  source "$TMPDIR/functions.sh"
  local result
  result=$(_sanitize_account_name "MyAccount-123")
  assert_eq "alphanumeric + hyphen passes through" "MyAccount-123" "$result"
}; test_sanitize_passthrough

test_sanitize_strips_shell_metacharacters() {
  source "$TMPDIR/functions.sh"
  local result
  result=$(_sanitize_account_name 'My$Account&"test')
  assert_eq "strips \$, &, \"" "MyAccounttest" "$result"
}; test_sanitize_strips_shell_metacharacters

test_sanitize_keeps_safe_special_chars() {
  source "$TMPDIR/functions.sh"
  local result
  result=$(_sanitize_account_name "My Account_v2.0+test=ok")
  assert_eq "keeps space, underscore, dot, plus, equals" "My Account_v2.0+test=ok" "$result"
}; test_sanitize_keeps_safe_special_chars

test_sanitize_strips_control_chars() {
  source "$TMPDIR/functions.sh"
  local result
  # shellcheck disable=SC2059
  result=$(_sanitize_account_name $'My\x01\x1FAccount')
  assert_eq "strips control characters" "MyAccount" "$result"
}; test_sanitize_strips_control_chars

test_sanitize_empty_result() {
  source "$TMPDIR/functions.sh"
  local result
  result=$(_sanitize_account_name '$$$')
  assert_eq "all-invalid chars returns empty" "" "$result"
}; test_sanitize_empty_result

# ============================================================================
echo ""
echo "── _emit_rename_telemetry ──"
# ============================================================================

test_emit_success() {
  source "$TMPDIR/functions.sh"
  AUTO_RENAME_ACCOUNT=true
  _TELEM_EVENTS=()
  _emit_rename_telemetry true true
  assert_eq "event name" "install.account_renamed" "${_TELEM_EVENTS[0]%%|*}"
  assert_contains "renamed=true" '"renamed":true' "${_TELEM_EVENTS[0]}"
  assert_contains "allowed=true" '"allowed":true' "${_TELEM_EVENTS[0]}"
  assert_contains "auto_rename_enabled=true" '"auto_rename_enabled":true' "${_TELEM_EVENTS[0]}"
  assert_not_contains "no skipped_reason" 'skipped_reason' "${_TELEM_EVENTS[0]}"
}; test_emit_success

test_emit_skipped() {
  source "$TMPDIR/functions.sh"
  AUTO_RENAME_ACCOUNT=false
  _TELEM_EVENTS=()
  _emit_rename_telemetry false false "user_declined"
  assert_contains "renamed=false" '"renamed":false' "${_TELEM_EVENTS[0]}"
  assert_contains "allowed=false" '"allowed":false' "${_TELEM_EVENTS[0]}"
  assert_contains "skipped_reason" '"skipped_reason":"user_declined"' "${_TELEM_EVENTS[0]}"
}; test_emit_skipped

test_emit_coerces_invalid_booleans() {
  source "$TMPDIR/functions.sh"
  AUTO_RENAME_ACCOUNT=false
  _TELEM_EVENTS=()
  _emit_rename_telemetry "garbage" "junk" "api_error"
  assert_contains "coerced to false" '"renamed":false' "${_TELEM_EVENTS[0]}"
  assert_contains "coerced to false" '"allowed":false' "${_TELEM_EVENTS[0]}"
}; test_emit_coerces_invalid_booleans

# ============================================================================
echo ""
echo "── maybe_rename_account ──"
# ============================================================================

test_disabled_flag() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=true
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "info message" "Account rename disabled" "$_OUTPUT"
  assert_contains "telemetry skipped_reason" '"disabled_flag"' "${_TELEM_EVENTS[0]}"
}; test_disabled_flag

test_api_error_on_get() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  _AWS_ACCOUNT_INFO_EXIT=1
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "warn message" "Could not read account name" "$_OUTPUT"
  assert_contains "telemetry skipped_reason" '"api_error"' "${_TELEM_EVENTS[0]}"
}; test_api_error_on_get

test_already_prefixed() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"Lowkey-MyAccount"}'
  _AWS_SSM_GET_EXIT=1  # SSM param not found → write it
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "ok message" "already named for Lowkey" "$_OUTPUT"
  assert_contains "telemetry skipped_reason" '"already_prefixed"' "${_TELEM_EVENTS[0]}"
}; test_already_prefixed

test_already_prefixed_case_insensitive() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"lOwKeY-MyAccount"}'
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "detects case-insensitive prefix" "already named for Lowkey" "$_OUTPUT"
}; test_already_prefixed_case_insensitive

test_already_prefixed_lowkey_variant() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"lowkey1-MyAccount"}'
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "detects lowkey1- as already prefixed" "already named for Lowkey" "$_OUTPUT"
}; test_already_prefixed_lowkey_variant

test_already_prefixed_lowkeydev() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"LowkeyDev-SomeAccount"}'
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "detects LowkeyDev- as already prefixed" "already named for Lowkey" "$_OUTPUT"
}; test_already_prefixed_lowkeydev

test_headless_no_opt_in() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  AUTO_YES=true
  AUTO_RENAME_ACCOUNT=false
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"dev-account"}'
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "info message" "account rename skipped" "$_OUTPUT"
  assert_contains "telemetry skipped_reason" '"headless_no_opt_in"' "${_TELEM_EVENTS[0]}"
}; test_headless_no_opt_in

test_headless_auto_rename() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  AUTO_YES=true
  AUTO_RENAME_ACCOUNT=true
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"dev-account"}'
  _AWS_ACCOUNT_PUT_EXIT=0
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "ok message" "Account renamed" "$_OUTPUT"
  assert_contains "telemetry renamed=true" '"renamed":true' "${_TELEM_EVENTS[0]}"
  assert_contains "telemetry allowed=true" '"allowed":true' "${_TELEM_EVENTS[0]}"
}; test_headless_auto_rename

test_headless_auto_rename_api_failure() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  AUTO_YES=true
  AUTO_RENAME_ACCOUNT=true
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"dev-account"}'
  _AWS_ACCOUNT_PUT_EXIT=1
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "warn message" "Could not rename account" "$_OUTPUT"
  assert_contains "telemetry renamed=false" '"renamed":false' "${_TELEM_EVENTS[0]}"
  assert_contains "telemetry allowed=true" '"allowed":true' "${_TELEM_EVENTS[0]}"
  assert_contains "telemetry api_error" '"api_error"' "${_TELEM_EVENTS[0]}"
}; test_headless_auto_rename_api_failure

test_empty_account_name_fallback() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  AUTO_YES=true
  AUTO_RENAME_ACCOUNT=true
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":""}'
  _AWS_ACCOUNT_PUT_EXIT=0
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "uses account ID fallback" "Lowkey-123456789012" "$_OUTPUT"
}; test_empty_account_name_fallback

test_long_name_truncation() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  AUTO_YES=true
  AUTO_RENAME_ACCOUNT=true
  _AWS_ACCOUNT_INFO_EXIT=0
  # 50 char name + "Lowkey-" = 57, must truncate
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"ThisIsAVeryLongAccountNameThatExceedsFiftyCharsX"}'
  _AWS_ACCOUNT_PUT_EXIT=0
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  assert_contains "truncation warning" "truncated to 50" "$_OUTPUT"
  assert_contains "rename succeeds" "Account renamed" "$_OUTPUT"
}; test_long_name_truncation

test_sanitize_then_prefix() {
  source "$TMPDIR/functions.sh"
  DISABLE_ACCOUNT_RENAME=false
  AUTO_YES=true
  AUTO_RENAME_ACCOUNT=true
  _AWS_ACCOUNT_INFO_EXIT=0
  _AWS_ACCOUNT_INFO_RESULT='{"AccountName":"my$bad&name"}'
  _AWS_ACCOUNT_PUT_EXIT=0
  _OUTPUT="" _TELEM_EVENTS=()
  maybe_rename_account
  # Should sanitize to "mybadname" then prefix → "Lowkey-mybadname"
  assert_contains "sanitized and prefixed" "Lowkey-mybadname" "$_OUTPUT"
}; test_sanitize_then_prefix

# ============================================================================
echo ""
echo "── Flag parsing ──"
# ============================================================================

test_flag_auto_rename() {
  local result
  result=$(grep -c "\-\-auto-rename-account-enabled)" "$INSTALL_SH")
  assert_eq "--auto-rename-account-enabled in case block" "1" "$result"
}; test_flag_auto_rename

test_flag_disable_rename() {
  local result
  result=$(grep -c "\-\-disable-account-rename)" "$INSTALL_SH")
  assert_eq "--disable-account-rename in case block" "1" "$result"
}; test_flag_disable_rename

test_flag_defaults() {
  assert_contains "AUTO_RENAME_ACCOUNT default" "AUTO_RENAME_ACCOUNT=false" "$(cat "$INSTALL_SH")"
  assert_contains "DISABLE_ACCOUNT_RENAME default" "DISABLE_ACCOUNT_RENAME=false" "$(cat "$INSTALL_SH")"
}; test_flag_defaults

# ============================================================================
echo ""
echo "── call site ──"
# ============================================================================

test_rename_in_main() {
  assert_contains "maybe_rename_account called in main()" "maybe_rename_account" "$(sed -n '/^main()/,/^}/p' "$INSTALL_SH")"
}; test_rename_in_main

test_rename_before_config_wizard() {
  # Verify maybe_rename_account is called BEFORE run_config_and_review in main()
  local body
  body=$(sed -n '/^main()/,/^}/p' "$INSTALL_SH")
  local rename_line config_line
  rename_line=$(echo "$body" | grep -n "maybe_rename_account" | head -1 | cut -d: -f1)
  config_line=$(echo "$body" | grep -n "run_config_and_review" | head -1 | cut -d: -f1)
  if [[ -n "$rename_line" && -n "$config_line" && "$rename_line" -lt "$config_line" ]]; then
    echo "  ✓ maybe_rename_account before run_config_and_review"; PASS=$((PASS + 1))
  else
    echo "  ✗ maybe_rename_account should be before run_config_and_review"
    echo "    rename_line=$rename_line config_line=$config_line"
    FAIL=$((FAIL + 1))
  fi
}; test_rename_before_config_wizard

test_main_rename_guarded() {
  # Verify the call is guarded with || true (no 2>/dev/null — gum needs stderr)
  assert_contains "guarded call" "maybe_rename_account || true" "$(cat "$INSTALL_SH")"
}; test_main_rename_guarded

# ============================================================================
echo ""
echo "── Beacon: account_rename_enabled ──"
# ============================================================================

test_beacon_includes_field() {
  assert_contains "beacon includes account_rename_enabled" "account_rename_enabled" \
    "$(sed -n '/_telem_send_install_beacon/,/^}/p' "$INSTALL_SH")"
}; test_beacon_includes_field

# ============================================================================
echo ""
echo "── Help text ──"
# ============================================================================

test_help_auto_rename() {
  assert_contains "help mentions --auto-rename-account-enabled" "auto-rename-account-enabled" "$(cat "$INSTALL_SH")"
}; test_help_auto_rename

test_help_disable_rename() {
  assert_contains "help mentions --disable-account-rename" "disable-account-rename" "$(cat "$INSTALL_SH")"
}; test_help_disable_rename

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Tests: $((PASS + FAIL))  Passed: $PASS  Failed: $FAIL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[[ $FAIL -eq 0 ]] || exit 1
