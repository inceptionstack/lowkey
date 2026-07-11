#!/usr/bin/env bash
# tests/test-registry-parser.sh — tests for registry.json + jq parsing
# Run: bash tests/test-registry-parser.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${SCRIPT_DIR}/packs/registry.json"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---- Helpers ----------------------------------------------------------------
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    expected: $expected"; echo "    actual:   $actual"; FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    missing: $needle"; FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  ✓ $desc"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    should not contain: $needle"; FAIL=$((FAIL + 1))
  fi
}

assert_count() {
  local desc="$1" expected="$2" actual="$3"
  local count
  count=$(echo "$actual" | grep -c . || true)
  if [[ "$count" -eq "$expected" ]]; then
    echo "  ✓ $desc (count=$count)"; PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"; echo "    expected count: $expected, got: $count"; FAIL=$((FAIL + 1))
  fi
}

# jq query that mirrors what install.sh does for pack listing
list_agents() {
  local file="$1"
  jq -r '.packs | to_entries[] | select(.value.type == "agent") | "\(.key)|\(.value.description // .key)|\(if .value.experimental then "true" else "false" end)"' "$file" 2>/dev/null
}

# jq query that mirrors what install.sh does for key lookup
get_value() {
  local file="$1" pack="$2" key="$3"
  jq -r --arg p "$pack" --arg k "$key" '.packs[$p][$k] // empty' "$file" 2>/dev/null
}

# ---- Test: real registry.json -----------------------------------------------
echo "=== Test: real registry.json (agent packs) ==="
output=$(list_agents "$REGISTRY")
agent_count=$(echo "$output" | grep -c . || true)
if [[ "$agent_count" -ge 6 ]]; then
  echo "  ✓ lists at least 6 agents (found $agent_count)"; PASS=$((PASS + 1))
else
  echo "  ✗ expected at least 6 agents, found $agent_count"; FAIL=$((FAIL + 1))
fi
assert_contains "includes openclaw" "openclaw|" "$output"
assert_contains "includes claude-code" "claude-code|" "$output"
assert_contains "includes hermes" "hermes|" "$output"
assert_contains "includes kiro-cli" "kiro-cli|" "$output"
removed_packs=$(echo "$output" | grep -c -E '^(pi|ironclaw|nemoclaw)\|' || true)
assert_eq "excludes removed packs (pi/ironclaw/nemoclaw)" "0" "$removed_packs"
bedrockify_as_pack=$(echo "$output" | grep -c '^bedrockify|' || true)
assert_eq "excludes base packs (bedrockify)" "0" "$bedrockify_as_pack"

# ---- Test: experimental flag ------------------------------------------------
echo ""
echo "=== Test: experimental flag detection ==="
assert_contains "openclaw is not experimental" "openclaw|OpenClaw" "$output"
assert_contains "openclaw experimental=false" "|false" "$(echo "$output" | grep openclaw)"
assert_contains "hermes is experimental" "|true" "$(echo "$output" | grep '^hermes|')"
assert_contains "kiro-cli is experimental" "|true" "$(echo "$output" | grep '^kiro-cli|')"

# ---- Test: instance_type lookup ---------------------------------------------
echo ""
echo "=== Test: instance_type lookup ==="
assert_eq "openclaw → t4g.xlarge" "t4g.xlarge" "$(get_value "$REGISTRY" openclaw instance_type)"
assert_eq "hermes → t4g.medium" "t4g.medium" "$(get_value "$REGISTRY" hermes instance_type)"
assert_eq "roundhouse → t4g.medium" "t4g.medium" "$(get_value "$REGISTRY" roundhouse instance_type)"

# ---- Test: get arbitrary keys -----------------------------------------------
echo ""
echo "=== Test: get arbitrary keys ==="
assert_contains "openclaw description" "OpenClaw" "$(get_value "$REGISTRY" openclaw description)"
assert_eq "openclaw default_model" "us.anthropic.claude-opus-4-6-v1" "$(get_value "$REGISTRY" openclaw default_model)"
assert_eq "openclaw brain" "true" "$(get_value "$REGISTRY" openclaw brain)"

# ---- Test: nonexistent pack/key returns empty -------------------------------
echo ""
echo "=== Test: nonexistent pack/key ==="
assert_eq "nonexistent pack" "" "$(get_value "$REGISTRY" doesnotexist instance_type)"
assert_eq "nonexistent key" "" "$(get_value "$REGISTRY" openclaw doesnotexist)"

# ---- Test: fixture with special chars ---------------------------------------
echo ""
echo "=== Test: fixture with special chars ==="
cat > "$TMPDIR/special.json" <<'EOF'
{
  "packs": {
    "base": { "type": "base", "description": "not an agent" },
    "alpha": {
      "type": "agent",
      "description": "Alpha -- has dashes, (parens), and pipes | in desc",
      "experimental": false,
      "instance_type": "t4g.large"
    },
    "beta": {
      "type": "agent",
      "description": "Beta (experimental)",
      "experimental": true,
      "instance_type": "t4g.small"
    }
  }
}
EOF
special_output=$(list_agents "$TMPDIR/special.json")
assert_count "lists 2 agents from fixture" 2 "$special_output"
assert_contains "alpha is listed" "alpha|" "$special_output"
assert_contains "beta is experimental" "beta|Beta (experimental)|true" "$special_output"
assert_eq "alpha instance_type" "t4g.large" "$(get_value "$TMPDIR/special.json" alpha instance_type)"

# ---- Test: empty registry ---------------------------------------------------
echo ""
echo "=== Test: empty registry ==="
echo '{"packs":{}}' > "$TMPDIR/empty.json"
empty_output=$(list_agents "$TMPDIR/empty.json")
assert_eq "no output for empty registry" "" "$empty_output"

# ---- Test: no agent packs ---------------------------------------------------
echo ""
echo "=== Test: no agent packs (only base) ==="
echo '{"packs":{"base":{"type":"base"}}}' > "$TMPDIR/base-only.json"
base_output=$(list_agents "$TMPDIR/base-only.json")
assert_eq "no output when only base packs" "" "$base_output"

# ---- Test: missing fields ---------------------------------------------------
echo ""
echo "=== Test: missing fields ==="
cat > "$TMPDIR/minimal.json" <<'EOF'
{
  "packs": {
    "bare": { "type": "agent" },
    "partial": { "type": "agent", "description": "has desc", "instance_type": "t4g.nano" }
  }
}
EOF
minimal_output=$(list_agents "$TMPDIR/minimal.json")
assert_count "2 agents from minimal fixture" 2 "$minimal_output"
assert_contains "bare uses key as desc fallback" "bare|bare|false" "$minimal_output"
assert_eq "partial instance_type" "t4g.nano" "$(get_value "$TMPDIR/minimal.json" partial instance_type)"
assert_eq "bare has no instance_type" "" "$(get_value "$TMPDIR/minimal.json" bare instance_type)"

# ---- Test: malformed JSON ---------------------------------------------------
echo ""
echo "=== Test: malformed JSON (no crash) ==="
echo "not json at all" > "$TMPDIR/bad.json"
bad_output=$(list_agents "$TMPDIR/bad.json" || true)
assert_eq "parser returns empty on malformed input" "" "$bad_output"

# ---- Test: registry.json is valid JSON --------------------------------------
echo ""
echo "=== Test: registry.json validity ==="
if jq empty "$REGISTRY" 2>/dev/null; then
  echo "  ✓ registry.json is valid JSON"; PASS=$((PASS + 1))
else
  echo "  ✗ registry.json is NOT valid JSON"; FAIL=$((FAIL + 1))
fi

# ---- Results ----------------------------------------------------------------
echo ""
echo "================================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "================================================================"
[[ $FAIL -eq 0 ]] || exit 1
