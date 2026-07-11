# Design: AWS Account Rename During Lowkey Install

## Goal

During Lowkey installation, rename the AWS account to `Loki-<original-name>` so users can easily identify which AWS accounts have Lowkey deployed. This helps when switching between accounts in the AWS console.

We use `Loki-` (the internal project name) as the prefix, not `Lowkey-`, for
consistency with existing internal resource naming (SSM paths `/loki/*`, VPC
tags `loki:managed`, repo `loki-agent`, etc.).

## AWS API

- **Read**: `aws account get-account-information` → returns `AccountName`, `AccountId`, `AccountCreatedDate`
- **Write**: `aws account put-account-name --account-name "Loki-MyAccount"`
- Account name: 1–50 chars, printable ASCII (AWS allows `[ -;=?-~]+`)
- **We restrict to a safe subset** (`SAFE_NAME_PATTERN`): alphanumeric,
  space, hyphen, underscore, dot, plus, equals, at, colon, semicolon,
  comma, exclamation, question, hash, parens, brackets, braces, tilde,
  caret, slash.
  Explicitly **excluded**: `$`, `` ` ``, `"`, `\`, `&`, `|`, `*`, `'`, `%`
  (shell metacharacters, format-string hazards, or problematic in logging/quoting)
- Always use `printf '%s'` (not `printf "$var"`) when logging account names
  (`%` is excluded from SAFE_NAME_PATTERN but defense-in-depth applies)
- No global uniqueness constraint
- Requires `account:GetAccountInformation` and `account:PutAccountName` permissions
- These are **not** added to `check_permissions()` (which checks CFN/IAM/EC2 only)
  since the rename is non-fatal on AccessDenied. Worth adding in a future iteration
  for earlier user feedback.
- Changes can take up to 4 hours to propagate across AWS consoles
- `aws account` subcommand requires AWS CLI v2.8+ (2022)

## Behavior Summary

| Mode | Default behavior | Override |
|------|-----------------|----------|
| **Interactive** | Prompt user: Rename / Edit / Skip (default: Rename) | `--disable-account-rename` skips prompt entirely |
| **Headless (`-y`)** | Skip rename (safe default for CI) | `--auto-rename-account-enabled` to opt in |

Rationale: `-y` means "accept installer defaults and deploy" — silently mutating
the org-visible account name would be a surprising side effect for existing CI
pipelines. Headless rename requires explicit opt-in.

The rename is always **non-fatal** — API failures warn and continue.

**Telemetry safety rule:** The installer runs under `set -euo pipefail`.
All telemetry calls inside `maybe_rename_account()` MUST be guarded with
`2>/dev/null || true` to ensure a telemetry failure can never abort the
install. This matches the existing pattern used by all `_telem_*` calls
in `main()`. Example:
```bash
_telem_event "install.account_renamed" "$props" 2>/dev/null || true
```

## Current Installer Flow (preflight_checks)

```
1. verify_aws_credentials()     → sets ACCOUNT_ID, CALLER_ARN
2. Display Account/Region/Branch info
3. Warn about AdministratorAccess
4. confirm "Deploy to account?"
5. check_permissions
```

## Proposed Flow

Call `maybe_rename_account()` from `main()`, **after** `preflight_checks()`
and **before** the config wizard (`run_config_and_review()`). Account rename
is an account-level operation, not a deployment-level one, so it should
happen before the user configures packs, profiles, and deploy settings.

SSM writes inside the rename helpers use `${DEPLOY_REGION:-$REGION}` to
fall back to the preflight-detected `$REGION` when `$DEPLOY_REGION` hasn't
been set yet by the config wizard.

```
choose_install_mode()          ← simple or advanced (needed before preflight)
preflight_checks()
  → verify_aws_credentials()
  → Display Account/Region/Branch info
  → if normal mode: warn + confirm + check_permissions
  → else (simple): ok "Using current account and region"
**maybe_rename_account()**     ← account-level, before config wizard
run_config_and_review()       → config wizard + show_summary + deploy confirm
deploy()                      → including console-deploy early-exit path
```

Note: `maybe_rename_account()` must be placed **before** the console-deploy
early-exit (`DEPLOY_CFN_CONSOLE` path calls `exit 0` right after deploy).
All deploy paths — CFN console, CFN CLI — get the rename.

## maybe_rename_account() Logic

**Safety invariant:** Nothing in this function may abort the install.
All AWS API calls (`aws account`, `aws ssm`) and all telemetry calls
must be guarded with `2>/dev/null || true` or wrapped in `if` blocks.
The function itself is called from `main()` as:
```bash
maybe_rename_account || true
```
Note: no outer `2>/dev/null` — gum renders its interactive UI on stderr,
so suppressing stderr would hide the rename prompt.

### Helper: `_emit_rename_telemetry`

Single point for all rename telemetry. Called at every exit path.
```bash
_emit_rename_telemetry() {
  # Usage: _emit_rename_telemetry <renamed> <allowed> [skipped_reason]
  local renamed="${1:-false}"
  local allowed="${2:-false}"
  local skipped_reason="${3:-}"
  # Defensive: coerce to JSON booleans
  [[ "$renamed" == "true" ]] || renamed="false"
  [[ "$allowed" == "true" ]] || allowed="false"
  local props
  props=$(printf '{"renamed":%s,"allowed":%s,"auto_rename_enabled":%s' \
    "$renamed" "$allowed" "$AUTO_RENAME_ACCOUNT")
  if [[ -n "$skipped_reason" ]]; then
    props+=$(printf ',"skipped_reason":"%s"' "$skipped_reason")
  fi
  props+='}'
  _telem_event "install.account_renamed" "$props" 2>/dev/null || true
}
```

### Steps

```
1. If --disable-account-rename flag is set:
   → info "Account rename disabled via --disable-account-rename"
   → _emit_rename_telemetry false false "disabled_flag"
   → return

2. current_name = aws account get-account-information → .AccountName
   (CLI version ≥ 2.8 enforced by preflight `ensure_aws_cli_current`)
   → If fails: warn "Could not read account name"
   → _emit_rename_telemetry false false "api_error"
   → return

3. If current_name already starts with "Loki-" (case-insensitive via
   lowercase comparison, e.g. `tr '[:upper:]' '[:lower:]'` starts with "loki-"):
   → ok (using printf '%s' with tr -d '\000-\037'): "Account already named for Loki: <current_name>"
   → If SSM param `/loki/original-account-name` doesn't exist yet:
     → Strip "Loki-" prefix (case-insensitive) to get the original name
     → If stripped result is empty, use "<account_id>" as fallback
     → Store stripped name as `/loki/original-account-name`
     → Store current name as-is as `/loki/installed-account-name`
     This preserves restore capability for first-time installs.
     On re-installs where SSM already exists, skip SSM writes (no-op).
   → _emit_rename_telemetry false false "already_prefixed"
   → return (skip — do not re-sanitize or modify existing Loki-prefixed names,
     even if they contain characters outside SAFE_NAME_PATTERN)

4. proposed = "Loki-" + sanitize(current_name)
   → Sanitize the original name FIRST (against `SAFE_NAME_PATTERN`),
     then prepend "Loki-" to avoid corrupting the prefix
   → If current_name is empty: proposed = "Loki-<account_id>"
     (always 17 chars for 12-digit account IDs — well within 50-char limit)

5. If sanitized name is empty after stripping: fallback to "Loki-<account_id>"

6. If proposed > 50 chars: truncate to 50 chars
   (Sanitization in step 5 guarantees ASCII-only, so no multi-byte split risk)
   → Strip trailing hyphens or spaces from the truncated result
   → If result length < 6 (i.e., no meaningful suffix after "Loki-"): fallback to "Loki-<account_id>"

7. If --non-interactive / -y (headless):
   → If --auto-rename-account-enabled is NOT set:
     → info "Headless mode: account rename skipped (pass --auto-rename-account-enabled to enable)"
     → _emit_rename_telemetry false false "headless_no_opt_in"
     → return
   → Auto-apply proposed name (no prompt)
   → If name was truncated in step 6: warn "Account name truncated to 50 chars: <proposed>"
   → Jump to step 11 (pass final name to AWS CLI)

8. If name was truncated in step 6: info "Name truncated to 50 chars"

9. Show current name, proposed name, and explain:
   "This name appears in the AWS console account switcher and billing."

10. Prompt with gum choose: "Rename to <proposed>" / "Edit name" / "Skip"
    → Rename: use proposed name
    → Edit: prompt for custom name, validate against `SAFE_NAME_PATTERN`,
      1–50 char length, and non-empty/non-whitespace. Loop if invalid. The "Loki-" prefix is NOT enforced —
      user may choose any valid name (e.g., for org naming conventions).
      The prompt pre-fills with the proposed name for convenience.
    → Skip: info "Keeping account name: <current_name>"
     → _emit_rename_telemetry false false "user_declined"
     → return

11. Pass final name to AWS CLI using double-quoted variable: --account-name "$final_name"
    (No printf '%q' escaping — double-quoting is correct and sufficient;
    dangerous characters like $, ", `, \ are excluded by the validation pattern)

12. aws account put-account-name --account-name "$final_name"
    → On 429 (TooManyRequestsException): retry once after 2s sleep
    → On success:
      → ok (using printf '%s' for safety): "Account renamed to <final_name>"
      → info "May take up to 4 hours to appear everywhere in AWS console"
      → _emit_rename_telemetry true true
      → Store original name in SSM: /loki/original-account-name
      → Store installed name in SSM: /loki/installed-account-name
      → SSM writes are non-fatal: if they fail, warn and continue
        (uninstall falls back to prefix-stripping)
    → On failure (AccessDenied, SCP block, throttle, etc):
      → warn "Could not rename account: <error>. Deployment will continue."
      → _emit_rename_telemetry false true "api_error"
      → return (non-fatal)
```

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Already starts with "Loki-" / "loki-" | Skip with ok message |
| Name + "Loki-" prefix > 50 chars | Truncate to 50; offer Edit in interactive, auto-apply in headless |
| `--non-interactive` / `-y` mode | Skip rename (safe default) |
| `-y` + `--auto-rename-account-enabled` | Auto-rename |
| `-y` + `--disable-account-rename` | Skip rename entirely (redundant but explicit) |
| `--test` mode | Not applicable — installer exits before rename is reached |
| API call fails (permissions/SCP) | warn + continue — non-fatal |
| `get-account-information` fails | warn + skip |
| `aws account` command missing | Handled by preflight `ensure_aws_cli_current` (auto-updates CLI) |
| Empty account name from API | Fallback to "Loki-<account-id>" |
| Name contains non-ASCII chars | Strip to printable ASCII before prefixing |
| User input via Edit exceeds 50 chars | Reject and re-prompt |
| Organizations member account + SCP blocking | AccessDenied → warn + continue |
| Existing variants: "Lowkey-*", "Loki " (space) | Not recognized — only "Loki-" (with hyphen) is detected, case-insensitively |
| Concurrent installs on same account | Last writer wins for both account name and SSM state; second install's original-name SSM value overwrites first's. Cross-region dual-deploys store SSM in different regional stores — uninstaller may find wrong region's state (documented known gap) |
| TooManyRequestsException (429) | Retry once after 2s, then warn + continue |

## CLI Flags

Add to installer:
- `--auto-rename-account-enabled` — Enable auto-rename in headless (`-y`) mode
- `--disable-account-rename` — Skip account rename entirely (suppresses interactive prompt too)

Parsing: add to the existing `while [[ $# -gt 0 ]]` / `case` block:
```bash
AUTO_RENAME_ACCOUNT=false
DISABLE_ACCOUNT_RENAME=false
# ...
--auto-rename-account-enabled) AUTO_RENAME_ACCOUNT=true; shift ;;
--disable-account-rename)      DISABLE_ACCOUNT_RENAME=true; shift ;;
```

## Uninstall Approach (Hybrid)

During install, store state in SSM Parameter Store (using `${DEPLOY_REGION:-$REGION}`
to support the call site before the config wizard sets `$DEPLOY_REGION`):
```bash
aws ssm put-parameter --name "/loki/original-account-name" \
  --value "$current_name" --type String --overwrite --region "${DEPLOY_REGION:-$REGION}"
aws ssm put-parameter --name "/loki/installed-account-name" \
  --value "$final_name" --type String --overwrite --region "${DEPLOY_REGION:-$REGION}"
```

During uninstall (`maybe_restore_account_name()`):

The uninstaller must locate the SSM parameters in the correct region. Strategy:
1. Try `SCAN_REGION` (user-provided uninstall region) first
2. If not found, try the default configured region (`aws configure get region`);
   if no default region is configured, skip this step
3. If still not found, fall through to heuristic fallback (step 5)

Known limitation: if the user deployed to a non-default region and uninstalls
from a different region, SSM parameters won't be found and may restore the
wrong original name. The heuristic fallback handles this gracefully. A future improvement could tag the Loki VPC with the
SSM region for cross-region discovery.

Headless uninstall behavior: never auto-restore. Restoring the account name
requires interactive confirmation. If a headless `--non-interactive` flag is
added to the uninstaller in the future, account name restore should be skipped
unless an explicit `--restore-account-name` flag is passed.

1. Read `/loki/installed-account-name` from SSM (trying regions as above)
2. Read current account name via `get-account-information`
3. If current name equals the installed name (hasn't been manually changed):
   → Read `/loki/original-account-name` from SSM
   → The stored original is NOT re-validated against SAFE_NAME_PATTERN.
     It came from the AWS API, so it's already a valid AWS account name.
     Re-validating could reject a legitimate restore.
   → Offer to restore: "Restore account name from '<installed>' to '<original>'?"
4. If current name differs from installed name:
   → info "Account name was changed after install, skipping restore"
5. If SSM parameters don't exist (fallback):
   → If current name starts with "Loki-" (case-insensitive, same as install step 4):
     → Propose stripping prefix to get the approximate original name
     → Note: this is a heuristic — the stripped result may differ from the
       true original if the installer sanitized the name during install
     → Offer to restore, but never auto-restore
     → Note: this heuristic may match names not set by this installer —
       that's acceptable since it only offers, never auto-applies
6. Clean up SSM parameters only after a **successful restore**, not after skip.
   If the user declines, SSM parameters are preserved for future uninstall attempts.

## Security Notes

- All user input and generated names are validated against `SAFE_NAME_PATTERN`,
  a strict subset of AWS's `[ -;=?-~]+` that excludes shell metacharacters
  and characters problematic in logging/URL/quoting contexts:
  `$`, `` ` ``, `"`, `\`, `&`, `|`, `*`, `'`, `%`
- Double-quote variables in AWS CLI invocations: `--account-name "$final_name"`
- Never use `eval` with user-provided names
- Use `printf '%s'` for all display of account names (defense-in-depth)
- Use `tr -d '\000-\037'` to strip control characters before printing names
- **Uninstall exception**: The restore path passes the SSM-stored original name
  to `put-account-name` WITHOUT re-validating against SAFE_NAME_PATTERN.
  This is safe because: (a) the value came from the AWS API originally,
  (b) it's passed via double-quoted `"$var"` with no `eval`, and
  (c) re-validating could reject a legitimate restore.
- The rename is purely cosmetic — no security implications for the deployment

## Telemetry

### Install Beacon: `account_rename_enabled` field

Add `account_rename_enabled` (boolean) to the `/v1/install` beacon payload,
alongside `is_test`. This surfaces the flag on every install beacon so
dashboards can filter/segment without waiting for the event batch.

**Installer change** (`_telem_send_install_beacon` in install.sh):
```bash
# Add to the JSON body, after is_test:
,"account_rename_enabled":${AUTO_RENAME_ACCOUNT:-false}
```

**Backend change** (`lambda-shared/validate.py` → `validate_install()`):
```python
# In the output dict construction, after "outcome":
if isinstance(env.get("account_rename_enabled"), bool):
    out["account_rename_enabled"] = env["account_rename_enabled"]
```

**Backend change** (`lambda-install/handler.py`):
```python
# Add to the row dict written to Firehose, after "outcome":
"account_rename_enabled": env.get("account_rename_enabled"),

# Add to notify_payload:
notify_payload["account_rename_enabled"] = env.get("account_rename_enabled", False)
```

### Event: `install.account_renamed`

Emitted via the `/v1/ingest` batch path (queued by `_telem_event` in
installer, flushed by `_telem_flush` at install end).

Props:
- `renamed`: boolean — did the rename actually happen?
- `allowed`: boolean — did the user allow the rename?
  - Interactive: true if user chose "Rename" or "Edit", false if "Skip"
  - Headless: true if `--auto-rename-account-enabled` was passed
  - false for all other skip paths (disabled_flag, api_error, already_prefixed)
- `auto_rename_enabled`: boolean — was `--auto-rename-account-enabled` passed?
- `skipped_reason`: one of (only when renamed=false):
  - `"already_prefixed"` — account already starts with "Loki-"
  - `"user_declined"` — user chose "Skip" in interactive prompt
  - `"disabled_flag"` — `--disable-account-rename` was passed
  - `"headless_no_opt_in"` — headless mode without `--auto-rename-account-enabled`
  - `"api_error"` — AWS API call failed

### Backend Changes Required (loki-dashboard)

The `install.account_renamed` event must be registered in the telemetry
backend before the installer starts emitting it. Changes needed in
`inceptionstack/loki-dashboard` → `infra/loki-telemetry/`:

**1. `lambda-shared/validate.py` — EVENT_CATALOG + prop validators:**

(This is the canonical source; `build-lambdas.sh` copies it to
`lambda-ingest/_shared/` and `lambda-install/_shared/`.)
```python
# Add to EVENT_CATALOG:
"install.account_renamed": {"renamed", "allowed", "auto_rename_enabled", "skipped_reason"},

# Add allowed skipped_reason values:
ALLOWED_ACCOUNT_RENAME_SKIP = {
    "already_prefixed", "user_declined", "disabled_flag",
    "headless_no_opt_in", "api_error",
}

# Add to _PROP_VALIDATORS:
("install.account_renamed", "renamed"):             lambda v: isinstance(v, bool),
("install.account_renamed", "allowed"):              lambda v: isinstance(v, bool),
("install.account_renamed", "auto_rename_enabled"): lambda v: isinstance(v, bool),
("install.account_renamed", "skipped_reason"):      "account_rename_skip",

# Add to _scrub_prop:
if validator == "account_rename_skip":
    return value if value in ALLOWED_ACCOUNT_RENAME_SKIP else None
```

**2. `lambda-ingest/handler.py` — Telegram notification enrichment:**
```python
# Add alongside existing install.* notification handling:
elif name == "install.account_renamed":
    notify_payload["account_renamed"] = p.get("renamed", False)
    notify_payload["account_rename_allowed"] = p.get("allowed", False)
    if p.get("skipped_reason"):
        notify_payload["rename_skip_reason"] = p["skipped_reason"]
    if p.get("auto_rename_enabled"):
        notify_payload["auto_rename_enabled"] = True
```

**3. Build step:**
Run `build-lambdas.sh` to copy `lambda-shared/` into each Lambda's `_shared/`
directory.

**⚠️ Deployment order:** Deploy `loki-dashboard` backend changes **first** (so the
API accepts the new event), then deploy the installer update. If deployed in
reverse order, the new event gets silently dropped (forward-compat: unknown
events → drop). **This is a cross-service ordering constraint — violating it
causes data loss for rename telemetry.**

Note: The Python snippets above are illustrative. Verify against the current
`loki-dashboard` codebase at implementation time — the dashboard code may have
changed since this design was written.

## Implementation Scope

Checklist of files/repos that need changes:

### `inceptionstack/lowkey` (this repo)
- [x] `install.sh`: Add `maybe_rename_account()`, `_emit_rename_telemetry()`,
      flag parsing (`--auto-rename-account-enabled`, `--disable-account-rename`),
      call site in `main()` after `preflight_checks`, before config wizard
- [x] `install.sh`: Add `account_rename_enabled` field to `_telem_send_install_beacon`
- [x] `install.sh` `--help` text: Document new flags
- [x] `docs/reference/telemetry-v1.schema.json`: Add `account_rename_enabled` to beacon,
      `install.account_renamed` to EventName enum
- [x] `docs/reference/telemetry-schema.mdx`: Document new beacon field and event
- [x] `docs/reference/cli.mdx`: Document new flags
- [x] Tests: 47 test cases in `tests/test-account-rename.sh`
- [ ] `uninstall.sh`: Add `maybe_restore_account_name()` — **significant scope,
      tracked as follow-up:** currently has zero account/SSM-restore code.
- [ ] `docs/quickstart.mdx`: Mention account rename in install flow overview (follow-up)

### `inceptionstack/loki-dashboard` (separate repo)
- [ ] `lambda-shared/validate.py`: Register `install.account_renamed` event,
      add `ALLOWED_ACCOUNT_RENAME_SKIP`, prop validators
- [ ] `lambda-shared/validate.py`: Add `account_rename_enabled` to install beacon
- [ ] `lambda-ingest/handler.py`: Telegram notification enrichment
- [ ] `lambda-install/handler.py`: Add `account_rename_enabled` to Firehose row
- [ ] Run `build-lambdas.sh` and deploy
