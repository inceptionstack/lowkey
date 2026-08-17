#!/usr/bin/env bash
# Build the KiroCrew WebUI Cognito Lambda@Edge zip.
#
# Substitutes CONFIG_SECRET_NAME placeholder in index.js, runs npm install
# --production, and produces edge-lambda-<sha>.zip in $OUT_DIR (default: script dir).
#
# The Lambda code fetches all config (pool ID, client ID, domain, signing key)
# from Secrets Manager at cold start using the config secret name baked in
# here. This lets us build the zip BEFORE CFN creates the Cognito pool.
#
# Required env vars:
#   CONFIG_SECRET_NAME   — Secrets Manager name (not ARN) for the edge config secret
#                          e.g. /lowkey/<env>/webui-edge-config
#
# Optional:
#   OUT_DIR              — Where to place the zip (default: script dir)
#   NODE_BIN             — Node binary path (default: node from PATH)
#
# Exit codes: 0 success, non-zero failure with message on stderr.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR}"
NODE_BIN="${NODE_BIN:-node}"

if [[ -z "${CONFIG_SECRET_NAME:-}" ]]; then
  echo "build.sh: missing required env var: CONFIG_SECRET_NAME" >&2
  exit 2
fi

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  echo "build.sh: node binary not found ($NODE_BIN)" >&2
  exit 4
fi

NODE_MAJOR=$("$NODE_BIN" -e 'console.log(process.versions.node.split(".")[0])')
# Build-time Node just needs to run npm install and zip. The Lambda@Edge
# RUNTIME is nodejs22.x, but that's about what Lambda executes — not about
# what compiles the zip. Any Node >= 18 (LTS) is fine at build time.
# CloudShell currently ships Node 20; requiring 22+ here breaks it.
if [[ "$NODE_MAJOR" -lt 18 ]]; then
  echo "build.sh: node 18+ required at build time (target runtime is nodejs22.x, but the zip only needs npm install), got $NODE_MAJOR" >&2
  exit 5
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

cp "$SCRIPT_DIR/index.js" "$BUILD_DIR/index.js"
cp "$SCRIPT_DIR/package.json" "$BUILD_DIR/package.json"
cp "$SCRIPT_DIR/package-lock.json" "$BUILD_DIR/package-lock.json"
cp "$SCRIPT_DIR/.npmrc" "$BUILD_DIR/.npmrc"

# Substitute only CONFIG_SECRET_NAME placeholder
sed -i -e "s|__CONFIG_SECRET_NAME__|${CONFIG_SECRET_NAME}|g" "$BUILD_DIR/index.js"

if grep -q '__[A-Z_]*__' "$BUILD_DIR/index.js"; then
  echo "build.sh: unresolved placeholders in index.js:" >&2
  grep '__[A-Z_]*__' "$BUILD_DIR/index.js" >&2
  exit 6
fi

cd "$BUILD_DIR"
npm ci --omit=dev --no-audit --no-fund --loglevel=error >&2 >&2

# Content-addressed zip name: hash the actual ZIP BYTES (not source files) so
# the S3 key stays in lockstep with CodeSha256 in CFN. Round-3 fix (P1 #2):
# hashing source only meant node_modules variance produced different
# CodeSha256 with same S3 key -> CFN Function unchanged but Version.CodeSha256
# mismatch -> stack update fails.
#
# Portable SHA256: prefer openssl (universal on macOS + Linux); fall back to
# sha256sum (Linux) then shasum (macOS builtin). Round-3 fix (P2 #2).
sha256_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -hex "$1" | awk '{print $NF}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "build.sh: no sha256 tool available (need openssl, sha256sum, or shasum)" >&2
    return 1
  fi
}

# Build the zip first, then hash it. Use a stable temp name during build.
TMP_ZIP="${OUT_DIR}/.edge-lambda-tmp-$$.zip"
trap 'rm -f "$TMP_ZIP"; rm -rf "$BUILD_DIR"' EXIT
rm -f "$TMP_ZIP"
zip -r -q -X "$TMP_ZIP" index.js package.json package-lock.json node_modules >&2

ZIP_SHA=$(sha256_hex "$TMP_ZIP") || exit 7
SHA_SHORT="${ZIP_SHA:0:16}"
ZIP_NAME="edge-lambda-${SHA_SHORT}.zip"
ZIP_PATH="${OUT_DIR}/${ZIP_NAME}"

mv "$TMP_ZIP" "$ZIP_PATH"

echo "$ZIP_PATH"
