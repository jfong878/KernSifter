/**
 * Device authorization (RFC 8628) and per-user API tokens for KernSifter's
 * non-browser clients, stored in D1.
 *
 * Why this exists: the web client is authorised by the Freebuff session cookie,
 * which a native client does not have — and cannot get, because Freebuff
 * refuses token requests from browsers and exposes no device grant. So the
 * native apps never touch Freebuff tokens. They start a device authorization
 * here, the human approves it in the browser using the session they already
 * have, and what comes back is a KernSifter-issued bearer token scoped to one
 * `sub`. This module is deliberately free of HTTP/Response concerns: the
 * routing layer decides status codes, this layer decides truth.
 *
 * Storage rules, all load-bearing:
 *   - secrets are stored only as SHA-256 hashes; the plaintext leaves the
 *     server exactly once, in the response that mints it
 *   - the owner of a token is fixed at approval time from the signed-in
 *     session `sub`, never from anything the client sends
 *   - a device code is single-use, short-lived, and redeemed under a
 *     conditional UPDATE so concurrent polls cannot both mint a token
 */

import type { FreebuffAuth, FreebuffUser } from '@freebuff/auth';

import { sha256Hex } from './sync';

/** Bindings this module needs. */
export interface AuthEnv {
  SYNC_DB: D1Database;
  /** Canonical origin, from config. Used to build the verification URI only. */
  APP_ORIGIN: string;
}

export const DEVICE_CODE_TTL_MS = 10 * 60 * 1000;
export const DEVICE_POLL_INTERVAL_SECONDS = 5;
/** RFC 8628 §3.5: on `slow_down`, widen the interval by 5 seconds. */
export const DEVICE_POLL_BACKOFF_SECONDS = 5;
export const TOKEN_TTL_MS = 30 * 24 * 60 * 60 * 1000;
/**
 * `last_used_at` is bookkeeping, not authorization. Writing it on every request
 * would mean a D1 write per API call, so it is throttled to this granularity.
 */
export const TOKEN_LAST_USED_GRANULARITY_MS = 60 * 60 * 1000;

/**
 * The user code is read off a screen and typed by a human, so the alphabet
 * omits vowels (no accidental words), and `0/O`, `1/I/L` (no transcription
 * errors). 27^8 is ~2.8e11, which with a 10-minute TTL and a signed-in-only
 * approval step is not brute-forceable.
 */
export const USER_CODE_ALPHABET = '23456789BCDFGHJKLMNPQRSTVWXZ';
export const USER_CODE_LENGTH = 8;
const USER_CODE_GROUP = 4;

export const DEVICE_CODE_PREFIX = 'ksd_';
export const TOKEN_PREFIX = 'ks_';
export const MAX_CLIENT_NAME_LENGTH = 64;
/**
 * `POST /api/device/authorize` is the one endpoint that writes without any
 * credential, so it gets a valve: expired rows are swept on every call, and a
 * flood of live pending codes is refused rather than allowed to grow the table
 * without bound.
 */
export const MAX_PENDING_DEVICE_CODES = 5000;

// ---------------------------------------------------------------------------
// Secrets and encodings
// ---------------------------------------------------------------------------

function randomHex(byteCount: number): string {
  const buffer = new Uint8Array(byteCount);
  crypto.getRandomValues(buffer);
  let out = '';
  for (const byte of buffer) out += byte.toString(16).padStart(2, '0');
  return out;
}

/**
 * Rejection sampling rather than `% alphabet.length`: 256 is not a multiple of
 * 27, so the modulo shortcut would make the first few characters more likely.
 */
function randomUserCode(): string {
  const alphabetSize = USER_CODE_ALPHABET.length;
  const limit = 256 - (256 % alphabetSize);
  const chars: string[] = [];
  while (chars.length < USER_CODE_LENGTH) {
    const buffer = new Uint8Array(USER_CODE_LENGTH * 2);
    crypto.getRandomValues(buffer);
    for (const byte of buffer) {
      if (byte >= limit) continue;
      chars.push(USER_CODE_ALPHABET[byte % alphabetSize]);
      if (chars.length === USER_CODE_LENGTH) break;
    }
  }
  return chars.join('');
}

export function formatUserCode(code: string): string {
  return `${code.slice(0, USER_CODE_GROUP)}-${code.slice(USER_CODE_GROUP)}`;
}

/** Accept what a human types: any case, with or without the dash, spaced out. */
export function normaliseUserCode(input: string): string | null {
  const cleaned = input.toUpperCase().replace(/[^0-9A-Z]/g, '');
  if (cleaned.length !== USER_CODE_LENGTH) return null;
  for (const character of cleaned) {
    if (!USER_CODE_ALPHABET.includes(character)) return null;
  }
  return cleaned;
}

/**
 * Length-independent SHA-256 hex comparison. Both sides are fixed-length
 * digests, and the DB lookup has already matched, so this is belt-and-braces —
 * but it keeps the intent explicit rather than leaving a `===` to be "optimised"
 * back in later.
 */
export function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) {
    difference |= a.charCodeAt(index) ^ b.charCodeAt(index);
  }
  return difference === 0;
}

/**
 * The client name is attacker-supplied and is rendered on the consent page, so
 * strip control characters, collapse whitespace, and cap the length.
 */
export function sanitiseClientName(input: unknown): string {
  if (typeof input !== 'string') return '';
  return input
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, MAX_CLIENT_NAME_LENGTH);
}

// ---------------------------------------------------------------------------
// Device authorization
// ---------------------------------------------------------------------------

export interface DeviceAuthorization {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete: string;
  expires_in: number;
  interval: number;
}

export type DeviceErrorCode =
  | 'authorization_pending'
  | 'slow_down'
  | 'access_denied'
  | 'expired_token'
  | 'invalid_grant';

export type DevicePollOutcome =
  | { status: 'token'; token: string; tokenId: number; expiresIn: number }
  | { status: 'error'; error: DeviceErrorCode };

interface DeviceCodeRow {
  id: number;
  device_code_hash: string;
  user_code_hash: string;
  status: string;
  owner_sub: string | null;
  client_name: string;
  created_at: number;
  expires_at: number;
  poll_interval_seconds: number;
  last_poll_at: number | null;
}

const DEVICE_CODE_COLUMNS =
  'id, device_code_hash, user_code_hash, status, owner_sub, client_name, created_at, expires_at, poll_interval_seconds, last_poll_at';

/** Start a device authorization. The plaintext secrets are returned once. */
export async function createDeviceAuthorization(
  env: AuthEnv,
  clientName: string,
  now: number = Date.now(),
): Promise<DeviceAuthorization> {
  // Opportunistic sweep: no cron trigger needed to keep the table small.
  await env.SYNC_DB.prepare('DELETE FROM kernsifter_device_codes WHERE expires_at < ?')
    .bind(now - DEVICE_CODE_TTL_MS)
    .run();

  const pending = await env.SYNC_DB.prepare(
    "SELECT COUNT(*) AS live FROM kernsifter_device_codes WHERE status = 'pending' AND expires_at > ?",
  )
    .bind(now)
    .first<{ live: number }>();
  if (Number(pending?.live ?? 0) >= MAX_PENDING_DEVICE_CODES) {
    throw new Error('too many pending device authorizations');
  }

  for (let attempt = 0; ; attempt += 1) {
    const deviceCode = DEVICE_CODE_PREFIX + randomHex(32);
    const userCode = randomUserCode();
    try {
      await env.SYNC_DB.prepare(
        `INSERT INTO kernsifter_device_codes
           (device_code_hash, user_code_hash, status, owner_sub, client_name, created_at, expires_at, poll_interval_seconds, last_poll_at)
         VALUES (?, ?, 'pending', NULL, ?, ?, ?, ?, NULL)`,
      )
        .bind(
          await sha256Hex(deviceCode),
          await sha256Hex(userCode),
          clientName,
          now,
          now + DEVICE_CODE_TTL_MS,
          DEVICE_POLL_INTERVAL_SECONDS,
        )
        .run();
      const formatted = formatUserCode(userCode);
      return {
        device_code: deviceCode,
        user_code: formatted,
        verification_uri: `${env.APP_ORIGIN}/device`,
        verification_uri_complete: `${env.APP_ORIGIN}/device?code=${encodeURIComponent(formatted)}`,
        expires_in: Math.floor(DEVICE_CODE_TTL_MS / 1000),
        interval: DEVICE_POLL_INTERVAL_SECONDS,
      };
    } catch (error) {
      // Only a user_code collision is worth retrying; anything else (missing
      // table, no DB) should surface immediately rather than three times.
      const message = String((error as Error)?.message ?? error);
      if (attempt >= 2 || !/unique|constraint/i.test(message)) throw error;
    }
  }
}

/**
 * Poll for the token. Never reveals whether a device code exists beyond the
 * RFC's own error codes, and enforces the polling interval so a hot loop is
 * told to back off rather than hammering the database.
 */
export async function pollDeviceToken(
  env: AuthEnv,
  deviceCode: string,
  now: number = Date.now(),
): Promise<DevicePollOutcome> {
  const hash = await sha256Hex(deviceCode);
  const row = await env.SYNC_DB.prepare(
    `SELECT ${DEVICE_CODE_COLUMNS} FROM kernsifter_device_codes WHERE device_code_hash = ?`,
  )
    .bind(hash)
    .first<DeviceCodeRow>();

  if (!row || !constantTimeEqual(row.device_code_hash, hash)) {
    return { status: 'error', error: 'invalid_grant' };
  }
  if (now >= row.expires_at) return { status: 'error', error: 'expired_token' };
  if (row.status === 'denied') return { status: 'error', error: 'access_denied' };
  if (row.status === 'redeemed') return { status: 'error', error: 'invalid_grant' };

  if (row.status === 'pending') {
    const sinceLastPoll = row.last_poll_at === null ? Number.POSITIVE_INFINITY : now - row.last_poll_at;
    if (sinceLastPoll < row.poll_interval_seconds * 1000) {
      await env.SYNC_DB.prepare(
        'UPDATE kernsifter_device_codes SET last_poll_at = ?, poll_interval_seconds = ? WHERE id = ?',
      )
        .bind(now, row.poll_interval_seconds + DEVICE_POLL_BACKOFF_SECONDS, row.id)
        .run();
      return { status: 'error', error: 'slow_down' };
    }
    await env.SYNC_DB.prepare('UPDATE kernsifter_device_codes SET last_poll_at = ? WHERE id = ?')
      .bind(now, row.id)
      .run();
    return { status: 'error', error: 'authorization_pending' };
  }

  // Approved: redeem exactly once. The conditional UPDATE is the lock, so two
  // concurrent polls cannot both mint a token from one approval.
  const redeemed = await env.SYNC_DB.prepare(
    "UPDATE kernsifter_device_codes SET status = 'redeemed', redeemed_at = ? WHERE id = ? AND status = 'approved'",
  )
    .bind(now, row.id)
    .run();
  if (Number(redeemed.meta?.changes ?? 0) !== 1) return { status: 'error', error: 'invalid_grant' };
  if (!row.owner_sub) return { status: 'error', error: 'invalid_grant' };

  const token = TOKEN_PREFIX + randomHex(32);
  const tokenHash = await sha256Hex(token);
  const inserted = await env.SYNC_DB.prepare(
    `INSERT INTO kernsifter_tokens
       (token_hash, owner_sub, label, created_at, expires_at, last_used_at, revoked_at)
     VALUES (?, ?, ?, ?, ?, NULL, NULL)`,
  )
    .bind(tokenHash, row.owner_sub, row.client_name, now, now + TOKEN_TTL_MS)
    .run();

  return {
    status: 'token',
    token,
    tokenId: Number(inserted.meta?.last_row_id ?? 0),
    expiresIn: Math.floor(TOKEN_TTL_MS / 1000),
  };
}

export type DeviceApprovalOutcome =
  | { ok: true; clientName: string }
  | { ok: false; error: 'invalid_user_code' | 'expired_token' | 'already_used' };

async function findDeviceByUserCode(env: AuthEnv, userCodeHash: string): Promise<DeviceCodeRow | null> {
  // Newest first, so a stale row for a recycled code cannot shadow a live one.
  return await env.SYNC_DB.prepare(
    `SELECT ${DEVICE_CODE_COLUMNS} FROM kernsifter_device_codes
       WHERE user_code_hash = ? ORDER BY id DESC LIMIT 1`,
  )
    .bind(userCodeHash)
    .first<DeviceCodeRow>();
}

/** What the consent page shows the human before they approve. */
export async function describeDevice(
  env: AuthEnv,
  userCode: string,
  now: number = Date.now(),
): Promise<{ clientName: string; expiresIn: number } | null> {
  const normalised = normaliseUserCode(userCode);
  if (!normalised) return null;
  const row = await findDeviceByUserCode(env, await sha256Hex(normalised));
  if (!row || row.status !== 'pending' || now >= row.expires_at) return null;
  return { clientName: row.client_name, expiresIn: Math.floor((row.expires_at - now) / 1000) };
}

/** Bind a pending device code to the signed-in user. */
export async function approveDevice(
  env: AuthEnv,
  userCode: string,
  user: FreebuffUser,
  now: number = Date.now(),
): Promise<DeviceApprovalOutcome> {
  const normalised = normaliseUserCode(userCode);
  if (!normalised) return { ok: false, error: 'invalid_user_code' };
  const row = await findDeviceByUserCode(env, await sha256Hex(normalised));
  if (!row) return { ok: false, error: 'invalid_user_code' };
  if (now >= row.expires_at) return { ok: false, error: 'expired_token' };
  if (row.status !== 'pending') return { ok: false, error: 'already_used' };

  // The owner is the session subject. Nothing the client sent can influence it.
  const updated = await env.SYNC_DB.prepare(
    "UPDATE kernsifter_device_codes SET status = 'approved', owner_sub = ?, approved_at = ? WHERE id = ? AND status = 'pending'",
  )
    .bind(user.sub, now, row.id)
    .run();
  if (Number(updated.meta?.changes ?? 0) !== 1) return { ok: false, error: 'already_used' };
  return { ok: true, clientName: row.client_name };
}

/** The human declined. The code goes terminal so polling reports access_denied. */
export async function denyDevice(
  env: AuthEnv,
  userCode: string,
  now: number = Date.now(),
): Promise<DeviceApprovalOutcome> {
  const normalised = normaliseUserCode(userCode);
  if (!normalised) return { ok: false, error: 'invalid_user_code' };
  const row = await findDeviceByUserCode(env, await sha256Hex(normalised));
  if (!row) return { ok: false, error: 'invalid_user_code' };
  if (now >= row.expires_at) return { ok: false, error: 'expired_token' };
  if (row.status !== 'pending') return { ok: false, error: 'already_used' };

  const updated = await env.SYNC_DB.prepare(
    "UPDATE kernsifter_device_codes SET status = 'denied', denied_at = ? WHERE id = ? AND status = 'pending'",
  )
    .bind(now, row.id)
    .run();
  if (Number(updated.meta?.changes ?? 0) !== 1) return { ok: false, error: 'already_used' };
  return { ok: true, clientName: row.client_name };
}

// ---------------------------------------------------------------------------
// Bearer tokens
// ---------------------------------------------------------------------------

interface TokenRow {
  id: number;
  token_hash: string;
  owner_sub: string;
  label: string;
  created_at: number;
  expires_at: number;
  last_used_at: number | null;
  revoked_at: number | null;
}

export interface TokenSummary {
  id: number;
  label: string;
  createdAt: number;
  expiresAt: number;
  lastUsedAt: number | null;
}

async function findToken(env: AuthEnv, token: string, now: number): Promise<TokenRow | null> {
  if (!token) return null;
  const hash = await sha256Hex(token);
  const row = await env.SYNC_DB.prepare(
    'SELECT id, token_hash, owner_sub, label, created_at, expires_at, last_used_at, revoked_at FROM kernsifter_tokens WHERE token_hash = ?',
  )
    .bind(hash)
    .first<TokenRow>();
  if (!row || !constantTimeEqual(row.token_hash, hash)) return null;
  if (row.revoked_at !== null && row.revoked_at !== undefined) return null;
  if (now >= row.expires_at) return null;
  return row;
}

export async function listTokens(env: AuthEnv, ownerSub: string): Promise<TokenSummary[]> {
  const { results } = await env.SYNC_DB.prepare(
    `SELECT id, label, created_at, expires_at, last_used_at FROM kernsifter_tokens
       WHERE owner_sub = ? AND revoked_at IS NULL AND expires_at > ?
       ORDER BY id`,
  )
    .bind(ownerSub, Date.now())
    .all<{ id: number; label: string; created_at: number; expires_at: number; last_used_at: number | null }>();
  return (results ?? []).map((row) => ({
    id: row.id,
    label: row.label,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    lastUsedAt: row.last_used_at,
  }));
}

/** Revoke one token. Scoped by owner, so an id from another account is a no-op. */
export async function revokeToken(
  env: AuthEnv,
  ownerSub: string,
  id: number,
  now: number = Date.now(),
): Promise<boolean> {
  const result = await env.SYNC_DB.prepare(
    'UPDATE kernsifter_tokens SET revoked_at = ? WHERE id = ? AND owner_sub = ? AND revoked_at IS NULL',
  )
    .bind(now, id, ownerSub)
    .run();
  return Number(result.meta?.changes ?? 0) === 1;
}

/** Revoke every token for this owner, optionally sparing the caller's own. */
export async function revokeAllTokens(
  env: AuthEnv,
  ownerSub: string,
  exceptTokenId: number | null,
  now: number = Date.now(),
): Promise<number> {
  const result = exceptTokenId === null
    ? await env.SYNC_DB.prepare(
      'UPDATE kernsifter_tokens SET revoked_at = ? WHERE owner_sub = ? AND revoked_at IS NULL',
    )
      .bind(now, ownerSub)
      .run()
    : await env.SYNC_DB.prepare(
      'UPDATE kernsifter_tokens SET revoked_at = ? WHERE owner_sub = ? AND id <> ? AND revoked_at IS NULL',
    )
      .bind(now, ownerSub, exceptTokenId)
      .run();
  return Number(result.meta?.changes ?? 0);
}

// ---------------------------------------------------------------------------
// Request -> principal
// ---------------------------------------------------------------------------

export interface Principal {
  user: FreebuffUser;
  /** How this request proved who it is. Drives the CSRF rule in the router. */
  via: 'session' | 'token';
  tokenId?: number;
}

/**
 * Throttled `last_used_at`. The write is intentionally non-fatal: this is
 * telemetry for the user's token list, and failing an authenticated request
 * because usage bookkeeping did not persist would be the wrong trade.
 */
async function touchToken(env: AuthEnv, row: TokenRow, now: number): Promise<void> {
  if (row.last_used_at !== null && now - row.last_used_at < TOKEN_LAST_USED_GRANULARITY_MS) return;
  try {
    await env.SYNC_DB.prepare('UPDATE kernsifter_tokens SET last_used_at = ? WHERE id = ?')
      .bind(now, row.id)
      .run();
  } catch {
    // See above: bookkeeping must never break an authenticated request.
  }
}

/**
 * Resolve the caller from either an `Authorization: Bearer` token or the
 * Freebuff session cookie.
 *
 * A present-but-invalid bearer token is a hard failure. There is deliberately
 * no fallback to the cookie in that case: falling back would mean a request
 * carrying a broken token got silently authorised as a cookie session, and the
 * cookie path is exactly the one that must keep requiring a same-origin check.
 */
export async function resolvePrincipal(
  request: Request,
  env: AuthEnv,
  signedIn: Pick<FreebuffAuth, 'getUser'>,
  now: number = Date.now(),
): Promise<Principal | null> {
  const header = request.headers.get('Authorization');
  if (header !== null) {
    const match = /^Bearer[ \t]+(\S+)$/i.exec(header.trim());
    if (!match) return null;
    const row = await findToken(env, match[1], now);
    if (!row) return null;
    await touchToken(env, row, now);
    return { user: { sub: row.owner_sub }, via: 'token', tokenId: row.id };
  }

  const user = await signedIn.getUser(request);
  return user ? { user, via: 'session' } : null;
}
