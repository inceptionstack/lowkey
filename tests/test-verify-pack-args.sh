#!/usr/bin/env bash
# tests/test-verify-pack-args.sh — Exit-code test for scripts/verify-pack
# argument handling.
#
# A caller that runs 'verify-pack "$PACK"' with an empty $PACK must not see
# a pass. This test makes sure that:
#   - no pack argument gives a non-zero exit code and the error on stderr,
#   - --help still gives exit code 0 and the usage text on stdout.
#
# No AWS required. Run standalone or via CI (discovered by pack-tests.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY="$REPO_ROOT/scripts/verify-pack"

if [[ ! -f "$VERIFY" ]]; then
  echo "FAIL: verify-pack not found at $VERIFY" >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

printf "${BOLD}scripts/verify-pack argument handling${NC}\n"

OUT="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$OUT" "$ERR"' EXIT

# No pack argument: must fail, and the error must go to stderr.
rc=0
bash "$VERIFY" >"$OUT" 2>"$ERR" || rc=$?
if [[ $rc -ne 0 ]]; then
  pass "no pack argument gives a non-zero exit code ($rc)"
else
  fail "no pack argument gives exit code 0"
fi
if grep -q "No pack directory specified" "$ERR"; then
  pass "no pack argument writes the error to stderr"
else
  fail "no pack argument does not write the error to stderr"
fi

# --help: must pass, and the usage text must go to stdout.
rc=0
bash "$VERIFY" --help >"$OUT" 2>"$ERR" || rc=$?
if [[ $rc -eq 0 ]]; then
  pass "--help gives exit code 0"
else
  fail "--help gives exit code $rc"
fi
if grep -q "^Usage: verify-pack" "$OUT"; then
  pass "--help writes the usage text to stdout"
else
  fail "--help does not write the usage text to stdout"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
