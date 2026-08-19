// Stands up a fake Apple: a real RSA key, real signatures, real JWKS responses.
// Verifies both that a good token passes and that each tampered token is refused.
import { generateKeyPairSync, createSign, createHash } from 'node:crypto';
import assert from 'node:assert/strict';

process.env.APPLE_BUNDLE_ID = 'doody.lego';

const { publicKey, privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'test-kid', alg: 'RS256', use: 'sig' };

globalThis.fetch = async (url) => {
  assert.equal(url, 'https://appleid.apple.com/auth/keys');
  return { ok: true, status: 200, json: async () => ({ keys: [jwk] }) };
};

const { verifyIdentityToken, AppleAuthError } = await import('../lib/apple.js');

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const sha256Hex = (v) => createHash('sha256').update(v).digest('hex');

function makeToken(claimOverrides = {}, headerOverrides = {}, { corrupt = false } = {}) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', kid: 'test-kid', ...headerOverrides };
  const claims = {
    iss: 'https://appleid.apple.com',
    aud: 'doody.lego',
    sub: '001234.abcdef.1234',
    iat: nowSeconds,
    exp: nowSeconds + 600,
    nonce: sha256Hex('the-raw-nonce'),
    email: 'someone@privaterelay.appleid.com',
    email_verified: 'true',
    ...claimOverrides,
  };
  const input = `${b64(header)}.${b64(claims)}`;
  const signer = createSign('RSA-SHA256');
  signer.update(input);
  signer.end();
  let signature = signer.sign(privateKey);
  if (corrupt) signature = Buffer.concat([signature.subarray(0, signature.length - 1), Buffer.from([signature.at(-1) ^ 0xff])]);
  return `${input}.${signature.toString('base64url')}`;
}

async function rejects(label, token, rawNonce, expectedFragment) {
  await assert.rejects(
    () => verifyIdentityToken(token, rawNonce),
    (error) => {
      assert.ok(error instanceof AppleAuthError, `${label}: wrong error type`);
      assert.match(error.message, expectedFragment, `${label}: ${error.message}`);
      return true;
    },
    label
  );
  console.log(`  ok   rejects ${label}`);
}

// The happy path.
const claims = await verifyIdentityToken(makeToken(), 'the-raw-nonce');
assert.equal(claims.sub, '001234.abcdef.1234');
assert.equal(claims.email, 'someone@privaterelay.appleid.com');
assert.equal(claims.emailVerified, true);
console.log('  ok   accepts a genuine token');

// The attacks.
await rejects('a forged signature', makeToken({}, {}, { corrupt: true }), 'the-raw-nonce', /signature is not valid/);
await rejects('alg:none downgrade', `${b64({ alg: 'none', kid: 'test-kid' })}.${b64({ sub: 'x' })}.`, 'the-raw-nonce', /Unexpected token algorithm/);
await rejects('an unknown signing key', makeToken({}, { kid: 'not-apples-key' }), 'the-raw-nonce', /unknown Apple key/);
await rejects('a token for another app', makeToken({ aud: 'com.someone.else' }), 'the-raw-nonce', /not doody.lego/);
await rejects('a token from another issuer', makeToken({ iss: 'https://evil.example' }), 'the-raw-nonce', /not issued by Apple/);
await rejects('an expired token', makeToken({ exp: Math.floor(Date.now() / 1000) - 60 }), 'the-raw-nonce', /expired/);
await rejects('a replayed token (nonce mismatch)', makeToken(), 'a-different-nonce', /Nonce does not match/);
await rejects('a token with no nonce', makeToken({ nonce: undefined }), 'the-raw-nonce', /no nonce/);
await rejects('garbage', 'not-a-jwt', 'the-raw-nonce', /Malformed/);

console.log('\napple.test.js — all 10 checks passed');
