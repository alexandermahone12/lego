/**
 * End-to-end test against a running server.
 *   node server.js &   then   node test/api.test.js
 * Exercises the happy paths and, more importantly, the rules: ownership, blocking,
 * moderation, validation, and what an unauthenticated caller can reach.
 */
const BASE = process.env.BASE ?? 'http://localhost:8080';
const ADMIN = process.env.ADMIN_TOKEN ?? 'test-admin-token';

let passed = 0, failed = 0;

function check(label, condition, detail = '') {
  if (condition) { passed++; console.log(`  ok    ${label}`); }
  else { failed++; console.log(`  FAIL  ${label} ${detail}`); }
}

async function call(method, path, { token, body } = {}) {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not json */ }
  return { status: response.status, body: json, raw: text };
}

// Every listing needs at least one photo now, and a photo can only be used once.
const JPEG = Buffer.from(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a' +
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA' +
  'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==', 'base64');

async function newPhoto(token) {
  const response = await fetch(`${BASE}/v1/photos`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'image/jpeg' },
    body: JPEG,
  });
  return (await response.json()).path;
}

console.log('\nauth');
const alice = await call('POST', '/v1/auth/dev', { body: { userID: 'alice', displayName: 'Alice', whatsAppNumber: '97430000001' } });
const bob   = await call('POST', '/v1/auth/dev', { body: { userID: 'bob', displayName: 'Bob', whatsAppNumber: '97430000002' } });
check('dev sign-in returns a session', alice.status === 200 && !!alice.body.accessToken, JSON.stringify(alice.body));
check('sign-in returns the user', alice.body?.user?.displayName === 'Alice');
const A = alice.body.accessToken, B = bob.body.accessToken;

check('/v1/me needs a token', (await call('GET', '/v1/me')).status === 401);
check('/v1/me rejects a made-up token', (await call('GET', '/v1/me', { token: 'not-a-real-token' })).status === 401);
check('/v1/me works with a real token', (await call('GET', '/v1/me', { token: A })).body?.id === 'alice');

const refreshed = await call('POST', '/v1/auth/refresh', { body: { refreshToken: alice.body.refreshToken } });
check('refresh issues a new session', refreshed.status === 200 && refreshed.body.accessToken !== A);
check('a used refresh token is dead', (await call('POST', '/v1/auth/refresh', { body: { refreshToken: alice.body.refreshToken } })).status === 401);
const A2 = refreshed.body.accessToken;

console.log('\nreal Apple sign-in');
const forged = await call('POST', '/v1/auth/apple', { body: { identityToken: 'aaa.bbb.ccc', rawNonce: 'whatever' } });
check('a forged Apple token is refused', forged.status === 401, JSON.stringify(forged.body));
check('missing nonce is refused', (await call('POST', '/v1/auth/apple', { body: { identityToken: 'aaa.bbb.ccc' } })).status === 400);

console.log('\npublishing');
const publish = await call('POST', '/v1/listings', { token: A2, body: {
  type: 'set', setNumber: '10281', theme: 'Botanicals', title: 'Bonsai Tree',
  condition: 'New', completeness: 8, includesInstructions: true,
  priceQAR: 180, note: 'Sealed, bought as a gift and never given.', whatsAppNumber: '97430000001',
  photoURLs: [await newPhoto(A2)],
}});
check('publishing works', publish.status === 201, JSON.stringify(publish.body));
check('the server assigns the seller', publish.body?.sellerID === 'alice');
check('the server fills in the seller name', publish.body?.sellerName === 'Alice');
check('a new listing is live', publish.body?.moderationStatus === 'live');
const listingID = publish.body?.id;

const spoof = await call('POST', '/v1/listings', { token: A2, body: {
  type: 'set', theme: 'Icons', title: 'Spoofed', condition: 'New', priceQAR: 10,
  note: 'Trying to post as someone else.', whatsAppNumber: '97430000001',
  sellerID: 'bob', sellerName: 'Bob', sellerTrades: 9999, isSold: true,
  photoURLs: [await newPhoto(A2)],
}});
check('a client cannot choose its own sellerID', spoof.body?.sellerID === 'alice');
check('a client cannot inflate its trade count', spoof.body?.sellerTrades === 0);
check('a client cannot publish something pre-sold', spoof.body?.isSold === false);

const noPhoto = await call('POST', '/v1/listings', { token: A2, body: {
  type: 'set', theme: 'Icons', title: 'No photos', condition: 'New', priceQAR: 100,
  note: 'A description with no photo attached.', whatsAppNumber: '97430000001',
}});
check('publishing without a photo is refused', noPhoto.status === 422, JSON.stringify(noPhoto.body));

check('publishing needs a token', (await call('POST', '/v1/listings', { body: { type: 'set', theme: 'Icons', title: 'x', condition: 'New', priceQAR: 1, note: 'x', whatsAppNumber: '97430000001' } })).status === 401);

console.log('\nvalidation');
const cases = [
  ['a bogus condition', { condition: 'Excellent' }],
  ['a bogus type', { type: 'spaceship' }],
  ['a negative price', { priceQAR: -50 }],
  ['a non-integer price', { priceQAR: 'free' }],
  ['an empty note', { note: '   ' }],
  ['an undialable phone number', { whatsAppNumber: '123' }],
  ['completeness out of range', { completeness: 99 }],
];
const base = { type: 'set', theme: 'Icons', title: 'Test', condition: 'New', priceQAR: 100, note: 'A real note.', whatsAppNumber: '97430000001' };
for (const [label, override] of cases) {
  const result = await call('POST', '/v1/listings', { token: A2, body: { ...base, ...override } });
  check(`refuses ${label}`, result.status === 400, `got ${result.status}`);
}

console.log('\nmoderation');
const counterfeit = await call('POST', '/v1/listings', { token: A2, body: {
  ...base, title: 'Lepin castle', note: 'Compatible bricks, not original but looks the same.',
  photoURLs: [await newPhoto(A2)],
}});
check('a counterfeit listing is held, not published', counterfeit.body?.moderationStatus === 'held', JSON.stringify(counterfeit.body));
const heldID = counterfeit.body?.id;
const browseAll = await call('GET', '/v1/listings?limit=200');
check('a held listing is not browsable', !browseAll.body.listings.some((l) => l.id === heldID));

const offPlatform = await call('POST', '/v1/listings', { token: A2, body: {
  ...base, note: 'DM me on snapchat instead of using the app.',
}});
check('an off-platform contact listing is refused outright', offPlatform.status === 422, JSON.stringify(offPlatform.body));

console.log('\nownership');
check("Bob cannot delete Alice's listing", (await call('DELETE', `/v1/listings/${listingID}`, { token: B })).status === 403);
check("Bob cannot mark Alice's listing sold", (await call('POST', `/v1/listings/${listingID}/sold`, { token: B })).status === 403);
check('Alice sees her own listings, held ones included', (await call('GET', '/v1/listings/mine', { token: A2 })).body.listings.some((l) => l.id === heldID));

console.log('\nblocking');
const bobListing = await call('POST', '/v1/listings', { token: B, body: {
  ...base, title: 'Colosseum', theme: 'Icons', priceQAR: 1900, note: "Bob's listing.", whatsAppNumber: '97430000002',
  photoURLs: [await newPhoto(B)],
}});
check("Bob's listing publishes", bobListing.status === 201);
check('Alice can see it before blocking', (await call('GET', '/v1/listings?limit=200', { token: A2 })).body.listings.some((l) => l.id === bobListing.body.id));

const block = await call('POST', '/v1/blocks', { token: A2, body: { userID: 'bob' } });
check('blocking works', block.status === 201 && block.body.blockedUserIDs.includes('bob'));
check('blocking yourself is refused', (await call('POST', '/v1/blocks', { token: A2, body: { userID: 'alice' } })).status === 400);
check('blocked listings vanish for Alice', !(await call('GET', '/v1/listings?limit=200', { token: A2 })).body.listings.some((l) => l.id === bobListing.body.id));
check('...but Bob is unaffected', (await call('GET', '/v1/listings?limit=200', { token: B })).body.listings.some((l) => l.id === bobListing.body.id));
check('blocks are readable', (await call('GET', '/v1/blocks', { token: A2 })).body.blockedUserIDs.includes('bob'));
await call('DELETE', '/v1/blocks/bob', { token: A2 });
check('unblocking restores the listing', (await call('GET', '/v1/listings?limit=200', { token: A2 })).body.listings.some((l) => l.id === bobListing.body.id));

console.log('\nfilters and search');
const icons = await call('GET', '/v1/listings?theme=Icons&limit=200');
check('theme filter', icons.body.listings.length > 0 && icons.body.listings.every((l) => l.theme === 'Icons'));
const bulk = await call('GET', '/v1/listings?type=bulk&limit=200');
check('type filter', bulk.body.listings.every((l) => l.type === 'bulk'));
const newOnly = await call('GET', `/v1/listings?condition=${encodeURIComponent('Good condition')}&limit=200`);
check('condition filter (with a space in it)', newOnly.body.listings.length > 0 && newOnly.body.listings.every((l) => l.condition === 'Good condition'));
const search = await call('GET', '/v1/listings?query=galaxy&limit=200');
check('search by title', search.body.listings.some((l) => l.title === 'Galaxy Explorer'));
check('search is case-insensitive', (await call('GET', '/v1/listings?query=GALAXY')).body.listings.length === search.body.listings.length);
check('search by set number', (await call('GET', '/v1/listings?query=10497')).body.listings.some((l) => l.setNumber === '10497'));
check('sorted newest first', (() => {
  const dates = browseAll.body.listings.map((l) => new Date(l.createdAt).getTime());
  return dates.every((d, i) => i === 0 || dates[i - 1] >= d);
})());

console.log('\nsold and delete');
await call('POST', `/v1/listings/${listingID}/sold`, { token: A2 });
check('a sold listing leaves the browse feed', !(await call('GET', '/v1/listings?limit=200')).body.listings.some((l) => l.id === listingID));
check('the seller still sees it', (await call('GET', '/v1/listings/mine', { token: A2 })).body.listings.some((l) => l.id === listingID && l.isSold));
const toDelete = await call('POST', '/v1/listings', { token: A2, body: { ...base, title: 'Temporary', photoURLs: [await newPhoto(A2)] } });
check('deleting your own listing works', (await call('DELETE', `/v1/listings/${toDelete.body.id}`, { token: A2 })).status === 204);
check('a deleted listing is gone', (await call('GET', `/v1/listings/${toDelete.body.id}`)).status === 404);

console.log('\nwanted');
const wanted = await call('POST', '/v1/wanted', { token: A2, body: { setNumber: '10276', maxPriceQAR: 2600 } });
check('adding a wanted entry works', wanted.status === 201 && !!wanted.body.id);
check('an empty wanted entry is refused', (await call('POST', '/v1/wanted', { token: A2, body: {} })).status === 400);
check('the wanted list is per-user', (await call('GET', '/v1/wanted', { token: B })).body.wanted.length === 0);
check('Alice sees her entry', (await call('GET', '/v1/wanted', { token: A2 })).body.wanted.some((w) => w.id === wanted.body.id));
check('removing works', (await call('DELETE', `/v1/wanted/${wanted.body.id}`, { token: A2 })).status === 204);
check("you can't delete someone else's entry", (await call('DELETE', `/v1/wanted/${wanted.body.id}`, { token: B })).status === 404);

console.log('\nreports');
const report = await call('POST', '/v1/reports', { token: B, body: {
  listingID: bobListing.body.id, reason: 'Counterfeit or clone bricks', detail: 'Looks like a clone.',
}});
check('reporting works', report.status === 201 && report.body.received === true);
check('a made-up reason is refused', (await call('POST', '/v1/reports', { token: B, body: { listingID: 'x', reason: 'I just do not like it' } })).status === 400);
check('reporting needs a token', (await call('POST', '/v1/reports', { body: { listingID: 'x', reason: 'Something else' } })).status === 401);

console.log('\nmoderation queue');
check('the queue needs the admin token', (await call('GET', '/v1/admin/queue')).status === 401);
check('a user token is not an admin token', (await call('GET', '/v1/admin/queue', { token: A2 })).status === 401);
const queue = await call('GET', '/v1/admin/queue', { token: ADMIN });
check('the queue lists open reports', queue.status === 200 && queue.body.openReports.length > 0);
check('the queue lists held listings', queue.body.heldListings.some((l) => l.id === heldID));
check('approving a held listing works', (await call('POST', `/v1/admin/listings/${heldID}/approve`, { token: ADMIN })).status === 200);
check('the approved listing is now browsable', (await call('GET', '/v1/listings?limit=200')).body.listings.some((l) => l.id === heldID));
check('removing a listing works', (await call('POST', `/v1/admin/listings/${heldID}/remove`, { token: ADMIN })).status === 200);
check('a removed listing is not browsable', !(await call('GET', '/v1/listings?limit=200')).body.listings.some((l) => l.id === heldID));
const reportID = queue.body.openReports[0].id;
check('resolving a report works', (await call('POST', `/v1/admin/reports/${reportID}/resolve`, { token: ADMIN, body: { resolution: 'removed the listing' } })).status === 200);
check('a resolved report leaves the queue', !(await call('GET', '/v1/admin/queue', { token: ADMIN })).body.openReports.some((r) => r.id === reportID));

console.log('\naccount deletion');
const doomed = await call('POST', '/v1/auth/dev', { body: { userID: 'doomed', displayName: 'Doomed' } });
const D = doomed.body.accessToken;
const doomedListing = await call('POST', '/v1/listings', { token: D, body: { ...base, title: 'Going away', whatsAppNumber: '97430000009', photoURLs: [await newPhoto(D)] } });
check('the doomed listing exists', (await call('GET', '/v1/listings?limit=200')).body.listings.some((l) => l.id === doomedListing.body.id));
const deletion = await call('DELETE', '/v1/account', { token: D });
check('account deletion succeeds', deletion.status === 200 && deletion.body.deleted === true);
check('it reports what happened with Apple', typeof deletion.body.appleRevocation === 'string');
check('the session dies with the account', (await call('GET', '/v1/me', { token: D })).status === 401);
check('their listings are gone', !(await call('GET', '/v1/listings?limit=200')).body.listings.some((l) => l.id === doomedListing.body.id));

console.log('\nstale sessions');
// The failure mode this exists to prevent: a token from before a database reset gets
// quietly ignored on public routes, so browsing works and the Sell flow does not.
const STALE = 'a-token-that-no-longer-exists-server-side';
check('browsing signed out still works', (await call('GET', '/v1/listings')).status === 200);
check('a stale token fails immediately, on browse', (await call('GET', '/v1/listings', { token: STALE })).status === 401);
check('...and on upload', (await call('POST', '/v1/photos', { token: STALE })).status === 401);
check('the admin token is not mistaken for a dead session',
      (await call('GET', '/v1/admin/queue', { token: ADMIN })).status === 200);
check('signing in is still reachable with a stale token in hand',
      (await call('POST', '/v1/auth/dev', { token: STALE, body: { userID: 'recovering', displayName: 'Recovered' } })).status === 200);

console.log('\nrouting');
check('an unknown path is a 404', (await call('GET', '/v1/nonsense')).status === 404);
check('a wrong verb is a 405', (await call('DELETE', '/v1/health')).status === 405);
check('malformed JSON is a 400', (await fetch(`${BASE}/v1/wanted`, { method: 'POST', headers: { Authorization: `Bearer ${A2}`, 'Content-Type': 'application/json' }, body: '{not json' })).status === 400);

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
