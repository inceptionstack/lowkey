#!/usr/bin/env bash
# tests/test-wake-token.sh — Contract tests for the wake token check in
# bootstraps/optional/idle-shutdown/wake-lambda/index.mjs.
#
# The test runs the real handler with stub @aws-sdk modules. It asserts that:
#   - the correct token passes the check             → not 403
#   - a wrong token of the same length               → 403
#   - a wrong token of a different length            → 403, no exception
#   - a token with the same string length but a
#     different UTF-8 byte length                    → 403, no exception
#   - the handler compares with crypto.timingSafeEqual and not with !==
#
# A unit test cannot measure timing, so the last check reads the source.
# No AWS required. Needs node. Run standalone or via CI (discovered by pack-tests.yml).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$REPO_ROOT/bootstraps/optional/idle-shutdown/wake-lambda/index.mjs"

if [[ ! -f "$SRC" ]]; then
  echo "FAIL: index.mjs not found at $SRC" >&2
  exit 1
fi
command -v node >/dev/null || { echo "FAIL: node not found" >&2; exit 1; }

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { printf "${GREEN}  \xE2\x9C\x93${NC} %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "${RED}  \xE2\x9C\x97${NC} %s\n" "$1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub @aws-sdk modules (the Lambda runtime supplies the real ones) ---
mkdir -p "$TMP/node_modules/@aws-sdk/client-ssm" "$TMP/node_modules/@aws-sdk/client-ec2"

cat > "$TMP/node_modules/@aws-sdk/client-ssm/package.json" <<'JSON'
{ "name": "@aws-sdk/client-ssm", "type": "module", "main": "index.mjs" }
JSON
cat > "$TMP/node_modules/@aws-sdk/client-ssm/index.mjs" <<'JS'
class Cmd { constructor(input) { this.input = input; } }
export class GetParameterCommand extends Cmd {}
export class DeleteParameterCommand extends Cmd {}
export class PutParameterCommand extends Cmd {}
export class SSMClient {
  async send(cmd) {
    if (cmd instanceof GetParameterCommand) {
      const v = globalThis.__params[cmd.input.Name];
      if (v === undefined) {
        const e = new Error("not found"); e.name = "ParameterNotFound"; throw e;
      }
      return { Parameter: { Value: v } };
    }
    return {};
  }
}
JS

cat > "$TMP/node_modules/@aws-sdk/client-ec2/package.json" <<'JSON'
{ "name": "@aws-sdk/client-ec2", "type": "module", "main": "index.mjs" }
JSON
cat > "$TMP/node_modules/@aws-sdk/client-ec2/index.mjs" <<'JS'
class Cmd { constructor(input) { this.input = input; } }
export class StartInstancesCommand extends Cmd {}
export class DescribeInstanceStatusCommand extends Cmd {}
export class EC2Client {
  async send(cmd) {
    if (cmd instanceof DescribeInstanceStatusCommand) {
      return { InstanceStatuses: [{ InstanceState: { Name: "running" } }] };
    }
    return {};
  }
}
JS

cp "$SRC" "$TMP/index.mjs"

cat > "$TMP/run.mjs" <<'JS'
const token = process.argv[2];
globalThis.__params = {
  "/openclaw/wake-token": "123e4567-e89b-12d3-a456-426614174000",
  "/openclaw/wake-config/instance-id": "i-0123456789abcdef0",
  "/openclaw/wake-config/telegram-chat-id": "",
  "/openclaw/wake-config/telegram-bot-token": "",
};
const { handler } = await import("./index.mjs");
try {
  const res = await handler({ queryStringParameters: { token } });
  console.log(res.statusCode);
} catch (e) {
  console.log("THREW:" + e.name);
}
JS

# run_case <token>  -> prints the status code, or THREW:<error name>
run_case() {
  node "$TMP/run.mjs" "$1"
}

echo "wake-lambda token check"

STORED="123e4567-e89b-12d3-a456-426614174000"

out="$(run_case "$STORED")"
if [[ "$out" == "200" ]]; then pass "correct token passes the check"; else fail "correct token: got $out, want 200"; fi

out="$(run_case "123e4567-e89b-12d3-a456-426614174001")"
if [[ "$out" == "403" ]]; then pass "wrong token, same length → 403"; else fail "wrong token, same length: got $out, want 403"; fi

out="$(run_case "short")"
if [[ "$out" == "403" ]]; then pass "wrong token, different length → 403"; else fail "wrong token, different length: got $out, want 403"; fi

# Same number of JS characters as STORED (36), but é is 2 bytes in UTF-8.
out="$(run_case "é23e4567-e89b-12d3-a456-426614174000")"
if [[ "$out" == "403" ]]; then pass "same string length, different byte length → 403"; else fail "same string length, different byte length: got $out, want 403"; fi

if grep -q "timingSafeEqual" "$SRC" && ! grep -Eq 'token[[:space:]]*!==[[:space:]]*stored|stored[[:space:]]*!==[[:space:]]*token' "$SRC"; then
  pass "handler compares with crypto.timingSafeEqual, not !=="
else
  fail "handler must compare the token with crypto.timingSafeEqual, not !=="
fi

echo
echo "passed: $PASS, failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
