#!/usr/bin/env bash
# tests/test-setup-hooks.sh — Test for scripts/setup-hooks.sh.
#
# In a linked worktree (git worktree add), .git is a file, not a directory,
# and git reads hooks from the common git directory. This test makes a
# temporary repository with a linked worktree and makes sure that:
#   - setup-hooks.sh exits 0 in the main checkout and in the linked worktree
#   - the pre-commit hook is in the hooks directory that git uses
#   - setup-hooks.sh exits 1 outside a git repository
#   - setup-hooks.sh exits 1 when git finds only an ancestor repository, and
#     installs no hook into that repository
#   - setup-hooks.sh exits 0 when core.hooksPath points to scripts/
#
# No AWS required. Run standalone or via CI (discovered by pack-tests.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

printf "${BOLD}scripts/setup-hooks.sh${NC}\n"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Isolate from the user's git configuration.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G=(git -c user.name=test -c user.email=test@example.invalid -c init.defaultBranch=main)

MAIN="$WORK/main"
mkdir -p "$MAIN/scripts"
cp "$REPO_ROOT/scripts/setup-hooks.sh" "$REPO_ROOT/scripts/pre-commit" "$MAIN/scripts/"
"${G[@]}" -C "$MAIN" init -q
"${G[@]}" -C "$MAIN" add scripts
"${G[@]}" -C "$MAIN" commit -q -m init
"${G[@]}" -C "$MAIN" worktree add -q "$WORK/linked" -b linked

# Main checkout.
if bash "$MAIN/scripts/setup-hooks.sh" >/dev/null 2>&1; then
  pass "exits 0 in the main checkout"
else
  fail "exits non-zero in the main checkout"
fi
if [[ -x "$MAIN/.git/hooks/pre-commit" ]]; then
  pass "pre-commit hook installed in .git/hooks"
else
  fail "pre-commit hook missing from .git/hooks"
fi

# Linked worktree: remove the hook first, so the check below proves this run.
rm -f "$MAIN/.git/hooks/pre-commit"
if bash "$WORK/linked/scripts/setup-hooks.sh" >/dev/null 2>&1; then
  pass "exits 0 in a linked worktree"
else
  fail "exits non-zero in a linked worktree"
fi
hooks_dir="$(git -C "$WORK/linked" rev-parse --git-path hooks)"
[[ "$hooks_dir" = /* ]] || hooks_dir="$WORK/linked/$hooks_dir"
if [[ -x "$hooks_dir/pre-commit" ]]; then
  pass "pre-commit hook installed in the hooks directory git uses"
else
  fail "pre-commit hook missing from $hooks_dir"
fi
if [[ ! -e "$WORK/linked/.git/hooks" ]]; then
  pass "no hooks directory created under the worktree .git file"
else
  fail "hooks directory created under the worktree .git file"
fi

# Not a git repository.
NOREPO="$WORK/norepo"
mkdir -p "$NOREPO/scripts"
cp "$REPO_ROOT/scripts/setup-hooks.sh" "$NOREPO/scripts/"
rc=0
GIT_CEILING_DIRECTORIES="$WORK" bash "$NOREPO/scripts/setup-hooks.sh" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
  pass "exits 1 outside a git repository"
else
  fail "exits $rc outside a git repository (expected 1)"
fi

# Copy inside an unrelated repository: git finds only the ancestor.
OUTER="$WORK/outer"
"${G[@]}" init -q "$OUTER"
mkdir -p "$OUTER/vendor/lowkey/scripts"
cp "$REPO_ROOT/scripts/setup-hooks.sh" "$REPO_ROOT/scripts/pre-commit" "$OUTER/vendor/lowkey/scripts/"
rc=0
bash "$OUTER/vendor/lowkey/scripts/setup-hooks.sh" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
  pass "exits 1 when git finds only an ancestor repository"
else
  fail "exits $rc when git finds only an ancestor repository (expected 1)"
fi
if [[ ! -e "$OUTER/.git/hooks/pre-commit" ]]; then
  pass "no hook installed into the ancestor repository"
else
  fail "hook installed into the ancestor repository"
fi

# core.hooksPath points to the directory that holds the source hook.
"${G[@]}" -C "$MAIN" config core.hooksPath scripts
if bash "$MAIN/scripts/setup-hooks.sh" >/dev/null 2>&1; then
  pass "exits 0 when core.hooksPath is scripts"
else
  fail "exits non-zero when core.hooksPath is scripts"
fi
if [[ -x "$MAIN/scripts/pre-commit" ]]; then
  pass "pre-commit hook in scripts/ is executable"
else
  fail "pre-commit hook in scripts/ is not executable"
fi
"${G[@]}" -C "$MAIN" config --unset core.hooksPath

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
