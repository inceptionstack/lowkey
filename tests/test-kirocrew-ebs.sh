#!/usr/bin/env bash
# tests/test-kirocrew-ebs.sh — KiroCrew EBS workspace contract
# Verifies the pack requests a data volume and bootstrap maps the agent workspace
# onto that volume. The test is static because mounting requires a live EC2 host.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT_DIR}/packs/kirocrew/manifest.yaml"
REGISTRY_YAML="${ROOT_DIR}/packs/registry.yaml"
REGISTRY_JSON="${ROOT_DIR}/packs/registry.json"
BOOTSTRAP="${ROOT_DIR}/deploy/bootstrap.sh"
SERVICE="${ROOT_DIR}/packs/kirocrew/resources/kirocrew-gateway.service"

PASS=0
FAIL=0

pass() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

if python3 - "$MANIFEST" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    data = yaml.safe_load(stream)
assert data["data_volume_gb"] == 80
PY
then
  pass "KiroCrew manifest requests an 80 GB data volume"
else
  fail "KiroCrew manifest must request an 80 GB data volume"
fi

if grep -A12 '^  kirocrew:' "$REGISTRY_YAML" | grep -q '^    data_volume_gb: 80$'; then
  pass "KiroCrew YAML registry requests an 80 GB data volume"
else
  fail "KiroCrew YAML registry must request an 80 GB data volume"
fi

if python3 - "$REGISTRY_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["packs"]["kirocrew"]["data_volume_gb"] == 80
PY
then
  pass "KiroCrew generated registry requests an 80 GB data volume"
else
  fail "KiroCrew generated registry must request an 80 GB data volume"
fi

assert_bootstrap_contains() {
  local pattern="$1"
  local description="$2"
  if grep -Fq "$pattern" "$BOOTSTRAP"; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_bootstrap_contains \
  'if [[ "${PACK_NAME}" == "kirocrew" && "${DATA_VOL_GB}" -gt 0 && -d /mnt/ebs-data ]]; then' \
  "bootstrap gates the workspace mapping on KiroCrew and a mounted data volume"
assert_bootstrap_contains \
  'mount --bind /mnt/ebs-data/workplace /home/ec2-user/workplace' \
  "bootstrap bind-mounts the EBS workplace directory"
assert_bootstrap_contains \
  '/mnt/ebs-data/workplace /home/ec2-user/workplace none bind,nofail,x-systemd.requires-mounts-for=/mnt/ebs-data 0 0' \
  "bootstrap persists a non-fatal workplace bind mount after the data volume"
if grep -Fq 'ReadWritePaths=/home/ec2-user/workplace' "$SERVICE"; then
  pass "KiroCrew gateway can write to the EBS-backed workplace"
else
  fail "KiroCrew gateway must allow writes to the EBS-backed workplace"
fi

printf '\nResults: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
