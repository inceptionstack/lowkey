# KiroCrew: Add Kiro CLI API Key Prompt (Port from main)

> **Superseded in part by PR #99.** The `"Press Enter to skip"` line in the snippet
> below, and the skip-on-empty-input branch it describes, were removed: the Kiro API
> key and the Telegram bot token / user ID are now required fields once their prompt
> is reached. See `install.sh` for the implemented flow. The snippets here are the
> original design record, not current code.

## Overview

Port the interactive Kiro API key prompt (already on `main` for the `kiro-cli` pack) into the `feat/kirocrew-pack` branch so that kirocrew users also get headless mode configured during install.

## What Already Exists on This Branch

- `--kiro-from-secret` CLI flag in install.sh (line 697–705) ✓
- `KiroFromSecret` in PARAM_CFN_NAMES (index 17) ✓
- `packs/kirocrew/manifest.yaml` has `from-secret` param ✓
- `packs/kirocrew/install.sh` — likely delegates to kiro-cli install or has its own `--from-secret` handling

## What's Missing

The interactive prompt block and deferred secret creation that were added to `main`. On `main`, the condition is:
```bash
if [[ "${PACK_NAME:-}" == "kiro-cli" ]]; then
```

On this branch, it needs to also match `kirocrew`:
```bash
if [[ "${PACK_NAME:-}" == "kiro-cli" || "${PACK_NAME:-}" == "kirocrew" ]]; then
```

## Changes Required

### 1. install.sh — Interactive prompt block (insert after roundhouse `build_deploy_params`, before troika block)

**Location:** After line 3007 (`build_deploy_params` at end of roundhouse block), before line 3010 (troika block).

```bash
  # Pack-specific: kiro-cli/kirocrew interactive API key for headless mode
  if [[ "${PACK_NAME:-}" == "kiro-cli" || "${PACK_NAME:-}" == "kirocrew" ]]; then
    if [[ -z "${KIRO_FROM_SECRET:-}" && "$AUTO_YES" != true ]]; then
      echo ""
      echo -e "  ${BOLD}Kiro CLI supports headless mode (no browser login).${NC}"
      echo -e "  Create an API key at: ${CYAN}https://app.kiro.dev/settings/api-keys${NC}"
      echo -e "  (Your organization must have API keys enabled.)"
      echo ""
      echo -e "  Press Enter to skip (you can authenticate via browser later)."
      echo ""
      _KIRO_API_KEY=""
      prompt_secret "Kiro API key" _KIRO_API_KEY ""
      if [[ -n "$_KIRO_API_KEY" ]]; then
        # Validate format: ksk_<alphanumeric>, ~35 chars
        if [[ ! "$_KIRO_API_KEY" =~ ^ksk_[A-Za-z0-9]{26,96}$ ]]; then
          warn "API key doesn't match expected format (ksk_...). Skipping — authenticate manually after install."
          _KIRO_API_KEY=""
        else
          # Secret name determined now; actual write deferred until after user confirms
          _KIRO_SECRET_NAME="/lowkey/${ENV_NAME}/kiro-api-key"
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

### 2. install.sh — Deferred secret creation (insert after roundhouse secret block, ~line 3131)

```bash
  # Kiro CLI: save API key to Secrets Manager (deferred until after user confirmation)
  if [[ -n "${_KIRO_API_KEY:-}" && -n "${_KIRO_SECRET_NAME:-}" ]]; then
    info "Storing Kiro API key in Secrets Manager: ${_KIRO_SECRET_NAME}"
    local kiro_key_file
    kiro_key_file=$(mktemp /tmp/lowkey-kiro-key.XXXXXX)
    chmod 600 "$kiro_key_file"
    printf '%s' "$_KIRO_API_KEY" > "$kiro_key_file"
    aws secretsmanager restore-secret --secret-id "$_KIRO_SECRET_NAME" --region "$DEPLOY_REGION" >/dev/null 2>&1 || true
    local kiro_sm_err=""
    if kiro_sm_err=$(aws secretsmanager create-secret \
      --name "$_KIRO_SECRET_NAME" \
      --secret-string "file://${kiro_key_file}" \
      --description "Kiro CLI API key for headless mode (${ENV_NAME})" \
      --tags Key=loki:managed,Value=true Key=loki:pack,Value=kiro-cli Key=loki:env,Value="${ENV_NAME}" \
      --region "$DEPLOY_REGION" 2>&1); then
      ok "Kiro API key saved to Secrets Manager"
    elif kiro_sm_err=$(aws secretsmanager put-secret-value \
      --secret-id "$_KIRO_SECRET_NAME" \
      --secret-string "file://${kiro_key_file}" \
      --region "$DEPLOY_REGION" 2>&1); then
      ok "Kiro API key updated in Secrets Manager"
    else
      rm -f "$kiro_key_file"
      fail "Failed to save Kiro API key to Secrets Manager: ${kiro_sm_err}"
    fi
    rm -f "$kiro_key_file"
    unset _KIRO_API_KEY
  fi
```

### 3. No pack-level changes

`packs/kirocrew/install.sh` presumably delegates to kiro-cli's install or has its own `--from-secret` handling. Verify it passes `KIRO_FROM_SECRET` through — if it already does (matching kiro-cli pack pattern), no changes needed.

## Key Differences from main Branch Port

| Aspect | main | kirocrew branch |
|--------|------|-----------------|
| Condition | `== "kiro-cli"` only | `== "kiro-cli" \|\| == "kirocrew"` |
| Variable scoping | No `local` on `_KIRO_API_KEY` | Same (no `local`) |
| Everything else | Identical | Identical |

## Testing

1. `bash install.sh --test --debug-in-repo --pack kirocrew --profile builder -y` — non-interactive, should skip prompt
2. Interactive run (no `-y`) — should show API key prompt when selecting kirocrew
3. `--kiro-from-secret /some/secret` — should skip prompt (already configured)

## Notes

- `_KIRO_API_KEY` must NOT be `local` — it's set in `run_config_and_review()` but consumed in the deploy section (different scope). Same bug was caught and fixed on main.
- Deferred write pattern ensures no orphan secrets if user aborts before deploy.
