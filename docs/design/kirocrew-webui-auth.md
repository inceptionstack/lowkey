# KiroCrew WebUI Authentication — Technical Design

## Overview

When a user selects a pack with a WebUI (currently KiroCrew), the installer offers to protect it with AWS Cognito-based authentication. This flow is **pack-agnostic** — any future pack exposing a web interface can reuse the same function.

## Architecture

```
Browser → KiroCrew WebUI (port 5476)
    ↓ (unauthenticated)
Redirect → Cognito Managed Login (hosted UI)
    ↓ (user authenticates)
Callback → /auth/callback with authorization code
    ↓ (code exchange via PKCE)
KiroCrew validates JWT → grants session
```

### Auth Flow: Authorization Code + PKCE (Recommended)

- **Grant type:** Authorization Code with PKCE (`code_challenge_method=S256`)
- **No client secret** — public client (SPA running in browser)
- **Scopes:** `openid email`
- **Token transport:** Tokens stored in secure httpOnly cookies or session storage (never in URL params beyond the initial callback)
- **Managed Login:** Uses Cognito's hosted UI — no custom login page needed

### Why Managed Login + PKCE (not SRP)

| Concern | Managed Login + PKCE | Custom SRP |
|---------|---------------------|------------|
| Implementation complexity | Low (redirect-based) | High (SDK integration) |
| Server-side enforcement | Standard JWT validation | Same |
| MFA support (future) | Built-in | Manual |
| Custom login UI | Not needed (Cognito hosted) | Required |
| Token refresh | Standard refresh_token grant | Manual |
| Security surface | Proven, AWS-managed | Custom code = custom bugs |

## Security Requirements

### Mandatory (non-negotiable)

1. **No self-registration** — `AdminCreateUserConfig.AllowAdminCreateUserOnly = true`
2. **Server-side JWT validation** on every request:
   - Validate signature against Cognito JWKS (`/.well-known/jwks.json`)
   - Validate `iss` matches pool URL
   - Validate `aud` (client_id) for ID tokens\n   - Validate `exp` (reject expired tokens)
   - Validate `token_use` (`id` vs `access`) per endpoint
   - Fail closed: if validation fails or JWKS unavailable → 401
3. **All API endpoints + WebSocket/SSE connections protected** — not just HTML routes
4. **Explicit unauthenticated allowlist** — only `/health`, `/auth/callback`, `/.well-known/*`
5. **HTTPS required for remote access** — HTTP only permitted for `localhost` / loopback
6. **No tokens in URL query strings** (except the one-time authorization code on callback)
7. **No wildcard callback URLs** — exact match only
8. **CSRF protection** — `state` parameter validated on callback

### Network-gated no-auth option

The `--no-auth` escape hatch is only safe when:
- Access is via SSM port-forward (`localhost:5476`)
- WebUI is behind a VPN/private VPC with restricted SG
- Another upstream auth layer exists (e.g. ALB + Cognito, CloudFront + Lambda@Edge)

If the installer detects the instance has a public IP and no restrictive SG on port 5476, it should **warn strongly** or **refuse** to skip auth.

## Installer Flow

### Function signature

```bash
# Pack-agnostic — any WebUI pack calls this
configure_webui_auth() {
  local pack_name="$1"        # e.g. "kirocrew"
  local webui_port="$2"       # e.g. 5476
  local callback_path="$3"    # e.g. "/auth/callback"
  # ...
}
```

### Step 1: Ask if auth is wanted

```
┌─────────────────────────────────────────────────────┐
│ Protect KiroCrew WebUI with login? (recommended)    │
│                                                     │
│   > Yes — create Cognito login (recommended)        │
│     No  — I'll use SSM port-forward only            │
└─────────────────────────────────────────────────────┘
```

- Default: **Yes**
- `AUTO_YES` mode: Yes (secure by default)
- `--<pack>-no-auth` flag: Skip (user takes responsibility)
- If "No" selected and public exposure detected: show strong warning, require explicit confirmation

### Step 2: Choose or create user pool

```
┌─────────────────────────────────────────────────────┐
│ Cognito user pool                                   │
│                                                     │
│   > Create new pool (recommended)                   │
│     Use existing pool: my-pool-1                    │
│     Use existing pool: dev-auth-pool                │
└─────────────────────────────────────────────────────┘
```

- `aws cognito-idp list-user-pools --max-results 20`
- If 0 existing pools → skip picker, auto-create
- `AUTO_YES` mode: always create new

#### New pool configuration

```bash
aws cognito-idp create-user-pool \
  --pool-name "lowkey-${pack_name}-${ENV_NAME}" \
  --policies '{
    "PasswordPolicy": {
      "MinimumLength": 12,
      "RequireUppercase": true,
      "RequireLowercase": true,
      "RequireNumbers": true,
      "RequireSymbols": true,
      "TemporaryPasswordValidityDays": 1
    }
  }' \
  --admin-create-user-config '{
    "AllowAdminCreateUserOnly": true
  }' \
  --auto-verified-attributes email \
  --username-attributes email \
  --schema '[
    {"Name":"email","Required":true,"Mutable":true}
  ]' \
  --user-pool-tags '{
    "loki:managed": "true",
    "loki:pack": "'"${pack_name}"'",
    "loki:env": "'"${ENV_NAME}"'"
  }'
```

#### App client (created for BOTH new and existing pools)

```bash
aws cognito-idp create-user-pool-client \
  --user-pool-id "${POOL_ID}" \
  --client-name "${pack_name}-webui" \
  --no-generate-secret \
  --explicit-auth-flows ALLOW_USER_SRP_AUTH ALLOW_REFRESH_TOKEN_AUTH \
  --supported-identity-providers COGNITO \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email \
  --callback-urls "[\"${CALLBACK_URL}\"]" \
  --logout-urls "[\"${LOGOUT_URL}\"]" \
  --prevent-user-existence-errors ENABLED \
  --token-validity-units '{
    "AccessToken": "hours",
    "IdToken": "hours",
    "RefreshToken": "days"
  }' \
  --access-token-validity 1 \
  --id-token-validity 1 \
  --refresh-token-validity 30
```

#### Cognito domain (required for Managed Login)

```bash
aws cognito-idp create-user-pool-domain \
  --user-pool-id "${POOL_ID}" \
  --domain "lowkey-${pack_name}-${UNIQUE_SUFFIX}"
```

### Step 3: Determine callback URL

- **Local/tunnel access:** `http://localhost:${webui_port}${callback_path}`
- **Remote/ALB access:** `https://${DOMAIN}${callback_path}`
- Installer detects based on whether CloudFront/ALB is configured for this pack
- Both can be registered as callback URLs if both access paths exist

### Step 4: Create initial user

```
┌─────────────────────────────────────────────────────┐
│ Email for WebUI login:                              │
│ > roy@example.com                                   │
└─────────────────────────────────────────────────────┘
```

- Validate: basic email regex (`[^@]+@[^@]+\.[^@]+`)
- `AUTO_YES` mode: require `--webui-email <email>` flag or fail with clear message
- Generate password: 16 chars, cryptographically random (mixed case + digits + symbols)

```bash
# Generate secure random password
WEBUI_PASSWORD=$(python3 -c "
import secrets, string
alphabet = string.ascii_letters + string.digits + '!@#$%&*'
print(''.join(secrets.choice(alphabet) for _ in range(16)))
")

# Create user with permanent password (skip force-change-password)
aws cognito-idp admin-create-user \
  --user-pool-id "${POOL_ID}" \
  --username "${USER_EMAIL}" \
  --user-attributes Name=email,Value="${USER_EMAIL}" Name=email_verified,Value=true \
  --message-action SUPPRESS  # Don't send welcome email

aws cognito-idp admin-set-user-password \
  --user-pool-id "${POOL_ID}" \
  --username "${USER_EMAIL}" \
  --password "${WEBUI_PASSWORD}" \
  --permanent
```

### Step 5: Pass config to pack

Export for pack's `install.sh` to consume:

```bash
export WEBUI_AUTH_ENABLED="true"
export WEBUI_COGNITO_POOL_ID="${POOL_ID}"
export WEBUI_COGNITO_CLIENT_ID="${CLIENT_ID}"
export WEBUI_COGNITO_DOMAIN="${COGNITO_DOMAIN}"
export WEBUI_COGNITO_REGION="${DEPLOY_REGION}"
export WEBUI_CALLBACK_URL="${CALLBACK_URL}"
export WEBUI_LOGOUT_URL="${LOGOUT_URL}"
```

The pack installer writes these to its `.env` or config file.

### Step 6: Output summary

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ WebUI protected with Cognito

  Login:    roy@example.com
  Password: Xk9#mP2vR8$nL4wQ

  ⚠  Save these credentials now — the password
     will not be shown again.

  Pool:     lowkey-kirocrew-env-1-3847
  Region:   us-east-1
  Login UI: https://lowkey-kirocrew-3847.auth.us-east-1.amazoncognito.com
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Pack-Side Enforcement (KiroCrew gateway responsibility)

The installer provisions Cognito. The **pack** (KiroCrew) must enforce:

1. **Middleware/filter** on all routes except allowlisted paths
2. **JWKS caching** with periodic refresh (respect `Cache-Control` from Cognito)
3. **Token validation** per the mandatory requirements above
4. **Session management** — exchange auth code for tokens on callback, set httpOnly cookie
5. **Logout** — clear session, redirect to Cognito logout endpoint
6. **WebSocket auth** — validate token on connection upgrade, not just initial page load

### Minimal enforcement pseudocode

```python
# On every request (except /health, /auth/callback):
token = extract_token(request)  # from cookie or Authorization header
if not token:
    redirect_to_cognito_login()

claims = validate_jwt(token, jwks_url, expected_client_id)
if not claims:
    return 401

# Proceed with request
```

## CLI Flags (new)

| Flag | Description | Default |
|------|-------------|---------|
| `--webui-email <email>` | Pre-set email for non-interactive auth setup | (required if `AUTO_YES` + auth) |
| `--webui-no-auth` | Skip Cognito setup entirely | `false` |
| `--webui-pool-id <id>` | Use specific existing pool (skip picker) | (none) |

## Edge Cases

| Scenario | Handling |
|----------|----------|
| 0 existing pools | Skip picker, auto-create |
| >20 pools in account | Show first 20, note truncation |
| Pool creation fails (IAM) | Clear error with required permissions list |
| Existing pool has self-signup enabled | Warn user, offer to disable or pick different pool |
| Email already exists in pool | `admin-create-user` fails → catch, offer to reset password |
| Instance has public IP + no auth | Strong warning, require explicit `--webui-no-auth` |
| `AUTO_YES` without `--webui-email` | Fail with clear message about required flag |
| KiroCrew doesn't support Cognito yet | Fail with clear error: "Pack does not support WebUI auth yet. Remove --webui-auth or wait for pack update." Never report "protected" without verified enforcement. |
| Domain prefix collision | Append random suffix, retry once |

## Cognito Resource Cleanup

All resources tagged for discovery by uninstaller:

```json
{
  "loki:managed": "true",
  "loki:pack": "<pack-name>",
  "loki:env": "<env-name>"
}
```

Uninstall flow:
1. Find pools by tag
2. Delete app client
3. Delete domain
4. Delete user pool
5. (Or offer to keep if user wants to reuse credentials)

## Future Extensibility

- **MFA:** Add TOTP MFA by updating pool config + app client (`MfaConfiguration: OPTIONAL`)
- **Multiple users:** `admin-create-user` can be called multiple times post-install
- **Custom domain:** `create-user-pool-domain --custom-domain-config` with ACM cert
- **SSO/SAML:** Add external IdP to pool for enterprise federation
- **Other packs:** Any pack with `webui: true` in registry.json calls `configure_webui_auth "$PACK_NAME" "$PORT" "$CALLBACK_PATH"`

## Implementation Checklist

- [ ] Add `configure_webui_auth()` function to `install.sh`
- [ ] Call from `collect_config_simple()` when pack has WebUI
- [ ] Call from `collect_config_advanced()` (same trigger)
- [ ] Add `--webui-email`, `--webui-no-auth`, `--webui-pool-id` CLI flags + arg parsing
- [ ] Add `webui` field to `registry.json` pack schema (port + callback_path)
- [ ] Update KiroCrew pack `install.sh` to consume `WEBUI_*` env vars
- [ ] KiroCrew gateway: implement JWT middleware (separate PR on KiroCrew repo)
- [ ] Update uninstaller to handle Cognito cleanup
- [ ] Add telemetry events: `install.webui_auth_configured`
