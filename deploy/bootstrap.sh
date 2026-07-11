#!/bin/bash
# deploy/bootstrap.sh — Generic agent pack bootstrap dispatcher
#
# Usage:
#   bootstrap.sh --pack <name> --region <region> [--model <id>] [--key value ...]
#
# Phase 1: System setup (SSM, dnf, data volume, mise, Node.js, .openclaw symlink)
# Phase 2: Pack dispatch (resolve deps from packs/registry.yaml, run install.sh files)
# Phase 3: Post-install (brain files, Claude Code, SSM shell profile, cfn-signal)
#
# Environment variables (all optional unless noted):
#   STACK_NAME   — CloudFormation stack name (enables cfn-signal when set)
#   REGION       — AWS region (overridden by --region if provided)
#   LOGFILE      — log file path (default: /var/log/loki-bootstrap.log)

set -euo pipefail

LOGFILE="${LOGFILE:-/var/log/loki-bootstrap.log}"
exec > >(tee "$LOGFILE") 2>&1

# Trap for unexpected exits — clean up SSM publisher and signal CFN failure
trap '
  echo "[FAIL] Bootstrap exited unexpectedly at line $LINENO" >&2
  aws ssm put-parameter --name "/loki/setup-status" \
    --value "FAILED" \
    --type String --overwrite --region "${REGION:-us-east-1}" >/dev/null 2>&1 || true
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "FAILED at line $LINENO" \
    --type String --overwrite --region "${REGION:-us-east-1}" >/dev/null 2>&1 || true
  touch /tmp/loki-bootstrap-done
  if [[ -n "${STACK_NAME:-}" ]]; then
    if [[ -x /opt/aws/bin/cfn-signal ]]; then
      /opt/aws/bin/cfn-signal -e 1 --stack "${STACK_NAME}" --resource Instance --region "${REGION:-us-east-1}" 2>/dev/null || true
    else
      _INSTANCE_ID=$(get_instance_id)
      aws cloudformation signal-resource \
        --stack-name "${STACK_NAME}" \
        --logical-resource-id Instance \
        --unique-id "$_INSTANCE_ID" \
        --status FAILURE \
        --region "${REGION:-us-east-1}" 2>/dev/null || true
    fi
  fi
' ERR

# ── Helpers ───────────────────────────────────────────────────────────────────

# IMDSv2-only instance ID fetch (instance enforces HttpTokens=required)
get_instance_id() {
  local token
  token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
  if [[ -n "$token" ]]; then
    curl -sf -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo unknown
  else
    echo unknown
  fi
}

STEP_COUNTER_FILE="/tmp/loki-step-counter"
STEP_TOTAL_FILE="/tmp/loki-step-total"
echo "0" > "$STEP_COUNTER_FILE"
echo "0" > "$STEP_TOTAL_FILE"

step() {
  local n
  n=$(cat "$STEP_COUNTER_FILE" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$STEP_COUNTER_FILE"
  local total
  total=$(cat "$STEP_TOTAL_FILE" 2>/dev/null || echo "?")
  echo ""
  echo "========================================"
  echo "[STEP ${n}/${total}] $(date -u '+%H:%M:%S') $1"
  echo "========================================"
  # Publish current step to SSM for the installer to display
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "${n}/${total} $1" \
    --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
}
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
fail() { echo "[FAIL]  $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") --pack <name> [OPTIONS]

Generic agent pack bootstrap dispatcher.

Required:
  --pack <name>     Pack to install (e.g. openclaw, hermes)

Common options:
  --region <r>      AWS region for Bedrock        (default: us-east-1)
  --model <id>      Default Bedrock model ID
  --help            Show this help message

All --key value arguments are forwarded to pack install.sh scripts.
Packs silently ignore arguments they don't recognise.

Examples:
  $(basename "$0") --pack openclaw --region us-east-1 --model us.anthropic.claude-sonnet-4-6
  $(basename "$0") --pack hermes   --region eu-west-1

Environment:
  STACK_NAME    CloudFormation stack name (enables cfn-signal)
  LOGFILE       Override log file path (default: $LOGFILE)
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
PACK_NAME=""
PROFILE_NAME="${PROFILE_NAME:-}"
REGION="${REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-}"
# Pack-specific args (written to JSON config)
MODEL=""
GW_PORT=""
MODEL_MODE=""
BEDROCKIFY_PORT=""
HERMES_MODEL=""
LITELLM_URL=""
LITELLM_KEY=""
LITELLM_MODEL=""
PROVIDER_KEY=""
SKIP_TELEMETRON="false"
# Pack-specific: optional Secrets Manager id/arn to resolve at install time
# into KIRO_API_KEY inside the kiro-cli pack (and potentially others later).
# The raw key is NEVER written to CFN state, UserData, or bootstrap logs.
KIRO_FROM_SECRET=""
TELEGRAM_BOT_TOKEN_SECRET="${TELEGRAM_BOT_TOKEN_SECRET:-}"
TELEGRAM_USER="${TELEGRAM_USER:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --pack)
      [[ $# -gt 1 ]] || { echo "ERROR: --pack requires a value" >&2; exit 1; }
      PACK_NAME="$2"
      shift 2
      ;;
    --profile)
      [[ $# -gt 1 ]] || { echo "ERROR: --profile requires a value" >&2; exit 1; }
      PROFILE_NAME="$2"
      shift 2
      ;;
    --region)
      [[ $# -gt 1 ]] || { echo "ERROR: --region requires a value" >&2; exit 1; }
      REGION="$2"
      shift 2
      ;;
    --model)
      [[ $# -gt 1 ]] || { echo "ERROR: --model requires a value" >&2; exit 1; }
      MODEL="$2"
      shift 2
      ;;
    --gw-port)
      [[ $# -gt 1 ]] || { echo "ERROR: --gw-port requires a value" >&2; exit 1; }
      GW_PORT="$2"
      shift 2
      ;;
    --model-mode)
      [[ $# -gt 1 ]] || { echo "ERROR: --model-mode requires a value" >&2; exit 1; }
      MODEL_MODE="$2"
      shift 2
      ;;
    --bedrockify-port)
      [[ $# -gt 1 ]] || { echo "ERROR: --bedrockify-port requires a value" >&2; exit 1; }
      BEDROCKIFY_PORT="$2"
      shift 2
      ;;
    --hermes-model)
      [[ $# -gt 1 ]] || { echo "ERROR: --hermes-model requires a value" >&2; exit 1; }
      HERMES_MODEL="$2"
      shift 2
      ;;
    --litellm-base-url|--litellm-url)
      [[ $# -gt 1 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      LITELLM_URL="$2"
      shift 2
      ;;
    --litellm-api-key|--litellm-key)
      [[ $# -gt 1 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      LITELLM_KEY="$2"
      shift 2
      ;;
    --litellm-model)
      [[ $# -gt 1 ]] || { echo "ERROR: --litellm-model requires a value" >&2; exit 1; }
      LITELLM_MODEL="$2"
      shift 2
      ;;
    --provider-api-key|--provider-key)
      [[ $# -gt 1 ]] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      PROVIDER_KEY="$2"
      shift 2
      ;;
    --skip-telemetron)
      SKIP_TELEMETRON="true"
      shift
      ;;
    --kiro-from-secret)
      [[ $# -gt 1 ]] || { echo "ERROR: --kiro-from-secret requires a value" >&2; exit 1; }
      KIRO_FROM_SECRET="$2"
      shift 2
      ;;
    --telegram-bot-token-secret)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-bot-token-secret requires a value" >&2; exit 1; }
      TELEGRAM_BOT_TOKEN_SECRET="$2"
      shift 2
      ;;
    --telegram-user)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-user requires a value" >&2; exit 1; }
      TELEGRAM_USER="$2"
      shift 2
      ;;
    --*)
      # Skip unknown options (with optional value)
      if [[ $# -gt 1 ]] && [[ "$2" != --* ]]; then
        shift 2
      else
        shift
      fi
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$PACK_NAME" ]]; then
  echo "ERROR: --pack is required" >&2
  echo ""
  usage
  exit 1
fi

# ── Write pack config JSON ────────────────────────────────────────────────────
PACK_CONFIG="/tmp/loki-pack-config.json"
jq -n \
  --arg pack "$PACK_NAME" \
  --arg profile "$PROFILE_NAME" \
  --arg region "$REGION" \
  --arg model "$MODEL" \
  --arg gw_port "$GW_PORT" \
  --arg model_mode "$MODEL_MODE" \
  --arg bedrockify_port "$BEDROCKIFY_PORT" \
  --arg hermes_model "$HERMES_MODEL" \
  --arg litellm_url "$LITELLM_URL" \
  --arg litellm_key "$LITELLM_KEY" \
  --arg litellm_model "$LITELLM_MODEL" \
  --arg provider_key "$PROVIDER_KEY" \
  --arg from_secret "$KIRO_FROM_SECRET" \
  --arg telegram_bot_token_secret "$TELEGRAM_BOT_TOKEN_SECRET" \
  --arg telegram_user "$TELEGRAM_USER" \
  --arg skip_telemetron "$SKIP_TELEMETRON" \
  '{pack:$pack, profile:$profile, region:$region, model:$model, gw_port:$gw_port,
    model_mode:$model_mode, bedrockify_port:$bedrockify_port,
    hermes_model:$hermes_model, litellm_url:$litellm_url,
    litellm_key:$litellm_key, litellm_model:$litellm_model,
    provider_key:$provider_key,
    "from-secret":$from_secret,
    telegram_bot_token_secret:$telegram_bot_token_secret,
    telegram_user:$telegram_user,
    "skip-telemetron":$skip_telemetron}' > "${PACK_CONFIG}"
chmod 600 "${PACK_CONFIG}"
chown ec2-user:ec2-user "${PACK_CONFIG}"
export PACK_CONFIG
export AWS_DEFAULT_REGION="${REGION}"

# ── Locate repo root ──────────────────────────────────────────────────────────
# bootstrap.sh lives in deploy/, one level above repo root
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
PACKS_DIR="${REPO_DIR}/packs"
REGISTRY="${PACKS_DIR}/registry.yaml"

step "Bootstrap Dispatcher"
info "Pack: ${PACK_NAME} | Profile: ${PROFILE_NAME:-unset} | Region: ${REGION}${STACK_NAME:+ | Stack: $STACK_NAME}"
info "Repo: ${REPO_DIR}"
info "Instance: $(get_instance_id)"

# ── Validate pack exists in registry ─────────────────────────────────────────
if [[ ! -f "$REGISTRY" ]]; then
  fail "Registry not found: $REGISTRY"
  exit 1
fi

# Check pack key exists in registry (look for "  packname:" at start of line)
if ! grep -q "^  ${PACK_NAME}:" "$REGISTRY"; then
  fail "Pack '${PACK_NAME}' not found in registry (${REGISTRY})"
  info "Available packs:"
  grep "^  [a-z]" "$REGISTRY" | awk -F: '{print "  " $1}' | tr -d ' ' | awk '{print "    " $1}'
  exit 1
fi

ok "Pack '${PACK_NAME}' found in registry"

# ── Registry helpers (grep/awk only — no python yaml) ─────────────────────────
# registry_get_flag PACK FIELD — returns "true" or "" for boolean fields
registry_get_flag() {
  local pack="$1"
  local field="$2"
  # Find the pack block and scan until the next top-level pack entry or EOF
  awk "
    /^  ${pack}:/{found=1; next}
    found && /^  [a-z]/{exit}
    found && /^    ${field}: true/{print \"true\"; exit}
  " "$REGISTRY"
}

# registry_get_deps PACK — prints each dep on its own line
registry_get_deps() {
  local pack="$1"
  awk "
    /^  ${pack}:/{found=1; in_deps=0; next}
    found && /^  [a-z]/{exit}
    found && /^    deps:/{in_deps=1; next}
    found && in_deps && /^      - /{gsub(/^      - /, \"\"); print; next}
    found && in_deps && !/^      /{in_deps=0}
  " "$REGISTRY"
}

# registry_get_data_vol PACK — prints data_volume_gb value or "80" default
registry_get_data_vol() {
  local pack="$1"
  local val
  val=$(awk "
    /^  ${pack}:/{found=1; next}
    found && /^  [a-z]/{exit}
    found && /^    data_volume_gb:/{gsub(/^    data_volume_gb: /, \"\"); print; exit}
  " "$REGISTRY")
  echo "${val:-80}"
}

# ── Count total steps dynamically ─────────────────────────────────────────────
# Count step() calls in bootstrap.sh + all pack scripts that will run
_count_steps_in() { grep -c '^step ' "$1" 2>/dev/null || echo 0; }
_total_steps=$(_count_steps_in "${DEPLOY_DIR}/bootstrap.sh")

# Add steps from deps
while IFS= read -r _dep; do
  [[ -n "$_dep" ]] && _dep_script="${PACKS_DIR}/${_dep}/install.sh" && \
    [[ -f "$_dep_script" ]] && _total_steps=$((_total_steps + $(_count_steps_in "$_dep_script")))
done < <(registry_get_deps "${PACK_NAME}")

# Add steps from main pack
_pack_script="${PACKS_DIR}/${PACK_NAME}/install.sh"
[[ -f "$_pack_script" ]] && _total_steps=$((_total_steps + $(_count_steps_in "$_pack_script")))

echo "$_total_steps" > "$STEP_TOTAL_FILE"
chmod 666 "$STEP_COUNTER_FILE" "$STEP_TOTAL_FILE"
chown ec2-user:ec2-user "$STEP_COUNTER_FILE" "$STEP_TOTAL_FILE" 2>/dev/null || true

# ── Phase 1: SYSTEM ───────────────────────────────────────────────────────────
step "Phase 1: System Setup"

# ---- SSM Agent ----
step "SSM Agent"
dnf install -y amazon-ssm-agent 2>/dev/null || true
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
systemctl is-active amazon-ssm-agent >/dev/null 2>&1 && ok "SSM agent running" || fail "SSM agent not running"

# ---- SSM log publisher (background) ----
(
  while [ ! -f /tmp/loki-bootstrap-done ]; do
    aws ssm put-parameter --name "/loki/setup-log" \
      --value "$(tail -c 4000 "${LOGFILE}")" \
      --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
    aws ssm put-parameter --name "/loki/setup-status" \
      --value "IN_PROGRESS" \
      --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
    sleep 30
  done
  aws ssm put-parameter --name "/loki/setup-log" \
    --value "$(tail -c 4000 "${LOGFILE}")" \
    --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
  aws ssm put-parameter --name "/loki/setup-status" \
    --value "COMPLETE" \
    --type String --overwrite --region "${REGION}" >/dev/null 2>&1 || true
) &
SSM_PUB_PID=$!
ok "SSM log publisher running (pid=$SSM_PUB_PID)"

# ---- System updates ----
step "System Updates"

# Ensure ec2-user has passwordless sudo (cloud-init usually sets this, but
# some AMIs or custom configs may not; pack install scripts need sudo for
# dnf, systemctl, etc.)
if [[ ! -f /etc/sudoers.d/ec2-user-nopasswd ]]; then
  echo "ec2-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ec2-user-nopasswd
  chmod 440 /etc/sudoers.d/ec2-user-nopasswd
  ok "Passwordless sudo configured for ec2-user"
else
  ok "Passwordless sudo already configured"
fi

dnf update -y 2>&1 | tail -5
ok "System updated"

# ---- Dependencies ----
step "System Dependencies"
dnf install -y git jq htop tmux gnupg2-minimal libatomic gettext python3-pip dbus-tools
ok "Packages installed"

# Install aws-cfn-bootstrap for cfn-signal (not pre-installed on AL2023)
if [[ ! -x /opt/aws/bin/cfn-signal ]]; then
  info "Installing aws-cfn-bootstrap (provides cfn-signal)..."
  pip3 install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz 2>/dev/null || \
    python3 -m pip install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz 2>/dev/null || true
  [[ -x /opt/aws/bin/cfn-signal ]] && ok "cfn-bootstrap installed (cfn-signal ready)" || warn "cfn-bootstrap install failed — stack may timeout waiting for signal"
fi

# ---- Mount data volume ----
DATA_VOL_GB="$(registry_get_data_vol "${PACK_NAME}")"
step "Data Volume (pack requests ${DATA_VOL_GB}GB)"
if [[ "${DATA_VOL_GB}" -gt 0 ]]; then
  DATA_DEV=""
  for attempt in 1 2 3; do
    for dev in /dev/sdb /dev/nvme1n1 /dev/xvdb; do
      [ -b "$dev" ] && DATA_DEV="$dev" && break 2
    done
    info "Waiting for data volume (attempt $attempt)..." && sleep 10
  done
  if [ -n "$DATA_DEV" ]; then
    blkid "$DATA_DEV" | grep -q ext4 || mkfs.ext4 "$DATA_DEV"
    mkdir -p /mnt/ebs-data && mount "$DATA_DEV" /mnt/ebs-data && chown ec2-user:ec2-user /mnt/ebs-data
    ok "Data volume mounted ($DATA_DEV)"
    UUID=$(blkid -s UUID -o value "$DATA_DEV")
    grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /mnt/ebs-data ext4 defaults,nofail 0 2" >> /etc/fstab
  else
    fail "Data volume not found (expected ${DATA_VOL_GB}GB EBS)!"
  fi
else
  info "Pack requests no data volume — skipping mount"
fi

# ---- Enable systemd user session for ec2-user (needed by openclaw gateway) ----
loginctl enable-linger ec2-user 2>/dev/null || true
# Wait for user runtime dir — linger starts the user manager asynchronously
_EC2_UID=$(id -u ec2-user)
_RUNTIME_DIR="/run/user/${_EC2_UID}"
for _i in $(seq 1 30); do
  [[ -d "${_RUNTIME_DIR}/systemd" ]] && break
  sleep 1
done
if [[ -d "${_RUNTIME_DIR}/systemd" ]]; then
  ok "Enabled loginctl linger for ec2-user (runtime dir ready)"
else
  warn "User runtime dir not ready after 30s — systemctl --user may fail"
fi
# Export for sudo --preserve-env in pack install steps
export XDG_RUNTIME_DIR="${_RUNTIME_DIR}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=${_RUNTIME_DIR}/bus"

# ---- mise + Node.js (as ec2-user) ----
step "mise + Node.js"
export PACK_NAME REGION
# shellcheck disable=SC2016
sudo -u ec2-user bash << 'MISE_EOF'
set -euo pipefail
step() { echo ""; echo "========================================"; echo "[STEP] $(date -u '+%H:%M:%S') $1"; echo "========================================"; }
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }

step "mise install"
# Pin mise version — v2026.7.0+ requires glibc ≥2.38, AL2023 has 2.34
export MISE_VERSION=v2026.5.16
for _attempt in 1 2 3; do
  if curl --retry 3 --retry-delay 2 -fsSL https://mise.run | sh; then
    break
  fi
  if [[ $_attempt -eq 3 ]]; then
    echo "[FAIL] mise install failed after 3 attempts"; exit 1
  fi
  echo "[INFO] mise install attempt $_attempt failed, retrying in 5s..."
  sleep 5
done
export PATH="/home/ec2-user/.local/bin:$PATH"
eval "$(/home/ec2-user/.local/bin/mise activate bash)"
ok "mise installed: $(mise --version 2>/dev/null || echo unknown)"

# Persist mise activation to .bashrc so SSM sessions have node/npm/openclaw on PATH
if ! grep -q 'mise activate' "${HOME}/.bashrc" 2>/dev/null; then
  echo '' >> "${HOME}/.bashrc"
  echo '# mise — runtime version manager (node, python, etc.)' >> "${HOME}/.bashrc"
  echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "${HOME}/.bashrc"
  echo 'eval "$(~/.local/bin/mise activate bash 2>/dev/null)"' >> "${HOME}/.bashrc"
  ok "mise activation added to .bashrc"
fi

step "Node.js"
export MISE_NODE_VERIFY=false
mise use -g node@latest
eval "$(/home/ec2-user/.local/bin/mise activate bash)"
ok "Node installed: $(node --version 2>/dev/null || echo unknown)"
MISE_EOF
ok "mise + Node.js setup complete"

# ---- Pack-specific shell profile (aliases + banner) ----
PACK_PROFILE="${PACKS_DIR}/${PACK_NAME}/resources/shell-profile.sh"
if [[ -f "$PACK_PROFILE" ]]; then
  # Source pack profile to get PACK_ALIASES, PACK_BANNER_NAME, etc.
  # Default all expected vars first — packs may omit optional ones
  PACK_ALIASES=""
  PACK_BANNER_NAME="${PACK_NAME}"
  PACK_BANNER_EMOJI="🤖"
  PACK_BANNER_COMMANDS=""
  source "$PACK_PROFILE"

  # Write AWS env vars + D-Bus session + aliases to ec2-user .bashrc
  sudo -u ec2-user tee -a /home/ec2-user/.bashrc > /dev/null << ALIASES_BLOCK
export AWS_PROFILE="\${AWS_PROFILE:-default}"
export AWS_DEFAULT_REGION="\${AWS_DEFAULT_REGION:-${REGION}}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=\${XDG_RUNTIME_DIR}/bus}"
${PACK_ALIASES}
ALIASES_BLOCK

  # Write welcome banner to ec2-user .bashrc (unquoted heredoc: \$ → $ at write time, ${PACK_*} expanded by outer shell)
  sudo -u ec2-user tee -a /home/ec2-user/.bashrc > /dev/null << BANNER_BLOCK

# Welcome banner (only for interactive login shells)
if [[ \$- == *i* ]] && [[ -z "\$LOKI_BANNER_SHOWN" ]]; then
  export LOKI_BANNER_SHOWN=1
  printf '\n\033[1;35m${PACK_BANNER_EMOJI} InceptionStack ${PACK_BANNER_NAME}\033[0m\n\n'
  printf '${PACK_BANNER_COMMANDS}\n'
fi
BANNER_BLOCK
  ok "Pack shell profile added to .bashrc (${PACK_NAME})"
else
  warn "No shell profile found for pack ${PACK_NAME}"
fi

# ---- .openclaw data volume mount ----
# Use bind mount instead of symlink: OpenClaw's exec sandbox refuses to
# traverse symlinks in the state dir path, breaking all exec tool calls.
step "Data Volume Mount"
OC_HOME="/home/ec2-user"
if [ -d /mnt/ebs-data ]; then
  mkdir -p /mnt/ebs-data/.openclaw
  # If .openclaw is already a symlink from a previous install, remove it
  if [ -L "${OC_HOME}/.openclaw" ]; then
    rm -f "${OC_HOME}/.openclaw"
  fi
  # If .openclaw is a real dir with content, migrate to data volume
  if [ -d "${OC_HOME}/.openclaw" ]; then
    cp -a "${OC_HOME}/.openclaw/"* /mnt/ebs-data/.openclaw/ 2>/dev/null || true
    rm -rf "${OC_HOME}/.openclaw"
  fi
  mkdir -p "${OC_HOME}/.openclaw"
  # Bind mount so .openclaw is a real directory, not a symlink
  if ! mountpoint -q "${OC_HOME}/.openclaw"; then
    mount --bind /mnt/ebs-data/.openclaw "${OC_HOME}/.openclaw"
  fi
  # Persist in fstab for reboots
  if ! grep -q "ebs-data/.openclaw" /etc/fstab; then
    echo "/mnt/ebs-data/.openclaw ${OC_HOME}/.openclaw none bind 0 0" >> /etc/fstab
  fi
  chmod 700 "${OC_HOME}/.openclaw"
  chown ec2-user:ec2-user "${OC_HOME}/.openclaw"
  ok "Bind-mounted .openclaw -> /mnt/ebs-data/.openclaw"
else
  mkdir -p "${OC_HOME}/.openclaw"
  chmod 700 "${OC_HOME}/.openclaw"
  chown ec2-user:ec2-user "${OC_HOME}/.openclaw"
  info "No data volume — using local .openclaw"
fi
mkdir -p "${OC_HOME}/.openclaw/workspace"
chmod 700 "${OC_HOME}/.openclaw/workspace"
chown ec2-user:ec2-user "${OC_HOME}/.openclaw/workspace"
ok "Workspace ready"

# ---- AWS CLI default profile (so SDK finds region without needing IMDS) ----
# Only for profiles that need AWS CLI access (builder, account_assistant)
step "AWS CLI Config"
if [[ "${PROFILE_NAME:-}" == "personal_assistant" ]]; then
  info "Skipping AWS CLI config (personal_assistant profile — Bedrock only)"
else
  mkdir -p "${OC_HOME}/.aws"
  cat > "${OC_HOME}/.aws/config" <<AWSCFG
[default]
region = ${REGION}
output = json
AWSCFG
  chmod 600 "${OC_HOME}/.aws/config"
  chown -R ec2-user:ec2-user "${OC_HOME}/.aws"
  ok "AWS CLI default profile set (region=${REGION})"
fi

# ---- Enable linger for ec2-user (allows user systemd services to survive logout) ----
step "Enable Linger"
loginctl enable-linger ec2-user
ok "Linger enabled for ec2-user"

# ---- Write profile marker file ----
step "Profile Marker"
sudo -u ec2-user bash << PROFILE_EOF
set -euo pipefail
ok()   { echo "[OK]    \$(date -u '+%H:%M:%S') \$1"; }
info() { echo "[INFO]  \$(date -u '+%H:%M:%S') \$1"; }
mkdir -p "\${HOME}/.openclaw/workspace"
echo "${PROFILE_NAME:-}" > "\${HOME}/.openclaw/workspace/.profile"
chmod 644 "\${HOME}/.openclaw/workspace/.profile"
ok "Profile marker written: ${PROFILE_NAME:-unset} -> \${HOME}/.openclaw/workspace/.profile"
PROFILE_EOF

# ── Phase 2: PACKS ────────────────────────────────────────────────────────────
step "Phase 2: Pack Dispatch"

# Resolve deps for the requested pack
DEPS=()
while IFS= read -r dep; do
  [[ -n "$dep" ]] && DEPS+=("$dep")
done < <(registry_get_deps "${PACK_NAME}")

info "Pack: ${PACK_NAME}"
if [[ ${#DEPS[@]} -gt 0 ]]; then
  info "Deps: ${DEPS[*]}"
else
  info "Deps: (none)"
fi

# Run deps first (in order)
for dep in "${DEPS[@]}"; do
  DEP_INSTALL="${PACKS_DIR}/${dep}/install.sh"
  if [[ ! -f "$DEP_INSTALL" ]]; then
    fail "Dependency install script not found: ${DEP_INSTALL}"
    exit 1
  fi
  info "Installing dependency: ${dep}"
  # Run as ec2-user with mise/node on PATH; PACK_CONFIG is auto-detected by packs
  sudo -u ec2-user --preserve-env=PACK_CONFIG,AWS_DEFAULT_REGION,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,LOWKEY_TELEMETRY,DO_NOT_TRACK bash -c '
    export PATH="/home/ec2-user/.local/bin:$PATH"
    eval "$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true
    NODE_PREFIX=$(npm prefix -g 2>/dev/null || true)
    [ -n "$NODE_PREFIX" ] && export PATH="${NODE_PREFIX}/bin:$PATH"
    bash "$@"
  ' -- "${DEP_INSTALL}" || {
    fail "Dependency pack '${dep}' install failed"
    exit 1
  }
  ok "Dependency '${dep}' complete"
done

# Run the requested pack
PACK_INSTALL="${PACKS_DIR}/${PACK_NAME}/install.sh"
if [[ ! -f "$PACK_INSTALL" ]]; then
  fail "Pack install script not found: ${PACK_INSTALL}"
  exit 1
fi
info "Installing pack: ${PACK_NAME}"
sudo -u ec2-user --preserve-env=PACK_CONFIG,AWS_DEFAULT_REGION,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS,LOWKEY_TELEMETRY,DO_NOT_TRACK bash -c '
  export PATH="/home/ec2-user/.local/bin:$PATH"
  eval "$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true
  NODE_PREFIX=$(npm prefix -g 2>/dev/null || true)
  [ -n "$NODE_PREFIX" ] && export PATH="${NODE_PREFIX}/bin:$PATH"
  bash "$@"
' -- "${PACK_INSTALL}" || {
  fail "Pack '${PACK_NAME}' install failed"
  exit 1
}
ok "Pack '${PACK_NAME}' complete"

# ── Phase 3: POST-INSTALL ─────────────────────────────────────────────────────
step "Phase 3: Post-Install"

# ---- Brain files ----
BRAIN_FLAG="$(registry_get_flag "${PACK_NAME}" "brain")"
if [[ "${BRAIN_FLAG}" == "true" ]]; then
  step "InceptionStack Brain"
  BRAIN_REPO="https://raw.githubusercontent.com/inceptionstack/lowkey/main/deploy/brain"
  BRAIN_DEST="/home/ec2-user/.openclaw/workspace"
  mkdir -p "${BRAIN_DEST}"
  for bf in SOUL.md IDENTITY.md USER.md TOOLS.md AGENTS.md CLAUDE.md PROJECT-GUIDELINES.md HEARTBEAT.md APP-REGISTRY.md; do
    curl -fsSL "${BRAIN_REPO}/${bf}" -o "${BRAIN_DEST}/${bf}" 2>/dev/null \
      && info "  + $bf" \
      || info "  - $bf (skip)"
  done
  chown ec2-user:ec2-user "${BRAIN_DEST}/"*.md 2>/dev/null || true
  ok "Brain files installed"
else
  info "Brain files: skipped (brain=false for ${PACK_NAME})"
fi

# ---- Claude Code ----
CC_FLAG="$(registry_get_flag "${PACK_NAME}" "claude_code")"
if [[ "${CC_FLAG}" == "true" ]]; then
  step "Claude Code"
  sudo -u ec2-user bash << 'CC_EOF'
set -euo pipefail
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }
export PATH="/home/ec2-user/.local/bin:$PATH"
eval "$(/home/ec2-user/.local/bin/mise activate bash 2>/dev/null)" 2>/dev/null || true

npm install -g @anthropic-ai/claude-code 2>/dev/null || info "Claude Code install failed (non-fatal)"
if command -v mise &>/dev/null; then
  mise reshim 2>/dev/null || true
fi

if command -v claude &>/dev/null; then
  mkdir -p ~/.claude
  echo "export CLAUDE_CODE_USE_BEDROCK=1" >> ~/.bashrc
  cat > ~/.claude/settings.json << CCEOF
{
  "skipDangerousModePermissionPrompt": true
}
CCEOF
  ok "Claude Code installed: $(claude --version 2>/dev/null || echo unknown)"
else
  info "Claude Code not available after install (non-fatal)"
fi
CC_EOF
else
  info "Claude Code: skipped (claude_code=false for ${PACK_NAME})"
fi

# ---- SSM Shell Profile ----
step "SSM Shell Profile"
# Re-source pack profile if available (may already be sourced, but safe to repeat)
PACK_PROFILE="${PACKS_DIR}/${PACK_NAME}/resources/shell-profile.sh"
_SSM_BANNER_EMOJI="🤖"
_SSM_BANNER_NAME="Agent Environment"
_SSM_BANNER_COMMANDS="  (no commands configured for this pack)"
if [[ -f "$PACK_PROFILE" ]]; then
  source "$PACK_PROFILE"
  _SSM_BANNER_EMOJI="${PACK_BANNER_EMOJI}"
  _SSM_BANNER_NAME="${PACK_BANNER_NAME}"
  _SSM_BANNER_COMMANDS="${PACK_BANNER_COMMANDS}"
fi
cat > /etc/profile.d/loki-aws.sh << AWSPROFILE
# AWS credentials: ensure SDK default chain works (EC2 instance role via IMDS)
export AWS_PROFILE="\${AWS_PROFILE:-default}"
export AWS_DEFAULT_REGION="\${AWS_DEFAULT_REGION:-${REGION}}"
# D-Bus + systemd user session: needed for openclaw gateway restart / systemctl --user
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-unix:path=\${XDG_RUNTIME_DIR}/bus}"
AWSPROFILE
chmod 644 /etc/profile.d/loki-aws.sh

cat > /etc/profile.d/loki.sh << LOKIPROFILE
# SSM session: auto-switch to ec2-user with welcome banner
if [ "\$(whoami)" = "ssm-user" ] && [ -z "\$LOKI_PROFILE_LOADED" ]; then
  export LOKI_PROFILE_LOADED=1
  printf '\n\033[1;35m${_SSM_BANNER_EMOJI} InceptionStack ${_SSM_BANNER_NAME}\033[0m\n\n'
  printf '${_SSM_BANNER_COMMANDS}\n'
  exec sudo -iu ec2-user
fi
LOKIPROFILE
chmod 644 /etc/profile.d/loki.sh
ok "Shell profile installed (/etc/profile.d/loki.sh)"

# ---- Bedrock model access check (runs for ALL profiles — all need inference) ----
step "Bedrock Model Access Check"
sudo -u ec2-user bash << 'BEDROCK_EOF'
set -euo pipefail
ok()   { echo "[OK]    $(date -u '+%H:%M:%S') $1"; }
fail() { echo "[FAIL]  $(date -u '+%H:%M:%S') $1"; }
info() { echo "[INFO]  $(date -u '+%H:%M:%S') $1"; }
if aws bedrock get-use-case-for-model-access --region us-east-1 >/dev/null 2>&1; then
  ok "Bedrock access form verified"
else
  fail "Bedrock access form not submitted — complete it at: https://us-east-1.console.aws.amazon.com/bedrock/home#/modelaccess"
fi
BEDROCK_EOF

# ---- Security services check (skip for personal_assistant — no AWS read access) ----
if [[ "${PROFILE_NAME:-}" == "personal_assistant" ]]; then
  info "Security checks: skipped for personal_assistant profile (agent cannot read findings)"
else
  info "Security checks: applicable for profile '${PROFILE_NAME:-builder}'"
fi

# ---- Complete ----
# ---- Clean up config file (contains secrets) ----
rm -f "${PACK_CONFIG}"
info "Pack config cleaned up"

step "Bootstrap Complete"
touch /tmp/loki-bootstrap-done
ok "Pack '${PACK_NAME}' bootstrap complete at $(date -u)"

# ---- cfn-signal ----
if [[ -n "${STACK_NAME}" ]]; then
  step "CloudFormation Signal"
  _INSTANCE_ID=$(get_instance_id)
  if [[ -x /opt/aws/bin/cfn-signal ]]; then
    /opt/aws/bin/cfn-signal -e 0 --stack "${STACK_NAME}" --resource Instance --region "${REGION}" \
      && ok "cfn-signal sent (stack=${STACK_NAME})" \
      || fail "cfn-signal binary failed"
  else
    # Fallback: signal via AWS CLI when cfn-bootstrap is not installed
    info "cfn-signal binary not found — signalling via AWS CLI"
    aws cloudformation signal-resource \
      --stack-name "${STACK_NAME}" \
      --logical-resource-id Instance \
      --unique-id "${_INSTANCE_ID}" \
      --status SUCCESS \
      --region "${REGION}" \
      && ok "cfn-signal sent via CLI (stack=${STACK_NAME})" \
      || fail "cfn-signal via CLI failed"
  fi
fi
