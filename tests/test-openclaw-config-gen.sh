#!/usr/bin/env bash
# tests/test-openclaw-config-gen.sh — Contract tests for the file that
# packs/openclaw/resources/config-gen.py writes.
#
# openclaw.json holds the gateway token and can hold API keys. These tests
# make sure that:
#   - the script creates ~/.openclaw/ when it does not exist
#   - the new file has mode 600, also when the umask is 022
#   - an existing file that has mode 644 is changed to mode 600
#   - the file is valid JSON and holds the gateway token
#
# HOME is set to a temporary directory. No AWS required.
# Run standalone or via CI (discovered by pack-tests.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PY="$REPO_ROOT/packs/openclaw/resources/config-gen.py"

if [[ ! -f "$PY" ]]; then
  echo "FAIL: config-gen.py not found at $PY" >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# file_mode <path>  -> echoes the octal permission bits (for example 600)
file_mode() {
  python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$1"
}

# run_gen <home>  -> runs config-gen.py with umask 022 and HOME=<home>
run_gen() {
  ( umask 022; HOME="$1" GW_TOKEN_ENV="test-gw-token" \
      python3 "$PY" us-east-1 test-model 18789 "" bedrock ) >"$TMP/out.log" 2>&1
}

# --- 1. Missing ~/.openclaw/ is created ---
H1="$TMP/h1"; mkdir -p "$H1"
if run_gen "$H1"; then
  pass "Script runs when ~/.openclaw/ does not exist"
else
  fail "Script fails when ~/.openclaw/ does not exist: $(tail -1 "$TMP/out.log")"
fi
CFG1="$H1/.openclaw/openclaw.json"

# --- 2. New file has mode 600 with umask 022 ---
if [[ -f "$CFG1" ]]; then
  m="$(file_mode "$CFG1")"
  if [[ "$m" == "600" ]]; then
    pass "New openclaw.json has mode 600 (umask 022)"
  else
    fail "New openclaw.json has mode $m, expected 600"
  fi
else
  fail "New openclaw.json was not written"
fi

# --- 3. File is valid JSON and holds the gateway token ---
if [[ -f "$CFG1" ]] && python3 - "$CFG1" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
sys.exit(0 if cfg["gateway"]["auth"]["token"] == "test-gw-token" else 1)
PY
then
  pass "openclaw.json is valid JSON with the gateway token"
else
  fail "openclaw.json is not valid JSON or has no gateway token"
fi

# --- 4. Existing file with mode 644 is changed to mode 600 ---
H4="$TMP/h4"; mkdir -p "$H4/.openclaw"
echo '{}' > "$H4/.openclaw/openclaw.json"
chmod 644 "$H4/.openclaw/openclaw.json"
if run_gen "$H4"; then
  m="$(file_mode "$H4/.openclaw/openclaw.json")"
  if [[ "$m" == "600" ]]; then
    pass "Existing mode-644 openclaw.json is changed to mode 600"
  else
    fail "Existing openclaw.json keeps mode $m, expected 600"
  fi
else
  fail "Script fails on an existing openclaw.json: $(tail -1 "$TMP/out.log")"
fi

echo
printf "${BOLD}Results:${NC} ${GREEN}${PASS} pass${NC} / ${RED}${FAIL} fail${NC}\n"
[[ $FAIL -eq 0 ]] || exit 1
