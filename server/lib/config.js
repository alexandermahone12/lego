import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

// Tiny .env loader so there is nothing to install. Values already present in the
// real environment always win, which is what you want on a deployed host.
function loadDotEnv() {
  const path = join(ROOT, '.env');
  if (!existsSync(path)) return;
  for (const rawLine of readFileSync(path, 'utf8').split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (process.env[key] === undefined) process.env[key] = value;
  }
}
loadDotEnv();

const isProduction = process.env.NODE_ENV === 'production';

export const config = {
  isProduction,
  port: Number(process.env.PORT ?? 8080),
  host: process.env.HOST ?? '0.0.0.0',
  databasePath: process.env.DATABASE_PATH ?? join(ROOT, 'data', 'bricksouq.db'),

  // Photos live next to the database on purpose: one persistent volume to mount and
  // one thing to back up. Object storage is the eventual answer, but it is another
  // account, another set of keys and another way to be misconfigured — and this works.
  uploadDir: process.env.UPLOAD_DIR
    ?? join(dirname(process.env.DATABASE_PATH ?? join(ROOT, 'data', 'bricksouq.db')), 'uploads'),

  // Phones downscale before uploading, so anything above this is a bug or an attack.
  maxPhotoBytes: Number(process.env.MAX_PHOTO_BYTES ?? 6_000_000),

  // Must match PRODUCT_BUNDLE_IDENTIFIER in the Xcode project, because it is the
  // `aud` claim Apple puts in the identity token.
  appleBundleID: process.env.APPLE_BUNDLE_ID ?? 'doody.lego',

  // Needed only for account deletion — Apple's revoke endpoint wants a client
  // secret signed with your Sign in with Apple key. Leave unset while developing.
  appleTeamID: process.env.APPLE_TEAM_ID ?? '',
  appleKeyID: process.env.APPLE_KEY_ID ?? '',
  applePrivateKeyPath: process.env.APPLE_PRIVATE_KEY_PATH ?? '',

  // Lets the app sign in without going through Apple, so the simulator and the
  // app's DEBUG `skipSignIn` path work. Refuses to switch on in production.
  allowDevAuth: !isProduction && process.env.ALLOW_DEV_AUTH !== '0',

  // Guards the moderation queue endpoints.
  adminToken: process.env.ADMIN_TOKEN ?? '',

  sessionDays: Number(process.env.SESSION_DAYS ?? 90),
};

if (config.isProduction && !config.adminToken) {
  console.warn('[config] ADMIN_TOKEN is unset — /v1/admin routes are disabled.');
}
