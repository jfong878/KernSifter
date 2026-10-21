import { createFreebuffAuth, isSameOriginRequest } from '@freebuff/auth';
import type { FreebuffAuth } from '@freebuff/auth';

import {
  approveDevice,
  createDeviceAuthorization,
  denyDevice,
  describeDevice,
  formatUserCode,
  listTokens,
  normaliseUserCode,
  pollDeviceToken,
  resolvePrincipal,
  revokeAllTokens,
  revokeToken,
  sanitiseClientName,
} from './auth';
import type { Principal } from './auth';
import { renderDevicePage, renderDeviceResult } from './device-page';
import { ensureSchema } from './schema';
import { SyncError, jsonResponse, listItems, readPayload, saveItems } from './sync';


export interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
  SYNC_DB: D1Database;
  FILES: R2Bucket;
  FREEBUFF_CLIENT_ID: string;
  FREEBUFF_ISSUER?: string;
  APP_ORIGIN: string;
  /** Comma-separated origins the desktop webview may call the API from. */
  ALLOWED_WEBVIEW_ORIGINS?: string;
}

/**
 * The Tauri webview is a browser engine, so calls from it are cross-origin and
 * need CORS. That is not a formality: `POST /api/device/authorize` writes
 * without any credential, so an open CORS policy would let any web page mint a
 * device code, show the victim a user code, and then redeem the approval for
 * itself — the classic device-flow phishing shape. Hence an explicit allowlist
 * of the shell's own origins, never `*`, and never `Allow-Credentials`.
 */
const DEFAULT_WEBVIEW_ORIGINS = 'http://tauri.localhost,https://tauri.localhost,tauri://localhost';

function allowedWebviewOrigins(env: Env): string[] {
  return (env.ALLOWED_WEBVIEW_ORIGINS ?? DEFAULT_WEBVIEW_ORIGINS)
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean);
}

/** CORS headers, but only for an allowlisted webview origin. */
function corsHeaders(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get('Origin');
  if (!origin || !allowedWebviewOrigins(env).includes(origin)) return {};
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
}

async function withCors(response: Response, request: Request, env: Env): Promise<Response> {
  const headers = corsHeaders(request, env);
  if (Object.keys(headers).length === 0) return response;
  const wrapped = new Response(response.body, response);
  for (const [name, value] of Object.entries(headers)) wrapped.headers.set(name, value);
  return wrapped;
}

// One auth instance per isolate: it caches issuer discovery and signing keys.
let auth: FreebuffAuth | undefined;
let app: ((request: Request, env: Env) => Promise<Response>) | undefined;

function setup(env: Env): (request: Request, env: Env) => Promise<Response> {
  auth ??= createFreebuffAuth({
    clientId: env.FREEBUFF_CLIENT_ID,
    issuer: env.FREEBUFF_ISSUER,
    baseUrl: env.APP_ORIGIN,
    // Config-derived, never request-derived: loopback only, for local development.
    allowInsecureLocalhost: /^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(env.APP_ORIGIN),
  });
  const signedIn = auth;
  // wrap() serves /auth/freebuff/* and refreshes sessions, so it must run
  // before the asset handler or the auth routes would be swallowed by it.
  app ??= signedIn.wrap((request: Request, env: Env) => handleRequest(request, env, signedIn));
  return app;
}

/**
 * The router, separated from the SDK wrapper so a test can drive every route
 * with a stubbed session and no network — the same reason [`handleSync`] is
 * exported.
 */
export async function handleRequest(
  request: Request,
  env: Env,
  signedIn: FreebuffAuth,
): Promise<Response> {
  const url = new URL(request.url);
  const isApi = url.pathname === '/api' || url.pathname.startsWith('/api/');

  // Preflight for the desktop webview. Answered only for an allowlisted origin;
  // anything else gets no CORS headers and the browser stops there.
  if (isApi && request.method === 'OPTIONS') {
    const headers = corsHeaders(request, env);
    if (!headers['Access-Control-Allow-Origin']) return new Response(null, { status: 403 });
    return new Response(null, { status: 204, headers });
  }

  // The managed database has no other client — no SQL console, no
  // `wrangler d1 execute` — so the tables are created from here. Idempotent and
  // memoised per isolate, so this is one round trip per cold start, not per
  // request.
  if (isDatabaseRoute(url.pathname)) {
    try {
      await ensureSchema(env.SYNC_DB);
    } catch (error) {
      // Report a transient failure as transient. A missing table must not look
      // like a policy refusal, and must not look like success either.
      console.error('schema bootstrap failed:', String(error));
      return withCors(jsonResponse({ error: 'temporarily_unavailable' }, 503), request, env);
    }
  }

  let response: Response;
  if (url.pathname === '/device') {
    response = await handleDevicePage(request, env, url, signedIn);
  } else if (url.pathname.startsWith('/api/device')) {
    response = await handleDeviceApi(request, env, url, signedIn);
  } else if (url.pathname === '/api/tokens' || url.pathname.startsWith('/api/tokens/')) {
    response = await handleTokens(request, env, url, signedIn);
  } else if (url.pathname === '/api/sync' || url.pathname.startsWith('/api/sync/')) {
    response = await handleSync(request, env, url, signedIn);
  } else {
    response = await env.ASSETS.fetch(request);
  }

  return isApi ? withCors(response, request, env) : response;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

const HTML_HEADERS: Record<string, string> = {
  'Content-Type': 'text/html; charset=utf-8',
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
  // No script on the consent page at all, and it may never be framed.
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
  'Referrer-Policy': 'no-referrer',
};

function htmlResponse(body: string, status = 200): Response {
  return new Response(body, { status, headers: HTML_HEADERS });
}

interface Submission {
  fields: Record<string, unknown>;
  /** True when the caller sent JSON, which decides the response shape. */
  json: boolean;
}

/** Read a form post or a JSON body. Returns null when the body is unusable. */
async function readSubmission(request: Request): Promise<Submission | null> {
  const contentType = (request.headers.get('Content-Type') ?? '').toLowerCase();
  try {
    if (contentType.includes('application/json')) {
      const parsed: unknown = await request.json();
      if (typeof parsed !== 'object' || parsed === null) return null;
      return { fields: parsed as Record<string, unknown>, json: true };
    }
    if (contentType.includes('application/x-www-form-urlencoded')) {
      const params = new URLSearchParams(await request.text());
      return { fields: Object.fromEntries(params.entries()), json: false };
    }
  } catch {
    return null;
  }
  return null;
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function methodNotAllowed(allow: string): Response {
  return jsonResponse({ error: 'method_not_allowed' }, 405, { Allow: allow });
}

/**
 * The API routes that touch D1. `/device` is not one: it renders from the
 * session and, at most, one lookup. Nothing here includes the asset handler.
 */
function isDatabaseRoute(pathname: string): boolean {
  return pathname.startsWith('/api/device')
    || pathname === '/api/tokens' || pathname.startsWith('/api/tokens/')
    || pathname === '/api/sync' || pathname.startsWith('/api/sync/');
}

/**
 * Resolve the caller, or return the 401 response to send instead.
 *
 * `requireSession` rejects bearer tokens: the two endpoints that use it are
 * reached by a human in a browser, and a machine credential should not be able
 * to approve a new machine credential.
 */
async function authenticate(
  request: Request,
  env: Env,
  signedIn: Pick<FreebuffAuth, 'getUser'>,
  requireSession = false,
): Promise<{ principal: Principal } | { response: Response }> {
  const principal = await resolvePrincipal(request, env, signedIn);
  if (!principal) {
    return { response: jsonResponse({ error: 'sign_in_required' }, 401) };
  }
  if (requireSession && principal.via !== 'session') {
    return { response: jsonResponse({ error: 'session_required' }, 403) };
  }
  return { principal };
}

/**
 * The CSRF rule, in one place.
 *
 * A cookie is ambient authority: the browser attaches it to a request the page
 * did not intend, which is what CSRF exploits, so a cookie-authenticated state
 * change must be same-origin. An `Authorization: Bearer` header is not ambient
 * — no browser adds it by itself, a cross-site page cannot set it without a
 * preflight we never approve, and we send no permissive CORS headers — so a
 * token-authenticated request needs no origin check. Keeping the check tied to
 * `via` rather than to the method is what preserves the web client's protection
 * exactly as it was.
 */
function csrfProtected(principal: Principal, request: Request, env: Env): Response | null {
  const stateChanging = request.method !== 'GET' && request.method !== 'HEAD';
  if (!stateChanging) return null;
  if (principal.via !== 'session') return null;
  if (isSameOriginRequest(request, env.APP_ORIGIN)) return null;
  return jsonResponse({ error: 'forbidden' }, 403);
}

// ---------------------------------------------------------------------------
// Device authorization
// ---------------------------------------------------------------------------

async function handleDeviceApi(
  request: Request,
  env: Env,
  url: URL,
  signedIn: FreebuffAuth,
): Promise<Response> {
  // Started and polled by a native client: unauthenticated by design, because
  // the whole point is that the caller does not have a session yet.
  if (url.pathname === '/api/device/authorize') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    const submission = await readSubmission(request);
    const clientName = sanitiseClientName(submission?.fields.client_name);
    try {
      return jsonResponse(await createDeviceAuthorization(env, clientName));
    } catch (error) {
      // A real failure (missing table, unreachable database) must not look like
      // a policy refusal. Log the cause and report the RFC's transient code.
      console.error('device authorize failed:', String(error));
      return jsonResponse({ error: 'temporarily_unavailable' }, 503);
    }
  }

  if (url.pathname === '/api/device/token') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    const submission = await readSubmission(request);
    const deviceCode = asString(submission?.fields.device_code).trim();
    if (!deviceCode) return jsonResponse({ error: 'invalid_grant' }, 400);
    const outcome = await pollDeviceToken(env, deviceCode);
    if (outcome.status === 'error') {
      // RFC 8628 §3.5 reports every polling outcome as a token-endpoint error,
      // so these stay 400 with the spec's `error` codes rather than an
      // HTTP-invented status.
      return jsonResponse({ error: outcome.error }, 400);
    }
    return jsonResponse({
      access_token: outcome.token,
      token_type: 'Bearer',
      expires_in: outcome.expiresIn,
    });
  }

  // The browser half: a signed-in human, on our own origin, on a form post.
  if (
    url.pathname === '/api/device/lookup'
    || url.pathname === '/api/device/approve'
    || url.pathname === '/api/device/deny'
  ) {
    if (request.method !== 'POST') return methodNotAllowed('POST');

    // A human in a browser: a session is required (a machine credential must not
    // mint another machine credential), and the post must be same-origin.
    const authenticated = await authenticate(request, env, signedIn, true);
    if ('response' in authenticated) return authenticated.response;
    const { principal } = authenticated;
    const failure = csrfProtected(principal, request, env);
    if (failure) return failure;

    const submission = await readSubmission(request);
    if (!submission) return jsonResponse({ error: 'invalid_request' }, 400);
    const rawCode = asString(submission.fields.user_code).trim();
    const wantsJson = submission.json;

    if (url.pathname === '/api/device/lookup') {
      const pending = await describeDevice(env, rawCode);
      const normalised = normaliseUserCode(rawCode);
      if (wantsJson) {
        return pending
          ? jsonResponse({
            user_code: normalised ? formatUserCode(normalised) : rawCode,
            client_name: pending.clientName,
            expires_in: pending.expiresIn,
          })
          : jsonResponse({ error: 'invalid_user_code' }, 404);
      }
      return renderDeviceResponse(request, env, url, signedIn, {
        code: rawCode,
        problem: pending ? undefined : 'That code is not valid, or it has expired.',
        status: pending ? 200 : 404,
      });
    }

    const result = url.pathname === '/api/device/approve'
      ? await approveDevice(env, rawCode, principal.user)
      : await denyDevice(env, rawCode);

    if (wantsJson) {
      if (!result.ok) return jsonResponse({ error: result.error }, 400);
      return jsonResponse({ ok: true, approved: url.pathname === '/api/device/approve', client_name: result.clientName });
    }

    const approved = url.pathname === '/api/device/approve';
    if (!result.ok) {
      return htmlResponse(
        renderDeviceResult({
          ok: false,
          message: result.error === 'expired_token'
            ? 'That code has expired. Start again from the app.'
            : result.error === 'already_used'
              ? 'That code has already been used.'
              : 'That code is not valid.',
          signedIn: true,
          returnTo: '/device',
        }),
        400,
      );
    }
    return htmlResponse(
      renderDeviceResult({
        ok: approved,
        clientName: result.clientName,
        message: approved
          ? 'You can return to the app now.'
          : 'The app was not given access. Nothing was shared.',
        signedIn: true,
        returnTo: '/device',
      }),
    );
  }

  return jsonResponse({ error: 'not_found' }, 404);
}

/** `GET /device` — the consent page. */
async function handleDevicePage(
  request: Request,
  env: Env,
  url: URL,
  signedIn: FreebuffAuth,
): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') return methodNotAllowed('GET');
  return renderDeviceResponse(request, env, url, signedIn, { code: url.searchParams.get('code') ?? '' });
}

/**
 * Render the consent page. Kept free of method handling because the form post
 * re-renders this same page with either the pending authorization or a problem.
 */
async function renderDeviceResponse(
  request: Request,
  env: Env,
  url: URL,
  signedIn: FreebuffAuth,
  options: { code: string; problem?: string; status?: number },
): Promise<Response> {
  const raw = options.code;
  const normalised = normaliseUserCode(raw);
  // Show the canonical form when it parses, and otherwise show what was typed
  // so the user can see and fix their own typo.
  const display = normalised ? formatUserCode(normalised) : raw.trim().slice(0, 32);
  const user = await signedIn.getUser(request);
  const pending = user && normalised ? await describeDevice(env, normalised) : null;
  const returnTo = display ? `/device?code=${encodeURIComponent(display)}` : '/device';

  return htmlResponse(
    renderDevicePage({
      userCode: display || null,
      pending,
      signedIn: Boolean(user),
      returnTo,
      problem: options.problem,
    }),
    options.status ?? 200,
  );
}

// ---------------------------------------------------------------------------
// Token management (session or bearer)
// ---------------------------------------------------------------------------

async function handleTokens(
  request: Request,
  env: Env,
  url: URL,
  signedIn: FreebuffAuth,
): Promise<Response> {
  const authenticated = await authenticate(request, env, signedIn);
  if ('response' in authenticated) return authenticated.response;
  const { principal } = authenticated;

  if (url.pathname === '/api/tokens') {
    if (request.method !== 'GET') return methodNotAllowed('GET');
    const tokens = await listTokens(env, principal.user.sub);
    return jsonResponse({
      tokens: tokens.map((token) => ({ ...token, current: token.id === principal.tokenId })),
    });
  }

  if (url.pathname === '/api/tokens/revoke') {
    if (request.method !== 'POST') return methodNotAllowed('POST');
    const failure = csrfProtected(principal, request, env);
    if (failure) return failure;

    const submission = await readSubmission(request);
    if (!submission) return jsonResponse({ error: 'invalid_request' }, 400);

    if (submission.fields.all === true) {
      // "Sign out everywhere": keep the caller's own token so this request does
      // not saw off the branch it is standing on.
      const revoked = await revokeAllTokens(env, principal.user.sub, principal.tokenId ?? null);
      return jsonResponse({ revoked });
    }

    const id = Number(submission.fields.id);
    if (!Number.isInteger(id) || id <= 0) return jsonResponse({ error: 'invalid_id' }, 400);
    const revoked = await revokeToken(env, principal.user.sub, id);
    if (!revoked) return jsonResponse({ error: 'not_found' }, 404);
    return jsonResponse({ revoked: 1 });
  }

  return jsonResponse({ error: 'not_found' }, 404);
}

// ---------------------------------------------------------------------------
// Sync
// ---------------------------------------------------------------------------

// Exported so the route's authorization and storage behaviour can be tested
// with stubs, without needing a live Freebuff sign-in.
export async function handleSync(
  request: Request,
  env: Env,
  url: URL,
  signedIn: Pick<FreebuffAuth, 'getUser'>,
): Promise<Response> {
  // Authorization is decided here, on the server, for every request. Either
  // credential resolves to a `sub`; nothing downstream needs to know which.
  const principal = await resolvePrincipal(request, env, signedIn);
  if (!principal) return jsonResponse({ error: 'sign_in_required' }, 401);

  const failedCsrf = csrfProtected(principal, request, env);
  if (failedCsrf) return failedCsrf;

  const user = principal.user;

  try {
    if (request.method === 'POST') {
      if (url.pathname !== '/api/sync') return jsonResponse({ error: 'not_found' }, 404);
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return jsonResponse({ error: 'invalid_json' }, 400);
      }
      const items = (body as { items?: unknown })?.items;
      if (!Array.isArray(items)) return jsonResponse({ error: 'items_must_be_an_array' }, 400);
      const saved = await saveItems(env, user, items);
      return jsonResponse({ saved });
    }

    if (request.method === 'GET') {
      if (url.pathname === '/api/sync') return jsonResponse({ items: await listItems(env, user) });
      const segments = url.pathname.split('/').filter(Boolean); // api, sync, kind, clientId
      if (segments.length === 4) {
        const stored = await readPayload(env, user, decodeURIComponent(segments[2]), decodeURIComponent(segments[3]));
        if (!stored) return jsonResponse({ error: 'not_found' }, 404);
        return jsonResponse({ payload: stored.payload, payloadHash: stored.payloadHash });
      }
      return jsonResponse({ error: 'not_found' }, 404);
    }

    return methodNotAllowed('GET, POST');
  } catch (error) {
    if (error instanceof SyncError) return jsonResponse({ error: error.message }, error.status);
    // Do not leak internals to the caller.
    return jsonResponse({ error: 'internal_error' }, 500);
  }
}

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return setup(env)(request, env);
  },
};
