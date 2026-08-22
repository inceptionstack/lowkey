#!/usr/bin/env bash
# packs/kirocrew/install.sh — Install Kiro CLI + KiroCrew multi-agent gateway
#
# Usage:
#   ./install.sh [--region us-east-1]
#                [--from-secret SECRET_ID_OR_ARN]
#                [--channel stable|nightly|insider]
#                [--kirocrew-version X.Y.Z]
#                [--extras aws,voice]
#                [--gateway-port 5476]
#                [--start-gateway true|false]
#                [--kirocrew-home /path/to/home]
#
# Two-phase pack:
#   Phase 1: Installs Kiro CLI (same logic as packs/kiro-cli — inline, no dep)
#   Phase 2: Installs KiroCrew gateway on top (drives kiro-cli over ACP)
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_FROM_SECRET="$(pack_config_get from-secret "")"
PACK_ARG_API_KEY="$(pack_config_get kiro-api-key "")"
PACK_ARG_CHANNEL="$(pack_config_get channel "stable")"
PACK_ARG_KIROCREW_VERSION="$(pack_config_get kirocrew-version "0.3.0")"
PACK_ARG_EXTRAS="$(pack_config_get extras "aws,voice")"
PACK_ARG_GATEWAY_PORT="$(pack_config_get gateway-port "5476")"
PACK_ARG_START_GATEWAY="$(pack_config_get start-gateway "true")"
PACK_ARG_KIROCREW_HOME="$(pack_config_get kirocrew-home "")"
PACK_ARG_PROFILE="$(pack_config_get profile "")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Kiro CLI + KiroCrew multi-agent gateway.

Phase 1 installs Kiro CLI v2 (same as kiro-cli pack, inline).
Phase 2 installs KiroCrew gateway on top (drives kiro-cli over ACP).

Options:
  --region             AWS region (informational only)              [default: us-east-1]
  --from-secret        Secrets Manager id/arn for Kiro API key      [default: ""]
  --channel            KiroCrew release channel                     [default: stable]
                       (stable | nightly | insider)
  --kirocrew-version   Pin KiroCrew version                         [default: latest]
  --extras             Comma-separated pip extras (aws,voice)       [default: aws,voice]
  --gateway-port       KiroCrew gateway port                        [default: 5476]
  --start-gateway      Enable systemd service (true|false)          [default: true]
  --kirocrew-home      Override data home (KIROCREW_HOME)            [default: ~/.kiro/crew]
  --help               Show this help message

Post-install:
  kirocrew doctor      Verify kiro-cli, auth, MCP, embeddings
  kirocrew gateway     Start manually (if --start-gateway=false)
  http://<host>:5476   Web dashboard (if gateway running)

Examples:
  ./install.sh --from-secret faststart/kiro-api-key
  ./install.sh --channel nightly --extras aws,voice
  ./install.sh --start-gateway false
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage; exit 0 ;;
    --region)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --region requires a value" >&2; exit 2; }
      PACK_ARG_REGION="$2"; shift 2 ;;
    --kiro-api-key)
      # Hidden legacy flag — accepted but discouraged (argv-leak risk).
      [[ $# -ge 2 ]] || { echo "error: --kiro-api-key requires a value" >&2; exit 2; }
      case "$2" in -*) echo "error: --kiro-api-key value must not start with '-'" >&2; exit 2 ;; esac
      PACK_ARG_API_KEY="$2"; shift 2 ;;
    --from-secret)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --from-secret requires a value" >&2; exit 2; }
      PACK_ARG_FROM_SECRET="$2"; shift 2 ;;
    --channel)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --channel requires a value" >&2; exit 2; }
      PACK_ARG_CHANNEL="$2"; shift 2 ;;
    --kirocrew-version)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --kirocrew-version requires a value" >&2; exit 2; }
      PACK_ARG_KIROCREW_VERSION="$2"; shift 2 ;;
    --extras)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --extras requires a value" >&2; exit 2; }
      PACK_ARG_EXTRAS="$2"; shift 2 ;;
    --gateway-port)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --gateway-port requires a value" >&2; exit 2; }
      if ! [[ "$2" =~ ^[0-9]+$ ]] || (( $2 < 1 || $2 > 65535 )); then
        echo "error: --gateway-port must be 1-65535 (got: $2)" >&2; exit 2
      fi
      PACK_ARG_GATEWAY_PORT="$2"; shift 2 ;;
    --start-gateway)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --start-gateway requires a value" >&2; exit 2; }
      case "$2" in
        true|false) ;;
        *) echo "error: --start-gateway must be true or false (got: $2)" >&2; exit 2 ;;
      esac
      PACK_ARG_START_GATEWAY="$2"; shift 2 ;;
    --kirocrew-home)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --kirocrew-home requires a value" >&2; exit 2; }
      PACK_ARG_KIROCREW_HOME="$2"; shift 2 ;;
    --model)
      # Bootstrap passes --model kiro-cloud to all packs. Accept and ignore.
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --model requires a value" >&2; exit 2; }
      if [[ "$2" != "kiro-cloud" ]]; then
        log "ignoring --model '$2' — Kiro CLI uses its own cloud inference (select via /model inside the CLI)"
      fi
      shift 2 ;;
    --)
      shift; break ;;
    -*)
      echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      echo "error: unexpected positional argument: $1" >&2; exit 2 ;;
  esac
done

REGION="${PACK_ARG_REGION}"
CHANNEL="${PACK_ARG_CHANNEL}"
KIROCREW_VERSION="${PACK_ARG_KIROCREW_VERSION}"
EXTRAS="${PACK_ARG_EXTRAS}"
GATEWAY_PORT="${PACK_ARG_GATEWAY_PORT}"
START_GATEWAY="${PACK_ARG_START_GATEWAY}"
KIROCREW_HOME_OVERRIDE="${PACK_ARG_KIROCREW_HOME}"

# ── Validation ────────────────────────────────────────────────────────────────
# Mutex: can't use both auth paths
if [[ -n "${PACK_ARG_API_KEY}" && -n "${PACK_ARG_FROM_SECRET}" ]]; then
  echo "error: --kiro-api-key and --from-secret are mutually exclusive" >&2
  exit 2
fi

# Channel validation
case "${CHANNEL}" in
  stable|nightly|insider) ;;
  *) echo "error: --channel must be stable, nightly, or insider (got: ${CHANNEL})" >&2; exit 2 ;;
esac

# Port and start-gateway already validated inline during arg parsing

# Warn about argv-leak for --kiro-api-key
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  warn "KIRO_API_KEY received via --kiro-api-key (argv). This value is"
  warn "likely visible in the invoking shell's history and was briefly in"
  warn "/proc/<pid>/cmdline. Consider rotating and switching to --from-secret."
fi

# Resolve --from-secret → KIRO_API_KEY
if [[ -n "${PACK_ARG_FROM_SECRET}" ]]; then
  log "Resolving Kiro API key from Secrets Manager: ${PACK_ARG_FROM_SECRET}"
  SECRET_JSON="$(aws secretsmanager get-secret-value \
        --secret-id "${PACK_ARG_FROM_SECRET}" \
        --region "${REGION}" \
        --output json 2>&1)" || {
    fail "failed to read secret ${PACK_ARG_FROM_SECRET} in ${REGION}. Check IAM perms and secret id. AWS said: ${SECRET_JSON}"
  }
  PACK_ARG_API_KEY="$(printf '%s' "${SECRET_JSON}" | jq -r 'if (.SecretString // "") == "" then empty else .SecretString end')"
  if [[ -z "${PACK_ARG_API_KEY}" ]]; then
    fail "secret ${PACK_ARG_FROM_SECRET} has no SecretString payload (binary secret? empty value?). Refusing to proceed."
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Kiro CLI Base
# ══════════════════════════════════════════════════════════════════════════════

pack_banner "kirocrew"
log "region=${REGION} channel=${CHANNEL} extras=${EXTRAS} port=${GATEWAY_PORT} start-gateway=${START_GATEWAY}"
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  log "auth mode: headless (KIRO_API_KEY will be configured)"
else
  log "auth mode: interactive (run 'kiro-cli login --use-device-flow' after install)"
fi

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl python3
if [[ -n "${PACK_ARG_FROM_SECRET}" ]]; then
  require_cmd jq
fi

# ── Step 2: Install Kiro CLI ──────────────────────────────────────────────────
step "Installing Kiro CLI via upstream installer (stable channel → latest)"

if command -v kiro-cli &>/dev/null; then
  KIROCLI_EXISTING="$(kiro-cli --version 2>/dev/null || echo unknown)"
  log "kiro-cli already installed (${KIROCLI_EXISTING}) — reinstalling"
fi

curl -fsSL https://cli.kiro.dev/install -o /tmp/install-kiro-cli.sh

# Run as ec2-user if we're root; otherwise run as current user.
# Use -H so HOME is set to /home/ec2-user; the upstream kiro-cli installer
# does mkdir "$HOME/.agents" and would create /.agents with empty HOME.
if [[ "$(id -u)" == "0" ]] && id ec2-user &>/dev/null; then
  sudo -H -u ec2-user bash /tmp/install-kiro-cli.sh
else
  # We're already ec2-user (via bootstrap.sh's sudo -u). Ensure HOME is set
  # so nested "mkdir $HOME/..." calls in kiro-cli installer don't collapse to /.
  HOME="${HOME:-/home/ec2-user}" bash /tmp/install-kiro-cli.sh
fi
rm -f /tmp/install-kiro-cli.sh

# Refresh PATH for current session
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

if ! command -v kiro-cli &>/dev/null; then
  fail "kiro-cli command not found after install. Check PATH or installer output."
fi

KIROCLI_VERSION="$(kiro-cli --version 2>/dev/null || echo unknown)"
ok "Kiro CLI installed: ${KIROCLI_VERSION}"

# Version check — warn on v1 or v3+ (this pack targets v2)
KIROCLI_MAJOR="$(printf '%s' "${KIROCLI_VERSION}" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
if [[ -n "${KIROCLI_MAJOR}" ]]; then
  if (( KIROCLI_MAJOR < 2 )); then
    warn "Kiro CLI v${KIROCLI_MAJOR} detected — this pack is designed for v2+. Headless mode may not work."
  elif (( KIROCLI_MAJOR > 2 )); then
    warn "Kiro CLI v${KIROCLI_MAJOR} detected — this pack has been tested against v2. Auth/env semantics may have changed."
  fi
fi

# ── Step 3: MCP server prerequisites ─────────────────────────────────────────
step "Installing MCP server prerequisites (uv + build tools)"

# Install build tools for MCP servers with C extensions
log "Installing build tools for MCP servers..."
if command -v dnf &>/dev/null; then
  sudo dnf install -y -q gcc python3-devel 2>/dev/null || warn "Failed to install build tools (gcc, python3-devel)"
fi

# Install uv (fast Python package manager) if not present
if ! command -v uv &>/dev/null; then
  log "Installing uv (Python package manager)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
fi

if command -v uv &>/dev/null; then
  ok "uv available: $(uv --version 2>/dev/null || echo unknown)"
else
  warn "uv not found after install — MCP servers may not install correctly"
fi

# Install uvenv (MCP server installer used by AWS samples)
if ! command -v uvenv &>/dev/null; then
  log "Installing uvenv..."
  pip3 install uvenv 2>/dev/null || warn "pip3 install uvenv failed"
fi

if command -v uvenv &>/dev/null; then
  ok "uvenv available"
else
  warn "uvenv not found — will skip MCP server installs"
fi

# ── Step 4: Configure AWS MCP proxy ──────────────────────────────────────────
step "Configuring AWS MCP proxy"
install_aws_mcp_proxy "${REGION}" "${HOME}/.kiro/settings/mcp.json"

# ── Step 5: Wire up KIRO_API_KEY if provided ─────────────────────────────────
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  step "Configuring KIRO_API_KEY for headless mode"

  KIRO_USER="${KIRO_USER:-ec2-user}"
  KIRO_USER_HOME="$(getent passwd "${KIRO_USER}" | cut -d: -f6 2>/dev/null || echo "/home/${KIRO_USER}")"
  KIRO_ENV_FILE="${KIRO_USER_HOME}/.kiro/env"

  ( umask 077
    mkdir -p "$(dirname "${KIRO_ENV_FILE}")"
    printf 'export KIRO_API_KEY=%q\n' "${PACK_ARG_API_KEY}" > "${KIRO_ENV_FILE}"
  )
  chmod 600 "${KIRO_ENV_FILE}"
  chown -R "${KIRO_USER}:${KIRO_USER}" "$(dirname "${KIRO_ENV_FILE}")" 2>/dev/null || true

  # Source from .bash_profile (idempotent)
  KIRO_PROFILE="${KIRO_USER_HOME}/.bash_profile"
  KIRO_SRC_MARKER='# lowkey-kirocrew-env-source'
  KIRO_SRC_LINE='[[ -f ~/.kiro/env ]] && source ~/.kiro/env'
  if ! grep -qxF "${KIRO_SRC_MARKER}" "${KIRO_PROFILE}" 2>/dev/null; then
    {
      echo ""
      echo "${KIRO_SRC_MARKER}"
      echo "# Load KIRO_API_KEY (headless mode) — managed by lowkey kirocrew pack"
      echo "${KIRO_SRC_LINE}"
    } >> "${KIRO_PROFILE}"
    chown "${KIRO_USER}:${KIRO_USER}" "${KIRO_PROFILE}" 2>/dev/null || true
  fi

  ok "KIRO_API_KEY written to ${KIRO_ENV_FILE} (0600) and sourced from ~/.bash_profile"

  # Also write to ~/.kiro/crew/.env — kirocrew reads this file directly
  # and does NOT pick up KIRO_API_KEY from the shell environment.
  # See: https://kiro.dev/docs/crew/configuration/
  KIROCREW_ENV_DIR="${KIROCREW_HOME_OVERRIDE:-${KIRO_USER_HOME}/.kiro/crew}"
  KIROCREW_ENV_FILE="${KIROCREW_ENV_DIR}/.env"
  ( umask 077
    mkdir -p "${KIROCREW_ENV_DIR}"
    # Idempotent: remove old entry before appending
    if [[ -f "${KIROCREW_ENV_FILE}" ]]; then
      grep -v '^KIRO_API_KEY=' "${KIROCREW_ENV_FILE}" > "${KIROCREW_ENV_FILE}.tmp" 2>/dev/null || true
      mv "${KIROCREW_ENV_FILE}.tmp" "${KIROCREW_ENV_FILE}"
    fi
    printf 'KIRO_API_KEY=%s\n' "${PACK_ARG_API_KEY}" >> "${KIROCREW_ENV_FILE}"
  )
  chmod 600 "${KIROCREW_ENV_FILE}"
  chown -R "${KIRO_USER}:${KIRO_USER}" "${KIROCREW_ENV_DIR}" 2>/dev/null || true
  ok "KIRO_API_KEY also written to ${KIROCREW_ENV_FILE} (kirocrew native .env)"
fi

# ── Step 6: Install skills ────────────────────────────────────────────────────
step "Installing agent skills"
PACK_SKILLS_DIR="${HOME}/.kiro/skills"
if ensure_skills_clone "${PACK_SKILLS_DIR}"; then
  ok "loki-skills installed to ${PACK_SKILLS_DIR}"
else
  warn "loki-skills clone failed (optional)"
fi
install_aws_toolkit_skills "${PACK_SKILLS_DIR}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: KiroCrew Layer
# ══════════════════════════════════════════════════════════════════════════════

# ── Step 7: Ensure Python ≥ 3.10 ─────────────────────────────────────────────
step "Ensuring Python ≥ 3.10 for KiroCrew"

KIROCREW_PY=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "${candidate}" &>/dev/null; then
    if "${candidate}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      KIROCREW_PY="${candidate}"
      break
    fi
  fi
done

# On AL2023, if no ≥3.10 found, try installing python3.11
if [[ -z "${KIROCREW_PY}" ]] && command -v dnf &>/dev/null; then
  log "No Python ≥3.10 found; installing python3.11 via dnf..."
  sudo dnf install -y -q python3.11 2>/dev/null || true
  if command -v python3.11 &>/dev/null; then
    KIROCREW_PY="python3.11"
  fi
fi

if [[ -z "${KIROCREW_PY}" ]]; then
  fail "Python ≥3.10 is required for KiroCrew. On Amazon Linux: sudo dnf install python3.11"
fi
ok "Python for KiroCrew: ${KIROCREW_PY} ($(${KIROCREW_PY} --version 2>&1))"

# ── Step 8: Install pipx ─────────────────────────────────────────────────────
step "Ensuring pipx is available"

if ! command -v pipx &>/dev/null; then
  log "Installing pipx using ${KIROCREW_PY}..."
  "${KIROCREW_PY}" -m pip install --user pipx 2>/dev/null || true
  export PATH="${HOME}/.local/bin:${PATH}"
fi

# Verify pipx uses the correct Python (>=3.10), not system 3.9
if command -v pipx &>/dev/null; then
  PIPX_PY_VERSION="$(pipx --version 2>/dev/null && python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || echo "")"
  # If pipx is linked to a Python < 3.10, reinstall under the correct interpreter
  if pipx environment 2>/dev/null | grep -q "python3.9\|Python 3.9"; then
    log "pipx is running under Python 3.9 — reinstalling under ${KIROCREW_PY}"
    "${KIROCREW_PY}" -m pip install --user --force-reinstall pipx 2>/dev/null || true
  fi
  ok "pipx available: $(pipx --version 2>/dev/null || echo unknown)"
else
  log "pipx not available — upstream installer will use managed venv instead"
fi

# ── Step 9: Run upstream KiroCrew installer ───────────────────────────────────
step "Installing KiroCrew (channel: ${CHANNEL})"

KIROCREW_INSTALLER_URL="https://download.crew.kiro.dev/cli.sh"

# Build installer args as array (safe against word-splitting / glob expansion)
KIROCREW_INSTALLER_ARGS=(--channel "${CHANNEL}")
if [[ -n "${KIROCREW_VERSION}" ]]; then
  KIROCREW_INSTALLER_ARGS+=(--version "${KIROCREW_VERSION}")
fi

# Set KIROCREW_HOME if overridden
if [[ -n "${KIROCREW_HOME_OVERRIDE}" ]]; then
  export KIROCREW_HOME="${KIROCREW_HOME_OVERRIDE}"
fi

# Ensure the correct Python is first in PATH for the upstream installer
# The upstream cli.sh uses `python3` — if system python3 is 3.9 but we have 3.11+
# available, we need to make sure the right one is found first.
if [[ "${KIROCREW_PY}" != "python3" ]]; then
  KIROCREW_PY_PATH="$(command -v "${KIROCREW_PY}")"
  KIROCREW_PY_DIR="$(dirname "${KIROCREW_PY_PATH}")"
  # Create a temporary symlink so the upstream installer's `python3` resolves correctly
  mkdir -p /tmp/kirocrew-pybin
  ln -sf "${KIROCREW_PY_PATH}" /tmp/kirocrew-pybin/python3
  export PATH="/tmp/kirocrew-pybin:${PATH}"
  log "Prepended ${KIROCREW_PY} as python3 in PATH for upstream installer"
fi

log "Running: curl -fsSL ${KIROCREW_INSTALLER_URL} | sh -s -- ${KIROCREW_INSTALLER_ARGS[*]}"

# Download to temp file first (avoid truncated-script execution on network failure)
curl -fsSL "${KIROCREW_INSTALLER_URL}" -o /tmp/install-kirocrew.sh || {
  fail "Failed to download KiroCrew installer. Possible causes:
  - Network: check DNS/proxy/firewall for download.crew.kiro.dev
  - CDN: the installer URL may be temporarily unavailable"
}

if ! sh /tmp/install-kirocrew.sh "${KIROCREW_INSTALLER_ARGS[@]}"; then
  rm -f /tmp/install-kirocrew.sh
  fail "KiroCrew installer failed. Possible causes:
  - Python: ensure ${KIROCREW_PY} is ≥3.10
  - OpenSSL: required for signature verification
  - Channel: '${CHANNEL}' may not have a published release yet"
fi
rm -f /tmp/install-kirocrew.sh

# Refresh PATH
export PATH="${HOME}/.local/bin:${PATH}"

# ── Step 10: Verify kirocrew binary ──────────────────────────────────────────
step "Verifying KiroCrew installation"

if ! command -v kirocrew &>/dev/null; then
  fail "kirocrew command not found after install. Check PATH (~/.local/bin should be included)."
fi

KIROCREW_INSTALLED_VERSION="$(kirocrew --version 2>/dev/null || echo unknown)"
ok "KiroCrew installed: ${KIROCREW_INSTALLED_VERSION}"

# ── Step 11: Install pip extras ──────────────────────────────────────────────
if [[ -n "${EXTRAS}" ]]; then
  step "Installing pip extras: ${EXTRAS}"

  # Map extras to pip install specifiers
  # pipx inject adds packages into kirocrew's existing venv
  IFS=',' read -ra EXTRA_LIST <<< "${EXTRAS}"

  # Determine install method: pipx or direct venv pip
  KIROCREW_BIN_PATH="$(command -v kirocrew)"
  KIROCREW_DATA_HOME="${KIROCREW_HOME:-${HOME}/.kiro/crew}"
  KIROCREW_VENV="${KIROCREW_DATA_HOME%/}-venv"

  if command -v pipx &>/dev/null && pipx list 2>/dev/null | grep -q "kirocrew"; then
    # Installed via pipx — use pipx inject
    for extra in "${EXTRA_LIST[@]}"; do
      extra="$(echo "${extra}" | xargs)"  # trim whitespace
      case "${extra}" in
        aws)
          log "pipx inject: boto3"
          pipx inject kirocrew boto3 2>/dev/null && ok "extra 'aws' installed" || warn "failed to inject boto3"
          ;;
        voice)
          log "pipx inject: boto3 amazon-transcribe"
          pipx inject kirocrew boto3 amazon-transcribe 2>/dev/null && ok "extra 'voice' installed" || warn "failed to inject voice extras"
          ;;
        *)
          warn "unknown extra '${extra}' — skipping (valid: aws, voice)"
          ;;
      esac
    done
  elif [[ -d "${KIROCREW_VENV}" && -f "${KIROCREW_VENV}/bin/pip" ]]; then
    # Installed via managed venv
    for extra in "${EXTRA_LIST[@]}"; do
      extra="$(echo "${extra}" | xargs)"
      case "${extra}" in
        aws)
          "${KIROCREW_VENV}/bin/pip" install --quiet boto3 && ok "extra 'aws' installed" || warn "failed to install boto3"
          ;;
        voice)
          "${KIROCREW_VENV}/bin/pip" install --quiet boto3 amazon-transcribe && ok "extra 'voice' installed" || warn "failed to install voice extras"
          ;;
        *)
          warn "unknown extra '${extra}' — skipping (valid: aws, voice)"
          ;;
      esac
    done
  else
    warn "Could not determine KiroCrew install path — skipping extras"
  fi
fi

# ── Step 12: kirocrew setup (TTY-gated) ──────────────────────────────────────
step "KiroCrew initial configuration"

if [[ -t 0 ]]; then
  log "TTY detected — running kirocrew setup (interactive wizard)"
  kirocrew setup || warn "kirocrew setup exited non-zero (may need manual config)"
else
  log "No TTY — skipping interactive setup"
  log "Run 'kirocrew setup' manually to complete configuration"
fi

# ── Step 13: kirocrew doctor (informational) ─────────────────────────────────
step "Running kirocrew doctor (informational)"

kirocrew doctor 2>&1 | while IFS= read -r line; do log "  doctor: ${line}"; done || true
ok "kirocrew doctor completed (warnings above are non-fatal; embedding model downloads on first gateway start)"

# ── Step 14: Preload embedding model ─────────────────────────────────────────
step "Preloading embedding model (~610 MB)"

KIROCREW_DATA_HOME="${KIROCREW_HOME:-${HOME}/.kiro/crew}"
KIROCREW_MODELS_DIR="${KIROCREW_DATA_HOME}/models"
mkdir -p "${KIROCREW_MODELS_DIR}"

# Approach A: Try dedicated download command (if kirocrew supports it)
if kirocrew gateway --help 2>/dev/null | grep -q "download-model"; then
  log "Using kirocrew gateway --download-model-only"
  if kirocrew gateway --download-model-only 2>&1 | while IFS= read -r line; do log "  model: ${line}"; done; then
    ok "Embedding model preloaded via --download-model-only"
  else
    warn "--download-model-only failed; will try alternative approach"
  fi
# Approach C: Direct download using KIROCREW_EMBED_MODEL_URL if discoverable
elif kirocrew --help 2>/dev/null | grep -qi "embed"; then
  log "Attempting model preload via kirocrew embed/model subcommand..."
  kirocrew model download 2>/dev/null || kirocrew embed download 2>/dev/null || true
else
  # Fallback: start gateway briefly to trigger download, then stop
  log "No dedicated download command found — starting gateway briefly to trigger model download"
  log "This may take 1-3 minutes depending on network speed..."

  # Use a temporary port to avoid conflict with the systemd service later
  # Cap at 65534 to avoid overflow (port+1 could exceed 65535)
  if (( GATEWAY_PORT >= 65535 )); then
    PRELOAD_PORT=9999
  else
    PRELOAD_PORT=$((GATEWAY_PORT + 1))
  fi
  KIROCREW_PORT="${PRELOAD_PORT}" timeout 300 kirocrew gateway &
  PRELOAD_PID=$!

  # Wait for model file to appear and reach minimum size (500 MB = 524288000 bytes)
  PRELOAD_TIMEOUT=300
  PRELOAD_ELAPSED=0
  MODEL_READY=false
  while (( PRELOAD_ELAPSED < PRELOAD_TIMEOUT )); do
    # Check if any model file > 500MB exists
    if find "${KIROCREW_MODELS_DIR}" -type f -size +500M 2>/dev/null | grep -q .; then
      MODEL_READY=true
      break
    fi
    # Check if gateway process died
    if ! kill -0 "${PRELOAD_PID}" 2>/dev/null; then
      warn "Gateway process exited during model preload"
      break
    fi
    sleep 5
    PRELOAD_ELAPSED=$((PRELOAD_ELAPSED + 5))
  done

  # Stop the temporary gateway
  kill "${PRELOAD_PID}" 2>/dev/null || true
  wait "${PRELOAD_PID}" 2>/dev/null || true

  # Wait briefly for port to free
  sleep 2

  if [[ "${MODEL_READY}" == "true" ]]; then
    ok "Embedding model preloaded successfully"
  else
    warn "Embedding model preload timed out or failed — gateway will download on first real start"
  fi
fi

# Verify model exists (non-fatal)
if find "${KIROCREW_MODELS_DIR}" -type f -size +500M 2>/dev/null | grep -q .; then
  MODEL_SIZE="$(find "${KIROCREW_MODELS_DIR}" -type f -size +500M -exec du -sh {} + 2>/dev/null | head -1 | awk '{print $1}')"
  ok "Embedding model verified: ${MODEL_SIZE} in ${KIROCREW_MODELS_DIR}"
else
  warn "No embedding model found (>500MB) in ${KIROCREW_MODELS_DIR} — will download on first gateway start"
fi

# ── Step 15: Agent sandbox config (builder profile only) ────────────────────
# The builder profile needs unrestricted filesystem + credential access
# (AWS CLI, SSH keys, kiro-cli auth tokens). Write agent.sandbox=off to
# config.local.json (wins over config.json, survives upgrades) BEFORE the
# gateway starts so it takes effect on the first session spawn without a restart.
#
# Config key: agent.sandbox (loader.py:1352, enum=["auto","off"])
# Default is "auto" (user namespace sandbox enabled on Linux).
#
# Read profile from PACK_CONFIG (via pack_config_get). PROFILE_NAME env var
# is NOT forwarded through the sudo boundary in deploy/bootstrap.sh (only
# PACK_CONFIG is preserved), so the pack must go through pack_config_get.
KIROCREW_CFG_DIR="${KIROCREW_HOME:-${HOME}/.kiro/crew}"
if [[ "${PACK_ARG_PROFILE:-}" == "builder" ]]; then
  step "Configuring agent sandbox (builder profile — disabling namespace sandbox)"
  # KIRO_USER may not be set yet (step 5 only sets it inside the API-key branch).
  # Initialize with a safe default so chown below doesn't fail under set -u.
  KIRO_USER="${KIRO_USER:-ec2-user}"
  mkdir -p "${KIROCREW_CFG_DIR}"
  # Merge into config.local.json using jq so we don't clobber other local overrides
  local_cfg="${KIROCREW_CFG_DIR}/config.local.json"
  if [[ -f "${local_cfg}" ]]; then
    # File exists — merge agent.sandbox into it
    tmp_cfg="$(mktemp)"
    if jq '.agent.sandbox = "off"' "${local_cfg}" > "${tmp_cfg}" 2>/dev/null; then
      mv "${tmp_cfg}" "${local_cfg}"
    else
      rm -f "${tmp_cfg}"
      warn "jq merge failed; writing agent.sandbox=off directly to ${local_cfg}"
      printf '{"agent":{"sandbox":"off"}}\n' > "${local_cfg}"
    fi
  else
    printf '{"agent":{"sandbox":"off"}}\n' > "${local_cfg}"
  fi
  chown "${KIRO_USER}:${KIRO_USER}" "${local_cfg}" 2>/dev/null || true
  chmod 600 "${local_cfg}"
  ok "agent.sandbox=off written to ${local_cfg} (builder profile, upgrade-safe)"
fi

# ── Step 15b: Denied commands allow-list ─────────────────────────────────────
# KiroCrew ships an out-of-the-box denied-commands list that blocks certain
# shell commands (rm -rf, curl | sh, etc). For the lowkey deploy we disable
# that list wholesale — the agent is already sandboxed at the AWS/network
# layer (VPC, IAM, ALB origin-verify) and the builder profile deliberately
# turns off the process-level sandbox. The default deny-list gets in the way
# of legitimate builder work. Write BEFORE the gateway starts so the setting
# takes effect on the first session spawn.
step "Configuring denied_commands (disable_all=true)"
KIROCREW_DENIED_FILE="${KIROCREW_CFG_DIR}/denied_commands.json"
mkdir -p "${KIROCREW_CFG_DIR}"
KIRO_USER="${KIRO_USER:-ec2-user}"
printf '{\n  "disable_all": true\n}\n' > "${KIROCREW_DENIED_FILE}"
chown "${KIRO_USER}:${KIRO_USER}" "${KIROCREW_DENIED_FILE}" 2>/dev/null || true
chmod 600 "${KIROCREW_DENIED_FILE}"
ok "denied_commands.json written to ${KIROCREW_DENIED_FILE} (disable_all=true)"

# ── Step 16: Install systemd service ─────────────────────────────────────────
if [[ "${START_GATEWAY}" == "true" ]]; then
  step "Installing kirocrew-gateway systemd service"

  KIROCREW_BIN_PATH="$(command -v kirocrew)"
  KIROCREW_DATA_HOME="${KIROCREW_HOME:-${HOME}/.kiro/crew}"
  SERVICE_SRC="${SCRIPT_DIR}/resources/kirocrew-gateway.service"
  SERVICE_DST="/etc/systemd/system/kirocrew-gateway.service"

  if [[ ! -f "${SERVICE_SRC}" ]]; then
    warn "Service template not found: ${SERVICE_SRC} — skipping"
  else
    # Template the unit file
    sed -e "s|__PORT__|${GATEWAY_PORT}|g" \
        -e "s|__HOME__|${KIROCREW_DATA_HOME}|g" \
        -e "s|__BINPATH__|${KIROCREW_BIN_PATH}|g" \
        "${SERVICE_SRC}" > /tmp/kirocrew-gateway.service

    sudo cp /tmp/kirocrew-gateway.service "${SERVICE_DST}"
    rm -f /tmp/kirocrew-gateway.service
    sudo systemctl daemon-reload
    sudo systemctl enable kirocrew-gateway.service
    if sudo systemctl start kirocrew-gateway.service; then
      # Verify
      sleep 2
      if systemctl is-active --quiet kirocrew-gateway.service; then
        ok "kirocrew-gateway.service started on port ${GATEWAY_PORT}"
      else
        warn "kirocrew-gateway.service enabled but not active — check: journalctl -u kirocrew-gateway"
      fi
    else
      warn "kirocrew-gateway.service failed to start — check: journalctl -u kirocrew-gateway"
      warn "Service is enabled and will retry on next boot. Run 'kirocrew doctor' to diagnose."
    fi
  fi

  # Open firewall port for external access (ALB health checks, direct access)
  if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    sudo firewall-cmd --permanent --add-port="${GATEWAY_PORT}/tcp" 2>/dev/null || true
    sudo firewall-cmd --reload 2>/dev/null || true
    ok "Firewall port ${GATEWAY_PORT}/tcp opened"
  fi
fi

# ── Shell profile ─────────────────────────────────────────────────────────────
step "Installing shell profile"
SHELL_PROFILE="${SCRIPT_DIR}/resources/shell-profile.sh"
if [[ -f "${SHELL_PROFILE}" && -d /etc/profile.d ]]; then
  sudo cp "${SHELL_PROFILE}" /etc/profile.d/kirocrew.sh 2>/dev/null && \
    ok "Shell profile installed: /etc/profile.d/kirocrew.sh" || \
    warn "Could not install shell profile (permission denied?)"
fi

# ── Post-install notice ───────────────────────────────────────────────────────
step "Post-install notice"

# Resolve public IP via EC2 IMDS for the gateway URL
KIROCREW_PUBLIC_IP="$(curl -sf --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")"
if [[ -z "${KIROCREW_PUBLIC_IP}" ]]; then
  # Try IMDSv2
  IMDS_TOKEN="$(curl -sf --connect-timeout 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 30' http://169.254.169.254/latest/api/token 2>/dev/null || echo "")"
  if [[ -n "${IMDS_TOKEN}" ]]; then
    KIROCREW_PUBLIC_IP="$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")"
  fi
fi
KIROCREW_HOST="${KIROCREW_PUBLIC_IP:-<this-host>}"

# Generate a dashboard login token (non-fatal if kirocrew isn't fully configured yet)
KIROCREW_DASH_TOKEN=""
if command -v kirocrew &>/dev/null; then
  KIROCREW_DASH_TOKEN="$(kirocrew token --ttl 24h 2>/dev/null || echo "")" 
fi

KIROCREW_URL="http://${KIROCREW_HOST}:${GATEWAY_PORT}"

if [[ "${START_GATEWAY}" == "true" ]]; then
  cat <<NOTICE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIROCREW] GATEWAY RUNNING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Dashboard: ${KIROCREW_URL}
NOTICE

  if [[ -n "${KIROCREW_DASH_TOKEN}" ]]; then
    cat <<NOTICE
  Login:     ${KIROCREW_URL}/?token=${KIROCREW_DASH_TOKEN}
             (valid for 24 hours)
NOTICE
  fi

  cat <<NOTICE

  Commands:
    kirocrew doctor              → Verify setup
    kirocrew setup               → Reconfigure
    kirocrew token --ttl 2h      → Generate new login token\n    systemctl status kirocrew-gateway  → Service status
    journalctl -u kirocrew-gateway -f  → Logs

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTICE
else
  cat <<NOTICE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIROCREW] INSTALLED — start manually
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  kirocrew gateway               → Start server (port ${GATEWAY_PORT})
  kirocrew doctor                → Verify setup
  kirocrew setup                 → Interactive config wizard
  kirocrew token --ttl 2h        → Generate login token

  Access: ${KIROCREW_URL} (after starting gateway)

  To enable as service:
    sudo systemctl enable --now kirocrew-gateway.service

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTICE
fi

if [[ -z "${PACK_ARG_API_KEY}" ]]; then
  echo ""
  echo "  ⚠  kiro-cli authentication required:"
  echo "     kiro-cli login --use-device-flow"
  echo "     OR use kiro-cli --no-interactive with KIRO_API_KEY set"
  echo ""
fi

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "kirocrew"
if [[ "${START_GATEWAY}" == "true" ]]; then
  printf "\n[PACK:kirocrew] INSTALLED — %s, gateway running on port %s\n" "${KIROCREW_INSTALLED_VERSION}" "${GATEWAY_PORT}"
else
  printf "\n[PACK:kirocrew] INSTALLED — %s, start with 'kirocrew gateway'\n" "${KIROCREW_INSTALLED_VERSION}"
fi
