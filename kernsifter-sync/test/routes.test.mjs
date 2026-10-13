// Dependency-free route test for the KernSifter sync Worker.
//
// Run with:  node test/routes.test.mjs
//
// The Worker source is TypeScript (src/index.ts, src/sync.ts) and its relative
// imports are extensionless (`from './sync'`). Node strips TypeScript types by
// default for .ts files, but Node ESM still requires an explicit extension for
// relative specifiers, so this test installs an in-process resolve hook
// (node:module registerHooks, Node >= 23.5) that appends `.ts` before falling
// back to normal resolution. The source is then loaded with `await import()`
// AFTER the hook is registered (static imports would be resolved too early).
//
// No third-party packages, no test framework, no build step, no network.

import { registerHooks } from 'node:module';
import assert from 'node:assert/strict';

const APP_ORIGIN = 'https://sync.example.com';
const FOREIGN_ORIGIN = 'https://evil.example';

// ---------------------------------------------------------------------------
// Load the Worker source
// ---------------------------------------------------------------------------

let hookInstalled = false;
if (typeof registerHooks === 'function') {
  registerHooks({
    resolve(specifier, context, nextResolve) {
      const isRelative = specifier.startsWith('./') || specifier.startsWith('../');
      const hasExtension = /\.[cm]?[jt]s$/.test(specifier) || specifier.endsWith('.json');
      if (isRelative && !hasExtension) {
        try {
          return nextResolve(specifier + '.ts', context);
        } catch {
          // fall through to the normal resolver and report that error instead
        }
      }
      return nextResolve(specifier, context);
    },
  });
  hookInstalled = true;
}

let handleSync;
const importErrors = [];
for (const specifier of ['../src/index.ts', '../src/index.js', '../src/index']) {
  try {
    ({ handleSync } = await import(specifier));
    break;
  } catch (error) {
    importErrors.push(`${specifier} -> ${error?.code ?? error?.name}: ${error?.message}`);
  }
}

if (typeof handleSync !== 'function') {
  console.error('FATAL: could not import handleSync from the Worker source.');
  console.error(`  registerHooks available: ${hookInstalled} (node ${process.version})`);
  for (const line of importErrors) console.error(`  - ${line}`);
  console.error(
    'The Worker source uses extensionless relative imports, which Node ESM cannot resolve\n' +
      'without the resolve hook above. Either run this test on Node >= 23.5, or give the\n' +
      "source explicit extensions (e.g. `from './sync.ts'`, with allowImportingTsExtensions).",
  );
  process.exit(1);
}

// ---------------------------------------------------------------------------
// In-memory fakes for the two bindings the source uses
// ---------------------------------------------------------------------------

/**
 * Emulates ONLY the two statements src/sync.ts issues, plus parameter binding.
 * Any other SQL throws loudly, so the fake can never silently "pass" a query it
 * does not actually understand.
 */
function makeFakeD1() {
  const rows = [];
  const calls = [];
  let nextId = 1;

  const normalise = (text) => String(text).replace(/\s+/g, ' ').trim();
  const INSERT = /^INSERT INTO kernsifter_items \(client_id, kind, owner_sub, payload, payload_hash, meta, created_at\) VALUES \(\?, \?, \?, \?, \?, \?, \?\) ON CONFLICT\(owner_sub, client_id\) DO UPDATE SET ./i;
  const SELECT = /^SELECT id, client_id, kind, owner_sub, payload_hash, meta, created_at FROM kernsifter_items WHERE owner_sub = \? ORDER BY id$/i;

  function write(sql, params) {
    if (params.length !== 7) throw new Error(`fake D1: expected 7 bind params, got ${params.length}`);
    const [clientId, kind, ownerSub, payload, payloadHash, meta, createdAt] = params;
    const existing = rows.find((r) => r.owner_sub === ownerSub && r.client_id === clientId);
    if (existing) {
      // ON CONFLICT(owner_sub, client_id) DO UPDATE
      Object.assign(existing, { kind, payload, payload_hash: payloadHash, meta, created_at: createdAt });
      return { last_row_id: existing.id, changes: 1 };
    }
    const id = nextId++;
    rows.push({ id, client_id: clientId, kind, owner_sub: ownerSub, payload, payload_hash: payloadHash, meta, created_at: createdAt });
    return { last_row_id: id, changes: 1 };
  }

  function read(sql, params) {
    if (params.length !== 1) throw new Error(`fake D1: expected 1 bind param, got ${params.length}`);
    return rows
      .filter((r) => r.owner_sub === params[0])
      .sort((a, b) => a.id - b.id)
      // The source selects columns explicitly; `payload` must NOT come back here.
      .map(({ id, client_id, kind, owner_sub, payload_hash, meta, created_at }) => ({ id, client_id, kind, owner_sub, payload_hash, meta, created_at }));
  }

  return {
    rows,
    calls,
    inserts: () => calls.filter((c) => /^INSERT/i.test(c.sql)),
    prepare(sqlText) {
      const sql = normalise(sqlText);
      let params = [];
      const statement = {
        bind(...args) {
          params = args;
          return statement;
        },
        async all() {
          calls.push({ sql, params });
          if (!SELECT.test(sql)) throw new Error(`fake D1: unsupported SELECT: ${sql}`);
          return { success: true, results: read(sql, params) };
        },
        async run() {
          calls.push({ sql, params });
          if (!INSERT.test(sql)) throw new Error(`fake D1: unsupported write: ${sql}`);
          return { success: true, meta: write(sql, params) };
        },
      };
      return statement;
    },
  };
}

function makeFakeR2() {
  const objects = new Map();
  const puts = [];
  return {
    puts,
    objects,
    async put(key, value, options) {
      puts.push({ key, value, options });
      objects.set(key, { value: String(value), customMetadata: options?.customMetadata ?? {}, options });
      return { key };
    },
    async get(key) {
      const found = objects.get(key);
      if (!found) return null;
      return { key, customMetadata: found.customMetadata, text: async () => found.value };
    },
    async list() {
      return { objects: [...objects.keys()].map((key) => ({ key })) };
    },
  };
}

/** Fresh bindings + a swappable signed-in user for one test case. */
function makeHarness(initialUser = null) {
  const db = makeFakeD1();
  const r2 = makeFakeR2();
  const state = { user: initialUser };
  const env = {
    SYNC_DB: db,
    FILES: r2,
    APP_ORIGIN,
    FREEBUFF_CLIENT_ID: 'test-client-id',
    FREEBUFF_ISSUER: undefined,
    ASSETS: { fetch: async () => new Response('asset', { status: 200 }) },
  };
  const signedIn = { getUser: async () => state.user };
  const call = (request) => handleSync(request, env, new URL(request.url), signedIn);
  return { db, r2, env, state, call };
}

const USER_A = { sub: 'user-abc' };
const USER_B = { sub: 'user-other' };

function syncRequest({ method = 'GET', body, path = '/api/sync', origin, fetchSite } = {}) {
  const headers = {};
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (origin) headers.Origin = origin;
  if (fetchSite) headers['Sec-Fetch-Site'] = fetchSite;
  return new Request(`${APP_ORIGIN}${path}`, {
    method,
    headers,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

const sameOrigin = { origin: APP_ORIGIN, fetchSite: 'same-origin' };
const foreignOrigin = { origin: FOREIGN_ORIGIN, fetchSite: 'cross-site' };

// ---------------------------------------------------------------------------
// Assertions
// ---------------------------------------------------------------------------

const results = [];
async function check(number, name, fn) {
  try {
    await fn();
    results.push({ number, name, ok: true });
    console.log(`ok ${number} - ${name}`);
  } catch (error) {
    results.push({ number, name, ok: false, error });
    console.error(`not ok ${number} - ${name}\n    ${error?.message ?? error}`);
  }
}

// 1. Signed out: both GET and POST are 401, and nothing is written.
await check(1, 'signed out => 401 on GET and POST, no writes', async () => {
  const h = makeHarness(null);
  const get = await h.call(syncRequest({ method: 'GET' }));
  assert.equal(get.status, 401, `GET status was ${get.status}`);
  assert.deepEqual(await get.json(), { error: 'sign_in_required' });
  const post = await h.call(syncRequest({ method: 'POST', body: { items: [] }, ...sameOrigin }));
  assert.equal(post.status, 401, `POST status was ${post.status}`);
  assert.deepEqual(await post.json(), { error: 'sign_in_required' });
  assert.equal(h.db.inserts().length, 0, `expected no D1 write, saw ${h.db.inserts().length}`);
  assert.equal(h.r2.puts.length, 0, `expected no R2 put, saw ${h.r2.puts.length}`);
});

// 2. Signed in, state change from a foreign origin: 403, no write.
await check(2, 'signed in + foreign Origin => 403, no writes', async () => {
  const h = makeHarness(USER_A);
  const response = await h.call(
    syncRequest({ method: 'POST', body: { items: [{ clientId: 'a1', kind: 'note', payload: { n: 1 } }] }, ...foreignOrigin }),
  );
  assert.equal(response.status, 403, `expected 403, got ${response.status}`);
  assert.deepEqual(await response.json(), { error: 'forbidden' });
  assert.equal(h.db.inserts().length, 0, 'D1 insert ran for a cross-origin request');
  assert.equal(h.r2.puts.length, 0, 'R2 put ran for a cross-origin request');
});

// 3. Signed in, same-origin: owner comes from the session and R2 is keyed by owner.
await check(3, 'signed in + same origin => 200, sub bound, R2 keyed by sub', async () => {
  const h = makeHarness(USER_A);
  const item = { clientId: 'a1', kind: 'note', payload: { n: 1 }, meta: 'm' };
  const response = await h.call(syncRequest({ method: 'POST', body: { items: [item] }, ...sameOrigin }));
  assert.equal(response.status, 200, `expected 200, got ${response.status}`);
  const body = await response.json();
  assert.equal(body.saved.length, 1);
  assert.equal(body.saved[0].ok, true, `item was rejected: ${JSON.stringify(body.saved)}`);

  assert.equal(h.db.inserts().length, 1, 'expected exactly one insert');
  const params = h.db.inserts()[0].params;
  assert.equal(params[2], USER_A.sub, `owner_sub bound as ${params[2]}, expected ${USER_A.sub}`);

  assert.equal(h.r2.puts.length, 1, `expected exactly one R2 put, got ${h.r2.puts.length}`);
  assert.equal(h.r2.puts[0].key, `${USER_A.sub}/${item.kind}/${item.clientId}.json`);
});

// 4. The body cannot choose the owner.
await check(4, 'body cannot set the owner (no "someone-else" reaches storage)', async () => {
  const h = makeHarness(USER_A);
  const response = await h.call(
    syncRequest({
      method: 'POST',
      body: {
        items: [
          // Payload itself is clean, so any occurrence of the hostile strings
          // below could only come from the item's top-level fields.
          { clientId: 'a1', kind: 'note', payload: { n: 2 }, owner_sub: 'someone-else', sub: 'someone-else', owner: 'someone-else' },
        ],
      },
      ...sameOrigin,
    }),
  );
  assert.equal(response.status, 200);
  const bound = h.db.calls.flatMap((c) => c.params ?? []).map(String);
  assert.equal(
    bound.some((value) => value.includes('someone-else')),
    false,
    `a caller-supplied owner reached the database: ${JSON.stringify(bound)}`,
  );
  const keys = h.r2.puts.map((p) => p.key);
  assert.equal(keys.some((key) => key.includes('someone-else')), false, `caller-supplied owner in R2 key: ${keys}`);
  assert.equal(keys[0].startsWith(USER_A.sub + '/'), true, `R2 key not owner-scoped: ${keys[0]}`);
});

// 5. Replaying a clientId upserts instead of duplicating.
await check(5, 'replayed clientId upserts (no second row)', async () => {
  const h = makeHarness(USER_A);
  const item = { clientId: 'a1', kind: 'note', payload: { n: 1 } };
  const first = await h.call(syncRequest({ method: 'POST', body: { items: [item] }, ...sameOrigin }));
  assert.equal(first.status, 200);
  assert.equal((await first.json()).saved[0].ok, true);

  const second = await h.call(
    syncRequest({ method: 'POST', body: { items: [{ ...item, payload: { n: 99 } }] }, ...sameOrigin }),
  );
  assert.equal(second.status, 200);
  const saved = (await second.json()).saved;
  assert.equal(saved[0].ok, true, `replay was rejected: ${JSON.stringify(saved)}`);

  const rows = h.db.rows.filter((r) => r.owner_sub === USER_A.sub && r.client_id === 'a1');
  assert.equal(rows.length, 1, `expected 1 logical row after replay, got ${rows.length}`);
  assert.equal(rows[0].payload, JSON.stringify({ n: 99 }), 'replay did not update the stored payload');
});

// 6. Listing is scoped to the session's own sub and is not cacheable.
await check(6, 'GET /api/sync lists only the session owner and is no-store', async () => {
  const h = makeHarness(USER_A);
  await h.call(syncRequest({ method: 'POST', body: { items: [{ clientId: 'a1', kind: 'note', payload: { who: 'a' } }] }, ...sameOrigin }));
  h.state.user = USER_B;
  await h.call(syncRequest({ method: 'POST', body: { items: [{ clientId: 'b1', kind: 'note', payload: { who: 'b' } }] }, ...sameOrigin }));
  h.state.user = USER_A;

  const response = await h.call(syncRequest({ method: 'GET' }));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  const body = await response.json();
  assert.equal(Array.isArray(body.items), true, 'items was not an array');
  assert.equal(body.items.length, 1, `expected only user A's row, got ${body.items.length}`);
  assert.equal(body.items[0].owner_sub, USER_A.sub);
  assert.equal(body.items[0].client_id, 'a1');
  assert.equal('payload' in body.items[0], false, 'the list leaked payload bodies');
});

// 7. Invalid input is rejected per item and never 500s.
await check(7, 'invalid input rejected without a 500 (kind, clientId, oversize, non-array)', async () => {
  const h = makeHarness(USER_A);
  const response = await h.call(
    syncRequest({
      method: 'POST',
      body: {
        items: [
          { clientId: 'ok1', kind: 'bad kind!', payload: { n: 1 } },
          { kind: 'note', payload: { n: 2 } },
          { clientId: 'big1', kind: 'note', payload: 'x'.repeat(300 * 1024) },
        ],
      },
      ...sameOrigin,
    }),
  );
  assert.notEqual(response.status, 500, 'oversize/invalid input produced a 500');
  assert.equal(response.status, 200, `expected 200 with per-item errors, got ${response.status}`);
  const saved = (await response.json()).saved;
  assert.equal(saved.length, 3, `expected 3 results, got ${saved.length}`);
  assert.equal(saved[0].ok, false, 'a malformed kind was accepted');
  assert.equal(saved[1].ok, false, 'a missing clientId was accepted');
  assert.equal(saved[2].ok, false, 'an oversize payload was accepted');

  const nonArray = await h.call(syncRequest({ method: 'POST', body: { items: 'nope' }, ...sameOrigin }));
  assert.equal(nonArray.status, 400, `a non-array "items" gave ${nonArray.status}, expected 400`);
});

// 8. Payload read route: 404 when absent, stored payload when present.
await check(8, 'GET /api/sync/<kind>/<clientId> is 404 when absent and returns the stored payload', async () => {
  const h = makeHarness(USER_A);
  const missing = await h.call(syncRequest({ method: 'GET', path: '/api/sync/note/nope' }));
  assert.equal(missing.status, 404, `expected 404 for a missing object, got ${missing.status}`);

  const payload = { n: 7, nested: { ok: true } };
  await h.call(syncRequest({ method: 'POST', body: { items: [{ clientId: 'a9', kind: 'note', payload }] }, ...sameOrigin }));
  const found = await h.call(syncRequest({ method: 'GET', path: '/api/sync/note/a9' }));
  assert.equal(found.status, 200, `expected 200 for a stored object, got ${found.status}`);
  const body = await found.json();
  assert.deepEqual(body.payload, payload);
  assert.equal(typeof body.payloadHash, 'string', 'payloadHash was not returned');

  // Another user must not read it through the same route.
  h.state.user = USER_B;
  const asOther = await h.call(syncRequest({ method: 'GET', path: '/api/sync/note/a9' }));
  assert.equal(asOther.status, 404, `another user read the object (status ${asOther.status})`);
});

// 9. Other methods are refused.
await check(9, 'PUT /api/sync => 405 with Allow header', async () => {
  const h = makeHarness(USER_A);
  const response = await h.call(syncRequest({ method: 'PUT', ...sameOrigin }));
  assert.equal(response.status, 405, `expected 405, got ${response.status}`);
  const allow = response.headers.get('Allow');
  assert.equal(allow, 'GET, POST', `Allow header was ${JSON.stringify(allow)}`);
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

const passed = results.filter((r) => r.ok).length;
const total = results.length;
if (passed === total) {
  console.log(`PASS ${passed}/${total} route behaviours`);
  process.exit(0);
}
console.error(`FAIL ${passed}/${total} route behaviours`);
console.error(`failing: ${results.filter((r) => !r.ok).map((r) => r.number).join(', ')}`);
process.exit(1);
