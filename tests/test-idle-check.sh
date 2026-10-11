#!/usr/bin/env bash
# tests/test-idle-check.sh — Contract tests for idle-check.py activity detection.
#
# Synthetic JSONL fixtures assert that:
#   - Telegram messages (numeric sender_id)          → count as activity
#   - TUI surface messages (no metadata)             → count as activity (blocklist)
#   - Messages prefixed "Read HEARTBEAT.md"          → ignored
#   - Messages prefixed "System:"                    → ignored
#   - Messages prefixed "Pre-compaction memory flush"→ ignored
#   - Mixed: newest real message wins                → correct latest_ts
#
# No AWS required. Run standalone or via CI (discovered by pack-tests.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$REPO_ROOT/bootstraps/optional/idle-shutdown/idle-check.py"

if [[ ! -f "$PY" ]]; then
  echo "FAIL: idle-check.py not found at $PY" >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- helpers ---

# mk_msg <timestamp> <text>  -> echoes one JSONL line
mk_msg() {
  local ts="$1"; shift
  local text="$*"
  python3 - "$ts" "$text" <<'PY'
import json, sys
ts, text = sys.argv[1], sys.argv[2]
print(json.dumps({
    "createdAt": ts,
    "message": {"role": "user", "content": [{"type": "text", "text": text}]}
}))
PY
}

# assert_activity <dir> <expected_ts|NO_MESSAGES>
assert_activity() {
  local dir="$1" want="$2" label="$3"
  local out
  out="$(python3 "$PY" --idle-hours "$dir")"
  if [[ "$want" == "NO_MESSAGES" ]]; then
    if [[ "$out" == "NO_MESSAGES" ]]; then pass "$label"; else fail "$label — expected NO_MESSAGES, got: $out"; fi
  else
    # out is: HOURS TIMESTAMP FILE_FAIL PARSE_FAIL
    local got_ts
    got_ts="$(awk '{print $2}' <<<"$out")"
    if [[ "$got_ts" == "$want" ]]; then pass "$label"; else fail "$label — expected $want, got: $got_ts (full: $out)"; fi
  fi
}

printf "${BOLD}${CYAN}idle-check activity detection tests${NC}\n"

# --- 1. Telegram message (numeric sender_id) counts ---
D1="$TMP/t1"; mkdir -p "$D1"
cat > "$D1/sess.jsonl" <<'EOF'
EOF
mk_msg "2026-04-22T10:00:00Z" '{"sender_id":"1775159795"} hey loki' >> "$D1/sess.jsonl"
assert_activity "$D1" "2026-04-22T10:00:00Z" "Telegram message with numeric sender_id counts"

# --- 2. TUI surface (openclaw-tui) with no sender_id counts ---
D2="$TMP/t2"; mkdir -p "$D2"
mk_msg "2026-04-22T11:00:00Z" 'deploy the slats guardian please' > "$D2/sess.jsonl"
assert_activity "$D2" "2026-04-22T11:00:00Z" "TUI / bare-text message counts as real activity"

# --- 3. HEARTBEAT poll does NOT count ---
D3="$TMP/t3"; mkdir -p "$D3"
mk_msg "2026-04-22T12:00:00Z" 'Read HEARTBEAT.md if it exists. Reply HEARTBEAT_OK if idle.' > "$D3/sess.jsonl"
assert_activity "$D3" "NO_MESSAGES" "Heartbeat poll prefix does not count"

# --- 4. System: prefix does NOT count ---
D4="$TMP/t4"; mkdir -p "$D4"
mk_msg "2026-04-22T13:00:00Z" 'System: [2026-04-22] Exec completed (nice-cliff, code 0)' > "$D4/sess.jsonl"
assert_activity "$D4" "NO_MESSAGES" "System: prefix does not count"

# --- 5. Pre-compaction memory flush does NOT count ---
D5="$TMP/t5"; mkdir -p "$D5"
mk_msg "2026-04-22T14:00:00Z" 'Pre-compaction memory flush: save any pending state.' > "$D5/sess.jsonl"
assert_activity "$D5" "NO_MESSAGES" "Pre-compaction memory flush prefix does not count"

# --- 6. Mixed: automated + real, real wins with correct timestamp ---
D6="$TMP/t6"; mkdir -p "$D6"
{
  mk_msg "2026-04-22T09:00:00Z" 'Read HEARTBEAT.md noise'
  mk_msg "2026-04-22T10:00:00Z" 'real user message here'
  mk_msg "2026-04-22T11:00:00Z" 'System: more noise'
} > "$D6/sess.jsonl"
assert_activity "$D6" "2026-04-22T10:00:00Z" "Mixed: real message wins, noise ignored"

# --- 7. IDLE_EXTRA_AUTOMATED_PREFIXES env works ---
D7="$TMP/t7"; mkdir -p "$D7"
mk_msg "2026-04-22T15:00:00Z" '[CustomBotPing] scheduled wake' > "$D7/sess.jsonl"
out="$(IDLE_EXTRA_AUTOMATED_PREFIXES='[CustomBotPing]' python3 "$PY" --idle-hours "$D7")"
if [[ "$out" == "NO_MESSAGES" ]]; then
  pass "Custom prefix via IDLE_EXTRA_AUTOMATED_PREFIXES respected"
else
  fail "Custom prefix via IDLE_EXTRA_AUTOMATED_PREFIXES — got: $out"
fi

# --- 8. Leading 'Conversation info' metadata block does not mask real text ---
D8="$TMP/t8"; mkdir -p "$D8"
TEXT=$'Conversation info (untrusted metadata):\n```json\n{"sender":"Roy"}\n```\n\nbuild me the thing'
mk_msg "2026-04-22T16:00:00Z" "$TEXT" > "$D8/sess.jsonl"
assert_activity "$D8" "2026-04-22T16:00:00Z" "Message wrapped with Conversation info metadata still counts"

# --- 9. Valid JSON lines that are not objects are skipped, not a SCAN_ERROR ---
D9="$TMP/t9"; mkdir -p "$D9"
{
  echo '[]'
  echo '"x"'
  echo '1'
  echo 'null'
  mk_msg "2026-04-22T17:00:00Z" 'real message after non-object lines'
} > "$D9/sess.jsonl"
assert_activity "$D9" "2026-04-22T17:00:00Z" "Non-object JSON lines are skipped and do not stop the scan"

echo
printf "${BOLD}Results:${NC} ${GREEN}${PASS} pass${NC} / ${RED}${FAIL} fail${NC}\n"
[[ $FAIL -eq 0 ]] || exit 1
