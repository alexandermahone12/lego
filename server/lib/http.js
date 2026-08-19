/** Small helpers so the route file stays about the marketplace, not about plumbing. */

export class HTTPError extends Error {
  constructor(status, message, code = null) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

export const badRequest   = (message) => new HTTPError(400, message, 'bad_request');
export const unauthorized = (message = 'Sign in again to continue.') => new HTTPError(401, message, 'unauthorized');
export const forbidden    = (message = 'That is not yours to change.') => new HTTPError(403, message, 'forbidden');
export const notFound     = (message = 'Not found.') => new HTTPError(404, message, 'not_found');
export const rejected     = (message) => new HTTPError(422, message, 'rejected');

const MAX_BODY_BYTES = 1_000_000;

export async function readJSON(request) {
  const chunks = [];
  let size = 0;

  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw badRequest('Request body is too large.');
    chunks.push(chunk);
  }

  if (size === 0) return {};

  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw badRequest('Request body is not valid JSON.');
  }
}

/** Raw bytes, for photo upload. JSON parsing would only get in the way. */
export async function readBinary(request, maxBytes) {
  const chunks = [];
  let size = 0;

  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) {
      throw new HTTPError(413, `That photo is larger than ${Math.round(maxBytes / 1_000_000)}MB.`, 'too_large');
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export function sendJSON(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  response.end(body);
}

export function sendEmpty(response, status = 204) {
  response.writeHead(status, { 'Cache-Control': 'no-store' });
  response.end();
}

/** Trims, rejects blanks, enforces a ceiling so nobody stores a novel in a title. */
export function requireString(value, field, { max = 2000, min = 1 } = {}) {
  if (typeof value !== 'string') throw badRequest(`"${field}" must be text.`);
  const trimmed = value.trim();
  if (trimmed.length < min) throw badRequest(`"${field}" is required.`);
  if (trimmed.length > max) throw badRequest(`"${field}" is longer than ${max} characters.`);
  return trimmed;
}

export function optionalString(value, field, { max = 2000 } = {}) {
  if (value === undefined || value === null || value === '') return null;
  return requireString(value, field, { max });
}

export function requireInt(value, field, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const number = typeof value === 'string' ? Number(value) : value;
  if (!Number.isInteger(number)) throw badRequest(`"${field}" must be a whole number.`);
  if (number < min || number > max) throw badRequest(`"${field}" must be between ${min} and ${max}.`);
  return number;
}

export function optionalInt(value, field, options = {}) {
  if (value === undefined || value === null || value === '') return null;
  return requireInt(value, field, options);
}

export function requireEnum(value, allowed, field) {
  if (!allowed.includes(value)) {
    throw badRequest(`"${field}" must be one of: ${allowed.join(', ')}.`);
  }
  return value;
}

/**
 * A blunt per-IP limiter. Enough to stop one broken client or one bored person from
 * filling the database; put a real one in front of this if the app takes off.
 */
export function rateLimiter({ windowMs = 60_000, max = 240 } = {}) {
  const hits = new Map();

  setInterval(() => {
    const cutoff = Date.now() - windowMs;
    for (const [key, entry] of hits) if (entry.start < cutoff) hits.delete(key);
  }, windowMs).unref();

  return function check(key) {
    const nowMs = Date.now();
    const entry = hits.get(key);
    if (!entry || nowMs - entry.start > windowMs) {
      hits.set(key, { start: nowMs, count: 1 });
      return true;
    }
    entry.count += 1;
    return entry.count <= max;
  };
}
