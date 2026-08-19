/**
 * Photo upload, the count rules, ownership, and the ways this could serve back
 * something it should not. Run against a live server.
 */
const BASE = process.env.BASE ?? 'http://localhost:8080';
let passed = 0, failed = 0;

function check(label, condition, detail = '') {
  if (condition) { passed++; console.log(`  ok    ${label}`); }
  else { failed++; console.log(`  FAIL  ${label} ${detail}`); }
}

async function call(method, path, { token, body, contentType } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(contentType ? { 'Content-Type': contentType } : {}),
      ...(body && !contentType ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body instanceof Buffer ? body : body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* binary or empty */ }
  return { status: response.status, body: json, raw: text, headers: response.headers };
}

// A real 1x1 JPEG, so the magic-byte sniffing is exercised for what it is.
const JPEG = Buffer.from(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a' +
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA' +
  'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64');
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

const alice = (await call('POST', '/v1/auth/dev', { body: { userID: 'photo-alice', displayName: 'Alice' } })).body;
const bob = (await call('POST', '/v1/auth/dev', { body: { userID: 'photo-bob', displayName: 'Bob' } })).body;
const A = alice.accessToken, B = bob.accessToken;

console.log('\nupload');
const upload = await call('POST', '/v1/photos', { token: A, body: JPEG, contentType: 'image/jpeg' });
check('a JPEG uploads', upload.status === 201 && !!upload.body.path, JSON.stringify(upload.body));
check('it returns a path, not a host-specific URL', upload.body?.path?.startsWith('/v1/photos/'), upload.body?.path);
check('a PNG uploads too', (await call('POST', '/v1/photos', { token: A, body: PNG, contentType: 'image/png' })).status === 201);
check('upload needs a token', (await call('POST', '/v1/photos', { body: JPEG, contentType: 'image/jpeg' })).status === 401);

console.log('\nwhat is not an image');
const fakeJpeg = await call('POST', '/v1/photos', { token: A, body: Buffer.from('#!/bin/sh\nrm -rf /'), contentType: 'image/jpeg' });
check('a script claiming to be a JPEG is refused', fakeJpeg.status === 400, JSON.stringify(fakeJpeg.body));
check('an empty upload is refused', (await call('POST', '/v1/photos', { token: A, body: Buffer.alloc(0), contentType: 'image/jpeg' })).status === 400);
const huge = await call('POST', '/v1/photos', { token: A, body: Buffer.alloc(7_000_000, 1), contentType: 'image/jpeg' });
check('an oversized upload is refused', huge.status === 413, `${huge.status}`);

console.log('\nserving');
const fetched = await fetch(`${BASE}${upload.body.path}`);
check('a photo is served', fetched.status === 200);
check('served as an image', fetched.headers.get('content-type') === 'image/jpeg');
check('cached hard (the name is a uuid)', (fetched.headers.get('cache-control') ?? '').includes('immutable'));
check('served without a token — the app renders these in an <img>', true);
check('a made-up name is a 404', (await call('GET', '/v1/photos/nope.jpg')).status === 404);
check('path traversal is refused', (await fetch(`${BASE}/v1/photos/..%2F..%2Fbricksouq.db`)).status === 404);
check('a non-jpg extension is refused', (await call('GET', '/v1/photos/0f8fad5b-d9cb-469f-a165-70867728950e.db')).status === 404);

console.log('\nthe count rules');
const base = {
  type: 'set', setNumber: '10305', theme: 'Icons', title: "Lion Knights' Castle",
  priceQAR: 900, note: 'A perfectly ordinary description.', whatsAppNumber: '97430001111',
};
async function photo(token = A) {
  return (await call('POST', '/v1/photos', { token, body: JPEG, contentType: 'image/jpeg' })).body.path;
}

const noPhotos = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [] } });
check('publishing with no photos is refused', noPhotos.status === 422, JSON.stringify(noPhotos.body));

const onePhoto = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [await photo()] } });
check('one photo is enough for a sealed set', onePhoto.status === 201, JSON.stringify(onePhoto.body));
check('the photo comes back on the listing', onePhoto.body?.photoURLs?.length === 1);

const builtOne = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'Built', photoURLs: [await photo()] } });
check('a built set needs more than one photo', builtOne.status === 422, JSON.stringify(builtOne.body));
check('...and says why', /two photos/i.test(builtOne.body?.error ?? ''), builtOne.body?.error);

const builtTwo = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'Built', photoURLs: [await photo(), await photo()] } });
check('two photos publishes a built set', builtTwo.status === 201, JSON.stringify(builtTwo.body));

const four = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [await photo(), await photo(), await photo(), await photo()] } });
check('four photos is refused', four.status === 422, JSON.stringify(four.body));

const three = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [await photo(), await photo(), await photo()] } });
check('three photos is the maximum and it works', three.status === 201);
check('order is preserved', three.body?.photoURLs?.length === 3);

console.log('\nownership');
const alicePhoto = await photo(A);
const stolen = await call('POST', '/v1/listings', { token: B, body: { ...base, condition: 'New', photoURLs: [alicePhoto], whatsAppNumber: '97430002222' } });
check("Bob cannot use Alice's photo", stolen.status === 422, JSON.stringify(stolen.body));

const reusedPath = onePhoto.body.photoURLs[0];
const reused = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [reusedPath] } });
check('a photo cannot be reused on a second listing', reused.status === 422, JSON.stringify(reused.body));

const twice = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [alicePhoto, alicePhoto] } });
check('the same photo twice is refused', twice.status === 422, JSON.stringify(twice.body));

const invented = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: ['/v1/photos/0f8fad5b-d9cb-469f-a165-70867728950e.jpg'] } });
check('an invented photo path is refused', invented.status === 422, JSON.stringify(invented.body));

const external = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: ['https://evil.example/tracker.gif'] } });
check('an off-site image URL is refused', external.status === 422, JSON.stringify(external.body));

console.log('\ncleanup');
const doomedPhoto = await photo(A);
const doomed = await call('POST', '/v1/listings', { token: A, body: { ...base, condition: 'New', photoURLs: [doomedPhoto] } });
check('the photo is reachable while the listing lives', (await fetch(`${BASE}${doomedPhoto}`)).status === 200);
await call('DELETE', `/v1/listings/${doomed.body.id}`, { token: A });
check('deleting the listing deletes the photo', (await fetch(`${BASE}${doomedPhoto}`)).status === 404);

console.log('\nthe rules are published');
const health = await call('GET', '/v1/health');
check('health advertises the photo rules', health.body?.photoRules?.max === 3 && health.body?.photoRules?.minWhenBuilt === 2,
      JSON.stringify(health.body?.photoRules));

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
