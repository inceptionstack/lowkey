#!/usr/bin/env bash
# tests/test-idle-wake-policy.sh — Contract test for the wake Lambda IAM policy
# in bootstraps/optional/idle-shutdown/install-idle.sh.
#
# EC2 Describe* actions do not support resource-level permissions. They match
# only "Resource": "*". This test reads the WAKE_INLINE policy from the script
# and makes sure that:
#   - the policy is valid JSON after variable substitution
#   - each statement with an ec2:Describe* action has "Resource": "*"
#   - ec2:StartInstances stays limited to the one instance ARN
#
# No AWS required. Run standalone or via CI (discovered by pack-tests.yml).
# Note: pack-tests.yml runs only when its path filters match. Its filters do
# not include bootstraps/**, so a change to install-idle.sh alone does not
# start this test in CI. Run it by hand when you change that file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$REPO_ROOT/bootstraps/optional/idle-shutdown/install-idle.sh"

if [[ ! -f "$INSTALL" ]]; then
  echo "FAIL: install-idle.sh not found at $INSTALL" >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

printf "${BOLD}idle-shutdown wake Lambda IAM policy${NC}\n"

# Get the heredoc body between 'WAKE_INLINE=$(cat <<JSON' and the closing 'JSON'.
POLICY="$(awk '/^WAKE_INLINE=\$\(cat <<JSON$/{f=1; next} f && /^JSON$/{exit} f' "$INSTALL")"

if [[ -z "$POLICY" ]]; then
  fail "WAKE_INLINE heredoc found in install-idle.sh"
  printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
  exit 1
fi
pass "WAKE_INLINE heredoc found in install-idle.sh"

# Check the policy with Python. Each output line is "PASS <msg>" or "FAIL <msg>".
RESULTS="$(POLICY="$POLICY" python3 - <<'PY'
import json, os

region, acct, inst = "us-east-1", "123456789012", "i-0123456789abcdef0"
text = (os.environ["POLICY"]
        .replace("${REGION}", region)
        .replace("${ACCT_ID}", acct)
        .replace("${INSTANCE_ID}", inst))
instance_arn = f"arn:aws:ec2:{region}:{acct}:instance/{inst}"

def out(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)

try:
    doc = json.loads(text)
except ValueError as e:
    out(False, f"policy is valid JSON ({e})")
    raise SystemExit(0)
out(True, "policy is valid JSON")

def as_list(v):
    return v if isinstance(v, list) else [v]

stmts = as_list(doc.get("Statement", []))
describe_seen = False
start_seen = False
for s in stmts:
    actions = as_list(s.get("Action", []))
    resources = as_list(s.get("Resource", []))
    describes = [a for a in actions if a.startswith("ec2:Describe")]
    if "ec2:DescribeInstanceStatus" in actions:
        describe_seen = True
    if describes:
        out(resources == ["*"],
            f"{', '.join(describes)} uses Resource \"*\" (got {resources})")
    if "ec2:StartInstances" in actions:
        start_seen = True
        out(resources == [instance_arn],
            f"ec2:StartInstances is limited to the instance ARN (got {resources})")

out(describe_seen, "policy allows ec2:DescribeInstanceStatus")
out(start_seen, "policy allows ec2:StartInstances")
PY
)"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  case "$line" in
    PASS\ *) pass "${line#PASS }" ;;
    *)       fail "${line#FAIL }" ;;
  esac
done <<< "$RESULTS"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
