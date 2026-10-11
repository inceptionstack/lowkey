#!/usr/bin/env bash
# install-idle.sh — Install the idle-shutdown bootstrap.
#
# Idempotent: re-running updates existing resources rather than creating duplicates.
# Does NOT enable the systemd timer — prints the manual command at the end so
# you can review the config first.
#
# Usage:
#   ./install-idle.sh \
#       --region us-east-1 \
#       --instance-id i-0123456789abcdef0 \
#       --chat-id 1234567890 \
#       { --bot-token-ssm-ref /my/existing/ssm/path
#       | --bot-token-file /path/to/token.txt
#       | --reuse-openclaw-bot-token }
#
# Flags:
#   --region R               AWS region (default: us-east-1)
#   --instance-id I          EC2 instance id to manage
#   --chat-id ID             Telegram chat id (required — never auto-derived)
#   --bot-token-ssm-ref P    Existing SSM SecureString param holding the bot token
#   --bot-token-file F       File containing the bot token (stored as SecureString)
#   --reuse-openclaw-bot-token
#                            Read bot token from ~/.openclaw/openclaw.json
#                            (.channels.telegram.botToken) and store as SecureString.
#                            Chat id is NOT auto-derived — pass --chat-id explicitly.
#   --install-user U         Unix user for systemd service (default: $SUDO_USER or current user)
#   --dry-run                Print actions without executing mutations
#   -h, --help               Show this help
set -euo pipefail

# --- Defaults ---
REGION="us-east-1"
INSTANCE_ID=""
CHAT_ID=""
BOT_TOKEN_SSM_REF=""
BOT_TOKEN_FILE=""
REUSE_OPENCLAW=false
INSTALL_USER="${SUDO_USER:-$(id -un)}"
DRY_RUN=false

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { printf "${CYAN}[install-idle]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}  !${NC} %s\n" "$*"; }
die()  { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$*" >&2; exit 1; }

usage() { sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0; }

# --- Arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)                    REGION="$2"; shift 2 ;;
    --instance-id)               INSTANCE_ID="$2"; shift 2 ;;
    --chat-id)                   CHAT_ID="$2"; shift 2 ;;
    --bot-token-ssm-ref)         BOT_TOKEN_SSM_REF="$2"; shift 2 ;;
    --bot-token-file)            BOT_TOKEN_FILE="$2"; shift 2 ;;
    --reuse-openclaw-bot-token)  REUSE_OPENCLAW=true; shift ;;
    --install-user)              INSTALL_USER="$2"; shift 2 ;;
    --dry-run)                   DRY_RUN=true; shift ;;
    -h|--help)                   usage ;;
    *)                           die "Unknown argument: $1" ;;
  esac
done

# --- Validate ---
[[ -z "$INSTANCE_ID" ]] && die "--instance-id is required"
[[ -z "$CHAT_ID"     ]] && die "--chat-id is required (never auto-derived for safety)"
[[ -z "$REGION"      ]] && die "--region is required"

token_src_count=0
[[ -n "$BOT_TOKEN_SSM_REF" ]] && token_src_count=$((token_src_count + 1))
[[ -n "$BOT_TOKEN_FILE"    ]] && token_src_count=$((token_src_count + 1))
$REUSE_OPENCLAW              && token_src_count=$((token_src_count + 1))
(( token_src_count == 1 )) || die "Exactly one of --bot-token-ssm-ref / --bot-token-file / --reuse-openclaw-bot-token must be provided"

id -u "$INSTALL_USER" >/dev/null 2>&1 || die "User '$INSTALL_USER' does not exist"

# --- Root check ---
# The script writes files to /etc/systemd/system and calls `systemctl daemon-reload`
# at step 7. Bail out NOW, before any AWS mutations, if we can't do that. Otherwise
# a non-root invocation would provision SSM/IAM/Lambda/API GW and then abort with
# 'Permission denied' in step 7, leaving a half-installed deployment.
if [[ $EUID -ne 0 ]]; then
  die "install-idle.sh must run as root (need to write /etc/systemd/system and run systemctl). Try: sudo ./install-idle.sh ..."
fi

# --- Resolve the install user's real home via getent (NOT hardcoded /home) ---
# `root` lives in /root, some accounts live in /var/lib/*, LDAP/AD users may have
# custom homes. Everything downstream (WORKSPACE, LOG_DIR, systemd ReadWritePaths,
# idle-check.sh's $HOME-derived paths) must agree on a single source of truth.
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | awk -F: '{print $6}')"
[[ -n "$INSTALL_HOME" && -d "$INSTALL_HOME" ]] \
  || die "Could not resolve home directory for '$INSTALL_USER' via getent passwd"

command -v aws  >/dev/null || die "aws CLI not found"
command -v jq   >/dev/null || die "jq not found"
command -v zip  >/dev/null || die "zip not found"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$INSTALL_HOME/.openclaw/workspace"
LOG_DIR="$INSTALL_HOME/.openclaw/logs"

# --- Execution helpers ---
run() {
  if $DRY_RUN; then
    printf "  ${YELLOW}DRY${NC} %s\n" "$*"
  else
    eval "$@"
  fi
}

run_q() {
  # like run, but don't print the command (for secret-bearing commands)
  if $DRY_RUN; then
    printf "  ${YELLOW}DRY${NC} <redacted aws command>\n"
  else
    eval "$@"
  fi
}

# --- Constants ---
SSM_BOT_TOKEN_PARAM="/openclaw/wake-config/telegram-bot-token"
SSM_CHAT_ID_PARAM="/openclaw/wake-config/telegram-chat-id"
SSM_WAKE_URL_PARAM="/openclaw/wake-config/wake-url"
SSM_TOKEN_PARAM="/openclaw/wake-token"

NOTIFY_LAMBDA="openclaw-idle-notify"
WAKE_LAMBDA="openclaw-idle-wake"
NOTIFY_ROLE="openclaw-idle-notify-role"
WAKE_ROLE="openclaw-idle-wake-role"
API_NAME="openclaw-idle-wake-api"
EVENT_RULE_NAME="openclaw-idle-ec2-state"

ACCT_ID="$(aws sts get-caller-identity --query Account --output text)"

# ---------- 1. SSM: bot token + chat id + wake url placeholder ----------

log "1/7 Resolving Telegram bot token into SSM"

put_ssm_securestring() {
  local name="$1" value="$2"
  run_q "aws ssm put-parameter --name \"$name\" --value \"$value\" --type SecureString --overwrite --region \"$REGION\" --output text > /dev/null"
}

put_ssm_string() {
  local name="$1" value="$2"
  run "aws ssm put-parameter --name \"$name\" --value \"$value\" --type String --overwrite --region \"$REGION\" --output text > /dev/null"
}

if [[ -n "$BOT_TOKEN_SSM_REF" ]]; then
  # Validate it exists (don't print the value)
  aws ssm get-parameter --name "$BOT_TOKEN_SSM_REF" --region "$REGION" --with-decryption --query 'Parameter.Name' --output text >/dev/null \
    || die "SSM parameter $BOT_TOKEN_SSM_REF not found or not readable"
  if [[ "$BOT_TOKEN_SSM_REF" != "$SSM_BOT_TOKEN_PARAM" ]]; then
    # Copy into the canonical param so runtime code has a single source
    TOKEN_VAL="$(aws ssm get-parameter --name "$BOT_TOKEN_SSM_REF" --region "$REGION" --with-decryption --query 'Parameter.Value' --output text)"
    put_ssm_securestring "$SSM_BOT_TOKEN_PARAM" "$TOKEN_VAL"
    unset TOKEN_VAL
    ok "Copied bot token from $BOT_TOKEN_SSM_REF → $SSM_BOT_TOKEN_PARAM"
  else
    ok "Bot token already at canonical path $SSM_BOT_TOKEN_PARAM"
  fi
elif [[ -n "$BOT_TOKEN_FILE" ]]; then
  [[ -r "$BOT_TOKEN_FILE" ]] || die "Cannot read $BOT_TOKEN_FILE"
  TOKEN_VAL="$(tr -d '\n\r ' < "$BOT_TOKEN_FILE")"
  [[ -n "$TOKEN_VAL" ]] || die "$BOT_TOKEN_FILE is empty"
  put_ssm_securestring "$SSM_BOT_TOKEN_PARAM" "$TOKEN_VAL"
  unset TOKEN_VAL
  ok "Stored bot token from $BOT_TOKEN_FILE → $SSM_BOT_TOKEN_PARAM"
else
  OPENCLAW_JSON="$INSTALL_HOME/.openclaw/openclaw.json"
  [[ -r "$OPENCLAW_JSON" ]] || die "$OPENCLAW_JSON not readable (needed for --reuse-openclaw-bot-token)"
  TOKEN_VAL="$(jq -r '.channels.telegram.botToken // empty' "$OPENCLAW_JSON")"
  [[ -n "$TOKEN_VAL" && "$TOKEN_VAL" != "null" ]] \
    || die "No .channels.telegram.botToken in $OPENCLAW_JSON"
  put_ssm_securestring "$SSM_BOT_TOKEN_PARAM" "$TOKEN_VAL"
  unset TOKEN_VAL
  ok "Stored bot token from $OPENCLAW_JSON → $SSM_BOT_TOKEN_PARAM"
fi

put_ssm_string "$SSM_CHAT_ID_PARAM" "$CHAT_ID"
ok "Chat id → $SSM_CHAT_ID_PARAM"

# Wake Lambda reads the instance id from SSM at cold start. Without this the
# wake flow returns 'Config Error' and the instance never starts.
put_ssm_string "/openclaw/wake-config/instance-id" "$INSTANCE_ID"
ok "Instance id → /openclaw/wake-config/instance-id"

# Wake URL written after API GW created (step 5)

# ---------- 2. IAM roles ----------

log "2/7 IAM roles"

ensure_role() {
  local name="$1"
  local trust_doc="$2"
  if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
    ok "Role $name exists"
  else
    run "aws iam create-role --role-name \"$name\" --assume-role-policy-document '$trust_doc' --output text > /dev/null"
    ok "Role $name created"
    log "   sleeping 10s for IAM propagation"
    $DRY_RUN || sleep 10
  fi
}

LAMBDA_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

ensure_role "$NOTIFY_ROLE" "$LAMBDA_TRUST"
ensure_role "$WAKE_ROLE"   "$LAMBDA_TRUST"

run "aws iam attach-role-policy --role-name \"$NOTIFY_ROLE\" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
run "aws iam attach-role-policy --role-name \"$WAKE_ROLE\"   --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

NOTIFY_INLINE=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["ec2:DescribeInstances","ec2:DescribeInstanceStatus"],"Resource":"*"},
  {"Effect":"Allow","Action":["ssm:GetParameter"],"Resource":[
    "arn:aws:ssm:${REGION}:${ACCT_ID}:parameter/openclaw/wake-config/*",
    "arn:aws:ssm:${REGION}:${ACCT_ID}:parameter/openclaw/wake-token"
  ]},
  {"Effect":"Allow","Action":["ssm:PutParameter"],"Resource":[
    "arn:aws:ssm:${REGION}:${ACCT_ID}:parameter/openclaw/wake-token",
    "arn:aws:ssm:${REGION}:${ACCT_ID}:parameter/openclaw/wake-config/last-stop-event-id"
  ]}
]}
JSON
)

WAKE_INLINE=$(cat <<JSON
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["ec2:StartInstances"],
   "Resource":"arn:aws:ec2:${REGION}:${ACCT_ID}:instance/${INSTANCE_ID}"},
  {"Effect":"Allow","Action":["ec2:DescribeInstanceStatus"],"Resource":"*"},
  {"Effect":"Allow","Action":["ssm:GetParameter","ssm:PutParameter","ssm:DeleteParameter"],"Resource":[
    "arn:aws:ssm:${REGION}:${ACCT_ID}:parameter/openclaw/wake-token",
    "arn:aws:ssm:${REGION}:${ACCT_ID}:parameter/openclaw/wake-config/*"
  ]}
]}
JSON
)

run "aws iam put-role-policy --role-name \"$NOTIFY_ROLE\" --policy-name inline --policy-document '$NOTIFY_INLINE'"
run "aws iam put-role-policy --role-name \"$WAKE_ROLE\"   --policy-name inline --policy-document '$WAKE_INLINE'"
ok  "Inline policies applied"

# ---------- 3. Lambdas ----------

log "3/7 Packaging + deploying Lambdas"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# notify-lambda (python3.13)
cp "$SCRIPT_DIR/notify-lambda/handler.py" "$BUILD_DIR/handler.py"
(cd "$BUILD_DIR" && zip -q notify.zip handler.py)

# wake-lambda (nodejs22)
cp "$SCRIPT_DIR/wake-lambda/index.mjs" "$BUILD_DIR/index.mjs"
(cd "$BUILD_DIR" && zip -q wake.zip index.mjs)

deploy_lambda() {
  local name="$1" role="$2" runtime="$3" handler="$4" zip="$5" env_json="$6"
  if aws lambda get-function --function-name "$name" --region "$REGION" >/dev/null 2>&1; then
    run "aws lambda update-function-code --function-name \"$name\" --zip-file fileb://$zip --region \"$REGION\" --output text > /dev/null"
    $DRY_RUN || aws lambda wait function-updated --function-name "$name" --region "$REGION"
    run "aws lambda update-function-configuration --function-name \"$name\" --runtime \"$runtime\" --handler \"$handler\" --role arn:aws:iam::${ACCT_ID}:role/${role} --architectures arm64 --timeout 30 --memory-size 256 --environment '$env_json' --region \"$REGION\" --output text > /dev/null"
    ok "Lambda $name updated"
  else
    run "aws lambda create-function --function-name \"$name\" --runtime \"$runtime\" --handler \"$handler\" --role arn:aws:iam::${ACCT_ID}:role/${role} --architectures arm64 --timeout 30 --memory-size 256 --environment '$env_json' --zip-file fileb://$zip --region \"$REGION\" --output text > /dev/null"
    ok "Lambda $name created"
  fi
}

# Wake URL for the notify Lambda is finalized after the API is created
# (step 4). We bounce the config through a local var and re-apply the env
# once the URL is known — see step 4.
NOTIFY_ENV='{"Variables":{"INSTANCE_ID":"'"$INSTANCE_ID"'","TELEGRAM_CHAT_ID":"'"$CHAT_ID"'"}}'
WAKE_ENV='{"Variables":{"INSTANCE_ID":"'"$INSTANCE_ID"'","TELEGRAM_CHAT_ID":"'"$CHAT_ID"'","REGION":"'"$REGION"'"}}'

deploy_lambda "$NOTIFY_LAMBDA" "$NOTIFY_ROLE" python3.13 handler.handler "$BUILD_DIR/notify.zip" "$NOTIFY_ENV"
deploy_lambda "$WAKE_LAMBDA"   "$WAKE_ROLE"   nodejs22.x index.handler   "$BUILD_DIR/wake.zip"   "$WAKE_ENV"

# ---------- 4. API Gateway HTTP API (wake) ----------

log "4/7 API Gateway for wake Lambda"

API_ID="$(aws apigatewayv2 get-apis --region "$REGION" --query "Items[?Name=='$API_NAME'].ApiId" --output text 2>/dev/null | head -1)"
if [[ -z "$API_ID" || "$API_ID" == "None" ]]; then
  API_ID="$(run "aws apigatewayv2 create-api --name \"$API_NAME\" --protocol-type HTTP --target arn:aws:lambda:${REGION}:${ACCT_ID}:function:${WAKE_LAMBDA} --region \"$REGION\" --query ApiId --output text")"
  ok "API created: $API_ID"
else
  ok "API exists: $API_ID"
fi

# Throttling on the default stage — re-apply each run (idempotent)
run "aws apigatewayv2 update-stage --api-id \"$API_ID\" --stage-name '\$default' --default-route-settings 'ThrottlingBurstLimit=5,ThrottlingRateLimit=2' --region \"$REGION\" --output text > /dev/null"
ok "Stage throttling: 2 rps / 5 burst"

# Permission: apigateway.amazonaws.com must be allowed to InvokeFunction on wake.
# Order matters: permission BEFORE a client tries to invoke.
STMT_ID="apigw-invoke-$(echo "$API_ID" | tr -dc '[:alnum:]')"
aws lambda get-policy --function-name "$WAKE_LAMBDA" --region "$REGION" --output json 2>/dev/null \
  | jq -r '.Policy | fromjson | .Statement[]?.Sid' | grep -q "^$STMT_ID$" \
  || run "aws lambda add-permission --function-name \"$WAKE_LAMBDA\" --statement-id \"$STMT_ID\" --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn 'arn:aws:execute-api:${REGION}:${ACCT_ID}:${API_ID}/*/*' --region \"$REGION\" --output text > /dev/null"
ok "Lambda:InvokeFunction for apigateway granted"

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
put_ssm_string "$SSM_WAKE_URL_PARAM" "$API_ENDPOINT"
ok "Wake URL → $SSM_WAKE_URL_PARAM = $API_ENDPOINT"

# Re-apply notify Lambda env now that we have the wake URL. Without WAKE_URL
# in the env, stop-event Telegram messages contain a bare '?token=...' link.
NOTIFY_ENV_WITH_URL="{\"Variables\":{\"INSTANCE_ID\":\"${INSTANCE_ID}\",\"TELEGRAM_CHAT_ID\":\"${CHAT_ID}\",\"WAKE_URL\":\"${API_ENDPOINT}\"}}"
run "aws lambda update-function-configuration --function-name \"$NOTIFY_LAMBDA\" --environment '$NOTIFY_ENV_WITH_URL' --region \"$REGION\" --output text > /dev/null"
$DRY_RUN || aws lambda wait function-updated --function-name "$NOTIFY_LAMBDA" --region "$REGION"
ok "Notify Lambda env updated with WAKE_URL"

# ---------- 5. EventBridge rule (notify) ----------

log "5/7 EventBridge EC2 state rule"

EVENT_PATTERN=$(cat <<JSON
{"source":["aws.ec2"],"detail-type":["EC2 Instance State-change Notification"],"detail":{"instance-id":["${INSTANCE_ID}"],"state":["running","stopped"]}}
JSON
)

run "aws events put-rule --name \"$EVENT_RULE_NAME\" --event-pattern '$EVENT_PATTERN' --state ENABLED --region \"$REGION\" --output text > /dev/null"
run "aws events put-targets --rule \"$EVENT_RULE_NAME\" --targets 'Id=1,Arn=arn:aws:lambda:${REGION}:${ACCT_ID}:function:${NOTIFY_LAMBDA}' --region \"$REGION\" --output text > /dev/null"
ok "Rule + target set"

EB_STMT_ID="events-invoke-${EVENT_RULE_NAME}"
aws lambda get-policy --function-name "$NOTIFY_LAMBDA" --region "$REGION" --output json 2>/dev/null \
  | jq -r '.Policy | fromjson | .Statement[]?.Sid' | grep -q "^$EB_STMT_ID$" \
  || run "aws lambda add-permission --function-name \"$NOTIFY_LAMBDA\" --statement-id \"$EB_STMT_ID\" --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn 'arn:aws:events:${REGION}:${ACCT_ID}:rule/${EVENT_RULE_NAME}' --region \"$REGION\" --output text > /dev/null"
ok "Lambda:InvokeFunction for events.amazonaws.com granted"

# ---------- 6. On-instance files + systemd ----------

log "6/7 Installing on-instance scripts + systemd units"

run "install -d -o \"$INSTALL_USER\" -g \"$INSTALL_USER\" -m 755 \"$WORKSPACE\""
run "install -d -o \"$INSTALL_USER\" -g \"$INSTALL_USER\" -m 755 \"$LOG_DIR\""
run "install -o \"$INSTALL_USER\" -g \"$INSTALL_USER\" -m 755 \"$SCRIPT_DIR/idle-check.sh\" \"$WORKSPACE/idle-check.sh\""
run "install -o \"$INSTALL_USER\" -g \"$INSTALL_USER\" -m 755 \"$SCRIPT_DIR/idle-check.py\" \"$WORKSPACE/idle-check.py\""

# Substitute ${INSTALL_USER} + ${INSTALL_HOME} in the unit file
TMP_UNIT="$(mktemp)"
sed -e "s|\${INSTALL_USER}|${INSTALL_USER}|g" \
    -e "s|\${INSTALL_HOME}|${INSTALL_HOME}|g" \
    "$SCRIPT_DIR/systemd/idle-check.service" > "$TMP_UNIT"
run "install -o root -g root -m 644 \"$TMP_UNIT\" /etc/systemd/system/idle-check.service"
rm -f "$TMP_UNIT"

run "install -o root -g root -m 644 \"$SCRIPT_DIR/systemd/idle-check.timer\" /etc/systemd/system/idle-check.timer"
run "systemctl daemon-reload"
ok "Systemd units installed (user=$INSTALL_USER). Timer NOT yet enabled."

# ---------- 7. Done ----------

echo
log "${BOLD}Install complete${NC}"
echo
echo "Next step (manual, intentional):"
echo "  ${BOLD}sudo systemctl enable --now idle-check.timer${NC}"
echo
echo "Check status with:"
echo "  systemctl list-timers idle-check.timer"
echo "  tail -f $LOG_DIR/idle-check.log"
echo
echo "Wake URL: $API_ENDPOINT"
echo "Uninstall with: ./uninstall-idle.sh --region $REGION --instance-id $INSTANCE_ID"
