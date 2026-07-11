# Stable vs Latest Installer Versioning

> Status: **Plan** — not yet implemented.
> Author: Codex brainstorm + human review, 2026-05-01

## Problem

`install.lowkey.run` serves `main` branch directly. Every push is immediately live.
There is no way to distinguish a tested release from a work-in-progress commit.

## Goals

1. Default `curl -sfL install.lowkey.run | bash` always gets a **stable** version.
2. Testers can opt into **latest** (tip of main): `curl -sfL install.lowkey.run/latest | bash`.
3. Any version can be **pinned**: `curl -sfL install.lowkey.run/v0.5.116 | bash`.
4. **Rollback** is a 30-second operation, not a git revert.
5. Stable means the *entire install* is stable — not just the wrapper script.

## URL Design

```
install.lowkey.run              → channels/stable/install.sh
install.lowkey.run/stable       → channels/stable/install.sh
install.lowkey.run/latest       → channels/latest/install.sh
install.lowkey.run/v0.5.116     → versions/v0.5.116/install.sh
```

Paths, not query params. No subdomains.

## S3 Layout

```
s3://lowkey-install/
  versions/
    v0.5.116/
      install.sh          # immutable — never overwritten
      sha256.txt
    v0.5.117/
      install.sh
      sha256.txt
  channels/
    stable/
      install.sh          # copy of a specific version
    latest/
      install.sh          # auto-published on every push to main
```

CloudFront serves the bucket. Cache headers:
- `channels/*` → `Cache-Control: max-age=60`
- `versions/*` → `Cache-Control: public, max-age=31536000, immutable`

## How a Version Becomes Stable

**Manual workflow dispatch**: `promote-installer.yml`

Inputs:
- `version` (required): e.g. `v0.5.116`
- `channel`: `stable` (default)

Steps:
1. Verify `versions/v0.5.116/install.sh` exists in S3 (or build from tagged commit).
2. Run validation + smoke tests against that exact artifact.
3. Create/verify annotated git tag `installer/v0.5.116`.
4. Create/update GitHub Release for that tag (provenance + changelog).
5. Copy `versions/v0.5.116/install.sh` → `channels/stable/install.sh`.
6. Invalidate CloudFront paths: `/`, `/stable`, `/channels/stable/*`.

Stable promotion is an **intentional button press**, not automatic.
Consider requiring GitHub Environment approval for production safety.

## Rollback

Rollback = re-promote an older version:

```
# stable is currently v0.5.117 (bad)
# run promote-installer.yml with version=v0.5.116
# → copies versions/v0.5.116/install.sh to channels/stable/
# → invalidates CloudFront
# → done in 30 seconds
```

Never mutate `versions/v*`. Only mutate `channels/*`.

## CI Flow

### On every push to `main`:
1. Validate (syntax, shellcheck, tests).
2. Stamp `INSTALLER_VERSION`, commit hash, date.
3. Publish to `channels/latest/install.sh`.
4. Publish to `versions/vX.Y.Z/install.sh` (if version is new/unique).
5. **Do not touch stable.**

### On manual promotion:
1. Pick an existing version.
2. Verify CI passed for that commit.
3. Tag: `installer/vX.Y.Z`.
4. Publish to `channels/stable/install.sh`.
5. Invalidate CDN.
6. Create GitHub Release.

## Installer Metadata

Stamp these into `install.sh` at publish time:

```bash
INSTALLER_VERSION="0.5.116"
INSTALLER_CHANNEL="stable"        # or "latest"
INSTALLER_COMMIT="abc1234"
INSTALLER_DATE="2026-05-01T12:34:00Z"
INSTALLER_REPO_REF="installer/v0.5.116"   # or "main" for latest
```

Banner shows: `Lowkey installer v0.5.116 stable abc1234 2026-05-01`

Telemetry includes: `installer_version`, `installer_channel`, `installer_commit`, `installer_repo_ref`.

## Critical: Downstream Asset Pinning

**Stable is cosmetic unless downstream assets are also pinned.**

Today the installer fetches from `main`:
```bash
TEMPLATE_RAW_URL="https://raw.githubusercontent.com/.../main/deploy/cloudformation/template.yaml"
REPO_URL="https://github.com/inceptionstack/lowkey.git"  # clones main
```

For stable, all raw URLs, git clones, template fetches, and pack resources
must resolve from `INSTALLER_REPO_REF`, not `main`:

```bash
# stable: fetches from tagged ref
TEMPLATE_RAW_URL="https://raw.githubusercontent.com/.../installer/v0.5.116/deploy/..."
# latest: fetches from main
TEMPLATE_RAW_URL="https://raw.githubusercontent.com/.../main/deploy/..."
```

Without this, a "stable" installer wraps unstable downstream content.

## Alternatives Considered

| Approach | Verdict |
|---|---|
| GitHub Releases only (`/releases/latest/download/install.sh`) | Workable but less elegant URLs, weaker cache control |
| Mutable `stable` branch | Easy to accidentally push to, harder audit trail |
| CloudFront redirect to GitHub raw | Still depends on GitHub raw serving reliability |
| Query params (`?channel=latest`) | CDN caching footgun, shell quoting issues |
| Subdomains (`latest.install.lowkey.run`) | More DNS/routing overhead for no real benefit |

## Implementation Checklist

### Infrastructure
- [ ] Create S3 bucket `lowkey-install` (or similar)
- [ ] CloudFront distribution with path-based routing
- [ ] IAM role for CI to publish to S3 + invalidate CloudFront
- [ ] DNS: point `install.lowkey.run` to CloudFront

### CI Workflows
- [ ] `publish-installer.yml` — on push to main: stamp + publish to latest + version
- [ ] `promote-installer.yml` — manual dispatch: copy version to stable + CDN invalidate + tag + release
- [ ] Update existing `version-bump.yml` and `stamp-version.yml` to work with new flow

### Installer Changes
- [ ] Add `INSTALLER_CHANNEL` and `INSTALLER_REPO_REF` variables
- [ ] Replace hardcoded `main` in all raw URLs / git clones with `INSTALLER_REPO_REF`
- [ ] Show channel in banner
- [ ] Include channel in telemetry beacon

### Telemetry Backend
- [ ] Add `installer_channel` and `installer_repo_ref` to install beacon schema
- [ ] Update dashboard to filter/group by channel

### Docs
- [ ] Update `docs/quickstart.mdx` with stable/latest URLs
- [ ] Update `docs/reference/cli.mdx` with version pinning examples
- [ ] Add `docs/reference/installer-channels.mdx`
