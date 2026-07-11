#!/usr/bin/env bash
# packs/kiro-cli/install.sh — Install Kiro CLI (AWS agentic IDE terminal client)
#
# Usage:
#   ./install.sh [--region us-east-1]
#                [--from-secret SECRET_ID_OR_ARN]
#
# Kiro CLI v2 supports two auth modes:
#   1. Headless (no browser): set KIRO_API_KEY env var. This pack can
#      resolve a Secrets Manager secret for you via --from-secret.
#      Get a key at https://app.kiro.dev (account settings).
#   2. Interactive (browser-based SSO):
#      kiro-cli login --use-device-flow
#
# We deliberately do NOT document a --kiro-api-key flag that takes the
# key inline on argv — that leaks to shell history and /proc/<pid>/cmdline.
# Use --from-secret (preferred) or set KIRO_API_KEY in ~/.kiro/env yourself.
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_FROM_SECRET="$(pack_config_get from-secret "")"
# Hidden legacy flag: accepted but discouraged (argv-leak risk).
PACK_ARG_API_KEY="$(pack_config_get kiro-api-key "")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Kiro CLI v2 — AWS agentic IDE terminal client with MCP server support.

Kiro CLI v2 can run in two modes:

  1. Headless (non-interactive, no browser) — uses KIRO_API_KEY env var
  2. Interactive (browser-based SSO)        — uses 'kiro-cli login --use-device-flow'

Options:
  --region         AWS region (informational only; Kiro uses its own inference)
                   (default: us-east-1)
  --from-secret    AWS Secrets Manager secret id/arn whose SecretString is the
                   Kiro API key. The pack writes it to ~/.kiro/env (0600) so
                   Kiro CLI picks it up automatically. Preferred for automation.
  --help           Show this help message

Post-install authentication:
  Without API key:  kiro-cli login --use-device-flow   # browser SSO
  With API key:     already wired up — just run 'kiro-cli'

Examples:
  ./install.sh
  ./install.sh --region eu-west-1
  ./install.sh --from-secret faststart/kiro-api-key

SECURITY NOTE:
  Don't pass raw API keys on the command line. Store your key in AWS
  Secrets Manager and pass --from-secret SECRET_ID. If a key does end
  up on argv (e.g. via the hidden --kiro-api-key flag, still accepted
  for back-compat), this script warns about the leak path.
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
      # Hidden legacy flag. Accept but warn: passing secrets on argv leaks
      # them into shell history and /proc/<pid>/cmdline. Prefer --from-secret.
      [[ $# -ge 2 ]] || { echo "error: --kiro-api-key requires a value" >&2; exit 2; }
      # Refuse values that look like another flag — catches typos like
      # '--kiro-api-key --from-secret foo' which would otherwise set the
      # key to the literal string '--from-secret'.
      case "$2" in -*) echo "error: --kiro-api-key value must not start with '-' (got: $2)" >&2; exit 2 ;; esac
      PACK_ARG_API_KEY="$2"; shift 2 ;;
    --from-secret)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --from-secret requires a value" >&2; exit 2; }
      PACK_ARG_FROM_SECRET="$2"; shift 2 ;;
    --model)
      # Kiro CLI uses its own cloud inference — models are selected inside
      # the CLI via /model. Any --model passed in from the generic bootstrap
      # path is safely ignored. 'kiro-cloud' is the sentinel from install.sh
      # for clarity; real model ids are tolerated with an informational log.
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

# Mutex: can't use both auth paths — treat as bad-args (exit 2) to match
# the style of the rest of the parser.
if [[ -n "${PACK_ARG_API_KEY}" && -n "${PACK_ARG_FROM_SECRET}" ]]; then
  echo "error: --kiro-api-key and --from-secret are mutually exclusive" >&2
  exit 2
fi

# Warn when a secret came in via argv — there's nothing we can do about
# the leak that already happened, but the operator should know and rotate.
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  warn "KIRO_API_KEY received via --kiro-api-key (argv). This value is"
  warn "likely visible in the invoking shell's history and was briefly in"
  warn "/proc/<pid>/cmdline. Consider rotating and switching to --from-secret."
fi

# Resolve --from-secret → KIRO_API_KEY
if [[ -n "${PACK_ARG_FROM_SECRET}" ]]; then
  log "Resolving Kiro API key from Secrets Manager: ${PACK_ARG_FROM_SECRET}"
  # Use JSON output rather than --output text: an empty SecretString with
  # --output text returns the literal string 'None', which would pass a
  # naive non-empty check and get written as the "key".
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

pack_banner "kiro-cli"
log "region=${REGION} (informational — Kiro CLI uses its own cloud inference)"
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  log "auth mode: headless (KIRO_API_KEY will be configured)"
else
  log "auth mode: interactive (run 'kiro-cli login --use-device-flow' after install)"
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl python3
# jq is needed for --from-secret path but not for interactive mode.
if [[ -n "${PACK_ARG_FROM_SECRET}" ]]; then
  require_cmd jq
fi

# ── Step 1: Install Kiro CLI ──────────────────────────────────────────────────
step "Installing Kiro CLI via upstream installer (stable channel → latest)"

if command -v kiro-cli &>/dev/null; then
  KIROCLI_EXISTING="$(kiro-cli --version 2>/dev/null || echo unknown)"
  log "kiro-cli already installed (${KIROCLI_EXISTING}) — reinstalling"
fi

curl -fsSL https://cli.kiro.dev/install -o /tmp/install-kiro-cli.sh
sudo -u ec2-user bash /tmp/install-kiro-cli.sh
rm -f /tmp/install-kiro-cli.sh

# Refresh PATH for current session
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

if ! command -v kiro-cli &>/dev/null; then
  fail "kiro-cli command not found after install. Check PATH or installer output."
fi

KIROCLI_VERSION="$(kiro-cli --version 2>/dev/null || echo unknown)"
ok "Kiro CLI installed: ${KIROCLI_VERSION}"

# Verify v2+ (required for --no-interactive / KIRO_API_KEY headless mode).
# Version strings look like: "kiro-cli 2.0.0" — tolerate any whitespace/prefix.
# Warn explicitly on both too-old and too-new: this pack is tested against v2.
KIROCLI_MAJOR="$(printf '%s' "${KIROCLI_VERSION}" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)"
if [[ -n "${KIROCLI_MAJOR}" ]]; then
  if (( KIROCLI_MAJOR < 2 )); then
    warn "Kiro CLI v${KIROCLI_MAJOR} detected — this pack is designed for v2+. Headless mode may not work."
  elif (( KIROCLI_MAJOR > 2 )); then
    warn "Kiro CLI v${KIROCLI_MAJOR} detected — this pack has been tested against v2. Auth/env semantics may have changed; verify before trusting in production."
  fi
fi

# ── Step 2: Install MCP server prerequisites ──────────────────────────────────
step "Installing MCP server prerequisites (uv + uvenv + build tools)"

# Install build tools for MCP servers with C extensions (matches AWS sample repo)
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

# ── Step 3: Configure AWS MCP proxy (mcp-proxy-for-aws) ───────────────────────
# mcp-proxy-for-aws is the official AWS successor to individual awslabs.*
# MCP servers — one endpoint covers all 300+ AWS services with IAM audit logging.
# Pinned version for reproducibility; check https://pypi.org/project/mcp-proxy-for-aws/
step "Configuring AWS MCP proxy"
install_aws_mcp_proxy "${REGION}" "${HOME}/.kiro/settings/mcp.json"

# ── Step 4: Wire up KIRO_API_KEY if provided ─────────────────────────────────
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  step "Configuring KIRO_API_KEY for headless mode"

  # Target user is always ec2-user on our AMIs
  KIRO_USER="${KIRO_USER:-ec2-user}"
  KIRO_USER_HOME="$(getent passwd "${KIRO_USER}" | cut -d: -f6 2>/dev/null || echo "/home/${KIRO_USER}")"
  KIRO_ENV_FILE="${KIRO_USER_HOME}/.kiro/env"

  # Create with restrictive umask so the intermediate directory never
  # briefly exposes the key path as world-readable before chmod runs.
  ( umask 077
    mkdir -p "$(dirname "${KIRO_ENV_FILE}")"
    # Write key to a dedicated env file. Use %q so shell metachars, newlines,
    # quotes etc. in the key cannot break the source step.
    printf 'export KIRO_API_KEY=%q\n' "${PACK_ARG_API_KEY}" > "${KIRO_ENV_FILE}"
  )
  chmod 600 "${KIRO_ENV_FILE}"
  chown -R "${KIRO_USER}:${KIRO_USER}" "$(dirname "${KIRO_ENV_FILE}")" 2>/dev/null || true

  # Source it from ec2-user's .bash_profile so interactive + SSM-shell
  # sessions both see it. Idempotent: only appended once, matched by an
  # exact marker comment + source line so re-runs don't stack duplicates.
  KIRO_PROFILE="${KIRO_USER_HOME}/.bash_profile"
  KIRO_SRC_MARKER='# lowkey-kiro-cli-env-source'
  KIRO_SRC_LINE='[[ -f ~/.kiro/env ]] && source ~/.kiro/env'
  if ! grep -qxF "${KIRO_SRC_MARKER}" "${KIRO_PROFILE}" 2>/dev/null; then
    {
      echo ""
      echo "${KIRO_SRC_MARKER}"
      echo "# Load KIRO_API_KEY (headless mode) — managed by lowkey kiro-cli pack"
      echo "${KIRO_SRC_LINE}"
    } >> "${KIRO_PROFILE}"
    chown "${KIRO_USER}:${KIRO_USER}" "${KIRO_PROFILE}" 2>/dev/null || true
  fi

  ok "KIRO_API_KEY written to ${KIRO_ENV_FILE} (0600) and sourced from ~/.bash_profile"
fi

# ── Step 5: Post-install instructions ────────────────────────────────────────
step "Post-install notice"

if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  cat <<'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIRO CLI v2] HEADLESS MODE READY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  KIRO_API_KEY is configured — no interactive login required.
  Kiro CLI will auto-auth on startup.

  Usage:
    kiro-cli                               # Interactive TUI
    kiro-cli --no-interactive "prompt"     # Headless one-shot (CI-friendly)
    kiro-cli --agent platform-engineer     # Start with specific agent
    /model                                 # Select model (inside CLI)
    /tools                                 # List MCP tools (inside CLI)

  Key storage: ~/.kiro/env (0600, ec2-user:ec2-user)
  Rotate via:  re-run the pack with --from-secret /your/secret
               OR edit ~/.kiro/env manually

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTICE
else
  cat <<'NOTICE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [KIRO CLI v2] AUTHENTICATION REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Choose one of the following:

  ─ INTERACTIVE (browser SSO) ─
    kiro-cli login --use-device-flow
      → prints a device code + URL; enter the code in your browser.

  ─ HEADLESS (no browser) ─
    Get an API key from https://app.kiro.dev (account settings),
    store it in AWS Secrets Manager, then re-run this pack with
    --from-secret /path/in/secrets-manager.

    To set it manually without re-running the pack:
      mkdir -p ~/.kiro && chmod 700 ~/.kiro
      ( umask 077; printf 'export KIRO_API_KEY=%q\n' "<key>" > ~/.kiro/env )
      echo '[[ -f ~/.kiro/env ]] && source ~/.kiro/env' >> ~/.bash_profile

  Usage after auth:
    kiro-cli                              # Interactive TUI
    kiro-cli --no-interactive "prompt"    # One-shot, prints to stdout
    kiro-cli --agent platform-engineer    # Specific agent
    /model                                # Select model (inside CLI)
    /tools                                # List MCP tools (inside CLI)

  MCP server config: ~/.kiro/agents/*.json

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTICE
fi

# Install shell profile (aliases + banner). The shipped profile no longer
# hardcodes "interactive login required" — it branches on whether
# ~/.kiro/env exists so the banner matches the actual auth mode.
SHELL_PROFILE="${SCRIPT_DIR}/resources/shell-profile.sh"
if [[ -f "${SHELL_PROFILE}" && -d /etc/profile.d ]]; then
  sudo cp "${SHELL_PROFILE}" /etc/profile.d/kiro-cli.sh 2>/dev/null && \
    ok "Shell profile installed: /etc/profile.d/kiro-cli.sh" || \
    warn "Could not install shell profile (permission denied?)"
fi

# ── Install loki-skills + AWS Agent Toolkit skills ────────────────────────────
# Toolkit skills overwrite duplicates (toolkit is preferred — newer + evaluated).
PACK_SKILLS_DIR="${HOME}/.kiro/skills"
if ensure_skills_clone "${PACK_SKILLS_DIR}"; then
  ok "loki-skills installed to ${PACK_SKILLS_DIR}"
else
  warn "loki-skills clone failed (optional)"
fi
install_aws_toolkit_skills "${PACK_SKILLS_DIR}"

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "kiro-cli"
if [[ -n "${PACK_ARG_API_KEY}" ]]; then
  printf "\n[PACK:kiro-cli] INSTALLED — %s, headless mode READY (KIRO_API_KEY set)\n" "${KIROCLI_VERSION}"
else
  printf "\n[PACK:kiro-cli] INSTALLED — %s, run 'kiro-cli login --use-device-flow' to authenticate\n" "${KIROCLI_VERSION}"
fi
