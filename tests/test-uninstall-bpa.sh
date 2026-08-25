#!/usr/bin/env bash
# Regression tests for uninstall.sh's shared-VPC BPA warning.
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

assert_not_contains() {
  local name="$1" unexpected="$2" actual="$3"
  if grep -Fq -- "$unexpected" <<< "$actual"; then
    fail "$name (unexpected: ${unexpected})"
  else
    pass "$name"
  fi
}

# Source the functions without running uninstall.sh's main entrypoint.
# shellcheck disable=SC1090
source <(sed '$d' "$UNINSTALL")

SCAN_REGION="us-east-1"
VPC_IDS=("vpc-target")
WATERMARKS=("target")

aws() {
  local service="$1" operation="$2"
  case "${FAKE_SCENARIO}:${service}:${operation}" in
    shared:cloudformation:list-stacks|retained:cloudformation:list-stacks|single:cloudformation:list-stacks|failed-scan:cloudformation:list-stacks)
      printf 'stack-target\n'
      ;;
    shared:cloudformation:describe-stack-resources|retained:cloudformation:describe-stack-resources|single:cloudformation:describe-stack-resources|failed-scan:cloudformation:describe-stack-resources)
      if [[ "$*" == *"ResourceType=='AWS::EC2::VPCBlockPublicAccessExclusion'"* ]]; then
        case "$FAKE_SCENARIO" in
          retained) printf 'ExistingVpcBpaExclusion\tbpa-retained\n' ;;
          *)        printf 'VpcBpaExclusion\tbpa-owned\n' ;;
        esac
      else
        printf 'vpc-target\n'
      fi
      ;;
    shared:ec2:describe-instances|retained:ec2:describe-instances)
      printf 'i-target\ttarget\ni-other\tother\n'
      ;;
    single:ec2:describe-instances)
      printf 'i-target\ttarget\n'
      ;;
    failed-scan:ec2:describe-instances)
      return 1
      ;;
    *)
      printf 'unexpected fake AWS call: %s %s\n' "$service" "$operation" >&2
      return 1
      ;;
  esac
}

FAKE_SCENARIO=shared
output=$(warn_shared_vpc_bpa 0)
assert_contains "shared VPC warning names the VPC" "VPC vpc-target is shared" "$output"
assert_contains "shared VPC warning names the exclusion" "bpa-owned" "$output"
assert_contains "shared VPC warning gives remediation" "CreateVpcBpaExclusion=true" "$output"

FAKE_SCENARIO=retained
output=$(warn_shared_vpc_bpa 0)
assert_not_contains "retained exclusion suppresses warning" "VPC vpc-target is shared" "$output"

FAKE_SCENARIO=single
output=$(warn_shared_vpc_bpa 0)
assert_not_contains "unshared VPC suppresses warning" "VPC vpc-target is shared" "$output"

FAKE_SCENARIO=failed-scan
output=$(warn_shared_vpc_bpa 0)
assert_contains "failed instance scan warns instead of suppressing" "Could not verify whether VPC vpc-target has another Lowkey deployment" "$output"
assert_contains "failed instance scan treats VPC as potentially shared" "VPC vpc-target may be shared by multiple Lowkey deployments" "$output"

printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
