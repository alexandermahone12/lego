import { randomUUID } from 'node:crypto';
import { config } from './config.js';
import { transaction, now } from './db.js';
import { verifyIdentityToken, revokeAppleUser, AppleAuthError } from './apple.js';
import {
  issueSession, refreshSession, revokeSession, revokeAllSessions,
  userForToken, bearerToken, secretsMatch,
} from './auth.js';
import * as repo from './repository.js';
import { evaluate, statusForVerdict, checkPhotoCount, PHOTO_RULES } from './moderation.js';
import {
  savePhoto, attachPhotos, detectImageType, streamPhoto,
  deletePhotosForListing, deletePhotosForUser,
} from './photos.js';
import {
  HTTPError, badRequest, unauthorized, forbidden, notFound, rejected,
  readJSON, readBinary, sendJSON, sendEmpty,
  requireString, optionalString, requireInt, optionalInt, requireEnum,
} from './http.js';

// Mirrors the Swift enums. Anything outside these sets is a client bug or an attack.
const LISTING_TYPES = ['set', 'minifigures', 'bulk', 'parts'];
const CONDITIONS = ['New', 'Built', 'Good condition', 'Poor condition'];
const REPORT_REASONS = [
  'Counterfeit or clone bricks', 'Condition is misleading', 'Not LEGO, or not allowed here',
  'Spam or duplicate listing', 'Abusive or offensive content', 'Something else',
];

function requireUser(request) {
  const user = userForToken(bearerToken(request));
  if (!user) throw unauthorized();
  return user;
}

function requireAdmin(request) {
  if (!config.adminToken) throw notFound('Moderation queue is disabled — set ADMIN_TOKEN.');
  if (!secretsMatch(bearerToken(request), config.adminToken)) throw unauthorized('Bad admin token.');
}

export const routes = [];

function route(method, pattern, handler, { auth = true } = {}) {
  // '/v1/listings/:id/sold' -> a regex with a named group for id
  const regex = new RegExp(
    '^' + pattern.replace(/:[A-Za-z]+/g, (match) => `(?<${match.slice(1)}>[^/]+)`) + '$'
  );
  routes.push({ method, regex, handler, auth, pattern });
}

// MARK: - Health

route('GET', '/v1/health', async (_request, response) => {
  sendJSON(response, 200, {
    ok: true,
    time: now(),
    devAuth: config.allowDevAuth,
    moderationQueue: Boolean(config.adminToken),
    photoRules: PHOTO_RULES,
  });
}, { auth: false });

// MARK: - Auth

route('POST', '/v1/auth/apple', async (request, response) => {
  const body = await readJSON(request);

  const identityToken = requireString(body.identityToken, 'identityToken', { max: 8000 });
  const rawNonce = requireString(body.rawNonce, 'rawNonce', { max: 256 });

  let claims;
  try {
    claims = await verifyIdentityToken(identityToken, rawNonce);
  } catch (error) {
    if (error instanceof AppleAuthError) throw unauthorized(error.message);
    throw error;
  }

  // Apple sends the name only on the very first authorization, so take it when offered.
  // The email in the token is authoritative; the one the client sends is a fallback.
  const user = repo.upsertAppleUser({
    sub: claims.sub,
    displayName: optionalString(body.displayName, 'displayName', { max: 120 }),
    email: claims.email ?? optionalString(body.email, 'email', { max: 320 }),
  });

  const session = issueSession(user.id);
  sendJSON(response, 200, { ...session, user: repo.userJSON(user) });
}, { auth: false });

/**
 * Development sign-in. Lets the simulator and the app's DEBUG `skipSignIn` path talk to
 * a real server without going through Apple. config.allowDevAuth is false whenever
 * NODE_ENV=production, so this cannot be left on by accident.
 */
route('POST', '/v1/auth/dev', async (request, response) => {
  if (!config.allowDevAuth) throw notFound('Dev auth is disabled.');

  const body = await readJSON(request);
  const user = repo.upsertDevUser({
    id: optionalString(body.userID, 'userID', { max: 64 }) ?? 'dev-user',
    displayName: optionalString(body.displayName, 'displayName', { max: 120 }) ?? 'Dev User',
    whatsAppNumber: optionalString(body.whatsAppNumber, 'whatsAppNumber', { max: 32 }),
    completedTrades: optionalInt(body.completedTrades, 'completedTrades', { max: 100_000 }),
  });

  const session = issueSession(user.id);
  sendJSON(response, 200, { ...session, user: repo.userJSON(user) });
}, { auth: false });

route('POST', '/v1/auth/refresh', async (request, response) => {
  const body = await readJSON(request);
  const refreshToken = requireString(body.refreshToken, 'refreshToken', { max: 256 });

  const session = refreshSession(refreshToken);
  if (!session) throw unauthorized('That session has expired. Sign in again.');

  sendJSON(response, 200, session);
}, { auth: false });

route('POST', '/v1/auth/signout', async (request, response) => {
  revokeSession(bearerToken(request));
  sendEmpty(response);
});

route('GET', '/v1/me', async (request, response) => {
  sendJSON(response, 200, repo.userJSON(requireUser(request)));
});

route('PATCH', '/v1/me', async (request, response) => {
  const user = requireUser(request);
  const body = await readJSON(request);
  const updated = repo.upsertDevUser({
    id: user.id,
    displayName: optionalString(body.displayName, 'displayName', { max: 120 }),
    whatsAppNumber: optionalString(body.whatsAppNumber, 'whatsAppNumber', { max: 32 }),
  });
  sendJSON(response, 200, repo.userJSON(updated));
});

/**
 * Guideline 5.1.1(v). Two things have to happen: the data goes, and Apple is told to
 * forget the connection. Removing only the database row is the mistake reviewers catch.
 */
route('DELETE', '/v1/account', async (request, response) => {
  const user = requireUser(request);
  const body = await readJSON(request).catch(() => ({}));

  const revocation = await revokeAppleUser({
    refreshToken: body.appleRefreshToken ?? null,
    authorizationCode: body.authorizationCode ?? null,
  });

  deletePhotosForUser(user.id);
  transaction(() => {
    revokeAllSessions(user.id);
    repo.deleteUser(user.id);
  });

  console.log(`[account] deleted ${user.id} (apple revocation: ${revocation})`);
  sendJSON(response, 200, { deleted: true, appleRevocation: revocation });
});

// MARK: - Photos
//
// Upload is a raw image body rather than multipart/form-data. Multipart would mean
// writing a parser for a format that exists to send several fields at once, and this
// sends one image. `URLSession.upload(for:from:)` posts raw bytes in one line.

route('POST', '/v1/photos', async (request, response) => {
  const user = requireUser(request);
  const buffer = await readBinary(request, config.maxPhotoBytes);

  if (buffer.length === 0) throw badRequest('That upload was empty.');

  // Sniff the bytes. Content-Type is whatever the client felt like claiming, and an
  // upload directory that will serve back anything it is given is a real problem.
  const kind = detectImageType(buffer);
  if (!kind) throw badRequest('That file is not a JPEG or PNG image.');

  const photo = savePhoto({ userID: user.id, buffer });
  console.log(`[photos] ${user.id} uploaded ${photo.id} (${Math.round(photo.bytes / 1024)}KB ${kind})`);

  sendJSON(response, 201, photo);
});

route('GET', '/v1/photos/:file', async (request, response, { params }) => {
  // streamPhoto refuses anything that is not one of our UUID filenames, which is what
  // keeps this from being a way to read arbitrary files off the disk.
  if (!streamPhoto(response, params.file)) throw notFound('No such photo.');
}, { auth: false });

// MARK: - Listings

route('GET', '/v1/listings', async (request, response, { url, user }) => {
  const results = repo.listings({
    viewerID: user?.id ?? null,
    theme: url.searchParams.get('theme'),
    type: url.searchParams.get('type'),
    condition: url.searchParams.get('condition'),
    query: url.searchParams.get('query'),
    limit: url.searchParams.get('limit') ?? 100,
    offset: url.searchParams.get('offset') ?? 0,
  });
  sendJSON(response, 200, { listings: results });
}, { auth: false });   // browsing works signed-out; blocks only apply once we know who you are

route('GET', '/v1/listings/mine', async (request, response) => {
  const user = requireUser(request);
  sendJSON(response, 200, { listings: repo.listingsBySeller(user.id) });
});

route('GET', '/v1/listings/:id', async (request, response, { params }) => {
  const listing = repo.findListing(params.id);
  if (!listing || listing.moderationStatus !== 'live') throw notFound('That listing is gone.');
  sendJSON(response, 200, listing);
}, { auth: false });

route('POST', '/v1/listings', async (request, response) => {
  const user = requireUser(request);
  const body = await readJSON(request);

  const type = requireEnum(body.type, LISTING_TYPES, 'type');
  const condition = requireEnum(body.condition, CONDITIONS, 'condition');
  const title = requireString(body.title, 'title', { max: 140 });
  const note = requireString(body.note, 'note', { max: 4000 });
  const theme = requireString(body.theme, 'theme', { max: 60 });
  const priceQAR = requireInt(body.priceQAR, 'priceQAR', { min: 1, max: 10_000_000 });
  const whatsAppNumber = requireString(body.whatsAppNumber, 'whatsAppNumber', { max: 32 });
  const setNumber = optionalString(body.setNumber, 'setNumber', { max: 20 });
  const completeness = optionalInt(body.completeness, 'completeness', { min: 0, max: 8 });
  const boxCondition = optionalString(body.boxCondition, 'boxCondition', { max: 60 });

  if (whatsAppNumber.replace(/\D/g, '').length < 8) {
    throw badRequest('That WhatsApp number is too short to dial.');
  }

  // Screen before publishing, not after. Guideline 1.2 wants "a method for refusing to
  // publish objectionable content"; moderating after the fact does not satisfy it. The
  // app runs the same check, but the app is not a control — this is.
  const { verdict, message } = evaluate({ title, note });
  if (verdict === 'reject') throw rejected(message);

  // Photo rules are enforced here, not only in the Sell screen. The app checks first so
  // the seller finds out before typing a description, but the app is not a control.
  const photoPaths = Array.isArray(body.photoURLs) ? body.photoURLs.map(String) : [];
  const photoCheck = checkPhotoCount({ condition, count: photoPaths.length });
  if (!photoCheck.ok) throw rejected(photoCheck.message);

  // Everything above is a pure check. Claiming photos is the first thing that writes,
  // and it stays last for that reason: a validation error after this point would leave
  // photos attached to a listing that was never created, where the orphan sweep cannot
  // see them (it only collects unclaimed ones) and the seller cannot reuse them.
  const listingID = randomUUID();
  const claimed = attachPhotos({ userID: user.id, listingID, paths: photoPaths });
  if (claimed.error) throw rejected(claimed.error);

  const listing = repo.insertListing({
    id: listingID,
    sellerID: user.id,                       // from the session, never from the client
    type,
    setNumber,
    theme,
    title,
    condition,
    completeness,
    includesInstructions: body.includesInstructions === true,
    boxCondition,
    priceQAR,
    note,
    photoURLs: claimed.paths,
    whatsAppNumber,
    createdAt: now(),                        // server clock, so ordering can't be gamed
    status: statusForVerdict(verdict),
  });

  if (listing.moderationStatus === 'live') {
    const watchers = repo.watchersFor(listing);
    if (watchers.length) {
      // Where the push notification will go once APNs is wired up.
      console.log(`[wanted] "${listing.title}" matches ${watchers.length} wanted-list entr${watchers.length === 1 ? 'y' : 'ies'}`);
    }
  } else {
    console.log(`[moderation] listing ${listing.id} held for review: ${message}`);
  }

  sendJSON(response, 201, { ...listing, moderationMessage: message });
});

route('POST', '/v1/listings/:id/sold', async (request, response, { params }) => {
  const user = requireUser(request);
  const listing = repo.findListing(params.id);
  if (!listing) throw notFound('That listing is gone.');
  if (listing.sellerID !== user.id) throw forbidden('You can only mark your own listings sold.');

  repo.markListingSold(params.id, user.id);
  sendEmpty(response);
});

route('DELETE', '/v1/listings/:id', async (request, response, { params }) => {
  const user = requireUser(request);
  const listing = repo.findListing(params.id);
  if (!listing) throw notFound('That listing is gone.');
  if (listing.sellerID !== user.id) throw forbidden('You can only delete your own listings.');

  repo.softDeleteListing(params.id, user.id);
  // The row is kept for auditing; the bytes are not. Disk is the thing that fills up.
  deletePhotosForListing(params.id);
  sendEmpty(response);
});

// MARK: - Wanted

route('GET', '/v1/wanted', async (request, response) => {
  const user = requireUser(request);
  sendJSON(response, 200, { wanted: repo.wantedFor(user.id) });
});

route('POST', '/v1/wanted', async (request, response) => {
  const user = requireUser(request);
  const body = await readJSON(request);

  const setNumber = optionalString(body.setNumber, 'setNumber', { max: 20 });
  const theme = optionalString(body.theme, 'theme', { max: 60 });
  if (!setNumber && !theme) throw badRequest('A wanted entry needs a set number or a theme.');

  const item = repo.insertWanted(user.id, {
    id: optionalString(body.id, 'id', { max: 64 }) ?? randomUUID(),
    setNumber,
    theme,
    maxPriceQAR: optionalInt(body.maxPriceQAR, 'maxPriceQAR', { min: 1, max: 10_000_000 }),
    createdAt: now(),
  });

  sendJSON(response, 201, item);
});

route('DELETE', '/v1/wanted/:id', async (request, response, { params }) => {
  const user = requireUser(request);
  if (!repo.deleteWanted(user.id, params.id)) throw notFound('No such wanted entry.');
  sendEmpty(response);
});

// MARK: - Reports and blocks

route('POST', '/v1/reports', async (request, response) => {
  const user = requireUser(request);
  const body = await readJSON(request);

  const listingID = requireString(body.listingID, 'listingID', { max: 64 });
  const reason = requireEnum(body.reason, REPORT_REASONS, 'reason');

  const report = repo.insertReport({
    id: optionalString(body.id, 'id', { max: 64 }) ?? randomUUID(),
    listingID,
    reporterID: user.id,                     // from the session, not the client
    reason,
    detail: optionalString(body.detail, 'detail', { max: 2000 }),
    createdAt: now(),
  });

  // Apple requires action within 24 hours of a report. This log line is the alert
  // until you point it at email or Slack — someone has to actually see it.
  console.log(`[REPORT] listing=${listingID} reason="${reason}" by=${user.id} — action required within 24h`);

  sendJSON(response, 201, { id: report.id, received: true });
});

route('GET', '/v1/blocks', async (request, response) => {
  const user = requireUser(request);
  sendJSON(response, 200, { blockedUserIDs: repo.blockedIDs(user.id) });
});

route('POST', '/v1/blocks', async (request, response) => {
  const user = requireUser(request);
  const body = await readJSON(request);
  const blockedID = requireString(body.userID, 'userID', { max: 64 });
  if (blockedID === user.id) throw badRequest('You cannot block yourself.');

  repo.insertBlock(user.id, blockedID);
  sendJSON(response, 201, { blockedUserIDs: repo.blockedIDs(user.id) });
});

route('DELETE', '/v1/blocks/:id', async (request, response, { params }) => {
  const user = requireUser(request);
  repo.removeBlock(user.id, params.id);
  sendEmpty(response);
});

// MARK: - Moderation queue
//
// The human side of Guideline 1.2. Apple does not check that you have an admin UI, but
// it does expect reports to be acted on within 24 hours, and that is impossible without
// somewhere to see them. Authenticate with ADMIN_TOKEN, not a user session.

route('GET', '/v1/admin/queue', async (request, response) => {
  requireAdmin(request);
  sendJSON(response, 200, {
    openReports: repo.openReports(),
    heldListings: repo.heldListings(),
  });
}, { auth: false });

route('POST', '/v1/admin/listings/:id/approve', async (request, response, { params }) => {
  requireAdmin(request);
  if (!repo.setListingStatus(params.id, 'live')) throw notFound('No such listing.');
  sendJSON(response, 200, { id: params.id, status: 'live' });
}, { auth: false });

route('POST', '/v1/admin/listings/:id/remove', async (request, response, { params }) => {
  requireAdmin(request);
  if (!repo.setListingStatus(params.id, 'removed')) throw notFound('No such listing.');
  sendJSON(response, 200, { id: params.id, status: 'removed' });
}, { auth: false });

route('POST', '/v1/admin/reports/:id/resolve', async (request, response, { params }) => {
  requireAdmin(request);
  const body = await readJSON(request).catch(() => ({}));
  const resolution = optionalString(body.resolution, 'resolution', { max: 500 }) ?? 'reviewed';
  if (!repo.resolveReport(params.id, resolution)) throw notFound('No such report.');
  sendJSON(response, 200, { id: params.id, status: 'resolved', resolution });
}, { auth: false });

export { HTTPError };
