#!/usr/bin/env bash
# packs/troika/install.sh — Wire OpenClaw/Hermes + Claude Code + Codex CLI (all via Bedrock)
#
# Runs AFTER deps: bedrockify → <primary> → claude-code → codex-cli
# (bootstrap substitutes openclaw dep with selected primary; §12a.1)
#
# Responsibilities:
#   1. Validate and persist the daily-driver selection
#   2. Rewire Codex CLI → Bedrock (merge model_provider + model; preserve other keys per §12.7)
#   3. Ensure AWS_REGION is exported for Codex (reads AWS_REGION, not AWS_DEFAULT_REGION)
#   4. Install the `agents` multi-harness helper to /usr/local/bin
#   5. Append auto-launch block to ~/.bashrc (idempotent, sentinel-guarded per §12.8)
#   6. Publish daily-driver to SSM for observability
#
# Idempotent: safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKS_REL_DIR="${SCRIPT_DIR}/.."  # parent of all pack directories

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Constants ─────────────────────────────────────────────────────────────────
# §12.8: sentinel string used for idempotency guard on ~/.bashrc block
AUTOLAUNCH_SENTINEL="# --- troika-autolaunch ---"
AWS_REGION_SENTINEL="# --- troika-aws-region ---"
DAILY_DRIVER_FILE="${HOME}/.config/lowkey/daily-driver"

# ── Defaults (from pack config, then CLI overrides) ───────────────────────────
PACK_ARG_PRIMARY="$(pack_config_get "primary"       "openclaw")"
PACK_ARG_DAILY_DRIVER="$(pack_config_get "daily-driver" "")"   # empty → tracks primary
PACK_ARG_MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6")"
PACK_ARG_CODEX_MODEL="$(pack_config_get "codex-model" "openai.gpt-5.5")"
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Wire OpenClaw + Claude Code + Codex CLI on one instance via Amazon Bedrock (Troika harness).
Runs after deps: bedrockify → openclaw → claude-code → codex-cli.

Options:
  --primary <name>        OpenClaw-family first horse (openclaw | hermes; default: openclaw)
  --daily-driver <name>   Agent to auto-launch on SSM login (default: follows primary)
                          Valid: <primary> | claude-code | codex-cli | none
  --model <id>            Bedrock model for Claude-family agents (default: us.anthropic.claude-sonnet-4-6)
  --codex-model <id>      Bedrock Mantle model for Codex CLI    (default: openai.gpt-5.5)
  --region <region>       AWS region for Bedrock                (default: us-east-1)
  --help                  Show this help message

Examples:
  ./install.sh --daily-driver openclaw
  ./install.sh --daily-driver claude-code --region eu-west-1
  ./install.sh --daily-driver none        # disable auto-launch
EOF
}

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)       usage; exit 0 ;;
    --primary)       PACK_ARG_PRIMARY="$2";       shift 2 ;;
    --daily-driver)  PACK_ARG_DAILY_DRIVER="$2";  shift 2 ;;
    --model)         PACK_ARG_MODEL="$2";          shift 2 ;;
    --codex-model)   PACK_ARG_CODEX_MODEL="$2";   shift 2 ;;
    --region)        PACK_ARG_REGION="$2";         shift 2 ;;
    *) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
  esac
done

PRIMARY="${PACK_ARG_PRIMARY}"
MODEL="${PACK_ARG_MODEL}"
CODEX_MODEL="${PACK_ARG_CODEX_MODEL}"
REGION="${PACK_ARG_REGION}"

# §12b.1: Single source of truth — read PACK_TUI_COMMAND from each pack's shell-profile.
# VALID_DRIVERS, autolaunch case, and agents helper ALL derive from _read_tui_cmd().
_read_tui_cmd() {
  local profile="$1"
  [[ -f "$profile" ]] || { printf ''; return 0; }
  local line cmd
  line=$(grep -m1 '^PACK_TUI_COMMAND=' "$profile" 2>/dev/null || true)
  [[ -z "$line" ]] && { printf ''; return 0; }
  cmd="${line#PACK_TUI_COMMAND=}"
  cmd="${cmd#\"}"   # strip leading "
  cmd="${cmd%\"}"   # strip trailing "
  printf '%s' "${cmd}"
}

_PRIMARY_CMD="$(_read_tui_cmd "${PACKS_REL_DIR}/${PRIMARY}/resources/shell-profile.sh")"
_PRIMARY_CMD="${_PRIMARY_CMD:-${PRIMARY}}"
_CLAUDE_CMD="$(_read_tui_cmd "${PACKS_REL_DIR}/claude-code/resources/shell-profile.sh")"
_CLAUDE_CMD="${_CLAUDE_CMD:-claude}"
_CODEX_CMD="$(_read_tui_cmd "${PACKS_REL_DIR}/codex-cli/resources/shell-profile.sh")"
_CODEX_CMD="${_CODEX_CMD:-codex}"

_PRIMARY_BIN="${_PRIMARY_CMD%% *}"
_CLAUDE_BIN="${_CLAUDE_CMD%% *}"
_CODEX_BIN="${_CODEX_CMD%% *}"

# Derive VALID_DRIVERS from metadata — §12a.2, §12b.1 (no hardcoded openclaw)
VALID_DRIVERS=("${PRIMARY}" claude-code codex-cli none)

# DAILY_DRIVER: default tracks selected primary — §12a.2
DAILY_DRIVER="${PACK_ARG_DAILY_DRIVER:-${PRIMARY}}" 

pack_banner "troika"
log "primary=${PRIMARY} daily-driver=${DAILY_DRIVER} model=${MODEL} codex-model=${CODEX_MODEL} region=${REGION}"

# ── Validate daily-driver ─────────────────────────────────────────────────────
step "Validating primary"
case "${PRIMARY}" in
  openclaw|hermes) ok "primary is valid: ${PRIMARY}" ;;
  *) fail "Invalid primary '${PRIMARY}'. Must be openclaw or hermes." ;;
esac

step "Validating daily-driver"

_valid_driver=0
for _v in "${VALID_DRIVERS[@]}"; do
  [[ "$DAILY_DRIVER" == "$_v" ]] && _valid_driver=1 && break
done

if [[ "$_valid_driver" -eq 0 ]]; then
  fail "Invalid daily-driver '${DAILY_DRIVER}'. Valid set for primary=${PRIMARY}: ${VALID_DRIVERS[*]}"
fi
ok "daily-driver is valid: ${DAILY_DRIVER} (primary=${PRIMARY})"

# ── Persist daily-driver ──────────────────────────────────────────────────────
step "Persisting daily-driver config"

mkdir -p "$(dirname "${DAILY_DRIVER_FILE}")"
printf '%s\n' "${DAILY_DRIVER}" > "${DAILY_DRIVER_FILE}"
chmod 644 "${DAILY_DRIVER_FILE}"
ok "daily-driver written to ${DAILY_DRIVER_FILE}"

# ── Rewire Codex CLI → Bedrock ────────────────────────────────────────────────
# §12.7: MERGE only model_provider + model keys; preserve approval_policy / sandbox_mode
# written by the codex-cli dep. Never replace the whole file.
step "Rewiring Codex CLI to Bedrock (merge model_provider + model)"

CODEX_HOME="${HOME}/.codex"
CODEX_CONFIG="${CODEX_HOME}/config.toml"
mkdir -p "${CODEX_HOME}"

CODEX_MODEL="${CODEX_MODEL}" python3 - "${CODEX_CONFIG}" <<'PYEOF'
import os, sys, re

path   = sys.argv[1]
cmodel = os.environ.get("CODEX_MODEL", "openai.gpt-5.5")

# TOML-escape a basic-string value (newlines in values are illegal)
if "\n" in cmodel or "\r" in cmodel:
    sys.stderr.write(f"error: codex-model contains newline: {cmodel!r}\n")
    sys.exit(2)

def toml_escape(s):
    out = []
    for ch in s:
        code = ord(ch)
        if   ch == "\\":   out.append("\\\\")
        elif ch == '"':    out.append('\\"')
        elif ch == "\t":   out.append("\\t")
        elif ch == "\b":   out.append("\\b")
        elif ch == "\f":   out.append("\\f")
        elif code < 0x20 or code == 0x7f:
            out.append(f"\\u{code:04X}")
        else:
            out.append(ch)
    return "".join(out)

escaped = toml_escape(cmodel)

# Sentinel strings
TRI_START = "# >>> managed by lowkey troika pack (bedrock) >>>"
TRI_END   = "# <<< managed by lowkey troika pack (bedrock) <<<"
CC_START  = "# >>> managed by lowkey codex-cli pack >>>"
CC_END    = "# <<< managed by lowkey codex-cli pack <<<"

tri_block = (
    TRI_START + "\n"
    "# Bedrock provider — managed by packs/troika/install.sh.\n"
    "# Edits inside this block will be overwritten on pack re-run.\n"
    "model_provider = \"amazon-bedrock\"\n"
    f"model = \"{escaped}\"\n"
    + TRI_END + "\n"
)

existing = ""
if os.path.exists(path):
    with open(path) as f:
        existing = f.read()

# 1. Remove any previous troika block (idempotency)
tri_re = re.compile(
    re.escape(TRI_START) + r".*?" + re.escape(TRI_END) + r"\n?",
    re.DOTALL,
)
text = tri_re.sub("", existing, count=1)

# 2. Remove `model = "..."` from the codex-cli managed block to avoid TOML
#    duplicate-key errors. approval_policy and sandbox_mode are preserved.
def strip_model_from_cc_block(s):
    cc_re = re.compile(
        re.escape(CC_START) + r"(.*?)" + re.escape(CC_END),
        re.DOTALL,
    )
    def _replace(m):
        content = m.group(1)
        # Remove model = "..." lines (handles escaped quotes in value)
        content = re.sub(r'\nmodel\s*=\s*"(?:[^"\\]|\\.)*"[ \t]*', "", content)
        return CC_START + content + CC_END
    return cc_re.sub(_replace, s, count=1)

text = strip_model_from_cc_block(text)

# 3. Place troika block at the TOP (bare top-level keys before any [table])
stripped = text.lstrip("\n")
new = (tri_block + "\n" + stripped) if stripped else tri_block
if not new.endswith("\n"):
    new += "\n"

with open(path, "w") as f:
    f.write(new)
print(f"[ok] Bedrock config merged: {path}")
PYEOF

chmod 600 "${CODEX_CONFIG}"
ok "Codex Bedrock config merged: ${CODEX_CONFIG}"

# ── Export AWS_REGION for Codex ───────────────────────────────────────────────
# Codex CLI reads AWS_REGION (not only AWS_DEFAULT_REGION). Bootstrap already
# exports AWS_DEFAULT_REGION; we export both so Codex finds the right region.
step "Ensuring AWS_REGION exported in .bashrc"

BASHRC="${HOME}/.bashrc"
if grep -qF "${AWS_REGION_SENTINEL}" "${BASHRC}" 2>/dev/null; then
  ok "AWS_REGION block already present in ${BASHRC} (idempotent)"
else
  printf '\n%s\n# Troika: Codex CLI reads AWS_REGION (not only AWS_DEFAULT_REGION)\nexport AWS_REGION="%s"\n%s\n' \
    "${AWS_REGION_SENTINEL}" "${REGION}" "${AWS_REGION_SENTINEL}" >> "${BASHRC}"
  ok "AWS_REGION=\"${REGION}\" sentinel-written to ${BASHRC}"
fi

# ── Install agents helper ─────────────────────────────────────────────────────
step "Installing agents helper"

AGENTS_BIN="/usr/local/bin/agents"
AGENTS_TMP="$(mktemp)"
# Ensure temp file is cleaned up even on error
# shellcheck disable=SC2064
trap "rm -f '${AGENTS_TMP}'" EXIT

cat > "${AGENTS_TMP}" <<AGENTS_SCRIPT
# shellcheck disable=SC2086  # intentional unquoted expansion of metadata vars in generated script
#!/usr/bin/env bash
# agents — Troika multi-harness helper
# Generated by packs/troika/install.sh (primary=${PRIMARY}) — do not edit manually.
set -euo pipefail

DAILY_DRIVER_FILE="\${HOME}/.config/lowkey/daily-driver"
# VALID_DRIVERS derives from primary selected at install time (§12b.1, §12a.2).
VALID_DRIVERS=(${PRIMARY} claude-code codex-cli none)

_valid_driver() {
  local d="\$1"
  for v in "\${VALID_DRIVERS[@]}"; do
    [[ "\$d" == "\$v" ]] && return 0
  done
  return 1
}

case "\${1:-}" in
  driver)
    new_driver="\${2:-}"
    if [[ -z "\$new_driver" ]]; then
      echo "Usage: agents driver <${PRIMARY}|claude-code|codex-cli|none>" >&2
      exit 1
    fi
    if ! _valid_driver "\$new_driver"; then
      echo "Unknown driver: \${new_driver} (valid: ${PRIMARY} | claude-code | codex-cli | none)" >&2
      exit 1
    fi
    mkdir -p "\$(dirname "\${DAILY_DRIVER_FILE}")"
    printf '%s\n' "\${new_driver}" > "\${DAILY_DRIVER_FILE}"
    echo "Daily driver set to: \${new_driver}"
    ;;

  review)
    echo "agents review: not yet implemented (stretch goal — Phase 2+)" >&2
    exit 1
    ;;

  ""|status)
    dd="(none)"
    [[ -f "\${DAILY_DRIVER_FILE}" ]] && dd="\$(cat "\${DAILY_DRIVER_FILE}")"
    printf "\n=== Troika — Agent Status ===\n\n"
    for _bin in "${_PRIMARY_BIN}" "${_CLAUDE_BIN}" "${_CODEX_BIN}"; do
      if command -v "\${_bin}" &>/dev/null; then
        _ver="\$("\${_bin}" --version 2>/dev/null | head -1 || echo unknown)"
        printf "  \033[0;32m✓\033[0m %-12s %s\n" "\${_bin}:" "\${_ver}"
      else
        printf "  \033[0;31m✗\033[0m %-12s not found\n" "\${_bin}:"
      fi
    done
    unset _bin _ver
    printf "\n  Daily driver:  %s\n\n" "\${dd}"
    printf "  agents driver <name>  → switch daily driver\n"
    printf "  LOKI_NO_TUI=1         → suppress auto-launch for this session\n\n"
    ;;

  *)
    printf 'Usage: agents [status | driver <name>]\n\n'
    printf '  status              Show installed agents and current daily driver\n'
    printf '  driver <name>       Set daily driver (%s | claude-code | codex-cli | none)\n\n' "${PRIMARY}"
    printf 'Daily driver values:\n'
    printf '  %-20s Auto-launch: %s\n' "${PRIMARY}" "${_PRIMARY_CMD}"
    printf '  %-20s Auto-launch: %s\n' "claude-code" "${_CLAUDE_CMD}"
    printf '  %-20s Auto-launch: %s\n' "codex-cli"   "${_CODEX_CMD}"
    printf '  %-20s Disable auto-launch\n' "none"
    printf '\nEscape hatches:\n'
    printf '  agents driver none  Disable auto-launch permanently\n'
    printf '  LOKI_NO_TUI=1       Disable auto-launch for this session\n\n'
    exit 1
    ;;
esac
AGENTS_SCRIPT

if [[ -w "$(dirname "${AGENTS_BIN}")" ]]; then
  cp "${AGENTS_TMP}" "${AGENTS_BIN}"
  chmod 755 "${AGENTS_BIN}"
  ok "agents helper installed: ${AGENTS_BIN}"
elif sudo -n true 2>/dev/null; then
  sudo cp "${AGENTS_TMP}" "${AGENTS_BIN}"
  sudo chmod 755 "${AGENTS_BIN}"
  ok "agents helper installed (sudo): ${AGENTS_BIN}"
else
  warn "Cannot write to $(dirname "${AGENTS_BIN}") — falling back to ~/.local/bin/agents"
  AGENTS_BIN="${HOME}/.local/bin/agents"
  mkdir -p "$(dirname "${AGENTS_BIN}")"
  cp "${AGENTS_TMP}" "${AGENTS_BIN}"
  chmod 755 "${AGENTS_BIN}"
  ok "agents helper installed: ${AGENTS_BIN}"
fi
rm -f "${AGENTS_TMP}"
trap - EXIT

# ── Append auto-launch block to .bashrc (idempotent) ─────────────────────────
# §12.8: sentinel-replacement idempotency — grep guard prevents double-append.
# Safety: [[ -t 0 ]] + interactive guard prevents firing on non-tty SSM sessions,
#         port-forwarding, scp-over-ssm, or aws ssm send-command invocations.
# Escape hatches: Ctrl+C during grace period; LOKI_NO_TUI=1; agents driver none.
step "Appending auto-launch block to .bashrc"

BASHRC="${HOME}/.bashrc"
if grep -qF "${AUTOLAUNCH_SENTINEL}" "${BASHRC}" 2>/dev/null; then
  ok "Auto-launch block already present in ${BASHRC} (idempotent — skipping)"
else
  # Note: variable references inside the AUTOLAUNCH heredoc are escaped (\$)
  # so they expand at runtime (when .bashrc is sourced), not at install time.
  cat >> "${BASHRC}" <<AUTOLAUNCH

${AUTOLAUNCH_SENTINEL}
# Troika daily-driver auto-launch
# Managed by packs/troika/install.sh (primary=${PRIMARY}) — do not edit manually.
# To disable: agents driver none   OR   export LOKI_NO_TUI=1
if [[ \$- == *i* ]] && [[ -t 0 ]] && [[ -z "\${LOKI_TUI_LAUNCHED:-}" ]] \\
   && [[ -z "\${LOKI_NO_TUI:-}" ]] && [[ -f ~/.config/lowkey/daily-driver ]]; then
  export LOKI_TUI_LAUNCHED=1
  _dd=\$(<~/.config/lowkey/daily-driver)
  echo "Launching \${_dd} (daily driver) — Ctrl+C to skip, LOKI_NO_TUI=1 to disable"
  sleep 2   # grace period to Ctrl+C
  # SC2086: command vars intentionally unquoted — multi-word cmds (e.g. "openclaw tui")
  # shellcheck disable=SC2086
  case "\$_dd" in
    ${PRIMARY})    ${_PRIMARY_CMD} ;;
    claude-code)   ${_CLAUDE_CMD} ;;
    codex-cli)     ${_CODEX_CMD} ;;
    none)          : ;;
  esac
  unset _dd
fi
${AUTOLAUNCH_SENTINEL}
AUTOLAUNCH
  ok "Auto-launch block appended to ${BASHRC}"
fi

# §12a.6: Only reference/enable openclaw-gateway when primary=openclaw
if [[ "${PRIMARY}" == "openclaw" ]]; then
  if systemctl is-enabled openclaw-gateway.service >/dev/null 2>&1; then
    ok "openclaw-gateway service is enabled (primary=openclaw)"
  else
    warn "openclaw-gateway service not found (primary=openclaw)"
  fi
fi

# ── Write SSM parameter for observability ────────────────────────────────────
step "Writing SSM parameter /loki/daily-driver"

aws ssm put-parameter \
  --name "/loki/daily-driver" \
  --value "${DAILY_DRIVER}" \
  --type String \
  --overwrite \
  --region "${REGION}" \
  >/dev/null 2>&1 \
  && ok "SSM parameter /loki/daily-driver = ${DAILY_DRIVER}" \
  || warn "SSM parameter write failed (non-fatal — check IAM role)"

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "troika"
printf "\n[PACK:troika] INSTALLED — daily driver: %s\n" "${DAILY_DRIVER}"
printf "  openclaw:    openclaw tui\n"
printf "  claude-code: claude\n"
printf "  codex-cli:   codex\n"
printf "  switch:      agents driver <name>\n\n"
