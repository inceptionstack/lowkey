/**
 * KiroCrew WebUI Cognito Auth — Lambda@Edge (viewer-request trigger).
 *
 * Validates a Cognito session cookie set by cognito-at-edge. Unauthenticated
 * requests are redirected to the Cognito hosted UI. Requests to /auth/callback
 * exchange the auth code for tokens and set the session cookie.
 *
 * Lambda@Edge constraints:
 *   - No environment variables (config baked in below OR fetched from Secrets Manager)
 *   - Node.js 22.x runtime
 *   - Must be deployed in us-east-1 (enforced by CFN Rule WebUIEdgeRequiresUsEast1)
 *
 * Only CONFIG_SECRET_NAME is substituted at build time. All other config
 * (pool ID, client ID, domain, signing key) is fetched from Secrets Manager
 * on cold start, cached in module scope for warm invocations.
 *
 * This lets us zip the Lambda code BEFORE CFN creates the Cognito pool —
 * the Lambda only needs the secret's name, which is a deterministic function
 * of the stack's environment name.
 */

const { Authenticator } = require('cognito-at-edge');
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require('@aws-sdk/client-secrets-manager');

const CONFIG_SECRET_NAME = '__CONFIG_SECRET_NAME__';
const SECRETS_REGION = 'us-east-1';

const AUTHENTICATOR_CACHE_TTL_MS = 15 * 60 * 1000;
let authenticatorPromise = null;
let authenticatorCacheTimestamp = 0;

async function loadConfig() {
  const sm = new SecretsManagerClient({ region: SECRETS_REGION });
  const resp = await sm.send(new GetSecretValueCommand({ SecretId: CONFIG_SECRET_NAME }));
  const parsed = JSON.parse(resp.SecretString);
  const required = ['poolId', 'clientId', 'cognitoDomain', 'signingKey', 'cognitoRegion'];
  const missing = required.filter((k) => !parsed[k] || typeof parsed[k] !== 'string' || parsed[k] === 'pending');
  if (missing.length > 0) {
    throw new Error(`Edge config secret missing or pending fields: ${missing.join(', ')}`);
  }
  return parsed;
}

async function getAuthenticator() {
  const now = Date.now();
  if (authenticatorPromise && now - authenticatorCacheTimestamp <= AUTHENTICATOR_CACHE_TTL_MS) {
    return authenticatorPromise;
  }
  authenticatorPromise = null;
  authenticatorCacheTimestamp = now;
  authenticatorPromise = (async () => {
    const cfg = await loadConfig();
    return new Authenticator({
      // cognito-at-edge uses this region for JWKS + token validation and
      // Cognito API calls. It must match the region the user pool lives in
      // (which is the main stack's DEPLOY_REGION, NOT us-east-1 where the
      // Lambda@Edge itself is hosted).
      region: cfg.cognitoRegion,
      userPoolId: cfg.poolId,
      userPoolAppId: cfg.clientId,
      userPoolDomain: cfg.cognitoDomain,
      // Must match a CallbackURL registered on the Cognito user pool client
      // in the main-stack template (`/auth/callback`). Without this,
      // cognito-at-edge defaults to `/parseauth`, which Cognito rejects
      // because it's not in the client's CallbackURLs allowlist.
      parseAuthPath: '/auth/callback',
      cookieExpirationDays: 1,
      cookiePath: '/',
      httpOnly: true,
      sameSite: 'Lax',
      disableCookieDomain: true,
      logoutConfiguration: {
        logoutUri: '/logout',
        logoutRedirectUri: '/',
      },
      logLevel: 'warn',
      csrfProtection: {
        nonceSigningSecret: cfg.signingKey,
      },
    });
  })().catch((err) => {
    authenticatorPromise = null;
    authenticatorCacheTimestamp = 0;
    throw err;
  });
  return authenticatorPromise;
}

exports.handler = async (event) => {
  try {
    const auth = await getAuthenticator();
    return auth.handle(event);
  } catch (err) {
    console.error('[edge-auth] handler error:', err && err.message);
    // Fail closed — do NOT forward an unauthenticated request
    return {
      status: '503',
      statusDescription: 'Service Unavailable',
      headers: {
        'content-type': [{ key: 'Content-Type', value: 'text/plain' }],
        'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
      },
      body: 'Auth service temporarily unavailable. Retry in a moment.',
    };
  }
};
