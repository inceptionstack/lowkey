#!/usr/bin/env bash
# Install git hooks for local development.
# Usage: bash scripts/setup-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# In a linked worktree, .git is a file, so ask git for the worktree root.
# The root must be REPO_ROOT. If git finds only an ancestor repository (for
# example, a copy of this repo inside an unrelated checkout), do not install
# the hook into that repository.
TOPLEVEL="$(git -C "${REPO_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${TOPLEVEL}" ]] || [[ "$(cd "${TOPLEVEL}" && pwd -P)" != "${REPO_ROOT}" ]]; then
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

# Install pre-commit hook. If core.hooksPath points to scripts/, the hook is
# already in place, and cp would fail because the files are the same.
if [[ ! "${REPO_ROOT}/scripts/pre-commit" -ef "${HOOKS_DIR}/pre-commit" ]]; then
  cp "${REPO_ROOT}/scripts/pre-commit" "${HOOKS_DIR}/pre-commit"
fi
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
