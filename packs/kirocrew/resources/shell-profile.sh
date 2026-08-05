# shellcheck shell=bash
# KiroCrew shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
# Defines aliases and a welcome banner for the kirocrew pack.
#
# Auth-mode-aware (checks ~/.kiro/env like kiro-cli pack):
#   - If ~/.kiro/env exists → headless mode is configured; banner reflects that.
#   - Otherwise            → show the interactive-login reminder.

PACK_TUI_COMMAND="kirocrew gateway"

PACK_ALIASES='
alias kiro="kiro-cli"
alias kiro-agent="kiro-cli --agent"
alias kiro-login="kiro-cli login --use-device-flow"
alias kiro-exec="kiro-cli --no-interactive"
alias crew="kirocrew"
alias crew-gw="kirocrew gateway"
alias crew-doctor="kirocrew doctor"
alias crew-setup="kirocrew setup"
'

PACK_BANNER_NAME="KiroCrew Agent Environment"
PACK_BANNER_EMOJI="🚀"
PACK_BANNER_COMMANDS='
  kirocrew gateway                 → Start crew gateway (http://localhost:${KIROCREW_PORT:-5476})
  kirocrew doctor                  → Verify setup (kiro-cli, auth, MCP, embeddings)
  kirocrew setup                   → Interactive config wizard
  kiro-cli                         → Kiro CLI (single agent, direct)
  kiro-cli --no-interactive "p"    → One-shot headless
'

# Interactive-shell helper: source ~/.kiro/env for KIRO_API_KEY if present.
# Also ensure KIRO_API_KEY is sourced in case .bash_profile isn't executed
# (e.g. SSM sessions may skip login shells on some configs).
if [[ $- == *i* ]] && command -v kirocrew &>/dev/null; then
  if [[ -f "${HOME}/.kiro/env" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.kiro/env" 2>/dev/null || true
  elif [[ -z "${KIRO_API_KEY:-}" ]]; then
    printf '\n\033[0;33m⚠  KiroCrew: kiro-cli not authenticated. Run "kiro-cli login --use-device-flow" or configure headless mode.\033[0m\n\n'
  fi
fi
