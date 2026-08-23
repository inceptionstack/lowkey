# Kiro CLI Headless API Key — Interactive Install Preference

> **Superseded in part by PR #99.** The skip-on-empty-input behaviour described in
> R3 and shown in the code snippets below was removed: the Kiro API key is now a
> required field once the prompt is reached, validated over up to 5 attempts, with
> no "press Enter to skip" escape. See `install.sh` for the implemented flow. The
> snippets here are retained as the original design record, not as current code.

## Overview

When a user interactively selects the **kiro-cli** pack during `install.sh`, the installer
should prompt them to create and paste a Kiro API key. This enables headless mode
(no browser login required) out of the box, matching the pattern already used by the
roundhouse pack for Telegram bot tokens.

## Background

- **Headless mode docs:** https://kiro.dev/blog/introducing-headless-mode/
- **Key creation URL:** https://app.kiro.dev/settings/api-keys
  - Note: user's organization must have API keys enabled
- **How it works:** When the `KIRO_API_KEY` environment variable is set, Kiro CLI
  skips the browser-based login flow entirely. That single env var is the difference
  between interactive and headless mode.
- **Current state:** The pack already supports `--from-secret` and `--kiro-api-key`
  CLI flags, plus `pack_config_get` for JSON config. What's missing is the
  **interactive prompt** during the install wizard.

## Existing Patterns (roundhouse pack precedent)

In `install.sh` (line ~2970+), after `build_deploy_params`, pack-specific prompts run:

```bash
if [[ "${PACK_NAME:-}" == "roundhouse" ]]; then
  if [[ -z "${TELEGRAM_BOT_TOKEN_SECRET:-}" ]]; then
    # ... prompts user for Telegram bot token
    # ... validates format
    # ... stores in Secrets Manager as /lowkey/${ENV_NAME}/telegram-bot-token
    # ... sets TELEGRAM_BOT_TOKEN_SECRET to point at the new secret
  fi
fi
```

We will follow this exact pattern for kiro-cli.

## Requirements

### R1: Interactive API Key Prompt

After pack selection resolves to `kiro-cli` and `build_deploy_params` completes:

1. **Skip if already configured** — if `KIRO_FROM_SECRET` is already set (via
   `--kiro-from-secret` CLI flag), skip the prompt entirely.
2. **Display guidance** — show the user:
   - What headless mode is (one sentence)
   - URL to create an API key: `https://app.kiro.dev/settings/api-keys`
   - Note that their org must have API keys enabled
3. **Prompt for key** — use `prompt_secret` (existing helper, masks input) to
   collect the API key. Allow empty (user can skip → falls back to interactive
   browser auth post-install).
4. **Validate format** — Kiro API keys follow the pattern `ksk_<base62>` (e.g.
   `ksk_gqxMn1sVz6E4n7NVLOru3Leu7Ys4jPsP`). Validate:
   - Must start with `ksk_`
   - Total length ~35 chars (check ≥30, ≤100 to allow for future growth)
   - Remainder after prefix: alphanumeric only (`[A-Za-z0-9]`)
5. **Store in Secrets Manager** — write the key to
   `/lowkey/${ENV_NAME}/kiro-api-key` (same pattern as roundhouse's bot token).
   - Encrypted at rest (default KMS key)
   - Tags: `loki:managed=true`, `loki:pack=kiro-cli`, `loki:env=${ENV_NAME}`
6. **Set KIRO_FROM_SECRET** — point the deploy param at the new secret so the
   pack's `install.sh` resolves it on the instance via `--from-secret`.
7. **Update PARAM_VALUES** — splice the secret reference into the correct index
   (index 17, currently `"${KIRO_FROM_SECRET:-}"`).

### R2: Non-Interactive Mode (no change needed)

When `-y` / `--non-interactive` is used:
- If `--kiro-from-secret` was passed, use it (existing behavior).
- If not, skip the prompt — pack installs in interactive-auth mode (existing behavior).
\nNo new behavior needed here; just ensure the new prompt block is gated on
`[[ "$AUTO_YES" != true ]]`.

### R3: Skip Option — WITHDRAWN (PR #99)

~~If the user presses Enter without pasting a key (empty input), the installer should:~~
~~Log: `"Skipping API key — you can authenticate later with: kiro-cli login --use-device-flow"`~~
~~Continue deployment without headless mode (existing behavior).~~

PR #99 removed this requirement. The key is required once the prompt is reached;
blank input is rejected with "API key is required and cannot be blank" and costs one
of 5 attempts. Only exhausting all 5 attempts falls through without a key, which
exists to avoid bricking a broken session rather than as a user-facing opt-out.

### R4: manifest.yaml Update

Add a new param to `packs/kiro-cli/manifest.yaml`:

```yaml
params:
  - name: api-key-secret
    description: "Secrets Manager secret id/arn for headless API key (auto-created during interactive install)"
    default: ""
```

This documents the param in the pack's contract even though `from-secret` already
exists (the new param name aligns with the interactive flow naming).

Actually — keep using the existing `from-secret` param. No manifest change needed.
The existing param already covers this. The only change is that the **main installer**
now auto-creates the secret and passes it.

## Files to Change

| File | Change |
|------|--------|
| `install.sh` | Add kiro-cli pack-specific prompt block (~10 lines) after the roundhouse block |
| `packs/kiro-cli/install.sh` | No changes needed (already handles `--from-secret`) |
| `packs/kiro-cli/manifest.yaml` | No changes needed |

## Implementation Detail

### install.sh addition (after roundhouse block, ~line 3020)

```bash
# ── kiro-cli: interactive API key for headless mode ──
if [[ "${PACK_NAME:-}" == "kiro-cli" ]]; then
  if [[ -z "${KIRO_FROM_SECRET:-}" && "$AUTO_YES" != true ]]; then
    echo ""
    echo -e "  ${BOLD}Kiro CLI supports headless mode (no browser login).${NC}"
    echo -e "  Create an API key at: ${CYAN}https://app.kiro.dev/settings/api-keys${NC}"
    echo -e "  (Your organization must have API keys enabled.)"
    echo ""
    echo -e "  Press Enter to skip (you can authenticate via browser later)."
    echo ""
    local _KIRO_API_KEY=""
    prompt_secret "Kiro API key" _KIRO_API_KEY ""
    if [[ -n "$_KIRO_API_KEY" ]]; then
      # Validate format: ksk_<alphanumeric>, ~35 chars
      if [[ ! "$_KIRO_API_KEY" =~ ^ksk_[A-Za-z0-9]{26,96}$ ]]; then
        warn "API key doesn't match expected format (ksk_...). Skipping — authenticate manually after install."
      else
        # Store in Secrets Manager
        local _KIRO_SECRET_NAME="/lowkey/${ENV_NAME}/kiro-api-key"
        KIRO_FROM_SECRET="$_KIRO_SECRET_NAME"
        # Update PARAM_VALUES[17] (KiroFromSecret index)
        PARAM_VALUES[17]="$KIRO_FROM_SECRET"
        ok "API key will be stored in Secrets Manager: ${_KIRO_SECRET_NAME}"
      fi
    else
      info "Skipping API key — authenticate after install with: kiro-cli login --use-device-flow"
    fi
  fi
fi
```

### Secret creation (deferred to deploy phase)

Like the roundhouse pattern, actual `aws secretsmanager create-secret` is called
in the deploy execution section (after user confirms the summary). This avoids
creating orphan secrets if the user aborts. Pattern:

```bash
# In the deploy section, before CFN create-stack:
if [[ -n "${KIRO_FROM_SECRET:-}" && -n "${_KIRO_API_KEY:-}" ]]; then
  aws secretsmanager create-secret \
    --name "${KIRO_FROM_SECRET}" \
    --secret-string "${_KIRO_API_KEY}" \
    --description "Kiro CLI API key for headless mode (lowkey ${ENV_NAME})" \
    --tags Key=loki:managed,Value=true Key=loki:pack,Value=kiro-cli Key=loki:env,Value="${ENV_NAME}" \
    --region "${DEPLOY_REGION}" >/dev/null 2>&1 \
  && ok "Kiro API key stored: ${KIRO_FROM_SECRET}" \
  || warn "Failed to store Kiro API key in Secrets Manager — headless mode may not work"
fi
```

## Security Considerations

- API key is collected via `prompt_secret` (input masked, no echo)
- Key is never logged or written to disk on the installer machine
- Stored in Secrets Manager (encrypted at rest, IAM-gated access)
- Only the secret *reference* (path) enters CloudFormation parameters
- Instance resolves the actual key at boot via its IAM role
- If user aborts install, no secret is created (deferred write pattern)

## Testing

1. **Interactive install, paste key:** Verify secret created, pack installs in headless mode
2. **Interactive install, skip (empty):** Verify graceful skip, pack installs in interactive mode
3. **Non-interactive (`-y`):** Verify no prompt, existing `--kiro-from-secret` still works
4. **Invalid key (too short):** Verify warning + graceful skip
5. **kirocrew pack:** Out of scope (separate branch)

## Branch

`feat/kiro-cli-headless-apikey` (derived from `main`)
