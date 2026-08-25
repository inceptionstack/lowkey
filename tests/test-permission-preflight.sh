#!/usr/bin/env bash
# tests/test-permission-preflight.sh — IAM policy simulation identity handling
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
pass() { printf '  ✓ %s\n' "$1"; PASS=$((PASS + 1)); }
fail_test() { printf '  ✗ %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$description"
  else
    fail_test "$description (expected: $expected, actual: $actual)"
  fi
}
assert_contains() {
  local description="$1" needle="$2" haystack="$3"
  [[ "$haystack" == *"$needle"* ]] \
    && pass "$description" \
    || fail_test "$description (missing: $needle)"
}

FUNCTIONS="${TMPDIR}/functions.sh"
sed -n '/^resolve_policy_source_arn() {/,/^}/p' "$INSTALL_SH" > "$FUNCTIONS"
sed -n '/^check_permissions() {/,/^}/p' "$INSTALL_SH" >> "$FUNCTIONS"
# shellcheck source=/dev/null
source "$FUNCTIONS"

printf '── Permission preflight identity resolution ──\n'

test_iam_user_is_passed_through() {
  aws() { printf 'unexpected AWS call\n' >&2; return 1; }
  local actual
  actual="$(resolve_policy_source_arn 'arn:aws:iam::123456789012:user/deployer')"
  assert_eq "IAM user ARN is passed through" \
    "arn:aws:iam::123456789012:user/deployer" "$actual"
}
test_iam_user_is_passed_through

test_iam_role_is_passed_through() {
  aws() { printf 'unexpected AWS call\n' >&2; return 1; }
  local actual
  actual="$(resolve_policy_source_arn 'arn:aws:iam::123456789012:role/platform/deployer')"
  assert_eq "IAM role ARN is passed through" \
    "arn:aws:iam::123456789012:role/platform/deployer" "$actual"
}
test_iam_role_is_passed_through

test_assumed_role_resolves_iam_role_with_path() {
  local call_log="${TMPDIR}/get-role-call"
  aws() {
    printf '%s\n' "$*" > "$call_log"
    printf 'arn:aws:iam::123456789012:role/platform/Admin\n'
  }
  local actual
  actual="$(resolve_policy_source_arn \
    'arn:aws:sts::123456789012:assumed-role/Admin/deploy-session')"
  assert_eq "STS assumed role resolves to IAM role ARN with path" \
    "arn:aws:iam::123456789012:role/platform/Admin" "$actual"
  assert_eq "role resolution uses the parsed role name" \
    "iam get-role --role-name Admin --query Role.Arn --output text" \
    "$(cat "$call_log")"
}
test_assumed_role_resolves_iam_role_with_path

test_assumed_role_resolution_failure_is_reported() {
  aws() { printf 'AccessDenied from get-role\n' >&2; return 254; }
  local output
  if output="$(resolve_policy_source_arn \
      'arn:aws:sts::123456789012:assumed-role/Admin/deploy-session' 2>&1)"; then
    fail_test "assumed-role resolution failure returns nonzero"
  else
    pass "assumed-role resolution failure returns nonzero"
  fi
  assert_contains "assumed-role resolution failure keeps AWS error" \
    "AccessDenied from get-role" "$output"
}
test_assumed_role_resolution_failure_is_reported

test_check_permissions_simulates_resolved_role() {
  local source_log="${TMPDIR}/simulation-source"
  local warning_log="${TMPDIR}/assumed-role-warning"
  local confirm_log="${TMPDIR}/assumed-role-confirm"
  CALLER_ARN='arn:aws:sts::123456789012:assumed-role/Admin/deploy-session'
  info() { :; }
  warn() { printf '%s\n' "$*" > "$warning_log"; }
  confirm_or_abort() { printf '%s\n' "$*" > "$confirm_log"; }
  ok() { printf 'must not claim full verification\n' > "${TMPDIR}/unexpected-ok"; }
  aws() {
    if [[ "$1 $2" == "iam get-role" ]]; then
      printf 'arn:aws:iam::123456789012:role/platform/Admin\n'
      return 0
    fi
    if [[ "$1 $2" == "iam simulate-principal-policy" ]]; then
      while (($#)); do
        if [[ "$1" == "--policy-source-arn" ]]; then
          printf '%s\n' "$2" > "$source_log"
          break
        fi
        shift
      done
      return 0
    fi
    return 1
  }

  check_permissions >/dev/null
  assert_eq "permission simulation uses resolved IAM role ARN" \
    "arn:aws:iam::123456789012:role/platform/Admin" "$(cat "$source_log")"
  assert_contains "assumed-role success warns about session-policy limits" \
    "cannot evaluate restrictions from the active STS session policies" \
    "$(cat "$warning_log")"
  assert_eq "assumed-role success asks before partially verified continuation" \
    "Continue with partially verified permissions? default_yes" \
    "$(cat "$confirm_log")"
  [[ ! -e "${TMPDIR}/unexpected-ok" ]] \
    && pass "assumed-role success does not claim full verification" \
    || fail_test "assumed-role success does not claim full verification"
}
test_check_permissions_simulates_resolved_role

test_check_permissions_verifies_direct_iam_role() {
  CALLER_ARN='arn:aws:iam::123456789012:role/platform/Admin'
  info() { :; }
  warn() { printf 'unexpected warning: %s\n' "$*" >&2; return 1; }
  confirm_or_abort() { printf 'unexpected confirmation: %s\n' "$*" >&2; return 1; }
  ok() { printf '%s\n' "$*" > "${TMPDIR}/direct-role-ok"; }
  aws() {
    [[ "$1 $2" == "iam simulate-principal-policy" ]] || return 99
    return 0
  }

  check_permissions >/dev/null
  assert_eq "direct IAM role success reports verified permissions" \
    "Permissions verified" "$(cat "${TMPDIR}/direct-role-ok")"
}
test_check_permissions_verifies_direct_iam_role

test_check_permissions_handles_resolution_failure() {
  local warning_log="${TMPDIR}/resolution-warning"
  local confirm_log="${TMPDIR}/resolution-confirm"
  CALLER_ARN='arn:aws:sts::123456789012:assumed-role/Admin/deploy-session'
  info() { :; }
  ok() { printf 'must not claim verification\n' > "${TMPDIR}/unexpected-ok"; }
  warn() { printf '%s\n' "$*" > "$warning_log"; }
  confirm_or_abort() { printf '%s\n' "$*" > "$confirm_log"; }
  aws() {
    [[ "$1 $2" == "iam get-role" ]] || return 99
    printf 'AccessDenied from get-role\n' >&2
    return 254
  }

  check_permissions >/dev/null
  assert_contains "resolution failure warns accurately" \
    "Could not resolve caller identity for deployment permission verification" \
    "$(cat "$warning_log")"
  assert_eq "resolution failure asks before continuing" \
    "Continue without verified permissions?" "$(cat "$confirm_log")"
  [[ ! -e "${TMPDIR}/unexpected-ok" ]] \
    && pass "resolution failure does not claim verification" \
    || fail_test "resolution failure does not claim verification"
}
test_check_permissions_handles_resolution_failure

test_check_permissions_handles_simulator_failure() {
  local warning_log="${TMPDIR}/simulator-warning"
  local confirm_log="${TMPDIR}/simulator-confirm"
  CALLER_ARN='arn:aws:iam::123456789012:role/Admin'
  info() { :; }
  ok() { printf 'must not claim verification\n' > "${TMPDIR}/unexpected-ok"; }
  warn() { printf '%s\n' "$*" > "$warning_log"; }
  confirm_or_abort() { printf '%s\n' "$*" > "$confirm_log"; }
  aws() {
    [[ "$1 $2" == "iam simulate-principal-policy" ]] || return 99
    printf 'ServiceFailure from simulator\n' >&2
    return 254
  }

  check_permissions >/dev/null
  assert_contains "simulator failure keeps AWS error" \
    "ServiceFailure from simulator" "$(cat "$warning_log")"
  assert_eq "simulator failure asks before continuing" \
    "Continue without verified permissions?" "$(cat "$confirm_log")"
  [[ ! -e "${TMPDIR}/unexpected-ok" ]] \
    && pass "simulator failure does not claim verification" \
    || fail_test "simulator failure does not claim verification"
}
test_check_permissions_handles_simulator_failure

printf '\n'
if ((FAIL > 0)); then
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi
printf '%d passed, 0 failed\n' "$PASS"
