import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync, unlinkSync, existsSync, statSync, createReadStream } from 'node:fs';
import { join, basename } from 'node:path';
import { db, now } from './db.js';
import { config } from './config.js';

mkdirSync(config.uploadDir, { recursive: true });

/** Photos are addressed by UUID, so this is the only shape a valid name can have. */
const FILENAME = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/;

/**
 * Sniff the actual bytes rather than trusting Content-Type, which the client controls.
 * The app sends JPEG; PNG is allowed because it costs nothing to accept.
 */
export function detectImageType(buffer) {
  if (buffer.length < 12) return null;
  if (buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return 'jpeg';
  if (buffer[0] === 0x89 && buffer[1] === 0x50 && buffer[2] === 0x4e && buffer[3] === 0x47 &&
      buffer[4] === 0x0d && buffer[5] === 0x0a && buffer[6] === 0x1a && buffer[7] === 0x0a) return 'png';
  return null;
}

/**
 * Paths, not absolute URLs.
 *
 * The app joins these onto whatever server it is pointed at, so moving from your Mac to
 * a real host changes nothing and there is no PUBLIC_URL to set wrong. The trade is that
 * these are not portable outside the app, which does not matter here.
 */
export function photoPath(id) {
  return `/v1/photos/${id}.jpg`;
}

export function idFromPath(value) {
  const match = /^\/v1\/photos\/([0-9a-f-]{36})\.jpg$/.exec(String(value ?? ''));
  return match ? match[1] : null;
}

export function fileFor(id) {
  return join(config.uploadDir, `${id}.jpg`);
}

export function savePhoto({ userID, buffer }) {
  const id = randomUUID();
  writeFileSync(fileFor(id), buffer);

  db.prepare(`
    INSERT INTO photos (id, user_id, listing_id, bytes, created_at)
    VALUES (?, ?, NULL, ?, ?)
  `).run(id, userID, buffer.length, now());

  return { id, path: photoPath(id), bytes: buffer.length };
}

/**
 * Claim uploaded photos for a listing.
 *
 * Returns the ordered paths on success, or a reason string on failure. A photo can only
 * be claimed by the person who uploaded it, and only once — otherwise anyone could
 * attach someone else's photo to their own listing, or reuse one across many listings
 * and have it vanish for all of them when one is deleted.
 */
export function attachPhotos({ userID, listingID, paths }) {
  const ids = [];

  for (const path of paths) {
    const id = idFromPath(path);
    if (!id) return { error: 'One of those photos is not a Brick Souq photo.' };

    const row = db.prepare('SELECT * FROM photos WHERE id = ?').get(id);
    if (!row) return { error: 'One of those photos has expired. Add it again.' };
    if (row.user_id !== userID) return { error: 'One of those photos is not yours.' };
    if (row.listing_id && row.listing_id !== listingID) {
      return { error: 'One of those photos is already on another listing.' };
    }
    if (!existsSync(fileFor(id))) return { error: 'One of those photos is missing. Add it again.' };

    ids.push(id);
  }

  if (new Set(ids).size !== ids.length) return { error: 'The same photo was added twice.' };

  const claim = db.prepare('UPDATE photos SET listing_id = ? WHERE id = ?');
  for (const id of ids) claim.run(listingID, id);

  return { paths: ids.map(photoPath) };
}

function removeFile(id) {
  try {
    unlinkSync(fileFor(id));
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`[photos] could not delete ${id}:`, error.message);
  }
}

export function deletePhotosForListing(listingID) {
  const rows = db.prepare('SELECT id FROM photos WHERE listing_id = ?').all(listingID);
  for (const row of rows) removeFile(row.id);
  db.prepare('DELETE FROM photos WHERE listing_id = ?').run(listingID);
  return rows.length;
}

export function deletePhotosForUser(userID) {
  const rows = db.prepare('SELECT id FROM photos WHERE user_id = ?').all(userID);
  for (const row of rows) removeFile(row.id);
  db.prepare('DELETE FROM photos WHERE user_id = ?').run(userID);
  return rows.length;
}

/** Photos picked but never published. Someone abandons the Sell screen every day. */
export function sweepOrphans({ olderThanHours = 24 } = {}) {
  const cutoff = new Date(Date.now() - olderThanHours * 3_600_000).toISOString();
  const rows = db.prepare(
    'SELECT id FROM photos WHERE listing_id IS NULL AND created_at < ?'
  ).all(cutoff);

  for (const row of rows) removeFile(row.id);
  db.prepare('DELETE FROM photos WHERE listing_id IS NULL AND created_at < ?').run(cutoff);
  return rows.length;
}

/** Serve a stored photo. Returns false if the name is not one we could have written. */
export function streamPhoto(response, filename) {
  const safe = basename(String(filename ?? ''));
  if (!FILENAME.test(safe)) return false;

  const path = join(config.uploadDir, safe);
  if (!existsSync(path)) return false;

  const { size } = statSync(path);
  response.writeHead(200, {
    'Content-Type': 'image/jpeg',
    'Content-Length': size,
    // The name is a UUID, so the bytes behind it never change.
    'Cache-Control': 'public, max-age=31536000, immutable',
    'X-Content-Type-Options': 'nosniff',
  });
  createReadStream(path).pipe(response);
  return true;
}
