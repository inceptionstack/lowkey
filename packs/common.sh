#!/usr/bin/env bash
# packs/common.sh — shared helpers for all pack install scripts
# Source this file; do not execute directly.
# Usage: source "$(dirname "$0")/../common.sh"

# ── Shared constants ─────────────────────────────────────────────────────────
# Loki skills library — the single source of truth used by every pack that
# wants to pre-install agent skills. Each pack owns its own install step (so
# pack-specific layout / post-clone wiring can differ); only this URL is
# shared. Override at install time with: LOKI_SKILLS_REPO_URL=...
export LOKI_SKILLS_REPO_URL="${LOKI_SKILLS_REPO_URL:-https://github.com/inceptionstack/loki-skills.git}"

# ── ensure_skills_clone ───────────────────────────────────────────────────────
# Clone loki-skills library to target directory (best-effort, non-fatal).
# Handles update path, partial directory recovery, missing git gracefully.
#
# Usage: ensure_skills_clone <target_dir> [<repo_url>] [<branch>] [<mode>]
#   target_dir: where to clone (e.g. ~/.openclaw/workspace/skills)
#   repo_url:   git repo (default: $LOKI_SKILLS_REPO_URL)
#   branch:     git branch (default: main)
#   mode:       'warn' (default) or 'fail' — controls error handling
#
# Returns: 0 on success, non-zero on failure (caller decides via || true)
ensure_skills_clone() {
  local target_dir="${1:?target_dir required}"
  local repo_url="${2:-${LOKI_SKILLS_REPO_URL}}"
  local branch="${3:-main}"
  local mode="${4:-warn}"

  # Check git available
  if ! command -v git &>/dev/null; then
    local msg="git not found; skills clone skipped"
    [[ "$mode" == "fail" ]] && { log "$msg (FATAL)"; return 1; } || log "$msg (warn)"
    return 0
  fi

  # Existing repo: try update if same origin
  if [[ -d "$target_dir" ]] && [[ -d "$target_dir/.git" ]]; then
    local origin_url="$(cd "$target_dir" && git config --get remote.origin.url 2>/dev/null)"
    if [[ "$origin_url" == "$repo_url" ]]; then
      # Same origin, safe to update: reset to remote tip
      if (cd "$target_dir" && git fetch origin "$branch" 2>&1 && git reset --hard "origin/$branch" 2>&1) &>/dev/null; then
        log "Skills repo updated at $target_dir (branch: $branch)"
        return 0
      else
        # Update failed: preserve existing rather than move aside in warn mode
        if [[ "$mode" == "fail" ]]; then
          log "Skills repo update failed (FATAL)"
          return 1
        else
          log "Skills repo update failed; keeping existing checkout (warn mode)"
          return 0
        fi
      fi
    else
      # Different origin: only move aside if clone will succeed
      # Preserve existing in warn mode if replacement fails
      log "Skills origin mismatch; attempting re-clone..."
    fi
  fi

  # Partial dir (no .git): remove and re-clone
  local backup_dir=""
  if [[ -d "$target_dir" ]]; then
    if [[ ! -d "$target_dir/.git" ]]; then
      log "Incomplete skills dir; removing and re-cloning"
      rm -rf "$target_dir" || true
    else
      # Save as backup in case clone fails (warn mode recovery)
      backup_dir="${target_dir}.bak.$RANDOM"
      mv "$target_dir" "$backup_dir" || true
    fi
  fi

  # Fresh clone (shallow) — only commit to move if clone succeeds
  if git clone --depth 1 --branch "$branch" "$repo_url" "$target_dir" &>/dev/null; then
    # Clone succeeded: remove backup if one exists
    [[ -n "$backup_dir" ]] && rm -rf "$backup_dir" || true
    log "Skills cloned to $target_dir"
    return 0
  else
    # Clone failed: restore backup if we have one (warn mode)
    if [[ -n "$backup_dir" ]] && [[ -d "$backup_dir" ]]; then
      mv "$backup_dir" "$target_dir" || true
      local msg="Skills clone failed; restored backup at $target_dir"
      [[ "$mode" == "fail" ]] && { log "$msg (FATAL)"; return 1; } || { log "$msg (warn)"; return 0; }
    else
      # No backup to restore
      local msg="Skills clone failed (repo: $repo_url, branch: $branch)"
      [[ "$mode" == "fail" ]] && { log "$msg (FATAL)"; return 1; } || { log "$msg (warn, no fallback)"; return 1; }
    fi
  fi
}

# Colors
_CLR_GREEN='\033[0;32m'
_CLR_CYAN='\033[0;36m'
_CLR_RED='\033[0;31m'
_CLR_YELLOW='\033[0;33m'
_CLR_BOLD='\033[1m'
_CLR_NC='\033[0m'

# log LEVEL MESSAGE
log()  { printf "${_CLR_CYAN}→${_CLR_NC} %s\n" "$1"; }
ok()   { printf "${_CLR_GREEN}✓${_CLR_NC} %s\n" "$1"; }
fail() { printf "${_CLR_RED}✗${_CLR_NC} %s\n" "$1" >&2; exit 1; }
warn() { printf "${_CLR_YELLOW}⚠${_CLR_NC} %s\n" "$1"; }
step() {
  # Increment shared step counter (shared with bootstrap.sh)
  local counter_file="/tmp/loki-step-counter"
  local total_file="/tmp/loki-step-total"
  local n total
  n=$(cat "$counter_file" 2>/dev/null || echo 0)
  n=$((n + 1))
  echo "$n" > "$counter_file"
  total=$(cat "$total_file" 2>/dev/null || echo "?")
  printf "\n${_CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n"
  printf "${_CLR_BOLD}  [%s/%s] %s${_CLR_NC}\n" "$n" "$total" "$1"
  printf "${_CLR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n\n"
  # Publish to SSM for installer progress display
  aws ssm put-parameter --name "/loki/setup-step" \
    --value "${n}/${total} $1" \
    --type String --overwrite --region "${AWS_DEFAULT_REGION:-us-east-1}" >/dev/null 2>&1 || true
}

# require_cmd CMD [CMD...]  — fail if any command is not found
require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      fail "Required command not found: $cmd (prerequisites not met)"
    fi
  done
}

# write_done_marker PACK_NAME
write_done_marker() {
  local pack_name="$1"
  touch "/tmp/pack-${pack_name}-done"
  ok "Marker written: /tmp/pack-${pack_name}-done"
}

# Read a value from the pack config JSON file
# Usage: pack_config_get "key" "default_value"
pack_config_get() {
  local key="$1" default="${2:-}"
  local config="${PACK_CONFIG:-/tmp/loki-pack-config.json}"
  if [[ -f "$config" ]] && command -v jq &>/dev/null; then
    local val
    val=$(jq -r --arg k "$key" '.[$k] // empty' "$config" 2>/dev/null)
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

# check_bedrockify_health PORT
# Verify bedrockify is running and healthy on the given port.
# Fails with a clear message if not reachable.
check_bedrockify_health() {
  local port="${1:?usage: check_bedrockify_health PORT}"
  local health
  health="$(curl -sf "http://127.0.0.1:${port}/" 2>&1)" || true
  if ! printf '%s' "${health}" | grep -q '"status":"ok"'; then
    fail "bedrockify is not running on port ${port}. Install bedrockify pack first."
  fi
  ok "bedrockify is healthy on port ${port}"
}

# pack_banner NAME ACTION
pack_banner() {
  local name="$1"
  local action="${2:-INSTALLING}"
  printf "\n${_CLR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n"
  printf "${_CLR_CYAN}  [PACK:%s] %s${_CLR_NC}\n" "$name" "$action"
  printf "${_CLR_CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${_CLR_NC}\n\n"
}

# run_optional_sidecar — best-effort bootstrap of an optional install-time
# companion (metrics agent, diagnostics daemon, etc.) with the following
# hard invariants:
#
# DEPRECATED: No pack currently calls this function. Telemetron installs now
# use `install_telemetron` from common-telemetron.sh instead. Kept for
# potential future sidecars that use a curl|bash pipeline pattern.
#
#   - Silent:  zero bytes on caller's stdout/stderr. Every line (begin,
#              outcome, transcript of the inner installer, end) goes to
#              LOG_FILE only.
#   - Logged:  every outcome writes a tagged `[NAME] ...` line.
#   - Bounded: wall clock is capped by TIMEOUT_SECS via coreutils `timeout`.
#   - Piped:   the `curl | bash` pipeline runs under `bash -o pipefail`
#              so a curl failure cannot be masked by the RHS bash exit code.
#   - Safe:    returns 0 to the caller under any outcome. The caller's
#              `set -euo pipefail` is never tripped by a sidecar failure.
#
# Usage: run_optional_sidecar NAME URL TIMEOUT_SECS LOG_FILE [KEY=VAL ...]
#   NAME          human-readable tag, e.g. "telemetron"
#   URL           HTTPS URL serving the sidecar's install.sh on stdout
#   TIMEOUT_SECS  outer wall-clock cap, e.g. 30
#   LOG_FILE      absolute path for outcome + install transcript
#   KEY=VAL...    env vars exported into the install script
#
# If the env var SIDECAR_USE_SUDO=1 is present in the KEY=VAL list,
# the inner `curl | bash` pipeline runs under `sudo -E` so that sidecar
# installers requiring root (e.g. telemetron setup writing /etc/* and
# installing systemd units) succeed in the bootstrap context where the
# pack install script runs as ec2-user with passwordless sudo.
run_optional_sidecar() {
  local name="${1:?usage: run_optional_sidecar NAME URL TIMEOUT_SECS LOG_FILE [ENV...]}"
  local url="${2:?sidecar URL required}"
  local secs="${3:?sidecar timeout required}"
  local log="${4:?sidecar log path required}"
  shift 4

  # Subshell + outer `|| true` ensures nothing in here can propagate
  # a non-zero exit to the caller — not even a failed exec-redirect.
  (
    set +e
    # Redirect all output to the log. Test writability first so the
    # "silent" contract holds even if the log path is unwritable or its
    # parent directory does not exist. The test-open uses a subshell so
    # any shell diagnostic stays invisible before we commit to a dest.
    if ( >> "$log" ) 2>/dev/null; then
      exec >>"$log" 2>&1
    else
      exec >/dev/null 2>&1
    fi
    printf '\n[%s] begin %s\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] installing from %s (timeout=%ss)\n' "$name" "$url" "$secs"

    # Inner curl caps budget well under the outer wall-clock so network
    # hangs return crisply. connect 5s, transfer = outer - 5s.
    local connect_to=5
    local max_to=$(( secs > 5 ? secs - 5 : secs ))

    # Positional args (not quote-splicing) so the command reads cleanly.
    # pipefail must apply to the pipeline, so it's set on the bash -c
    # subshell, not the outer shell.
    # Check if the caller requested privileged execution via SIDECAR_USE_SUDO=1.
    # Filter it out of the env vars passed to the inner script — it's a
    # control flag, not something the sidecar installer needs.
    local use_sudo=0
    local env_args=()
    for _arg in "$@"; do
      case "$_arg" in
        SIDECAR_USE_SUDO=1) use_sudo=1 ;;
        *) env_args+=("$_arg") ;;
      esac
    done

    local sudo_prefix=""
    if [[ "$use_sudo" -eq 1 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo_prefix="sudo -n -E"
    fi

    timeout "$secs" env "${env_args[@]}" bash -o pipefail -c '
      curl --fail --silent --show-error --location \
        --connect-timeout "$2" --max-time "$3" \
        "$1" \
      | '"${sudo_prefix}"' bash
    ' _ "$url" "$connect_to" "$max_to"
    local rc=$?

    case "$rc" in
      0)          printf '[%s] installed and enrolled\n' "$name" ;;
      124|137|143) printf '[%s] install aborted: %ss outer timeout reached (rc=%s)\n' "$name" "$secs" "$rc" ;;
      *)          printf '[%s] install failed (rc=%s); see log above\n' "$name" "$rc" ;;
    esac
    printf '[%s] end %s\n' "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exit 0
  ) || true
}

# ── install_aws_toolkit_skills ────────────────────────────────────────────────
# Install AWS Agent Toolkit skills into an agent's skills directory.
# Usage: install_aws_toolkit_skills <target_dir>
#   target_dir: agent-specific skills path (e.g. ~/.claude/skills)
# Prefers 'npx skills add' (official method). Falls back to sparse git clone.
# Best-effort: never fails the parent installer.
# Duplicate loki-skills are overwritten by the toolkit (newer, preferred).
install_aws_toolkit_skills() {
  local target_dir="$1"
  local toolkit_repo="aws/agent-toolkit-for-aws"
  local toolkit_skills_path="skills"

  mkdir -p "${target_dir}"

  if command -v npx &>/dev/null; then
    log "Installing AWS Agent Toolkit skills via npx → ${target_dir}"
    SKILLS_DIR="${target_dir}" npx --yes skills add "${toolkit_repo}/${toolkit_skills_path}" --yes \
      2>&1 | grep -v "^npm warn" || true
    if [[ -d "${target_dir}/core-skills" || -d "${target_dir}/specialized-skills" ]]; then
      ok "AWS Agent Toolkit skills installed → ${target_dir}"
      return 0
    fi
    warn "npx skills add returned but skills dirs not found — falling back to git clone"
  fi

  # Fallback: sparse git clone of skills subtree
  local tmp_clone; tmp_clone="$(mktemp -d)"
  if git clone --depth=1 --filter=blob:none --sparse \
      "https://github.com/${toolkit_repo}.git" "${tmp_clone}" 2>/dev/null; then
    git -C "${tmp_clone}" sparse-checkout set "${toolkit_skills_path}" 2>/dev/null
    if [[ -d "${tmp_clone}/${toolkit_skills_path}" ]]; then
      cp -r "${tmp_clone}/${toolkit_skills_path}/." "${target_dir}/"
      ok "AWS Agent Toolkit skills installed (git clone fallback) → ${target_dir}"
    else
      warn "AWS Agent Toolkit skills: sparse checkout empty — skipping"
    fi
  else
    warn "AWS Agent Toolkit skills: git clone failed — skipping (non-fatal)"
  fi
  rm -rf "${tmp_clone}"
  return 0
}

# ── install_aws_mcp_proxy ─────────────────────────────────────────────────────
# Install and wire mcp-proxy-for-aws (official AWS MCP server successor).
# Writes ~/.kiro/agents/aws-mcp.json (kiro format) or ~/.config/mcp/aws.json.
# Usage: install_aws_mcp_proxy <region> [<config_path>]
# Requires: uv (installed by kiro-cli step 2 or present on system)
MCP_PROXY_VERSION="1.6.3"
install_aws_mcp_proxy() {
  local region="${1:-us-east-1}"
  local config_path="${2:-}"

  if ! command -v uv &>/dev/null && ! command -v uvx &>/dev/null; then
    warn "uv/uvx not found — skipping mcp-proxy-for-aws install (non-fatal)"
    return 0
  fi

  local uvx_cmd
  uvx_cmd="$(command -v uvx 2>/dev/null || echo "uv run --with uvx uvx")"

  log "Configuring mcp-proxy-for-aws@${MCP_PROXY_VERSION} (region: ${region})"

  # Write MCP server config (JSON used by kiro and other MCP-aware agents)
  if [[ -n "${config_path}" ]]; then
    mkdir -p "$(dirname "${config_path}")"
    cat > "${config_path}" << MCPJSON
{
  "mcpServers": {
    "aws": {
      "command": "uvx",
      "args": [
        "mcp-proxy-for-aws@${MCP_PROXY_VERSION}",
        "https://aws-mcp.${region}.api.aws/mcp",
        "--metadata",
        "AWS_REGION=${region}"
      ]
    }
  }
}
MCPJSON
    chmod 600 "${config_path}"
    ok "AWS MCP proxy config written: ${config_path}"
  fi

  # Pre-warm: pull the package so first run is instant
  ${uvx_cmd} "mcp-proxy-for-aws@${MCP_PROXY_VERSION}" --help &>/dev/null &
  ok "mcp-proxy-for-aws@${MCP_PROXY_VERSION} configured (region: ${region})"
  return 0
}
