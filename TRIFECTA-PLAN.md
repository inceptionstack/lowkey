# Trifecta Pack — Technical Plan

New installer menu option **`trifecta`**: installs **OpenClaw + Claude Code + Codex CLI**
on ONE EC2 instance, all inference via **Amazon Bedrock** (no OpenAI/Anthropic API keys).
At install time the user picks a **daily driver** — the agent whose TUI auto-launches
when they SSM into the box. Goal: a multi-harness coding + cross-review experience
(e.g. OpenClaw builds, Claude Code reviews, Codex arbitrates).

## 1. Registry (packs/registry.yaml + registry.json — keep in sync)

New entry:

    trifecta:
      type: agent
      description: "Trifecta — OpenClaw + Claude Code + Codex CLI on one instance, all via Bedrock"
      deps:
        - bedrockify      # explicit: bootstrap dep resolution is SINGLE-LEVEL (verify — see risks)
        - openclaw
        - claude-code
        - codex-cli
      instance_type: t4g.xlarge     # max of the three (openclaw needs xlarge)
      root_volume_gb: 40
      data_volume_gb: 80            # openclaw brain volume
      default_model: "us.anthropic.claude-sonnet-4-6"
      ports: { gateway: 3001 }
      brain: true                   # openclaw brain files
      claude_code: false            # claude-code installed as dep, not via legacy flag
      experimental: true            # new; promote later
      requires_openai_key: false    # codex runs via Bedrock — NO OpenAI key needed
      compatible_profiles:
        - builder                   # Trifecta is ALWAYS builder profile

Ordering note: deps run in listed order (bedrockify -> openclaw -> claude-code ->
codex-cli), then trifecta's own install.sh runs LAST (it wires cross-agent config).

## 2. New pack: packs/trifecta/

    packs/trifecta/
      manifest.yaml
      install.sh
      resources/shell-profile.sh
      test.sh

### manifest.yaml
- name: trifecta, type: agent, deps as in registry
- params:
  - `daily-driver`  (openclaw | claude-code | codex-cli; default openclaw)
  - `model`         (Bedrock id for Claude-family agents; default us.anthropic.claude-sonnet-4-6)
  - `codex-model`   (Bedrock Mantle id for Codex; default openai.gpt-5.5)
  - `region`        (Bedrock region; default us-east-1)
- health_check: verify all three: `openclaw --version && claude --version && codex --version`
- provides.commands: [openclaw, claude, codex, agents]

### install.sh (runs after all deps installed)
1. Read `daily-driver` via pack_config_get; validate against allowed set; write to
   `/home/ec2-user/.config/lowkey/daily-driver` (mode 0644, owner ec2-user).
2. **Codex -> Bedrock rewire**: write `/home/ec2-user/.codex/config.toml`:
       model_provider = "amazon-bedrock"
       model = "<codex-model>"        # default openai.gpt-5.5
   Auth = instance IAM role via AWS SDK chain (verified working pattern). Ensure
   `AWS_REGION` exported in .bashrc (bootstrap already exports AWS_DEFAULT_REGION;
   Codex reads AWS_REGION — export BOTH).
3. **Claude Code -> Bedrock**: claude-code pack already sets CLAUDE_CODE_USE_BEDROCK=1 +
   ANTHROPIC_MODEL. Trifecta only overrides model if user changed `model` param.
4. Install `agents` helper (small bash script to /usr/local/bin/agents):
   - `agents`            -> status: which of the 3 are installed + current daily driver
   - `agents driver <x>` -> switch daily driver (rewrites the config file)
   - `agents review <path>` (stretch) -> run the two non-driver agents in -p/exec mode
     against a diff for the multi-harness review flow
5. Write SSM parameter `/loki/daily-driver` (String) for observability.

### resources/shell-profile.sh
- PACK_BANNER_NAME="Trifecta", emoji, PACK_BANNER_COMMANDS lists: openclaw tui / claude /
  codex / agents driver <name>
- PACK_ALIASES: aliases for all three + `agents`

## 3. Daily-driver auto-launch (the SSM->TUI popup)

Current flow: `/etc/profile.d/loki.sh` auto-execs `sudo -iu ec2-user` for ssm-user;
ec2-user .bashrc prints the pack banner.

Trifecta appends an auto-launch block to ec2-user `.bashrc` (AFTER the banner block):

    # Trifecta daily-driver auto-launch
    if [[ $- == *i* ]] && [[ -t 0 ]] && [[ -z "$LOKI_TUI_LAUNCHED" ]] \
       && [[ -z "$LOKI_NO_TUI" ]] && [[ -f ~/.config/lowkey/daily-driver ]]; then
      export LOKI_TUI_LAUNCHED=1
      _dd=$(<~/.config/lowkey/daily-driver)
      echo "Launching ${_dd} (daily driver) — Ctrl+C to skip, LOKI_NO_TUI=1 to disable"
      sleep 2   # grace period to Ctrl+C
      case "$_dd" in
        openclaw)    openclaw tui ;;
        claude-code) claude ;;
        codex-cli)   codex ;;
      esac
    fi

Safety properties (MUST hold):
- `[[ -t 0 ]]` + interactive guard: never triggers for `aws ssm send-command`,
  scp-over-ssm, port-forwarding sessions, or non-tty execs.
- NOT `exec`-ed: when the TUI exits, the user lands in a normal shell.
- `LOKI_TUI_LAUNCHED` guard prevents nested relaunch inside the TUI's own subshells.
- Escape hatches: Ctrl+C during grace period; `LOKI_NO_TUI=1`; `agents driver none`
  (writes `none` -> case falls through).

## 4. Installer changes (install.sh)

1. Pack menu: registry-driven, so the new registry entry appears automatically —
   VERIFY menu is built from registry (it is: jq over registry.json, L~1759).
2. `pack_default_model()`: add `trifecta) echo "us.anthropic.claude-sonnet-4-6"`.
3. New config question (only when PACK_NAME=trifecta), gum choose:
   "Which agent is your daily driver? (auto-launches when you SSM in)"
   -> openclaw (default) | claude-code | codex-cli. Preselect flag: `--daily-driver <x>`.
3b. **Profile lock**: trifecta is builder-only. Installer must skip the profile
   question (auto-set builder) or fail fast on `--profile != builder`, mirroring
   existing `compatible_profiles` handling for roundhouse.
4. Param plumbing: append `DailyDriver` to PARAM_CFN_NAMES + PARAM_VALUES
   (empty/openclaw for non-trifecta packs). NOTE: arrays must stay in sync
   (validated at runtime; CFN-only — installer assumes CloudFormation is the sole
   deploy method).
5. `requires_openai_key` logic: trifecta must NOT trigger the OpenAI key prompt that
   codex-cli standalone uses (registry flag false handles it — verify installer checks
   the flag per-pack, not per-installed-component).
6. Review summary: show `Daily driver  <x>` line when pack=trifecta.

## 5. CloudFormation template (deploy/cloudformation/template.yaml)

- `PackName` AllowedValues += `trifecta`.
- New param `DailyDriver` (String, default `openclaw`, AllowedValues
  [openclaw, claude-code, codex-cli]; harmless/ignored for other packs).
- UserData: pass `--daily-driver ${DailyDriver}` to bootstrap.sh pack args
  (bootstrap forwards unknown `--key value` pairs to pack install.sh via
  pack_config — verify the generic passthrough, L~127).
- Instance sizing: template must honor registry instance_type/data_volume for
  trifecta (t4g.xlarge / 80GB). Check how InstanceType default interacts with
  pack selection in the installer (installer reads registry -> sets param).

## 6. bootstrap.sh (deploy/bootstrap.sh)

- Dep resolution: `registry_get_deps` is single-level (reads only the requested
  pack's deps list). Trifecta lists bedrockify explicitly, so no transitive
  resolution needed — but ADD a dedupe guard so bedrockify isn't run twice
  (openclaw's dep + trifecta's explicit dep) — check existing behavior first;
  if steps array dedupes already, document it.
- Shell profile phase: uses packs/trifecta/resources/shell-profile.sh (banner
  covers all three agents). The SSM banner vars (_SSM_BANNER_*) come from the
  same file — verify.
- Post-install claude_code legacy flag: registry has `claude_code: false` for
  trifecta because claude-code is a real dep pack; ensure Phase 3 doesn't
  double-install it.

## 7. Preflight (install.sh — interacts with Bedrock access check)

The new `check_bedrock_access` probes Anthropic Sonnet 4.6. For trifecta, Codex
uses Bedrock Mantle model `openai.gpt-5.5` — access is granted separately from
Anthropic models. Amendment: when pack=trifecta, ALSO probe the Codex model.
Mantle models may not respond to `bedrock-runtime converse` (they use the
OpenAI-compatible Responses API path) — needs a live test; if converse doesn't
work, fall back to `aws bedrock list-foundation-models` grep for `openai.` ids
+ non-fatal warning pointing at model-access console.

## 8. Tests

- packs/trifecta/test.sh: contract test (manifest parses, install.sh shellcheck-clean,
  daily-driver validation rejects bad values, .bashrc block is idempotent on re-run).
- tests/test-registry-parser.sh: add trifecta expectations (deps order, instance_type,
  default_model, requires_openai_key=false).
- tests/test-pack-contracts.sh: auto-discovers packs/* — verify it picks up trifecta
  and passes (install.sh executable, shebang, common.sh, done marker).
- packs/test-packs.sh: include trifecta in the matrix.
- Idempotency: re-running bootstrap must not append duplicate .bashrc blocks
  (use a sentinel marker like `# --- trifecta-autolaunch ---` + grep guard).

## 9. Docs

- docs/agents/trifecta.mdx (what it is, daily-driver switching, review workflow)
- docs/agents/overview.mdx + docs.json nav + README pack table + wiki page update

## 10. Risks / open questions

1. **Disk**: three harnesses + node toolchains on 40GB root — openclaw alone is fine,
   measure actual usage on a test deploy; bump root to 60GB if tight.
2. **Memory**: openclaw gateway (persistent) + on-demand claude/codex TUIs on
   t4g.xlarge (16GB) — fine; document that only the driver runs persistently.
3. **Bedrock quotas**: three agents share account TPM/RPM quotas; heavy parallel
   use may throttle — document; optional preflight quota listing.
4. **Codex model access**: openai.gpt-5.5 on Bedrock is region-limited; default
   region us-east-1 verified working. Add region note to docs.
5. **Dep double-run**: bedrockify listed as dep of both trifecta and openclaw —
   MUST verify bootstrap dedupes or make install.sh idempotent (it is a systemd
   unit write — likely safe, but verify).
6. **claude-code haiku fast-path**: ANTHROPIC_DEFAULT_HAIKU_MODEL default has a
   versioned id — leave as pack default.
7. **kiro-cli style `requires_*` flags**: confirm installer treats unknown/false
   flags as no-op for trifecta.

## 11. Implementation order

1. Registry entries + packs/trifecta skeleton + tests (no installer changes yet).
2. Codex-on-Bedrock config in trifecta install.sh + live verify on a scratch deploy.
3. Installer menu/question/params + CFN param + bootstrap passthrough.
4. Daily-driver autolaunch + agents helper + shell profile.
5. Preflight Codex-model probe amendment.
6. Docs + full test matrix + scratch-account end-to-end install.

## 12. Review amendments (Codex/GPT-5.5, verified against code)

Verdict: required amendments before implementation. All folded into the plan above
conceptually; listed here as the authoritative checklist:

1. **Bootstrap param plumbing is NOT generic** (bootstrap.sh:219, :242): unknown
   `--key value` args are dropped; PACK_CONFIG JSON has a hardcoded key list.
   ADD explicit parsing + config keys for `daily-driver` and `codex-model`.
2. **bedrockify double-run: non-issue** — dep resolution is single-level with no
   transitive expansion, so explicit listing is required and nothing runs twice.
   (Plan risk #5 resolved.)
3. **Pack menu reads packs/registry.json only** (install.sh:1742); YAML feeds
   bootstrap. Update BOTH or the menu option won't appear; test-sync-registry.sh
   (:165) has per-pack expectations to extend.
4. **Simple-mode sizing** (install.sh:1852): instance picked by profile, ignoring
   pack instance_type. MITIGATED by builder-only constraint (builder → xlarge),
   but still add pack-minimum enforcement to match advanced mode (:1940).
5. **Volume sizes are not plumbed**: installer never passes registry
   root/data_volume_gb to CFN (template defaults 40/80 at template.yaml:177).
   Trifecta's needs happen to match the defaults — document, or add params.
6. **CFN**: add `trifecta` to PackName AllowedValues (template.yaml:117) +
   `DailyDriver`/`CodexModel` params + explicit UserData passthrough.
7. **Codex config must be MERGED, not replaced**: codex-cli pack writes
   approval_policy/sandbox_mode to ~/.codex/config.toml (codex-cli/install.sh:195).
   Trifecta edits only model_provider/model keys. Keep Bedrock rewiring in
   trifecta only — standalone codex-cli stays OpenAI (it rejects Bedrock ids, :87).
8. **Autolaunch gating**: tty-check alone fires on every interactive SSM shell,
   including troubleshooting. Add sentinel-replacement idempotency (bootstrap
   appends .bashrc blocks blindly, bootstrap.sh:515/:524), allow `none` as a
   valid daily-driver value, and keep LOKI_NO_TUI + post-exit-to-shell behavior.
9. **requires_openai_key is inert in the installer** (registry data + tests only);
   codex standalone handles auth post-deploy. No installer guard needed.
10. **Profile lock (owner decision)**: trifecta is ALWAYS builder profile —
    registry compatible_profiles: [builder]; installer skips/validates profile.
