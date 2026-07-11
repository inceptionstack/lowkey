#!/usr/bin/env bash
# packs/bedrockify/install.sh — Install bedrockify as a systemd daemon
#
# Usage:
#   ./install.sh [--region us-east-1] [--port 8090] [--model <id>] [--embed-model <id>]
#
# Assumes:
#   - bedrockify binary already installed (npm install -g bedrockify or via mise)
#   - systemd available
#   - IAM role with bedrock:InvokeModel permissions
#
# Idempotent: safe to re-run. Restarts service if already installed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Defaults from config file (written by bootstrap dispatcher), then CLI overrides
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_PORT="$(pack_config_get bedrockify_port "8090")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6")"
PACK_ARG_EMBED_MODEL="$(pack_config_get embed_model "amazon.titan-embed-text-v2:0")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install bedrockify as a systemd daemon (OpenAI-compatible Bedrock proxy).

Options:
  --region       AWS region for Bedrock           (default: us-east-1)
  --port         Port to listen on                (default: 8090)
  --model        Default Bedrock chat model       (default: us.anthropic.claude-sonnet-4-6)
  --embed-model  Default Bedrock embedding model  (default: amazon.titan-embed-text-v2:0)
  --help         Show this help message

Examples:
  ./install.sh --region us-east-1 --port 8090
  ./install.sh --region eu-west-1 --model us.anthropic.claude-sonnet-4-6
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --region)      PACK_ARG_REGION="$2";      shift 2 ;;
    --port)        PACK_ARG_PORT="$2";        shift 2 ;;
    --model)       PACK_ARG_MODEL="$2";       shift 2 ;;
    --embed-model) PACK_ARG_EMBED_MODEL="$2"; shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="$PACK_ARG_REGION"
PORT="$PACK_ARG_PORT"
MODEL="$PACK_ARG_MODEL"
EMBED_MODEL="$PACK_ARG_EMBED_MODEL"

pack_banner "bedrockify"
log "region=${REGION} port=${PORT} model=${MODEL}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl

# ── Install bedrockify binary ──────────────────────────────────────────────────
step "Installing bedrockify binary"

if command -v bedrockify &>/dev/null; then
  BEDROCKIFY_EXISTING="$(bedrockify --version 2>/dev/null || echo unknown)"
  log "bedrockify already installed (${BEDROCKIFY_EXISTING}) — updating"
fi

curl -fsSL https://raw.githubusercontent.com/inceptionstack/bedrockify/main/install.sh | bash

# Ensure binary is on PATH
if ! command -v bedrockify &>/dev/null; then
  if [[ -x /usr/local/bin/bedrockify ]]; then
    export PATH="/usr/local/bin:$PATH"
  else
    fail "bedrockify binary not found after install"
  fi
fi

BEDROCKIFY_VERSION="$(bedrockify --version 2>/dev/null || echo unknown)"
ok "bedrockify installed: ${BEDROCKIFY_VERSION}"

# ── Install daemon ─────────────────────────────────────────────────────────────
step "Installing bedrockify daemon"

# Stop existing service if running (idempotent)
if sudo systemctl is-active bedrockify &>/dev/null; then
  log "Stopping existing bedrockify service..."
  sudo systemctl stop bedrockify
fi

sudo bedrockify install-daemon \
  --region   "${REGION}"      \
  --model    "${MODEL}"       \
  --embed-model "${EMBED_MODEL}" \
  --port     "${PORT}"

ok "Daemon installed"

# ── Enable and start ──────────────────────────────────────────────────────────
step "Enabling and starting service"

sudo systemctl daemon-reload
sudo systemctl enable bedrockify
sudo systemctl start bedrockify

# Wait for readiness (up to 15s)
log "Waiting for bedrockify to be ready..."
for _i in $(seq 1 15); do
  if curl -sf "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# ── Health check ──────────────────────────────────────────────────────────────
step "Health check"

HEALTH=$(curl -sf "http://127.0.0.1:${PORT}/" 2>&1) || true
if printf '%s' "${HEALTH}" | grep -q '"status":"ok"'; then
  ok "bedrockify is healthy on port ${PORT}"
else
  fail "bedrockify health check failed. Run: sudo journalctl -u bedrockify -n 50"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "bedrockify"
printf "\n[PACK:bedrockify] INSTALLED — http://127.0.0.1:%s (systemd: bedrockify)\n" "${PORT}"
