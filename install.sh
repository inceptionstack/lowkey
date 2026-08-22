#!/usr/bin/env bash
# Lowkey Agent — One-Shot Installer
# Usage: curl -sfL https://raw.githubusercontent.com/inceptionstack/lowkey/main/install.sh -o /tmp/lowkey-install.sh && bash /tmp/lowkey-install.sh
# Flags: --non-interactive / -y  Accept all defaults, minimal prompts
#        --pack <name>           Pre-select agent pack (e.g. --pack claude-code, --pack openclaw)
#        --method <m>            Pre-select deploy method: cfn
#        --debug-in-repo         Copy local repo to /tmp instead of cloning (for local testing)

# Require bash — printf -v and other bashisms won't work in dash/sh
if [ -z "${BASH_VERSION:-}" ]; then
  echo "This script requires bash. Run with: bash $0" >&2; exit 1
fi

set -euo pipefail

# Save original dir before changing (needed for --debug-in-repo)
_ORIG_DIR="$(pwd)"
# Ensure we run from a safe CWD — avoid interference from local .env, direnv, etc.
# (--debug-in-repo will cd back after arg parsing)
cd "$HOME" 2>/dev/null || cd /tmp

export AWS_PAGER=""
export PAGER=""
aws() { command aws --no-cli-pager "$@"; }

# Persistent log file for debugging (survives script exit)
INSTALL_LOG="/tmp/lowkey-install.log"
: > "$INSTALL_LOG"

show_debug_locations() {
  echo -e "\033[1;33m  Debug info:\033[0m" >&2
  if [[ -s "${INSTALL_LOG:-}" ]]; then
    echo -e "\033[1;33m    Installer log:  ${INSTALL_LOG}\033[0m" >&2
  fi
  if [[ -n "${CLONE_DIR:-}" && "${CLONE_DIR}" == /tmp/* && -d "$CLONE_DIR" ]]; then
    echo -e "\033[1;33m    Clone dir:      ${CLONE_DIR}\033[0m" >&2
  fi
}

# Ctrl-C: kill background jobs and exit immediately
cleanup_on_interrupt() {
  echo -e "\n\033[0;31m✗ Interrupted\033[0m" >&2
  # Kill all child processes (gum, tee, etc.)
  kill -- -$$ 2>/dev/null || kill 0 2>/dev/null
  exit 130
}
trap cleanup_on_interrupt INT TERM

# Always show debug info on non-zero exit (EXIT trap is more reliable than ERR)
trap '
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo -e "\n\033[0;31m✗ Installer failed (exit code $exit_code)\033[0m" >&2
    show_debug_locations
    if [[ -z "${_TELEM_FINAL_STATE:-}" ]]; then
      # Telemetry: report failure (silently, never blocks >2s)
      _telem_install_failed "$exit_code" "${_TELEM_CURRENT_STEP:-unknown}" 2>/dev/null || true
    fi
  fi
' EXIT

# Track which step we're in (for failure attribution in telemetry)
_TELEM_CURRENT_STEP="init"

REPO_URL="https://github.com/inceptionstack/lowkey.git"
DOCS_URL="https://github.com/inceptionstack/lowkey/wiki"
# Template URL deferred: REPO_BRANCH may not be set yet at this point (set later
# during branch detection around line ~817). We use a function to resolve at call time.
TEMPLATE_RAW_URL=""  # populated by get_template_url()
get_template_url() {
  echo "https://raw.githubusercontent.com/inceptionstack/lowkey/${REPO_BRANCH:-main}/deploy/cloudformation/template.yaml"
}
SSM_DOC_NAME=""
INSTALLER_VERSION="0.5.222"

# ── Telemetry ────────────────────────────────────────────────────────────
# Fire-and-forget telemetry. Opt-out: LOWKEY_TELEMETRY=0 / DO_NOT_TRACK=1
# / ~/.lowkey/telemetry-off. 2s hard timeout, silent on every failure,
# never blocks install. Payloads documented at:
#   https://docs.lowkey.run/reference/telemetry-privacy
#   https://docs.lowkey.run/reference/telemetry-schema

# Safe no-op fallbacks first — overwritten below. Keeps install hooks
# defined under set -euo pipefail even if something in the block below
# fails to load (e.g. partial download).
_TELEM_LIB_READY=0
_TELEM_FINAL_STATE=""
_telem_install_started()    { :; }
_telem_pack_selected()      { :; }
_telem_method_selected()    { :; }
_telem_deploy_started()     { :; }
_telem_deploy_completed()   { :; }
_telem_bootstrap_completed(){ :; }
_telem_install_completed()  { :; }
_telem_install_failed()     { :; }
_telem_event()              { :; }

# ── Telemetry implementation ─────────────────────────────────────────
# All functions below are prefixed _telem_ to avoid collisions.
# Fire-and-forget, 2-second timeouts, silent on every failure.
# Opt-out: LOWKEY_TELEMETRY=0 | DO_NOT_TRACK=1 | ~/.lowkey/telemetry-off

# ── Config ──────────────────────────────────────────────────────────────
_TELEM_ENDPOINT="${LOWKEY_TELEMETRY_URL:-https://telemetry.loki.run}"
_TELEM_TIMEOUT=2          # seconds — curl connect + transfer
_TELEM_LOG="${INSTALL_LOG:-/tmp/lowkey-install.log}"
_TELEM_QUEUE="/tmp/.lowkey-telem-$$"   # per-process event queue (NDJSON)
_TELEM_ENABLED=true
_TELEM_INSTALL_ID=""
_TELEM_MACHINE_ID=""
_TELEM_SESSION_ID=""
_TELEM_T0=""              # epoch ms when install started
_TELEM_FINAL_STATE="${_TELEM_FINAL_STATE:-}"

_telem_num_or_default() {
  local value="${1:-}"
  local fallback="${2:-0}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

# ── Opt-out check ───────────────────────────────────────────────────────
_telem_init() {
  # Respect all three opt-out signals
  if [[ "${LOWKEY_TELEMETRY:-}" == "0" ]] \
     || [[ "${DO_NOT_TRACK:-}" == "1" ]] \
     || [[ -n "${HOME:-}" && -f "${HOME}/.lowkey/telemetry-off" ]]; then
    _TELEM_ENABLED=false
    return 0
  fi

  # Require curl — if missing, silently disable
  if ! command -v curl &>/dev/null; then
    _TELEM_ENABLED=false
    return 0
  fi

  # IDs — validate against schema; if we can't produce a conformant machine_id,
  # disable telemetry rather than send payloads that will 400.
  _TELEM_INSTALL_ID="$(_telem_uuid)"
  _TELEM_SESSION_ID="$(_telem_uuid)"
  _TELEM_MACHINE_ID="$(_telem_machine_id)"
  _TELEM_T0="$(_telem_epoch_ms)"

  local os_name arch_name os_ver version os_ver_re
  os_name="$(_telem_norm_os)"
  arch_name="$(_telem_norm_arch)"
  os_ver="$(_telem_norm_os_version)"
  version="$(_telem_norm_version)"
  os_ver_re='^[-A-Za-z0-9./_+ ]{1,48}$'

  if [[ -z "$_TELEM_MACHINE_ID" ]] \
     || [[ -z "$os_name" ]] \
     || [[ -z "$arch_name" ]] \
     || ! [[ "$_TELEM_INSTALL_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
     || ! [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9.+_-]*$ ]] \
     || ! [[ "$os_ver" =~ $os_ver_re ]]; then
    _TELEM_ENABLED=false
    return 0
  fi

  # Init the event queue file
  : > "$_TELEM_QUEUE" 2>/dev/null || _TELEM_ENABLED=false
}

# ── Identity ────────────────────────────────────────────────────────────
_telem_machine_id() {
  # Stable, irreversible machine fingerprint. Never transmitted raw.
  local raw=""
  if [[ -f /etc/machine-id ]]; then
    raw="$(cat /etc/machine-id 2>/dev/null || printf '')"
  elif [[ -f /var/lib/dbus/machine-id ]]; then
    raw="$(cat /var/lib/dbus/machine-id 2>/dev/null || printf '')"
  elif command -v ioreg &>/dev/null; then
    raw="$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F\" '/IOPlatformUUID/{print $4}' 2>/dev/null || printf '')"
  fi
  # Mix with hostname for extra uniqueness, hash it
  raw="${raw}:$(hostname 2>/dev/null || printf 'unknown')"
  # Validate: schema requires sha256:<64-lowercase-hex>. Empty → disable.
  local hex=""
  if command -v sha256sum &>/dev/null; then
    hex="$(printf '%s' "$raw" | sha256sum 2>/dev/null | cut -d' ' -f1 2>/dev/null || printf '')"
  elif command -v shasum &>/dev/null; then
    hex="$(printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -d' ' -f1 2>/dev/null || printf '')"
  fi
  if [[ "$hex" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'sha256:%s\n' "$hex"
  else
    printf ''
  fi
}

_telem_uuid() {
  # UUIDv4 from /dev/urandom — no external deps
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid 2>/dev/null || printf '00000000-0000-4000-8000-000000000000\n'
  elif command -v uuidgen &>/dev/null; then
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf '00000000-0000-4000-8000-000000000000\n'
  else
    # Pure bash fallback
    local hex
    hex="$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' 2>/dev/null || printf '')"
    if [[ ${#hex} -ge 32 ]]; then
      printf '%s-%s-4%s-%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:16:4}" "${hex:20:12}"
    else
      printf '00000000-0000-4000-8000-%012d\n' "$$"
    fi
  fi
}

_telem_epoch_ms() {
  # Milliseconds since epoch. Falls back to seconds * 1000.
  if date +%s%3N >/dev/null 2>&1; then
    local ms
    ms="$(_telem_num_or_default "$(date +%s%3N 2>/dev/null || printf '')" '')"
    # GNU date returns ms, but macOS date may not support %3N
    if [[ ${#ms} -ge 13 ]]; then
      printf '%s\n' "$ms"
    else
      printf '%s000\n' "$(_telem_num_or_default "$(date +%s 2>/dev/null || printf '')" 0)"
    fi
  else
    printf '%s000\n' "$(_telem_num_or_default "$(date +%s 2>/dev/null || printf '')" 0)"
  fi
}

_telem_iso() {
  # ISO 8601 UTC timestamp
  local ts
  ts="$(LC_ALL=C date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf '')"
  if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    printf '%s\n' "$ts"
  else
    printf '1970-01-01T00:00:00Z\n'
  fi
}

_telem_duration_ms() {
  # Duration since _TELEM_T0 in milliseconds
  local now start
  now="$(_telem_num_or_default "$(_telem_epoch_ms)" 0)"
  start="$(_telem_num_or_default "${_TELEM_T0:-}" 0)"
  printf '%s\n' "$(( now - start ))"
}

# ── Normalization helpers ──────────────────────────────────────────────
# Keep outputs strictly within the schema enums.
_telem_norm_os() {
  # Map raw uname -s to schema enum: linux | darwin | windows
  local s
  s="$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf 'linux')"
  case "$s" in
    darwin*)                 printf 'darwin\n' ;;
    linux*)                  printf 'linux\n' ;;
    mingw*|msys*|cygwin*|windows*) printf 'windows\n' ;;
    *)                       printf '' ;;
  esac
}

_telem_norm_arch() {
  # Map raw uname -m / hw_arch to schema enum: arm64 | x86_64
  local a
  a="$(hw_arch 2>/dev/null || uname -m 2>/dev/null || printf 'x86_64')"
  a="$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf '')"
  case "$a" in
    arm64|aarch64|armv8*|armv9*) printf 'arm64\n' ;;
    x86_64|amd64|x64)            printf 'x86_64\n' ;;
    *)                           printf '' ;;
  esac
}

_telem_norm_os_version() {
  # Schema: alnum + . _ + - space, max 48 chars.
  local v
  v="$(uname -r 2>/dev/null || printf '0.0')"
  # Strip anything not in the allowed set, then cap to 48 chars
  v="$(printf '%s' "$v" | tr -cd 'A-Za-z0-9._+\- ' 2>/dev/null || printf '0.0')"
  v="${v:0:48}"
  [[ -n "$v" ]] || v="0.0"
  printf '%s\n' "$v"
}

# Resolve the installer delivery channel for the /v1/install beacon.
# Server enum: brew | curl | dmg | msi | pkg. This describes HOW the
# installer bits got onto the machine, not what cloud deploy method the
# user chose. Default to 'curl' since install.lowkey.run is the canonical
# delivery.
_telem_resolve_install_method() {
  # CI runs of install.sh fire real beacons before the TEST_MODE guard
  # kicks in. Detecting the GitHub Actions runner environment here lets
  # dashboards filter on install_method instead of is_test (which is
  # validated but not persisted in the data lake).
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    printf 'github-actions\n'; return 0
  fi
  # Allow override via env for Homebrew/pkg distribution channels later.
  # Server enum: brew | curl | dmg | msi | pkg | github-actions.
  local m="${LOWKEY_INSTALL_CHANNEL:-}"
  m="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf '')"
  case "$m" in
    brew|curl|dmg|msi|pkg|github-actions) printf '%s\n' "$m" ;;
    *)                                    printf 'curl\n' ;;
  esac
}

# Resolve the deploy method to a catalog-compliant slug for telemetry.
# install.sh stores DEPLOY_METHOD as a numeric code (1=cfn-console, 2=cfn-cli)
# and PRESELECT_METHOD as the raw user input. Both need normalization for
# the server catalog: the client emits only `cfn`; unresolved values return
# empty so the caller omits the prop.
#
# Returns empty string when unresolved so callers can omit the prop
# (server validator drops any value not matching the enum, which pollutes
# dashboards with false "cfn" signals if we default).
_telem_resolve_method() {
  local m="${DEPLOY_METHOD:-}"
  case "$m" in
    1|2)    printf 'cfn\n'; return 0 ;;
  esac
  m="${PRESELECT_METHOD:-}"
  m="$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]' 2>/dev/null || printf '')"
  case "$m" in
    cfn|cloudformation)  printf 'cfn\n' ;;
    *)                   printf '\n' ;;  # unresolved — caller omits key
  esac
}

_telem_norm_version() {
  # Schema: ^[A-Za-z0-9][A-Za-z0-9.+_-]*$, max 32 chars
  local v="${INSTALLER_VERSION:-0.0.0}"
  v="$(printf '%s' "$v" | tr -cd 'A-Za-z0-9.+_\-' 2>/dev/null || printf '0.0.0')"
  # Ensure first char is alnum
  case "${v:0:1}" in
    [A-Za-z0-9]) : ;;
    *) v="0.0.0" ;;
  esac
  v="${v:0:32}"
  [[ -n "$v" ]] || v="0.0.0"
  printf '%s\n' "$v"
}

# ── Event recording (local queue, no network) ──────────────────────────
_telem_event() {
  # Usage: _telem_event "event.name" '{"key":"value"}'
  #
  # Spec note: Event.props is REQUIRED (required: ["t","name","props"] in
  # $defs/Event). Per-event `oneOf` branches all permit `{}`; an empty object
  # is valid. Always emit `props`, defaulting to {} when no props are given.
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  local name="${1:-unknown}"
  local props="${2:-}"
  local ts
  ts="$(_telem_iso)"

  # Event.props is REQUIRED per $defs/Event in telemetry-v1.schema.json
  # (required: ["t", "name", "props"]). Always emit it, defaulting to {}
  # when the caller passes no props or an empty body. An empty object is
  # valid against the Event.props schema (no minProperties constraint).
  if [[ -z "$props" || "$props" == "{}" ]]; then
    props='{}'
  fi
  printf '{"t":"%s","name":"%s","props":%s}\n' "$ts" "$name" "$props" \
    >> "$_TELEM_QUEUE" 2>/dev/null || true
}

# ── Network: fire-and-forget POST ──────────────────────────────────────
_telem_post() {
  # Usage: _telem_post "/v1/install" '{"json":"body"}'
  # Runs curl in the background. Never blocks. Never fails visibly.
  # Logs HTTP status + ms latency to $_TELEM_LOG so drift can be diagnosed
  # locally without breaking user-visible behavior.
  local path="${1:-}" body="${2:-}"
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  (
    command curl -sSL -X POST \
      "${_TELEM_ENDPOINT}${path}" \
      -H "Content-Type: application/json" \
      --connect-timeout "$_TELEM_TIMEOUT" \
      --max-time "$_TELEM_TIMEOUT" \
      -d "$body" \
      -o /dev/null \
      -w "telemetry ${path} http=%{http_code} time=%{time_total}s\n" \
      </dev/null \
      2>>"$_TELEM_LOG" \
      | tee -a "$_TELEM_LOG" >/dev/null || true
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# Validate a string against the spec's Ident regex.
# Returns the value if it matches, else empty.
_telem_ident() {
  local v="${1:-}"
  [[ "$v" =~ ^[A-Za-z][A-Za-z0-9_.:-]{0,63}$ ]] && printf '%s' "$v"
}

# ── High-level: install beacon (/v1/install) ────────────────────────────
_telem_send_install_beacon() {
  # Usage: _telem_send_install_beacon "completed" [duration_ms] [failure_step] [failure_class]
  #
  # Spec note (openapi-spec.json InstallEnvelope):
  # failure_step and failure_class are NOT nullable — they must be OMITTED
  # entirely unless outcome=failed AND the value passes the Ident regex.
  # Previous code emitted "null" which a strict OpenAPI 3.1 validator rejects.
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  local outcome="${1:-started}"
  local duration_ms
  local failure_step=""
  local failure_class=""
  duration_ms="$(_telem_num_or_default "${2:-0}" 0)"

  # Only include failure fields when outcome=failed AND they pass Ident regex.
  if [[ "$outcome" == "failed" ]]; then
    failure_step="$(_telem_ident "${3:-}")"
    failure_class="$(_telem_ident "${4:-}")"
  fi

  local os_name arch_name os_ver install_method
  os_name="$(_telem_norm_os)"
  arch_name="$(_telem_norm_arch)"
  os_ver="$(_telem_norm_os_version)"
  install_method="$(_telem_resolve_install_method)"

  # Build JSON with failure_step / failure_class OMITTED when empty.
  local fs_json="" fc_json=""
  [[ -n "$failure_step"  ]] && fs_json=",\"failure_step\":\"${failure_step}\""
  [[ -n "$failure_class" ]] && fc_json=",\"failure_class\":\"${failure_class}\""

  # account_prefix: first 5 digits of AWS account ID (omitted if unavailable)
  local ap_json=""
  local ap="$(_telem_account_prefix "${ACCOUNT_ID:-}")"
  [[ -n "$ap" ]] && ap_json=",\"account_prefix\":\"${ap}\""

  local body
  body=$(cat <<EOF
{"schema":"lowkey.install.v1","sent_at":"$(_telem_iso)","install_id":"${_TELEM_INSTALL_ID}","machine_id":"${_TELEM_MACHINE_ID}","agent":{"version":"$(_telem_norm_version)","channel":"stable","os":"${os_name}","arch":"${arch_name}","os_version":"${os_ver}"},"install_method":"${install_method}","outcome":"${outcome}","duration_ms":${duration_ms},"is_test":${TEST_MODE:-false},"account_rename_enabled":${AUTO_RENAME_ACCOUNT:-false}${ap_json}${fs_json}${fc_json}}
EOF
  )
  _telem_post "/v1/install" "$body"
}

# ── High-level: flush queued events (/v1/ingest) ───────────────────────
_telem_flush() {
  # Backend catalog was expanded 2026-04-27 to accept install.* names.
  # Flush all queued events as one batch. Called at install end.
  [[ "$_TELEM_ENABLED" == "true" ]] || return 0
  [[ -s "$_TELEM_QUEUE" ]] || return 0   # nothing to send

  local os_name arch_name os_ver events
  local queue_copy
  queue_copy="$(cat "$_TELEM_QUEUE" 2>/dev/null || printf '')"
  rm -f "$_TELEM_QUEUE" 2>/dev/null || true

  [[ -n "$queue_copy" ]] || return 0

  os_name="$(_telem_norm_os)"
  arch_name="$(_telem_norm_arch)"
  os_ver="$(_telem_norm_os_version)"

  # Build the events array from NDJSON lines
  events="["
  local first=true line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$first" == "true" ]]; then first=false; else events+=","; fi
    events+="$line"
  done <<< "$queue_copy"
  events+="]"

  local body
  body=$(cat <<EOF
{
  "schema": "lowkey.telemetry.v1",
  "sent_at": "$(_telem_iso)",
  "agent": {
    "version": "$(_telem_norm_version)",
    "channel": "stable",
    "os": "${os_name}",
    "arch": "${arch_name}",
    "os_version": "${os_ver}"
  },
  "machine_id": "${_TELEM_MACHINE_ID}",
  "install_id": "${_TELEM_INSTALL_ID}",
  "session_id": "${_TELEM_SESSION_ID}",
  "is_test": ${TEST_MODE:-false},
  "events": ${events}
}
EOF
  )

  _telem_post "/v1/ingest" "$body"
  return 0
}

# ── Convenience: record common installer events ────────────────────────
#
# ⚠ IMPORTANT — only these 21 event names are in the server catalog
# (see https://docs.lowkey.run/reference/telemetry-schema and the OpenAPI at
# https://lowkey.run/api/telemetry-v1.openapi.yaml). Unknown event names and
# unwhitelisted props are silently dropped server-side. We do NOT emit
# install.started / install.completed / install.failed as catalog events —
# those are captured by the /v1/install beacon outcome= field instead.
#
# Props are built via _telem_kv so keys with empty or invalid values are
# omitted, rather than sending "unknown" strings that the server drops.

# Build a single "k":"v" pair if value is non-empty; otherwise print nothing.
# Quotes and special JSON chars are NOT escaped because installer values are
# bounded (enums, regex-validated). Use only for controlled inputs.
_telem_kv() {
  local k="$1" v="$2"
  [[ -n "$v" ]] || return 0
  printf '"%s":"%s"' "$k" "$v"
}

_telem_kv_num() {
  local k="$1" v="$2"
  [[ -n "$v" ]] || return 0
  # only emit if purely numeric
  [[ "$v" =~ ^[0-9]+$ ]] || return 0
  printf '"%s":%s' "$k" "$v"
}

# Join non-empty pairs with commas into a JSON object body.
_telem_props() {
  local body="" pair
  for pair in "$@"; do
    [[ -z "$pair" ]] && continue
    [[ -z "$body" ]] && body="$pair" || body="$body,$pair"
  done
  printf '{%s}' "$body"
}

# Return $1 only if it matches AWS region pattern, else empty.
_telem_aws_region() {
  local v="${1:-}"
  [[ "$v" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]{1,2}[a-z]?$ ]] && printf '%s' "$v"
}

# Return $1 only if it matches AWS 12-digit account ID pattern, else empty.
_telem_account_prefix() {
  local v="${1:-}"
  [[ "$v" =~ ^[0-9]{12}$ ]] && printf '%s' "${v:0:5}"
}

# Return $1 only if it's a valid InstallPack enum value, else empty.
_telem_pack() {
  local v="${1:-}"
  case "$v" in
    builder|personal-assistant|account-assistant|essential|optional\
    |personal_assistant|account_assistant|openclaw|claude-code|codex-cli\
    |kiro-cli|hermes|roundhouse|kirocrew)
      printf '%s' "$v" ;;
  esac
}

_telem_profile() {
  local v="${1:-}"
  case "$v" in
    builder|personal_assistant|account_assistant|personal-assistant|account-assistant)
      printf '%s' "$v" ;;
  esac
}

# Clamp to [0,3600000] (spec max for install.deploy_completed.duration_ms).
_telem_clamp_duration_ms() {
  local v="${1:-0}"
  [[ "$v" =~ ^[0-9]+$ ]] || { printf '0'; return 0; }
  (( v > 3600000 )) && v=3600000
  printf '%s' "$v"
}

# Install started: beacon only, no catalog event (install.started is NOT in
# the server catalog and would be silently dropped from /v1/ingest).
_telem_install_started() {
  _telem_send_install_beacon "started"
}

_telem_pack_selected() {
  local props
  props="$(_telem_props \
    "$(_telem_kv pack "$(_telem_pack "${PACK_NAME:-}")")" \
    "$(_telem_kv profile "$(_telem_profile "${PROFILE_NAME:-}")")")"
  _telem_event "install.pack_selected" "$props"
}

_telem_method_selected() {
  local props
  props="$(_telem_props \
    "$(_telem_kv method "$(_telem_resolve_method)")" \
    "$(_telem_kv region "$(_telem_aws_region "${DEPLOY_REGION:-}")")")"
  _telem_event "install.method_selected" "$props"
}

_telem_deploy_started() {
  local props
  props="$(_telem_props \
    "$(_telem_kv method "$(_telem_resolve_method)")" \
    "$(_telem_kv region "$(_telem_aws_region "${DEPLOY_REGION:-}")")" \
    "$(_telem_kv pack "$(_telem_pack "${PACK_NAME:-}")")")"
  _telem_event "install.deploy_started" "$props"
}

_telem_deploy_completed() {
  local dur
  dur="$(_telem_clamp_duration_ms "$(_telem_duration_ms)")"
  local props
  props="$(_telem_props \
    "$(_telem_kv method "$(_telem_resolve_method)")" \
    "$(_telem_kv_num duration_ms "$dur")")"
  _telem_event "install.deploy_completed" "$props"
}

_telem_bootstrap_completed() {
  local props
  props="$(_telem_props \
    "$(_telem_kv account_prefix "$(_telem_account_prefix "${ACCOUNT_ID:-}")")")"
  _telem_event "install.bootstrap_completed" "$props"
}

# Install completed: beacon only (install.completed NOT in catalog — would be dropped).
_telem_install_completed() {
  [[ -z "${_TELEM_FINAL_STATE:-}" ]] || return 0
  _TELEM_FINAL_STATE="completed"
  local dur
  dur="$(_telem_duration_ms)"
  _telem_send_install_beacon "completed" "$dur"
  _telem_flush
}

# Install failed: beacon only. failure_step is normalized to the spec's Ident
# regex (^[A-Za-z][A-Za-z0-9_.:-]{0,63}$); anything that doesn't conform is
# sanitized to "unknown_step".
_telem_install_failed() {
  [[ -z "${_TELEM_FINAL_STATE:-}" ]] || return 0
  _TELEM_FINAL_STATE="failed"
  local exit_code="${1:-1}"
  local failure_step="${2:-unknown_step}"
  [[ "$failure_step" =~ ^[A-Za-z][A-Za-z0-9_.:-]{0,63}$ ]] || failure_step="unknown_step"
  local dur
  dur="$(_telem_duration_ms)"
  _telem_send_install_beacon "failed" "$dur" "$failure_step" "exit_${exit_code}"
  _telem_flush
}

# ── Auto-init on source ────────────────────────────────────────────────
_telem_init
_TELEM_LIB_READY=1

# --non-interactive / --yes / -y: accept all defaults, minimal prompts
# --pack <name>: pre-select agent pack
# --method <m>: pre-select deploy method (cfn)
# --profile <p>: pre-select permission profile (builder, account_assistant, personal_assistant)
# --simple / --advanced: pre-select install mode
# --test: mark this invocation as a test (no AWS deploy, telemetry tagged is_test)
AUTO_YES=false
PRESELECT_PACK=""
PRESELECT_METHOD=""
TROIKA_PRIMARY=""      # --primary flag: first horse (openclaw | hermes)
TROIKA_DAILY_DRIVER="" # --daily-driver flag: auto-launch agent
TROIKA_CODEX_MODEL=""  # --codex-model flag: Bedrock model for Codex CLI
PRESELECT_PROFILE=""
INSTALL_MODE=""  # "simple" or "advanced", empty = ask
DEBUG_IN_REPO=false
TEST_MODE=false
AUTO_RENAME_ACCOUNT=false
DISABLE_ACCOUNT_RENAME=false
WEBUI_EMAIL=""
WEBUI_NO_AUTH=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive|--yes|-y) AUTO_YES=true; shift ;;
    --simple)   INSTALL_MODE="simple"; shift ;;
    --advanced) INSTALL_MODE="advanced"; shift ;;
    --pack)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --pack requires a pack name (e.g. --pack openclaw, --pack claude-code)" >&2
        exit 1
      fi
      PRESELECT_PACK="$2"; shift 2 ;;
    --method)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --method requires a value (cfn)" >&2
        exit 1
      fi
      PRESELECT_METHOD="$2"; shift 2 ;;
    --profile)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --profile requires a value (builder, account_assistant, personal_assistant)" >&2
        exit 1
      fi
      PRESELECT_PROFILE="$2"; shift 2 ;;
    --kiro-from-secret)
      # Secrets Manager id/arn whose SecretString is the Kiro API key.
      # Only the secret *reference* passes through CloudFormation state; the raw key
      # is resolved on the instance at install time via its IAM role.
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --kiro-from-secret requires a Secrets Manager id or arn" >&2
        exit 1
      fi
      KIRO_FROM_SECRET="$2"; shift 2 ;;
    --telegram-bot-token)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --telegram-bot-token requires a token value" >&2
        exit 1
      fi
      TELEGRAM_BOT_TOKEN_RAW="$2"; shift 2 ;;
    --telegram-bot-token-secret)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --telegram-bot-token-secret requires a Secrets Manager id or arn" >&2
        exit 1
      fi
      TELEGRAM_BOT_TOKEN_SECRET="$2"; shift 2 ;;
    --telegram-user)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --telegram-user requires a Telegram username" >&2
        exit 1
      fi
      TELEGRAM_USER="$2"; shift 2 ;;
    --primary)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --primary requires a value (openclaw, hermes)" >&2
        exit 1
      fi
      TROIKA_PRIMARY="$2"; shift 2 ;;
    --daily-driver)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --daily-driver requires a value (openclaw, hermes, claude-code, codex-cli, none)" >&2
        exit 1
      fi
      TROIKA_DAILY_DRIVER="$2"; shift 2 ;;
    --codex-model)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --codex-model requires a Bedrock model ID" >&2
        exit 1
      fi
      TROIKA_CODEX_MODEL="$2"; shift 2 ;;
    --webui-email)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo -e "\033[0;31m✗\033[0m --webui-email requires an email address" >&2
        exit 1
      fi
      WEBUI_EMAIL="$2"; shift 2 ;;
    --webui-no-auth) WEBUI_NO_AUTH=true; shift ;;
    --debug-in-repo) DEBUG_IN_REPO=true; shift ;;
    --test|--dry-run) TEST_MODE=true; shift ;;
    --auto-rename-account-enabled) AUTO_RENAME_ACCOUNT=true; shift ;;
    --disable-account-rename)      DISABLE_ACCOUNT_RENAME=true; shift ;;
    --help|-h)
      cat <<'USAGE'
Usage: install.sh [OPTIONS]

Deploy a self-hosted AI coding agent to your AWS account.

Options:
  -y, --non-interactive, --yes   Accept defaults; skip prompts
  --simple                       Force simple install mode
  --advanced                     Force advanced install mode
  --pack <name>                  Agent pack (openclaw, claude-code, codex-cli,
                                 kiro-cli, hermes, roundhouse, troika, kirocrew)
  --profile <name>               Permission profile (builder,
                                 account_assistant, personal_assistant)
  --method <cfn>                 Deploy method (default: cfn)
  --primary <name>               Troika: first horse (openclaw | hermes;
                                 default openclaw)
  --daily-driver <name>          Troika: agent to auto-launch on SSM login
                                 (<primary> | claude-code | codex-cli | none;
                                 default = primary)
  --codex-model <id>             Troika: Bedrock Mantle model for Codex CLI
                                 (default openai.gpt-5.5)
  --kiro-from-secret <id|arn>    Secrets Manager id/arn for Kiro API key
                                 (kiro-cli headless mode)
  --telegram-bot-token <token>  Telegram bot token (roundhouse pack;
                                 saved to Secrets Manager automatically)
  --telegram-bot-token-secret <id|arn>
                                 Secrets Manager id/arn for Telegram bot token
                                 (roundhouse pack, advanced/pre-created)
  --telegram-user <username>     Telegram username for bot pairing
                                 (roundhouse pack, without @)
  --webui-email <email>          Email for the initial WebUI user
  --webui-no-auth                Skip Cognito WebUI authentication setup
  --debug-in-repo                Dev-only: run installer from cwd
  --test, --dry-run              Run installer end-to-end without
                                 provisioning AWS resources. Telemetry
                                 hits from this invocation are tagged
                                 is_test and excluded from dashboard stats.
  --auto-rename-account-enabled  Enable auto-rename of AWS account to
                                 Lowkey-<name> in headless (-y) mode
  --disable-account-rename       Skip account rename entirely
  -h, --help                     Show this help and exit

Examples:
  curl -sfL install.lowkey.run | bash
  curl -sfL install.lowkey.run | bash -s -- -y --pack openclaw --profile builder
  curl -sfL install.lowkey.run | bash -s -- -y --pack kiro-cli --profile builder \
      --kiro-from-secret /lowkey/kiro-api-key

  # Test install (no AWS resources created, not counted in install stats):
  curl -sfL "install.lowkey.run?test" | bash -s -- --test

Docs: https://github.com/inceptionstack/lowkey/tree/main/docs
USAGE
      exit 0 ;;
    *) shift ;;
  esac
done

# If --debug-in-repo, go back to the original directory (before cd $HOME)
if [[ "$DEBUG_IN_REPO" == "true" ]]; then
  cd "$_ORIG_DIR"
fi
SCRIPT_DIR="$_ORIG_DIR"

# Debug logging — writes to install log only, never to terminal
dbg() {
  [[ "$DEBUG_IN_REPO" == "true" ]] && echo "[DBG] $*" >> "$INSTALL_LOG"
  return 0
}

# Deploy method constants
DEPLOY_CFN_CONSOLE=1
DEPLOY_CFN_CLI=2
# Stamped at release; fall back to git info at runtime
INSTALLER_COMMIT="${INSTALLER_COMMIT:-$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"
INSTALLER_DATE="${INSTALLER_DATE:-$(d=$(git -C "$SCRIPT_DIR" log -1 --format='%ci' 2>/dev/null | cut -d' ' -f1,2); echo "${d:-unknown}")}"
# Only detect branch from git if we're inside the actual lowkey repo (not a random parent repo)
if [[ -z "${REPO_BRANCH:-}" ]]; then
  if [[ -f "$SCRIPT_DIR/packs/registry.yaml" ]]; then
    REPO_BRANCH="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  else
    REPO_BRANCH="main"
  fi
fi
[[ "$REPO_BRANCH" == "HEAD" ]] && REPO_BRANCH="main"

# Detect AWS CloudShell (limited ~1GB home dir, use /tmp for large files)
IS_CLOUDSHELL=false
if [[ -n "${AWS_EXECUTION_ENV:-}" && "${AWS_EXECUTION_ENV}" == *"CloudShell"* ]] || [[ -d /home/cloudshell-user && "$(whoami)" == "cloudshell-user" ]]; then
  IS_CLOUDSHELL=true
fi

# ============================================================================
# gum — UI toolkit (installed to /tmp, no root required)
# ============================================================================
GUM=""  # set by install_gum — required, script fails without it
GUM_VERSION="0.14.5"  # fallback version

# ── Shared platform detection ────────────────────────────────────────────────
# Sets DETECTED_OS and DETECTED_ARCH (x86_64/arm64 — gum, generic).
DETECTED_OS=""
DETECTED_ARCH=""

# Get real hardware arch (uname -m and sysctl hw.machine lie under Rosetta)
hw_arch() {
  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" == "1" ]]; then
    echo "arm64"
  else
    uname -m
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) DETECTED_OS="Darwin" ;;
    Linux)  DETECTED_OS="Linux"  ;;
    *)      DETECTED_OS=""; return 1 ;;
  esac
  case "$(hw_arch)" in
    x86_64|amd64)  DETECTED_ARCH="x86_64" ;;
    aarch64|arm64) DETECTED_ARCH="arm64" ;;
    *)             DETECTED_ARCH=""; return 1 ;;
  esac
}

install_gum() {
  # Already installed?
  if command -v gum &>/dev/null; then
    GUM="gum"; return 0
  fi
  local gum_bin="/tmp/gum-bin/gum"
  if [[ -x "$gum_bin" ]]; then
    GUM="$gum_bin"; return 0
  fi

  detect_platform || fail "Unsupported OS/architecture for gum: $(uname -s)/$(uname -m)"
  local os="$DETECTED_OS" arch="$DETECTED_ARCH"

  # Try to get latest version from GitHub API, fall back to known good
  local version
  version=$(curl -sf https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/' || echo "")
  [[ -z "$version" ]] && version="$GUM_VERSION"

  local url="https://github.com/charmbracelet/gum/releases/download/v${version}/gum_${version}_${os}_${arch}.tar.gz"
  mkdir -p /tmp/gum-bin
  if curl -sfL "$url" | tar xz --strip-components=1 -C /tmp/gum-bin 2>/dev/null; then
    chmod +x "$gum_bin"
    GUM="$gum_bin"
  else
    fail "Could not install gum. Check network connectivity and try again."
  fi
}

# ============================================================================
# UI helpers
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
MAGENTA='\033[0;35m'; WHITE='\033[1;37m'

info()  { echo -e "  ${BLUE}▸${NC} $1"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()  { echo -e "  ${RED}✗${NC} $1"; show_debug_locations; exit 1; }

# ── Elapsed time formatting ──────────────────────────────────────────────────
elapsed_fmt() {
  local secs=$1
  if [[ $secs -lt 60 ]]; then
    printf '%ds' "$secs"
  else
    printf '%dm %ds' "$((secs / 60))" "$((secs % 60))"
  fi
}

# ── Step progress tracker ────────────────────────────────────────────────────
STEP_NUM=0
TOTAL_STEPS=7
STEP_NAMES=()

step() {
  STEP_NUM=$((STEP_NUM + 1))
  STEP_NAMES+=("$1")
  echo ""
  $GUM style --foreground 117 --bold --border double --border-foreground 240 \
    --padding "0 2" --margin "0 2" "[${STEP_NUM}/${TOTAL_STEPS}] $1"
  echo ""
}

prompt() {
  local text="$1" var="$2" default="${3:-}"
  if [[ "$AUTO_YES" == true && -n "$default" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local value
  _gum_or_die value $GUM input --header "$text" --value "$default" --placeholder "$text" || value="$default"
  printf -v "$var" '%s' "${value:-$default}"
}

prompt_secret() {
  local text="$1" var="$2" default="${3:-}"
  if [[ "$AUTO_YES" == true && -n "$default" ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local value
  _gum_or_die value $GUM input --password --header "$text" --placeholder "$text" || value="$default"
  printf -v "$var" '%s' "${value:-$default}"
}

confirm() {
  local text="$1" default="${2:-default_no}"
  if [[ "$AUTO_YES" == true ]]; then return 0; fi
  local rc=0
  if [[ "$default" == "default_yes" ]]; then
    $GUM confirm --default=yes "$text" < /dev/tty || rc=$?
  else
    $GUM confirm "$text" < /dev/tty || rc=$?
  fi
  [[ $rc -eq 130 ]] && { echo ""; cleanup_on_interrupt; }
  return $rc
}

toggle() {
  local text="$1" var="$2" default="${3:-true}"
  if [[ "$AUTO_YES" == true ]]; then
    printf -v "$var" '%s' "$default"
    return
  fi
  local rc=0
  if [[ "$default" == "true" ]]; then
    $GUM confirm --default=yes "  $text" < /dev/tty || rc=$?
  else
    $GUM confirm "  $text" < /dev/tty || rc=$?
  fi
  [[ $rc -eq 0 ]] && printf -v "$var" '%s' "true" || printf -v "$var" '%s' "false"
}

require_cmd() { command -v "$1" &>/dev/null || fail "$2"; }

# Run a gum command; if it exits with 130 (SIGINT/Ctrl-C), abort the installer.
# Usage: _gum_or_die result_var gum_command [args...]
#   On success: sets result_var to gum's stdout, returns 0
#   On Ctrl-C (exit 130): exits the installer immediately
#   On other failure (Escape, etc): returns 1 (caller handles fallback)
_gum_or_die() {
  local __var="$1"; shift
  local __out __rc=0
  __out=$("$@" < /dev/tty) || __rc=$?
  if [[ $__rc -eq 130 ]]; then
    echo ""
    cleanup_on_interrupt
  fi
  printf -v "$__var" '%s' "$__out"
  return $__rc
}

# Confirm or exit cleanly
confirm_or_abort() { confirm "$@" || { echo "Aborted."; exit 0; }; }

# Extract a key from JSON on stdin
json_field() { jq -r ".$1" 2>/dev/null; }

# URL-encode a string
url_encode() { jq -rn --arg s "$1" '$s | @uri'; }

# ── Reusable helpers (DRY) ──────────────────────────────────────────────────

# Animate a gum spinner with label for N seconds.
# Usage: animate_spinner <seconds> <label>
animate_spinner() {
  local total_secs="$1" label="$2"
  $GUM spin --spinner dot --title "  $label" -- sleep "$total_secs" || true
}

# Show SSM manual connection help
show_ssm_help() {
  local instance_id="$1"
  echo "  Connect manually: $(ssm_connect_cmd "$instance_id")"
  echo "  Then check: cat /var/log/loki-bootstrap.log"
}

# Copy text to clipboard (tries pbcopy, xclip, xsel)
copy_to_clipboard() {
  local text="$1"
  if echo -n "$text" | pbcopy 2>/dev/null; then return 0
  elif echo -n "$text" | xclip -selection clipboard 2>/dev/null; then return 0
  elif echo -n "$text" | xsel --clipboard 2>/dev/null; then return 0
  fi
  return 1
}

# Safely remove a temp directory after confirmation
# Usage: safe_cleanup_dir <path> <label> <allowed_pattern...>
safe_cleanup_dir() {
  local dir="$1" label="$2"; shift 2
  [[ -z "${dir:-}" || ! -d "$dir" ]] && return 0
  if confirm "Remove ${label} (${dir})?" ; then
    local pattern ok_to_remove=false
    for pattern in "$@"; do
      # shellcheck disable=SC2053  # intentional glob matching
      [[ "$dir" == $pattern ]] && ok_to_remove=true
    done
    if $ok_to_remove; then
      rm -rf "$dir" 2>/dev/null
      ok "Cleaned up ${dir}"
    else
      warn "Unexpected path — skipping automatic removal: ${dir}"
    fi
  else
    info "${label} kept at ${dir}"
  fi
}

# Verify AWS credentials with specific error messages.
# On success, sets ACCOUNT_ID and CALLER_ARN from a single STS call.
verify_aws_credentials() {
  local sts_output sts_rc=0
  sts_output=$(aws sts get-caller-identity --output json 2>&1) || sts_rc=$?
  if [[ $sts_rc -ne 0 ]]; then
    echo ""
    $GUM style --border rounded --border-foreground 196 --padding "1 2" --margin "0 2"       "✗ AWS credentials check failed"       ""       "  Not logged in or insufficient permissions."       ""       "  Quick fixes:"       "    • aws sso login              (if using SSO)"       "    • aws configure              (set up credentials)"       "    • aws sts get-caller-identity (verify who you are)"       ""       "  Or try AWS CloudShell (no setup needed):"       "  https://console.aws.amazon.com/cloudshell"
    echo ""
    fail "Cannot continue without valid AWS credentials."
  fi
  # Extract account and ARN from the single STS response
  ACCOUNT_ID=$(echo "$sts_output" | json_field Account) \
    || fail "Could not determine AWS account ID"
  CALLER_ARN=$(echo "$sts_output" | json_field Arn) \
    || fail "Could not determine caller ARN"
}

# ============================================================================
# Reusable AWS helpers
# ============================================================================

# Create a private S3 bucket with versioning + KMS encryption
create_s3_bucket() {
  local bucket="$1" region="$2"
  if aws s3api head-bucket --bucket "$bucket" --region "$region" 2>/dev/null; then
    ok "Bucket exists: ${bucket}"; return 0
  fi
  info "Creating bucket: ${bucket}"
  if [[ "$region" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$bucket" --region "$region" >/dev/null
  else
    aws s3api create-bucket --bucket "$bucket" --region "$region" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$bucket" \
    --versioning-configuration Status=Enabled --region "$region"
  aws s3api put-bucket-encryption --bucket "$bucket" --region "$region" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
  aws s3api put-public-access-block --bucket "$bucket" --region "$region" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  ok "Bucket created: ${bucket}"
}

# Try to open a URL in the default browser
open_url() {
  local url="$1"
  for cmd in open xdg-open start; do
    command -v "$cmd" &>/dev/null && "$cmd" "$url" 2>/dev/null && return 0
  done
  [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v explorer.exe &>/dev/null \
    && explorer.exe "$url" 2>/dev/null && return 0
  return 1
}

# Run a command, capture output; on failure show full log and exit.
# Sets _RUN_LOG to the temp file path so caller can grep it.
run_or_fail() {
  local label="$1"; shift
  dbg "run_or_fail: $label -> $*"
  _RUN_LOG=$(mktemp)

  # gum spin runs external commands directly — simple and reliable.
  # Do NOT pass bash functions here; call them directly instead.
  local rc=0
  $GUM spin --spinner dot --title "  $label" -- \
    bash -c '"$@" > "'"$_RUN_LOG"'" 2>&1' _ "$@" \
    || rc=$?

  # Append to persistent install log for debugging
  { echo "=== ${label} (rc=$rc) ==="; cat "$_RUN_LOG"; echo ""; } >> "$INSTALL_LOG" 2>/dev/null

  if [[ $rc -ne 0 ]]; then
    warn "${label} failed:"; cat "$_RUN_LOG"; rm -f "$_RUN_LOG"
    fail "${label} exited with code $rc"
  fi
}

# Build the SSM connect command for a given instance (or placeholder)
ssm_connect_cmd() {
  local target="${1:-\$INSTANCE_ID}"
  local cmd="aws ssm start-session --target ${target}"
  local doc_name="${SSM_DOC_NAME:-Lowkey-Session-${PACK_NAME:-openclaw}}"
  if [[ -n "$doc_name" ]] && aws ssm describe-document --name "$doc_name" --region "$DEPLOY_REGION" &>/dev/null 2>&1; then
    cmd+=" --document-name ${doc_name}"
  fi
  cmd+=" --region ${DEPLOY_REGION}"
  echo "$cmd"
}

# ============================================================================
# Phase: Banner
# ============================================================================
show_banner() {
  # Resolve commit/date from git if running from a clone, otherwise use stamped values
  local commit="$INSTALLER_COMMIT" date="$INSTALLER_DATE"
  if [[ "$commit" == "dev" ]] && command -v git &>/dev/null; then
    if [[ -d "$SCRIPT_DIR/.git" ]]; then
      commit=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      date=$(git -C "$SCRIPT_DIR" log -1 --format='%ci' 2>/dev/null | cut -d: -f1,2 || echo "unknown")
    fi
  fi
  local version_line="v${INSTALLER_VERSION}  ${commit}  ${date}"

  echo ""
  echo ""
  echo -e "  ${CYAN}    __                    __              ${NC}"
  echo -e "  ${CYAN}   / /   ____  _      __ / /__ ___   __  __${NC}"
  echo -e "  ${BLUE}  / /   / __ \\| | /| / // //_// _ \\ / / / /${NC}"
  echo -e "  ${BLUE} / /___/ /_/ /| |/ |/ // ,<  /  __// /_/ / ${NC}"
  echo -e "  ${MAGENTA}/_____/\\____/ |__/|__//_/|_| \\___/ \\__, /  ${NC}"
  echo -e "  ${MAGENTA}                                   /____/   ${NC}"
  echo ""
  echo -e "  ${DIM}AWS Agent Installer  ${version_line}${NC}"
  echo ""
  if [[ "$AUTO_YES" == true ]]; then
    local auto_msg="Running in non-interactive mode"
    [[ -n "${PRESELECT_PACK}" ]] && auto_msg+=", pack: ${PRESELECT_PACK}"
    [[ -n "${PRESELECT_METHOD}" ]] && auto_msg+=", method: ${PRESELECT_METHOD}"
    [[ -n "${PRESELECT_PROFILE}" ]] && auto_msg+=", profile: ${PRESELECT_PROFILE}"
    info "$auto_msg"
  fi
}

# ── Welcome & prerequisites prompt ───────────────────────────────────────────
show_welcome() {
  if [[ "$AUTO_YES" == true ]]; then return 0; fi

  echo ""
  $GUM style --border rounded --border-foreground 39 --padding "1 2" --margin "0 2"     "🚀  Lowkey Agent Installer"     ""     "You'll need:"     "  • AWS CLI logged in with admin access"     "  • A sandbox AWS account (recommended)"     ""     "Easiest: run this from AWS CloudShell"     "https://console.aws.amazon.com/cloudshell"
  echo ""

  local choice
  _gum_or_die choice $GUM choose --header "  Ready?" "Continue" "Learn more" "Quit" || choice="Continue"
  case "$choice" in
    "Learn more")
      _show_prerequisites_detail
      local choice2
      _gum_or_die choice2 $GUM choose --header "  Ready?" "Continue" "Quit" || choice2="Continue"
      if [[ "$choice2" == "Quit" ]]; then
        info "No resources created. Re-run when ready."
        exit 0
      fi
      ;;
    "Quit")
      info "No resources created. Re-run when ready."
      exit 0
      ;;
  esac
}

_show_prerequisites_detail() {
  echo ""
  $GUM style --border rounded --border-foreground 39 --padding "1 2" --margin "0 2"     "Prerequisites"     ""     "1. AWS Account (sandbox/dev recommended)"     "   https://aws.amazon.com/free"     ""     "2. Admin credentials — any of these work:"     "   • AWS CloudShell (zero setup)"     "     https://console.aws.amazon.com/cloudshell"     "   • SSO login: aws configure sso && aws sso login"     "     https://docs.aws.amazon.com/cli/latest/userguide/sso"     "   • IAM user keys: aws configure"     "     https://docs.aws.amazon.com/IAM/latest/UserGuide/"     ""     "3. Permissions (admin role covers all):"     "   CloudFormation, EC2, IAM, SSM, SecretsManager"     ""     "4. Supported regions: any with Bedrock model access"     "   https://docs.aws.amazon.com/bedrock/latest/userguide/"
  echo ""
}


# Minimum AWS CLI version — aws account subcommand requires 2.8+.
MIN_AWS_CLI_MAJOR=2
MIN_AWS_CLI_MINOR=8
_AWS_CLI_MAJOR=""
_AWS_CLI_MINOR=""

# Parse AWS CLI version string → sets _AWS_CLI_MAJOR, _AWS_CLI_MINOR.
_parse_aws_cli_version() {
  local ver_str
  ver_str=$(aws --version 2>&1 | head -1)
  # "aws-cli/2.33.15 Python/..." → "2.33.15"
  local ver
  ver=$(printf '%s' "$ver_str" | sed -n 's|^aws-cli/\([0-9][0-9.]*\).*|\1|p')
  _AWS_CLI_MAJOR=$(printf '%s' "$ver" | cut -d. -f1)
  _AWS_CLI_MINOR=$(printf '%s' "$ver" | cut -d. -f2)
}

# Check if current AWS CLI meets the minimum version.
_aws_cli_is_current() {
  _parse_aws_cli_version
  [[ -n "$_AWS_CLI_MAJOR" && -n "$_AWS_CLI_MINOR" ]] || return 1
  if [[ $_AWS_CLI_MAJOR -gt $MIN_AWS_CLI_MAJOR ]]; then return 0; fi
  if [[ $_AWS_CLI_MAJOR -eq $MIN_AWS_CLI_MAJOR && $_AWS_CLI_MINOR -ge $MIN_AWS_CLI_MINOR ]]; then return 0; fi
  return 1
}

# Update AWS CLI v2 in-place. Supports Linux and macOS.
_update_aws_cli() {
  local os
  os=$(uname -s)
  info "Updating AWS CLI..."
  case "$os" in
    Linux)
      local tmp_dir
      tmp_dir=$(mktemp -d)
      if curl -sfL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmp_dir/awscliv2.zip"; then
        ( cd "$tmp_dir" && unzip -oq awscliv2.zip && sudo ./aws/install --update 2>/dev/null ) || {
          # Try without sudo (user installs, CloudShell)
          ( cd "$tmp_dir" && ./aws/install --update --install-dir "$HOME/.local/aws-cli" --bin-dir "$HOME/.local/bin" 2>/dev/null ) || true
        }
      fi
      rm -rf "$tmp_dir"
      ;;
    Darwin)
      # macOS: download .pkg and install
      local tmp_pkg
      tmp_pkg=$(mktemp /tmp/AWSCLIV2-XXXXXX.pkg)
      if curl -sfL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$tmp_pkg"; then
        sudo installer -pkg "$tmp_pkg" -target / 2>/dev/null || true
      fi
      rm -f "$tmp_pkg"
      ;;
    *)
      warn "Auto-update not supported on $os — update manually: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      return 1
      ;;
  esac
  # Re-hash so bash picks up the new binary
  hash -r 2>/dev/null || true
}

# Ensure AWS CLI is at minimum version, offer to update if not.
ensure_aws_cli_current() {
  if _aws_cli_is_current; then
    return 0
  fi
  _parse_aws_cli_version
  warn "AWS CLI ${_AWS_CLI_MAJOR:-?}.${_AWS_CLI_MINOR:-?} is below minimum ${MIN_AWS_CLI_MAJOR}.${MIN_AWS_CLI_MINOR}"
  if [[ "$AUTO_YES" == "true" ]]; then
    _update_aws_cli || true
  else
    echo ""
    echo "  Lowkey requires AWS CLI ${MIN_AWS_CLI_MAJOR}.${MIN_AWS_CLI_MINOR}+ for all features."
    echo "  Current version: ${_AWS_CLI_MAJOR:-?}.${_AWS_CLI_MINOR:-?}"
    echo ""
    if confirm "Update AWS CLI now?"; then
      _update_aws_cli || true
    else
      warn "Continuing with older AWS CLI — some features (e.g. account rename) may be unavailable"
      return 0
    fi
  fi
  # Verify update worked
  if _aws_cli_is_current; then
    _parse_aws_cli_version
    ok "AWS CLI updated to ${_AWS_CLI_MAJOR}.${_AWS_CLI_MINOR}"
  else
    warn "AWS CLI update may have failed — continuing with current version"
  fi
}

# ============================================================================
# Phase: Pre-flight checks
# ============================================================================
preflight_checks() {
  step "Pre-flight checks"

  if [[ "$DEBUG_IN_REPO" == "true" ]]; then
    git rev-parse --show-toplevel &>/dev/null \
      || fail "--debug-in-repo requires running from inside the lowkey repo directory."
    ok "Debug mode: repo root is $(pwd)"
    info "Debug log: ${INSTALL_LOG}"
  fi

  ok "gum UI: $($GUM --version 2>/dev/null || echo installed)"

  require_cmd aws "AWS CLI not found. Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  ensure_aws_cli_current
  ok "AWS CLI: $(aws --version 2>&1 | head -1)"

  require_cmd jq "jq is required but not found. Install: https://jqlang.github.io/jq/download/"

  verify_aws_credentials
  # ACCOUNT_ID and CALLER_ARN are now set by verify_aws_credentials (single STS call)
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")

  ok "Identity: ${CALLER_ARN}"
  echo ""
  echo -e "  ${BOLD}Account:${NC}  ${ACCOUNT_ID}"
  echo -e "  ${BOLD}Region:${NC}   ${REGION}"
  echo -e "  ${BOLD}Branch:${NC}   ${REPO_BRANCH}  ${DIM}(used by EC2 bootstrap)${NC}"
  echo ""

  if [[ "$INSTALL_MODE" != "simple" ]]; then
    warn "Lowkey will get AdministratorAccess on this ENTIRE account."
    warn "Use a dedicated sandbox account — never deploy in production."
    echo ""
    confirm_or_abort "Deploy to account ${ACCOUNT_ID} in ${REGION}?" "default_yes"
    check_permissions
  else
    ok "Using current account and region"
  fi

  check_bedrock_access
}

# Verify Bedrock is reachable AND models can actually be invoked on this
# account. Model access grants are per-account/per-region and are the #1
# silent install-killer: everything deploys green, then the agent can't
# think. Non-fatal — warns and lets the user continue informed.
BEDROCK_ACCESS_OK="unknown"
check_bedrock_access() {
  local check_region="${DEPLOY_REGION:-$REGION}"
  # Mirror build_deploy_params(): probe the region Bedrock will actually use
  local bedrock_allowed="us-east-1 us-west-2 eu-west-1 eu-central-1 eu-north-1 ap-northeast-1 ap-southeast-1"
  local probe_region
  if [[ " $bedrock_allowed " == *" $check_region "* ]]; then
    probe_region="$check_region"
  else
    probe_region="us-east-1"
  fi

  echo ""
  info "Checking Bedrock access in ${probe_region}..."

  # 1) Service reachable + IAM allows Bedrock at all?
  if ! aws bedrock list-foundation-models --region "$probe_region" \
       --query 'modelSummaries[0].modelId' --output text >/dev/null 2>&1; then
    BEDROCK_ACCESS_OK="false"
    warn "Bedrock is not reachable in ${probe_region} (service unavailable or IAM denies bedrock:*)."
    _bedrock_access_guidance "$probe_region"
    return 0
  fi

  # 2) Can a model actually be invoked? (catches missing model-access grants,
  #    which list-foundation-models does NOT detect)
  # Cross-region inference profile prefix must match the probe region's geo
  local geo_prefix
  case "$probe_region" in
    eu-*) geo_prefix="eu" ;;
    ap-*) geo_prefix="apac" ;;
    *)    geo_prefix="us" ;;
  esac
  local probe_model="${geo_prefix}.anthropic.claude-sonnet-4-6"

  # Capability probe: --generate-cli-skeleton is offline and exits 0 iff the
  # subcommand exists (unlike `aws ... help`, which needs groff and can fail
  # on minimal systems even when the command is present). `converse` has been
  # in CLI v2 for years; this only trips on genuinely ancient installs.
  if ! aws bedrock-runtime converse --generate-cli-skeleton >/dev/null 2>&1; then
    warn "AWS CLI lacks 'bedrock-runtime converse' — updating AWS CLI..."
    _update_aws_cli || true
    hash -r  # forget cached path in case the binary location changed
    if ! aws bedrock-runtime converse --generate-cli-skeleton >/dev/null 2>&1; then
      BEDROCK_ACCESS_OK="unknown"
      warn "AWS CLI update failed or still lacks 'bedrock-runtime converse' — skipping invoke check."
      ok "Bedrock service reachable in ${probe_region}"
      return 0
    fi
    ok "AWS CLI updated: $(aws --version 2>&1 | head -1)"
  fi

  local invoke_err=""
  if invoke_err=$(aws bedrock-runtime converse \
      --model-id "$probe_model" \
      --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
      --inference-config '{"maxTokens":1}' \
      --region "$probe_region" 2>&1 >/dev/null); then
    BEDROCK_ACCESS_OK="true"
    ok "Bedrock model access verified (${probe_model} @ ${probe_region})"
  elif grep -qiE "ThrottlingException|TooManyRequests|ServiceQuotaExceeded" <<<"$invoke_err"; then
    # Throttled = the account CAN invoke; access is granted
    BEDROCK_ACCESS_OK="true"
    ok "Bedrock model access verified (throttled response — access is enabled)"
  else
    BEDROCK_ACCESS_OK="false"
    warn "Bedrock is reachable, but model invocation FAILED on this account."
    echo -e "    ${DIM}$(echo "$invoke_err" | head -1)${NC}"
    _bedrock_access_guidance "$probe_region"
  fi

  # Phase 5: Troika Codex (Bedrock Mantle) model probe — non-fatal, independent
  # of the Sonnet result above. BEDROCK_ACCESS_OK tracks Sonnet only.
  # PACK_NAME is not yet resolved at preflight time (pack selection runs later);
  # detect troika early via PRESELECT_PACK (--pack flag) or TROIKA_CODEX_MODEL
  # (--codex-model flag).
  if [[ "${PACK_NAME:-}" == "troika" ]] \
     || [[ "${PRESELECT_PACK:-}" == "troika" ]] \
     || [[ -n "${TROIKA_CODEX_MODEL:-}" ]]; then
    _check_codex_model_access "${TROIKA_CODEX_MODEL:-openai.gpt-5.5}" "$probe_region"
  fi
}

_bedrock_access_guidance() {
  local probe_region="$1"
  echo ""
  echo -e "  ${YELLOW}${BOLD}Bedrock model access is currently NOT enabled for this account.${NC}"
  echo ""
  echo "  The install can continue, but the agent will not be able to use"
  echo "  Bedrock inference out of the box. What this means for you:"
  echo ""
  echo -e "  ${BOLD}1. After install:${NC} log in to your chosen agent and configure a"
  echo "     3rd-party inference provider (e.g. an Anthropic or OpenAI API key)"
  echo "     so the agent works while Bedrock access is being sorted out."
  echo ""
  echo -e "  ${BOLD}2. In parallel:${NC} ask your AWS account representatives / support to"
  echo "     help enable Bedrock model access and raise the Bedrock quotas"
  echo "     for this account."
  echo ""
  echo "  Self-service model access (if available to your account):"
  echo "  https://${probe_region}.console.aws.amazon.com/bedrock/home?region=${probe_region}#/modelaccess"
  echo ""
  confirm_or_abort "Continue with the install anyway?" "default_yes"
}

# Phase 5: Probe Bedrock Mantle (openai.*) model access for Troika's Codex CLI.
# Mantle models use the OpenAI-compatible Responses API, NOT bedrock-runtime
# converse — attempt converse first; fall back to list-foundation-models grep
# for openai.* ids. Non-fatal: warns and lets the install continue.
_check_codex_model_access() {
  local codex_model="$1"
  local probe_region="$2"

  echo ""
  info "Checking Codex (Bedrock Mantle) model access: ${codex_model} @ ${probe_region}..."

  # Attempt 1: converse — Mantle models likely return UnsupportedOperationException
  # (they use the OpenAI-compatible Responses API path, not converse). We try
  # anyway because the error response is informative and throttle = access OK.
  local codex_err=""
  if codex_err=$(aws bedrock-runtime converse \
      --model-id "$codex_model" \
      --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
      --inference-config '{"maxTokens":1}' \
      --region "$probe_region" 2>&1 >/dev/null); then
    ok "Codex Mantle model verified via converse (${codex_model})"
    return 0
  elif grep -qiE "ThrottlingException|TooManyRequests|ServiceQuotaExceeded" <<<"$codex_err"; then
    ok "Codex Mantle model access verified (throttled — access is enabled)"
    return 0
  fi

  # Attempt 2: list-foundation-models grep for openai.* ids.
  # Confirms Bedrock Mantle is visible/available in this region + account,
  # even if converse is unsupported for Mantle model IDs.
  local openai_ids=""
  openai_ids=$(aws bedrock list-foundation-models \
    --region "$probe_region" \
    --query "modelSummaries[?contains(modelId, 'openai')]" \
    --output text 2>/dev/null || true)

  if [[ -n "$openai_ids" ]]; then
    ok "Bedrock Mantle models visible (openai.* ids found in ${probe_region})"
    info "Codex CLI uses the OpenAI-compatible Responses API — converse probe does not apply."
  else
    warn "Codex Mantle model '${codex_model}' may not be accessible in ${probe_region}."
    echo -e "    ${DIM}$(echo "$codex_err" | head -1)${NC}"
    echo ""
    echo "  Troika's Codex CLI uses Amazon Bedrock Mantle (openai.* model IDs)."
    echo "  Bedrock Mantle access is separate from Anthropic model access."
    echo "  Enable Mantle model access (if available to your account):"
    echo "  https://${probe_region}.console.aws.amazon.com/bedrock/home?region=${probe_region}#/modelaccess"
    echo ""
    echo "  Note: Bedrock Mantle is region-limited; us-east-1 is the recommended region."
    echo "  The install will continue — Codex will not function until access is enabled."
    echo ""
    # Non-fatal: no confirm_or_abort (user already saw Sonnet warning if applicable)
  fi
}

check_vpc_quota() {
  local check_region="${DEPLOY_REGION:-$REGION}"
  echo ""
  info "Checking VPC quota in ${check_region}..."
  local vpc_count vpc_limit
  vpc_count=$(aws ec2 describe-vpcs --region "$check_region" \
    --query 'length(Vpcs)' --output text 2>/dev/null || echo "0")
  vpc_limit=$(aws service-quotas get-service-quota \
    --service-code vpc --quota-code L-F678F1CE --region "$check_region" \
    --query 'Quota.Value' --output text 2>/dev/null || echo "5")
  # Truncate decimals (quota API returns 5.0) and validate numeric
  vpc_limit=${vpc_limit%%.*}
  [[ "$vpc_count" =~ ^[0-9]+$ ]] || vpc_count=0
  [[ "$vpc_limit" =~ ^[0-9]+$ ]] || vpc_limit=5

  local remaining=$((vpc_limit - vpc_count))
  if [[ $remaining -le 0 ]]; then
    echo ""
    echo -e "  ${RED}VPC quota reached: ${vpc_count}/${vpc_limit} VPCs in ${check_region}${NC}"
    echo "  Lowkey needs 1 VPC. You have none remaining."
    echo ""
    if confirm "Request a VPC quota increase (+5) now?" "default_yes"; then
      local request_id
      request_id=$(aws service-quotas request-service-quota-increase \
        --service-code vpc --quota-code L-F678F1CE \
        --desired-value $((vpc_limit + 5)) --region "$check_region" \
        --query 'RequestedQuota.Id' --output text 2>/dev/null || echo "")
      if [[ -n "$request_id" ]]; then
        ok "Quota increase requested (id: ${request_id})"
        info "New limit: $((vpc_limit + 5)) VPCs — usually approved within minutes"
        info "Check status: https://${check_region}.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
        echo ""
        confirm_or_abort "Continue with deployment (quota increase pending)?" "default_yes"
      else
        warn "Could not request quota increase automatically"
        echo "  Request manually: https://${check_region}.console.aws.amazon.com/servicequotas/home/services/vpc/quotas/L-F678F1CE"
        confirm_or_abort "Continue anyway (deploy will likely fail)?"
      fi
    else
      confirm_or_abort "Continue anyway (deploy will likely fail)?"
    fi
  elif [[ $remaining -le 1 ]]; then
    warn "VPC quota is tight: ${vpc_count}/${vpc_limit} VPCs in ${check_region} (${remaining} remaining)"
    echo "  Lowkey needs 1 VPC."
    if confirm "Request a quota increase (+5) as a precaution?" ; then
      aws service-quotas request-service-quota-increase \
        --service-code vpc --quota-code L-F678F1CE \
        --desired-value $((vpc_limit + 5)) --region "$check_region" >/dev/null 2>&1 \
        && ok "Quota increase requested (+5)" \
        || warn "Could not request quota increase (non-fatal)"
    fi
  else
    ok "VPC quota: ${vpc_count}/${vpc_limit} used (${remaining} remaining)"
  fi
}

check_permissions() {
  echo ""
  info "Checking permissions..."
  if aws iam simulate-principal-policy \
    --policy-source-arn "$CALLER_ARN" \
    --action-names "cloudformation:CreateStack" "iam:CreateRole" "ec2:CreateVpc" \
    --query 'EvaluationResults[?EvalDecision!=`allowed`].EvalActionName' \
    --output text 2>/dev/null | grep -q "."; then
    warn "Some permissions may be missing."
    confirm_or_abort "Continue anyway?"
  else
    ok "Permissions verified"
  fi
}

check_existing_deployments() {
  local check_region="${DEPLOY_REGION:-$REGION}"
  echo ""
  info "Checking for existing Lowkey deployments in ${check_region}..."
  local vpcs
  vpcs=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$check_region" \
    --query 'Vpcs[*].[VpcId, Tags[?Key==`loki:watermark`].Value|[0], Tags[?Key==`loki:deploy-method`].Value|[0], Tags[?Key==`Name`].Value|[0]]' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$vpcs" ]]; then
    local count; count=$(echo "$vpcs" | wc -l | tr -d ' ')
    warn "Found ${count} existing Lowkey deployment(s) in this account/region:"
    echo ""
    local -a vpc_ids=()
    while IFS=$'\t' read -r vpc_id watermark method name; do
      echo -e "    ${BOLD}${vpc_id}${NC}  watermark=${watermark:-n/a}  method=${method:-n/a}  name=${name:-n/a}"
      vpc_ids+=("$vpc_id")
    done <<< "$vpcs"
    echo ""

    # Offer to reuse an existing VPC instead of creating a new one
    local reuse_vpc=true
    if [[ "$AUTO_YES" == true || "$INSTALL_MODE" == "simple" ]]; then
      info "Reusing existing VPC"
    else
      if ! confirm "Reuse an existing VPC?" "default_yes"; then
        reuse_vpc=false
      fi
    fi

    if [[ "$reuse_vpc" == true ]]; then
      local chosen_vpc
      if [[ ${#vpc_ids[@]} -eq 1 || "$AUTO_YES" == true || "$INSTALL_MODE" == "simple" ]]; then
        chosen_vpc="${vpc_ids[0]}"
        info "Using VPC: ${chosen_vpc}"
      else
        local __rc=0
        chosen_vpc=$(printf '%s\n' "${vpc_ids[@]}" | $GUM choose --header "Select a VPC to reuse") || __rc=$?
        [[ $__rc -eq 130 ]] && { echo ""; cleanup_on_interrupt; }
        [[ $__rc -ne 0 ]] && fail "VPC selection cancelled"
        info "Selected VPC: ${chosen_vpc}"
      fi

      EXISTING_VPC_ID="$chosen_vpc"

      # Find a public subnet in the chosen VPC (one with an internet gateway route)
      local subnet_id=""
      local candidate_subnets
      # First try subnets tagged with "public"
      candidate_subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${chosen_vpc}" "Name=tag:Name,Values=*public*" \
        --query 'Subnets[*].SubnetId' --output text --region "$check_region" 2>/dev/null || echo "")
      # Fallback: subnets with auto-assign public IP
      if [[ -z "$candidate_subnets" || "$candidate_subnets" == "None" ]]; then
        candidate_subnets=$(aws ec2 describe-subnets \
          --filters "Name=vpc-id,Values=${chosen_vpc}" "Name=mapPublicIpOnLaunch,Values=true" \
          --query 'Subnets[*].SubnetId' --output text --region "$check_region" 2>/dev/null || echo "")
      fi
      # Verify at least one candidate has an IGW route (0.0.0.0/0 → igw-*)
      for candidate in $candidate_subnets; do
        [[ "$candidate" == "None" || -z "$candidate" ]] && continue
        local rtb_id
        rtb_id=$(aws ec2 describe-route-tables \
          --filters "Name=association.subnet-id,Values=${candidate}" \
          --query 'RouteTables[0].RouteTableId' --output text --region "$check_region" 2>/dev/null || echo "")
        # Fall back to main route table if no explicit association
        if [[ -z "$rtb_id" || "$rtb_id" == "None" ]]; then
          rtb_id=$(aws ec2 describe-route-tables \
            --filters "Name=vpc-id,Values=${chosen_vpc}" "Name=association.main,Values=true" \
            --query 'RouteTables[0].RouteTableId' --output text --region "$check_region" 2>/dev/null || echo "")
        fi
        if [[ -n "$rtb_id" && "$rtb_id" != "None" ]]; then
          local has_igw
          has_igw=$(aws ec2 describe-route-tables \
            --route-table-ids "$rtb_id" \
            --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
            --output text --region "$check_region" 2>/dev/null || echo "")
          if [[ "$has_igw" == igw-* ]]; then
            subnet_id="$candidate"
            break
          fi
        fi
      done

      if [[ -n "$subnet_id" && "$subnet_id" != "None" ]]; then
        EXISTING_SUBNET_ID="$subnet_id"
        # KiroCrew pack needs a second public subnet in a DIFFERENT AZ (ALB requirement).
        # Discover it now so we can pass ExistingSubnetId2 to the stack.
        EXISTING_SUBNET_ID2=""
        if [[ "${PACK_NAME:-}" == "kirocrew" ]]; then
          local subnet1_az
          subnet1_az=$(aws ec2 describe-subnets \
            --subnet-ids "$subnet_id" \
            --query 'Subnets[0].AvailabilityZone' --output text --region "$check_region" 2>/dev/null || echo "")
          for candidate in $candidate_subnets; do
            [[ "$candidate" == "None" || -z "$candidate" || "$candidate" == "$subnet_id" ]] && continue
            local candidate_az
            candidate_az=$(aws ec2 describe-subnets \
              --subnet-ids "$candidate" \
              --query 'Subnets[0].AvailabilityZone' --output text --region "$check_region" 2>/dev/null || echo "")
            if [[ -n "$candidate_az" && "$candidate_az" != "$subnet1_az" ]]; then
              # Verify this candidate also has IGW route
              local rtb2_id has_igw2
              rtb2_id=$(aws ec2 describe-route-tables \
                --filters "Name=association.subnet-id,Values=${candidate}" \
                --query 'RouteTables[0].RouteTableId' --output text --region "$check_region" 2>/dev/null || echo "")
              if [[ -z "$rtb2_id" || "$rtb2_id" == "None" ]]; then
                rtb2_id=$(aws ec2 describe-route-tables \
                  --filters "Name=vpc-id,Values=${chosen_vpc}" "Name=association.main,Values=true" \
                  --query 'RouteTables[0].RouteTableId' --output text --region "$check_region" 2>/dev/null || echo "")
              fi
              if [[ -n "$rtb2_id" && "$rtb2_id" != "None" ]]; then
                has_igw2=$(aws ec2 describe-route-tables \
                  --route-table-ids "$rtb2_id" \
                  --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
                  --output text --region "$check_region" 2>/dev/null || echo "")
                if [[ "$has_igw2" == igw-* ]]; then
                  EXISTING_SUBNET_ID2="$candidate"
                  break
                fi
              fi
            fi
          done
          if [[ -z "$EXISTING_SUBNET_ID2" ]]; then
            warn "KiroCrew pack requires 2 public subnets in different AZs (for ALB) but only found one in ${chosen_vpc} — creating new VPC instead"
            EXISTING_VPC_ID=""
            EXISTING_SUBNET_ID=""
            EXISTING_SUBNET_ID2=""
          else
            ok "Reusing VPC: ${EXISTING_VPC_ID}  subnets: ${EXISTING_SUBNET_ID}, ${EXISTING_SUBNET_ID2}"
          fi
        else
          ok "Reusing VPC: ${EXISTING_VPC_ID}  subnet: ${EXISTING_SUBNET_ID}"
        fi
      else
        warn "Could not find a public subnet in ${chosen_vpc} — creating new VPC instead"
        EXISTING_VPC_ID=""
        EXISTING_SUBNET_ID=""
        EXISTING_SUBNET_ID2=""
      fi
    else
      # User declined reuse — proceed with a new VPC
      confirm_or_abort "Continue with a new deployment (new VPC)?"
    fi
  else
    ok "No existing Lowkey deployments found"
  fi
}

choose_deploy_method() {
  step "Deploy method"
  # If method was pre-selected via --method, validate and set it
  if [[ -n "${PRESELECT_METHOD}" ]]; then
    case "${PRESELECT_METHOD}" in
      cfn|cloudformation)   DEPLOY_METHOD="$DEPLOY_CFN_CLI" ;;
      *)
        echo ""
        echo -e "  ${RED}✗ Unknown deploy method: '${PRESELECT_METHOD}'${NC}"
        echo ""
        echo "  Valid methods:"
        echo "    cfn          — CloudFormation CLI"
        echo ""
        fail "Use --method cfn (CloudFormation is the only supported deploy method)."
        ;;
    esac
    local method_name
    case "$DEPLOY_METHOD" in
      "$DEPLOY_CFN_CLI")     method_name="CloudFormation CLI" ;;
    esac
    ok "Deploy method pre-selected: ${method_name}"
  else
  local method_choice
  _gum_or_die method_choice $GUM choose --header "Deployment method" --selected "CloudFormation CLI" \
    "CloudFormation CLI" \
    "CloudFormation Console"
  case "$method_choice" in
    "CloudFormation CLI")     DEPLOY_METHOD="$DEPLOY_CFN_CLI" ;;
    "CloudFormation Console") DEPLOY_METHOD="$DEPLOY_CFN_CONSOLE" ;;
    *)                        DEPLOY_METHOD="$DEPLOY_CFN_CLI" ;;
  esac
  fi
}

# ============================================================================
# Profile selection — REQUIRED, no default
# ============================================================================
PROFILE_NAME=""  # set by choose_profile()

choose_profile() {
  local valid_profiles=("builder" "account_assistant" "personal_assistant")

  # Validate a profile name against allowed values
  _is_valid_profile() {
    local p="$1"
    for vp in "${valid_profiles[@]}"; do [[ "$p" == "$vp" ]] && return 0; done
    return 1
  }

  if [[ -n "${PRESELECT_PROFILE}" ]]; then
    if ! _is_valid_profile "${PRESELECT_PROFILE}"; then
      echo ""
      echo -e "  ${RED}✗ Unknown profile: '${PRESELECT_PROFILE}'${NC}"
      echo ""
      echo "  Valid profiles:"
      echo "    builder             — Full AWS admin access"
      echo "    account_assistant   — Read-only AWS access"
      echo "    personal_assistant  — Bedrock only, no AWS"
      echo ""
      fail "Use --profile <builder|account_assistant|personal_assistant> with one of the profiles listed above."
    fi
    PROFILE_NAME="${PRESELECT_PROFILE}"
    ok "Profile pre-selected: ${PROFILE_NAME}"
    return
  fi

  # Non-interactive without --profile: default to builder
  if [[ "$AUTO_YES" == true ]]; then
    PROFILE_NAME="builder"
    ok "Profile defaulted: ${PROFILE_NAME}"
    return
  fi

  # Interactive: show menu
  local profile_choice
  _gum_or_die profile_choice $GUM choose --header "Permission profile" --selected "builder — Full AWS admin access" \
    "builder — Full AWS admin access" \
    "account_assistant — Read-only AWS access" \
    "personal_assistant — Bedrock only, no AWS access" \
    || profile_choice="builder — Full AWS admin access"
  PROFILE_NAME="${profile_choice%% —*}"

  ok "Profile selected: ${PROFILE_NAME}"
}

# ============================================================================
# Pack registry loading (shared by simple + advanced modes)
# ============================================================================
_PACK_REGISTRY=""
PACK_NAMES=()
PACK_DESCS=()
PACK_EXPERIMENTAL=()

load_pack_registry() {
  _PACK_REGISTRY="${CLONE_DIR:-}/packs/registry.json"
  if [[ ! -f "$_PACK_REGISTRY" ]]; then
    local registry_url="https://raw.githubusercontent.com/inceptionstack/lowkey/${REPO_BRANCH:-main}/packs/registry.json"
    _PACK_REGISTRY="/tmp/lowkey-registry-$$.json"
    curl -sfL "$registry_url" -o "$_PACK_REGISTRY" 2>/dev/null || _PACK_REGISTRY=""
  fi
  PACK_NAMES=()
  PACK_DESCS=()
  PACK_EXPERIMENTAL=()
  while IFS='|' read -r pname pdesc pexp; do
    PACK_NAMES+=("$pname")
    PACK_DESCS+=("$pdesc")
    PACK_EXPERIMENTAL+=("$pexp")
  done < <([ -n "$_PACK_REGISTRY" ] && jq -r '
    .packs | to_entries[]
    | select(.value.type == "agent" and (.value.hidden // false) == false)
    | "\(.key)|\(.value.description // .key)|\(if .value.experimental then "true" else "false" end)"
  ' "$_PACK_REGISTRY" 2>/dev/null \
    || echo "openclaw|OpenClaw -- stateful AI agent with persistent gateway|false")
}

# ============================================================================
# Install mode selection: simple (default) or advanced
# ============================================================================
choose_install_mode() {
  if [[ -n "$INSTALL_MODE" ]]; then
    return  # pre-selected via --simple or --advanced
  fi
  if [[ "$AUTO_YES" == true ]]; then
    INSTALL_MODE="simple"
    return
  fi
  local mode_choice
  _gum_or_die mode_choice $GUM choose --header "Install mode" \
    --selected "Simple — quick setup, smart defaults" \
    "Simple — quick setup, smart defaults" \
    "Advanced — full control over all settings" || mode_choice=""
  case "$mode_choice" in
    Simple*) INSTALL_MODE="simple" ;;
    *)       INSTALL_MODE="advanced" ;;
  esac
}

# ============================================================================
# Shared: pack selection (used by both simple and advanced modes)
# ============================================================================
choose_pack() {
  # If pack was pre-selected via --pack, validate it
  if [[ -n "${PRESELECT_PACK}" ]]; then
    local found=false
    for i in "${!PACK_NAMES[@]}"; do
      if [[ "${PACK_NAMES[$i]}" == "${PRESELECT_PACK}" ]]; then
        PACK_NAME="${PACK_NAMES[$i]}"
        found=true
        if [[ "${PACK_EXPERIMENTAL[$i]}" == "true" ]]; then
          warn "${PACK_NAME} is experimental — expect rough edges"
        fi
        ok "Pack pre-selected: ${PACK_NAME}"
        break
      fi
    done
    if [[ "$found" != true ]]; then
      echo ""
      echo -e "  ${RED}✗ Unknown pack: '${PRESELECT_PACK}'${NC}"
      echo ""
      echo "  Available packs:"
      for i in "${!PACK_NAMES[@]}"; do
        echo "    - ${PACK_NAMES[$i]}"
      done
      echo ""
      fail "Pack '${PRESELECT_PACK}' not found. Use --pack <name> with one of the packs listed above."
    fi
    return
  fi

  # Simple mode + non-interactive: auto-select kirocrew without gum
  # TODO(unattended): v1 is interactive wizard only. Unattended (-y) support for
  # KiroCrew (credential collection, --webui-email passthrough) will be added in
  # a future iteration. For now, non-interactive falls back to openclaw.
  if [[ "$INSTALL_MODE" == "simple" && "$AUTO_YES" == true ]]; then
    # Unattended: fall back to openclaw (no WebUI auth prompting needed)
    PACK_NAME="openclaw"
    local found_auto=false
    for i in "${!PACK_NAMES[@]}"; do
      if [[ "${PACK_NAMES[$i]}" == "$PACK_NAME" ]]; then
        found_auto=true
        break
      fi
    done
    if [[ "$found_auto" != true ]]; then
      fail "openclaw not found in registry. Check packs/registry.json."
    fi
    ok "Agent: ${PACK_NAME} (auto-selected, unattended)"
    return
  fi

  # Interactive: build display items for gum choose
  local -a gum_items=()
  local default_item=""
  local pname="" item="" in_list=false sp="" wp=""

  # Simple mode: curated list (order preserved) with UI-type hints
  local -a simple_packs=(kirocrew openclaw hermes claude-code codex-cli kiro-cli troika)
  local -a webui_packs=(kirocrew)

  if [[ "$INSTALL_MODE" == "simple" ]]; then
    # Iterate in curated order to guarantee display position
    for sp in "${simple_packs[@]}"; do
      for i in "${!PACK_NAMES[@]}"; do
        [[ "${PACK_NAMES[$i]}" == "$sp" ]] || continue
        pname="${PACK_NAMES[$i]}"

        item="${pname} — ${PACK_DESCS[$i]}"
        [[ "${PACK_EXPERIMENTAL[$i]}" == "true" ]] && item+=" (experimental)"

        gum_items+=("$item")
        [[ "$pname" == "kirocrew" ]] && default_item="$item"
        break
      done
    done
  else
    # Advanced mode: show all packs in registry order, no UI-type labels
    for i in "${!PACK_NAMES[@]}"; do
      pname="${PACK_NAMES[$i]}"
      item="${pname} — ${PACK_DESCS[$i]}"
      [[ "${PACK_EXPERIMENTAL[$i]}" == "true" ]] && item+=" (experimental)"
      gum_items+=("$item")
      [[ "$pname" == "openclaw" ]] && default_item="$item"
    done
  fi

  # Fallback: if intended default wasn't found, use first item
  if [[ -z "$default_item" && ${#gum_items[@]} -gt 0 ]]; then
    default_item="${gum_items[0]}"
  fi

  # Guard: if no packs matched, fail clearly
  if [[ ${#gum_items[@]} -eq 0 ]]; then
    fail "No supported packs found for ${INSTALL_MODE} mode. Check packs/registry.json."
  fi
  local pack_choice
  local header="${1:-Agent to deploy}"
  _gum_or_die pack_choice $GUM choose --header "$header" \
    ${default_item:+--selected "$default_item"} \
    "${gum_items[@]}" \
    || { fail "Pack selection is required"; }
  PACK_NAME="${pack_choice%% —*}"
  PACK_NAME="${PACK_NAME%" "}"  # trim trailing space before the em dash separator, if any
  for i in "${!PACK_NAMES[@]}"; do
    if [[ "${PACK_NAMES[$i]}" == "$PACK_NAME" && "${PACK_EXPERIMENTAL[$i]}" == "true" ]]; then
      warn "${PACK_NAME} is experimental — expect rough edges"
    fi
  done
  ok "Agent: ${PACK_NAME}"
}

# Check pack/profile compatibility against registry compatible_profiles.
# When a pack declares compatible_profiles, auto-selects the first allowed
# profile (or fails fast when --profile was explicit). No-op for packs with
# no restriction (most packs).
check_pack_profile_compat() {
  local registry="$_PACK_REGISTRY"
  [[ -z "$registry" || ! -f "$registry" ]] && return 0

  local compat_profiles
  compat_profiles=$(jq -r --arg p "$PACK_NAME" '.packs[$p].compatible_profiles // [] | .[]' "$registry" 2>/dev/null || true)
  [[ -z "$compat_profiles" ]] && return 0  # no restriction

  local profile_ok=false
  while IFS= read -r cp; do
    [[ "$PROFILE_NAME" == "$cp" ]] && profile_ok=true && break
  done <<< "$compat_profiles"

  [[ "$profile_ok" == "true" ]] && return 0

  local allowed_list
  allowed_list=$(printf '%s' "$compat_profiles" | tr '\n' ',' | sed 's/,$//')

  if [[ -n "${PRESELECT_PROFILE:-}" ]]; then
    fail "Pack '${PACK_NAME}' requires profile in [${allowed_list}]. Got --profile '${PRESELECT_PROFILE}'."
  fi

  # Interactive selection was outside allowed set — auto-correct to first allowed profile
  local first_compat
  first_compat=$(printf '%s' "$compat_profiles" | head -1)
  info "${PACK_NAME} is restricted to [${allowed_list}] profile(s) — auto-selecting '${first_compat}'"
  PROFILE_NAME="$first_compat"
  ok "Profile: ${PROFILE_NAME}"
}

# ============================================================================
# Simple mode: pack + profile → auto-configure everything else
# ============================================================================
collect_config_simple() {
  step "Configuration (simple)"

  load_pack_registry
  local registry="$_PACK_REGISTRY"

  choose_pack "Which agent do you want to deploy?"
  choose_profile
  check_pack_profile_compat

  # ---- Auto-configure everything else ----
  DEPLOY_REGION="${REGION:-us-east-1}"
  DEPLOY_METHOD="$DEPLOY_CFN_CLI"

  # Instance type: profile determines size in simple mode
  case "$PROFILE_NAME" in
    builder)            INSTANCE_TYPE="t4g.xlarge" ;;
    account_assistant)  INSTANCE_TYPE="t4g.medium" ;;
    personal_assistant) INSTANCE_TYPE="t4g.medium" ;;
    *)                  INSTANCE_TYPE="t4g.xlarge" ;;
  esac

  # Pack minimum (§12.4): enforce registry instance_type as floor so a pack that
  # requires a larger instance isn't silently under-provisioned in simple mode.
  if [[ -n "$registry" && -f "$registry" ]]; then
    local _sim_pack_min
    _sim_pack_min=$(jq -r --arg p "$PACK_NAME" '.packs[$p].instance_type // ""' "$registry" 2>/dev/null || echo "")
    case "$_sim_pack_min" in
      t4g.xlarge)
        if [[ "$INSTANCE_TYPE" != "t4g.xlarge" ]]; then
          INSTANCE_TYPE="t4g.xlarge"
          info "${PACK_NAME} requires t4g.xlarge minimum (§12.4) — upgrading from profile default"
        fi ;;
      t4g.large)
        if [[ "$INSTANCE_TYPE" == "t4g.medium" ]]; then
          INSTANCE_TYPE="t4g.large"
          info "${PACK_NAME} requires t4g.large minimum (§12.4) — upgrading from profile default"
        fi ;;
    esac
  fi

  # Environment name: auto-generate
  local existing_count
  existing_count=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$DEPLOY_REGION" \
    --query 'length(Vpcs)' --output text 2>/dev/null || echo "0")
  local ts_suffix; ts_suffix=$(date +%s | tail -c 4)
  ENV_NAME="${PACK_NAME}-$((existing_count + 1))-${ts_suffix}"
  LOKI_WATERMARK="$ENV_NAME"
  case "$PROFILE_NAME" in
    personal_assistant)
      SECURITY_HUB="false"; GUARDDUTY="false"; INSPECTOR="false"
      ACCESS_ANALYZER="false"; CONFIG_RECORDER="false" ;;
    *)
      SECURITY_HUB="true"; GUARDDUTY="true"; INSPECTOR="true"
      ACCESS_ANALYZER="true"; CONFIG_RECORDER="true" ;;
  esac

  # WebUI auth: ask during config wizard (before summary)
  if [[ "$PACK_NAME" == "kirocrew" ]]; then
    configure_webui_auth "$PACK_NAME" 5476 "/auth/callback"
  fi
}

# Collect WebUI auth preferences for a pack. Cognito resources are created
# by the CloudFormation stack (WebUIUserPool + custom resource); this
# function only gathers user input and sets vars for build_deploy_params.
configure_webui_auth() {
  local pack_name="$1" webui_port="$2" callback_path="$3"
  local user_email="${WEBUI_EMAIL:-}"

  export WEBUI_AUTH_ENABLED="false"
  export WEBUI_ADMIN_EMAIL=""

  if [[ "${WEBUI_NO_AUTH:-false}" == true ]]; then
    warn "WebUI authentication disabled (--webui-no-auth); use SSM/VPN-only access."
    return 0
  fi

  if [[ "${AUTO_YES:-false}" != true ]] && ! confirm "Protect ${pack_name} WebUI with Cognito login? (enterprise-grade)" "default_no"; then
    warn "WebUI authentication disabled; use SSM/VPN-only access."
    return 0
  fi

  if [[ "${AUTO_YES:-false}" == true && -z "$user_email" ]]; then
    # TODO(unattended): --webui-email plumbing for fully unattended installs.
    warn "Non-interactive mode without --webui-email; skipping WebUI auth."
    warn "Use SSM port-forward or VPN-only access."
    return 0
  fi

  if [[ -z "$user_email" ]]; then
    while true; do
      prompt "Email for WebUI admin login" user_email ""
      [[ "$user_email" =~ ^[^@]+@[^@]+\.[^@]+$ ]] && break
      warn "Please enter a valid email address."
    done
  elif [[ ! "$user_email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    fail "Invalid --webui-email value: ${user_email}"
  fi

  export WEBUI_AUTH_ENABLED="true"
  export WEBUI_ADMIN_EMAIL="$user_email"
  ok "WebUI auth enabled — Cognito will be provisioned by CloudFormation"
  info "Admin email: ${user_email}"
  info "Initial password will be shown after stack deploys."
}

# ============================================================================
# WebUI Lambda@Edge zip build + S3 upload (KiroCrew, when auth enabled)
# ============================================================================
# Builds the Cognito-at-Edge zip, uploads it to a dedicated us-east-1 bucket,
# and exports the edge artifact details for deploy_edge_stack.
build_and_upload_edge_lambda() {
  [[ "${WEBUI_AUTH_ENABLED:-false}" == "true" ]] || return 0
  [[ "$PACK_NAME" == "kirocrew" ]] || return 0

  # Preflight: required tools for the edge Lambda build path.
  require_cmd node "node (22+) is required to build the Cognito Lambda@Edge zip. Install Node 22+ or disable WebUI auth."
  require_cmd npm "npm is required to build the Cognito Lambda@Edge zip."
  require_cmd zip "zip is required to package the Cognito Lambda@Edge deployment."
  require_cmd openssl "openssl is required to compute the Lambda@Edge zip SHA256 for CFN."

  local build_script="${CLONE_DIR}/packs/kirocrew/webui-auth-edge/build.sh"
  # In debug-in-repo mode CLONE_DIR points into the working repo; otherwise it
  # points at the freshly-cloned copy. In either case the script must exist
  # AFTER prepare_repo has run. This function is called from that point.
  if [[ ! -x "$build_script" ]]; then
    fail "Edge Lambda build script missing: $build_script"
  fi

  step "WebUI Lambda@Edge"
  info "Building Cognito Lambda@Edge zip..."

  # Deterministic config secret NAME (not ARN — Secrets Manager appends a random suffix
  # to the ARN we can't know at build time, but names are stable). The Lambda@Edge
  # bakes this name in and fetches the merged config at cold start.
  local secret_name="/lowkey/${ENV_NAME}/webui-edge-config"

  local zip_path
  zip_path=$(CONFIG_SECRET_NAME="$secret_name" "$build_script" 2>&1 | tail -1) \
    || fail "Edge Lambda build failed: $zip_path"
  if [[ ! -f "$zip_path" ]]; then
    fail "Edge Lambda build script did not produce a zip: $zip_path"
  fi

  local bucket="${ENV_NAME}-edge-${ACCOUNT_ID}"
  local key="edge/$(basename "$zip_path")"

  # Lambda@Edge requires its source bucket to be in us-east-1. Ensure the
  # dedicated bucket exists (idempotent), independently of the main-region
  # CloudFormation templates bucket.
  if ! aws s3api head-bucket --bucket "$bucket" --region us-east-1 2>/dev/null; then
    info "Creating edge Lambda bucket: $bucket"
    aws s3api create-bucket --bucket "$bucket" --region us-east-1 \
      >/dev/null 2>&1 || fail "Failed to create bucket $bucket"
  fi
  aws s3api put-bucket-encryption --bucket "$bucket" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}' \
    --region us-east-1 >/dev/null 2>&1 || true
  aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled \
    --region us-east-1 >/dev/null 2>&1 || fail "Failed to enable versioning on $bucket"
  aws s3api put-public-access-block --bucket "$bucket" --region us-east-1 \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
    >/dev/null 2>&1 || fail "Failed to block public access on $bucket"

  info "Uploading edge Lambda zip: s3://${bucket}/${key} ($(wc -c < "$zip_path") bytes)"
  aws s3 cp "$zip_path" "s3://${bucket}/${key}" --region us-east-1 >/dev/null \
    || fail "Failed to upload edge Lambda zip"

  # Compute base64-encoded SHA256 of the zip. CFN needs this on the
  # AWS::Lambda::Version resource so a new version is published whenever
  # the code changes; without it, CloudFront keeps pointing at the old
  # version even though $LATEST has new code.
  local code_sha256
  code_sha256=$(openssl dgst -sha256 -binary "$zip_path" | openssl base64 -A) \
    || fail "Failed to compute SHA256 of edge Lambda zip"

  export EDGE_S3_BUCKET_US_EAST_1="$bucket"
  export EDGE_S3_KEY="$key"
  export EDGE_CODE_SHA256="$code_sha256"
  ok "Edge Lambda uploaded"
}

deploy_edge_stack() {
  [[ "${WEBUI_AUTH_ENABLED:-false}" == "true" ]] || return 0
  [[ "$PACK_NAME" == "kirocrew" ]] || return 0

  local edge_stack_name="${ENV_NAME}-edge-stack"
  step "Deploy WebUI Lambda@Edge companion stack"
  if ! aws cloudformation deploy \
    --template-file "${CLONE_DIR}/deploy/cloudformation/edge-stack.yaml" \
    --stack-name "$edge_stack_name" \
    --region us-east-1 \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      "EnvironmentName=${ENV_NAME}" "PackName=${PACK_NAME}" \
      "EdgeLambdaS3Bucket=${EDGE_S3_BUCKET_US_EAST_1}" \
      "EdgeLambdaS3Key=${EDGE_S3_KEY}" "EdgeLambdaCodeSha256=${EDGE_CODE_SHA256}"; then
    fail "Lambda@Edge companion stack deployment failed; main stack was not started"
  fi

  local outputs
  outputs=$(aws cloudformation describe-stacks --stack-name "$edge_stack_name" --region us-east-1 \
    --query 'Stacks[0].Outputs' --output json) \
    || fail "Could not read outputs from Lambda@Edge companion stack"
  EDGE_LAMBDA_VERSION_ARN=$(printf '%s' "$outputs" | jq -r '.[] | select(.OutputKey=="EdgeLambdaVersionArn") | .OutputValue')
  EDGE_CONFIG_SECRET_NAME=$(printf '%s' "$outputs" | jq -r '.[] | select(.OutputKey=="EdgeConfigSecretName") | .OutputValue')
  EDGE_CONFIG_SECRET_ARN=$(printf '%s' "$outputs" | jq -r '.[] | select(.OutputKey=="EdgeConfigSecretArn") | .OutputValue')
  SIGNING_KEY_SECRET_NAME=$(printf '%s' "$outputs" | jq -r '.[] | select(.OutputKey=="SigningKeySecretName") | .OutputValue')
  SIGNING_KEY_SECRET_ARN=$(printf '%s' "$outputs" | jq -r '.[] | select(.OutputKey=="SigningKeySecretArn") | .OutputValue')
  export EDGE_LAMBDA_VERSION_ARN EDGE_CONFIG_SECRET_NAME EDGE_CONFIG_SECRET_ARN
  export SIGNING_KEY_SECRET_NAME SIGNING_KEY_SECRET_ARN
  [[ -n "$EDGE_LAMBDA_VERSION_ARN" && "$EDGE_LAMBDA_VERSION_ARN" != null ]] \
    || fail "Lambda@Edge companion stack returned no version ARN"
  ok "Lambda@Edge companion stack deployed"
}


collect_config() {
  step "Configuration"

  load_pack_registry
  local registry="$_PACK_REGISTRY"

  choose_pack
  choose_profile
  check_pack_profile_compat

  prompt "AWS region" DEPLOY_REGION "$REGION"

  # Count existing deployments to generate a smart default env name
  # Must be after region prompt so we count in the right region
  local existing_count
  existing_count=$(aws ec2 describe-vpcs \
    --filters "Name=tag:loki:managed,Values=true" \
    --region "$DEPLOY_REGION" \
    --query 'length(Vpcs)' --output text 2>/dev/null || echo "0")
  local ts_suffix; ts_suffix=$(date +%s | tail -c 4)
  local default_env_name="${PACK_NAME}-$((existing_count + 1))-${ts_suffix}"

  ENV_NAME="$default_env_name"
  LOKI_WATERMARK="$ENV_NAME"
  ok "Environment: ${ENV_NAME}"

  # Adjust instance size default: profile takes precedence, pack registry as fallback
  local default_size_choice="3"  # default → t4g.xlarge
  # Profile-driven defaults (profile wins over pack registry)
  case "${PROFILE_NAME:-}" in
    builder)             default_size_choice="3" ;;  # t4g.xlarge
    account_assistant)   default_size_choice="1" ;;  # t4g.medium
    personal_assistant)  default_size_choice="1" ;;  # t4g.medium
    *)
      # Fallback: pack registry instance_type
      local pack_instance_type
      pack_instance_type=$([ -n "$registry" ] && jq -r --arg p "$PACK_NAME" '.packs[$p].instance_type // "t4g.xlarge"' "$registry" 2>/dev/null || echo "t4g.xlarge")
      case "$pack_instance_type" in
        t4g.medium)  default_size_choice="1"; info "${PACK_NAME} is lightweight — defaulting to t4g.medium" ;;
        t4g.large)   default_size_choice="2" ;;
        *)           default_size_choice="3" ;;
      esac
      ;;
  esac

  # Pack minimum override: if the pack requires a larger instance than the profile default, upgrade
  if [ -n "$registry" ]; then
    local pack_min_type
    pack_min_type=$(jq -r --arg p "$PACK_NAME" '.packs[$p].instance_type // ""' "$registry" 2>/dev/null || echo "")
    case "$pack_min_type" in
      t4g.xlarge)
        if [[ "$default_size_choice" == "1" || "$default_size_choice" == "2" ]]; then
          default_size_choice="3"
          info "${PACK_NAME} requires t4g.xlarge minimum — upgrading from profile default"
        fi
        ;;
      t4g.large)
        if [[ "$default_size_choice" == "1" ]]; then
          default_size_choice="2"
          info "${PACK_NAME} requires t4g.large minimum — upgrading from profile default"
        fi
        ;;
    esac
  fi
  local default_type="t4g.xlarge"
  case "$default_size_choice" in 1) default_type="t4g.medium" ;; 2) default_type="t4g.large" ;; esac

  local size_choice
  _gum_or_die size_choice $GUM choose --header "Instance size" \
    --selected "${default_type}  — recommended" \
    "t4g.medium  — 2 vCPU,  4GB  ~\$25/mo   light use" \
    "t4g.large   — 2 vCPU,  8GB  ~\$50/mo   regular use" \
    "t4g.xlarge  — 4 vCPU, 16GB  ~\$100/mo  recommended" || size_choice=""
  INSTANCE_TYPE="${size_choice%%  *}"
  [[ -z "$INSTANCE_TYPE" ]] && INSTANCE_TYPE="$default_type"

  collect_security_config

  # WebUI auth: ask during config wizard (before summary)
  if [[ "$PACK_NAME" == "kirocrew" ]]; then
    configure_webui_auth "$PACK_NAME" 5476 "/auth/callback"
  fi
}

collect_security_config() {
  echo ""
  echo -e "  ${BOLD}Security services${NC} (~\$5/mo total):"
  echo ""

  if confirm "Enable all security services?" "default_yes"; then
    SECURITY_HUB="true"; GUARDDUTY="true"; INSPECTOR="true"
    ACCESS_ANALYZER="true"; CONFIG_RECORDER="true"
    ok "All security services enabled"
    return
  fi

  # Multi-select: user picks which to enable
  echo ""
  local selected
  _gum_or_die selected $GUM choose --no-limit \
    --header "Select services to enable (space to toggle, enter to confirm)" \
    --selected "AWS Security Hub,Amazon GuardDuty,Amazon Inspector,IAM Access Analyzer,AWS Config Recorder" \
    "AWS Security Hub" \
    "Amazon GuardDuty" \
    "Amazon Inspector" \
    "IAM Access Analyzer" \
    "AWS Config Recorder" || selected=""

  SECURITY_HUB="false"; GUARDDUTY="false"; INSPECTOR="false"
  ACCESS_ANALYZER="false"; CONFIG_RECORDER="false"
  while IFS= read -r svc; do
    case "$svc" in
      "AWS Security Hub")    SECURITY_HUB="true" ;;
      "Amazon GuardDuty")    GUARDDUTY="true" ;;
      "Amazon Inspector")    INSPECTOR="true" ;;
      "IAM Access Analyzer") ACCESS_ANALYZER="true" ;;
      "AWS Config Recorder") CONFIG_RECORDER="true" ;;
    esac
  done <<< "$selected"

  local enabled=""
  [[ "$SECURITY_HUB"    == "true" ]] && enabled+=" SecurityHub"
  [[ "$GUARDDUTY"        == "true" ]] && enabled+=" GuardDuty"
  [[ "$INSPECTOR"        == "true" ]] && enabled+=" Inspector"
  [[ "$ACCESS_ANALYZER"  == "true" ]] && enabled+=" AccessAnalyzer"
  [[ "$CONFIG_RECORDER"  == "true" ]] && enabled+=" Config"
  if [[ -n "$enabled" ]]; then ok "Enabled:${enabled}"; else warn "All security services disabled"; fi
}

# ============================================================================
# Parameter source-of-truth: single mapping for CFN Console and CFN CLI
# ============================================================================
# ⚠ KEEP THESE TWO ARRAYS IN SYNC — same order, same count
PARAM_CFN_NAMES=(EnvironmentName PackName ProfileName InstanceType DefaultModel ModelMode BedrockRegion LokiWatermark EnableBedrockForm EnableSecurityHub EnableGuardDuty EnableInspector EnableAccessAnalyzer EnableConfigRecorder ExistingVpcId ExistingSubnetId ExistingSubnetId2 RepoBranch KiroFromSecret TelegramBotTokenSecret TelegramUser Primary DailyDriver CodexModel EnableWebUIAuth WebUIAdminEmail EdgeLambdaVersionArn EdgeConfigSecretName EdgeConfigSecretArn SigningKeySecretName SigningKeySecretArn)
PARAM_VALUES=()  # populated by build_deploy_params()

# Per-pack default model (passed to CFN DefaultModel / bootstrap.sh --model).
# Packs that use AWS Bedrock get Bedrock model IDs; packs that use provider
# APIs (OpenAI, etc.) get provider-native model IDs. Without this mapping
# every pack inherits the template's Bedrock default, which breaks codex-cli
# (OpenAI rejects Bedrock ids with HTTP 400).
pack_default_model() {
  case "$1" in
    codex-cli)                echo "gpt-5.4" ;;
    kiro-cli)                 echo "kiro-cloud" ;;  # Kiro uses its own inference; value is informational only
    kirocrew)                 echo "kiro-cloud" ;;  # KiroCrew drives kiro-cli over ACP; same inference
    openclaw)                 echo "us.anthropic.claude-sonnet-4-6" ;;
    claude-code)              echo "us.anthropic.claude-sonnet-4-6" ;;
    troika)                   echo "us.anthropic.claude-sonnet-4-6" ;;
    # hermes depends on bedrockify; 'model' is the Bedrock id bedrockify
    # proxies to (NOT the Hermes-specific model ID, which is a separate
    # 'hermes-model' param on the pack).
    hermes)                   echo "us.anthropic.claude-sonnet-4-6" ;;
    *)                        echo "us.anthropic.claude-sonnet-4-6" ;;
  esac
}

# Populate PARAM_VALUES from user config (call after collect_config)
build_deploy_params() {
  # Bedrock region: use us-east-1 by default (widest model availability, cross-region inference)
  # Only override if the deploy region is itself a supported Bedrock region
  local bedrock_allowed="us-east-1 us-west-2 eu-west-1 eu-central-1 eu-north-1 ap-northeast-1 ap-southeast-1"
  if [[ " $bedrock_allowed " == *" $DEPLOY_REGION "* ]]; then
    BEDROCK_REGION="$DEPLOY_REGION"
  else
    BEDROCK_REGION="us-east-1"
  fi

  PARAM_VALUES=(
    "$ENV_NAME"
    "$PACK_NAME"
    "$PROFILE_NAME"
    "$INSTANCE_TYPE"
    "${DEFAULT_MODEL:-$(pack_default_model "$PACK_NAME")}"
    "bedrock"
    "$BEDROCK_REGION"
    "$LOKI_WATERMARK"
    "false"
    "$SECURITY_HUB"
    "$GUARDDUTY"
    "$INSPECTOR"
    "$ACCESS_ANALYZER"
    "$CONFIG_RECORDER"
    "${EXISTING_VPC_ID:-}"
    "${EXISTING_SUBNET_ID:-}"
    "${EXISTING_SUBNET_ID2:-}"
    "$REPO_BRANCH"
    "${KIRO_FROM_SECRET:-}"
    "${TELEGRAM_BOT_TOKEN_SECRET:-}"
    "${TELEGRAM_USER:-}"
    "${TROIKA_PRIMARY:-openclaw}"
    "${TROIKA_DAILY_DRIVER:-}"
    "${TROIKA_CODEX_MODEL:-openai.gpt-5.5}"
    "${WEBUI_AUTH_ENABLED:-false}"
    "${WEBUI_ADMIN_EMAIL:-}"
    "${EDGE_LAMBDA_VERSION_ARN:-}"
    "${EDGE_CONFIG_SECRET_NAME:-}"
    "${EDGE_CONFIG_SECRET_ARN:-}"
    "${SIGNING_KEY_SECRET_NAME:-}"
    "${SIGNING_KEY_SECRET_ARN:-}"
  )
  # Validate parallel arrays are in sync
  [[ ${#PARAM_CFN_NAMES[@]} -eq ${#PARAM_VALUES[@]} ]] \
    || fail "BUG: PARAM_CFN_NAMES has ${#PARAM_CFN_NAMES[@]} entries but PARAM_VALUES has ${#PARAM_VALUES[@]}"
}

# Format params as CFN Console URL query string (param_Key=Value), URL-encoded
format_console_params() {
  local params=""
  for i in "${!PARAM_CFN_NAMES[@]}"; do
    local encoded_val
    encoded_val=$(url_encode "${PARAM_VALUES[$i]}")
    params+="&param_${PARAM_CFN_NAMES[$i]}=${encoded_val}"
  done
  echo "$params"
}

# Format params as CFN CLI --parameters (ParameterKey=X,ParameterValue=Y)
format_cfn_cli_params() {
  local params=""
  for i in "${!PARAM_CFN_NAMES[@]}"; do
    [[ -n "$params" ]] && params+=" "
    params+="ParameterKey=${PARAM_CFN_NAMES[$i]},ParameterValue=${PARAM_VALUES[$i]}"
  done
  echo "$params"
}

# Format params for CFN deploy --parameter-overrides (Key=Value)
format_cfn_deploy_params() {
  local params=""
  for i in "${!PARAM_CFN_NAMES[@]}"; do
    [[ -n "$params" ]] && params+=" "
    params+="${PARAM_CFN_NAMES[$i]}=${PARAM_VALUES[$i]}"
  done
  echo "$params"
}

show_summary() {
  step "Review & confirm"

  local security_summary=""
  if [[ "$SECURITY_HUB" == "true" && "$GUARDDUTY" == "true" && "$INSPECTOR" == "true" \
     && "$ACCESS_ANALYZER" == "true" && "$CONFIG_RECORDER" == "true" ]]; then
    security_summary="all enabled"
  elif [[ "$SECURITY_HUB" == "false" && "$GUARDDUTY" == "false" && "$INSPECTOR" == "false" \
       && "$ACCESS_ANALYZER" == "false" && "$CONFIG_RECORDER" == "false" ]]; then
    security_summary="all disabled"
  else
    local enabled_list=""
    [[ "$SECURITY_HUB"    == "true" ]] && enabled_list+="Hub "
    [[ "$GUARDDUTY"        == "true" ]] && enabled_list+="Guard "
    [[ "$INSPECTOR"        == "true" ]] && enabled_list+="Inspector "
    [[ "$ACCESS_ANALYZER"  == "true" ]] && enabled_list+="Analyzer "
    [[ "$CONFIG_RECORDER"  == "true" ]] && enabled_list+="Config "
    security_summary="${enabled_list:-none}"
  fi

  local deploy_method_label="CloudFormation CLI"
  [[ "$DEPLOY_METHOD" == "$DEPLOY_CFN_CONSOLE" ]] && deploy_method_label="CloudFormation Console"

  local summary=""
  summary+="Branch        ${REPO_BRANCH}\n"
  summary+="Deploy via    ${deploy_method_label}\n"
  summary+="Account       ${ACCOUNT_ID}\n"
  summary+="Agent         ${PACK_NAME}\n"
  if [[ "${PACK_NAME:-}" == "troika" ]]; then
    summary+="Primary       ${TROIKA_PRIMARY:-openclaw}\n"
    summary+="Daily driver  ${TROIKA_DAILY_DRIVER:-${TROIKA_PRIMARY:-openclaw}}\n"
  fi
  summary+="Profile       ${PROFILE_NAME}\n"
  summary+="Instance      ${INSTANCE_TYPE}\n"
  summary+="Region        ${DEPLOY_REGION}\n"
  if [[ "${BEDROCK_ACCESS_OK:-unknown}" == "false" ]]; then
    if [[ "$BEDROCK_REGION" != "$DEPLOY_REGION" ]]; then
      summary+="Bedrock       ${BEDROCK_REGION} ⚠ model access NOT enabled — use 3rd-party inference after install\n"
    else
      summary+="Bedrock       ⚠ model access NOT enabled — use 3rd-party inference after install\n"
    fi
  elif [[ "$BEDROCK_REGION" != "$DEPLOY_REGION" ]]; then
    summary+="Bedrock       ${BEDROCK_REGION} (cross-region inference)\n"
  fi
  [[ -n "${EXISTING_VPC_ID:-}" ]] && summary+="VPC           reuse ${EXISTING_VPC_ID}\n"
  summary+="Security      ${security_summary}\n"
  summary+="Environment   ${ENV_NAME}"

  echo -e "$summary" | $GUM style --border rounded --border-foreground 117 \
    --foreground 255 --padding "1 2" --margin "0 2" --bold
  echo ""

  # In simple mode, offer "Change settings" to switch to advanced
  if [[ "$INSTALL_MODE" == "simple" && "$AUTO_YES" != true ]]; then
    local action
    _gum_or_die action $GUM choose --header "Ready to deploy?" \
      "Deploy" \
      "Change settings (advanced mode)" || action="Deploy"
    if [[ "$action" == *"Change settings"* ]]; then
      INSTALL_MODE="advanced"
      return 1  # signal to re-run config in advanced mode
    fi
  else
    confirm_or_abort "Proceed with deployment?" "default_yes"
  fi
}

# ============================================================================
# Phase: Clone / prepare repo (CLI deploys only)
# ============================================================================
prepare_repo() {
  echo ""
  CLONE_DIR="/tmp/lowkey-$$"
  dbg "prepare_repo: CLONE_DIR=$CLONE_DIR DEBUG_IN_REPO=$DEBUG_IN_REPO"

  if [[ "$DEBUG_IN_REPO" == "true" ]]; then
    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
    info "Debug mode: cloning local repo ${repo_root} → ${CLONE_DIR}"
    rm -rf "$CLONE_DIR" 2>/dev/null || true
    git clone "$repo_root" "$CLONE_DIR" 2>/dev/null
    cd "$CLONE_DIR"
    ok "Local repo cloned: ${CLONE_DIR}"
  else
    echo ""
    info "Cloning lowkey into ${CLONE_DIR}..."

    if [[ -d "$CLONE_DIR/.git" ]]; then
      info "Directory exists, syncing to latest..."
      run_or_fail "Git fetch" git -C "$CLONE_DIR" fetch origin
      local branch
      branch=$(git -C "$CLONE_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
      if ! git -C "$CLONE_DIR" merge --ff-only "origin/$branch" 2>/dev/null; then
        warn "Local repo diverged from remote — resetting to origin/$branch"
        git -C "$CLONE_DIR" reset --hard "origin/$branch" 2>&1 | tail -1
      fi
    else
      rm -rf "$CLONE_DIR" 2>/dev/null || true
      run_or_fail "Cloning repository" git clone --depth 1 -b "${REPO_BRANCH:-main}" "$REPO_URL" "$CLONE_DIR"
    fi

    cd "$CLONE_DIR"
    ok "Repository ready: ${CLONE_DIR}"
  fi
}

# ============================================================================
# Deploy: CloudFormation Console (option 1)
# ============================================================================
deploy_console() {
  # Load pack profile for TUI command display
  local _pack_profile="${CLONE_DIR:-}/packs/${PACK_NAME}/resources/shell-profile.sh"
  if [[ -f "$_pack_profile" ]]; then
    eval "$(grep -E '^PACK_(TUI_COMMAND|BANNER_NAME|BANNER_EMOJI)=' "$_pack_profile")"
  fi
  echo ""
  info "Preparing CloudFormation Console launch..."

  local bucket="${ENV_NAME}-cfn-templates-${ACCOUNT_ID}"
  create_s3_bucket "$bucket" "$DEPLOY_REGION"

  local tmp; tmp=$(mktemp /tmp/lowkey-cfn-template.XXXXXX.yaml)
  TEMPLATE_RAW_URL="$(get_template_url)"
  run_or_fail "Downloading template" curl -sfL "$TEMPLATE_RAW_URL" -o "$tmp"
  rm -f "$_RUN_LOG"

  run_or_fail "Uploading template to S3" \
    aws s3 cp "$tmp" "s3://${bucket}/lowkey/template.yaml" --region "$DEPLOY_REGION"
  rm -f "$_RUN_LOG"
  rm -f "$tmp"

  # Generate a pre-signed URL (valid 1 hour) since the bucket blocks public access
  local s3_url
  s3_url=$(aws s3 presign "s3://${bucket}/lowkey/template.yaml" \
    --expires-in 3600 --region "$DEPLOY_REGION") \
    || fail "Could not generate pre-signed URL for template"
  local encoded
  encoded=$(url_encode "$s3_url")

  local url="https://${DEPLOY_REGION}.console.aws.amazon.com/cloudformation/home?region=${DEPLOY_REGION}#/stacks/create/review"
  url+="?templateURL=${encoded}&stackName=${ENV_NAME}-stack"
  url+="$(format_console_params)"

  echo ""
  echo ""
  echo -e "  ${GREEN}${BOLD}Open this link in your browser to launch the stack wizard:${NC}"
  echo ""
  echo -e "  ${CYAN}${url}${NC}"
  echo ""

  if open_url "$url"; then ok "Opened in your browser"
  else info "Copy the link above and paste it into your browser"; fi

  echo ""
  echo -e "  ${BOLD}What to do next:${NC}"
  echo ""
  echo -e "    ${DIM}1.${NC} Log in to AWS if prompted"
  echo -e "    ${DIM}2.${NC} Review the parameters ${DIM}(your choices are pre-filled)${NC}"
  echo -e "    ${DIM}3.${NC} Check ${BOLD}\"I acknowledge that AWS CloudFormation might create IAM resources\"${NC}"
  echo -e "    ${DIM}4.${NC} Click ${GREEN}${BOLD}Create stack${NC}"
  echo -e "    ${DIM}5.${NC} Wait ~10 minutes for the stack to finish"
  echo -e "    ${DIM}6.${NC} Find the Instance ID in the stack ${BOLD}Outputs${NC} tab"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    ${CYAN}$(ssm_connect_cmd '<instance-id>')${NC}"
  echo -e "    ${CYAN}${PACK_TUI_COMMAND:-bash --login}${NC}"
  echo ""
  echo -e "  ${DIM}Docs:${NC}  ${DOCS_URL}"
  echo ""
  echo -e "  ${YELLOW}Note:${NC} Template bucket ${DIM}${bucket}${NC} was created in your account."
  echo -e "  ${DIM}Delete it after the stack is created:${NC}"
  echo -e "    ${DIM}aws s3 rb s3://${bucket} --force --region ${DEPLOY_REGION}${NC}"
  echo ""
}

# ============================================================================
# Deploy: CloudFormation via CLI
# ============================================================================
deploy_cfn_stack() {
  local template="$1" capabilities="$2"
  STACK_NAME="${ENV_NAME}-stack"

  # Template is ~62KB, CFN inline limit is 51,200 bytes. Upload to S3 first.
  local bucket="${ENV_NAME}-cfn-templates-${ACCOUNT_ID}"
  create_s3_bucket "$bucket" "$DEPLOY_REGION"

  info "Uploading template to S3 (inline limit is 51.2KB, template is $(wc -c < "$template") bytes)"
  aws s3 cp "$template" "s3://${bucket}/lowkey/template.yaml" --region "$DEPLOY_REGION" >/dev/null \
    || fail "Failed to upload template to S3"

  # aws cloudformation deploy is idempotent: it creates a missing stack and
  # updates an existing one. --no-fail-on-empty-changeset makes reruns safe.
  # shellcheck disable=SC2046
  aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file "$template" \
    --s3-bucket "$bucket" \
    --s3-prefix lowkey/deploy \
    --region "$DEPLOY_REGION" \
    --capabilities $capabilities \
    --parameter-overrides $(format_cfn_deploy_params) \
    --no-fail-on-empty-changeset \
    || fail "CloudFormation deployment failed"

  info "Stack deployment complete"

  INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
  PUBLIC_IP=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)
}

wait_for_cfn_stack() {
  local start_time=$SECONDS
  local seen_events=""
  local max_wait=1800  # 30 minutes

  while true; do
    local elapsed=$(( SECONDS - start_time ))
    if [[ $elapsed -ge $max_wait ]]; then
      warn "Timed out after 30 minutes. Check the CloudFormation console for status."
      break
    fi

    # Fetch recent stack events (newest first), show unseen ones
    local events_json
    events_json=$(aws cloudformation describe-stack-events \
      --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'StackEvents[0:20].[EventId,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
      --output json 2>/dev/null) || true

    if [[ -n "$events_json" ]]; then
      # Process events in reverse (oldest first) so they appear chronologically
      local count
      count=$(echo "$events_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      for (( i=count-1; i>=0; i-- )); do
        local event_id resource status reason
        event_id=$(echo "$events_json" | python3 -c "import sys,json; e=json.load(sys.stdin)[$i]; print(e[0])" 2>/dev/null)
        [[ -z "$event_id" ]] && continue
        # Skip already-seen events
        if [[ "$seen_events" == *"$event_id"* ]]; then continue; fi
        seen_events+=" $event_id"

        resource=$(echo "$events_json" | python3 -c "import sys,json; e=json.load(sys.stdin)[$i]; print(e[1])" 2>/dev/null)
        status=$(echo "$events_json" | python3 -c "import sys,json; e=json.load(sys.stdin)[$i]; print(e[2])" 2>/dev/null)
        reason=$(echo "$events_json" | python3 -c "import sys,json; e=json.load(sys.stdin)[$i]; print(e[3] or '')" 2>/dev/null)

        case "$status" in
          *COMPLETE)      echo -e "  ${GREEN}✓${NC} ${resource} ${DIM}${status}${NC}" ;;
          *IN_PROGRESS)   echo -e "  ${BLUE}+${NC} ${resource} ${DIM}${status}${NC}" ;;
          *FAILED*|*ROLLBACK*)
            echo -e "  ${RED}✗${NC} ${resource} ${status}"
            [[ -n "$reason" ]] && echo -e "    ${RED}${reason}${NC}"
            ;;
        esac
      done
    fi

    # Check overall stack status
    local stack_status rc=0
    stack_status=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].StackStatus' --output text 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
      echo ""; fail "Stack no longer exists or is inaccessible: $stack_status"
    fi

    local elapsed_str; elapsed_str=$(elapsed_fmt $elapsed)
    case "$stack_status" in
      CREATE_COMPLETE)     echo ""; ok "Stack created! ${DIM}(${elapsed_str})${NC}"; break ;;
      *FAILED*|*ROLLBACK_COMPLETE) echo ""; fail "Stack failed: $stack_status" ;;
    esac

    sleep 10
  done
}

PACK_NAME="openclaw"  # Default pack; overridden by collect_config

# VPC reuse: set by check_existing_deployments(); empty = create new VPC
EXISTING_VPC_ID=""
EXISTING_SUBNET_ID=""
EXISTING_SUBNET_ID2=""  # KiroCrew ALB needs a 2nd AZ subnet on existing-VPC path

# ============================================================================
# Ensure Lowkey-Session SSM document exists (instance-scoped, not account-wide)
ensure_ssm_session_document() {
  # Build pack-specific document name to avoid collisions between different agents
  SSM_DOC_NAME="Lowkey-Session-${PACK_NAME}"

  # Source pack profile to get the correct TUI command for this agent
  local pack_profile="${CLONE_DIR}/packs/${PACK_NAME}/resources/shell-profile.sh"
  local tui_cmd="bash --login"
  if [[ -f "$pack_profile" ]]; then
    # Extract only variable assignments — don't execute arbitrary profile code
    eval "$(grep -E '^PACK_(TUI_COMMAND|BANNER_NAME|BANNER_EMOJI)=' "$pack_profile")"
    tui_cmd="${PACK_TUI_COMMAND:-bash --login}"
  fi
  local shell_cmd="cd ~ && bash --login -c \"${tui_cmd} || exec bash --login\""
  local doc_content
  doc_content=$(jq -nc \
    --arg desc "SSM session for ${PACK_BANNER_NAME:-Agent} - starts as ec2-user and launches agent" \
    --arg shell "$shell_cmd" \
    '{schemaVersion:"1.0",description:$desc,sessionType:"Standard_Stream",inputs:{runAsEnabled:true,runAsDefaultUser:"ec2-user",shellProfile:{linux:$shell}}}')

  if aws ssm describe-document --name "$SSM_DOC_NAME" --region "$DEPLOY_REGION" &>/dev/null; then
    # Update existing document and set new version as default
    local new_version
    new_version=$(aws ssm update-document \
      --name "$SSM_DOC_NAME" \
      --content "$doc_content" \
      --document-version '$LATEST' \
      --region "$DEPLOY_REGION" \
      --query 'DocumentDescription.DocumentVersion' --output text 2>/dev/null) || true
    if [[ -n "$new_version" && "$new_version" =~ ^[0-9]+$ ]]; then
      aws ssm update-document-default-version \
        --name "$SSM_DOC_NAME" \
        --document-version "$new_version" \
        --region "$DEPLOY_REGION" >/dev/null 2>&1 || true
    fi
    ok "SSM session document: ${SSM_DOC_NAME} (updated)"
    return 0
  fi
  info "Creating ${SSM_DOC_NAME} SSM document..."
  aws ssm create-document \
    --name "$SSM_DOC_NAME" \
    --document-type "Session" \
    --content "$doc_content" \
    --region "$DEPLOY_REGION" >/dev/null 2>&1 || {
      warn "Could not create ${SSM_DOC_NAME} document (may need ssm:CreateDocument permission)"
      info "Connect with: aws ssm start-session --target \${INSTANCE_ID} --region \${DEPLOY_REGION}"
      info "Then run: sudo su - ec2-user"
      return 0
    }
  ok "Created ${SSM_DOC_NAME} SSM document"
}

# Post-deploy: wait for bootstrap + show results
# ============================================================================
wait_for_bootstrap() {
  step "Bootstrap"
  info "Waiting for Lowkey to bootstrap..."
  echo -e "  ${DIM}Instance: ${INSTANCE_ID}  |  IP: ${PUBLIC_IP}${NC}"
  echo ""

  # Clear stale SSM params from previous deploys to avoid false failure detection
  aws ssm delete-parameter --name "/loki/setup-status" --region "$DEPLOY_REGION" 2>/dev/null || true
  aws ssm delete-parameter --name "/loki/setup-step" --region "$DEPLOY_REGION" 2>/dev/null || true
  aws ssm delete-parameter --name "/loki/setup-log" --region "$DEPLOY_REGION" 2>/dev/null || true

  local boot_start=$SECONDS
  local current_step="" last_step=""
  for i in $(seq 1 60); do

    # ── 1. Read step + status from SSM parameters (fast, no SSM command) ──
    local setup_status
    setup_status=$(aws ssm get-parameter --name "/loki/setup-status" \
      --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")

    if [[ "$setup_status" == "FAILED" ]]; then
      echo ""
      local fail_step
      fail_step=$(aws ssm get-parameter --name "/loki/setup-step" \
        --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "unknown step")
      local fail_log
      fail_log=$(aws ssm get-parameter --name "/loki/setup-log" \
        --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")
      echo ""
      echo -e "  ${RED}✗ Bootstrap FAILED${NC}"
      echo -e "  ${BOLD}Step:${NC} ${fail_step}"
      if [[ -n "$fail_log" ]]; then
        echo ""
        echo -e "  ${BOLD}Last log output:${NC}"
        echo "$fail_log" | tail -20 | sed 's/^/    /'
      fi

      # Auto-fetch full bootstrap log via SSM
      echo ""
      info "Fetching full bootstrap log from instance..."
      local log_cmd_id
      log_cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters 'commands=["cat /var/log/loki-bootstrap.log 2>/dev/null || echo LOG_NOT_FOUND"]' \
        --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")
      if [[ -n "$log_cmd_id" ]]; then
        sleep 8
        local full_log
        full_log=$(aws ssm get-command-invocation --command-id "$log_cmd_id" \
          --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
          --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
        if [[ -n "$full_log" && "$full_log" != "LOG_NOT_FOUND" ]]; then
          local log_file="/tmp/loki-bootstrap-${INSTANCE_ID}.log"
          echo "$full_log" > "$log_file"
          ok "Full bootstrap log saved to: ${log_file}"
          echo ""
          echo -e "  ${BOLD}Last 30 lines:${NC}"
          echo "$full_log" | tail -30 | sed 's/^/    /'
        else
          warn "Could not retrieve bootstrap log via SSM"
          show_ssm_help "$INSTANCE_ID"
        fi
      else
        warn "SSM command failed — instance may not be reachable yet"
        show_ssm_help "$INSTANCE_ID"
      fi

      echo ""
      return 1
    fi

    current_step=$(aws ssm get-parameter --name "/loki/setup-step" \
      --region "$DEPLOY_REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "")

    # Print new line when step changes so the user sees the progression
    if [[ -n "$current_step" && "$current_step" != "$last_step" && -n "$last_step" ]]; then
      local ts; ts=$(elapsed_fmt $(( SECONDS - boot_start )))
      echo -e "  ${GREEN}✓${NC} ${last_step}  ${DIM}[${ts}]${NC}"
    fi
    [[ -n "$current_step" ]] && last_step="$current_step"

    # ── 2. Check if bootstrap is done (SSM command round-trip) ──
    local cmd_id
    cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["test -f /tmp/loki-bootstrap-done && echo READY || echo WAITING"]' \
      --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")

    if [[ -n "$cmd_id" ]]; then
      sleep 3

      local output
      output=$(aws ssm get-command-invocation --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
      local boot_elapsed=$(( SECONDS - boot_start ))
      local boot_elapsed_str; boot_elapsed_str=$(elapsed_fmt $boot_elapsed)
      if [[ "$output" == *"READY"* ]]; then
        # Print final step as completed
        if [[ -n "$current_step" ]]; then
          echo -e "  ${GREEN}✓${NC} ${current_step}  ${DIM}[${boot_elapsed_str}]${NC}"
        fi
        ok "Lowkey is ready! ${DIM}(${boot_elapsed_str})${NC}"
        return
      fi
    fi

    sleep 10
  done
  warn "Bootstrap check timed out — Lowkey may still be starting up"
}

show_complete() {
  step "Done!"
  local ssm_cmd
  ssm_cmd="$(ssm_connect_cmd "$INSTANCE_ID")"

  # Load pack-specific commands for the completion screen
  local pack_profile="${CLONE_DIR}/packs/${PACK_NAME}/resources/shell-profile.sh"
  local pack_commands="${PACK_TUI_COMMAND:-bash --login}"
  local pack_name_display="${PACK_BANNER_NAME:-Agent}"
  if [[ -f "$pack_profile" ]]; then
    # Source in subshell to extract variables safely (PACK_* only)
    eval "$(bash -c 'source "$1" 2>/dev/null; for v in PACK_TUI_COMMAND PACK_BANNER_NAME PACK_BANNER_EMOJI PACK_BANNER_COMMANDS; do [[ -n "${!v}" ]] && printf "%s=%q\n" "$v" "${!v}"; done' _ "$pack_profile")"
    pack_name_display="${PACK_BANNER_NAME:-Agent}"
    pack_commands="${PACK_BANNER_COMMANDS:-${PACK_TUI_COMMAND:-bash --login}}"
  fi

  echo ""
  local info_block=""
  info_block+="Instance   ${INSTANCE_ID}\n"
  info_block+="IP         ${PUBLIC_IP}\n"
  info_block+="Region     ${DEPLOY_REGION}\n"
  info_block+="Account    ${ACCOUNT_ID}\n"
  info_block+="Docs       ${DOCS_URL}"

  local next_block=""
  next_block+="Connect to your agent:\n\n"
  next_block+="  ${ssm_cmd}\n\n"

  # KiroCrew-specific: dashboard URL with pre-baked login token so the user
  # can click straight through to an authenticated session. Falls back
  # gracefully at every layer (no CF URL -> raw IP; no token -> plain URL).
  if [[ "${PACK_NAME}" == "kirocrew" ]]; then
    local cf_url=""
    cf_url=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$DEPLOY_REGION" \
      --query 'Stacks[0].Outputs[?OutputKey==`KiroCrewDashboardUrl`].OutputValue' --output text 2>/dev/null)
    local dash_base=""
    if [[ -n "$cf_url" && "$cf_url" != "None" ]]; then
      dash_base="$cf_url"
    elif [[ -n "${PUBLIC_IP}" ]]; then
      dash_base="http://${PUBLIC_IP}:5476"
    fi

    # Fetch a login token from the instance so the user gets a click-through URL.
    # kirocrew is installed under the ec2-user home (not on the default PATH the
    # SSM shell inherits), so invoke it via a login shell as ec2-user.
    local dash_token="" token_cmd_id="" token_out=""
    token_cmd_id=$(aws ssm send-command \
      --instance-ids "$INSTANCE_ID" \
      --document-name AWS-RunShellScript \
      --parameters 'commands=["sudo -u ec2-user bash -lc \"kirocrew token --ttl 24h 2>/dev/null\" | tail -n +1"]' \
      --region "$DEPLOY_REGION" --output text --query 'Command.CommandId' 2>/dev/null || echo "")
    if [[ -n "$token_cmd_id" ]]; then
      # Poll up to ~15s for the SSM command to finish.
      local _t
      for _t in 1 2 3 4 5 6 7 8; do
        sleep 2
        local st
        st=$(aws ssm get-command-invocation --command-id "$token_cmd_id" \
          --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
          --query 'Status' --output text 2>/dev/null || echo "")
        [[ "$st" == "Success" || "$st" == "Failed" || "$st" == "TimedOut" ]] && break
      done
      token_out=$(aws ssm get-command-invocation --command-id "$token_cmd_id" \
        --instance-id "$INSTANCE_ID" --region "$DEPLOY_REGION" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "")
      # kirocrew token prints both a localhost URL and a public URL; pull the JWT
      # out of either. Format is `...?token=<jwt>` where <jwt> has three
      # dot-separated base64url segments.
      dash_token=$(printf '%s' "$token_out" | grep -oE 'token=[A-Za-z0-9_.-]+' | head -1 | sed 's/^token=//')
    fi

    next_block+="Dashboard:\n"
    if [[ -n "$dash_base" && -n "$dash_token" ]]; then
      next_block+="  ${dash_base}/?token=${dash_token}\n\n"
      next_block+="  ${DIM}(Token valid 24h. Regenerate on the instance with: kirocrew token --ttl 24h)${NC}\n\n"
    elif [[ -n "$dash_base" ]]; then
      next_block+="  ${dash_base}\n\n"
      next_block+="Generate login token (run on instance):\n"
      next_block+="  kirocrew token --ttl 24h\n\n"
    fi
  fi

  next_block+="Then run:\n"
  while IFS= read -r line; do
    [[ -n "$line" ]] && next_block+="  ${line}\n"
  done <<< "$pack_commands"

  $GUM style --foreground 82 --bold --margin "0 2" \
    "${pack_name_display} is deployed and running!"
  echo ""
  echo -e "$info_block" | $GUM style --foreground 255 --padding "1 2" --margin "0 2"
  echo ""
  # No border on the next-steps block: URLs and commands need to be easy to
  # copy without the box side rails breaking word-wrap or triple-click select.
  echo -e "$next_block" | $GUM style --foreground 117 --bold --padding "1 2" --margin "0 2"
  echo ""

  # Try to copy connect command to clipboard
  copy_to_clipboard "$ssm_cmd" && ok "Connect command copied to clipboard"
  echo ""

  safe_cleanup_dir "${CLONE_DIR:-}" "cloned repo directory" '/tmp/*' "$HOME/.*" '*/lowkey'
}

# ============================================================================
# Account Rename
# ============================================================================

# SAFE_NAME_PATTERN: printable ASCII subset excluding shell metacharacters.
# Keeps: alnum, space, hyphen, underscore, dot, plus, equals, at, colon,
#        semicolon, comma, exclamation, question, hash, parens, brackets,
#        braces, tilde, caret, slash.
# Strips: $, `, ", \, &, |, *, ', %  and control chars.
_sanitize_account_name() {
  local name="$1"
  # Strip control chars, then strip excluded metacharacters
  printf '%s' "$name" \
    | tr -d '\000-\037' \
    | sed 's/[\$`"\\&|*'\''%]//g'
}

_emit_rename_telemetry() {
  # Usage: _emit_rename_telemetry <renamed> <allowed> [skipped_reason]
  local renamed="${1:-false}"
  local allowed="${2:-false}"
  local skipped_reason="${3:-}"
  # Defensive: coerce to JSON booleans
  [[ "$renamed" == "true" ]] || renamed="false"
  [[ "$allowed" == "true" ]] || allowed="false"
  local auto_val="false"
  [[ "$AUTO_RENAME_ACCOUNT" == "true" ]] && auto_val="true"
  local props
  props=$(printf '{"renamed":%s,"allowed":%s,"auto_rename_enabled":%s' \
    "$renamed" "$allowed" "$auto_val")
  # Note: skipped_reason values are always hardcoded string literals from callers.
  # Do not pass user input here — the printf pattern does not escape for JSON.
  if [[ -n "$skipped_reason" ]]; then
    props+=$(printf ',"skipped_reason":"%s"' "$skipped_reason")
  fi
  props+='}'
  _telem_event "install.account_renamed" "$props" 2>/dev/null || true
}

maybe_rename_account() {
  # Step 1: Check disable flag
  if [[ "$DISABLE_ACCOUNT_RENAME" == "true" ]]; then
    [[ "$AUTO_RENAME_ACCOUNT" == "true" ]] && \
      info "Both --auto-rename-account-enabled and --disable-account-rename set; rename disabled"
    info "Account rename disabled via --disable-account-rename"
    _emit_rename_telemetry false false "disabled_flag"
    return 0
  fi

  # Step 2: Read current account name
  local account_info current_name
  if ! account_info=$(aws account get-account-information --output json 2>&1); then
    warn "Could not read account name"
    _emit_rename_telemetry false false "api_error"
    return 0
  fi
  current_name=$(printf '%s' "$account_info" | jq -r '.AccountName // ""' 2>/dev/null || printf '')

  # Step 3: Already prefixed?
  if _account_already_prefixed "$current_name"; then
    return 0
  fi

  # Step 4: Build proposed name (sets _RENAME_PROPOSED, _RENAME_WAS_TRUNCATED)
  _build_proposed_name "$current_name"
  local proposed="$_RENAME_PROPOSED"
  local was_truncated="$_RENAME_WAS_TRUNCATED"

  # Step 5: Resolve final name (headless or interactive)
  # Sets _RENAME_FINAL_NAME or returns 0 with telemetry emitted on skip.
  if ! _resolve_final_name "$proposed" "$current_name" "$was_truncated"; then
    return 0  # user skipped or headless without opt-in (telemetry already emitted)
  fi

  # Step 6: Apply rename via AWS API
  _apply_account_rename "$_RENAME_FINAL_NAME" "$current_name"
}

# Returns 0 (true) if already prefixed and handled; 1 otherwise.
_account_already_prefixed() {
  local current_name="$1"
  local lower_name
  lower_name=$(printf '%s' "$current_name" | tr '[:upper:]' '[:lower:]')
  if [[ "$lower_name" == lowkey* ]]; then
    local display_name
    display_name=$(printf '%s' "$current_name" | tr -d '\000-\037')
    ok "Account already named for Lowkey: $(printf '%s' "$display_name")"
    # Write SSM params if they don't exist yet (first install with pre-existing prefix).
    # Note: stripped_original is a best-guess — if account was manually named
    # "LOWKEY-Foo", we store "Foo" but the true pre-Lowkey original is unknown.
    if ! aws ssm get-parameter --name "/loki/original-account-name" \
        --region "${DEPLOY_REGION:-$REGION}" --output text >/dev/null 2>&1; then
      local stripped_original="${current_name:7}"  # strip 7-char prefix (Lowkey-)
      [[ -n "$stripped_original" ]] || stripped_original="$ACCOUNT_ID"
      aws ssm put-parameter --name "/loki/original-account-name" \
        --value "$stripped_original" --type String --overwrite \
        --region "${DEPLOY_REGION:-$REGION}" >/dev/null 2>&1 || true
      aws ssm put-parameter --name "/loki/installed-account-name" \
        --value "$current_name" --type String --overwrite \
        --region "${DEPLOY_REGION:-$REGION}" >/dev/null 2>&1 || true
    fi
    _emit_rename_telemetry false false "already_prefixed"
    return 0
  fi
  return 1
}

# Builds the proposed "Lowkey-<sanitized>" name.
# Sets _RENAME_PROPOSED and _RENAME_WAS_TRUNCATED.
_build_proposed_name() {
  local current_name="$1"
  local sanitized
  _RENAME_WAS_TRUNCATED=false
  _RENAME_PROPOSED=""

  sanitized=$(_sanitize_account_name "$current_name")
  if [[ -z "$sanitized" ]]; then
    _RENAME_PROPOSED="Lowkey-${ACCOUNT_ID}"
  else
    _RENAME_PROPOSED="Lowkey-${sanitized}"
  fi

  if [[ ${#_RENAME_PROPOSED} -gt 50 ]]; then
    _RENAME_PROPOSED="${_RENAME_PROPOSED:0:50}"
    _RENAME_PROPOSED=$(printf '%s' "$_RENAME_PROPOSED" | sed 's/[- ]*$//')
    _RENAME_WAS_TRUNCATED=true
  fi
  if [[ ${#_RENAME_PROPOSED} -lt 6 ]]; then
    _RENAME_PROPOSED="Lowkey-${ACCOUNT_ID}"
    _RENAME_WAS_TRUNCATED=false
  fi
}

# Resolves the final name via headless auto-apply or interactive prompt.
# Sets _RENAME_FINAL_NAME on success (return 0).
# Returns 1 if user skipped or headless without opt-in (telemetry emitted inside).
_resolve_final_name() {
  local proposed="$1" current_name="$2" was_truncated="$3"
  _RENAME_FINAL_NAME=""

  if [[ "$AUTO_YES" == "true" ]]; then
    # Headless mode
    if [[ "$AUTO_RENAME_ACCOUNT" != "true" ]]; then
      info "Headless mode: account rename skipped (pass --auto-rename-account-enabled to enable)"
      _emit_rename_telemetry false false "headless_no_opt_in"
      return 1
    fi
    _RENAME_FINAL_NAME="$proposed"
    if [[ "$was_truncated" == "true" ]]; then
      warn "Account name truncated to 50 chars: $(printf '%s' "$_RENAME_FINAL_NAME")"
    fi
  else
    # Interactive mode
    if [[ "$was_truncated" == "true" ]]; then
      info "Name truncated to 50 chars"
    fi
    echo ""
    local safe_current safe_proposed
    safe_current=$(printf '%s' "$current_name")
    safe_proposed=$(printf '%s' "$proposed")
    printf '%s\n' \
      "🏷️  AWS ACCOUNT NAME" \
      "" \
      "Current AWS account name:   ${safe_current}" \
      "Proposed AWS account name:  ${safe_proposed}" \
      "" \
      "Adding the 'Lowkey-' prefix is highly recommended." \
      "It enables:" \
      "  • Governance & compliance tracking" \
      "  • Cost attribution across your organization" \
      "  • Quick identification of Lowkey-managed accounts" \
      "" \
      "This name appears in the AWS console account" \
      "switcher and billing." | $GUM style \
      --border double --border-foreground 117 \
      --foreground 255 --padding "1 2" --margin "0 2" \
      --bold
    echo ""

    local choice
    _gum_or_die choice $GUM choose --header "Rename this AWS account?" \
      "Rename to $proposed" "Edit name" "Skip" || choice="Skip"

    # Use if/elif instead of case to avoid glob pattern matching on $proposed
    # (account names may contain ?, [], which are bash glob characters)
    if [[ "$choice" == "Rename to $proposed" ]]; then
        _RENAME_FINAL_NAME="$proposed"
    elif [[ "$choice" == "Edit name" ]]; then
        local edit_attempts=0
        while true; do
          edit_attempts=$((edit_attempts + 1))
          if [[ $edit_attempts -gt 3 ]]; then
            warn "Too many invalid attempts, skipping rename"
            _emit_rename_telemetry false false "user_declined"
            return 1
          fi
          _gum_or_die _RENAME_FINAL_NAME $GUM input --placeholder "Enter account name (1-50 chars)" \
            --value "$proposed" || _RENAME_FINAL_NAME=""
          # Validate against SAFE_NAME_PATTERN — reject (don't silently mutate)
          local sanitized_check
          sanitized_check=$(_sanitize_account_name "$_RENAME_FINAL_NAME")
          if [[ "$sanitized_check" != "$_RENAME_FINAL_NAME" ]]; then
            warn "Name contains invalid characters (no \$, \`, \", \\, &, |, *, ', %)"
            continue
          fi
          if [[ -z "$_RENAME_FINAL_NAME" || "${_RENAME_FINAL_NAME// /}" == "" ]]; then
            warn "Name cannot be empty or whitespace-only"
            continue
          fi
          if [[ ${#_RENAME_FINAL_NAME} -gt 50 ]]; then
            warn "Name must be 50 characters or less (got ${#_RENAME_FINAL_NAME})"
            continue
          fi
          break
        done
    else
        info "Keeping account name: $(printf '%s' "$current_name")"
        _emit_rename_telemetry false false "user_declined"
        return 1
    fi
  fi
  return 0
}

# Calls put-account-name with retry, writes SSM params. All non-fatal.
_apply_account_rename() {
  local final_name="$1" current_name="$2"
  local put_err

  if ! put_err=$(aws account put-account-name --account-name "$final_name" 2>&1); then
    if [[ "$put_err" == *"TooManyRequestsException"* || "$put_err" == *"429"* ]]; then
      sleep 2
      if ! put_err=$(aws account put-account-name --account-name "$final_name" 2>&1); then
        warn "Could not rename account: $(printf '%s' "$put_err"). Deployment will continue."
        _emit_rename_telemetry false true "api_error"
        return 0
      fi
    else
      warn "Could not rename account: $(printf '%s' "$put_err"). Deployment will continue."
      _emit_rename_telemetry false true "api_error"
      return 0
    fi
  fi

  ok "Account renamed to $(printf '%s' "$final_name")"
  info "May take up to 4 hours to appear everywhere in AWS console"
  _emit_rename_telemetry true true

  # Store original + installed names in SSM (non-fatal)
  aws ssm put-parameter --name "/loki/original-account-name" \
    --value "$current_name" --type String --overwrite \
    --region "${DEPLOY_REGION:-$REGION}" >/dev/null 2>&1 || \
    warn "Could not store original account name in SSM (non-fatal)"
  aws ssm put-parameter --name "/loki/installed-account-name" \
    --value "$final_name" --type String --overwrite \
    --region "${DEPLOY_REGION:-$REGION}" >/dev/null 2>&1 || \
    warn "Could not store installed account name in SSM (non-fatal)"
}

# ============================================================================
# Main
# ============================================================================
run_config_and_review() {
  if [[ "$INSTALL_MODE" == "simple" ]]; then
    # Simple mode: pack + profile, then auto-configure (defaults to CFN CLI)
    collect_config_simple
    # Auto-detect VPC reuse
    check_existing_deployments
  else
    # Advanced mode: full interactive flow
    choose_deploy_method
    collect_config
    check_existing_deployments
  fi

  # VPC quota check (skip if reusing)
  if [[ -z "${EXISTING_VPC_ID:-}" ]]; then
    check_vpc_quota
  else
    ok "Skipping VPC quota check (reusing existing VPC ${EXISTING_VPC_ID})"
  fi

  build_deploy_params

  # Pack-specific parameter collection (after build_deploy_params so we can amend)
  if [[ "${PACK_NAME:-}" == "roundhouse" ]]; then
    if [[ -z "${TELEGRAM_BOT_TOKEN_SECRET:-}" ]]; then
      _RH_BOT_TOKEN="${TELEGRAM_BOT_TOKEN_RAW:-}"
      if [[ -z "$_RH_BOT_TOKEN" ]]; then
        echo ""
        echo -e "  ${BOLD}Roundhouse connects to Telegram.${NC}"
        echo -e "  Create a bot via @BotFather and paste the token below."
        echo ""
        prompt_secret "Telegram bot token" _RH_BOT_TOKEN ""
      fi
      if [[ -z "$_RH_BOT_TOKEN" ]]; then
        fail "Telegram bot token is required for roundhouse pack"
      fi
      # Validate token format
      if [[ ! "$_RH_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        fail "Invalid Telegram bot token format (expected: 123456:ABC-DEF...)"
      fi
      # Secret name determined now; actual write deferred until after user confirms
      _RH_SECRET_NAME="/lowkey/${ENV_NAME}/telegram-bot-token"
      TELEGRAM_BOT_TOKEN_SECRET="$_RH_SECRET_NAME"
    fi
    if [[ -z "${TELEGRAM_USER:-}" ]]; then
      prompt "Your Telegram username (without @)" TELEGRAM_USER ""
      if [[ -z "${TELEGRAM_USER:-}" ]]; then
        fail "Telegram username is required for roundhouse pack"
      fi
    fi
    # Rebuild params with telegram values now set
    build_deploy_params
  fi

  # Pack-specific: kiro-cli/kirocrew interactive API key for headless mode
  if [[ "${PACK_NAME:-}" == "kiro-cli" || "${PACK_NAME:-}" == "kirocrew" ]]; then
    if [[ -z "${KIRO_FROM_SECRET:-}" && "$AUTO_YES" != true ]]; then
      echo ""
      echo -e "  ${BOLD}Kiro CLI supports headless mode (no browser login).${NC}"
      echo -e "  Create an API key at: ${CYAN}https://app.kiro.dev/settings/api-keys${NC}"
      echo -e "  (Your organization must have API keys enabled.)"
      echo ""
      echo -e "  Press Enter to skip (you can authenticate via browser later)."
      echo ""
      _KIRO_API_KEY=""
      prompt_secret "Kiro API key" _KIRO_API_KEY ""
      if [[ -n "$_KIRO_API_KEY" ]]; then
        # Validate format: ksk_<alphanumeric>, ~35 chars
        if [[ ! "$_KIRO_API_KEY" =~ ^ksk_[A-Za-z0-9]{26,96}$ ]]; then
          warn "API key doesn't match expected format (ksk_...). Skipping — authenticate manually after install."
          _KIRO_API_KEY=""
        else
          # Secret name determined now; actual write deferred until after user confirms
          _KIRO_SECRET_NAME="/lowkey/${ENV_NAME}/kiro-api-key"
          KIRO_FROM_SECRET="${_KIRO_SECRET_NAME}"
          # Update PARAM_VALUES at the KiroFromSecret index (looked up by name to
          # survive future reordering; hardcoded index bit us when ExistingSubnetId2
          # was inserted and shifted RepoBranch/KiroFromSecret by one).
          _kiro_idx=-1
          for _i in "${!PARAM_CFN_NAMES[@]}"; do
            [[ "${PARAM_CFN_NAMES[$_i]}" == "KiroFromSecret" ]] && { _kiro_idx=$_i; break; }
          done
          if [[ "$_kiro_idx" -ge 0 ]]; then
            PARAM_VALUES[$_kiro_idx]="$KIRO_FROM_SECRET"
          else
            fail "BUG: KiroFromSecret not found in PARAM_CFN_NAMES"
          fi
          ok "API key will be stored in Secrets Manager: ${_KIRO_SECRET_NAME}"
        fi
      else
        info "Skipping API key — authenticate after install with: kiro-cli login --use-device-flow"
      fi
    fi
  fi

  # Pack-specific: Troika primary + daily-driver selection
  if [[ "${PACK_NAME:-}" == "troika" ]]; then
    # ── Primary (first horse) ────────────────────────────────────────────────
    if [[ -z "${TROIKA_PRIMARY:-}" ]]; then
      if [[ "$AUTO_YES" == true ]]; then
        TROIKA_PRIMARY="openclaw"
        ok "Primary (troika): ${TROIKA_PRIMARY} (default)"
      else
        local _tri_primary_choice
        _gum_or_die _tri_primary_choice $GUM choose \
          --header "Which OpenClaw-family agent is your first horse?" \
          --selected "openclaw" \
          "openclaw" \
          "hermes" || _tri_primary_choice="openclaw"
        TROIKA_PRIMARY="${_tri_primary_choice:-openclaw}"
        ok "Primary: ${TROIKA_PRIMARY}"
      fi
    else
      ok "Primary (troika): ${TROIKA_PRIMARY} (pre-selected)"
    fi

    # ── Daily driver ─────────────────────────────────────────────────────────
    if [[ -z "${TROIKA_DAILY_DRIVER:-}" ]]; then
      if [[ "$AUTO_YES" == true ]]; then
        TROIKA_DAILY_DRIVER="${TROIKA_PRIMARY}"
        ok "Daily driver (troika): ${TROIKA_DAILY_DRIVER} (default = primary)"
      else
        local _tri_dd_choice
        _gum_or_die _tri_dd_choice $GUM choose \
          --header "Which agent auto-launches when you SSM in?" \
          --selected "${TROIKA_PRIMARY}" \
          "${TROIKA_PRIMARY}" \
          "claude-code" \
          "codex-cli" \
          "none" || _tri_dd_choice="${TROIKA_PRIMARY}"
        TROIKA_DAILY_DRIVER="${_tri_dd_choice:-${TROIKA_PRIMARY}}"
        ok "Daily driver: ${TROIKA_DAILY_DRIVER}"
      fi
    else
      ok "Daily driver (troika): ${TROIKA_DAILY_DRIVER} (pre-selected)"
    fi

    # Cross-validate daily-driver vs primary (catches --daily-driver openclaw --primary hermes)
    case "${TROIKA_DAILY_DRIVER}" in
      "${TROIKA_PRIMARY}"|claude-code|codex-cli|none) : ;;
      *)
        fail "--daily-driver '${TROIKA_DAILY_DRIVER}' is not valid when --primary='${TROIKA_PRIMARY}'. Valid: ${TROIKA_PRIMARY} | claude-code | codex-cli | none"
        ;;
    esac

    # Codex model: default if not pre-set
    TROIKA_CODEX_MODEL="${TROIKA_CODEX_MODEL:-openai.gpt-5.5}"

    # Rebuild params with troika values now set
    build_deploy_params
  fi
  show_summary || {
    # User chose "Change settings" → re-run in advanced mode with current values as preselects
    PRESELECT_PACK="$PACK_NAME"
    PRESELECT_PROFILE="$PROFILE_NAME"
    PRESELECT_METHOD=""
    EXISTING_VPC_ID=""
    EXISTING_SUBNET_ID=""
    EXISTING_SUBNET_ID2=""
    STEP_NUM=1
    run_config_and_review
    return
  }

  # Cognito is provisioned by CloudFormation — no SSM writes needed here.
  # Stack outputs (pool ID, client ID, domain, admin credentials) are
  # displayed to the user after deploy completes.
}

main() {
  install_gum            # must run before anything that uses $GUM
  show_banner
  _telem_install_started 2>/dev/null || true
  if [[ "$TEST_MODE" == "true" ]]; then
    echo ""
    $GUM style --foreground 220 --bold --border rounded --border-foreground 220 \
      --padding "0 2" --margin "0 2" "🧪 TEST MODE — no AWS resources will be created"
    echo ""
    info "This invocation is tagged is_test and excluded from install stats."
    info "Pass --help to see all flags."
    echo ""
    ok "Installer downloaded and parsed successfully."
    ok "Exit code 0."
    exit 0
  fi
  show_welcome
  choose_install_mode    # simple (default) or advanced — needed before preflight
  _TELEM_CURRENT_STEP="preflight"
  preflight_checks       # step 1
  maybe_rename_account || true  # account-level, before config wizard
  _TELEM_CURRENT_STEP="config"
  run_config_and_review  # steps 2-4 (config → review)
  _telem_pack_selected 2>/dev/null || true
  _telem_method_selected 2>/dev/null || true

  # Roundhouse: save bot token to Secrets Manager (deferred until after user confirmation)
  if [[ -n "${_RH_BOT_TOKEN:-}" && -n "${_RH_SECRET_NAME:-}" ]]; then
    info "Storing bot token in Secrets Manager: ${_RH_SECRET_NAME}"
    local token_file
    token_file=$(mktemp /tmp/lowkey-rh-token.XXXXXX)
    chmod 600 "$token_file"
    printf '%s' "$_RH_BOT_TOKEN" > "$token_file"
    # Restore if in pending-deletion state
    aws secretsmanager restore-secret --secret-id "$_RH_SECRET_NAME" --region "$DEPLOY_REGION" >/dev/null 2>&1 || true
    local sm_err=""
    if sm_err=$(aws secretsmanager create-secret \
      --name "$_RH_SECRET_NAME" \
      --secret-string "file://${token_file}" \
      --description "Telegram bot token for roundhouse pack (${ENV_NAME})" \
      --region "$DEPLOY_REGION" 2>&1); then
      ok "Token saved to Secrets Manager"
    elif sm_err=$(aws secretsmanager put-secret-value \
      --secret-id "$_RH_SECRET_NAME" \
      --secret-string "file://${token_file}" \
      --region "$DEPLOY_REGION" 2>&1); then
      ok "Token updated in Secrets Manager"
    else
      rm -f "$token_file"
      fail "Failed to save bot token to Secrets Manager: ${sm_err}"
    fi
    rm -f "$token_file"
    unset _RH_BOT_TOKEN
  fi

  # Kiro CLI: save API key to Secrets Manager (deferred until after user confirmation)
  if [[ -n "${_KIRO_API_KEY:-}" && -n "${_KIRO_SECRET_NAME:-}" ]]; then
    info "Storing Kiro API key in Secrets Manager: ${_KIRO_SECRET_NAME}"
    local kiro_key_file
    kiro_key_file=$(mktemp /tmp/lowkey-kiro-key.XXXXXX)
    chmod 600 "$kiro_key_file"
    printf '%s' "$_KIRO_API_KEY" > "$kiro_key_file"
    # Restore if in pending-deletion state
    aws secretsmanager restore-secret --secret-id "$_KIRO_SECRET_NAME" --region "$DEPLOY_REGION" >/dev/null 2>&1 || true
    local kiro_sm_err=""
    if kiro_sm_err=$(aws secretsmanager create-secret \
      --name "$_KIRO_SECRET_NAME" \
      --secret-string "file://${kiro_key_file}" \
      --description "Kiro CLI API key for headless mode (${ENV_NAME})" \
      --tags Key=loki:managed,Value=true Key=loki:pack,Value=kiro-cli Key=loki:env,Value="${ENV_NAME}" \
      --region "$DEPLOY_REGION" 2>&1); then
      ok "Kiro API key saved to Secrets Manager"
    elif kiro_sm_err=$(aws secretsmanager put-secret-value \
      --secret-id "$_KIRO_SECRET_NAME" \
      --secret-string "file://${kiro_key_file}" \
      --region "$DEPLOY_REGION" 2>&1); then
      ok "Kiro API key updated in Secrets Manager"
    else
      rm -f "$kiro_key_file"
      fail "Failed to save Kiro API key to Secrets Manager: ${kiro_sm_err}"
    fi
    rm -f "$kiro_key_file"
    unset _KIRO_API_KEY
  fi

  # Console deploy exits early (no clone, no bootstrap wait)
  if [[ "$DEPLOY_METHOD" == "$DEPLOY_CFN_CONSOLE" ]]; then
    # P1 #5: Console mode can't build+upload the edge Lambda zip (no local
    # clone, no shell access post-flow). WebUI auth requires CLI deploy.
    if [[ "${WEBUI_AUTH_ENABLED:-false}" == "true" ]]; then
      fail "WebUI authentication is not supported with the CloudFormation Console deploy method. Re-run and choose 'CloudFormation CLI' when prompted, or disable WebUI auth."
    fi
    TOTAL_STEPS=5
    _TELEM_CURRENT_STEP="deploy_console"
    _telem_deploy_started 2>/dev/null || true
    step "Deploy (Console)"
    deploy_console
    _telem_install_completed 2>/dev/null || true
    exit 0
  fi

  # CLI deploys need the repo
  _TELEM_CURRENT_STEP="deploy"
  _telem_deploy_started 2>/dev/null || true
  step "Deploy"
  prepare_repo
  echo ""

  if [[ "${WEBUI_AUTH_ENABLED:-false}" == "true" && "$PACK_NAME" == "kirocrew" ]]; then
    build_and_upload_edge_lambda
    deploy_edge_stack
    # Edge outputs are required by the main stack parameters; refresh the
    # parallel parameter values after the companion stack completes.
    build_deploy_params
  fi

  case "$DEPLOY_METHOD" in
    "$DEPLOY_CFN_CLI") info "Deploying with CloudFormation..."
       deploy_cfn_stack "deploy/cloudformation/template.yaml" "CAPABILITY_NAMED_IAM" ;;
    *) fail "Invalid choice: $DEPLOY_METHOD" ;;
  esac
  _telem_deploy_completed 2>/dev/null || true

  # Post-deploy: read Cognito outputs from the stack and display admin credentials
  # Wrapped in `|| true` and explicit guards so a transient AWS/jq failure here
  # doesn't abort the installer between stack success and show_complete.
  if [[ "${WEBUI_AUTH_ENABLED:-false}" == "true" ]]; then
    local stack_outputs="" pool_id="" client_id="" domain="" admin_email="" admin_password="" secret_arn="" dashboard_url=""
    stack_outputs=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME}" \
      --region "$DEPLOY_REGION" --output json 2>/dev/null || echo '{}')
    stack_outputs=$(printf '%s' "$stack_outputs" | jq -r '.Stacks[0].Outputs // []' 2>/dev/null || echo '[]')
    if [[ -n "$stack_outputs" && "$stack_outputs" != "null" && "$stack_outputs" != "[]" ]]; then
      pool_id=$(printf '%s' "$stack_outputs" | jq -r '.[] | select(.OutputKey=="WebUICognitoPoolId") | .OutputValue' 2>/dev/null || true)
      client_id=$(printf '%s' "$stack_outputs" | jq -r '.[] | select(.OutputKey=="WebUICognitoClientId") | .OutputValue' 2>/dev/null || true)
      domain=$(printf '%s' "$stack_outputs" | jq -r '.[] | select(.OutputKey=="WebUICognitoDomain") | .OutputValue' 2>/dev/null || true)
      admin_email=$(printf '%s' "$stack_outputs" | jq -r '.[] | select(.OutputKey=="WebUIAdminEmailOutput") | .OutputValue' 2>/dev/null || true)
      secret_arn=$(printf '%s' "$stack_outputs" | jq -r '.[] | select(.OutputKey=="WebUIAdminSecretArn") | .OutputValue' 2>/dev/null || true)
      dashboard_url=$(printf '%s' "$stack_outputs" | jq -r '.[] | select(.OutputKey=="KiroCrewDashboardUrl") | .OutputValue' 2>/dev/null || true)
      if [[ -n "$secret_arn" && "$secret_arn" != "null" ]]; then
        admin_password=$(aws secretsmanager get-secret-value --secret-id "$secret_arn" \
          --region "$DEPLOY_REGION" --query SecretString --output text 2>/dev/null \
          | jq -r '.password // empty' 2>/dev/null || true)
      fi
      if [[ -n "$admin_email" && "$admin_email" != "null" ]]; then
        echo ""
        $GUM style --border rounded --border-foreground 220 --padding "1 2" --margin "0 2" \
          "⚠  WEBUI ADMIN CREDENTIALS — stored in Secrets Manager" \
          "" \
          "  Dashboard: ${dashboard_url}" \
          "  Login:     ${admin_email}" \
          "  Password:  ${admin_password}" \
          "" \
          "  Pool:      ${pool_id}" \
          "  Client:    ${client_id}" \
          "  Domain:    ${domain}" \
          "" \
          "  Edge Lambda: ${EDGE_LAMBDA_VERSION_ARN}" \
          "  Edge Region: us-east-1" \
          "  Edge Stack:  ${ENV_NAME}-edge-stack" \
          "" \
          "  Secret:    ${secret_arn}" || true
        echo ""
      fi
    fi
  fi

  wait_for_bootstrap   # step 6
  _telem_bootstrap_completed 2>/dev/null || true
  ensure_ssm_session_document
  _TELEM_CURRENT_STEP="complete"
  _telem_install_completed 2>/dev/null || true
  show_complete        # step 7
}

main "$@"
