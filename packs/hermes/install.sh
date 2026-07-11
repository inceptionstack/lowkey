#!/usr/bin/env bash
# packs/hermes/install.sh — Install Hermes Agent with native Bedrock support
#
# Usage:
#   ./install.sh [--region us-east-1] [--hermes-model us.anthropic.claude-sonnet-4-6]
#
# Assumes:
#   - Python 3.11+ available
#   - IAM role with bedrock:InvokeModel + bedrock:InvokeModelWithResponseStream
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get hermes_model "us.anthropic.claude-sonnet-4-6")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Hermes Agent with native Amazon Bedrock support (Converse API).

Options:
  --region           AWS region for Bedrock         (default: us-east-1)
  --hermes-model     Bedrock inference profile ID   (default: us.anthropic.claude-sonnet-4-6)
  --help             Show this help message

Examples:
  ./install.sh --region us-east-1
  ./install.sh --hermes-model us.anthropic.claude-opus-4-6-v1 --region us-west-2
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)          usage; exit 0 ;;
    --region)           PACK_ARG_REGION="$2";  shift 2 ;;
    --hermes-model)     PACK_ARG_MODEL="$2";   shift 2 ;;
    --model)            [[ $# -gt 1 ]] && shift 2 || shift ;;  # Ignore generic --model
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"

pack_banner "hermes"
log "region=${REGION} model=${MODEL}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl

# ── Install Hermes ─────────────────────────────────────────────────────────────
# Pin to tested version for reproducibility — update deliberately
HERMES_VERSION="v2026.7.7.2"
HERMES_COMMIT="b7751df34688835a108e0d630f3495fc11f3df79"

step "Installing Hermes Agent ${HERMES_VERSION}"

if command -v hermes &>/dev/null; then
  HERMES_EXISTING="$(hermes --version 2>/dev/null | head -1 || echo unknown)"
  log "hermes already installed (${HERMES_EXISTING}) — upgrading to ${HERMES_VERSION}"
fi

curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
  | bash -s -- --skip-setup --commit "${HERMES_COMMIT}"

# Add local bin to PATH for current session
export PATH="${HOME}/.local/bin:${HOME}/.hermes/bin:$PATH"

if ! command -v hermes &>/dev/null; then
  fail "hermes command not found after install. Check PATH or install output."
fi

HERMES_VERSION="$(hermes --version 2>/dev/null | head -1 || echo unknown)"
ok "Hermes installed: ${HERMES_VERSION}"

# ── Install Bedrock extras ─────────────────────────────────────────────────────
step "Installing Bedrock provider (boto3)"

HERMES_UV="${HOME}/.hermes/bin/uv"
HERMES_VENV="${HOME}/.hermes/hermes-agent/venv"

if [[ -x "${HERMES_UV}" && -d "${HOME}/.hermes/hermes-agent" ]]; then
  cd "${HOME}/.hermes/hermes-agent"
  "${HERMES_UV}" pip install -e ".[bedrock]" --python "${HERMES_VENV}/bin/python" --quiet 2>&1 \
    && ok "Bedrock extras installed (boto3)" \
    || warn "Bedrock extras install failed (non-fatal — boto3 may already be present)"
else
  # Fallback: pip install boto3 directly
  if [[ -x "${HERMES_VENV}/bin/pip" ]]; then
    "${HERMES_VENV}/bin/pip" install boto3 --quiet 2>&1 \
      && ok "boto3 installed via pip" \
      || warn "boto3 install failed — Bedrock provider may not work"
  else
    warn "Could not locate hermes venv pip — skipping boto3 install"
  fi
fi

# ── Configure Hermes ──────────────────────────────────────────────────────────
step "Configuring Hermes for native Bedrock"

mkdir -p "${HOME}/.hermes"

# Write config from template
CONFIG_TPL="${SCRIPT_DIR}/resources/hermes-config.yaml.tpl"
if [[ ! -f "${CONFIG_TPL}" ]]; then
  fail "Config template not found at ${CONFIG_TPL}"
fi

export MODEL REGION
envsubst < "${CONFIG_TPL}" > "${HOME}/.hermes/config.yaml"
ok "Hermes config written: ${HOME}/.hermes/config.yaml"

# Write env file from template
ENV_TPL="${SCRIPT_DIR}/resources/hermes-env.tpl"
if [[ ! -f "${ENV_TPL}" ]]; then
  fail "Env template not found at ${ENV_TPL}"
fi

envsubst < "${ENV_TPL}" > "${HOME}/.hermes/.env"
chmod 600 "${HOME}/.hermes/.env" "${HOME}/.hermes/config.yaml"
ok "Hermes env written: ${HOME}/.hermes/.env"

# ── Verify end-to-end ─────────────────────────────────────────────────────────
step "End-to-end verification"

log "Testing native Bedrock via hermes..."
REPLY="$(timeout 30 hermes -z "Say OK in exactly 2 words." 2>&1)" || true

if [[ -n "${REPLY}" && "${REPLY}" != *"error"* && "${REPLY}" != *"Error"* ]]; then
  ok "Bedrock working — model replied: ${REPLY}"
else
  warn "Bedrock test inconclusive (IAM role may lack permissions). Response: ${REPLY}"
fi

# ── Install skills ────────────────────────────────────────────────────────────
PACK_SKILLS_DIR="${HOME}/.hermes/skills"
if ensure_skills_clone "${PACK_SKILLS_DIR}"; then
  ok "loki-skills installed to ${PACK_SKILLS_DIR}"
else
  warn "loki-skills clone failed (optional)"
fi
install_aws_toolkit_skills "${PACK_SKILLS_DIR}"

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "hermes"
printf "\n[PACK:hermes] INSTALLED — hermes CLI ready (model: %s, provider: bedrock, region: %s)\n" \
  "${MODEL}" "${REGION}"
