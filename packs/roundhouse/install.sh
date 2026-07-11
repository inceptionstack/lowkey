#!/usr/bin/env bash
# packs/roundhouse/install.sh — Install Roundhouse and connect to Telegram
#
# Usage:
#   ./install.sh [--telegram-bot-token TOKEN] [--telegram-bot-token-secret SECRET_ID]
#                [--telegram-user USERNAME] [--model MODEL]
#
# Assumes:
#   - npm/node available (mise-managed)
#   - IAM role with secretsmanager:GetSecretValue (if using --telegram-bot-token-secret)
#
# The Telegram bot token is required. It can be provided via:
#   1. --telegram-bot-token flag (plaintext, for dev/test)
#   2. --telegram-bot-token-secret flag (AWS Secrets Manager id/arn, recommended)
#   3. pack config JSON key "telegram_bot_token" or "telegram_bot_token_secret"
#
# Idempotent: safe to re-run (--force).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_TELEGRAM_BOT_TOKEN="$(pack_config_get telegram_bot_token "")"
PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET="$(pack_config_get telegram_bot_token_secret "")"
PACK_ARG_TELEGRAM_USER="$(pack_config_get telegram_user "")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6")"
PACK_ARG_SKIP_TELEMETRON="$(pack_config_get "skip-telemetron" "false")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Roundhouse and connect to Telegram.

Options:
  --telegram-bot-token         Telegram bot token (plaintext, for dev/test)
  --telegram-bot-token-secret  AWS Secrets Manager secret id containing the token
  --telegram-user              Telegram username for pairing (without @)
  --model                      AI model ID (default: us.anthropic.claude-sonnet-4-6)
  --skip-telemetron            Skip the telemetron metrics sidecar
  --help                       Show this help message

One of --telegram-bot-token or --telegram-bot-token-secret is required.

Examples:
  ./install.sh --telegram-bot-token-secret "/my-project/telegram-bot-token" --telegram-user myuser
  ./install.sh --telegram-bot-token "123456:ABC-DEF..." --telegram-user myuser
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage; exit 0 ;;
    --telegram-bot-token)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-bot-token requires a value" >&2; exit 1; }
      PACK_ARG_TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
    --telegram-bot-token-secret)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-bot-token-secret requires a value" >&2; exit 1; }
      PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET="$2"; shift 2 ;;
    --telegram-user)
      [[ $# -gt 1 ]] || { echo "ERROR: --telegram-user requires a value" >&2; exit 1; }
      PACK_ARG_TELEGRAM_USER="$2"; shift 2 ;;
    --model)
      [[ $# -gt 1 ]] || { echo "ERROR: --model requires a value" >&2; exit 1; }
      PACK_ARG_MODEL="$2"; shift 2 ;;
    --skip-telemetron)
      PACK_ARG_SKIP_TELEMETRON="true"; shift ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

# ── Resolve Telegram bot token ────────────────────────────────────────────────
step "Resolving Telegram bot token"

TELEGRAM_TOKEN=""

if [[ -n "${PACK_ARG_TELEGRAM_BOT_TOKEN}" ]]; then
  TELEGRAM_TOKEN="${PACK_ARG_TELEGRAM_BOT_TOKEN}"
  ok "Token provided directly"
elif [[ -n "${PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET}" ]]; then
  TELEGRAM_TOKEN=$(aws secretsmanager get-secret-value \
    --secret-id "${PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET}" \
    --query 'SecretString' --output text 2>/tmp/rh-sm-err.$$) || true
  if [[ -z "$TELEGRAM_TOKEN" || "$TELEGRAM_TOKEN" == "None" ]]; then
    sm_err=$(cat /tmp/rh-sm-err.$$ 2>/dev/null)
    rm -f /tmp/rh-sm-err.$$
    fail "Failed to resolve Telegram bot token from Secrets Manager: ${PACK_ARG_TELEGRAM_BOT_TOKEN_SECRET} ${sm_err:+(${sm_err})}"
  fi
  ok "Token resolved from Secrets Manager"
else
  fail "Telegram bot token is required. Use --telegram-bot-token or --telegram-bot-token-secret"
fi

# Validate token format (basic check: number:alphanumeric)
if [[ ! "$TELEGRAM_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
  fail "Invalid Telegram bot token format"
fi

# ── Install Roundhouse ────────────────────────────────────────────────────────
step "Installing Roundhouse"

npm install -g @inceptionstack/roundhouse

# Reshim if mise is available
if command -v mise &>/dev/null; then
  mise reshim 2>/dev/null || true
fi

# Ensure roundhouse is on PATH
NODE_PREFIX="$(npm prefix -g)"
export PATH="${NODE_PREFIX}/bin:$PATH"

RH_VERSION="$(roundhouse --version 2>/dev/null || echo unknown)"
ok "Roundhouse installed: ${RH_VERSION}"

# ── Run headless setup ────────────────────────────────────────────────────────
step "Running headless Telegram setup"

# roundhouse setup --telegram --headless reads TELEGRAM_BOT_TOKEN from env,
# writes config, .env, installs systemd service, and starts the daemon.
# --user is required for headless mode.
if [[ -z "${PACK_ARG_TELEGRAM_USER}" ]]; then
  fail "Telegram username is required for headless setup. Use --telegram-user"
fi

SETUP_ARGS=(
  --telegram
  --headless
  --force
  --user "${PACK_ARG_TELEGRAM_USER}"
  --model "${PACK_ARG_MODEL}"
  --provider amazon-bedrock
)

TELEGRAM_BOT_TOKEN="${TELEGRAM_TOKEN}" roundhouse setup "${SETUP_ARGS[@]}"

ok "Roundhouse setup complete"

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying service"

sleep 2
if systemctl is-active roundhouse.service &>/dev/null; then
  ok "Roundhouse service is running"
else
  warn "Roundhouse service may not be active yet — check: systemctl status roundhouse.service"
fi


# ── Done ──────────────────────────────────────────────────────────────────────
# ── Install loki-skills + AWS Agent Toolkit skills ───────────────────────────
PACK_SKILLS_DIR="${HOME}/.roundhouse/skills"
if ensure_skills_clone "${PACK_SKILLS_DIR}"; then
  ok "loki-skills installed to ${PACK_SKILLS_DIR}"
else
  warn "loki-skills clone failed (optional)"
fi
install_aws_toolkit_skills "${PACK_SKILLS_DIR}"

write_done_marker "roundhouse"
printf "\n[PACK:roundhouse] INSTALLED — Telegram bot connected (systemd: roundhouse)\n"

# ── Optional sidecar: telemetron ──────────────────────────────────────────────
# Runs after done marker so user sees success immediately.
# shellcheck source=../common-telemetron.sh
source "${SCRIPT_DIR}/../common-telemetron.sh"
install_telemetron roundhouse
