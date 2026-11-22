#!/usr/bin/env bash
# Regression tests for verify_aws_credentials in uninstall.sh (issue #132).
# When "aws sts get-caller-identity" fails, the function must show the
# error output and a hint, and then exit 1. It must not stop with no message.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNINSTALL="${UNINSTALL_OVERRIDE:-${ROOT}/uninstall.sh}"
PASS=0
FAIL=0

pass() {
  printf '✓ %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf '✗ %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_contains() {
  local name="$1" expected="$2" actual="$3"
  if grep -Fq -- "$expected" <<< "$actual"; then
    pass "$name"
  else
    fail "$name (missing: ${expected})"
  fi
}

assert_status() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" -eq "$expected" ]]; then
    pass "$name"
  else
    fail "$name (expected exit ${expected}, got ${actual})"
  fi
}

# Run verify_aws_credentials in a child bash with the same "set -euo pipefail"
# as uninstall.sh. The child loads the functions without the last line
# (main "$@") and replaces aws with a fake.
# $1 = scenario: not-set (no credentials) or expired (credentials, auth fails)
#      or ok (sts call works).
run_verify() {
  local scenario="$1"
  FAKE_SCENARIO="$scenario" UNINSTALL="$UNINSTALL" bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    source <(sed "\$d" "$UNINSTALL")
    aws() {
      case "${FAKE_SCENARIO}:$1:$2" in
        ok:sts:get-caller-identity)
          printf "{\"Account\": \"123456789012\"}\n" ;;
        *:sts:get-caller-identity)
          printf "FAKE-STS-ERROR: Unable to locate credentials\n" >&2
          return 255 ;;
        not-set:configure:list)
          printf "access_key     <not set>   None   None\n" ;;
        expired:configure:list)
          printf "access_key     ****ABCD   shared-credentials-file\n" ;;
        *)
          return 1 ;;
      esac
    }
    verify_aws_credentials
    echo "VERIFY-RETURNED"
  ' 2>&1
}

status=0
out=$(run_verify not-set) || status=$?
assert_status "missing credentials: exit 1" 1 "$status"
assert_contains "missing credentials: shows sts error" "FAKE-STS-ERROR" "$out"
assert_contains "missing credentials: shows configure hint" "Run 'aws configure' first" "$out"

status=0
out=$(run_verify expired) || status=$?
assert_status "failed auth: exit 1" 1 "$status"
assert_contains "failed auth: shows sts error" "FAKE-STS-ERROR" "$out"
assert_contains "failed auth: shows refresh hint" "Refresh session" "$out"

status=0
out=$(run_verify ok) || status=$?
assert_status "valid credentials: exit 0" 0 "$status"
assert_contains "valid credentials: function returns" "VERIFY-RETURNED" "$out"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
