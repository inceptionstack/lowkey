#!/usr/bin/env bash
# packs/claude-code/install.sh — Install Claude Code and configure it for AWS Bedrock
#
# Usage:
#   ./install.sh [--region us-east-1] [--model us.anthropic.claude-sonnet-4-6] \
#                [--haiku-model us.anthropic.claude-haiku-4-5-20251001-v1:0] \
#                [--version 2.1.197|stable|latest] [--skip-smoke-test]
#
# Assumes:
#   - curl, aws, python3 are available
#   - EC2 instance has an IAM role with bedrock:InvokeModel permissions
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
# Pin to tested version for stability — update deliberately.
# Installer accepts stable|latest|X.Y.Z (verified against claude.ai/install.sh).
CLAUDE_CODE_VERSION_DEFAULT="2.1.197"
PACK_ARG_VERSION="$(pack_config_get version "${CLAUDE_CODE_VERSION_DEFAULT}")"
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6")"
PACK_ARG_HAIKU_MODEL="$(pack_config_get "haiku-model" "us.anthropic.claude-haiku-4-5-20251001-v1:0")"
SKIP_SMOKE_TEST=0

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install Claude Code and configure it to use AWS Bedrock natively.

Options:
  --region          AWS region for Bedrock                         (default: us-east-1)
  --model           Bedrock model ID (ANTHROPIC_MODEL)             (default: us.anthropic.claude-sonnet-4-6)
  --haiku-model     Bedrock model ID for Haiku fast-path           (default: us.anthropic.claude-haiku-4-5-20251001-v1:0)
  --version         Claude Code version to install: X.Y.Z|stable|latest (default: pinned)
  --skip-smoke-test Skip the live Bedrock invocation check
  --help            Show this help message

Note: Claude Code is a CLI tool only — no systemd service is created.
      Claude Code talks to Bedrock directly via CLAUDE_CODE_USE_BEDROCK=1.
      No bedrockify dependency required.

Examples:
  ./install.sh --region us-east-1
  ./install.sh --model us.anthropic.claude-sonnet-4-6 --region eu-west-1
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)         usage; exit 0 ;;
    --region)          PACK_ARG_REGION="$2";       shift 2 ;;
    --model)           PACK_ARG_MODEL="$2";         shift 2 ;;
    --haiku-model)     PACK_ARG_HAIKU_MODEL="$2";   shift 2 ;;
    --version)         PACK_ARG_VERSION="$2";       shift 2 ;;
    --skip-smoke-test) SKIP_SMOKE_TEST=1;           shift ;;
    *)
      # Framework may pass shared args — tolerate but log.
      log "Ignoring unrecognized argument: $1"
      [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"
HAIKU_MODEL="${PACK_ARG_HAIKU_MODEL}"
CC_VERSION="${PACK_ARG_VERSION}"

pack_banner "claude-code"
log "version=${CC_VERSION} region=${REGION} model=${MODEL} haiku-model=${HAIKU_MODEL}"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd curl aws python3

# Verify AWS credentials are available (instance profile or env vars)
if ! aws sts get-caller-identity --region "${REGION}" &>/dev/null; then
  fail "AWS credentials not available. Ensure the EC2 instance has an IAM role with Bedrock permissions."
fi
ok "AWS credentials verified (IAM role or env)"

# ── Install Claude Code ───────────────────────────────────────────────────────
step "Installing Claude Code"

if command -v claude &>/dev/null; then
  CLAUDE_EXISTING="$(claude --version 2>/dev/null || echo unknown)"
  log "claude already installed (${CLAUDE_EXISTING}) — reinstalling"
fi

# Use the official Claude Code native installer with a pinned version.
# Download first, then execute — avoids partial-download execution race.
curl -fsSL https://claude.ai/install.sh -o /tmp/claude-code-install.sh
bash /tmp/claude-code-install.sh "${CC_VERSION}"
rm -f /tmp/claude-code-install.sh

# Add ~/.local/bin to PATH for current session (installer places binary there)
export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v claude &>/dev/null; then
  fail "claude command not found after install. Check PATH or install output."
fi

CLAUDE_VERSION="$(claude --version 2>/dev/null || echo unknown)"
ok "Claude Code installed: ${CLAUDE_VERSION}"

# Verify the pin took effect (warn-only: 'stable'/'latest' resolve dynamically)
if [[ "${CC_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && [[ "${CLAUDE_VERSION}" != *"${CC_VERSION}"* ]]; then
  warn "Installed version (${CLAUDE_VERSION}) does not match requested pin (${CC_VERSION})"
fi

# ── Configure Bedrock environment ─────────────────────────────────────────────
step "Configuring Bedrock environment"

# Write env vars — /etc/profile.d if root, else ~/.claude/bedrock-env.sh
if [[ $EUID -eq 0 ]]; then
  PROFILE_TARGET="/etc/profile.d/claude-code-bedrock.sh"
else
  PROFILE_TARGET="${HOME}/.claude/bedrock-env.sh"
  mkdir -p "${HOME}/.claude"
  # Ensure ~/.bashrc sources it
  if ! grep -q 'claude/bedrock-env.sh' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\n[ -f "%s/.claude/bedrock-env.sh" ] && source "%s/.claude/bedrock-env.sh"\n' "${HOME}" "${HOME}" >> "${HOME}/.bashrc"
  fi
fi

mkdir -p "$(dirname "${PROFILE_TARGET}")"
cat > "${PROFILE_TARGET}" <<EOF
# Claude Code — Bedrock configuration
# Managed by loki-agent packs/claude-code/install.sh — do not edit manually.
export PATH="\${HOME}/.local/bin:\${PATH}"
export CLAUDE_CODE_USE_BEDROCK=1
export AWS_REGION="${REGION}"
export ANTHROPIC_MODEL="${MODEL}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${HAIKU_MODEL}"
EOF

chmod 644 "${PROFILE_TARGET}"
ok "Bedrock env vars written to ${PROFILE_TARGET}"

# Source now for the current session
# shellcheck source=/dev/null
source "${PROFILE_TARGET}"

# ── Configure Claude Code settings (merge, never clobber) ───────────────────
step "Configuring Claude Code settings"

mkdir -p "${HOME}/.claude"

# Merge Bedrock env + permissions into settings.json, preserving existing keys.
# The env block makes Bedrock work in non-login shells (headless, CI, IDE) —
# same mechanism the official /setup-bedrock wizard uses.
SETTINGS_FILE="${HOME}/.claude/settings.json" \
CC_REGION="${REGION}" CC_MODEL="${MODEL}" CC_HAIKU_MODEL="${HAIKU_MODEL}" \
python3 <<'PYEOF'
import json, os

path = os.environ["SETTINGS_FILE"]
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

# Bedrock env (pack-managed keys only; user keys preserved)
env = settings.setdefault("env", {})
env["CLAUDE_CODE_USE_BEDROCK"] = "1"
env["AWS_REGION"] = os.environ["CC_REGION"]
env["ANTHROPIC_MODEL"] = os.environ["CC_MODEL"]
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = os.environ["CC_HAIKU_MODEL"]

# Full tool permissions (union with existing allow list)
perms = settings.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
for rule in ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)"]:
    if rule not in allow:
        allow.append(rule)
perms.setdefault("deny", [])

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

chmod 600 "${HOME}/.claude/settings.json"
ok "Settings merged (Bedrock env + permissions): ${HOME}/.claude/settings.json"

# ── Sanity check ─────────────────────────────────────────────────────────────
step "Sanity check"

CLAUDE_VER="$(claude --version 2>/dev/null || echo unknown)"
ok "claude --version: ${CLAUDE_VER}"

# ── Install AWS Agent Toolkit plugins ────────────────────────────────────────
# Plugins bundle MCP server config + skills in one install.
# Prefer toolkit over loki-skills for overlapping AWS skills (toolkit is newer).
step "Installing AWS Agent Toolkit plugins"
if command -v claude &>/dev/null; then
  if claude plugin --help &>/dev/null; then
    # First-class plugin CLI (Claude Code >= 2.x)
    claude plugin marketplace update claude-plugins-official 2>/dev/null || true
    for plugin in aws-core aws-agents; do
      if claude plugin list 2>/dev/null | grep -q "${plugin}"; then
        claude plugin update "${plugin}" 2>/dev/null \
          && ok "Plugin updated: ${plugin}" \
          || warn "Plugin update failed: ${plugin} (existing version still active)"
      else
        claude plugin install "${plugin}@claude-plugins-official" \
          && ok "Plugin installed: ${plugin}" \
          || warn "Plugin install failed: ${plugin} (offline?)"
      fi
    done
  else
    # Fallback for older CLIs without the plugin subcommand
    claude --dangerously-skip-permissions /plugin marketplace update claude-plugins-official \
      2>/dev/null || true
    for plugin in aws-core aws-agents; do
      claude --dangerously-skip-permissions /plugin install "${plugin}@claude-plugins-official" \
        2>/dev/null \
        && ok "Plugin installed: ${plugin}" \
        || warn "Plugin install skipped: ${plugin} (may already be installed or offline)"
    done
  fi
else
  warn "claude CLI not on PATH — skipping plugin install (non-fatal)"
fi

# ── Install loki-skills (non-AWS skills) + AWS Agent Toolkit skills ───────────
# AWS toolkit skills overwrite any duplicate loki-skills (toolkit is preferred).
PACK_SKILLS_DIR="${HOME}/.claude/skills"
if ensure_skills_clone "${PACK_SKILLS_DIR}"; then
  ok "loki-skills installed to ${PACK_SKILLS_DIR}"
else
  warn "loki-skills clone failed (optional)"
fi
install_aws_toolkit_skills "${PACK_SKILLS_DIR}"

# ── AWS MCP proxy (parity with kiro-cli) ─────────────────────────────────────
# Wires mcp-proxy-for-aws into Claude Code at user scope. Best-effort.
step "Configuring AWS MCP proxy"
if ! command -v uv &>/dev/null && ! command -v uvx &>/dev/null; then
  log "Installing uv (needed for mcp-proxy-for-aws)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh || warn "uv install failed (non-fatal)"
  export PATH="${HOME}/.cargo/bin:${HOME}/.local/bin:${PATH}"
fi
if command -v uvx &>/dev/null || command -v uv &>/dev/null; then
  if claude mcp list 2>/dev/null | grep -q "^aws:"; then
    ok "MCP server 'aws' already configured — skipping"
  else
    claude mcp add --scope user aws -- uvx "mcp-proxy-for-aws@${MCP_PROXY_VERSION}" \
      && ok "MCP server 'aws' added (mcp-proxy-for-aws@${MCP_PROXY_VERSION}, user scope)" \
      || warn "claude mcp add failed (non-fatal)"
  fi
else
  warn "uv/uvx unavailable — skipping AWS MCP proxy (non-fatal)"
fi

# ── Bedrock smoke test ───────────────────────────────────────────────────────
if [[ "${SKIP_SMOKE_TEST}" -eq 1 ]]; then
  log "Skipping Bedrock smoke test (--skip-smoke-test)"
else
  step "Bedrock smoke test"
  if CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION="${REGION}" ANTHROPIC_MODEL="${MODEL}" \
      timeout 90 claude -p "Reply with exactly: ok" --model "${MODEL}" 2>/dev/null | grep -qi "ok"; then
    ok "Bedrock smoke test passed (${MODEL} via ${REGION})"
  else
    warn "Bedrock smoke test failed — check IAM role Bedrock permissions and model access (non-fatal)"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
write_done_marker "claude-code"
printf "\n[PACK:claude-code] INSTALLED — claude %s ready (model: %s via Bedrock region: %s)\n" \
  "${CLAUDE_VERSION:-}" "${MODEL}" "${REGION}"
