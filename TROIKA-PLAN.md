# Troika Pack — Technical Plan

New installer menu option **`troika`**: installs **OpenClaw + Claude Code + Codex CLI**
on ONE EC2 instance, all inference via **Amazon Bedrock** (no OpenAI/Anthropic API keys).
At install time the user picks a **daily driver** — the agent whose TUI auto-launches
when they SSM into the box. Goal: a multi-harness coding + cross-review experience
(e.g. OpenClaw builds, Claude Code reviews, Codex arbitrates).

## 1. Registry (packs/registry.yaml + registry.json — keep in sync)

New entry:

    troika:
      type: agent
      description: "Troika — OpenClaw + Claude Code + Codex CLI on one instance, all via Bedrock"
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
        - builder                   # Troika is ALWAYS builder profile

Ordering note: deps run in listed order (bedrockify -> openclaw -> claude-code ->
codex-cli), then troika's own install.sh runs LAST (it wires cross-agent config).

## 2. New pack: packs/troika/

    packs/troika/
      manifest.yaml
      install.sh
      resources/shell-profile.sh
      test.sh

### manifest.yaml
- name: troika, type: agent, deps as in registry
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
   ANTHROPIC_MODEL. Troika only overrides model if user changed `model` param.
4. Install `agents` helper (small bash script to /usr/local/bin/agents):
   - `agents`            -> status: which of the 3 are installed + current daily driver
   - `agents driver <x>` -> switch daily driver (rewrites the config file)
   - `agents review <path>` (stretch) -> run the two non-driver agents in -p/exec mode
     against a diff for the multi-harness review flow
5. Write SSM parameter `/loki/daily-driver` (String) for observability.

### resources/shell-profile.sh
- PACK_BANNER_NAME="Troika", emoji, PACK_BANNER_COMMANDS lists: openclaw tui / claude /
  codex / agents driver <name>
- PACK_ALIASES: aliases for all three + `agents`

## 3. Daily-driver auto-launch (the SSM->TUI popup)

Current flow: `/etc/profile.d/loki.sh` auto-execs `sudo -iu ec2-user` for ssm-user;
ec2-user .bashrc prints the pack banner.

Troika appends an auto-launch block to ec2-user `.bashrc` (AFTER the banner block):

    # Troika daily-driver auto-launch
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
2. `pack_default_model()`: add `troika) echo "us.anthropic.claude-sonnet-4-6"`.
3. New config question (only when PACK_NAME=troika), gum choose:
   "Which agent is your daily driver? (auto-launches when you SSM in)"
   -> openclaw (default) | claude-code | codex-cli. Preselect flag: `--daily-driver <x>`.
3b. **Profile lock**: troika is builder-only. Installer must skip the profile
   question (auto-set builder) or fail fast on `--profile != builder`, mirroring
   existing `compatible_profiles` handling for roundhouse.
4. Param plumbing: append `DailyDriver` to PARAM_CFN_NAMES + PARAM_VALUES
   (empty/openclaw for non-troika packs). NOTE: arrays must stay in sync
   (validated at runtime; CFN-only — installer assumes CloudFormation is the sole
   deploy method).
5. `requires_openai_key` logic: troika must NOT trigger the OpenAI key prompt that
   codex-cli standalone uses (registry flag false handles it — verify installer checks
   the flag per-pack, not per-installed-component).
6. Review summary: show `Daily driver  <x>` line when pack=troika.

## 5. CloudFormation template (deploy/cloudformation/template.yaml)

- `PackName` AllowedValues += `troika`.
- New param `DailyDriver` (String, default `openclaw`, AllowedValues
  [openclaw, claude-code, codex-cli]; harmless/ignored for other packs).
- UserData: pass `--daily-driver ${DailyDriver}` to bootstrap.sh pack args
  (bootstrap forwards unknown `--key value` pairs to pack install.sh via
  pack_config — verify the generic passthrough, L~127).
- Instance sizing: template must honor registry instance_type/data_volume for
  troika (t4g.xlarge / 80GB). Check how InstanceType default interacts with
  pack selection in the installer (installer reads registry -> sets param).

## 6. bootstrap.sh (deploy/bootstrap.sh)

- Dep resolution: `registry_get_deps` is single-level (reads only the requested
  pack's deps list). Troika lists bedrockify explicitly, so no transitive
  resolution needed — but ADD a dedupe guard so bedrockify isn't run twice
  (openclaw's dep + troika's explicit dep) — check existing behavior first;
  if steps array dedupes already, document it.
- Shell profile phase: uses packs/troika/resources/shell-profile.sh (banner
  covers all three agents). The SSM banner vars (_SSM_BANNER_*) come from the
  same file — verify.
- Post-install claude_code legacy flag: registry has `claude_code: false` for
  troika because claude-code is a real dep pack; ensure Phase 3 doesn't
  double-install it.

## 7. Preflight (install.sh — interacts with Bedrock access check)

The new `check_bedrock_access` probes Anthropic Sonnet 4.6. For troika, Codex
uses Bedrock Mantle model `openai.gpt-5.5` — access is granted separately from
Anthropic models. Amendment: when pack=troika, ALSO probe the Codex model.
Mantle models may not respond to `bedrock-runtime converse` (they use the
OpenAI-compatible Responses API path) — needs a live test; if converse doesn't
work, fall back to `aws bedrock list-foundation-models` grep for `openai.` ids
+ non-fatal warning pointing at model-access console.

## 8. Tests

- packs/troika/test.sh: contract test (manifest parses, install.sh shellcheck-clean,
  daily-driver validation rejects bad values, .bashrc block is idempotent on re-run).
- tests/test-registry-parser.sh: add troika expectations (deps order, instance_type,
  default_model, requires_openai_key=false).
- tests/test-pack-contracts.sh: auto-discovers packs/* — verify it picks up troika
  and passes (install.sh executable, shebang, common.sh, done marker).
- packs/test-packs.sh: include troika in the matrix.
- Idempotency: re-running bootstrap must not append duplicate .bashrc blocks
  (use a sentinel marker like `# --- troika-autolaunch ---` + grep guard).

## 9. Docs

- docs/agents/troika.mdx (what it is, daily-driver switching, review workflow)
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
5. **Dep double-run**: bedrockify listed as dep of both troika and openclaw —
   MUST verify bootstrap dedupes or make install.sh idempotent (it is a systemd
   unit write — likely safe, but verify).
6. **claude-code haiku fast-path**: ANTHROPIC_DEFAULT_HAIKU_MODEL default has a
   versioned id — leave as pack default.
7. **kiro-cli style `requires_*` flags**: confirm installer treats unknown/false
   flags as no-op for troika.

## 11. Implementation order

1. Registry entries + packs/troika skeleton + tests (no installer changes yet).
2. Codex-on-Bedrock config in troika install.sh + live verify on a scratch deploy.
3. Installer menu/question/params + CFN param + bootstrap passthrough.
4. Daily-driver autolaunch + agents helper + shell profile.
5. Preflight Codex-model probe amendment.
6. Docs + full test matrix + scratch-account end-to-end install.

## 12a. Owner decision (2026-07-12): selectable first horse

The first horse (the OpenClaw-family agent) is **selectable**, not hardcoded:
new param `primary` (openclaw | hermes; default openclaw).
Full title: "Troika — mixture of harnesses: OpenClaw/Hermes
+ Claude Code + Codex CLI, all via Bedrock". No "OpenClaw" brand prefix on the
pack name/title — the first horse is selectable, we don't commit to it.
Owner decision 2026-07-12 12:25: roundhouse is EXCLUDED from the primary
options for now (its Telegram-credential requirement was a review blocker);
may be added later — see point 9.

Design implications (implement in Phase 3 alongside installer wiring) —
amended after troika review 2026-07-12 (Claude Opus + Codex, arbitrated):
1. **Dynamic dep resolution**: registry deps stay `bedrockify, openclaw,
   claude-code, codex-cli` as the DEFAULT; bootstrap substitutes the `openclaw`
   dep with the selected primary. CRITICAL: substitution must apply to BOTH dep
   reads — step counting (bootstrap.sh:343) AND install dispatch (bootstrap.sh:614)
   — and no-op cleanly when primary=openclaw. Add `--primary` parsing + PACK_CONFIG
   key (bootstrap.sh:242) alongside §12.1's `--daily-driver`/`--codex-model`.
2. **daily-driver values**: valid set on a given box = {installed primary,
   claude-code, codex-cli, none}; DEFAULT must track the selected primary (not
   hardcoded openclaw). THREE hardcoded sites in packs/troika/install.sh to widen:
   VALID_DRIVERS, the autolaunch `case`, and the `agents` helper status loop.
3. **Launch commands**: source of truth is `PACK_TUI_COMMAND` in each pack's
   resources/shell-profile.sh (openclaw→`openclaw tui`, hermes→`hermes`,
   claude-code→`claude`) — NOT provides.commands.
   Caveat: bare `hermes` may be one-shot CLI, not a REPL — live-verify in Phase 2/3;
   if not interactive, daily-driver=hermes degrades to `none` + banner hint.
4. **agents helper** status/driver must reflect the selected primary (see point 2).
5. **Sizing**: keep troika at t4g.xlarge regardless of primary (builder-only
   already implies it). (Note: openclaw pack min is t4g.large, not xlarge — immaterial.)
6. **Manifest is openclaw-bound**: health_check AND provides.services
   ([openclaw-gateway]) assume primary=openclaw. health_check is operationally
   inert (only checked for presence by test-pack-contracts) — keep static but
   document; install.sh must only reference/enable openclaw-gateway when
   primary=openclaw. `agents` helper is the real runtime health surface.
7. **CFN**: add `Primary` param (AllowedValues openclaw|hermes,
   default openclaw) + UserData passthrough, TOGETHER with the §12.6 batch
   (troika in PackName AllowedValues, DailyDriver, CodexModel — none exist yet;
   UserData currently passes only `--model`, template.yaml:1133).
8. **Installer question**: "Which OpenClaw-family agent is your first horse?"
   (gum choose) + `--primary` flag; review summary line.
9. **Roundhouse deferred** (owner decision, resolves the review BLOCKER):
   roundhouse is NOT a primary option for now. Reason: its install hard-fails
   without telegram_bot_token_secret + telegram_user (roundhouse/install.sh:97-129),
   and the installer only collects those when PACK_NAME==roundhouse
   (install.sh:~2815). IF added later: extend that prompt condition to
   `troika && primary==roundhouse`, plumb params through CFN/bootstrap to the
   dep, and use `roundhouse tui` (PACK_TUI_COMMAND) for autolaunch.
10. **Shell profile**: troika banner/aliases (loki, lt) are openclaw-flavored —
    make primary-aware in Phase 4 (autolaunch/profile phase).
11. Cleanup (unrelated, low-pri): hermes manifest says `deps: []` while registry
    gives it bedrockify — metadata drift, masked by troika's explicit dep.

## 12b. Code quality requirements (owner, 2026-07-12)

All troika code (pack install.sh, agents helper, installer/bootstrap/CFN changes)
must be clean, DRY, and maintainable. Concretely:

1. **Single source of truth for agent metadata.** The agent→launch-command,
   agent→binary, agent→display-name mappings must live in ONE place (e.g. an
   associative array or a small lookup function in packs/troika/install.sh that
   reads PACK_TUI_COMMAND from each pack's shell-profile.sh). The autolaunch
   case, VALID_DRIVERS, and the agents helper must all derive from it — no
   parallel hardcoded lists (the §12a review found 3 already; collapse them).
2. **No copy-paste between installer/bootstrap/pack.** Param plumbing for
   primary/daily-driver/codex-model follows the ONE existing pattern
   (PACK_CONFIG); extend it, don't invent a second mechanism.
3. **Functions over repetition** in install.sh: config-file writes, sentinel
   block management, and validation should each be one helper used everywhere.
4. **Shellcheck-clean at -S warning** for all new/touched shell files — no
   new suppressions without a comment explaining why.
5. **Tests mirror structure**: when a lookup table gains an agent, exactly one
   test fixture should need updating. If adding hermes support requires edits
   in >2 code sites (lookup + tests), the design is wrong — refactor first.
6. **Idempotency by construction**: every write to shared files (.bashrc,
   config.toml) goes through the sentinel/merge helpers, never raw appends.

Reviewers in troika reviews should flag violations of this section as MAJOR.

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
   Troika's needs happen to match the defaults — document, or add params.
6. **CFN**: add `troika` to PackName AllowedValues (template.yaml:117) +
   `DailyDriver`/`CodexModel` params + explicit UserData passthrough.
7. **Codex config must be MERGED, not replaced**: codex-cli pack writes
   approval_policy/sandbox_mode to ~/.codex/config.toml (codex-cli/install.sh:195).
   Troika edits only model_provider/model keys. Keep Bedrock rewiring in
   troika only — standalone codex-cli stays OpenAI (it rejects Bedrock ids, :87).
8. **Autolaunch gating**: tty-check alone fires on every interactive SSM shell,
   including troubleshooting. Add sentinel-replacement idempotency (bootstrap
   appends .bashrc blocks blindly, bootstrap.sh:515/:524), allow `none` as a
   valid daily-driver value, and keep LOKI_NO_TUI + post-exit-to-shell behavior.
9. **requires_openai_key is inert in the installer** (registry data + tests only);
   codex standalone handles auth post-deploy. No installer guard needed.
10. **Profile lock (owner decision)**: troika is ALWAYS builder profile —
    registry compatible_profiles: [builder]; installer skips/validates profile.
