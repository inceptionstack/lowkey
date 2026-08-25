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

test_exclusion_beyond_first_page_is_not_inspected() {
  source "${TMPDIR}/functions.sh"
  EXISTING_VPC_ID="vpc-0123456789abcdef0"
  # Documented limitation: only the first 100 exclusions are inspected, so a
  # target hidden behind NextToken is treated as absent rather than paginated.
  aws() {
    while [[ $# -gt 0 ]]; do
      # No continuation flag may be used by either caller.
      case "$1" in
        --next-token|--starting-token) return 252 ;;
      esac
      shift
    done
    printf '{"VpcBlockPublicAccessExclusions":[],"NextToken":"page2"}\n'
  }
  resolve_vpc_bpa_exclusion
  assert_eq "single-page lookup does not paginate" "true" "$CREATE_VPC_BPA_EXCLUSION"
  assert_eq "single-page lookup review status" "will be created" "$VPC_BPA_EXCLUSION_STATUS"
}
test_exclusion_beyond_first_page_is_not_inspected

# Malformed API output must fail closed rather than silently creating a duplicate.
if (
  source "${TMPDIR}/functions.sh"
  EXISTING_VPC_ID="vpc-0123456789abcdef0"
  aws() { printf 'not json\n'; }
  resolve_vpc_bpa_exclusion
) >/dev/null 2>&1; then
  fail_test "malformed exclusion output stops before duplicate creation"
else
  pass "malformed exclusion output stops before duplicate creation"
fi

assert_reused_exclusion_rejected() {
  local state="$1" mode="$2" description="$3" reason="${4:-}"
  if (
    source "${TMPDIR}/functions.sh"
    EXISTING_VPC_ID="vpc-0123456789abcdef0"
    aws() {
      printf '{"VpcBlockPublicAccessExclusions":[{"ExclusionId":"vpcbpa-excl-test","InternetGatewayExclusionMode":"%s","ResourceArn":"arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0","State":"%s","Reason":"%s"}]}\n' \
        "$mode" "$state" "$reason"
    }
    resolve_vpc_bpa_exclusion
  ) >/dev/null 2>&1; then
    fail_test "$description"
  else
    pass "$description"
  fi
}

assert_reused_exclusion_rejected \
  "create-in-progress" "allow-bidirectional" \
  "in-progress exclusion is rejected so bootstrap cannot start early"
assert_reused_exclusion_rejected \
  "update-in-progress" "allow-bidirectional" \
  "updating exclusion is rejected so bootstrap cannot start early"
assert_reused_exclusion_rejected \
  "create-failed" "allow-bidirectional" \
  "failed exclusion is rejected instead of attempting a duplicate" "service rejected request"
assert_reused_exclusion_rejected \
  "delete-in-progress" "allow-bidirectional" \
  "deleting exclusion is rejected instead of attempting a duplicate"
assert_reused_exclusion_rejected \
  "create-complete" "allow-egress" \
  "egress-only exclusion is rejected because it does not allow ingress"

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
permissions_body="$(sed -n '/^check_permissions() {/,/^}/p' "$INSTALL_SH")"
assert_contains "summary shows exact BPA status label" 'BPA exclusion: ${VPC_BPA_EXCLUSION_STATUS:-will be created}' "$summary_body"
assert_contains "summary explains VPC-wide bidirectional scope" 'VPC-wide bidirectional' "$summary_body"
assert_contains "summary explains ingress effect" 'allows internet ingress to this VPC' "$summary_body"
assert_contains "summary explains egress effect" 'and internet egress' "$summary_body"
assert_contains "summary identifies reused exclusion as external" 'external, not managed by this stack' "$summary_body"
assert_contains "config resolves BPA before review" 'resolve_vpc_bpa_exclusion' "$run_config_body"
assert_contains "installer passes BPA creation parameter" 'CreateVpcBpaExclusion' "$(grep '^PARAM_CFN_NAMES=' "$INSTALL_SH")"
assert_contains "permission check includes BPA modification" 'ec2:ModifyVpcBlockPublicAccessExclusion' "$permissions_body"
assert_contains "permission check includes BPA deletion" 'ec2:DeleteVpcBlockPublicAccessExclusion' "$permissions_body"
assert_contains "permission simulation failure is handled separately" 'if ! denied_actions=$(aws iam simulate-principal-policy' "$permissions_body"

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
template_text = open(sys.argv[1]).read()
with open(sys.argv[1]) as stream:
    doc = yaml.load(stream, Loader=Loader)
assert 'ec2:DescribeVpcBlockPublicAccessExclusions' in template_text
assert '--starting-token' not in template_text
assert '--next-token' not in template_text
assert '--max-results 100' in template_text
assert '${!_PRIMARY_MAC%/}' in template_text
bpa_check = template_text.index('aws ec2 describe-vpc-block-public-access-exclusions')
git_clone = template_text.index('git clone --depth 1')
pack_bootstrap = template_text.index('bash /tmp/lowkey/deploy/bootstrap.sh')
assert bpa_check < git_clone < pack_bootstrap
assert 'refusing to start pack bootstrap' in template_text
param = doc['Parameters']['CreateVpcBpaExclusion']
assert param['Default'] == 'true'
assert param['AllowedValues'] == ['true', 'false']
condition = doc['Conditions']['CreateExistingVpcBpaExclusion']
assert 'CreateNewVpc' in repr(condition)
assert 'CreateVpcBpaExclusion' in repr(condition)
new_vpc_resource = doc['Resources']['VpcBpaExclusion']
assert new_vpc_resource['Type'] == 'AWS::EC2::VPCBlockPublicAccessExclusion'
assert new_vpc_resource['Condition'] == 'CreateNewVpc'
assert new_vpc_resource['Properties']['InternetGatewayExclusionMode'] == 'allow-bidirectional'
assert new_vpc_resource['Properties']['VpcId'] == 'VPC'
assert 'DeletionPolicy' not in new_vpc_resource
existing_vpc_resource = doc['Resources']['ExistingVpcBpaExclusion']
assert existing_vpc_resource['Type'] == 'AWS::EC2::VPCBlockPublicAccessExclusion'
assert existing_vpc_resource['Condition'] == 'CreateExistingVpcBpaExclusion'
assert existing_vpc_resource['Properties']['InternetGatewayExclusionMode'] == 'allow-bidirectional'
assert existing_vpc_resource['Properties']['VpcId'] == 'ExistingVpcId'
assert existing_vpc_resource['DeletionPolicy'] == 'Retain'
assert existing_vpc_resource['UpdateReplacePolicy'] == 'Retain'
instance_dependency = doc['Resources']['Instance']['Metadata']['VpcBpaExclusionDependency']
assert 'VpcBpaExclusion' in repr(instance_dependency)
assert 'ExistingVpcBpaExclusion' in repr(instance_dependency)
routing_dependency = repr(doc['Resources']['Instance']['Metadata']['PublicRoutingDependency'])
for required in ('VPCGatewayAttachment', 'PublicRoute', 'PublicSubnetRouteTableAssociation'):
    assert required in routing_dependency
assert doc['Metadata']['AWSToolsMetrics']['AWSAgentToolkit'] == 'aws-cloudformation@2'
PY
then
  pass "template creates a conditional VPC-wide bidirectional exclusion"
else
  fail_test "template BPA exclusion wiring is invalid"
fi

printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
