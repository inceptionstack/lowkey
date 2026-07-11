# Pack Checklist — Creating a New Loki Agent Pack

This document defines everything needed to create a new pack for the lowkey deployer.
Use `scripts/verify-pack` to validate your pack before submitting.

```bash
# Verify a single pack
scripts/verify-pack ./packs/my-pack

# With fix suggestions
scripts/verify-pack ./packs/my-pack --fix

# Verify all packs
scripts/verify-pack --all
```

---

## Quick Start

```bash
# 1. Create pack directory
mkdir -p packs/my-agent/resources

# 2. Create required files (see sections below)
touch packs/my-agent/manifest.yaml
touch packs/my-agent/install.sh
touch packs/my-agent/resources/shell-profile.sh
touch packs/my-agent/test.sh

# 3. Make scripts executable
chmod +x packs/my-agent/install.sh
chmod +x packs/my-agent/test.sh

# 4. Verify
scripts/verify-pack ./packs/my-agent --fix
```

---

## Directory Structure

Every agent pack lives in `packs/<name>/` and follows this layout:

```
packs/my-agent/
├── manifest.yaml              # REQUIRED — pack metadata, params, deps, health check
├── install.sh                 # REQUIRED — idempotent installer script
├── resources/
│   └── shell-profile.sh      # REQUIRED (agent packs) — aliases + welcome banner
│   └── *.tpl                  # Optional — service files, config templates
└── test.sh                    # RECOMMENDED — offline unit tests
```

---

## 1. manifest.yaml (REQUIRED)

The manifest declares what the pack is, what it needs, and what it provides.
**All keys below are required.** The name must match the directory name.

```yaml
name: my-agent                              # Must match directory name
version: "1.0.0"                            # Semver string
type: agent                                 # "agent" or "base"
description: "My Agent — one-line desc"     # Human-readable, used in installer menu

deps:                                       # Pack dependencies (installed first)
  - bedrockify                              # Most agent packs need this

requirements:
  arch:                                     # Supported architectures
    - arm64
    - amd64
  os:                                       # Supported operating systems
    - al2023
    - ubuntu2204
  min_instance_type: t4g.medium             # Minimum EC2 instance size

params:                                     # Config parameters (each needs all 3 fields)
  - name: region
    description: "AWS region for Bedrock"
    default: us-east-1
  - name: model
    description: "Model ID for the agent"
    default: "us.anthropic.claude-sonnet-4-6-v1"
  - name: bedrockify-port
    description: "Port where bedrockify is running"
    default: "8090"

health_check:                               # How bootstrap verifies the install
  command: "my-agent --version"             # OR url: "http://127.0.0.1:${port}/"
  timeout: 10                               # Seconds

provides:
  commands:                                 # CLI commands this pack makes available
    - my-agent
  services: []                              # Systemd services (empty if none)
```

### Param rules
- Every param must have `name`, `description`, and `default`
- Common params: `region`, `model`, `bedrockify-port`
- Params are injected into `/tmp/loki-pack-config.json` by the bootstrap dispatcher

### Health check types
- **command**: `command: "my-agent --version"` — run a shell command, expect exit 0
- **url**: `url: "http://127.0.0.1:${port}/"` + `expect: "\"status\":\"ok\""` — HTTP check

---

## 2. install.sh (REQUIRED)

The installer script runs on the target EC2 instance during bootstrap.
It must be **idempotent** (safe to re-run).

### Required patterns

```bash
#!/usr/bin/env bash
# packs/my-agent/install.sh — Install My Agent
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../common.sh
source "${SCRIPT_DIR}/../common.sh"

# ── Read config from bootstrap dispatcher ─────────────────────────────────────
REGION="$(pack_config_get region "us-east-1")"
MODEL="$(pack_config_get model "us.anthropic.claude-sonnet-4-6-v1")"
BEDROCKIFY_PORT="$(pack_config_get bedrockify_port "8090")"

# ── Help ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: install.sh [OPTIONS]
  --region         AWS region (default: $REGION)
  --model          Model ID (default: $MODEL)
  --help           Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)   REGION="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --help)     usage ;;
    *)          shift ;;
  esac
done

# ── Install logic ─────────────────────────────────────────────────────────────
step "Installing My Agent"

# ... your installation steps here ...
# Use: ok "message", warn "message", fail "message" from common.sh
# Use: step "Step Name" to announce major phases

# ── Verify ────────────────────────────────────────────────────────────────────
step "Verifying My Agent"
check_bedrockify_health "$BEDROCKIFY_PORT"
require_cmd my-agent

# ── Done ──────────────────────────────────────────────────────────────────────
write_done_marker "my-agent"
```

### Checklist for install.sh
- [ ] `#!/usr/bin/env bash` shebang (first line)
- [ ] `set -euo pipefail` (fail fast on errors)
- [ ] Sources `../common.sh` for shared helpers
- [ ] Reads config via `pack_config_get` (not hardcoded values)
- [ ] Supports `--help` flag (prints usage, exits 0)
- [ ] Calls `write_done_marker "<pack-name>"` on success
- [ ] Is executable (`chmod +x`)
- [ ] Idempotent (safe to run twice)

### Available helpers from common.sh
| Function | Purpose |
|----------|---------|
| `ok "msg"` | Print success message |
| `warn "msg"` | Print warning |
| `fail "msg"` | Print error and exit 1 |
| `step "name"` | Announce a major phase (updates SSM progress) |
| `require_cmd cmd [cmd...]` | Fail if commands not found |
| `write_done_marker "name"` | Write `/tmp/pack-name-done` marker |
| `pack_config_get "key" "default"` | Read from bootstrap config JSON |
| `check_bedrockify_health PORT` | Verify bedrockify is running |

---

## 3. resources/shell-profile.sh (REQUIRED for agent packs)

Defines shell aliases and the welcome banner shown when users SSM into the instance.
**All four variables must be defined** (even if empty string) — the bootstrap runs
with `set -u` and will crash on any missing variable.

```bash
# My Agent shell profile — sourced by bootstrap for .bashrc
# This file defines aliases and the welcome banner for the my-agent pack.

PACK_ALIASES='
alias ma="my-agent"
alias mah="my-agent --help"
'

PACK_BANNER_NAME="My Agent Environment"
PACK_BANNER_EMOJI="🤖"
PACK_BANNER_COMMANDS='
  my-agent              → Run My Agent
  my-agent --help       → Show options
  my-agent --version    → Show installed version
'
```

### Required variables
| Variable | Purpose | Example |
|----------|---------|---------|
| `PACK_ALIASES` | Shell aliases written to `.bashrc` | `alias ma="my-agent"` |
| `PACK_BANNER_NAME` | Name shown in welcome banner | `"My Agent Environment"` |
| `PACK_BANNER_EMOJI` | Emoji for the banner | `"🤖"` |
| `PACK_BANNER_COMMANDS` | Commands listed in welcome banner | Multi-line string |

> **Why this matters:** The bootstrap dispatcher sources this file under `set -euo pipefail`.
> If ANY variable is undefined, bash treats it as an unbound variable error and the
> entire bootstrap aborts. This was the root cause of the IronClaw deploy failure.

---

## 4. Registry Entries (REQUIRED for deployment)

Your pack must be listed in **both** registry files for the installer to discover it.

### registry.yaml
```yaml
packs:
  # ... existing packs ...
  my-agent:
    type: agent
    description: "My Agent — one-line description"
    deps:
      - bedrockify
    instance_type: t4g.medium
    root_volume_gb: 40
    data_volume_gb: 0
    default_model: "us.anthropic.claude-sonnet-4-6-v1"
    ports: {}
    brain: false
    claude_code: false
    experimental: true          # Set true for new packs
```

### registry.json (GENERATED — do NOT edit by hand)
The JSON is a **generated artifact** for the client-side installer (which only
has `jq`, not a YAML parser). `registry.yaml` is the single source of truth.

Regenerate after editing `registry.yaml`:
```bash
bash scripts/sync-registry
```

CI/tests enforce parity via `bash scripts/sync-registry --check`. Manual edits
to `registry.json` will be caught and rejected by `tests/test-pack-contracts.sh`.

---

## 5. test.sh (RECOMMENDED)

Offline tests that validate your pack without requiring the agent to be installed.
CI auto-discovers and runs `packs/<name>/test.sh` files.

Good things to test:
- manifest.yaml parses and has correct values
- install.sh --help exits 0
- shell-profile.sh sources without error
- Config generation produces valid output
- Download URLs are correctly constructed
- Template rendering works

See `packs/ironclaw/test.sh` or `packs/pi/test.sh` for examples.

---

## 6. Dependency Rules

- **Agent packs** almost always depend on `bedrockify` (provides the OpenAI-compatible proxy)
- **Base packs** have no dependencies (they ARE the dependency)
- Dependencies are installed before your pack by the bootstrap dispatcher
- List deps in manifest.yaml AND registry.yaml/json

---

## Common Mistakes

| Mistake | What happens | Prevention |
|---------|-------------|-----------|
| Missing `PACK_ALIASES` in shell-profile.sh | Bootstrap crashes: "unbound variable" | verify-pack catches this |
| install.sh not executable | Bootstrap skips install silently | `chmod +x` + verify-pack |
| Hardcoded region/model in install.sh | Config from installer is ignored | Use `pack_config_get` |
| Missing `write_done_marker` | Bootstrap can't verify install succeeded | verify-pack catches this |
| Pack not in registry.yaml/json | Pack won't appear in installer menu | verify-pack catches this |
| manifest name ≠ directory name | Bootstrap can't find pack resources | verify-pack catches this |

---

## Verification

Before submitting a PR, always run:

```bash
# Verify your pack
scripts/verify-pack ./packs/my-agent --fix

# Run your pack tests
bash packs/my-agent/test.sh

# Run full test suite
bash packs/test-packs.sh
bash tests/test-pack-contracts.sh
```

CI will reject PRs where pack contracts are violated.
