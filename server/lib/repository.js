import { randomUUID } from 'node:crypto';
import { db, now } from './db.js';

/**
 * Row -> JSON mapping.
 *
 * The keys below are not arbitrary: they have to match the property names on
 * `Listing`, `WantedItem` and `User` in Models.swift exactly, because Swift's
 * synthesised CodingKeys use the property names verbatim. Rename a property in
 * Swift and you must rename it here. (Extra keys are harmless — Codable ignores
 * anything it wasn't asked for, which is how `moderationStatus` below rides along.)
 */

const LISTING_SELECT = `
  SELECT l.*,
         COALESCE(u.display_name, 'Seller') AS seller_name,
         COALESCE(u.completed_trades, 0)    AS seller_trades
  FROM listings l
  LEFT JOIN users u ON u.id = l.seller_id
`;

export function listingJSON(row) {
  return {
    id: row.id,
    sellerID: row.seller_id,
    sellerName: row.seller_name ?? 'Seller',
    sellerTrades: row.seller_trades ?? 0,
    type: row.type,
    setNumber: row.set_number,
    theme: row.theme,
    title: row.title,
    condition: row.condition,
    completeness: row.completeness,
    includesInstructions: row.includes_instructions === 1,
    boxCondition: row.box_condition,
    priceQAR: row.price_qar,
    note: row.note,
    photoURLs: JSON.parse(row.photo_urls || '[]'),
    whatsAppNumber: row.whatsapp_number,
    createdAt: row.created_at,
    isSold: row.is_sold === 1,
    // Extra, for the seller's benefit — the app ignores it.
    moderationStatus: row.status,
  };
}

export function wantedJSON(row) {
  return {
    id: row.id,
    setNumber: row.set_number,
    theme: row.theme,
    maxPriceQAR: row.max_price_qar,
    createdAt: row.created_at,
  };
}

export function userJSON(row) {
  return {
    id: row.id,
    displayName: row.display_name,
    email: row.email,
    whatsAppNumber: row.whatsapp_number,
    completedTrades: row.completed_trades,
    rating: row.rating,
    joinedAt: row.joined_at,
  };
}

// MARK: - Users

export function findUserByAppleSub(sub) {
  return db.prepare('SELECT * FROM users WHERE apple_sub = ? AND deleted_at IS NULL').get(sub);
}

export function findUser(id) {
  return db.prepare('SELECT * FROM users WHERE id = ? AND deleted_at IS NULL').get(id);
}

/**
 * Apple hands over the name and email on the FIRST authorization only, never again.
 * So: fill in blanks, never overwrite something we already have with a null.
 */
export function upsertAppleUser({ sub, displayName, email }) {
  const existing = findUserByAppleSub(sub);

  if (existing) {
    db.prepare(`
      UPDATE users
      SET display_name = COALESCE(?, display_name),
          email        = COALESCE(?, email)
      WHERE id = ?
    `).run(displayName ?? null, email ?? null, existing.id);
    return findUser(existing.id);
  }

  const id = randomUUID();
  db.prepare(`
    INSERT INTO users (id, apple_sub, display_name, email, joined_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(id, sub, displayName ?? null, email ?? null, now());
  return findUser(id);
}

/** Development shortcut — see config.allowDevAuth. Never reachable in production. */
export function upsertDevUser({ id, displayName, whatsAppNumber, completedTrades }) {
  const existing = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
  if (existing) {
    db.prepare(`
      UPDATE users
      SET display_name = COALESCE(?, display_name),
          whatsapp_number = COALESCE(?, whatsapp_number),
          completed_trades = COALESCE(?, completed_trades),
          deleted_at = NULL
      WHERE id = ?
    `).run(displayName ?? null, whatsAppNumber ?? null, completedTrades ?? null, id);
  } else {
    db.prepare(`
      INSERT INTO users (id, apple_sub, display_name, whatsapp_number, completed_trades, joined_at)
      VALUES (?, NULL, ?, ?, COALESCE(?, 0), ?)
    `).run(id, displayName ?? null, whatsAppNumber ?? null, completedTrades ?? null, now());
  }
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
}

/**
 * Soft-delete the account, hard-delete everything the user produced. The row stays so
 * the same Apple ID signing in again cannot silently inherit an old identity.
 */
export function deleteUser(userID) {
  db.prepare('DELETE FROM listings WHERE seller_id = ?').run(userID);
  db.prepare('DELETE FROM wanted   WHERE user_id = ?').run(userID);
  db.prepare('DELETE FROM blocks   WHERE user_id = ?').run(userID);
  db.prepare('DELETE FROM sessions WHERE user_id = ?').run(userID);
  db.prepare(`
    UPDATE users
    SET deleted_at = ?, display_name = NULL, email = NULL, whatsapp_number = NULL, apple_sub = NULL
    WHERE id = ?
  `).run(now(), userID);
}

// MARK: - Listings

/**
 * The browse query. Filtering happens here rather than on the phone so a blocked
 * seller's listings never reach the device in the first place.
 */
export function listings({ viewerID, theme, type, condition, query, limit = 100, offset = 0 }) {
  const where = ["l.status = 'live'", 'l.is_sold = 0', 'l.deleted_at IS NULL'];
  const params = [];

  if (theme)     { where.push('l.theme = ?');     params.push(theme); }
  if (type)      { where.push('l.type = ?');      params.push(type); }
  if (condition) { where.push('l.condition = ?'); params.push(condition); }

  if (query) {
    where.push("(LOWER(l.title) LIKE ? OR LOWER(l.theme) LIKE ? OR LOWER(COALESCE(l.set_number, '')) LIKE ?)");
    const needle = `%${query.toLowerCase()}%`;
    params.push(needle, needle, needle);
  }

  if (viewerID) {
    where.push('l.seller_id NOT IN (SELECT blocked_id FROM blocks WHERE user_id = ?)');
    params.push(viewerID);
  }

  params.push(Math.min(Number(limit) || 100, 200), Number(offset) || 0);

  return db.prepare(`
    ${LISTING_SELECT}
    WHERE ${where.join(' AND ')}
    ORDER BY l.created_at DESC
    LIMIT ? OFFSET ?
  `).all(...params).map(listingJSON);
}

/** A seller's own listings, including sold and held ones — they should see everything. */
export function listingsBySeller(sellerID, { includeSold = true } = {}) {
  const soldClause = includeSold ? '' : 'AND l.is_sold = 0';
  return db.prepare(`
    ${LISTING_SELECT}
    WHERE l.seller_id = ? AND l.deleted_at IS NULL ${soldClause}
    ORDER BY l.created_at DESC
  `).all(sellerID).map(listingJSON);
}

export function findListing(id) {
  const row = db.prepare(`${LISTING_SELECT} WHERE l.id = ? AND l.deleted_at IS NULL`).get(id);
  return row ? listingJSON(row) : null;
}

export function insertListing(listing) {
  db.prepare(`
    INSERT INTO listings (
      id, seller_id, type, set_number, theme, title, condition, completeness,
      includes_instructions, box_condition, price_qar, note, photo_urls,
      whatsapp_number, created_at, is_sold, status
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
  `).run(
    listing.id, listing.sellerID, listing.type, listing.setNumber ?? null, listing.theme,
    listing.title, listing.condition, listing.completeness ?? null,
    listing.includesInstructions ? 1 : 0, listing.boxCondition ?? null, listing.priceQAR,
    listing.note, JSON.stringify(listing.photoURLs ?? []), listing.whatsAppNumber,
    listing.createdAt, listing.status
  );
  return findListing(listing.id);
}

export function markListingSold(id, sellerID) {
  const result = db.prepare(`
    UPDATE listings SET is_sold = 1 WHERE id = ? AND seller_id = ? AND deleted_at IS NULL
  `).run(id, sellerID);
  return result.changes > 0;
}

export function softDeleteListing(id, sellerID) {
  const result = db.prepare(`
    UPDATE listings SET deleted_at = ? WHERE id = ? AND seller_id = ? AND deleted_at IS NULL
  `).run(now(), id, sellerID);
  return result.changes > 0;
}

export function setListingStatus(id, status) {
  const result = db.prepare('UPDATE listings SET status = ? WHERE id = ?').run(status, id);
  return result.changes > 0;
}

// MARK: - Wanted

export function wantedFor(userID) {
  return db.prepare('SELECT * FROM wanted WHERE user_id = ? ORDER BY created_at DESC')
    .all(userID).map(wantedJSON);
}

export function insertWanted(userID, item) {
  const id = item.id || randomUUID();
  db.prepare(`
    INSERT INTO wanted (id, user_id, set_number, theme, max_price_qar, created_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      set_number = excluded.set_number,
      theme = excluded.theme,
      max_price_qar = excluded.max_price_qar
  `).run(id, userID, item.setNumber ?? null, item.theme ?? null,
         item.maxPriceQAR ?? null, item.createdAt ?? now());
  const row = db.prepare('SELECT * FROM wanted WHERE id = ?').get(id);
  return wantedJSON(row);
}

export function deleteWanted(userID, id) {
  const result = db.prepare('DELETE FROM wanted WHERE id = ? AND user_id = ?').run(id, userID);
  return result.changes > 0;
}

/**
 * Everyone whose wanted list this new listing satisfies. Nothing sends a notification
 * yet — that needs APNs — but this is the query that will drive it, and having it here
 * means the wanted list is already doing real work rather than just storing rows.
 */
export function watchersFor(listing) {
  return db.prepare(`
    SELECT DISTINCT w.user_id, w.id AS wanted_id
    FROM wanted w
    WHERE w.user_id != ?
      AND (w.set_number = ? OR (w.set_number IS NULL AND w.theme = ?))
      AND (w.max_price_qar IS NULL OR w.max_price_qar >= ?)
  `).all(listing.sellerID, listing.setNumber ?? null, listing.theme, listing.priceQAR);
}

// MARK: - Moderation

export function insertReport(report) {
  db.prepare(`
    INSERT INTO reports (id, listing_id, reporter_id, reason, detail, created_at, status)
    VALUES (?, ?, ?, ?, ?, ?, 'open')
    ON CONFLICT(id) DO NOTHING
  `).run(report.id, report.listingID, report.reporterID, report.reason,
         report.detail ?? null, report.createdAt ?? now());
  return db.prepare('SELECT * FROM reports WHERE id = ?').get(report.id);
}

export function openReports() {
  return db.prepare(`
    SELECT r.*, l.title, l.note, l.seller_id, l.status AS listing_status
    FROM reports r
    LEFT JOIN listings l ON l.id = r.listing_id
    WHERE r.status = 'open'
    ORDER BY r.created_at ASC
  `).all();
}

export function resolveReport(id, resolution) {
  const result = db.prepare(`
    UPDATE reports SET status = 'resolved', resolved_at = ?, resolution = ? WHERE id = ?
  `).run(now(), resolution, id);
  return result.changes > 0;
}

export function heldListings() {
  return db.prepare(`${LISTING_SELECT} WHERE l.status = 'held' AND l.deleted_at IS NULL ORDER BY l.created_at ASC`)
    .all().map(listingJSON);
}

// MARK: - Blocks

export function blockedIDs(userID) {
  return db.prepare('SELECT blocked_id FROM blocks WHERE user_id = ?').all(userID)
    .map((row) => row.blocked_id);
}

export function insertBlock(userID, blockedID) {
  db.prepare(`
    INSERT INTO blocks (user_id, blocked_id, created_at) VALUES (?, ?, ?)
    ON CONFLICT(user_id, blocked_id) DO NOTHING
  `).run(userID, blockedID, now());
}

export function removeBlock(userID, blockedID) {
  const result = db.prepare('DELETE FROM blocks WHERE user_id = ? AND blocked_id = ?')
    .run(userID, blockedID);
  return result.changes > 0;
}
