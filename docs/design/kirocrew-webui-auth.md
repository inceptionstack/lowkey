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
  --allowed-o-auth-flows code --allowed-o-auth-flows-user-pool-client \
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
# Generate secure random password (guaranteed to satisfy all character classes)
WEBUI_PASSWORD=$(python3 -c "
import secrets, string
# Guarantee at least one of each required class
upper = secrets.choice(string.ascii_uppercase)
lower = secrets.choice(string.ascii_lowercase)
digit = secrets.choice(string.digits)
symbol = secrets.choice('!@#\$%&*')
remainder = [secrets.choice(string.ascii_letters + string.digits + '!@#\$%&*') for _ in range(12)]
password = [upper, lower, digit, symbol] + remainder
secrets.SystemRandom().shuffle(password)
print(''.join(password))
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

---

# Lambda@Edge Enforcement (v2)

**Status:** Design phase. Ships in follow-up PR after PR #85.

## Problem With v1

The v1 design (PR #82, #83) creates the Cognito pool, client, domain, and initial user, but **nothing actually enforces authentication on the CloudFront request path**. Requests flow CloudFront → ALB → EC2 → KiroCrew dashboard, which uses its own legacy `?token=<jwt>` query-param scheme. The Cognito resources exist but are unused.

## Solution: Lambda@Edge on the CloudFront Distribution

Lambda@Edge (viewer-request trigger) intercepts every request to the CloudFront distribution, validates a Cognito session cookie, and redirects unauthenticated users to Cognito hosted UI. Uses the AWS-published `cognito-at-edge` library.

## Architecture

```
Browser
   │
   ▼
CloudFront (KiroCrewDistribution)
   │  ┌─────────────────────────────┐
   ├──│ Viewer-Request Lambda@Edge  │ ← every request goes through here
   │  │  (cognito-at-edge)          │
   │  └─────────────────────────────┘
   │     │
   │     ├─ Has valid session cookie? ──► forward to ALB origin
   │     │
   │     ├─ Path is /auth/callback? ──► exchange code for tokens, set cookie, redirect to /
   │     │
   │     └─ No session? ──► 302 → Cognito hosted UI login
   │
   ▼
ALB → EC2 → KiroCrew dashboard
```

## Constraints (Lambda@Edge Specifics)

- **Runtime**: Node.js 18.x (has AWS SDK v3 pre-installed, saves package size).
- **Region**: Function MUST live in `us-east-1` (CloudFront requirement). Executes replicated at every edge location.
- **No environment variables**. Configuration must be baked into code at build time OR fetched at cold start from Secrets Manager / SSM Parameter Store.
- **No VPC access.** Fine — Cognito is public API.
- **50 MB unzipped package limit.** `cognito-at-edge` + deps ≈ 2 MB — well under.
- **Cold-start budget**: <500 ms for viewer-request. Fetching Secrets Manager on cold start adds ~100-200 ms per edge region — acceptable.
- **Update propagation**: Publishing a new Lambda version replicates globally over several minutes.

## Build & Deploy Flow

```
1. Installer (install.sh):
   a. cd packs/kirocrew/webui-auth-edge/
   b. npm install --production
   c. Substitute placeholders in index.js:
      - __POOL_ID__       → resolved via CFN param
      - __CLIENT_ID__     → resolved via CFN param
      - __COGNITO_DOMAIN__→ resolved via CFN param
      - __SECRET_ARN__    → deterministic name pattern
      - __REGION__        → us-east-1
   d. zip -r edge-lambda-<sha>.zip .
   e. aws s3 cp edge-lambda-<sha>.zip s3://<install-bucket>/edge/edge-lambda-<sha>.zip
   f. Pass S3 bucket + key as CFN parameters:
      - EdgeLambdaS3Bucket
      - EdgeLambdaS3Key

2. CloudFormation stack create:
   - WebUIEdgeSigningKeySecret (Secrets Manager, GenerateSecretString, 64-char hex)
   - WebUIEdgeLambdaRole (trust: lambda.amazonaws.com + edgelambda.amazonaws.com)
   - WebUIEdgeLambdaFunction (Code.S3Bucket/S3Key, Runtime nodejs18.x, us-east-1)
   - WebUIEdgeLambdaVersion (needed for association)
   - Update KiroCrewDistribution: add LambdaFunctionAssociations[viewer-request]
   - Update WebUIUserPoolClient: callback URLs already correct (from v1)

3. Cold start on first request:
   - Lambda fetches signing key from Secrets Manager via IAM role
   - Caches in module scope for subsequent invocations at same edge
```

## Signing Key Handling

- Stored in `AWS::SecretsManager::Secret` with `GenerateSecretString` (64-char hex, alphanumeric).
- Secret ARN is deterministic: `arn:aws:secretsmanager:us-east-1:<account>:secret:/lowkey/<env>/webui-edge-signing-key`. Baked into Lambda code at build time.
- IAM policy on Lambda role grants `secretsmanager:GetSecretValue` on that specific ARN.
- Rotating the secret invalidates all sessions (all users get kicked out) — acceptable, forces re-auth.

## Handler Code (skeleton)

```javascript
// packs/kirocrew/webui-auth-edge/index.js
import { Authenticator } from 'cognito-at-edge';
import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';

const REGION = 'us-east-1';
const POOL_ID = '__POOL_ID__';
const CLIENT_ID = '__CLIENT_ID__';
const COGNITO_DOMAIN = '__COGNITO_DOMAIN__';
const SECRET_ARN = '__SECRET_ARN__';

let authenticatorPromise = null;

async function getAuthenticator() {
  if (authenticatorPromise) return authenticatorPromise;
  authenticatorPromise = (async () => {
    const sm = new SecretsManagerClient({ region: REGION });
    const resp = await sm.send(new GetSecretValueCommand({ SecretId: SECRET_ARN }));
    const signingKey = JSON.parse(resp.SecretString).key;
    return new Authenticator({
      region: REGION,
      userPoolId: POOL_ID,
      userPoolAppId: CLIENT_ID,
      userPoolDomain: COGNITO_DOMAIN,
      cookieExpirationDays: 1,
      logLevel: 'warn',
      // cognito-at-edge signs its nonce/state with a key derived from client-secret;
      // since we use no-secret public clients, we pass a shared signing seed here:
      cookieSettings: { idToken: null, accessToken: null, refreshToken: null },
    });
  })();
  return authenticatorPromise;
}

export const handler = async (event) => {
  const auth = await getAuthenticator();
  return auth.handle(event);
};
```

## Cost Impact

- Lambda@Edge: $0.60 / 1M requests + $0.00005001 / GB-sec. Typical dashboard use = <10k req/mo → <$0.01/mo.
- Secrets Manager: $0.40 / secret / mo + $0.05 / 10k API calls. One secret + <100 cold starts/mo → $0.40/mo.
- CloudWatch Logs (edge): pennies.
- **Total: ~$0.40-0.50/mo per deployment.**

## Rollback

If Lambda@Edge causes issues, remove the `LambdaFunctionAssociations` block from the CloudFront distribution — takes ~15 min to fully propagate. CloudFront falls back to unauthenticated forwarding (same as v1 today).

## Deferred / Out-of-Scope

- **Logout**: cognito-at-edge doesn't handle logout natively. User must clear cookies OR visit `https://<cognito-domain>/logout?client_id=X&logout_uri=Y`. Follow-up work: add `/logout` path handler in Lambda@Edge.
- **Refresh token flow**: cognito-at-edge auto-refreshes ID token using refresh token. Works out of the box.
- **CSRF**: cognito-at-edge handles state param + PKCE. Verified against upstream code.
- **Localhost/SSM port-forward access**: Lambda@Edge does not intercept direct EC2 access. If users port-forward `localhost:5476`, they hit the dashboard's own `?token` auth. Acceptable — SSM is already authenticated.

## Implementation Checklist

- [ ] `packs/kirocrew/webui-auth-edge/` directory with `package.json`, `index.js`, `build.sh`
- [ ] `install.sh`: npm install + zip + S3 upload before CFN deploy
- [ ] `install.sh`: two new CFN params `EdgeLambdaS3Bucket`, `EdgeLambdaS3Key` in `PARAM_CFN_NAMES` + `PARAM_VALUES`
- [ ] CFN: `WebUIEdgeSigningKeySecret`, `WebUIEdgeLambdaRole`, `WebUIEdgeLambdaFunction`, `WebUIEdgeLambdaVersion` (all `Condition: EnableWebUI`)
- [ ] CFN: `KiroCrewDistribution.DistributionConfig.DefaultCacheBehavior.LambdaFunctionAssociations` = viewer-request → new function version
- [ ] CFN outputs: `WebUIEdgeFunctionArn`, `WebUIEdgeSigningKeySecretArn`
- [ ] Validate template, `bash -n install.sh`, deploy test stack
