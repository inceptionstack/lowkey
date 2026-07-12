# Troika Feature Code Review
> Reviewed: 2026-07-12 | Reviewer: subagent (Claude Sonnet 4.6)  
> Scope: packs/troika/, packs/registry.{yaml,json}, install.sh (troika sections), deploy/bootstrap.sh, deploy/cloudformation/template.yaml

---

## Summary

The troika feature is structurally sound and largely satisfies the §12b code-quality mandate. The pack follows the single-source-of-truth `_read_tui_cmd` lookup pattern, dep-substitution lives in a single `get_effective_deps` helper, PACK_CONFIG is the sole plumbing mechanism, and all 59 pack-level tests pass with shellcheck clean at `-S warning`. The TOML merge Python script is a standout piece — it handles idempotency, key deduplication, and TOML escape correctly.

There is one **critical bug** (shebang placement in generated `agents` script), two **major correctness gaps** (no installer-level cross-validation of `--daily-driver` vs `--primary`, autolaunch block frozen at first install), and a small cluster of minor items. None block a staged deploy to a scratch account, but the critical and major items should be fixed before a broader rollout.

---

## Critical Issues (blockers)

### C1 — Shebang on line 2 in generated `agents` script

**File:** `packs/troika/install.sh` lines 258–260

The `agents` script is generated with a `# shellcheck disable=SC2086` comment on line 1 and the `#!/usr/bin/env bash` shebang on line 2:

```bash
cat > "${AGENTS_TMP}" <<AGENTS_SCRIPT
# shellcheck disable=SC2086  # intentional unquoted expansion...
#!/usr/bin/env bash
```

The Linux kernel honors the magic byte sequence `#!` **only when it is the very first two bytes of the file**. When a comment precedes the shebang, `exec()` returns `ENOEXEC` (`strace` confirms this). Bash falls back to executing the file as a shell script in its own process (bash-specific behavior), which is why it appears to work in basic testing — but it is not portable and will silently break in any context that calls `agents` through a non-bash shell, a shebang-strict environment, or via `env` (e.g. sudo with secure_path).

**Fix:** Move the shebang to line 1 and place the shellcheck directive on line 2 (directives after the shebang are valid and supported by shellcheck):

```bash
cat > "${AGENTS_TMP}" <<AGENTS_SCRIPT
#!/usr/bin/env bash
# shellcheck disable=SC2086  # intentional unquoted expansion of metadata vars
# agents — Troika multi-harness helper
```

**Test gap:** `test.sh` checks `install.sh`'s shebang (line 126) but has no analogous check for the generated `agents` script content.

---

## Major Issues (should fix before merge)

### M1 — Installer has no pre-flight validation of `--daily-driver` vs `--primary` mismatch

**File:** `install.sh` (troika section, ~line 2928–2975)

When the user passes both flags non-interactively (`--primary hermes --daily-driver openclaw`), the installer stores them directly in `TROIKA_PRIMARY` and `TROIKA_DAILY_DRIVER` without cross-checking. The mismatch isn't caught until `packs/troika/install.sh` runs on the EC2 instance — after a CloudFormation stack has been launched and a 5–10 minute deployment has started. The error surface is a cryptic bootstrap log line rather than an immediate installer failure.

`VALID_DRIVERS` in the pack is computed as `("${PRIMARY}" claude-code codex-cli none)`, so `openclaw` is invalid when `primary=hermes`. The installer already has the information to catch this before launch.

**Fix:** Add a validation block after the primary/daily-driver are finalized in `collect_config`:

```bash
# Validate cross-combination: daily-driver must be valid for selected primary
if [[ -n "${TROIKA_DAILY_DRIVER:-}" ]]; then
  case "${TROIKA_DAILY_DRIVER}" in
    "${TROIKA_PRIMARY}"|claude-code|codex-cli|none) : ;;
    *)
      fail "--daily-driver '${TROIKA_DAILY_DRIVER}' is not valid when --primary='${TROIKA_PRIMARY}'. Valid set: ${TROIKA_PRIMARY} | claude-code | codex-cli | none"
      ;;
  esac
fi
```

---

### M2 — Autolaunch `.bashrc` block is frozen at first install (cannot be updated on re-run)

**File:** `packs/troika/install.sh` lines 352–395

The sentinel guard prevents appending a second autolaunch block on re-run — which is correct for the common case. However, the block **bakes in** `${PRIMARY}` and `${_PRIMARY_CMD}` at write time:

```bash
case "\$_dd" in
  ${PRIMARY})    ${_PRIMARY_CMD} ;;   # expanded once at install time
  claude-code)   ${_CLAUDE_CMD} ;;
  codex-cli)     ${_CODEX_CMD} ;;
  none)          : ;;
esac
```

If a user re-runs the pack with `--primary hermes` (having originally installed with `primary=openclaw`), the sentinel fires the "already present" path and silently skips the update. The `.bashrc` still dispatches `openclaw tui` when `_dd=openclaw`, and `hermes` is now a valid daily-driver value (per the new pack run) but has **no case branch**. Result: switching to `hermes` with `agents driver hermes` sets the driver file correctly, but `.bashrc` falls through the case with no output and the user gets a silent no-op on every login.

The `agents` helper is correctly overwritten on every run (no guard), so `agents status` would show the correct binary. But the autolaunch `.bashrc` dispatch is stale.

**Fix options:**

1. **Sentinel-replace pattern** (preferred for §12b.6): strip the old block and rewrite it, rather than skip. Use the sentinel to find-and-delete the old block via `sed` or Python before appending the fresh one. This would bring the autolaunch block in line with how the TOML merger works (find → remove → rewrite).

2. **Runtime-dynamic dispatch** (simpler): Instead of baking commands at write time, read `PACK_TUI_COMMAND` at runtime:

```bash
case "$_dd" in
  openclaw)    openclaw tui ;;
  hermes)      hermes ;;
  claude-code) claude ;;
  codex-cli)   codex ;;
  none)        : ;;
esac
```
This trades the `_read_tui_cmd` abstraction for hardcoded commands in `.bashrc` — a regression against §12b.1 — so option 1 is preferred.

**Related:** The `AWS_REGION` sentinel block (lines 241–246) has the same re-run immutability problem. If `--region` changes on re-run, the stale region persists in `.bashrc`. Lower urgency (region changes are rarer) but worth addressing in the same fix pass.

---

## Minor Issues (nice to have)

### m1 — `codex-cli/resources/shell-profile.sh` lacks `PACK_TUI_COMMAND`

**File:** `packs/codex-cli/resources/shell-profile.sh`

All other packs in the lookup chain (`openclaw`, `hermes`, `claude-code`) declare `PACK_TUI_COMMAND=`. The codex-cli pack does not, so `_read_tui_cmd` returns empty and `_CODEX_CMD` falls back to the hardcoded default `"codex"`. This works correctly — `codex` is the right command — but it breaks the single-source-of-truth discipline: a reader of `troika/install.sh` has no way to verify that the fallback is intentional vs. a missing declaration.

**Fix:** Add to `codex-cli/resources/shell-profile.sh`:
```bash
PACK_TUI_COMMAND="codex"
```

---

### m2 — `DailyDriver` CFN parameter has no `AllowedValues`

**File:** `deploy/cloudformation/template.yaml` lines 279–283

The `Primary` parameter correctly declares `AllowedValues: [openclaw, hermes]`. `DailyDriver` has no `AllowedValues` and accepts any string. A typo (e.g., `openclaww`) silently passes through CFN and fails at bootstrap after a full deployment. Adding `AllowedValues` provides immediate console-level feedback.

Suggested (empty string signals "default to primary"):
```yaml
AllowedValues:
  - ''
  - openclaw
  - hermes
  - claude-code
  - codex-cli
  - none
```

Note: this is the only reason the `AllowedValues` caveat exists at all — Primary has it correctly.

---

### m3 — Hardcoded `openclaw` in install completion summary and `manifest.yaml` health_check

**File:** `packs/troika/install.sh` lines 407–412; `packs/troika/manifest.yaml` lines 38–40

The final summary block always prints:
```
  openclaw:    openclaw tui
  claude-code: claude
  codex-cli:   codex
```

When `primary=hermes` this is incorrect — `openclaw tui` is not installed on that box.

Similarly, `manifest.yaml`'s `health_check.command` is:
```
openclaw --version && claude --version && codex --version
```
This would fail an active health probe when `primary=hermes`. The plan documents this as a known static limitation (§12a.6, "manifest is openclaw-bound"), but the install summary is fully runtime-aware and should use `${_PRIMARY_BIN}` / `${_PRIMARY_CMD}`.

**Fix for summary:**
```bash
printf "\n[PACK:troika] INSTALLED — daily driver: %s\n" "${DAILY_DRIVER}"
printf "  %s:    %s\n" "${PRIMARY}" "${_PRIMARY_CMD}"
printf "  claude-code: %s\n" "${_CLAUDE_CMD}"
printf "  codex-cli:   %s\n" "${_CODEX_CMD}"
printf "  switch:      agents driver <name>\n\n"
```

**Manifest health_check:** Accept as-is for now (operationally inert per plan) but add an inline comment: `# NOTE: static; valid only for primary=openclaw (§12a.6)`.

---

### m4 — No test for `primary=hermes` code path

**File:** `packs/troika/test.sh`

The test suite validates invalid primary/driver rejection but has zero coverage for the `primary=hermes` path. It doesn't verify:
- That `VALID_DRIVERS` contains `hermes` (not `openclaw`) when primary=hermes
- That the autolaunch block case-branches to `hermes` (not `openclaw tui`) when primary=hermes
- That the agents helper `VALID_DRIVERS` embedded string is hermes-aware

The `deploy/test-bootstrap.sh` does cover `get_effective_deps` substitution for `primary=hermes` (Test 7), which is good. The gap is at the pack level.

**Suggested test addition** (in section 3, daily-driver validation):
```bash
# Hermes-as-primary: valid drivers include hermes, exclude openclaw
if PACK_CONFIG=/dev/null bash "${INSTALL}" --primary hermes --daily-driver hermes >/dev/null 2>&1; then
  pass "install.sh: accepts hermes as daily-driver when primary=hermes"
else
  fail "install.sh: rejected hermes as daily-driver when primary=hermes (should accept)"
fi

if PACK_CONFIG=/dev/null bash "${INSTALL}" --primary hermes --daily-driver openclaw >/dev/null 2>&1; then
  fail "install.sh: accepted openclaw as daily-driver when primary=hermes (should reject)"
else
  pass "install.sh: rejects openclaw as daily-driver when primary=hermes"
fi
```

---

### m5 — Unknown-arg handler in `install.sh` uses fragile `&&...||` pattern

**File:** `packs/troika/install.sh` line 71

```bash
*) [[ $# -gt 1 ]] && [[ "$2" != --* ]] && shift 2 || shift ;;
```

This works correctly for all current inputs but the `A && B && C || D` chaining is a well-known shell footgun: if `A` is true and `B` is false, `C` is skipped and `D` runs — which happens to produce the right result here (shift 1 when next arg is a flag), but it's non-obvious and will confuse a future maintainer. The other packs (`openclaw`, `hermes`, etc.) use the same one-liner pattern — this isn't troika-specific — but since troika is new code, adopting a more readable form would be a small improvement:

```bash
*)
  if [[ $# -gt 1 ]] && [[ "$2" != --* ]]; then
    shift 2
  else
    shift
  fi
  ;;
```

---

### m6 — `_read_tui_cmd` strips only double-quotes

**File:** `packs/troika/install.sh` lines 83–93

```bash
cmd="${cmd#\"}"   # strip leading "
cmd="${cmd%\"}"   # strip trailing "
```

If a future pack uses `PACK_TUI_COMMAND='my cmd'` (single quotes), the stripping won't fire and the value will include the literal quotes. All current packs use `=` without quotes or with double quotes, so this is safe today. Worth a comment or a more general strip:

```bash
cmd="${cmd#[\"']}"   # strip leading quote
cmd="${cmd%[\"']}"   # strip trailing quote
```

---

### m7 — No test verifies the generated `agents` shebang placement

Directly related to C1. The test suite checks `install.sh`'s shebang on line 126-127 but doesn't extract and validate the generated script's first line. A simple check would catch the regression permanently:

```bash
# Verify agents script has shebang on line 1
_generated_shebang=$(bash "${INSTALL}" --help >/dev/null; ... )  # or parse the heredoc directly
```
(Implementation left to the maintainer since it requires either extracting the heredoc or running a dry-run install against a temp home.)

---

### m8 — `manifest.yaml` `provides.commands` lists `openclaw` unconditionally

**File:** `packs/troika/manifest.yaml` lines 42–46

```yaml
provides:
  commands:
    - openclaw
    - claude
    - codex
    - agents
  services:
    - openclaw-gateway
```

When `primary=hermes`, `openclaw` is not installed and `openclaw-gateway` is not enabled. The manifest is static and the plan acknowledges this (§12a.6). This is acceptable as-is, but `hermes` is missing from `provides.commands` entirely even for the hermes-primary case. Consider adding a note in the manifest or a separate `provides.commands_primary_openclaw` / `provides.commands_primary_hermes` comment.

---

## Positive Notes (things done well)

**Architecture:**
- **`_read_tui_cmd` lookup function** is an elegant single-source-of-truth implementation that satisfies §12b.1 cleanly. All three autolaunch sites (VALID_DRIVERS, case dispatch, agents helper status loop) derive from it.
- **`get_effective_deps` in bootstrap.sh** handles the troika dep-substitution in exactly one place, applying correctly to both step counting and install dispatch. No copy-paste.
- **PACK_CONFIG is the sole plumbing mechanism** — no second channel was invented. Primary/daily-driver/codex-model flow through the same JSON config that all other pack params use.

**TOML merge Python script:**
The Bedrock rewire logic in `packs/troika/install.sh` (lines 150–230) is the most complex piece and it's excellent:
- Idempotency: removes any prior troika block before writing (regex strip)
- Conflict avoidance: strips `model =` from the codex-cli managed block to prevent TOML duplicate-key errors while preserving `approval_policy` and `sandbox_mode`
- Placement: troika block goes to the top (before any `[table]`), valid per TOML spec
- Escape: the `toml_escape` function handles all required control-character cases including newline injection detection
- Error handling: validates the model string, exits with code 2 on newline in model value (prevents shell injection into TOML)

**Safety / idempotency:**
- Sentinel-based `.bashrc` guard correctly prevents double-append on re-run
- `[[ $- == *i* ]]`, `[[ -t 0 ]]`, `LOKI_TUI_LAUNCHED`, and `LOKI_NO_TUI` guards are all present and in the correct order — the autolaunch cannot fire on non-tty SSM sessions, scp-over-ssm, or `aws ssm send-command`
- `CODEX_CONFIG` gets `chmod 600` after write — correct
- Temp file cleanup uses `trap ... EXIT` then `trap - EXIT` after explicit removal — clean pattern
- SSM put-parameter uses `|| warn` (non-fatal on IAM permission gap) — correct severity

**Registry consistency:**
`registry.yaml` and `registry.json` are byte-for-byte semantically consistent (all 59 test-sync-registry.sh checks pass). `requires_openai_key: false` is correctly set and the installer's `compatible_profiles` enforcement will auto-lock troika to `builder`.

**Test coverage:**
59 tests, 0 failures, 0 skips in `packs/troika/test.sh`. Shellcheck clean at `-S warning` for both `install.sh` and `shell-profile.sh`. The suite covers: manifest structure, arg parsing, valid/invalid driver rejection, sentinel idempotency, all escape hatches, and registry consistency. This is significantly better test coverage than most other packs.

**bootstrap.sh dep substitution:**
`get_effective_deps` correctly handles the hermes-primary case (Test 7 in test-bootstrap.sh passes). The substitution is atomic: `openclaw` is replaced, `bedrockify` (which is both a troika explicit dep AND openclaw's dep) is not duplicated because dep resolution is single-level. This satisfies plan §12.2 (risk #5 resolved, documented in TROIKA-PLAN §12).

**CFN integration:**
`Primary` param has correct `AllowedValues: [openclaw, hermes]`. Both `Primary` and `DailyDriver` are listed in the `ParameterGroups` UI grouping. The `bootstrap.sh` passthrough is explicit (not relying on generic unknown-arg forwarding). Array sync check (`PARAM_CFN_NAMES` == `PARAM_VALUES` length) fires at deploy time — good guard against future drift.

---

*End of review. 3 critical/major items warrant fixes before broader rollout; minors can be addressed in a follow-up pass.*
