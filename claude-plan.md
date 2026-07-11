# claude-plan.md — Claude Code Pack Overhaul

## Review deltas (fresh-context subagent review, 2026-07-11)

Verdict: **approve with changes**. Incorporated below:

- ✅ VERIFIED live against installed 2.1.197 binary: installer accepts `stable|latest|X.Y.Z` arg;
  `claude plugin install <plugin>@<marketplace>`, `claude plugin list`, and
  `claude mcp add --scope user` all exist.
- Settings merge uses **python3** (always present on AL2023), not jq — no new prerequisite.
- MCP wiring uses `claude mcp add --scope user aws -- uvx mcp-proxy-for-aws@1.6.3`
  (reuses `MCP_PROXY_VERSION` from common.sh); best-effort `uv` install like kiro-cli.
- Existing test.sh settings.json structural tests must be **rewritten** (they assert the
  old permissions-only shape), not just supplemented.
- `write_done_marker` moves to the true end of install flow.
- PATH persistence: `~/.local/bin` export added to the profile target file.
- Plugin installs get an idempotency guard (`claude plugin list | grep`) like openclaw pack.
- `version` param wired through arg parser + help text (manifest param alone does nothing).
- Unknown-arg handling: keep permissive (framework passes shared args) but log a warning.

Gameplan for bringing `packs/claude-code` up to parity with the other packs and
current upstream best practices (https://code.claude.com/docs/en/amazon-bedrock).

## Current state (audited 2026-07-11)

| Area | Status | Notes |
|---|---|---|
| CLI version pin | ❌ None | Installs whatever `claude.ai/install.sh` resolves to. openclaw pack pins (`OPENCLAW_VERSION="2026.6.11"`); claude-code should too. Current stable: **2.1.197**. |
| Bedrock auto-connect | ⚠️ Partial | `CLAUDE_CODE_USE_BEDROCK=1` + model env vars written to profile.d / `~/.claude/bedrock-env.sh`. Works for login shells only — **not** for non-interactive SSH, CI, or systemd contexts. |
| Plugin install | ⚠️ Fragile | Uses `claude --dangerously-skip-permissions /plugin install ...` (slash-command-as-prompt hack). Modern CLI has first-class `claude plugin install <plugin>@<marketplace>` (verified in plugins-reference docs). |
| loki-skills | ✅ | `ensure_skills_clone ~/.claude/skills` — parity with other packs. |
| AWS toolkit skills | ✅ | `install_aws_toolkit_skills` — parity. |
| AWS MCP proxy | ❌ Missing | kiro-cli gets `install_aws_mcp_proxy`; claude-code doesn't. Claude Code supports MCP via `claude mcp add` / `.mcp.json`. |
| settings.json | ⚠️ Clobbers | Unconditionally overwrites `~/.claude/settings.json` on every run — destroys user customizations. Should merge with `jq`. |
| Model IDs | ✅ Valid | `us.anthropic.claude-sonnet-4-6` and `us.anthropic.claude-haiku-4-5-20251001-v1:0` both confirmed as live us-east-1 inference profiles. |
| Region resolution | ✅ OK | Doc note: since CC v2.1.172 `AWS_REGION` only needed to override profile region; we set it explicitly anyway (harmless, deterministic). |

## Phase 1 — Version pinning (highest value, lowest risk)

1. Add `CLAUDE_CODE_VERSION="2.1.197"` near top of `packs/claude-code/install.sh`
   with the same "pin deliberately, update deliberately" comment style as openclaw.
2. The official installer accepts a target arg (`stable|latest|X.Y.Z` — verified
   in installer source). Change invocation to:
   `bash /tmp/claude-code-install.sh "${CLAUDE_CODE_VERSION}"`
3. Add manifest param `version` (default `2.1.197`) so `--version` can override:
   `--pack-arg version=latest` escape hatch for testing.
4. Post-install assert: `claude --version` contains the pinned version (warn, not
   fail, if installer resolved a patch-newer build).

## Phase 2 — Bedrock auto-connect hardening

1. Keep profile.d/bashrc env export (interactive shells).
2. **Also** write the env into `~/.claude/settings.json` `"env"` block — this is
   what the official `/setup-bedrock` wizard does, and it makes Bedrock config
   work in every context (non-login shells, IDE integrations, headless `claude -p`):
   ```json
   {
     "env": {
       "CLAUDE_CODE_USE_BEDROCK": "1",
       "AWS_REGION": "<region>",
       "ANTHROPIC_MODEL": "<model>",
       "ANTHROPIC_DEFAULT_HAIKU_MODEL": "<haiku-model>"
     }
   }
   ```
3. Merge into existing settings.json with `jq` (create if absent) — never clobber.
4. Keep permissions block, but merge it too.
5. Add first-run smoke test: `claude -p "Reply with the word ok" --model "${MODEL}"`
   (behind a `--skip-smoke-test` flag; warn-only on failure so offline installs
   still succeed).

## Phase 3 — Plugins parity via first-class CLI

1. Replace the `/plugin` slash-command hack with:
   ```bash
   claude plugin marketplace update claude-plugins-official || true
   claude plugin install aws-core@claude-plugins-official
   claude plugin install aws-agents@claude-plugins-official
   ```
2. Keep best-effort semantics (`|| warn`) — offline installs must not fail.
3. Guard for older CLI: if `claude plugin --help` fails, fall back to the current
   slash-command invocation.

## Phase 4 — AWS MCP proxy (parity with kiro-cli)

1. Call `install_aws_mcp_proxy "${REGION}"` from claude-code install.sh.
2. Wire it into Claude Code natively:
   `claude mcp add --scope user aws -- uvx mcp-proxy-for-aws@<ver>` (or write the
   equivalent server entry into `~/.claude/settings.json` / `.mcp.json`).
3. `install_aws_mcp_proxy` requires `uv` — install `uv` if missing (same approach
   as kiro-cli pack) or degrade gracefully with a warn.

## Phase 5 — Manifest + registry + tests

1. manifest.yaml: bump pack `version` to `2.0.0`; add `version` param; keep
   health_check.
2. registry.yaml: no structural change needed (claude-code already listed);
   confirm default_model stays `us.anthropic.claude-sonnet-4-6`. Run
   `scripts/sync-registry` if anything changes (registry.json is GENERATED —
   never hand-edit it; that's what broke the pack-hiding attempt).
3. packs/claude-code/test.sh additions:
   - assert install.sh contains a `CLAUDE_CODE_VERSION` pin matching `X.Y.Z|stable`
   - assert settings.json template includes `env.CLAUDE_CODE_USE_BEDROCK`
   - assert plugin install uses `claude plugin install` (not the slash hack)
   - assert `install_aws_mcp_proxy` is invoked
   - settings-merge test: pre-seed a settings.json with a custom key, run the
     merge function, assert the key survives
4. Run full suite: `packs/test-packs.sh` + `tests/*.sh`.

## Phase 6 — Docs

1. Update pack usage text + README pack table if it describes claude-code capabilities.
2. Note the version pin and how to override (`--pack-arg version=...`).

## Verification checklist (done on a live install)

- [ ] `claude --version` == pinned version
- [ ] Fresh non-login shell: `claude -p "ok"` hits Bedrock without sourcing bashrc
- [ ] `claude plugin list` shows aws-core + aws-agents
- [ ] `ls ~/.claude/skills` shows loki-skills + core-skills/ + specialized-skills/
- [ ] `claude mcp list` shows the AWS MCP proxy
- [ ] Re-running install.sh is idempotent (settings.json customizations survive)

## Explicit non-goals

- No switch to `global.` inference profiles by default (us. profiles verified live;
  global is an easy param flip later).
- No systemd service (Claude Code is a CLI, matches current design).
- No Bedrock API-key auth path (instance IAM role is the pattern for these boxes).
