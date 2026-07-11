#!/usr/bin/env bash
# packs/openclaw/install.sh — Install OpenClaw and start the gateway service
#
# Usage:
#   ./install.sh [OPTIONS]
#
# Assumes:
#   - node/npm available (via mise or system)
#   - python3 available
#   - systemd available (user session)
#   - ~/.openclaw/ directory exists (or will be created)
#   - loginctl linger already enabled for running user (by dispatcher)
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Defaults from config file (written by bootstrap dispatcher), then CLI overrides
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-opus-4-6-v1")"
PACK_ARG_PORT="$(pack_config_get gw_port "3001")"
PACK_ARG_TOKEN="$(pack_config_get gw_token "")"
PACK_ARG_MODEL_MODE="$(pack_config_get model_mode "bedrock")"
PACK_ARG_LITELLM_URL="$(pack_config_get litellm_url "")"
PACK_ARG_LITELLM_KEY="$(pack_config_get litellm_key "")"
PACK_ARG_LITELLM_MODEL="$(pack_config_get litellm_model "claude-opus-4-6")"
PACK_ARG_PROVIDER_KEY="$(pack_config_get provider_key "")"
PACK_ARG_SKIP_TELEMETRON="$(pack_config_get "skip-telemetron" "false")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install OpenClaw and configure the gateway service.

Options:
  --region         AWS region for Bedrock         (default: us-east-1)
  --model          Default Bedrock model ID        (default: us.anthropic.claude-opus-4-6-v1)
  --port           Gateway port                    (default: 3001)
  --token          Gateway auth token              (default: auto-generated)
  --model-mode     bedrock | litellm | api-key   (default: bedrock)
  --litellm-url    LiteLLM base URL (litellm mode)
  --litellm-key    LiteLLM API key  (litellm mode)
  --litellm-model  LiteLLM model ID (litellm mode, default: claude-opus-4-6)
  --provider-key   Anthropic API key (provider-key mode)
  --skip-telemetron  Skip the telemetron metrics sidecar (default: false)
  --help           Show this help message

Examples:
  ./install.sh --region us-east-1 --model us.anthropic.claude-opus-4-6-v1 --port 3001
  ./install.sh --model-mode litellm --litellm-url http://proxy:4000 --litellm-key sk-xxx
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)        usage; exit 0 ;;
    --region)         PACK_ARG_REGION="$2";         shift 2 ;;
    --model)          PACK_ARG_MODEL="$2";           shift 2 ;;
    --port|--gw-port) PACK_ARG_PORT="$2";            shift 2 ;;
    --token)          PACK_ARG_TOKEN="$2";           shift 2 ;;
    --model-mode)     PACK_ARG_MODEL_MODE="$2";      shift 2 ;;
    --litellm-url|--litellm-base-url)    PACK_ARG_LITELLM_URL="$2";     shift 2 ;;
    --litellm-key|--litellm-api-key)     PACK_ARG_LITELLM_KEY="$2";     shift 2 ;;
    --litellm-model)  PACK_ARG_LITELLM_MODEL="$2";   shift 2 ;;
    --provider-key|--provider-api-key)   PACK_ARG_PROVIDER_KEY="$2";    shift 2 ;;
    --skip-telemetron)                   PACK_ARG_SKIP_TELEMETRON="true"; shift ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
GW_PORT="${PACK_ARG_PORT}"
GW_TOKEN="${PACK_ARG_TOKEN}"
MODEL_MODE="${PACK_ARG_MODEL_MODE}"
LITELLM_URL="${PACK_ARG_LITELLM_URL}"
LITELLM_KEY="${PACK_ARG_LITELLM_KEY}"
LITELLM_MODEL="${PACK_ARG_LITELLM_MODEL}"
PROVIDER_KEY="${PACK_ARG_PROVIDER_KEY}"

pack_banner "openclaw"
log "region=${REGION} model=${MODEL} port=${GW_PORT} mode=${MODEL_MODE}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd node npm python3 openssl envsubst

NODE_VERSION="$(node --version 2>/dev/null || echo unknown)"
ok "node found: ${NODE_VERSION}"

# ── Install OpenClaw ──────────────────────────────────────────────────────────
step "Installing OpenClaw"

# Pin to tested version for stability — update deliberately
OPENCLAW_VERSION="2026.6.11"
npm install -g "openclaw@${OPENCLAW_VERSION}"

# Reshim if mise is available
if command -v mise &>/dev/null; then
  mise reshim 2>/dev/null || true
fi

# Ensure openclaw is on PATH for current session
NODE_PREFIX="$(npm prefix -g)"
export PATH="${NODE_PREFIX}/bin:$PATH"

if ! command -v openclaw &>/dev/null; then
  fail "openclaw command not found after npm install"
fi

OC_VERSION="$(openclaw --version 2>/dev/null || echo unknown)"
ok "OpenClaw installed: ${OC_VERSION}"

# ── Install Bedrock provider plugin (required since OpenClaw 2026.6.x) ───────
# In 2026.6.x the bedrock-converse-stream transport was extracted into an
# external plugin. Without it every LLM request fails with:
#   "No API provider registered for api: bedrock-converse-stream"
step "Installing Bedrock provider plugin"
openclaw plugins install @openclaw/amazon-bedrock-provider \
  && ok "@openclaw/amazon-bedrock-provider installed" \
  || { warn "Bedrock provider plugin install failed — gateway will not start"; exit 1; }

# ── Workspace and state dir ───────────────────────────────────────────────────
step "Workspace setup"
mkdir -p "${HOME}/.openclaw/workspace"
chmod 700 "${HOME}/.openclaw"
chmod 700 "${HOME}/.openclaw/workspace"
ok "Workspace ready: ${HOME}/.openclaw/workspace"

# ── Pre-install loki-skills library ─────────────────────────────────
# OpenClaw auto-discovers skills under ~/.openclaw/workspace/skills.
# We clone the shared loki-skills repo into that path and write the same
# .bootstrapped-skills marker BOOTSTRAP-SKILLS.md uses, so the manual
# first-boot flow becomes a no-op.
#
# Repo URL is shared via LOKI_SKILLS_REPO_URL (see packs/common.sh). Each
# pack owns its own install step here so pack-specific wiring can diverge.
# Best-effort: a transient clone failure must not fail the pack install.
SKILLS_DIR="${HOME}/.openclaw/workspace/skills"
SKILLS_MARKER="${HOME}/.openclaw/workspace/memory/.bootstrapped-skills"

skills_write_marker() {
  local source="${1:-unknown}"
  mkdir -p "$(dirname "${SKILLS_MARKER}")"
  printf 'Skills bootstrapped %s (auto via openclaw pack, source=%s)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${source}" \
    > "${SKILLS_MARKER}"
}

skills_origin_url() {
  git -C "${SKILLS_DIR}" config --get remote.origin.url 2>/dev/null || true
}

skills_origin_matches_expected() {
  [[ "$(skills_origin_url)" == "${LOKI_SKILLS_REPO_URL}" ]]
}

skills_count_entries() {
  find "${SKILLS_DIR}" -maxdepth 1 -mindepth 1 ! -name '.*' 2>/dev/null | wc -l
}

skills_dir_is_empty() {
  [[ -z "$(ls -A "${SKILLS_DIR}" 2>/dev/null)" ]]
}

# Update an existing checkout in place, or refuse if its origin has been
# repointed (defends against the installer touching an unrelated repo).
skills_update_existing() {
  if ! skills_origin_matches_expected; then
    local origin; origin="$(skills_origin_url)"
    # Do NOT write the bootstrap marker here. A repointed origin means the
    # canonical loki-skills tree is not installed; leaving the marker absent
    # preserves the manual BOOTSTRAP-SKILLS.md recovery path for the agent.
    warn "loki-skills origin mismatch (expected ${LOKI_SKILLS_REPO_URL}, found ${origin:-none}) -- leaving existing tree untouched, skills marker NOT written"
    return 0
  fi
  if git -C "${SKILLS_DIR}" pull --ff-only --quiet 2>/dev/null; then
    ok "loki-skills updated ($(skills_count_entries) entries)"
    skills_write_marker "${LOKI_SKILLS_REPO_URL}"
    return 0
  fi
  # Fast-forward failed. Only mark bootstrapped if the existing tree is
  # non-empty (still usable for the agent, e.g., transient network blip).
  # An empty/corrupt repo (interrupted clone, bare 'git init') would leave
  # no skills behind -- in that case keep the marker absent so the manual
  # BOOTSTRAP-SKILLS.md recovery path stays available.
  local entries; entries="$(skills_count_entries)"
  if (( entries > 0 )); then
    warn "loki-skills fast-forward failed -- keeping existing tree (${entries} entries)"
    skills_write_marker "${LOKI_SKILLS_REPO_URL}"
  else
    warn "loki-skills fast-forward failed and tree is empty -- skills marker NOT written, agent can recover via BOOTSTRAP-SKILLS.md"
  fi
}

# Returns 0 if the path is now ready for a fresh clone (absent or just cleared);
# returns 1 if it exists with content we will not touch, signalling "skip clone".
skills_prepare_for_fresh_clone() {
  [[ ! -e "${SKILLS_DIR}" ]] && return 0
  if skills_dir_is_empty; then
    rmdir "${SKILLS_DIR}" 2>/dev/null || true
    return 0
  fi
  warn "${SKILLS_DIR} exists but is not a git repo -- leaving alone, skipping skills install"
  return 1
}

skills_fresh_clone() {
  if git clone --depth 1 --quiet "${LOKI_SKILLS_REPO_URL}" "${SKILLS_DIR}" 2>/dev/null; then
    ok "loki-skills cloned from ${LOKI_SKILLS_REPO_URL}"
    skills_write_marker "${LOKI_SKILLS_REPO_URL}"
    return 0
  fi
  # Self-heal: a partial dir from a failed clone would wedge the next run.
  rm -rf "${SKILLS_DIR}" 2>/dev/null || true
  warn "loki-skills clone failed -- agent can run BOOTSTRAP-SKILLS.md manually"
}

skills_install() {
  if ! command -v git &>/dev/null; then
    warn "git not found -- skipping loki-skills (agent can run BOOTSTRAP-SKILLS.md manually)"
    return 0
  fi
  if [[ -d "${SKILLS_DIR}/.git" ]]; then
    skills_update_existing
    return 0
  fi
  if ! skills_prepare_for_fresh_clone; then
    return 0
  fi
  skills_fresh_clone
}

step "Installing loki-skills library"
# Wrap in a subshell + ||-guard so ANY runtime failure in skills_install
# (errexit, pipefail, explicit exit, missing command, signal death, unbound
# var) cannot kill the pack install. Parse-time syntax errors in this file
# itself would still fail before we reach this line -- those must be caught
# by `bash -n` in CI. This is the best-effort contract: skills are
# nice-to-have, the agent can recover via BOOTSTRAP-SKILLS.md if anything
# here goes sideways.
_skills_rc=0
( skills_install ) || _skills_rc=$?
if (( _skills_rc != 0 )); then
  warn "loki-skills install failed (rc=${_skills_rc}) -- continuing pack install (best-effort); agent can recover via BOOTSTRAP-SKILLS.md"
fi
unset _skills_rc

# ── Generate token if not provided ────────────────────────────────────────────
if [[ -z "${GW_TOKEN}" ]]; then
  GW_TOKEN="$(openssl rand -hex 24)"
  log "Generated gateway token"
fi

# ── Generate OpenClaw config ──────────────────────────────────────────────────
step "Generating OpenClaw config"

CONFIG_GEN="${SCRIPT_DIR}/resources/config-gen.py"
if [[ ! -f "${CONFIG_GEN}" ]]; then
  fail "config-gen.py not found at ${CONFIG_GEN}"
fi

GW_TOKEN_ENV="${GW_TOKEN}" LITELLM_KEY_ENV="${LITELLM_KEY}" PROVIDER_KEY_ENV="${PROVIDER_KEY}" \
python3 "${CONFIG_GEN}" \
  "${REGION}"        \
  "${MODEL}"         \
  "${GW_PORT}"       \
  ""                 \
  "${MODEL_MODE}"    \
  "${LITELLM_URL}"   \
  ""                 \
  "${LITELLM_MODEL}" \
  ""

chmod 600 "${HOME}/.openclaw/openclaw.json"
ok "Config written and secured (mode=${MODEL_MODE})"

# ── Exec approvals config ─────────────────────────────────────────────────────
step "Writing exec-approvals config"

# Resolve real path to avoid symlink traversal issues with exec sandbox
EXEC_APPROVALS_DIR="$(readlink -f "${HOME}/.openclaw" 2>/dev/null || echo "${HOME}/.openclaw")"
EXEC_APPROVALS_FILE="${EXEC_APPROVALS_DIR}/exec-approvals.json"
if [[ ! -f "${EXEC_APPROVALS_FILE}" ]]; then
  cat > "${EXEC_APPROVALS_FILE}" <<'EOJSON'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "autoAllowSkills": true
  },
  "agents": {}
}
EOJSON
  chmod 600 "${EXEC_APPROVALS_FILE}"
  ok "exec-approvals.json written (security=full, ask=off)"
else
  ok "exec-approvals.json already exists — skipping"
fi

# ── Install systemd user service ──────────────────────────────────────────────
step "Installing systemd user service"

NODE_BIN="$(command -v node)"
OC_MAIN="${NODE_PREFIX}/lib/node_modules/openclaw/dist/index.js"

mkdir -p "${HOME}/.config/systemd/user"

# Expand template (resources/openclaw-gateway.service.tpl)
SERVICE_TPL="${SCRIPT_DIR}/resources/openclaw-gateway.service.tpl"
if [[ ! -f "${SERVICE_TPL}" ]]; then
  fail "Service template not found at ${SERVICE_TPL}"
fi

export NODE_BIN OC_MAIN GW_PORT GW_TOKEN NODE_PREFIX OC_VERSION
export USER_HOME="${HOME}"
export AWS_DEFAULT_REGION="${REGION}"
envsubst < "${SERVICE_TPL}" > "${HOME}/.config/systemd/user/openclaw-gateway.service"
chmod 600 "${HOME}/.config/systemd/user/openclaw-gateway.service"
ok "Service unit written"

# ── Enable and start service ──────────────────────────────────────────────────
step "Starting gateway service"

# Enable linger (may already be done by dispatcher, but safe to repeat)
loginctl enable-linger "$(id -un)" 2>/dev/null || true

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
systemctl --user daemon-reload
systemctl --user enable openclaw-gateway.service

# Stop first if already running (idempotent restart)
systemctl --user stop openclaw-gateway.service 2>/dev/null || true
systemctl --user start openclaw-gateway.service

# Wait for service to settle
sleep 3

if systemctl --user is-active openclaw-gateway.service &>/dev/null; then
  ok "Gateway service is running"
else
  warn "Gateway service may not be active yet — check: systemctl --user status openclaw-gateway.service"
fi


# ── Done ──────────────────────────────────────────────────────────────────────
# Mark the pack done and show the success banner BEFORE optional sidecars.
# The user should not wait on best-effort work to see that their install
# succeeded.
write_done_marker "openclaw"
printf "\n[PACK:openclaw] INSTALLED — gateway on :%s (systemd: openclaw-gateway)\n" "${GW_PORT}"


# ── Optional sidecar: telemetron ──────────────────────────────────────────────
# shellcheck source=../common-telemetron.sh
source "${SCRIPT_DIR}/../common-telemetron.sh"
install_telemetron openclaw
