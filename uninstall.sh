#!/usr/bin/env bash
# Lowkey — Uninstaller
# Usage: bash <(curl -sfL https://raw.githubusercontent.com/inceptionstack/lowkey/main/uninstall.sh)
#
# Finds all Lowkey deployments in your account (by loki:managed tag),
# lets you pick which to remove, and cleans up all resources.
set -euo pipefail
export AWS_PAGER=""
export PAGER=""
# Belt-and-suspenders: alias aws to always disable pager
aws() { command aws --no-cli-pager "$@"; }

UNINSTALLER_VERSION="0.1.0"
REPO_URL="https://github.com/inceptionstack/lowkey.git"
DEFAULT_TF_STATE_KEY="loki-agent/terraform.tfstate"

# ============================================================================
# UI helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

prompt() {
  local text="$1" var="$2" default="${3:-}"
  local display="$text"; [[ -n "$default" ]] && display="$text [$default]"
  read -rp "$(echo -e "${BOLD}${display}:${NC} ")" value
  eval "$var=\"\${value:-$default}\""
}

confirm() {
  local text="$1" default="${2:-default_no}"
  local hint="[y/N]"; [[ "$default" == "default_yes" ]] && hint="[Y/n]"
  read -rp "$(echo -e "${BOLD}${text} ${hint}:${NC} ")" answer
  case "$default" in
    default_yes) [[ ! "$answer" =~ ^[Nn]$ ]] ;;
    *)           [[ "$answer" =~ ^[Yy]$ ]] ;;
  esac
}

require_cmd() { command -v "$1" &>/dev/null || fail "$2"; }

# ============================================================================
# AWS helpers
# ============================================================================

verify_aws_credentials() {
  local sts_output sts_rc
  sts_output=$(aws sts get-caller-identity 2>&1)
  sts_rc=$?
  if [[ $sts_rc -ne 0 ]]; then
    warn "aws sts get-caller-identity failed:"
    warn "$sts_output"
    if aws configure list 2>/dev/null | grep -q '<not set>'; then
      fail "AWS credentials not configured. Run 'aws configure' first."
    else
      fail "Credentials configured (profile: ${AWS_PROFILE:-default}) but auth failed. Refresh session or check credential process."
    fi
  fi
}

# Get a single tag value from a resource. Returns "" if not found.
get_tag() {
  local resource_id="$1" tag_key="$2"
  local val
  val=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=${resource_id}" "Name=key,Values=${tag_key}" \
    --region "$SCAN_REGION" --query 'Tags[0].Value' --output text 2>/dev/null || echo "")
  [[ "$val" == "None" ]] && val=""
  echo "$val"
}

# List EC2 resources in a VPC. Usage: list_vpc_resources <vpc_id> <resource_type> <jq_query>
# Returns space-separated IDs.
list_vpc_resources() {
  local vpc_id="$1" filter_type="$2" query="$3"
  aws ec2 "$filter_type" --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" --query "$query" --output text 2>/dev/null || echo ""
}

# Resolve the TF state bucket for a deployment (tagged or conventional).
resolve_tf_state() {
  local idx="$1"
  _TF_BUCKET="${TF_BUCKETS[$idx]:-}"
  _TF_KEY="${TF_KEYS[$idx]:-$DEFAULT_TF_STATE_KEY}"
  # Fall back to conventional names
  if [[ -z "$_TF_BUCKET" ]]; then
    _TF_BUCKET="${WATERMARKS[$idx]}-tfstate-${ACCOUNT_ID}"
  fi
}

# Check if TF state file exists at the resolved location.
tf_state_exists() {
  aws s3api head-bucket --bucket "$_TF_BUCKET" --region "$SCAN_REGION" 2>/dev/null \
    && aws s3api head-object --bucket "$_TF_BUCKET" --key "$_TF_KEY" --region "$SCAN_REGION" &>/dev/null
}

# ============================================================================
# Phase: Banner
# ============================================================================
show_banner() {
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║     🗑️  Lowkey — Uninstaller                  ║${NC}"
  printf "${RED}║${NC}  %-42s${RED}║${NC}\n" "v${UNINSTALLER_VERSION}"
  echo -e "${RED}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  warn "This script ${BOLD}permanently destroys${NC}${YELLOW} Lowkey deployments and all their resources."
  warn "There is NO undo. Data on EC2 instances will be LOST."
  echo ""
}

# ============================================================================
# Phase: Pre-flight
# ============================================================================
preflight() {
  info "Running pre-flight checks..."
  require_cmd aws "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"

  verify_aws_credentials
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
  CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

  ok "Identity: ${CALLER_ARN}"
  echo -e "  ${BOLD}Account:${NC}  ${ACCOUNT_ID}"
  echo -e "  ${BOLD}Region:${NC}   ${REGION}"
  echo ""
}

# ============================================================================
# Phase: Discovery
# ============================================================================
discover_deployments() {
  prompt "AWS region to scan" SCAN_REGION "$REGION"
  echo ""
  info "Scanning for Lowkey deployments in ${SCAN_REGION}..."

  local raw
  raw=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$SCAN_REGION" \
    --query 'Vpcs[*].[VpcId, Tags[?Key==`loki:watermark`].Value|[0], Tags[?Key==`loki:deploy-method`].Value|[0], Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$raw" ]]; then
    ok "No Lowkey deployments found in ${SCAN_REGION}"
    exit 0
  fi

  DEPLOY_COUNT=0
  VPC_IDS=(); WATERMARKS=(); METHODS=(); NAMES=()
  TF_BUCKETS=(); TF_KEYS=()

  while IFS=$'\t' read -r vpc_id watermark method name; do
    VPC_IDS+=("$vpc_id")
    WATERMARKS+=("${watermark:-unknown}")
    METHODS+=("${method:-unknown}")
    NAMES+=("${name:-unnamed}")

    # Fetch TF state tags for terraform deploys
    if [[ "${method:-}" == "terraform" ]]; then
      TF_BUCKETS+=("$(get_tag "$vpc_id" "loki:tf-state-bucket")")
      TF_KEYS+=("$(get_tag "$vpc_id" "loki:tf-state-key")")
    else
      TF_BUCKETS+=(""); TF_KEYS+=("")
    fi
    DEPLOY_COUNT=$((DEPLOY_COUNT + 1))
  done <<< "$raw"

  print_deployments
}

print_deployments() {
  echo ""
  echo -e "  ${BOLD}Found ${DEPLOY_COUNT} Lowkey deployment(s):${NC}"
  echo ""
  for i in $(seq 0 $((DEPLOY_COUNT - 1))); do
    echo -e "    ${BOLD}$((i+1)))${NC} ${VPC_IDS[$i]}  watermark=${YELLOW}${WATERMARKS[$i]}${NC}  method=${METHODS[$i]}  name=${NAMES[$i]}"

    local count
    count=$(aws ec2 describe-instances \
      --filters "Name=vpc-id,Values=${VPC_IDS[$i]}" "Name=instance-state-name,Values=running,stopped" \
      --region "$SCAN_REGION" --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "0")
    echo -e "       EC2 instances: ${count}"

    if [[ -n "${TF_BUCKETS[$i]}" ]]; then
      echo -e "       TF state: s3://${TF_BUCKETS[$i]}/${TF_KEYS[$i]}"
    fi
  done
  echo ""
}

# ============================================================================
# Phase: Selection
# ============================================================================
select_targets() {
  if [[ "$DEPLOY_COUNT" -eq 1 ]]; then
    echo -e "  Only one deployment found."
    confirm "Remove it?" || { echo "Aborted."; exit 0; }
    TARGETS=(0)
    return
  fi

  echo "  Options:"
  echo "    a) Remove ALL deployments"
  echo "    Or enter numbers separated by spaces (e.g. '1 3')"
  echo ""
  local choice
  prompt "Which to remove" choice "a"

  if [[ "$choice" =~ ^[aA]$ ]]; then
    TARGETS=($(seq 0 $((DEPLOY_COUNT - 1))))
  else
    TARGETS=()
    for num in $choice; do
      local idx=$((num - 1))
      if [[ $idx -ge 0 && $idx -lt $DEPLOY_COUNT ]]; then
        TARGETS+=("$idx")
      else
        warn "Ignoring invalid selection: $num"
      fi
    done
  fi
  [[ ${#TARGETS[@]} -gt 0 ]] || fail "No valid deployments selected"
}

# ============================================================================
# Phase: Confirmation
# ============================================================================
# Resolve the CloudFormation stack that owns a VPC from the resource's
# CloudFormation system tag. Do not enumerate every stack in the account: an
# unrelated stack may be inaccessible even when the selected VPC's stack is
# readable, and that should not block teardown of the selected deployment.
vpc_cloudformation_stack_name() {
  local vpc_id="$1" stack_name
  if stack_name=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=${vpc_id}" \
              "Name=key,Values=aws:cloudformation:stack-name" \
    --region "$SCAN_REGION" \
    --query 'Tags[0].Value' --output text 2>/dev/null); then
    [[ -n "$stack_name" && "$stack_name" != "None" ]] || return 1
    printf '%s\n' "$stack_name"
    return 0
  fi
  return 2
}

# Print the lifecycle of the BPA exclusion owned by the stack selected for a VPC.
# The output is one of: owned:<exclusion-id>, retained:<exclusion-id>, or none.
# Reused-VPC exclusions use the retained logical resource and must not trigger a
# warning when their creating stack is removed.
vpc_bpa_lifecycle() {
  local vpc_id="$1"
  local stack_name resources stack_status

  if stack_name=$(vpc_cloudformation_stack_name "$vpc_id"); then
    :
  else
    stack_status=$?
    [[ "$stack_status" -eq 1 ]] && { echo "none"; return 0; }
    return 2
  fi

  if ! resources=$(aws cloudformation describe-stack-resources \
    --stack-name "$stack_name" --region "$SCAN_REGION" \
    --query "StackResources[?ResourceType=='AWS::EC2::VPCBlockPublicAccessExclusion'].[LogicalResourceId,PhysicalResourceId]" \
    --output text 2>/dev/null); then
    return 2
  fi
  while IFS=$'\t' read -r logical_id exclusion_id; do
    case "$logical_id" in
      VpcBpaExclusion)         echo "owned:${exclusion_id:-unknown}"; return 0 ;;
      ExistingVpcBpaExclusion) echo "retained:${exclusion_id:-unknown}"; return 0 ;;
    esac
  done <<< "$resources"
  echo "none"
}

# Return success when a non-selected Lowkey deployment still has a managed EC2
# instance in the target VPC. The selected deployment is identified by the
# instance owned by the CloudFormation stack tagged on this VPC, not by
# LokiWatermark, because independent stacks may use the same watermark.
vpc_stack_instance_ids() {
  local vpc_id="$1"
  local stack_name instances stack_status

  if stack_name=$(vpc_cloudformation_stack_name "$vpc_id"); then
    :
  else
    stack_status=$?
    [[ "$stack_status" -eq 1 ]] && return 1
    return 2
  fi

  if ! instances=$(aws cloudformation describe-stack-resources \
    --stack-name "$stack_name" --region "$SCAN_REGION" \
    --query "StackResources[?ResourceType=='AWS::EC2::Instance'].PhysicalResourceId" \
    --output text 2>/dev/null); then
    return 2
  fi
  printf '%s\n' "$instances"
  return 0
}

vpc_has_other_lowkey_deployment() {
  local vpc_id="$1"
  local selected_instances rows instance_id watermark
  if ! selected_instances=$(vpc_stack_instance_ids "$vpc_id"); then
    return 2
  fi
  if ! rows=$(aws ec2 describe-instances \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=tag:loki:managed,Values=true" \
    --region "$SCAN_REGION" \
    --query 'Reservations[].Instances[?State.Name!=`terminated`].[InstanceId, Tags[?Key==`loki:watermark`].Value|[0]]' \
    --output text 2>/dev/null); then
    return 2
  fi

  while IFS=$'\t' read -r instance_id watermark; do
    [[ -z "$instance_id" || "$instance_id" == "None" ]] && continue
    if grep -Fxq -- "$instance_id" <<< "$selected_instances"; then
      continue
    fi
    return 0
  done <<< "$rows"
  return 1
}

warn_shared_vpc_bpa() {
  local idx="$1"
  local vpc_id="${VPC_IDS[$idx]}" selected_watermark="${WATERMARKS[$idx]}"
  local lifecycle exclusion_id lifecycle_status shared_status sharing_description

  if lifecycle=$(vpc_bpa_lifecycle "$vpc_id"); then
    :
  else
    lifecycle_status=$?
    if [[ "$lifecycle_status" -eq 2 ]]; then
      echo ""
      warn "Could not verify whether VPC ${vpc_id} has a stack-owned BPA exclusion."
      warn "Treating the VPC as potentially shared; review the deployment before continuing."
    fi
    return 0
  fi
  [[ "$lifecycle" == owned:* ]] || return 0
  if vpc_has_other_lowkey_deployment "$vpc_id"; then
    shared_status=0
  else
    shared_status=$?
  fi
  case "$shared_status" in
    1) return 0 ;;
    2)
      echo ""
      warn "Could not verify whether VPC ${vpc_id} has another Lowkey deployment."
      warn "Treating the VPC as shared; review the deployment before continuing."
      sharing_description="may be shared by multiple"
      ;;
    *)
      sharing_description="is shared by multiple"
      ;;
  esac

  exclusion_id="${lifecycle#owned:}"
  echo ""
  warn "VPC ${vpc_id} ${sharing_description} Lowkey deployments."
  echo "  Removing ${selected_watermark} may delete VPC-wide BPA exclusion ${exclusion_id}."
  echo "  Remaining deployment(s) may lose internet ingress and egress."
  echo "  Recreate an allow-bidirectional exclusion, or redeploy the remaining stack with CreateVpcBpaExclusion=true."
}

confirm_destruction() {
  echo ""
  echo -e "  ${RED}${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${RED}${BOLD}║  ⚠️  DESTRUCTIVE OPERATION — POINT OF NO RETURN     ║${NC}"
  echo -e "  ${RED}${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  The following will be ${RED}${BOLD}PERMANENTLY DESTROYED${NC}:"
  echo ""

  for i in "${TARGETS[@]}"; do
    echo -e "    ${RED}✗${NC} ${VPC_IDS[$i]}  (${WATERMARKS[$i]}) — VPC, EC2, IAM, all resources"
    print_teardown_plan "$i"
    warn_shared_vpc_bpa "$i"
  done

  echo ""
  warn "EC2 instance data will be LOST. EBS volumes will be DELETED."
  warn "Security services (GuardDuty, SecurityHub, etc.) may be disabled."
  echo ""

  confirm "Are you SURE you want to destroy these deployments?" || { echo "Aborted."; exit 0; }
  echo ""
  echo -e "  ${RED}Type the word ${BOLD}DESTROY${NC}${RED} to confirm:${NC}"
  local answer
  read -rp "  > " answer
  [[ "$answer" == "DESTROY" ]] || { echo "Aborted."; exit 0; }
  echo ""
}

print_teardown_plan() {
  local i="$1" method="${METHODS[$1]}"
  case "$method" in
    terraform)
      resolve_tf_state "$i"
      if tf_state_exists; then
        echo -e "      ${BOLD}Teardown:${NC} terraform destroy (state: s3://${_TF_BUCKET}/${_TF_KEY})"
      else
        echo -e "      ${YELLOW}TF state not found (tried s3://${_TF_BUCKET}/${_TF_KEY})${NC}"
        echo -e "      ${BOLD}Teardown:${NC} manual resource cleanup"
      fi ;;
    cloudformation|sam)
      echo -e "      ${BOLD}Teardown:${NC} CloudFormation stack delete" ;;
    *)
      echo -e "      ${BOLD}Teardown:${NC} manual resource cleanup" ;;
  esac
}

# ============================================================================
# Removal: orchestrator
# ============================================================================
remove_deployment() {
  local idx="$1"
  local vpc_id="${VPC_IDS[$idx]}" watermark="${WATERMARKS[$idx]}" method="${METHODS[$idx]}"
  local cfn_status

  echo ""
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  info "Removing deployment: ${watermark} (${vpc_id})"
  echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # Strategy 1: CloudFormation stack delete (CFN/SAM deploys)
  if [[ "$method" != "terraform" ]]; then
    if try_delete_cfn_stack "$vpc_id"; then
      ok "Deployment ${watermark} removed via CloudFormation"; return
    else
      cfn_status=$?
      if [[ "$cfn_status" -eq 2 ]]; then
        warn "CloudFormation inspection failed; refusing manual cleanup for ${vpc_id}."
        return 1
      fi
    fi
  fi

  # Strategy 2: terraform destroy (Terraform deploys with state)
  if [[ "$method" == "terraform" ]] && try_terraform_destroy "$idx"; then
    ok "Deployment ${watermark} removed via terraform destroy"; return
  fi

  # Strategy 3: manual resource-by-resource cleanup
  info "Falling back to manual resource cleanup..."
  manual_vpc_cleanup "$vpc_id"
  cleanup_iam_resources "$watermark"
  ok "Deployment ${watermark} removed"
}

# ============================================================================
# Strategy 1: CloudFormation stack delete
# ============================================================================
try_delete_cfn_stack() {
  local vpc_id="$1"
  local stack_name stack_status stack_vpc

  if stack_name=$(vpc_cloudformation_stack_name "$vpc_id"); then
    :
  else
    stack_status=$?
    if [[ "$stack_status" -eq 2 ]]; then
      warn "Could not inspect CloudFormation ownership for VPC ${vpc_id}; refusing to remove it."
      return 2
    fi
    return 1
  fi

  if ! stack_vpc=$(aws cloudformation describe-stack-resources \
    --stack-name "$stack_name" --region "$SCAN_REGION" \
    --query "StackResources[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" \
    --output text 2>/dev/null); then
    warn "Could not inspect CloudFormation stack ${stack_name} for VPC ${vpc_id}; refusing to remove it."
    return 2
  fi
  [[ "$stack_vpc" == *"$vpc_id"* ]] || return 1

  info "Found CloudFormation stack: ${stack_name}"
  info "Deleting stack (this takes 5-10 minutes)..."
  aws cloudformation delete-stack --stack-name "$stack_name" --region "$SCAN_REGION"

  while true; do
    local status
    status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$SCAN_REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1 || echo "DELETE_COMPLETE")
    echo -ne "\r  Status: ${status}              "
    case "$status" in
      DELETE_COMPLETE)     echo ""; return 0 ;;
      *DELETE_FAILED*)     echo ""; warn "Stack delete failed — will try manual cleanup"; return 1 ;;
      *does\ not\ exist*) echo ""; return 0 ;;
      *)                   sleep 15 ;;
    esac
  done
}

# ============================================================================
# Strategy 2: Terraform destroy
# ============================================================================
try_terraform_destroy() {
  local idx="$1"
  command -v terraform &>/dev/null || { warn "Terraform CLI not found"; return 1; }

  resolve_tf_state "$idx"
  tf_state_exists || { warn "TF state not found at s3://${_TF_BUCKET}/${_TF_KEY}"; return 1; }

  info "Using terraform destroy (state: s3://${_TF_BUCKET}/${_TF_KEY})"

  local tf_dir; tf_dir="$(mktemp -d)/lowkey"
  # deploy/terraform/ was removed from main (CloudFormation is the only deploy
  # method now). Clone the pinned legacy tag that still contains the Terraform
  # config so teardown of old Terraform-based deployments keeps working.
  local tf_ref="legacy-terraform"
  info "Cloning lowkey (ref: ${tf_ref}) for Terraform config..."
  if ! git clone --depth 1 --branch "$tf_ref" "$REPO_URL" "$tf_dir" 2>&1 | tail -1; then
    warn "Could not clone legacy Terraform ref '${tf_ref}'"
    rm -rf "$tf_dir"; return 1
  fi
  if ! cd "$tf_dir/deploy/terraform" 2>/dev/null; then
    warn "Legacy ref '${tf_ref}' has no deploy/terraform directory"
    rm -rf "$tf_dir"; return 1
  fi

  cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "${_TF_BUCKET}"
    key            = "${_TF_KEY}"
    region         = "${SCAN_REGION}"
    use_lockfile   = true
    encrypt        = true
  }
}
EOF

  info "Initializing Terraform..."
  if ! terraform init -input=false -reconfigure >/dev/null 2>&1; then
    warn "Terraform init failed"; cd /; rm -rf "$tf_dir"; return 1
  fi

  info "Running terraform destroy (this may take several minutes)..."
  local log; log=$(mktemp)
  set +e; terraform destroy -auto-approve > "$log" 2>&1; local rc=$?; set -e

  grep -E 'Destroying\.\.\.|Destruction complete|Destroy complete' "$log" | while IFS= read -r line; do
    if   [[ "$line" == *"Destroying..."* ]];        then echo -e "  ${RED}-${NC} ${line##*] }"
    elif [[ "$line" == *"Destruction complete"* ]];  then echo -e "  ${GREEN}✓${NC} ${line##*] }"
    elif [[ "$line" == *"Destroy complete"* ]];      then echo -e "\n  ${GREEN}${line}${NC}"
    fi
  done

  if [[ $rc -ne 0 ]]; then
    warn "Terraform destroy failed:"; cat "$log"
  fi
  rm -f "$log"; cd /; rm -rf "$tf_dir"
  [[ $rc -eq 0 ]]
}

# ============================================================================
# Strategy 3: Manual VPC cleanup
# ============================================================================
manual_vpc_cleanup() {
  local vpc_id="$1"

  # 1. Terminate EC2 instances
  local instances
  instances=$(list_vpc_resources "$vpc_id" describe-instances \
    'Reservations[].Instances[?State.Name!=`terminated`].InstanceId[]')
  for iid in $instances; do
    info "Terminating instance: ${iid}"
    aws ec2 modify-instance-attribute --instance-id "$iid" --no-disable-api-termination --region "$SCAN_REGION" 2>/dev/null || true
    aws ec2 terminate-instances --instance-ids "$iid" --region "$SCAN_REGION" >/dev/null 2>&1 || true
  done
  if [[ -n "$instances" ]]; then
    info "Waiting for instances to terminate..."
    for iid in $instances; do
      aws ec2 wait instance-terminated --instance-ids "$iid" --region "$SCAN_REGION" 2>/dev/null || true
    done
    ok "Instances terminated"
  fi

  # 2. Delete ENIs (must happen before SGs)
  local enis
  enis=$(list_vpc_resources "$vpc_id" describe-network-interfaces 'NetworkInterfaces[].NetworkInterfaceId')
  for eni in $enis; do
    local attach
    attach=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$SCAN_REGION" \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || echo "None")
    if [[ "$attach" != "None" && -n "$attach" ]]; then
      aws ec2 detach-network-interface --attachment-id "$attach" --force --region "$SCAN_REGION" 2>/dev/null || true
      sleep 2
    fi
    info "Deleting ENI: ${eni}"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$SCAN_REGION" 2>/dev/null || true
  done

  # 3. Delete security groups (skip default)
  local sgs
  sgs=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || echo "")
  for sg in $sgs; do
    # Revoke all rules to break circular dependencies
    local ingress_rules egress_rules
    ingress_rules=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" --region "$SCAN_REGION" \
      --query 'SecurityGroupRules[?!IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || echo "")
    [[ -n "$ingress_rules" ]] && aws ec2 revoke-security-group-ingress --group-id "$sg" --region "$SCAN_REGION" \
      --security-group-rule-ids $ingress_rules 2>/dev/null || true
    egress_rules=$(aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" --region "$SCAN_REGION" \
      --query 'SecurityGroupRules[?IsEgress].SecurityGroupRuleId' --output text 2>/dev/null || echo "")
    [[ -n "$egress_rules" ]] && aws ec2 revoke-security-group-egress --group-id "$sg" --region "$SCAN_REGION" \
      --security-group-rule-ids $egress_rules 2>/dev/null || true
    info "Deleting SG: ${sg}"
    aws ec2 delete-security-group --group-id "$sg" --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete SG ${sg}"
  done

  # 4. Delete subnets
  local subnets
  subnets=$(list_vpc_resources "$vpc_id" describe-subnets 'Subnets[].SubnetId')
  for s in $subnets; do
    info "Deleting subnet: ${s}"
    aws ec2 delete-subnet --subnet-id "$s" --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete subnet ${s}"
  done

  # 5. Delete non-main route tables
  local rts
  rts=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${vpc_id}" --region "$SCAN_REGION" \
    --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text 2>/dev/null || echo "")
  for rt in $rts; do
    local assocs
    assocs=$(aws ec2 describe-route-tables --route-table-ids "$rt" --region "$SCAN_REGION" \
      --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null || echo "")
    for a in $assocs; do
      aws ec2 disassociate-route-table --association-id "$a" --region "$SCAN_REGION" 2>/dev/null || true
    done
    info "Deleting route table: ${rt}"
    aws ec2 delete-route-table --route-table-id "$rt" --region "$SCAN_REGION" 2>/dev/null || true
  done

  # 6. Detach + delete internet gateways
  local igws
  igws=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --region "$SCAN_REGION" --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || echo "")
  for igw in $igws; do
    info "Detaching + deleting IGW: ${igw}"
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$vpc_id" --region "$SCAN_REGION" 2>/dev/null || true
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$SCAN_REGION" 2>/dev/null || true
  done

  # 7. Delete VPC
  info "Deleting VPC: ${vpc_id}"
  aws ec2 delete-vpc --vpc-id "$vpc_id" --region "$SCAN_REGION" 2>/dev/null \
    || warn "Could not delete VPC ${vpc_id} — some resources may still depend on it"
}

# ============================================================================
# IAM cleanup (roles + users matching watermark with loki:managed tag)
# ============================================================================
cleanup_iam_resources() {
  local watermark="$1"
  cleanup_iam_roles "$watermark"
  cleanup_iam_users "$watermark"
}

# Strip all attachments from an IAM role and delete it
cleanup_iam_roles() {
  local watermark="$1"
  local roles
  roles=$(aws iam list-roles --query "Roles[?contains(RoleName, '${watermark}')].RoleName" --output text 2>/dev/null || echo "")

  for role in $roles; do
    is_loki_managed_role "$role" || continue
    info "Cleaning up IAM role: ${role}"
    detach_all_role_policies "$role"
    remove_role_from_profiles "$role"
    aws iam delete-role --role-name "$role" 2>/dev/null || warn "Could not delete role ${role}"
  done
}

is_loki_managed_role() {
  local val
  val=$(aws iam list-role-tags --role-name "$1" --query "Tags[?Key=='loki:managed'].Value" --output text 2>/dev/null || echo "")
  [[ "$val" == "true" ]]
}

detach_all_role_policies() {
  local role="$1"
  # Managed policies
  local policies
  policies=$(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
  for p in $policies; do aws iam detach-role-policy --role-name "$role" --policy-arn "$p" 2>/dev/null || true; done
  # Inline policies
  local inline
  inline=$(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
  for p in $inline; do aws iam delete-role-policy --role-name "$role" --policy-name "$p" 2>/dev/null || true; done
}

remove_role_from_profiles() {
  local role="$1"
  local profiles
  profiles=$(aws iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' --output text 2>/dev/null || echo "")
  for profile in $profiles; do
    aws iam remove-role-from-instance-profile --role-name "$role" --instance-profile-name "$profile" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$profile" 2>/dev/null || true
  done
}

# Strip all attachments from an IAM user and delete it
cleanup_iam_users() {
  local watermark="$1"
  local users
  users=$(aws iam list-users --query "Users[?contains(UserName, '${watermark}')].UserName" --output text 2>/dev/null || echo "")

  for user in $users; do
    is_loki_managed_user "$user" || continue
    info "Cleaning up IAM user: ${user}"
    detach_all_user_policies "$user"
    delete_user_access_keys "$user"
    aws iam delete-user --user-name "$user" 2>/dev/null || warn "Could not delete user ${user}"
  done
}

is_loki_managed_user() {
  local val
  val=$(aws iam list-user-tags --user-name "$1" --query "Tags[?Key=='loki:managed'].Value" --output text 2>/dev/null || echo "")
  [[ "$val" == "true" ]]
}

detach_all_user_policies() {
  local user="$1"
  local policies
  policies=$(aws iam list-attached-user-policies --user-name "$user" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
  for p in $policies; do aws iam detach-user-policy --user-name "$user" --policy-arn "$p" 2>/dev/null || true; done
  local inline
  inline=$(aws iam list-user-policies --user-name "$user" --query 'PolicyNames[]' --output text 2>/dev/null || echo "")
  for p in $inline; do aws iam delete-user-policy --user-name "$user" --policy-name "$p" 2>/dev/null || true; done
}

delete_user_access_keys() {
  local user="$1"
  local keys
  keys=$(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || echo "")
  for k in $keys; do aws iam delete-access-key --user-name "$user" --access-key-id "$k" 2>/dev/null || true; done
}

# ============================================================================
# Post-removal: optional state resource cleanup
# ============================================================================
offer_state_cleanup() {
  echo ""
  info "Checking for leftover state resources..."

  local -a buckets=()
  local found=false

  for i in "${TARGETS[@]}"; do
    local wm="${WATERMARKS[$i]}"

    # TF state bucket (tagged or conventional)
    resolve_tf_state "$i"
    if aws s3api head-bucket --bucket "$_TF_BUCKET" --region "$SCAN_REGION" 2>/dev/null; then
      found=true; buckets+=("$_TF_BUCKET")
      echo -e "    Terraform state bucket: ${YELLOW}${_TF_BUCKET}${NC}"
    fi

    # CFN template bucket
    local cfn_bucket="${wm}-cfn-templates-${ACCOUNT_ID}"
    if aws s3api head-bucket --bucket "$cfn_bucket" --region "$SCAN_REGION" 2>/dev/null; then
      found=true; buckets+=("$cfn_bucket")
      echo -e "    CFN template bucket:    ${YELLOW}${cfn_bucket}${NC}"
    fi
  done

  $found || { ok "No leftover state resources found"; return; }

  echo ""
  confirm "Delete these state/template resources too?" || return

  for b in "${buckets[@]}"; do
    aws s3 rb "s3://${b}" --force --region "$SCAN_REGION" 2>/dev/null || warn "Could not delete ${b}"
    ok "Deleted bucket: ${b}"
  done
}

# ============================================================================
# Done
# ============================================================================
show_done() {
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║     ✅ Lowkey deployment(s) removed            ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Removed ${#TARGETS[@]} deployment(s) from account ${ACCOUNT_ID} in ${SCAN_REGION}"
  echo ""
  echo -e "  ${BOLD}Note:${NC} Security services (GuardDuty, SecurityHub, Inspector, etc.)"
  echo "  were NOT disabled. Disable them manually if no longer needed:"
  echo "    AWS Console → each service → Settings → Disable"
  echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
  show_banner
  preflight
  discover_deployments
  select_targets
  confirm_destruction

  for i in "${TARGETS[@]}"; do
    remove_deployment "$i"
  done

  offer_state_cleanup
  show_done
}

main "$@"
