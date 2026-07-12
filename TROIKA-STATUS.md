# TROIKA-STATUS.md — Phases 5 & 6 Implementation Status

**Date:** 2026-07-12  
**Implementer:** Subagent (depth 1)  
**Phases completed:** 5 (Preflight Codex-model probe) + 6 (Docs)

---

## Phase 5: Preflight Codex-model probe

### What was implemented

**File modified:** `install.sh`

Two additions to `install.sh`:

1. **`_check_codex_model_access()` helper function** (placed after `_bedrock_access_guidance`, before `check_vpc_quota`, ~line 1460):
   - Takes `codex_model` and `probe_region` as arguments
   - **Attempt 1**: Tries `aws bedrock-runtime converse` — covers the case where Mantle does support converse, and catches ThrottlingException/TooManyRequests (throttled = access granted)
   - **Attempt 2 (fallback)**: `aws bedrock list-foundation-models --query "modelSummaries[?contains(modelId, 'openai')]"` — confirms Mantle models are visible in the region/account
   - If fallback also returns nothing: issues a non-fatal warning with model-access console URL
   - Does NOT call `confirm_or_abort` — purely informational (user already saw Sonnet warning)
   - Does NOT modify `BEDROCK_ACCESS_OK` — that global tracks Sonnet only

2. **Troika probe trigger** (added at end of `check_bedrock_access()`, before closing `}`):
   - Condition: `PACK_NAME=troika` OR `PRESELECT_PACK=troika` OR `TROIKA_CODEX_MODEL` non-empty
   - Rationale: `PACK_NAME` is still "openclaw" (default) at preflight time because pack selection runs later (`run_config_and_review`). `PRESELECT_PACK` covers `--pack troika` non-interactive mode. `TROIKA_CODEX_MODEL` covers `--codex-model` explicit overrides.
   - Uses `${TROIKA_CODEX_MODEL:-openai.gpt-5.5}` as the model to probe

### Shellcheck

- Pre-change: 18 output lines (3 pre-existing warnings, all unrelated to Troika)  
- Post-change: 18 output lines (same — zero new warnings introduced)  
- Exit code: 0 (shellcheck -S warning)

---

## Phase 6: Docs

### Files created/modified

**New file:** `docs/agents/troika.mdx`

Content covers:
- What Troika is (three-harness coding machine: OpenClaw/Hermes + Claude Code + Codex CLI, all via Bedrock)
- Summary table of the three horses with binaries and roles
- Daily driver switching (`agents driver <name>`, `agents` status, escape hatches)
- Review workflow concept (manual cross-review commands; `agents review` stretch goal noted)
- Stack requirements table (t4g.xlarge, 80GB data volume, builder-only, region requirements)
- Bedrock model access section (two separate grants required: Anthropic Sonnet + Mantle openai.gpt-5.5)
- What the pack installs (6 steps)
- Resource usage notes
- First-run commands
- Links to related docs

**Modified:** `README.md`

Two tables updated:
1. **"Agent packs" summary table** (~line 89): Added `| **Troika** *(experimental)* | ...` row after Codex CLI
2. **"Available Packs" reference table** (~line 207): Added `` | `troika` | Agent *(experimental)* | ... `` row after `codex-cli`, before `roundhouse`

---

## Test Results

### `bash packs/troika/test.sh`

```
Passed:  59
Failed:  0
Skipped: 0
✓ All tests passed
```

### `bash tests/test-pack-contracts.sh`

```
Discovered 7 agent pack(s): claude-code codex-cli hermes kiro-cli openclaw roundhouse troika

Passed:  155
Failed:  0
Skipped: 0
✓ All pack contracts satisfied
```

---

## Code quality (§12b compliance)

- ✅ DRY: `_check_codex_model_access` is a single helper, called once from `check_bedrock_access`
- ✅ Single source of truth: probe trigger checks all known early signals (`PACK_NAME`, `PRESELECT_PACK`, `TROIKA_CODEX_MODEL`)
- ✅ Non-fatal by construction: no `confirm_or_abort`, no `fail`, `BEDROCK_ACCESS_OK` unchanged
- ✅ Shellcheck-clean at `-S warning` (zero new warnings)
- ✅ No hardcoded pack logic in troika pack files — only `install.sh` (main installer) was modified
