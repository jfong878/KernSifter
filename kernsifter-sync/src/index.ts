import { createFreebuffAuth, isSameOriginRequest } from '@freebuff/auth';
import type { FreebuffAuth } from '@freebuff/auth';

import { SyncError, jsonResponse, listItems, readPayload, saveItems } from './sync';

export interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
  SYNC_DB: D1Database;
  FILES: R2Bucket;
  FREEBUFF_CLIENT_ID: string;
  FREEBUFF_ISSUER?: string;
  APP_ORIGIN: string;
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
  app ??= signedIn.wrap(async (request: Request, env: Env): Promise<Response> => {
    const url = new URL(request.url);
    if (url.pathname === '/api/sync' || url.pathname.startsWith('/api/sync/')) {
      return handleSync(request, env, url, signedIn);
    }
    return env.ASSETS.fetch(request);
  });
  return app;
}

// Exported so the route's authorization and storage behaviour can be tested
// with stubs, without needing a live Freebuff sign-in.
export async function handleSync(
  request: Request,
  env: Env,
  url: URL,
  signedIn: Pick<FreebuffAuth, 'getUser'>,
): Promise<Response> {
  // Authorization is decided here, on the server, for every request.
  const user = await signedIn.getUser(request);
  if (!user) return jsonResponse({ error: 'sign_in_required' }, 401);

  try {
    if (request.method === 'POST') {
      if (url.pathname !== '/api/sync') return jsonResponse({ error: 'not_found' }, 404);
      // State change: same-origin only.
      if (!isSameOriginRequest(request, env.APP_ORIGIN)) {
        return jsonResponse({ error: 'forbidden' }, 403);
      }
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

    return jsonResponse({ error: 'method_not_allowed' }, 405, { Allow: 'GET, POST' });
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
