/**
 * KiroCrew WebUI Cognito Auth — Lambda@Edge (viewer-request trigger).
 *
 * Validates a Cognito session cookie set by cognito-at-edge. Unauthenticated
 * requests are redirected to Cognito hosted UI. Requests to /auth/callback
 * exchange the auth code for tokens and set the session cookie.
 *
 * Lambda@Edge constraints:
 *   - No environment variables (config baked in below OR fetched from Secrets Manager)
 *   - Node.js 18.x runtime
 *   - Must be deployed in us-east-1
 *
 * Only SECRET_ARN is substituted at build time. All other config (pool ID,
 * client ID, domain, signing key) is fetched from Secrets Manager on cold
 * start, cached in module scope for warm invocations.
 *
 * This lets us zip the Lambda code BEFORE CFN creates the Cognito pool —
 * the Lambda only needs the secret's ARN, which is a deterministic function
 * of the stack's environment name.
 */

const { Authenticator } = require('cognito-at-edge');
const {
  SecretsManagerClient,
  GetSecretValueCommand,
} = require('@aws-sdk/client-secrets-manager');

// Only placeholder replaced at build time. All other config comes from the secret.
const SECRET_ARN = '__SECRET_NAME__';
const REGION = 'us-east-1';

let authenticatorPromise = null;

async function loadConfig() {
  const sm = new SecretsManagerClient({ region: REGION });
  const resp = await sm.send(new GetSecretValueCommand({ SecretId: SECRET_ARN }));
  const parsed = JSON.parse(resp.SecretString);
  const required = ['poolId', 'clientId', 'cognitoDomain', 'signingKey'];
  for (const k of required) {
    if (!parsed[k] || typeof parsed[k] !== 'string') {
      throw new Error(`Edge auth secret is missing required field: ${k}`);
    }
  }
  return parsed;
}

async function getAuthenticator() {
  if (authenticatorPromise) return authenticatorPromise;
  authenticatorPromise = (async () => {
    const cfg = await loadConfig();
    return new Authenticator({
      region: REGION,
      userPoolId: cfg.poolId,
      userPoolAppId: cfg.clientId,
      userPoolDomain: cfg.cognitoDomain,
      cookieExpirationDays: 1,
      disableCookieDomain: true,
      logLevel: 'warn',
      cookieCompatibility: 'amplify',
      nonceSigningSecret: cfg.signingKey,
    });
  })().catch((err) => {
    // Reset so the next cold-start attempt can retry
    authenticatorPromise = null;
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
