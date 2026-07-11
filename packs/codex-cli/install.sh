#!/usr/bin/env bash
# packs/codex-cli/install.sh — Install OpenAI Codex CLI (builder agent)
#
# Usage:
#   ./install.sh [--region us-east-1] [--model gpt-5.4]
#
# Assumes:
#   - Node.js / npm available
#
# Unlike other packs, Codex CLI uses OpenAI's API directly — no bedrockify needed.
# This pack configures Codex as a BUILDER AGENT: danger-full-access sandbox,
# never-prompt approval policy. Authenticate post-deploy with:
#   codex login                       # Browser-based ChatGPT login
#   printenv OPENAI_API_KEY | codex login --with-api-key
#
# Idempotent: safe to re-run. Preserves existing user settings in config.toml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# Codex CLI npm version — defaults to "latest" (opt-in auto-upgrade on re-run).
# Override with env CODEX_CLI_VERSION="1.2.3" for reproducible / pinned installs.
CODEX_CLI_VERSION="${CODEX_CLI_VERSION:-latest}"

# ── Defaults ──────────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_MODEL="$(pack_config_get model "gpt-5.4")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install OpenAI Codex CLI — configured as a builder agent on AWS EC2.

⚠️  Codex CLI requires an OpenAI API key or ChatGPT login, obtained AFTER
   deploy. This pack does not embed secrets. Get your key at:
   https://platform.openai.com/api-keys

Options:
  --region      AWS region (informational only)          (default: us-east-1)
  --model       Default model for Codex CLI              (default: gpt-5.4)
  --help        Show this help message

Post-deploy authentication (choose one):
  codex login                              # Browser-based ChatGPT login
  printenv OPENAI_API_KEY | codex login --with-api-key

Builder agent config (set by this pack):
  sandbox_mode    = "danger-full-access"   # Full filesystem/network access
  approval_policy = "never"                # Never prompt before commands
  model           = configured from --model

Note: Codex CLI is a CLI tool only — no systemd service is created.
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)   usage; exit 0 ;;
    --region)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --region requires a value" >&2; exit 2; }
      PACK_ARG_REGION="$2"; shift 2 ;;
    --model)
      [[ $# -ge 2 && "$2" != -* ]] || { echo "error: --model requires a value" >&2; exit 2; }
      PACK_ARG_MODEL="$2"; shift 2 ;;
    --)          shift; break ;;
    -*)          echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)           echo "error: unexpected positional argument: $1" >&2; exit 2 ;;
  esac
done

REGION="${PACK_ARG_REGION}"
MODEL="${PACK_ARG_MODEL}"

# ── Guard against Bedrock model IDs leaking in via CFN's DefaultModel ────────────────────────────────────
# install.sh / CFN template ship with a Bedrock-style DefaultModel
# (e.g. us.anthropic.claude-sonnet-4-6) that's great for openclaw/claude-code
# but poison for codex-cli — OpenAI's API rejects it with HTTP 400.
# If the caller hands us a Bedrock-style ID, fall back to the pack default
# instead of writing a broken config.
CODEX_DEFAULT_MODEL="gpt-5.4"
if [[ "${MODEL}" =~ ^(us\.|eu\.|ap\.|anthropic\.|amazon\.|meta\.|mistral\.|cohere\.|ai21\.) ]]; then
  warn "ignoring Bedrock-style model id '${MODEL}' — Codex CLI talks to OpenAI, not Bedrock"
  warn "falling back to ${CODEX_DEFAULT_MODEL} (override with: bash install.sh --model <openai-model>)"
  MODEL="${CODEX_DEFAULT_MODEL}"
fi

pack_banner "codex-cli"
log "region=${REGION} model=${MODEL} sandbox=danger-full-access approval=never"

# ── Prerequisites ─────────────────────────────────────────────────────────────
step "Checking prerequisites"
require_cmd npm node

# ── Install Codex CLI ─────────────────────────────────────────────────────────
step "Installing Codex CLI"

if command -v codex &>/dev/null; then
  CODEX_EXISTING="$(codex --version 2>/dev/null || echo unknown)"
  log "codex already installed (${CODEX_EXISTING}) — upgrading"
fi

# Resolve npm install strategy:
#   1. If mise manages Node.js, activate it — npm prefix becomes user-owned.
#   2. If npm prefix is already user-writable, install directly.
#   3. Otherwise (system npm with root-owned prefix), fall back to sudo.
NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"

if [[ -x "${HOME}/.local/bin/mise" ]] && [[ ! -w "${NPM_PREFIX}" ]]; then
  log "Activating mise to get a user-owned Node.js"
  eval "$(${HOME}/.local/bin/mise activate bash 2>/dev/null)" || true
  NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
fi

if [[ -w "${NPM_PREFIX}" ]]; then
  log "npm prefix is user-writable: ${NPM_PREFIX}"
  npm install -g "@openai/codex@${CODEX_CLI_VERSION}"
else
  # System npm with root-owned prefix. Fallback for standalone pack runs
  # on hosts without mise. Use sudo and preserve PATH so sudo's npm
  # resolves the same binary as ours.
  warn "npm prefix ${NPM_PREFIX} is not user-writable — falling back to sudo"
  warn "(install mise for rootless Node.js: curl -fsSL https://mise.run | sh)"
  if ! sudo -n true 2>/dev/null; then
    fail "npm install -g requires sudo but sudo is unavailable. Install mise and retry, or run this script as root."
  fi
  sudo --preserve-env=PATH npm install -g "@openai/codex@${CODEX_CLI_VERSION}"
fi

# Add npm global bin to PATH for current session
NPM_BIN="$(npm prefix -g)/bin"
export PATH="${NPM_BIN}:${PATH}"

if ! command -v codex &>/dev/null; then
  fail "codex command not found after install. Check PATH or install output."
fi

CODEX_VERSION="$(codex --version 2>/dev/null || echo unknown)"
ok "Codex CLI installed: ${CODEX_VERSION}"

# ── Configure Codex CLI (merge into existing config.toml) ─────────────────────
step "Writing Codex CLI configuration"

CODEX_HOME="${HOME}/.codex"
CODEX_CONFIG="${CODEX_HOME}/config.toml"
mkdir -p "${CODEX_HOME}"

# Merge strategy: sentinel-delimited managed block (regex-based text rewrite).
# Preserves user edits outside the managed block. Putting the managed block at
# the TOP of the file keeps our bare keys at the top-level TOML scope so they
# aren't accidentally nested into a user-defined [table] section.
PACK_MODEL="${MODEL}" python3 - "${CODEX_CONFIG}" <<'PYEOF'
import os, sys, re
path = sys.argv[1]
model = os.environ.get("PACK_MODEL", "gpt-5.4")

# TOML-escape the model value (basic-string rules):
#   https://toml.io/en/v1.0.0#string
# Newlines/CR are not legal in basic strings — reject up front instead of
# silently emitting invalid TOML.
if "\n" in model or "\r" in model:
    sys.stderr.write(f"error: model value contains newline: {model!r}\n")
    sys.exit(2)

def toml_escape(s: str) -> str:
    out = []
    for ch in s:
        code = ord(ch)
        if ch == "\\":   out.append("\\\\")
        elif ch == '"':  out.append('\\"')
        elif ch == "\t": out.append("\\t")
        elif ch == "\b": out.append("\\b")
        elif ch == "\f": out.append("\\f")
        elif code < 0x20 or code == 0x7f:
            out.append(f"\\u{code:04X}")
        else:
            out.append(ch)
    return "".join(out)

model_escaped = toml_escape(model)

# Managed block sentinels — preserve user edits outside this block.
# Block is placed at TOP of file (before any [tables]) so bare keys stay
# at the top-level scope and aren't accidentally scoped into a table.
START = "# >>> managed by lowkey codex-cli pack >>>"
END   = "# <<< managed by lowkey codex-cli pack <<<"
MANAGED_KEYS = ("model", "approval_policy", "sandbox_mode")

managed = f"""{START}
# Keys below are managed by packs/codex-cli/install.sh (builder agent).
# Edits inside this block will be overwritten on pack re-run.
model = "{model_escaped}"
approval_policy = "never"
sandbox_mode = "danger-full-access"
{END}
"""

existing = ""
if os.path.exists(path):
    with open(path) as f:
        existing = f.read()

# Strip any previous managed block. The inner pattern `(?:(?!START).)*?`
# refuses to cross a second START sentinel, so a stray sentinel in user
# content can't collapse a large region, and we only remove the FIRST
# well-formed block.
managed_re = re.compile(
    re.escape(START) + r"(?:(?!" + re.escape(START) + r").)*?" + re.escape(END) + r"\n?",
    re.DOTALL,
)
without_managed = managed_re.sub("", existing, count=1)

# Strip top-level assignments of managed keys from user content (before first [table]).
lines = without_managed.splitlines()
in_table = False
cleaned = []
for line in lines:
    stripped = line.lstrip()
    if stripped.startswith("["):
        in_table = True
    if not in_table:
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if m and m.group(1) in MANAGED_KEYS:
            continue  # skip
    cleaned.append(line)

cleaned_text = "\n".join(cleaned).lstrip("\n")

# Put managed block at TOP (before any [tables] so our bare keys stay top-level)
if cleaned_text:
    new = managed + "\n" + cleaned_text
else:
    new = managed

if not new.endswith("\n"):
    new += "\n"

with open(path, "w") as f:
    f.write(new)
print(f"[ok] Config updated: {path}")
PYEOF

chmod 600 "${CODEX_CONFIG}"
ok "Config merged: ${CODEX_CONFIG}"

# ── Sanity check ──────────────────────────────────────────────────────────────
step "Sanity check"

ok "codex --version: $(codex --version 2>/dev/null || echo unknown)"
ok "Model: ${MODEL}"
ok "Sandbox: danger-full-access (builder agent — full filesystem/network)"
ok "Approval: never (no command prompts)"
warn "Auth: NOT configured — run 'codex login' or set OPENAI_API_KEY"

# ── Post-install notice ──────────────────────────────────────────────────────
cat << NOTICE

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [CODEX CLI] INSTALLED — BUILDER AGENT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  !! AUTHENTICATION REQUIRED !!
  Codex CLI is installed but NOT authenticated. You must authenticate
  interactively on this machine before first use. Choose one:

    codex login                          # Browser/ChatGPT login
    codex login --with-api-key           # Paste API key on stdin
    export OPENAI_API_KEY=sk-...         # Or set env var (use Secrets Manager)

  NOTE: Headless (SSM / SSH-only) auth flow will be added in a follow-up.
        For now: SSM into the instance and run one of the commands above.

  Usage after auth:
    codex                                 # Start interactive TUI
    codex exec "Your prompt"              # One-shot execution
    codex resume --last                   # Resume last session

  Config:  ~/.codex/config.toml (managed block preserves user edits)
  Model:   ${MODEL}
  Sandbox: danger-full-access (builder — full filesystem/network)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

NOTICE

# ── Done ──────────────────────────────────────────────────────────────────────

# ── Install AWS Agent Toolkit plugin ─────────────────────────────────────────
step "Installing AWS Agent Toolkit plugin for Codex"
if command -v codex &>/dev/null; then
  codex plugin marketplace add aws/agent-toolkit-for-aws 2>/dev/null \
    && ok "AWS toolkit marketplace added" \
    || warn "Marketplace add skipped (may already exist or offline)"
  codex plugin install aws-core 2>/dev/null \
    && ok "Plugin installed: aws-core" \
    || warn "aws-core plugin install skipped (non-fatal)"
else
  warn "codex CLI not on PATH — skipping plugin install (non-fatal)"
fi

# ── Install loki-skills + AWS Agent Toolkit skills ───────────────────────
PACK_SKILLS_DIR="${HOME}/.codex/skills"
if ensure_skills_clone "${PACK_SKILLS_DIR}"; then
  ok "loki-skills installed to ${PACK_SKILLS_DIR}"
else
  warn "loki-skills clone failed (optional)"
fi
install_aws_toolkit_skills "${PACK_SKILLS_DIR}"
write_done_marker "codex-cli"
printf "\n[PACK:codex-cli] INSTALLED — codex CLI ready (model: %s)\n" "${MODEL}"
