import { createHash, createPublicKey, createSign, verify as cryptoVerify } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { config } from './config.js';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_KEYS_URL = 'https://appleid.apple.com/auth/keys';
const APPLE_REVOKE_URL = 'https://appleid.apple.com/auth/revoke';
const APPLE_TOKEN_URL = 'https://appleid.apple.com/auth/token';

export class AppleAuthError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AppleAuthError';
  }
}

// Apple rotates these keys, so they cannot be hardcoded, and they must not be
// re-fetched on every sign-in either.
let keyCache = { keys: null, fetchedAt: 0 };
const KEY_TTL_MS = 60 * 60 * 1000;

async function appleSigningKeys(forceRefresh = false) {
  const stale = Date.now() - keyCache.fetchedAt > KEY_TTL_MS;
  if (keyCache.keys && !stale && !forceRefresh) return keyCache.keys;

  const response = await fetch(APPLE_KEYS_URL);
  if (!response.ok) {
    if (keyCache.keys) return keyCache.keys; // survive a blip on Apple's side
    throw new AppleAuthError(`Could not fetch Apple's public keys (${response.status}).`);
  }
  const body = await response.json();
  keyCache = { keys: body.keys, fetchedAt: Date.now() };
  return body.keys;
}

function base64urlToBuffer(value) {
  return Buffer.from(value.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function decodeSegment(segment) {
  return JSON.parse(base64urlToBuffer(segment).toString('utf8'));
}

export function sha256Hex(value) {
  return createHash('sha256').update(value).digest('hex');
}

/**
 * Verify an Apple identity token properly: signature against Apple's published keys,
 * then every claim that matters.
 *
 * Decoding the token and trusting what is inside is NOT verification — the payload is
 * plain base64, anyone can write one that says they are anyone. The signature check is
 * the whole point.
 *
 * @param {string} identityToken JWT from ASAuthorizationAppleIDCredential.identityToken
 * @param {string} rawNonce      the unhashed nonce the app generated for this attempt
 */
export async function verifyIdentityToken(identityToken, rawNonce) {
  const parts = String(identityToken ?? '').split('.');
  if (parts.length !== 3) throw new AppleAuthError('Malformed identity token.');

  const [headerSegment, payloadSegment, signatureSegment] = parts;

  let header;
  try {
    header = decodeSegment(headerSegment);
  } catch {
    throw new AppleAuthError('Malformed identity token header.');
  }
  if (header.alg !== 'RS256') {
    throw new AppleAuthError(`Unexpected token algorithm ${header.alg}.`);
  }

  let keys = await appleSigningKeys();
  let jwk = keys.find((key) => key.kid === header.kid);
  if (!jwk) {
    // Key rotated since we last looked.
    keys = await appleSigningKeys(true);
    jwk = keys.find((key) => key.kid === header.kid);
  }
  if (!jwk) throw new AppleAuthError('Token was signed with an unknown Apple key.');

  const publicKey = createPublicKey({ key: jwk, format: 'jwk' });
  const signedContent = Buffer.from(`${headerSegment}.${payloadSegment}`, 'utf8');
  const signature = base64urlToBuffer(signatureSegment);

  if (!cryptoVerify('RSA-SHA256', signedContent, publicKey, signature)) {
    throw new AppleAuthError('Identity token signature is not valid.');
  }

  const claims = decodeSegment(payloadSegment);

  if (claims.iss !== APPLE_ISSUER) {
    throw new AppleAuthError('Identity token was not issued by Apple.');
  }

  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audience.includes(config.appleBundleID)) {
    throw new AppleAuthError(
      `Identity token is for ${audience.join(', ')}, not ${config.appleBundleID}.`
    );
  }

  const nowSeconds = Math.floor(Date.now() / 1000);
  if (typeof claims.exp !== 'number' || claims.exp <= nowSeconds) {
    throw new AppleAuthError('Identity token has expired.');
  }
  // 5 minutes of slack for clock drift between the phone and this machine.
  if (typeof claims.iat === 'number' && claims.iat > nowSeconds + 300) {
    throw new AppleAuthError('Identity token was issued in the future.');
  }

  // The nonce binds this token to this sign-in attempt. Without the check, a token
  // captured from another session can be replayed against yours.
  //
  // AuthManager sends request.nonce = sha256Hex(rawNonce), and Apple echoes exactly
  // what it was given, so that hex digest is what should come back.
  if (!claims.nonce) throw new AppleAuthError('Identity token has no nonce.');
  if (!rawNonce) throw new AppleAuthError('Sign-in request did not include a nonce.');
  if (claims.nonce !== sha256Hex(rawNonce)) {
    throw new AppleAuthError('Nonce does not match this sign-in attempt.');
  }

  return {
    sub: claims.sub,
    email: claims.email ?? null,
    emailVerified: claims.email_verified === true || claims.email_verified === 'true',
    isPrivateEmail: claims.is_private_email === true || claims.is_private_email === 'true',
  };
}

// MARK: - Revocation

function isRevocationConfigured() {
  return Boolean(config.appleTeamID && config.appleKeyID && config.applePrivateKeyPath);
}

/**
 * Apple's revoke endpoint authenticates with a client secret that is itself a JWT,
 * signed ES256 with the .p8 key you download from the developer portal.
 */
function clientSecret() {
  const privateKey = readFileSync(config.applePrivateKeyPath, 'utf8');
  const issuedAt = Math.floor(Date.now() / 1000);

  const header = { alg: 'ES256', kid: config.appleKeyID };
  const payload = {
    iss: config.appleTeamID,
    iat: issuedAt,
    exp: issuedAt + 300,
    aud: APPLE_ISSUER,
    sub: config.appleBundleID,
  };

  const encode = (object) => Buffer.from(JSON.stringify(object)).toString('base64url');
  const signingInput = `${encode(header)}.${encode(payload)}`;

  const signer = createSign('SHA256');
  signer.update(signingInput);
  signer.end();
  const signature = signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' });

  return `${signingInput}.${signature.toString('base64url')}`;
}

/**
 * Guideline 5.1.1(v): deleting your own database row is not enough. If the user signed
 * in with Apple you must also tell Apple to forget the connection, and reviewers check.
 *
 * Returns a short status string rather than throwing — a revocation failure must not
 * leave a user unable to delete their account.
 */
export async function revokeAppleUser({ refreshToken, authorizationCode }) {
  if (!isRevocationConfigured()) {
    console.warn(
      '[apple] Skipping token revocation: APPLE_TEAM_ID / APPLE_KEY_ID / ' +
      'APPLE_PRIVATE_KEY_PATH are not set. Required before you ship.'
    );
    return 'skipped-not-configured';
  }

  let token = refreshToken;
  let tokenTypeHint = 'refresh_token';

  try {
    // A refresh token is what Apple wants. If all we kept was the one-shot
    // authorization code, exchange it first.
    if (!token && authorizationCode) {
      const exchange = await fetch(APPLE_TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: config.appleBundleID,
          client_secret: clientSecret(),
          code: authorizationCode,
          grant_type: 'authorization_code',
        }),
      });
      const exchanged = await exchange.json();
      if (!exchange.ok) {
        console.warn('[apple] Code exchange failed:', exchanged);
        return `exchange-failed:${exchanged.error ?? exchange.status}`;
      }
      token = exchanged.refresh_token ?? exchanged.access_token;
      tokenTypeHint = exchanged.refresh_token ? 'refresh_token' : 'access_token';
    }

    if (!token) return 'skipped-no-token';

    const response = await fetch(APPLE_REVOKE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: config.appleBundleID,
        client_secret: clientSecret(),
        token,
        token_type_hint: tokenTypeHint,
      }),
    });

    if (response.status === 200) return 'revoked';
    console.warn('[apple] Revocation failed:', response.status, await response.text());
    return `revoke-failed:${response.status}`;
  } catch (error) {
    console.warn('[apple] Revocation error:', error.message);
    return `revoke-error:${error.message}`;
  }
}
