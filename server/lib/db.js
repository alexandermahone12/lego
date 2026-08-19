import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { config } from './config.js';

mkdirSync(dirname(config.databasePath), { recursive: true });

export const db = new DatabaseSync(config.databasePath);

db.exec('PRAGMA journal_mode = WAL');
db.exec('PRAGMA foreign_keys = ON');
db.exec('PRAGMA busy_timeout = 5000');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id               TEXT PRIMARY KEY,
  apple_sub        TEXT UNIQUE,
  display_name     TEXT,
  email            TEXT,
  whatsapp_number  TEXT,
  completed_trades INTEGER NOT NULL DEFAULT 0,
  rating           REAL,
  joined_at        TEXT NOT NULL,
  deleted_at       TEXT
);

CREATE TABLE IF NOT EXISTS sessions (
  access_hash   TEXT PRIMARY KEY,
  refresh_hash  TEXT UNIQUE,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at    TEXT NOT NULL,
  expires_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS listings (
  id                   TEXT PRIMARY KEY,
  seller_id            TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type                 TEXT NOT NULL,
  set_number           TEXT,
  theme                TEXT NOT NULL,
  title                TEXT NOT NULL,
  condition            TEXT NOT NULL,
  completeness         INTEGER,
  includes_instructions INTEGER NOT NULL DEFAULT 0,
  box_condition        TEXT,
  price_qar            INTEGER NOT NULL,
  note                 TEXT NOT NULL DEFAULT '',
  photo_urls           TEXT NOT NULL DEFAULT '[]',
  whatsapp_number      TEXT NOT NULL,
  created_at           TEXT NOT NULL,
  is_sold              INTEGER NOT NULL DEFAULT 0,
  -- live: visible. held: waiting on a human. removed: taken down by moderation.
  status               TEXT NOT NULL DEFAULT 'live',
  deleted_at           TEXT
);
CREATE INDEX IF NOT EXISTS idx_listings_browse  ON listings(status, is_sold, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_listings_theme   ON listings(theme);
CREATE INDEX IF NOT EXISTS idx_listings_type    ON listings(type);
CREATE INDEX IF NOT EXISTS idx_listings_cond    ON listings(condition);
CREATE INDEX IF NOT EXISTS idx_listings_seller  ON listings(seller_id);
CREATE INDEX IF NOT EXISTS idx_listings_set     ON listings(set_number);

CREATE TABLE IF NOT EXISTS wanted (
  id            TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  set_number    TEXT,
  theme         TEXT,
  max_price_qar INTEGER,
  created_at    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_wanted_user ON wanted(user_id);
CREATE INDEX IF NOT EXISTS idx_wanted_set  ON wanted(set_number);

CREATE TABLE IF NOT EXISTS reports (
  id          TEXT PRIMARY KEY,
  listing_id  TEXT NOT NULL,
  reporter_id TEXT NOT NULL,
  reason      TEXT NOT NULL,
  detail      TEXT,
  created_at  TEXT NOT NULL,
  -- open: nobody has looked. Apple expects action within 24 hours.
  status      TEXT NOT NULL DEFAULT 'open',
  resolved_at TEXT,
  resolution  TEXT
);
CREATE INDEX IF NOT EXISTS idx_reports_status ON reports(status, created_at);

CREATE TABLE IF NOT EXISTS photos (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- NULL until a listing claims it. Unclaimed rows are swept after a day, so an
  -- abandoned sell flow doesn't quietly fill the disk.
  listing_id TEXT,
  bytes      INTEGER NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_photos_listing ON photos(listing_id);
CREATE INDEX IF NOT EXISTS idx_photos_orphans ON photos(listing_id, created_at);

CREATE TABLE IF NOT EXISTS blocks (
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, blocked_id)
);
`);

export function now() {
  return new Date().toISOString();
}

export function transaction(fn) {
  db.exec('BEGIN');
  try {
    const result = fn();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  }
}
