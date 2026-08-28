# Lowkey Docs

Mintlify-powered documentation for Lowkey. Source of truth for [lokiagent.dev](https://lokiagent.dev) (official homepage) and [docs.lowkey.run](https://docs.lowkey.run) (deployed docs).

## Structure

```
docs/
├── docs.json                     # Mintlify config (navigation, theme, branding)
├── index.mdx                     # Landing page
├── quickstart.mdx                # Quickstart guide
├── concepts.mdx                  # Core concepts
├── profiles/                     # Per-profile pages (builder / account_assistant / personal_assistant)
├── agents/                       # Per-agent pages (one per pack)
├── reference/                    # CLI flags, defaults, deploy methods, security, secrets
└── images/                       # Shared imagery (add as needed)
```

## Preview locally

```bash
# Install Mintlify CLI (once)
npm i -g mintlify

# Run dev server from the docs directory
cd docs
mintlify dev
```

Opens a live-reloading preview at `http://localhost:3000`.

## Deploy

Lowkey's docs are intended to be deployed via Mintlify's hosted service or a similar MDX-compatible platform. On Mintlify:

1. Create a project at [mintlify.com](https://mintlify.com/dashboard).
2. Point it at `inceptionstack/lowkey` repo, `docs/` subdirectory, `main` branch.
3. Mintlify auto-deploys on every push.

The `docs.json` schema is documented at [mintlify.com/docs/settings/global](https://mintlify.com/docs/settings/global).

## Conventions

- **MDX files** (`.mdx`) for anything with components (`<Card>`, `<Tabs>`, `<Accordion>`, etc.).
- **One file per topic**; navigation tree in `docs.json` decides the order.
- **Front matter** (YAML) at the top: `title`, `description` are required.
- **Internal links** use the site-relative path without the `.mdx` extension: `/agents/openclaw`, not `/agents/openclaw.mdx`.
- **External links** use full URLs.

## Update when the pack or CLI changes

When adding/modifying a pack:

1. Update the pack's page in `docs/agents/<pack>.mdx`.
2. If a new top-level flag is added, update `docs/reference/cli.mdx` and `docs/reference/environment-variables.mdx`.
3. If profile defaults change, update `docs/reference/simple-mode-defaults.mdx`.
4. Bump the release-notes section of `docs/index.mdx` if it's a big change.

## Open questions

- Hosting: current assumption is Mintlify. If we self-host (Nextra, Docusaurus, etc.) the MDX files should still work but the `docs.json` config would need to be replaced.
- i18n: no translations yet. OpenClaw's docs use an auto-translate GitHub Action — if we want the same here, pattern to copy lives at [openclaw/openclaw docs-sync-publish.yml](https://github.com/openclaw/openclaw/blob/main/.github/workflows/docs-sync-publish.yml).
