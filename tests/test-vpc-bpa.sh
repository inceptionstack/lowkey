#!/usr/bin/env bash
# tests/test-vpc-bpa.sh — VPC BPA exclusion detection and template wiring
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
TEMPLATE="${REPO_ROOT}/deploy/cloudformation/template.yaml"

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
  [[ "$haystack" == *"$needle"* ]] && pass "$description" || fail_test "$description (missing: $needle)"
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
cat > "${TMPDIR}/functions.sh" <<'STUBS'
set -euo pipefail
EXISTING_VPC_ID=""
DEPLOY_REGION="us-east-1"
CREATE_VPC_BPA_EXCLUSION="true"
VPC_BPA_EXCLUSION_STATUS="will be created"
fail() { printf '%s\n' "$*" >&2; exit 1; }
STUBS
sed -n '/^resolve_vpc_bpa_exclusion() {/,/^}/p' "$INSTALL_SH" >> "${TMPDIR}/functions.sh"

printf '── VPC BPA resolution ──\n'

test_new_vpc_creates_exclusion() {
  source "${TMPDIR}/functions.sh"
  aws() { fail "AWS must not be called for a new VPC"; }
  resolve_vpc_bpa_exclusion
  assert_eq "new VPC creates exclusion" "true" "$CREATE_VPC_BPA_EXCLUSION"
  assert_eq "new VPC review status" "will be created" "$VPC_BPA_EXCLUSION_STATUS"
}
test_new_vpc_creates_exclusion

test_existing_bidirectional_exclusion_is_reused() {
  source "${TMPDIR}/functions.sh"
  EXISTING_VPC_ID="vpc-0123456789abcdef0"
  aws() {
    cat <<'JSON'
{"VpcBlockPublicAccessExclusions":[{"ExclusionId":"vpcbpa-excl-1","InternetGatewayExclusionMode":"allow-bidirectional","ResourceArn":"arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0","State":"create-complete"}]}
JSON
  }
  resolve_vpc_bpa_exclusion
  assert_eq "existing bidirectional exclusion is reused" "false" "$CREATE_VPC_BPA_EXCLUSION"
  assert_eq "existing exclusion review status" "already exists" "$VPC_BPA_EXCLUSION_STATUS"
}
test_existing_bidirectional_exclusion_is_reused

test_other_vpc_exclusion_is_ignored() {
  source "${TMPDIR}/functions.sh"
  EXISTING_VPC_ID="vpc-0123456789abcdef0"
  aws() {
    cat <<'JSON'
{"VpcBlockPublicAccessExclusions":[{"ExclusionId":"vpcbpa-excl-other","InternetGatewayExclusionMode":"allow-bidirectional","ResourceArn":"arn:aws:ec2:us-east-1:123456789012:vpc/vpc-fffffffffffffffff","State":"create-complete"}]}
JSON
  }
  resolve_vpc_bpa_exclusion
  assert_eq "other VPC exclusion does not suppress creation" "true" "$CREATE_VPC_BPA_EXCLUSION"
  assert_eq "missing target exclusion review status" "will be created" "$VPC_BPA_EXCLUSION_STATUS"
}
test_other_vpc_exclusion_is_ignored

if (
  source "${TMPDIR}/functions.sh"
  EXISTING_VPC_ID="vpc-0123456789abcdef0"
  aws() {
    cat <<'JSON'
{"VpcBlockPublicAccessExclusions":[{"ExclusionId":"vpcbpa-excl-egress","InternetGatewayExclusionMode":"allow-egress","ResourceArn":"arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0","State":"create-complete"}]}
JSON
  }
  resolve_vpc_bpa_exclusion
) >/dev/null 2>&1; then
  fail_test "egress-only exclusion is rejected because it does not allow ingress"
else
  pass "egress-only exclusion is rejected because it does not allow ingress"
fi

if (
  source "${TMPDIR}/functions.sh"
  EXISTING_VPC_ID="vpc-0123456789abcdef0"
  aws() { return 1; }
  resolve_vpc_bpa_exclusion
) >/dev/null 2>&1; then
  fail_test "existing VPC API failure stops before duplicate creation"
else
  pass "existing VPC API failure stops before duplicate creation"
fi

printf '\n── Installer and CloudFormation wiring ──\n'
summary_body="$(sed -n '/^show_summary() {/,/^}/p' "$INSTALL_SH")"
run_config_body="$(sed -n '/^run_config_and_review() {/,/^}/p' "$INSTALL_SH")"
assert_contains "summary shows BPA status" 'BPA exclusion ${VPC_BPA_EXCLUSION_STATUS:-will be created}' "$summary_body"
assert_contains "summary explains ingress effect" 'allows internet ingress to this VPC' "$summary_body"
assert_contains "config resolves BPA before review" 'resolve_vpc_bpa_exclusion' "$run_config_body"
assert_contains "installer passes BPA creation parameter" 'CreateVpcBpaExclusion' "$(grep '^PARAM_CFN_NAMES=' "$INSTALL_SH")"

if python3 - "$TEMPLATE" <<'PY'
import sys, yaml
class Loader(yaml.SafeLoader):
    pass
Loader.add_multi_constructor(
    '!',
    lambda loader, tag, node: loader.construct_scalar(node)
    if isinstance(node, yaml.ScalarNode)
    else loader.construct_sequence(node)
    if isinstance(node, yaml.SequenceNode)
    else loader.construct_mapping(node),
)
with open(sys.argv[1]) as stream:
    doc = yaml.load(stream, Loader=Loader)
param = doc['Parameters']['CreateVpcBpaExclusion']
assert param['Default'] == 'true'
assert param['AllowedValues'] == ['true', 'false']
condition = doc['Conditions']['ShouldCreateVpcBpaExclusion']
resource = doc['Resources']['VpcBpaExclusion']
assert resource['Type'] == 'AWS::EC2::VPCBlockPublicAccessExclusion'
assert resource['Condition'] == 'ShouldCreateVpcBpaExclusion'
assert resource['Properties']['InternetGatewayExclusionMode'] == 'allow-bidirectional'
assert 'VpcId' in resource['Properties']
instance_dependency = doc['Resources']['Instance']['Metadata']['VpcBpaExclusionDependency']
assert 'VpcBpaExclusion' in repr(instance_dependency)
assert doc['Metadata']['AWSToolsMetrics']['AWSAgentToolkit'] == 'aws-cloudformation@2'
PY
then
  pass "template creates a conditional VPC-wide bidirectional exclusion"
else
  fail_test "template BPA exclusion wiring is invalid"
fi

printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
