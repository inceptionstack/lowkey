# KiroCrew Pack — Implementation Plan (v3)

## Overview

A new lowkey pack called `kirocrew` that installs **KiroCrew** (the multi-agent crew gateway on top of Kiro CLI). The pack has two phases:

1. **Phase 1 — Kiro CLI base** (replicates `packs/kiro-cli/install.sh` logic inline; does NOT depend on kiro-cli pack)
2. **Phase 2 — KiroCrew layer** (installs the `kirocrew` Python gateway on top, using the official upstream installer)

### Why inline instead of deps?

Roy's requirement: packs must not trigger one another. The kiro-cli functionality is duplicated (not imported) so the two packs remain fully independent and can diverge in the future.

---

## File Structure

```
packs/kirocrew/
├── manifest.yaml
├── install.sh
├── test.sh
└── resources/
    ├── shell-profile.sh
    └── kirocrew-gateway.service    # systemd unit template
```

---

## Phase 1 — Kiro CLI Base (inline replication)

Steps replicated from `packs/kiro-cli/install.sh`:

| Step | Description | Notes |
|------|-------------|-------|
| 1 | Install Kiro CLI via upstream installer (`https://cli.kiro.dev/install`) | Verify v2+; idempotent |
| 2 | Install MCP server prerequisites (uv, uvx, gcc, python3-devel) | Same as kiro-cli |
| 3 | Configure AWS MCP proxy via `install_aws_mcp_proxy()` from common.sh | Config written to `~/.kiro/settings/mcp.json` |
| 4 | Wire KIRO_API_KEY (if `--from-secret` or `--kiro-api-key` provided) | Same secure handling: umask 077, `~/.kiro/env`, 0600 perms, %q escaping |
| 5 | Install loki-skills + AWS Agent Toolkit skills | Via `ensure_skills_clone` + `install_aws_toolkit_skills` |

### Auth modes (same as kiro-cli)
- **Headless**: `--from-secret <secret-id>` → resolves from Secrets Manager → writes `~/.kiro/env`
- **Interactive**: User runs `kiro-cli login --use-device-flow` post-install

---

## Phase 2 — KiroCrew Layer

After the Kiro CLI base is installed, install KiroCrew — a **full gateway server** (Python backend + React dashboard) that drives kiro-cli over the Agent Client Protocol (ACP).

Source: https://kiro.dev/docs/crew/installation.md

| Step | Description | Notes |
|------|-------------|-------|
| 6 | Ensure Python ≥ 3.10 (3.12 recommended) | AL2023 current AMIs ship 3.11+; if somehow missing, `dnf install python3.11`. Ubuntu 22.04 ships 3.10. |
| 7 | Install pipx (if not present) | KiroCrew installer prefers pipx; pre-install for cleaner management |
| 8 | Run upstream KiroCrew installer | `curl -fsSL https://download.crew.kiro.dev/cli.sh \| sh -s -- --channel <channel> [--version <ver>]` |
| 9 | Verify `kirocrew` binary in PATH | `kirocrew --version`; fail with actionable message if not found |
| 10 | Install pip extras (if requested) | `pipx inject kirocrew boto3 amazon-transcribe` or `pip install "kirocrew[aws,voice]"` in managed venv |
| 11 | Run `kirocrew setup` (TTY-gated) | **Only if TTY detected** (`[[ -t 0 ]]`); otherwise log post-install instruction. Creates `~/.kiro/crew/config.json` |
| 12 | Run `kirocrew doctor` (informational) | Log output but do NOT fail install on doctor warnings (embedding model not yet downloaded is expected) |
| 13 | Preload embedding model | Download ~610 MB model during install so gateway is fully operational on first start |
| 14 | Install systemd service (if `start-gateway=true`) | Template unit file, enable + start `kirocrew-gateway.service` |

### KiroCrew architecture:
- **What it is**: Multi-agent crew gateway with React dashboard, ACP, semantic memory, cron, audit
- **LLM provider**: Drives `kiro-cli` over Agent Client Protocol (`agent.provider = acp`)
- **Auth**: Reuses Kiro CLI auth — no additional credentials needed (KIRO_API_KEY from Phase 1)
- **Embedding model**: ~610 MB, **preloaded during install** to `~/.kiro/crew/models/`. Ensures vector search is immediately operational on first gateway start (no keyword-matching degradation period). Set `KIROCREW_EMBED_MODEL_URL` for airgapped mirrors.
- **Port**: 5476 (env: `KIROCREW_PORT`, overridable via `--gateway-port` param)

### KiroCrew installer details (from `https://download.crew.kiro.dev/cli.sh`):
- Downloads a **signed wheel** from CloudFront CDN
- Verifies RSA-SHA256 signature against embedded public key (offline trust root)
- Then verifies wheel SHA-256 against the signed manifest digest
- Installs via **pipx** (preferred, if available) or a managed venv at `~/.kiro/crew-venv` (BESIDE the data home, not inside it)
- Binary: `~/.local/bin/kirocrew`
- Channels: `stable` (default), `nightly`, `insider` (env: `KIROCREW_CHANNEL`)
- Requires: curl, openssl, Python ≥ 3.10, sha256sum/shasum

### Installer error handling:
- If `download.crew.kiro.dev` is unreachable: `fail` with actionable message (check DNS/firewall/proxy)
- If signature verification fails: upstream installer already aborts — we propagate
- If Python < 3.10: attempt `dnf install python3.11` (AL2023) or fail with clear prereq message

### Data home (`~/.kiro/crew/`, env: `KIROCREW_HOME`):
```
~/.kiro/crew/
├── config.json          # user configuration
├── .env                 # credentials (Slack tokens, owner ID)
├── channel              # records install channel (written by upstream installer)
├── models/              # embedding model (~610 MB, auto-downloaded)
├── workspace/
│   ├── memory/          # preferences.md, projects.md, history/
│   ├── lessons.jsonl    # learned corrections
│   └── knowledge/       # ingested documents (FTS5 + vectors)
├── conversations/       # JSONL session logs
├── crons.json           # scheduled jobs
├── audit.log            # bash command audit trail
└── agents/              # generated kiro-cli agent configs
```

### Optional pip extras (installed post-wheel if `--extras` param set):
- `kirocrew[voice]` — boto3 + amazon-transcribe (cloud STT)
- `kirocrew[aws]` — boto3 for AWS integrations

### Post-install verification:
```bash
kirocrew doctor    # checks: kiro-cli binary, auth, embeddings, MCP servers, config
kirocrew gateway   # starts server → http://localhost:5476
```

---

## manifest.yaml Design

```yaml
name: kirocrew
version: "1.0.0"
type: agent
description: "KiroCrew — multi-agent crew gateway on Kiro CLI (ACP) with dashboard, semantic memory, and MCP"

deps: []   # No dep on kiro-cli; we repeat inline

requirements:
  arch:
    - arm64
    - amd64
  os:
    - al2023
    - ubuntu2204
  min_instance_type: t4g.medium

params:
  - name: region
    description: "AWS region (informational; Kiro uses its own cloud inference)"
    default: us-east-1
  - name: from-secret
    description: "AWS Secrets Manager secret id/arn for Kiro API key (headless mode)"
    default: ""
  - name: channel
    description: "KiroCrew release channel (stable | nightly | insider)"
    default: "stable"  # confirmed by Roy 2026-08-05
  - name: kirocrew-version
    description: "Pin KiroCrew to a specific version (leave empty for latest in channel)"
    default: ""
  - name: extras
    description: "Comma-separated pip extras to install after wheel (voice, aws)"
    default: "aws,voice"  # confirmed by Roy 2026-08-05
  - name: gateway-port
    description: "Port for the KiroCrew gateway (env: KIROCREW_PORT)"
    default: "5476"
  - name: start-gateway
    description: "Install and enable kirocrew-gateway systemd service (true|false)"
    default: "true"
  - name: kirocrew-home
    description: "Override KiroCrew data home (env: KIROCREW_HOME)"
    default: ""

health_check:
  command: "kiro-cli --version && kirocrew --version"
  timeout: 15

provides:
  commands:
    - kiro-cli
    - kirocrew
  services:
    - kirocrew-gateway

instance_type: t4g.medium
root_volume_gb: 40
data_volume_gb: 80

experimental: true
```

### Design decisions in manifest:
- **`start-gateway` defaults to `true`**: KiroCrew's primary value is the web gateway/dashboard. Users expect to access it via browser immediately after install.
- **`extras` defaults to `aws`**: Our instances are AWS-focused; boto3 is almost always useful.
- **`kirocrew-home`**: Parameterized for flexibility (addresses review LOW finding).
- **Health check only checks binaries exist**: Does NOT depend on gateway running or embedding model downloaded (addresses review M2/M4).

---

## install.sh Outline

```bash
#!/usr/bin/env bash
# packs/kirocrew/install.sh — Install Kiro CLI + KiroCrew multi-agent gateway
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# ── Defaults ──────────────────────────────────────────────────────────────
PACK_ARG_REGION="$(pack_config_get region "us-east-1")"
PACK_ARG_FROM_SECRET="$(pack_config_get from-secret "")"
PACK_ARG_API_KEY="$(pack_config_get kiro-api-key "")"
PACK_ARG_CHANNEL="$(pack_config_get channel "stable")"
PACK_ARG_KIROCREW_VERSION="$(pack_config_get kirocrew-version "")"
PACK_ARG_EXTRAS="$(pack_config_get extras "aws,voice")"
PACK_ARG_GATEWAY_PORT="$(pack_config_get gateway-port "5476")"
PACK_ARG_START_GATEWAY="$(pack_config_get start-gateway "true")"
PACK_ARG_KIROCREW_HOME="$(pack_config_get kirocrew-home "")"

# ── Arg parsing ───────────────────────────────────────────────────────────
# Flags: --region, --from-secret, --kiro-api-key (hidden/deprecated),
#        --channel, --kirocrew-version, --extras, --gateway-port,
#        --start-gateway, --kirocrew-home, --model (accept+ignore), --help
#
# CRITICAL: --model MUST be accepted (bootstrap passes --model kiro-cloud
# to all packs). Ignore gracefully with informational log. (Fix for H3.)
#
# Unknown flags: exit 2 (matches kiro-cli behavior)
# Mutex: --kiro-api-key + --from-secret → exit 2

# ══════════════════════════════════════════════════════════════════════════
# PHASE 1: Kiro CLI Base (replicated from packs/kiro-cli/install.sh)
# ══════════════════════════════════════════════════════════════════════════

pack_banner "kirocrew"

# Step 1: Install Kiro CLI via upstream installer
#   - curl -fsSL https://cli.kiro.dev/install | bash (as ec2-user)
#   - Check if already installed first (idempotent)
#   - Verify v2+ (warn on v1/v3+)
#   - Note: `sudo -u ec2-user` only if running as root (fix M1)

# Step 2: MCP prerequisites (uv, uvx, gcc, python3-devel)
#   - Same as kiro-cli pack

# Step 3: AWS MCP proxy config
#   - install_aws_mcp_proxy "${REGION}" "${HOME}/.kiro/settings/mcp.json"

# Step 4: KIRO_API_KEY wiring
#   - Same logic as kiro-cli (--from-secret → Secrets Manager → ~/.kiro/env)
#   - umask 077, chmod 600, %q escaping, idempotent .bash_profile source

# Step 5: Skills clone
#   - ensure_skills_clone + install_aws_toolkit_skills

# ══════════════════════════════════════════════════════════════════════════
# PHASE 2: KiroCrew Layer
# ══════════════════════════════════════════════════════════════════════════

# Step 6: Ensure Python ≥ 3.10
#   - Check python3.12, python3.11, python3.10, python3 (in order)
#   - On AL2023 if none ≥3.10: dnf install python3.11
#   - Fail with clear message if still not available

# Step 7: Install pipx (preferred by upstream installer)
#   - pip install pipx (if not present)
#   - Ensures cleaner install isolation

# Step 8: Run upstream KiroCrew installer
#   - KIROCREW_CHANNEL="${CHANNEL}" curl -fsSL https://download.crew.kiro.dev/cli.sh | sh
#   - Pass --channel and --version if specified
#   - Set KIROCREW_HOME if param is non-empty
#   - On failure: log actionable error (DNS? proxy? Python version?)

# Step 9: Verify kirocrew binary
#   - command -v kirocrew || fail
#   - kirocrew --version → log

# Step 10: Install pip extras (if --extras is non-empty)
#   - If installed via pipx: pipx inject kirocrew <packages>
#   - If installed via managed venv: ~/.kiro/crew-venv/bin/pip install "kirocrew[aws,voice]"
#   - Parse comma-separated extras param → install matching packages

# Step 11: kirocrew setup (TTY-gated)
#   - if [[ -t 0 ]]; then kirocrew setup; fi
#   - else: log "Run 'kirocrew setup' to complete interactive configuration"
#   - NEVER hang waiting for input in automated bootstrap

# Step 12: kirocrew doctor (informational only)
#   - kirocrew doctor || warn "doctor reported issues (non-fatal)"
#   - Log output for debugging; do NOT fail install
#   - Expected warnings: embedding model not yet downloaded (downloads on first gateway start)

# Step 13: Preload embedding model
#   - Start gateway briefly to trigger model download, or use dedicated download command
#   - Approach A (PREFERRED): `kirocrew gateway --download-model-only` (if supported — check --help)
#   - Approach B (LAST RESORT ONLY — risky): `timeout 300 kirocrew gateway &` → wait for model → kill
#     WARNING: race conditions, port conflicts with Step 14, possible model corruption on kill.
#     If forced to use B: bind to temp port, use SIGTERM, verify port freed before Step 14.
#   - Approach C (RECOMMENDED fallback): Direct curl of model URL to ~/.kiro/crew/models/
#     Requires discovering default KIROCREW_EMBED_MODEL_URL from gateway source/docs.
#     Deterministic, no side effects, can be checksum-verified.
#   - Verify: model file exists in ~/.kiro/crew/models/ AND filesize > 500MB (catch truncated downloads)
#   - If SHA-256 checksum is available from upstream, verify that too
#   - KIROCREW_EMBED_MODEL_URL env can override CDN source (airgapped installs)
#   - This adds 1-3 minutes to install but ensures zero degradation on first use
#
#   Implementation order of preference: A > C > B

# Step 14: Systemd service (if start-gateway=true)
#   - Install resources/kirocrew-gateway.service → /etc/systemd/system/
#   - Template KIROCREW_PORT and KIROCREW_HOME into unit file
#   - systemctl daemon-reload && systemctl enable --now kirocrew-gateway.service
#   - Verify service started: systemctl is-active

# ── Shell profile ─────────────────────────────────────────────────────────
# Install to /etc/profile.d/kirocrew.sh (NOT kiro-cli.sh — avoids collision)

# ── Done ──────────────────────────────────────────────────────────────────
write_done_marker "kirocrew"
```

---

## Systemd Unit Template (`resources/kirocrew-gateway.service`)

```ini
[Unit]
Description=KiroCrew Gateway (multi-agent crew server)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
Group=ec2-user
Environment=KIROCREW_PORT=__PORT__
Environment=KIROCREW_HOME=__HOME__
Environment=PATH=/home/ec2-user/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=__BINPATH__ gateway
Restart=on-failure
RestartSec=5
# Embedding model download can take minutes on first start
TimeoutStartSec=300
# Graceful shutdown
TimeoutStopSec=30
KillSignal=SIGINT

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
# Covers both ~/.kiro/crew (data home) and ~/.kiro/settings, ~/.kiro/agents,
# ~/.kiro/env etc. that kiro-cli subprocesses (spawned via ACP) may write to.
ReadWritePaths=/home/ec2-user/.kiro
ReadWritePaths=/home/ec2-user/.local
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

install.sh will `sed` replace `__PORT__`, `__HOME__`, and `__BINPATH__` with actual values before copying to `/etc/systemd/system/`.

`__BINPATH__` is resolved at install time via `command -v kirocrew` (handles both pipx and managed-venv install paths).

---

## Shell Profile (`resources/shell-profile.sh`)

```bash
# KiroCrew shell profile — sourced for .bashrc and /etc/profile.d
# Auth-mode-aware (checks ~/.kiro/env like kiro-cli pack).

PACK_TUI_COMMAND="kirocrew gateway"

PACK_ALIASES='
alias kiro="kiro-cli"
alias kiro-agent="kiro-cli --agent"
alias kiro-login="kiro-cli login --use-device-flow"
alias kiro-exec="kiro-cli --no-interactive"
alias crew="kirocrew"
alias crew-gw="kirocrew gateway"
alias crew-doctor="kirocrew doctor"
alias crew-setup="kirocrew setup"
'

PACK_BANNER_NAME="KiroCrew Agent Environment"
PACK_BANNER_EMOJI="🚀"
PACK_BANNER_COMMANDS='
  kirocrew gateway                 → Start crew gateway (http://localhost:${KIROCREW_PORT:-5476})
  kirocrew doctor                  → Verify setup (kiro-cli, auth, MCP, embeddings)
  kirocrew setup                   → Interactive config wizard
  kiro-cli                         → Kiro CLI (single agent, direct)
  kiro-cli --no-interactive "p"    → One-shot headless
'

# Source ~/.kiro/env for KIRO_API_KEY if present (same pattern as kiro-cli)
if [[ $- == *i* ]] && command -v kirocrew &>/dev/null; then
  if [[ -f "${HOME}/.kiro/env" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.kiro/env" 2>/dev/null || true
  elif [[ -z "${KIRO_API_KEY:-}" ]]; then
    printf '\n\033[0;33m⚠  KiroCrew: kiro-cli not authenticated. Run "kiro-cli login --use-device-flow" or configure headless mode.\033[0m\n\n'
  fi
fi
```

Profile installed to `/etc/profile.d/kirocrew.sh` (unique filename, no collision with kiro-cli pack).

---

## Registry Updates

Add to `packs/registry.yaml`:
```yaml
  kirocrew:
    type: agent
    description: "KiroCrew — multi-agent crew gateway on Kiro CLI (ACP) with dashboard and semantic memory"
    deps: []
```

Add to `packs/registry.json`:
```json
"kirocrew": {
  "type": "agent",
  "description": "KiroCrew — multi-agent crew gateway on Kiro CLI (ACP) with dashboard and semantic memory",
  "deps": []
}
```

---

## Top-level install.sh Updates

1. Add `kirocrew` to the pack name case statement (line ~553 area)
2. Add CLI flags: `--kirocrew-channel`, `--kirocrew-version`, `--kirocrew-extras`, `--start-gateway`
3. Add `pack_default_model` entry: `kirocrew) echo "kiro-cloud" ;;` (same as kiro-cli)
4. Add to help text / usage

---

## Web Gateway Access

KiroCrew's primary UI is a web dashboard. Users need browser access to `http://<host>:5476` to configure crews, view conversations, and manage agents.

### Exposure strategy (same pattern as loki-chat ALB):

| Layer | Config | Notes |
|-------|--------|-------|
| systemd | `kirocrew-gateway.service` binds `0.0.0.0:5476` | Local + ALB accessible |
| Security Group | Inbound TCP 5476 from ALB SG only | NOT open to internet |
| ALB | Target group `kirocrew-tg` on port 5476 | Health check: `GET /` or `GET /health` |
| CloudFront (optional) | Origin = ALB, HTTPS termination | Same pattern as admin-mc, loki-chat |
| firewalld | `firewall-cmd --add-port=5476/tcp --permanent` | Required for ALB health checks |

### Minimum viable (pack scope):
The pack itself handles:
1. systemd service running on port 5476
2. `firewall-cmd` to open the port (if firewalld is active)
3. Log the access URL in post-install notice

### Infrastructure (separate IaC, out of pack scope but documented):
- ALB target group + listener rule
- CloudFront distribution (HTTPS)
- Cognito auth (reuse `loki-agent` pool)
- DNS record

The pack's install.sh will:
```bash
# Open firewall port for ALB health checks (same pattern as loki-chat port 3102)
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
  sudo firewall-cmd --permanent --add-port="${GATEWAY_PORT}/tcp" 2>/dev/null || true
  sudo firewall-cmd --reload 2>/dev/null || true
fi
```

---

## CFN / deploy wiring

1. Add `KiroCrewChannel` parameter to CFN template (default: "stable")
2. Add `KiroCrewVersion` parameter (optional pin, default: "")
3. Add `KiroCrewExtras` parameter (default: "aws")
4. Add `StartKiroCrewGateway` parameter (default: "true")
5. Wire all through `bootstrap.sh` → PACK_CONFIG JSON

---

## test.sh Plan

Offline tests (no network, no sudo):

### Manifest validation
- manifest.yaml exists and is valid YAML
- All required keys present (name, version, type, description, deps, requirements, params, health_check, provides)
- Name is `kirocrew`, deps is `[]`
- All params have defaults
- `from-secret` param present (v2 auth)
- `channel` param present with valid default
- `extras` param present
- `start-gateway` param present with `true` default

### install.sh validation
- File exists and is executable
- bash syntax OK (`bash -n`)
- Uses `set -euo pipefail`
- Sources `common.sh`
- Calls `write_done_marker`
- `--help` exits 0
- `--model` accepted (doesn't exit 2) — **critical for bootstrap compat**
- `--model kiro-cloud` accepted silently
- Unknown flags → exit 2
- `--kiro-api-key` without value → exit 2
- `--kiro-api-key` with flag-like value → exit 2
- `--from-secret` with flag-like value → exit 2
- Mutex (`--kiro-api-key` + `--from-secret`) → exit 2
- `--channel` without value → exit 2
- `--channel` with valid value accepted

### Phase 1 feature signals
- References `KIRO_API_KEY`
- References `--from-secret`
- References `--no-interactive` in docs/notice
- Warns on kiro-cli v3+ (forward compat)
- Does NOT write KIRO_API_KEY to world-readable paths

### Phase 2 feature signals
- References `download.crew.kiro.dev/cli.sh`
- References `--channel` flag
- References Python ≥ 3.10 check
- References `kirocrew doctor`
- References `kirocrew setup` with TTY guard (`[[ -t 0 ]]`)
- References pipx

### Shell profile
- File exists at resources/shell-profile.sh
- Does NOT contain KIRO_API_KEY assignment
- References `kirocrew` command
- Filename installed as `kirocrew.sh` (not `kiro-cli.sh`)

### Systemd unit
- File exists at resources/kirocrew-gateway.service
- Contains `__PORT__` and `__HOME__` placeholders
- Has `User=ec2-user`
- Has security hardening (NoNewPrivileges, ProtectSystem)

### Registry consistency
- `kirocrew` in registry.yaml
- `kirocrew` in registry.json

### Deploy flow wiring
- Top-level install.sh has `kirocrew` case
- Top-level install.sh has `kirocrew` in `pack_default_model`
- bootstrap.sh accepts `--kirocrew-channel`
- CFN template has `KiroCrewChannel` parameter

### Extras handling
- install.sh references extras install logic
- Handles comma-separated list parsing
- Validates known extras (aws, voice) — warns on unknown but doesn't fail

---

## Security Considerations

- Same secure KIRO_API_KEY handling as kiro-cli (umask 077, %q escaping, 0600, no argv leak)
- KiroCrew upstream installer performs **two-layer verification**: RSA-SHA256 signature of the manifest (against embedded public key), then SHA-256 of the wheel against the signed manifest. No unsigned fallback exists.
- No additional secrets needed — KiroCrew reuses the same `KIRO_API_KEY` env var
- Channel validation: accept only `stable|nightly|insider` (matches upstream); reject with exit 2
- systemd unit: hardened with NoNewPrivileges, ProtectSystem=strict, ReadWritePaths scoped
- Shell profile at `/etc/profile.d/kirocrew.sh` is world-readable — must NEVER contain secrets
- `~/.kiro/crew/.env` (credentials file) inherits default umask; consider explicit chmod 600 in setup

---

## Resolved Review Findings

| ID | Finding | Resolution |
|----|---------|------------|
| V3-M1 | ReadWritePaths too narrow | Fixed: widened to `/home/ec2-user/.kiro` + `~/.local` (kiro-cli subprocesses write to ~/.kiro/settings, ~/.kiro/agents) |
| V3-M2 | Venv path contradicts docs | Verified: actual installer uses `~/.kiro/crew-venv` (beside data home). Docs say `~/.kiro/crew/venv` but installer code uses `${KIROCREW_HOME}-venv`. Plan is correct. |
| V3-L1 | ExecStart hardcodes binary path | Fixed: uses `__BINPATH__` placeholder, resolved via `command -v kirocrew` at install time |
| V3-L2 | Step 10 extras path | Fixed: will use resolved path (same as V3-L1 logic) |
| V3-N1 | pipx inject vs extras syntax | Noted: implementer maps extras→packages (voice→boto3,amazon-transcribe; aws→boto3) |
| H1 | AL2023 Python version claim | Fixed: AL2023 current AMIs ship 3.11+; script checks available interpreters newest-first |
| H2 | Installer URL resilience | Added: clear fail message with actionable hints (DNS/proxy/firewall) |
| H3 | Missing --model flag | Fixed: arg parser accepts `--model` and ignores with informational log |
| H4 | Venv path wrong | Fixed: `~/.kiro/crew-venv` (beside data home, not inside — matches upstream) |
| H5 | Security wording | Fixed: documented two-layer verification (RSA sig + SHA-256 checksum) |
| H6 | `kirocrew setup` interactive | Fixed: TTY-gated with `[[ -t 0 ]]`; logs instruction when non-interactive |
| H7 | systemd unit not defined | Fixed: added unit template + `start-gateway` defaults to `true` (gateway is the point) |
| M1 | --model handler | Same as H3 |
| M2 | Health check all-or-nothing | Fixed: health_check only tests binary presence, not gateway/embeddings |
| M3 | extras pip step | Fixed: added Step 10 with pipx inject / venv pip install |
| M4 | Embedding model timing | Fixed: explicitly noted as background download, not install-time |
| M5 | Channel persistence | Confirmed: handled by upstream installer (writes `~/.kiro/crew/channel`) |
| L1 | Shell profile port hardcode | Fixed: uses `${KIROCREW_PORT:-5476}` in banner |
| L2 | KIROCREW_HOME not parameterized | Fixed: added `kirocrew-home` param |
| L3 | test.sh extras validation | Fixed: added extras handling test cases |

---

## Resolved Architectural Decisions

- **kiro-cli + Bedrock**: Phase 1 wires KIRO_API_KEY + MCP proxy. By the time Phase 2 runs, kiro-cli "just works" — KiroCrew drives it over ACP automatically.
- **Web access**: Gateway runs as systemd service, firewall port opened. Direct access via `http://<instance-ip>:5476` for now — no ALB/CloudFront (deferred).
- **start-gateway = true**: The web gateway IS the product. No point installing KiroCrew without running it.
- **Channel**: `stable` (confirmed).
- **Extras**: `aws,voice` (both, confirmed).
- **Embedding preload**: YES — download during install (adds 1-3 min). Users get full vector search immediately on first gateway start. No keyword-matching degradation period. (Confirmed by Roy 2026-08-05.)
- **ALB/CloudFront**: Not for now. Direct IP access.

## Open Questions / Decisions Needed

_All major questions resolved. Ready for implementation._

1. ~~Channel: `stable` or `nightly`?~~ → **`stable`** ✅
2. ~~Pip extras: just `aws` or also `voice`?~~ → **`aws,voice`** ✅
3. ~~Embedding preload?~~ → **Yes, preload** ✅
4. ~~ALB/CloudFront?~~ → **Not for now** (direct IP access) ✅
5. **Troika integration**: Deferred — separate PR

---

## Implementation Order

1. Create `packs/kirocrew/manifest.yaml`
2. Create `packs/kirocrew/resources/shell-profile.sh`
3. Create `packs/kirocrew/resources/kirocrew-gateway.service`
4. Create `packs/kirocrew/install.sh` (Phase 1 + Phase 2)
5. Create `packs/kirocrew/test.sh`
6. Update `packs/registry.yaml` and `packs/registry.json`
7. Update top-level `install.sh` (pack dispatch, model, CLI flags)
8. Update `deploy/bootstrap.sh` (new flags)
9. Update `deploy/cloudformation/template.yaml` (new params)
10. Run `packs/kirocrew/test.sh` to validate
11. PR + code review
