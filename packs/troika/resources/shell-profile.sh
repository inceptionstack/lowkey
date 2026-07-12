# shellcheck shell=bash
# Troika shell profile — sourced by bootstrap for .bashrc and /etc/profile.d
# Covers all three harnesses: OpenClaw, Claude Code, Codex CLI
# shellcheck disable=SC2034  # Variables are exported/used by the bootstrap dispatcher
PACK_TUI_COMMAND="openclaw tui"

PACK_ALIASES='
alias loki="openclaw"
alias lt="openclaw tui"
alias cc="claude"
alias cx="codex"
'

PACK_BANNER_NAME="Troika Agent Environment"
PACK_BANNER_EMOJI="🔱"
PACK_BANNER_COMMANDS='
  openclaw tui          → Launch OpenClaw TUI (default daily driver)
  claude                → Launch Claude Code
  codex                 → Launch Codex CLI
  agents                → Show all agent status + daily driver
  agents driver <name>  → Switch daily driver (openclaw|claude-code|codex-cli|none)
'
