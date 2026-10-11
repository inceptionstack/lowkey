#!/usr/bin/env bash
# Install git hooks for local development.
# Usage: bash scripts/setup-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# In a linked worktree, .git is a file, so ask git for the git directory.
if ! git -C "${REPO_ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "Error: not a git repository. Run from the repo root." >&2
  exit 1
fi

# Use the hooks directory that git reads. In a linked worktree this is in the
# common git directory. It also obeys core.hooksPath.
HOOKS_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-path hooks)"
if [[ "${HOOKS_DIR}" != /* ]]; then
  HOOKS_DIR="${REPO_ROOT}/${HOOKS_DIR}"
fi

mkdir -p "${HOOKS_DIR}"

# Install pre-commit hook
cp "${REPO_ROOT}/scripts/pre-commit" "${HOOKS_DIR}/pre-commit"
chmod +x "${HOOKS_DIR}/pre-commit"

# Install git-secrets hooks (if git-secrets is available)
if command -v git-secrets &>/dev/null; then
  ( cd "${REPO_ROOT}" && git secrets --register-aws 2>/dev/null || true )
  echo "✓ git-secrets AWS patterns registered"
else
  echo "⚠ git-secrets not found — install for local secret scanning:"
  echo "  brew install git-secrets  OR  https://github.com/awslabs/git-secrets#installing-git-secrets"
fi

echo "✓ Git hooks installed:"
echo "  pre-commit → runs all unit tests before commit"
echo ""
echo "  Skip with: git commit --no-verify"
