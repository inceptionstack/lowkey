#!/usr/bin/env bash
# Build the KiroCrew WebUI Cognito Lambda@Edge zip.
#
# Substitutes SECRET_ARN placeholder in index.js, runs npm install --production,
# and produces edge-lambda-<sha>.zip in $OUT_DIR (default: script dir).
#
# The Lambda code fetches all other config (pool ID, client ID, domain,
# signing key) from Secrets Manager at cold start, using the ARN baked in
# here. This means we can build the zip BEFORE CFN creates the Cognito pool.
#
# Required env vars:
#   SECRET_ARN   — Secrets Manager ARN for the edge auth config secret
#
# Optional:
#   OUT_DIR      — Where to place the zip (default: script dir)
#   NODE_BIN     — Node binary path (default: node from PATH)
#
# Exit codes: 0 success, non-zero failure with message on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR}"
NODE_BIN="${NODE_BIN:-node}"

if [[ -z "${SECRET_ARN:-}" ]]; then
  echo "build.sh: missing required env var: SECRET_ARN" >&2
  exit 2
fi

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "build.sh: node binary not found ($NODE_BIN)" >&2
  exit 4
fi

NODE_MAJOR=$("$NODE_BIN" -e 'console.log(process.versions.node.split(".")[0])')
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  echo "build.sh: node 18+ required, got $NODE_MAJOR" >&2
  exit 5
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

cp "$SCRIPT_DIR/index.js" "$BUILD_DIR/index.js"
cp "$SCRIPT_DIR/package.json" "$BUILD_DIR/package.json"

# Substitute only SECRET_ARN placeholder
sed -i -e "s|__SECRET_NAME__|${SECRET_ARN}|g" "$BUILD_DIR/index.js"

if grep -q '__[A-Z_]*__' "$BUILD_DIR/index.js"; then
  echo "build.sh: unresolved placeholders in index.js:" >&2
  grep '__[A-Z_]*__' "$BUILD_DIR/index.js" >&2
  exit 6
fi

cd "$BUILD_DIR"
npm install --production --no-audit --no-fund --loglevel=error >&2

# Hash based on the secret ARN so the zip name is deterministic per stack
SHA=$(printf '%s' "$SECRET_ARN" | sha256sum | cut -c1-12)
ZIP_NAME="edge-lambda-${SHA}.zip"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"

rm -f "$ZIP_PATH"
zip -r -q "$ZIP_PATH" index.js package.json node_modules >&2

echo "$ZIP_PATH"
