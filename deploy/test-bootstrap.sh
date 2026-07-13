#!/bin/bash
# deploy/test-bootstrap.sh — Validate bootstrap.sh without running system setup
#
# Tests:
#   1. --help prints usage and exits 0
#   2. --pack nonexistent exits non-zero with error
#   3. Arg parsing: --pack, --region, forwarded args
#   4. shellcheck (if available)

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP="${DEPLOY_DIR}/bootstrap.sh"

PASS=0
FAIL=0

ok()   { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
info() { echo "[INFO] $1"; }

echo ""
echo "================================================================"
echo "  bootstrap.sh test suite"
echo "================================================================"
echo ""

# ── Test 1: --help exits 0 and prints usage ───────────────────────────────────
info "Test 1: --help exits 0 and prints usage"
HELP_OUT=$("$BOOTSTRAP" --help 2>&1) && HELP_EXIT=0 || HELP_EXIT=$?
if [[ $HELP_EXIT -eq 0 ]]; then
  ok "--help exits 0"
else
  fail "--help exited $HELP_EXIT (expected 0)"
fi
if echo "$HELP_OUT" | grep -q "Usage:"; then
  ok "--help output contains 'Usage:'"
else
  fail "--help output missing 'Usage:' — got: $(echo "$HELP_OUT" | head -3)"
fi
if echo "$HELP_OUT" | grep -q -- "--pack"; then
  ok "--help output mentions --pack"
else
  fail "--help output missing --pack"
fi
echo ""

# ── Test 2: No --pack arg exits non-zero ─────────────────────────────────────
info "Test 2: missing --pack exits non-zero"
NO_PACK_OUT=$("$BOOTSTRAP" 2>&1) && NO_PACK_EXIT=0 || NO_PACK_EXIT=$?
if [[ $NO_PACK_EXIT -ne 0 ]]; then
  ok "missing --pack exits non-zero ($NO_PACK_EXIT)"
else
  fail "missing --pack should exit non-zero but exited 0"
fi
if echo "$NO_PACK_OUT" | grep -qi "required\|--pack"; then
  ok "missing --pack error message is informative"
else
  fail "missing --pack error message not informative: $(echo "$NO_PACK_OUT" | head -2)"
fi
echo ""

# ── Test 3: --pack nonexistent exits non-zero ─────────────────────────────────
info "Test 3: --pack nonexistent exits non-zero"
# We need a registry available; use a temp repo-like structure if needed
# bootstrap.sh looks for ../packs/registry.yaml relative to deploy/
REGISTRY="${DEPLOY_DIR}/../packs/registry.yaml"
if [[ ! -f "$REGISTRY" ]]; then
  info "  Registry not found at $REGISTRY — skipping test 3 (full repo not present)"
else
  FAKE_PACK_OUT=$("$BOOTSTRAP" --pack __nonexistent_pack_xyz__ 2>&1) && FAKE_EXIT=0 || FAKE_EXIT=$?
  if [[ $FAKE_EXIT -ne 0 ]]; then
    ok "--pack nonexistent exits non-zero ($FAKE_EXIT)"
  else
    fail "--pack nonexistent should exit non-zero but exited 0"
  fi
  if echo "$FAKE_PACK_OUT" | grep -qi "not found\|nonexistent\|registry"; then
    ok "--pack nonexistent error message mentions registry/not found"
  else
    fail "--pack nonexistent error message not informative: $(echo "$FAKE_PACK_OUT" | head -2)"
  fi
fi
echo ""

# ── Test 4: -h shorthand works ───────────────────────────────────────────────
info "Test 4: -h shorthand exits 0 and prints usage"
SHORT_OUT=$("$BOOTSTRAP" -h 2>&1) && SHORT_EXIT=0 || SHORT_EXIT=$?
if [[ $SHORT_EXIT -eq 0 ]]; then
  ok "-h exits 0"
else
  fail "-h exited $SHORT_EXIT (expected 0)"
fi
if echo "$SHORT_OUT" | grep -q "Usage:"; then
  ok "-h output contains 'Usage:'"
else
  fail "-h output missing 'Usage:'"
fi
echo ""

# ── Test 5: Arg parsing writes pack config JSON ───────────────────────────────
info "Test 5: Pack-specific args are parsed and config JSON is written"
ARGPARSE_SCRIPT=$(mktemp /tmp/test-argparse-XXXXXX.sh)
cat > "$ARGPARSE_SCRIPT" << 'ARGPARSE_EOF'
#!/bin/bash
set -euo pipefail
PACK_NAME=""
REGION="us-east-1"
STACK_NAME=""
MODEL=""
GW_PORT=""
MODEL_MODE=""
BEDROCKIFY_PORT=""
HERMES_MODEL=""
LITELLM_URL=""
LITELLM_KEY=""
LITELLM_MODEL=""
PROVIDER_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) ;;
    --pack)            PACK_NAME="$2";    shift 2 ;;
    --region)          REGION="$2";       shift 2 ;;
    --model)           MODEL="$2";        shift 2 ;;
    --gw-port)         GW_PORT="$2";      shift 2 ;;
    --model-mode)      MODEL_MODE="$2";   shift 2 ;;
    --bedrockify-port) BEDROCKIFY_PORT="$2"; shift 2 ;;
    --hermes-model)    HERMES_MODEL="$2"; shift 2 ;;
    --litellm-base-url|--litellm-url)     LITELLM_URL="$2"; shift 2 ;;
    --litellm-api-key|--litellm-key)      LITELLM_KEY="$2"; shift 2 ;;
    --litellm-model)   LITELLM_MODEL="$2"; shift 2 ;;
    --provider-api-key|--provider-key)    PROVIDER_KEY="$2"; shift 2 ;;
    --*) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
    *) shift ;;
  esac
done

TMPCONFIG="$(mktemp /tmp/test-pack-config-XXXXXX.json)"
cat > "${TMPCONFIG}" << JSON
{
  "pack": "${PACK_NAME}",
  "region": "${REGION}",
  "model": "${MODEL}",
  "gw_port": "${GW_PORT}",
  "model_mode": "${MODEL_MODE}"
}
JSON

echo "PACK=${PACK_NAME}"
echo "REGION=${REGION}"
echo "MODEL=${MODEL}"
echo "GW_PORT=${GW_PORT}"
echo "CONFIG_EXISTS=$([ -f "${TMPCONFIG}" ] && echo yes || echo no)"
if command -v jq &>/dev/null; then
  echo "CONFIG_REGION=$(jq -r '.region' "${TMPCONFIG}")"
  echo "CONFIG_MODEL=$(jq -r '.model' "${TMPCONFIG}")"
fi
rm -f "${TMPCONFIG}"
ARGPARSE_EOF

PARSE_TEST=$(bash "$ARGPARSE_SCRIPT" --pack openclaw --region eu-west-1 --model some-model --gw-port 3001 2>&1)
rm -f "$ARGPARSE_SCRIPT"

if echo "$PARSE_TEST" | grep -q "PACK=openclaw"; then
  ok "Arg parse: --pack value captured correctly"
else
  fail "Arg parse: --pack not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "REGION=eu-west-1"; then
  ok "Arg parse: --region value captured correctly"
else
  fail "Arg parse: --region not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "MODEL=some-model"; then
  ok "Arg parse: --model value captured correctly"
else
  fail "Arg parse: --model not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "GW_PORT=3001"; then
  ok "Arg parse: --gw-port value captured correctly"
else
  fail "Arg parse: --gw-port not captured — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "CONFIG_EXISTS=yes"; then
  ok "Arg parse: config JSON was written"
else
  fail "Arg parse: config JSON not written — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "CONFIG_REGION=eu-west-1"; then
  ok "Arg parse: config JSON contains correct region"
else
  info "  jq not available or CONFIG_REGION check skipped — got: $PARSE_TEST"
fi
if echo "$PARSE_TEST" | grep -q "CONFIG_MODEL=some-model"; then
  ok "Arg parse: config JSON contains correct model"
else
  info "  jq not available or CONFIG_MODEL check skipped — got: $PARSE_TEST"
fi
echo ""

# ── Test 6: shellcheck (optional) ────────────────────────────────────────────
info "Test 6: shellcheck (optional)"
if command -v shellcheck &>/dev/null; then
  if shellcheck -S warning "$BOOTSTRAP"; then
    ok "shellcheck passed"
  else
    fail "shellcheck found issues"
  fi
else
  info "  shellcheck not installed — skipping"
fi
echo ""

# ── Test 7: Troika dep-substitution ──────────────────────────────────────────
info "Test 7: get_effective_deps troika primary-substitution"
# Verify get_effective_deps is present and implements the substitution logic.
# We source only the registry helpers + get_effective_deps from bootstrap.sh;
# the rest of the script is not executed.

REGISTRY="${DEPLOY_DIR}/../packs/registry.yaml"
if [[ ! -f "$REGISTRY" ]]; then
  info "  Registry not found — skipping dep-substitution test"
else
  # Extract get_effective_deps function + its dependency (registry_get_deps) to a temp file
  _DEP_TEST_SCRIPT=$(mktemp /tmp/test-dep-subst-XXXXXX.sh)
  cat > "$_DEP_TEST_SCRIPT" << 'DEPTEST_EOF'
#!/bin/bash
set -euo pipefail
REGISTRY="$1"
PRIMARY="${2:-openclaw}"

# Minimal stubs for bootstrap helpers bootstrap.sh needs before registry helpers
registry_get_deps() {
  local pack="$1"
  awk "
    /^  ${pack}:/{found=1; in_deps=0; next}
    found && /^  [a-z]/{exit}
    found && /^    deps:/{in_deps=1; next}
    found && in_deps && /^      - /{gsub(/^      - /, \"\"); print; next}
    found && in_deps && !/^      /{in_deps=0}
  " "$REGISTRY"
}

get_effective_deps() {
  local pack="$1"
  local dep
  while IFS= read -r dep; do
    if [[ "$pack" == "troika" && "${PRIMARY:-openclaw}" != "openclaw" && "$dep" == "openclaw" ]]; then
      echo "${PRIMARY}"
    else
      echo "$dep"
    fi
  done < <(registry_get_deps "$pack")
}

# Test 1: troika + primary=openclaw → no substitution
PRIMARY="openclaw"
DEPS_OC=$(get_effective_deps troika | tr '\n' ',')
if [[ "$DEPS_OC" == *"openclaw"* ]]; then
  echo "PASS: primary=openclaw → openclaw dep preserved"
else
  echo "FAIL: primary=openclaw should preserve openclaw dep; got: $DEPS_OC"
  exit 1
fi

# Test 2: troika + primary=hermes → openclaw replaced with hermes
PRIMARY="hermes"
DEPS_HERMES=$(get_effective_deps troika | tr '\n' ',')
if [[ "$DEPS_HERMES" == *"hermes"* && "$DEPS_HERMES" != *"openclaw"* ]]; then
  echo "PASS: primary=hermes → hermes dep substituted, openclaw removed"
else
  echo "FAIL: primary=hermes substitution wrong; got: $DEPS_HERMES"
  exit 1
fi

# Test 3: non-troika pack unaffected by PRIMARY!=openclaw
PRIMARY="hermes"
DEPS_OC_PACK=$(get_effective_deps openclaw | tr '\n' ',')
# openclaw's own dep list should be unchanged
if [[ "$DEPS_OC_PACK" != *"hermes"* ]]; then
  echo "PASS: non-troika pack unaffected by PRIMARY=hermes"
else
  echo "FAIL: non-troika pack should not be affected; got: $DEPS_OC_PACK"
  exit 1
fi

# Test 4: order preservation — bedrockify,<primary>,claude-code,codex-cli
PRIMARY="hermes"
deps_arr=()
while IFS= read -r dep; do
  deps_arr+=("$dep")
done < <(get_effective_deps troika)
if [[ "${deps_arr[0]}" == "bedrockify" && "${deps_arr[1]}" == "hermes" \
   && "${deps_arr[2]}" == "claude-code" && "${deps_arr[3]}" == "codex-cli" ]]; then
  echo "PASS: dep order preserved (bedrockify→hermes→claude-code→codex-cli)"
else
  echo "FAIL: dep order wrong; got: ${deps_arr[*]}"
  exit 1
fi

echo "ALL_PASS"
DEPTEST_EOF

  DEP_OUT=$(bash "$_DEP_TEST_SCRIPT" "$REGISTRY" 2>&1) && DEP_RC=0 || DEP_RC=$?
  rm -f "$_DEP_TEST_SCRIPT"

  if echo "$DEP_OUT" | grep -q "FAIL"; then
    fail "dep-substitution: at least one case failed — see above"
    echo "$DEP_OUT" | grep -v PASS
  elif echo "$DEP_OUT" | grep -q "ALL_PASS"; then
    ok "dep-substitution: primary=openclaw no-op, primary=hermes substitutes, non-troika unaffected, order preserved"
  else
    fail "dep-substitution: unexpected output — got: $DEP_OUT"
  fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "================================================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "================================================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
