import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { db, now } from './db.js';
import { config } from './config.js';

// Tokens are stored hashed. If someone walks off with the database they still cannot
// sign in as anybody — the same reason you never store a password in the clear.
function hash(token) {
  return createHash('sha256').update(token).digest('hex');
}

function newToken() {
  return randomBytes(32).toString('base64url');
}

export function issueSession(userID) {
  const accessToken = newToken();
  const refreshToken = newToken();
  const createdAt = new Date();
  const expiresAt = new Date(createdAt.getTime() + config.sessionDays * 86_400_000);

  db.prepare(`
    INSERT INTO sessions (access_hash, refresh_hash, user_id, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?)
  `).run(hash(accessToken), hash(refreshToken), userID, createdAt.toISOString(), expiresAt.toISOString());

  return { accessToken, refreshToken, userID };
}

export function refreshSession(refreshToken) {
  const row = db.prepare('SELECT * FROM sessions WHERE refresh_hash = ?').get(hash(refreshToken));
  if (!row) return null;
  db.prepare('DELETE FROM sessions WHERE access_hash = ?').run(row.access_hash);
  return issueSession(row.user_id);
}

export function revokeSession(accessToken) {
  db.prepare('DELETE FROM sessions WHERE access_hash = ?').run(hash(accessToken));
}

export function revokeAllSessions(userID) {
  db.prepare('DELETE FROM sessions WHERE user_id = ?').run(userID);
}

/** Resolves a Bearer token to a live, non-deleted user. Returns null if anything is off. */
export function userForToken(token) {
  if (!token) return null;

  const session = db.prepare('SELECT * FROM sessions WHERE access_hash = ?').get(hash(token));
  if (!session) return null;

  if (new Date(session.expires_at) <= new Date()) {
    db.prepare('DELETE FROM sessions WHERE access_hash = ?').run(session.access_hash);
    return null;
  }

  const user = db.prepare('SELECT * FROM users WHERE id = ? AND deleted_at IS NULL').get(session.user_id);
  return user ?? null;
}

export function bearerToken(request) {
  const header = request.headers.authorization ?? '';
  return header.startsWith('Bearer ') ? header.slice(7).trim() : null;
}

/** Constant-time compare, so the admin token can't be guessed a character at a time. */
export function secretsMatch(a, b) {
  if (!a || !b) return false;
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export function purgeExpiredSessions() {
  const result = db.prepare('DELETE FROM sessions WHERE expires_at <= ?').run(now());
  return result.changes;
}
