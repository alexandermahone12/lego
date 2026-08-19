import { createServer } from 'node:http';
import { config } from './lib/config.js';
import { routes } from './lib/routes.js';
import { HTTPError, sendJSON, rateLimiter } from './lib/http.js';
import { userForToken, bearerToken, purgeExpiredSessions } from './lib/auth.js';
import { sweepOrphans } from './lib/photos.js';
import { db } from './lib/db.js';

const limit = rateLimiter({ windowMs: 60_000, max: 240 });

function clientIP(request) {
  return request.socket.remoteAddress ?? 'unknown';
}

const server = createServer(async (request, response) => {
  const started = Date.now();
  const url = new URL(request.url, `http://${request.headers.host ?? 'localhost'}`);

  // The app and the server are the same origin from the phone's point of view, so CORS
  // matters only if you build a web admin page. Kept permissive for GETs, nothing more.
  response.setHeader('Vary', 'Origin');
  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type',
      'Access-Control-Max-Age': '600',
    });
    response.end();
    return;
  }

  try {
    if (!limit(clientIP(request))) {
      throw new HTTPError(429, 'Too many requests. Slow down.', 'rate_limited');
    }

    const match = routes
      .map((candidate) => ({ candidate, result: candidate.regex.exec(url.pathname) }))
      .find(({ candidate, result }) => result && candidate.method === request.method);

    if (!match) {
      // Distinguish "wrong verb" from "no such thing" — it saves an hour of debugging.
      const pathExists = routes.some((candidate) => candidate.regex.test(url.pathname));
      throw new HTTPError(
        pathExists ? 405 : 404,
        pathExists ? `${request.method} is not allowed on ${url.pathname}.` : `No route for ${url.pathname}.`,
        pathExists ? 'method_not_allowed' : 'not_found'
      );
    }

    const { candidate, result } = match;
    // Resolve the caller once, for routes that behave differently signed in vs out.
    const token = bearerToken(request);
    const user = userForToken(token);

    // A token that is present but no longer valid is an error, even on routes that
    // work signed out. Quietly ignoring it means browsing keeps working while every
    // authenticated call fails, so the problem surfaces somewhere unrelated — deep in
    // the Sell flow, say — long after the thing that caused it.
    //
    // The exceptions are routes that carry a credential this function cannot resolve:
    // /v1/admin/* authenticates with ADMIN_TOKEN, and /v1/auth/* is where sessions are
    // obtained in the first place.
    const managesOwnCredential = candidate.pattern.startsWith('/v1/admin')
      || candidate.pattern.startsWith('/v1/auth');

    if (token && !user && !managesOwnCredential) {
      throw new HTTPError(401, 'That session is no longer valid. Sign in again.', 'unauthorized');
    }

    await candidate.handler(request, response, {
      url,
      params: result.groups ?? {},
      user,
    });

  } catch (error) {
    const status = error instanceof HTTPError ? error.status : 500;
    if (status >= 500) console.error(`[error] ${request.method} ${url.pathname}`, error);

    // If we are answering before the client finished sending — an upload rejected part
    // way through for being too large, say — the rest of that body is still coming down
    // the socket. Reusing the connection after that gets the NEXT request on it reset,
    // which surfaces as a mystery network failure nowhere near the actual cause.
    if (!request.readableEnded && !response.headersSent) {
      response.setHeader('Connection', 'close');
    }

    if (!response.headersSent) {
      sendJSON(response, status, {
        error: status >= 500 ? 'Something went wrong on our side.' : error.message,
        code: error.code ?? 'internal_error',
      });
    }
  } finally {
    const ms = Date.now() - started;
    console.log(`${request.method} ${url.pathname}${url.search} → ${response.statusCode} (${ms}ms)`);
  }
});

// Housekeeping: expired sessions are dead weight and a small liability, and photos
// picked but never published would otherwise accumulate on the volume forever.
setInterval(() => {
  const removed = purgeExpiredSessions();
  if (removed) console.log(`[sessions] purged ${removed} expired`);

  const swept = sweepOrphans();
  if (swept) console.log(`[photos] swept ${swept} unpublished`);
}, 60 * 60 * 1000).unref();

server.listen(config.port, config.host, () => {
  console.log('');
  console.log('  Brick Souq server');
  console.log(`  listening   http://localhost:${config.port}`);
  console.log(`  database    ${config.databasePath}`);
  console.log(`  photos      ${config.uploadDir}`);
  console.log(`  bundle id   ${config.appleBundleID}`);
  console.log(`  dev auth    ${config.allowDevAuth ? 'ON (development only)' : 'off'}`);
  console.log(`  moderation  ${config.adminToken ? 'ON at /v1/admin/queue' : 'off (set ADMIN_TOKEN to enable)'}`);
  console.log('');
});

function shutdown(signal) {
  console.log(`\n${signal} — closing.`);
  server.close(() => {
    try { db.close(); } catch { /* already closed */ }
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
