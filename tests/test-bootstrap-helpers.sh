#!/usr/bin/env bash
# tests/test-bootstrap-helpers.sh — Contract test for the log helpers in
# deploy/bootstrap.sh.
#
# bootstrap.sh runs with "set -euo pipefail". If the script calls a log helper
# (step, ok, fail, info, warn) that it does not define, bash exits with
# "command not found" and the bootstrap stops. This test reads the top-level
# script (it skips heredoc bodies, because they run in a different shell) and
# makes sure that each helper the script calls is also defined.
#
# No AWS required. Run standalone or via CI (discovered by pack-tests.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP="$REPO_ROOT/deploy/bootstrap.sh"

if [[ ! -f "$BOOTSTRAP" ]]; then
  echo "FAIL: bootstrap.sh not found at $BOOTSTRAP" >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

printf "${BOLD}deploy/bootstrap.sh log helpers${NC}\n"

# Print the top-level lines of the script. Lines inside a heredoc body are
# removed, because a heredoc body is data or a script for a different shell.
top_level() {
  awk '
    delim != "" { if ($0 == delim) delim = ""; next }
    {
      print
      if (match($0, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
        d = substr($0, RSTART, RLENGTH)
        sub(/^<<-?[ \t]*/, "", d)
        gsub(/["\047]/, "", d)
        delim = d
      }
    }
  ' "$BOOTSTRAP"
}

TOP="$(top_level)"

for helper in step ok fail info warn; do
  defined=0
  called=0
  if grep -Eq "^${helper}\(\)" <<<"$TOP"; then defined=1; fi
  # A call is the helper name at the start of a command: line start, or
  # after "&&", "||", ";" or "then"/"else"/"do".
  if grep -Eq "(^|&&|\|\||;|then|else|do)[[:space:]]*${helper}[[:space:]]+[\"\$]" <<<"$TOP"; then
    called=1
  fi
  if [[ $called -eq 0 ]]; then
    pass "$helper is not called at top level"
  elif [[ $defined -eq 1 ]]; then
    pass "$helper is called and defined at top level"
  else
    fail "$helper is called at top level but not defined"
  fi
done

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
