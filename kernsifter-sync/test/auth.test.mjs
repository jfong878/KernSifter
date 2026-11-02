// Device-authorization and bearer-token tests for the KernSifter sync Worker.
//
// Run with:  node test/auth.test.mjs
//
// The Worker source is TypeScript with extensionless relative imports, so this
// test installs the same in-process resolve hook as test/routes.test.mjs and
// imports the source afterwards.
//
// Unlike the route tests, the database here is REAL: node:sqlite runs the real
// src/db-schema.sql, so the schema itself is under test — unique indexes,
// conditional UPDATE row counts, and all. Only the two platform bindings and
// the session are stubbed, and the same-origin check is the SDK's real
// implementation.

import { registerHooks } from 'node:module';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const APP_ORIGIN = 'https://sync.example.com';
const FOREIGN_ORIGIN = 'https://evil.example';
const SCHEMA = readFileSync(new URL('../src/db-schema.sql', import.meta.url), 'utf8');

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

let handleRequest;
const importErrors = [];
for (const specifier of ['../src/index.ts', '../src/index.js', '../src/index']) {
  try {
    ({ handleRequest } = await import(specifier));
    break;
  } catch (error) {
    importErrors.push(`${specifier} -> ${error?.code ?? error?.name}: ${error?.message}`);
  }
}

if (typeof handleRequest !== 'function') {
  console.error('FATAL: could not import handleRequest from the Worker source.');
  console.error(`  registerHooks available: ${hookInstalled} (node ${process.version})`);
  for (const line of importErrors) console.error(`  - ${line}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Bindings
// ---------------------------------------------------------------------------

/** Adapts node:sqlite to the slice of the D1 interface the source uses. */
function makeD1(db) {
  return {
    prepare(sqlText) {
      const sql = String(sqlText);
      let params = [];
      const statement = {
        bind(...args) {
          params = args;
          return statement;
        },
        async all() {
          return { success: true, results: db.prepare(sql).all(...params) };
        },
        async run() {
          const result = db.prepare(sql).run(...params);
          return {
            success: true,
            meta: {
              changes: Number(result.changes),
              last_row_id: Number(result.lastInsertRowid),
            },
          };
        },
        async first() {
          return db.prepare(sql).get(...params) ?? null;
        },
      };
      return statement;
    },
    // The Worker applies its schema through `batch` on the first storage route
    // it serves. The harness below already applied the schema, so this is always
    // the idempotent no-op path — but it has to exist or the route handlers
    // cannot run at all.
    async batch(statements) {
      const results = [];
      for (const statement of statements) results.push(await statement.run());
      return results;
    },
  };
}

function makeFakeR2() {
  const objects = new Map();
  return {
    objects,
    async put(key, value) {
      objects.set(key, String(value));
      return { key };
    },
    async get(key) {
      if (!objects.has(key)) return null;
      const value = objects.get(key);
      return { key, customMetadata: {}, text: async () => value };
    },
  };
}

function makeHarness(initialUser = null) {
  const db = new DatabaseSync(':memory:');
  db.exec(SCHEMA);
  const env = {
    SYNC_DB: makeD1(db),
    FILES: makeFakeR2(),
    APP_ORIGIN,
    FREEBUFF_CLIENT_ID: 'test-client-id',
    FREEBUFF_ISSUER: undefined,
    ASSETS: { fetch: async () => new Response('asset', { status: 200 }) },
  };
  const state = { user: initialUser };
  const signedIn = { getUser: async () => state.user };
  const call = (request) => handleRequest(request, env, signedIn);
  return { db, env, state, call };
}

const USER_A = { sub: 'user-abc' };
const USER_B = { sub: 'user-other' };

function req(path, { method = 'GET', body, form, origin, fetchSite, token, cookie, authorization } = {}) {
  const headers = {};
  let payload;
  if (form !== undefined) {
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    payload = new URLSearchParams(form).toString();
  } else if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  if (origin) headers.Origin = origin;
  if (fetchSite) headers['Sec-Fetch-Site'] = fetchSite;
  if (token) headers.Authorization = `Bearer ${token}`;
  // Raw header, for the cases where a bearer token must be absent or malformed.
  if (authorization !== undefined) headers.Authorization = authorization;
  if (cookie) headers.Cookie = cookie;
  return new Request(`${APP_ORIGIN}${path}`, {
    method,
    headers,
    ...(payload === undefined ? {} : { body: payload }),
  });
}

const sameOrigin = { origin: APP_ORIGIN, fetchSite: 'same-origin' };
const foreignOrigin = { origin: FOREIGN_ORIGIN, fetchSite: 'cross-site' };

/** Every string value in every table, for "is this secret stored in the clear?" checks. */
function storeDump(db) {
  const values = [];
  for (const table of ['kernsifter_items', 'kernsifter_device_codes', 'kernsifter_tokens']) {
    for (const row of db.prepare(`SELECT * FROM ${table}`).all()) {
      for (const value of Object.values(row)) {
        if (typeof value === 'string') values.push(value);
      }
    }
  }
  return values.join('\n');
}

const count = (db, sql) => Number(db.prepare(sql).get().n);

/** Start a device authorization. Returns the parsed response and the harness. */
async function authorize(h = makeHarness(USER_A), clientName = 'KernSifter desktop') {
  const response = await h.call(req('/api/device/authorize', { method: 'POST', body: { client_name: clientName } }));
  return { response, body: await response.json(), h };
}

async function approve(h, userCode, options = sameOrigin) {
  return h.call(req('/api/device/approve', { method: 'POST', body: { user_code: userCode }, ...options }));
}

async function poll(h, deviceCode) {
  const response = await h.call(req('/api/device/token', { method: 'POST', body: { device_code: deviceCode } }));
  return { response, body: await response.json() };
}

/** Freeze the polling clock: pretend the client waited a full interval. */
function allowNextPoll(db) {
  db.exec('UPDATE kernsifter_device_codes SET last_poll_at = NULL');
}

/** Full happy path. Returns the bearer token. */
async function tokenFor(h, user = USER_A) {
  h.state.user = user;
  const { body } = await authorize(h);
  await approve(h, body.user_code);
  const polled = await poll(h, body.device_code);
  return { deviceCode: body.device_code, userCode: body.user_code, token: polled.body.access_token, polled };
}

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

// 1. Secrets are returned once and stored only as hashes.
await check(1, 'authorize returns an RFC-shaped grant and stores only hashes', async () => {
  const h = makeHarness(USER_A);
  const { response, body } = await authorize(h);
  assert.equal(response.status, 200);
  assert.match(body.device_code, /^ksd_[0-9a-f]{64}$/, `device_code shape: ${body.device_code}`);
  assert.match(body.user_code, /^[0-9A-Z]{4}-[0-9A-Z]{4}$/, `user_code shape: ${body.user_code}`);
  assert.equal(body.verification_uri, `${APP_ORIGIN}/device`);
  assert.equal(body.expires_in, 600);
  assert.equal(body.interval, 5);
  assert.equal(
    body.verification_uri_complete,
    `${APP_ORIGIN}/device?code=${encodeURIComponent(body.user_code)}`,
  );

  const dump = storeDump(h.db);
  assert.equal(dump.includes(body.device_code), false, 'the device_code is stored in the clear');
  assert.equal(
    dump.includes(body.user_code.replace('-', '')),
    false,
    'the user_code is stored in the clear',
  );
  assert.equal(count(h.db, 'SELECT COUNT(*) AS n FROM kernsifter_device_codes'), 1);
  assert.equal(count(h.db, 'SELECT COUNT(*) AS n FROM kernsifter_tokens'), 0, 'a token existed before approval');
});

// 2. Polling before approval issues nothing.
await check(2, 'poll before approval => authorization_pending, no token', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  const { response, body: polled } = await poll(h, body.device_code);
  assert.equal(response.status, 400, `expected 400, got ${response.status}`);
  assert.deepEqual(polled, { error: 'authorization_pending' });
  assert.equal(count(h.db, 'SELECT COUNT(*) AS n FROM kernsifter_tokens'), 0);
});

// 3. The polling interval is enforced, and widens after a violation.
await check(3, 'a hot poller gets slow_down and a widened interval', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  allowNextPoll(h.db);
  assert.deepEqual((await poll(h, body.device_code)).body, { error: 'authorization_pending' });
  const intervalBefore = Number(h.db.prepare('SELECT poll_interval_seconds AS n FROM kernsifter_device_codes').get().n);

  // Immediately again: inside the interval.
  const { response, body: slow } = await poll(h, body.device_code);
  assert.equal(response.status, 400, `expected 400, got ${response.status}`);
  assert.deepEqual(slow, { error: 'slow_down' });

  const intervalAfter = Number(h.db.prepare('SELECT poll_interval_seconds AS n FROM kernsifter_device_codes').get().n);
  assert.equal(intervalAfter, intervalBefore + 5, `interval went ${intervalBefore} -> ${intervalAfter}, expected +5`);
});

// 4. An unknown device code is indistinguishable from a bad one.
await check(4, 'an unknown device code => invalid_grant', async () => {
  const h = makeHarness(USER_A);
  const { response, body } = await poll(h, 'ksd_' + 'f'.repeat(64));
  assert.equal(response.status, 400);
  assert.deepEqual(body, { error: 'invalid_grant' });
});

// 5. Approval mints exactly one token, owned by the session subject.
await check(5, 'approve then poll mints a token owned by the session sub', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  const approved = await approve(h, body.user_code);
  assert.equal(approved.status, 200, `approve status ${approved.status}`);

  const { response, body: polled } = await poll(h, body.device_code);
  assert.equal(response.status, 200, `poll status ${response.status}: ${JSON.stringify(polled)}`);
  assert.match(polled.access_token, /^ks_[0-9a-f]{64}$/, `token shape: ${polled.access_token}`);
  assert.equal(polled.token_type, 'Bearer');
  assert.equal(polled.expires_in, 30 * 24 * 60 * 60);

  const rows = h.db.prepare('SELECT owner_sub, label FROM kernsifter_tokens').all();
  assert.equal(rows.length, 1, `expected 1 token row, got ${rows.length}`);
  assert.equal(rows[0].owner_sub, USER_A.sub, 'the token is not owned by the approving session');
  assert.equal(rows[0].label, 'KernSifter desktop', 'the client name did not become the token label');
  assert.equal(storeDump(h.db).includes(polled.access_token), false, 'the token is stored in the clear');
});

// 6. One approval, one token — even if the device polls again.
await check(6, 'a device code is single-use', async () => {
  const h = makeHarness(USER_A);
  const { deviceCode, token } = await tokenFor(h);
  assert.equal(typeof token, 'string', 'no token was issued');
  assert.equal(
    h.db.prepare('SELECT status FROM kernsifter_device_codes').get().status,
    'redeemed',
    'the device code was not marked redeemed',
  );

  const replay = await poll(h, deviceCode);
  assert.equal(replay.response.status, 400, `replay status ${replay.response.status}`);
  assert.deepEqual(replay.body, { error: 'invalid_grant' });
  assert.equal(count(h.db, 'SELECT COUNT(*) AS n FROM kernsifter_tokens'), 1, 'a replay minted a second token');
});

// 7. The browser approval step keeps its CSRF protection.
await check(7, 'approve from a foreign origin => 403 and still pending', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  const response = await approve(h, body.user_code, foreignOrigin);
  assert.equal(response.status, 403, `expected 403, got ${response.status}`);
  assert.deepEqual(await response.json(), { error: 'forbidden' });

  const row = h.db.prepare('SELECT status, owner_sub FROM kernsifter_device_codes').get();
  assert.equal(row.status, 'pending', 'a cross-origin post advanced the authorization');
  assert.equal(row.owner_sub, null, 'a cross-origin post bound an owner');
  assert.equal((await poll(h, body.device_code)).body.error, 'authorization_pending');
});

// 8. Approving requires being signed in at all.
await check(8, 'approve while signed out => 401, still pending', async () => {
  const h = makeHarness(null);
  const { body } = await authorize(h);
  const response = await approve(h, body.user_code);
  assert.equal(response.status, 401, `expected 401, got ${response.status}`);
  assert.equal(h.db.prepare('SELECT status FROM kernsifter_device_codes').get().status, 'pending');
});

// 9. A machine credential must not mint another machine credential.
await check(9, 'approve with a bearer token instead of a session => 403 session_required', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  const { body } = await authorize(h);
  const response = await h.call(
    req('/api/device/approve', { method: 'POST', body: { user_code: body.user_code }, token, ...sameOrigin }),
  );
  assert.equal(response.status, 403, `expected 403, got ${response.status}`);
  assert.deepEqual(await response.json(), { error: 'session_required' });
  assert.equal(h.db.prepare("SELECT COUNT(*) AS n FROM kernsifter_device_codes WHERE status = 'approved'").get().n, 0);
});

// 10. Denial is terminal and visible to the polling client.
await check(10, 'deny => the device learns access_denied and gets no token', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  const denied = await h.call(req('/api/device/deny', { method: 'POST', body: { user_code: body.user_code }, ...sameOrigin }));
  assert.equal(denied.status, 200, `deny status ${denied.status}`);
  assert.deepEqual((await poll(h, body.device_code)).body, { error: 'access_denied' });
  assert.equal(count(h.db, 'SELECT COUNT(*) AS n FROM kernsifter_tokens'), 0);
});

// 11. Bad codes do not become approvals.
await check(11, 'an invalid user code is rejected', async () => {
  const h = makeHarness(USER_A);
  await authorize(h);
  const lookup = await h.call(req('/api/device/lookup', { method: 'POST', body: { user_code: 'ZZZZ-ZZZZ' }, ...sameOrigin }));
  assert.equal(lookup.status, 404, `lookup status ${lookup.status}`);
  assert.deepEqual(await lookup.json(), { error: 'invalid_user_code' });

  // 'O' and '0'/'1' are absent from the alphabet by design.
  const withAmbiguous = await h.call(req('/api/device/lookup', { method: 'POST', body: { user_code: 'OOOO-OOOO' }, ...sameOrigin }));
  assert.equal(withAmbiguous.status, 404, `ambiguous-alphabet code gave ${withAmbiguous.status}`);
  assert.equal(h.db.prepare('SELECT COUNT(*) AS n FROM kernsifter_tokens').get().n, 0);
});

// 12. The human types it however they like.
await check(12, 'a lowercase, dashless user code still approves', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  const typed = body.user_code.replace('-', '').toLowerCase();
  const response = await approve(h, typed);
  assert.equal(response.status, 200, `expected 200, got ${response.status}`);
  const polled = await poll(h, body.device_code);
  assert.equal(polled.response.status, 200, `poll after lowercase approval: ${JSON.stringify(polled.body)}`);
});

// 13. Expiry is enforced on both sides of the flow.
await check(13, 'an expired device code => expired_token and cannot be approved', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h);
  h.db.exec('UPDATE kernsifter_device_codes SET expires_at = 1');
  assert.deepEqual((await poll(h, body.device_code)).body, { error: 'expired_token' });
  const response = await approve(h, body.user_code);
  assert.equal(response.status, 400, `approving an expired code gave ${response.status}`);
  assert.deepEqual(await response.json(), { error: 'expired_token' });
});

// 14. A bearer token reads its own owner's data.
await check(14, 'bearer GET /api/sync is scoped to the token owner', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  // Seed one item per user through the session path.
  await h.call(req('/api/sync', { method: 'POST', body: { items: [{ clientId: 'a1', kind: 'note', payload: { who: 'a' } }] }, ...sameOrigin }));
  h.state.user = USER_B;
  await h.call(req('/api/sync', { method: 'POST', body: { items: [{ clientId: 'b1', kind: 'note', payload: { who: 'b' } }] }, ...sameOrigin }));
  h.state.user = null;

  const response = await h.call(req('/api/sync', { token }));
  assert.equal(response.status, 200, `bearer GET status ${response.status}`);
  assert.equal(response.headers.get('Cache-Control'), 'private, no-store');
  const { items } = await response.json();
  assert.equal(items.length, 1, `expected 1 item for the token owner, got ${items.length}`);
  assert.equal(items[0].owner_sub, USER_A.sub);
  assert.equal(items[0].client_id, 'a1');
});

// 15. Deliberate: a token needs no origin check, because it is not ambient.
await check(15, 'bearer POST from a foreign origin succeeds, owned by the token', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  const response = await h.call(
    req('/api/sync', { method: 'POST', body: { items: [{ clientId: 'n1', kind: 'note', payload: { n: 1 } }] }, token, ...foreignOrigin }),
  );
  assert.equal(response.status, 200, `expected 200, got ${response.status}: ${JSON.stringify(await response.json())}`);
  const row = h.db.prepare('SELECT owner_sub FROM kernsifter_items').get();
  assert.equal(row.owner_sub, USER_A.sub, 'the row was not owned by the token subject');
});

// 16. Regression guard: the web client's protection is unchanged.
await check(16, 'session POST from a foreign origin is still 403', async () => {
  const h = makeHarness(USER_A);
  const response = await h.call(
    req('/api/sync', { method: 'POST', body: { items: [{ clientId: 'x', kind: 'note', payload: {} }] }, ...foreignOrigin }),
  );
  assert.equal(response.status, 403, `expected 403, got ${response.status}`);
  assert.equal(count(h.db, 'SELECT COUNT(*) AS n FROM kernsifter_items'), 0);
});

// 17. No confused deputy: an unusable credential is not a session.
await check(17, 'an unusable Authorization header does NOT fall back to the session', async () => {
  const h = makeHarness(USER_A);
  const cookie = '__Host-freebuff_session=whatever';

  // A well-formed bearer token that no row matches.
  const unknown = await h.call(req('/api/sync', { token: 'ks_' + 'a'.repeat(64), cookie }));
  assert.equal(unknown.status, 401, `expected 401, got ${unknown.status}`);
  assert.deepEqual(await unknown.json(), { error: 'sign_in_required' });

  // A bearer header with no credential in it (the Headers API trims the value).
  const empty = await h.call(req('/api/sync', { authorization: 'Bearer ', cookie }));
  assert.equal(empty.status, 401, 'an empty bearer token fell back to the session');

  // A scheme we do not implement must not be ignored in favour of the cookie.
  const wrongScheme = await h.call(req('/api/sync', { authorization: 'Basic dXNlcjpwYXNz', cookie }));
  assert.equal(wrongScheme.status, 401, 'a non-Bearer Authorization header was treated as a session');
});

// 18/19. Revoked and expired tokens stop working.
await check(18, 'a revoked token => 401', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  h.db.exec(`UPDATE kernsifter_tokens SET revoked_at = ${Date.now()}`);
  const response = await h.call(req('/api/sync', { token }));
  assert.equal(response.status, 401, `expected 401, got ${response.status}`);
});

await check(19, 'an expired token => 401', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  h.db.exec('UPDATE kernsifter_tokens SET expires_at = 1');
  const response = await h.call(req('/api/sync', { token }));
  assert.equal(response.status, 401, `expected 401, got ${response.status}`);
});

// 20. Owner scoping holds for the payload route too.
await check(20, "a token cannot read another owner's payload", async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  h.state.user = USER_B;
  await h.call(req('/api/sync', { method: 'POST', body: { items: [{ clientId: 'secret', kind: 'note', payload: { hidden: true } }] }, ...sameOrigin }));
  h.state.user = null;

  const response = await h.call(req('/api/sync/note/secret', { token }));
  assert.equal(response.status, 404, `another owner's payload was readable (${response.status})`);
});

// 21. The token list is the user's own, and never leaks the secret.
await check(21, 'GET /api/tokens lists only own tokens and marks the current one', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  // A second account's token, so the list has something it must exclude.
  h.state.user = USER_B;
  const other = await tokenFor(h, USER_B);

  const response = await h.call(req('/api/tokens', { token }));
  assert.equal(response.status, 200, `status ${response.status}`);
  const { tokens } = await response.json();
  assert.equal(tokens.length, 1, `expected 1 token, got ${tokens.length}`);
  assert.equal(tokens[0].current, true, 'the caller’s own token was not marked current');
  const serialised = JSON.stringify(tokens);
  assert.equal(serialised.includes(token), false, 'the list leaked a token value');
  assert.equal(serialised.includes(other.token), false, 'the list leaked another user’s token');
  assert.equal(serialised.toLowerCase().includes('token_hash'), false, 'the list leaked a hash column');
});

// 22. Revocation is owner-scoped.
await check(22, "revoking another user's token id => 404 and it still works", async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);
  h.state.user = USER_B;
  const other = await tokenFor(h, USER_B);
  h.state.user = null;

  // The newest token belongs to USER_B; the caller is USER_A.
  const otherRow = h.db.prepare('SELECT id, owner_sub FROM kernsifter_tokens ORDER BY id DESC LIMIT 1').get();
  assert.equal(otherRow.owner_sub, USER_B.sub, 'the fixture did not set up two owners');

  const response = await h.call(
    req('/api/tokens/revoke', { method: 'POST', body: { id: otherRow.id }, token, ...foreignOrigin }),
  );
  assert.equal(response.status, 404, `expected 404, got ${response.status}`);
  const stillWorks = await h.call(req('/api/sync', { token: other.token }));
  assert.equal(stillWorks.status, 200, 'another user’s token was revoked');
});

// 23. Revoke-all spares the caller's own credential.
await check(23, 'revoke all keeps the calling token usable', async () => {
  const h = makeHarness(USER_A);
  const first = await tokenFor(h);
  const second = await tokenFor(h, USER_A);
  assert.notEqual(first.token, second.token);

  const response = await h.call(req('/api/tokens/revoke', { method: 'POST', body: { all: true }, token: second.token }));
  assert.equal(response.status, 200, `status ${response.status}`);
  assert.equal((await response.json()).revoked, 1, 'expected exactly one other token to be revoked');

  assert.equal((await h.call(req('/api/sync', { token: first.token }))).status, 401, 'the other token survived revoke-all');
  assert.equal((await h.call(req('/api/sync', { token: second.token }))).status, 200, 'revoke-all killed the caller’s own token');
});

// 24. The consent page cannot be used to inject markup.
await check(24, 'a hostile client name is escaped on the consent page', async () => {
  const h = makeHarness(USER_A);
  const hostile = '<script>alert(1)</script>';
  const { body } = await authorize(h, hostile);
  const stored = h.db.prepare('SELECT client_name FROM kernsifter_device_codes').get().client_name;
  assert.equal(stored, hostile, 'the client name was not stored verbatim for this test to be meaningful');

  const page = await h.call(req(`/device?code=${encodeURIComponent(body.user_code)}`, { cookie: '__Host-freebuff_session=x' }));
  assert.equal(page.status, 200, `page status ${page.status}`);
  const html = await page.text();
  assert.equal(html.includes(hostile), false, 'the raw client name reached the page');
  assert.equal(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'), true, 'the client name was not escaped');
  assert.equal(html.includes('<script'), false, 'the page contains a script tag');
});

// 25. The page states what is being approved and is locked down by CSP.
await check(25, 'the consent page names the client and sets a strict CSP', async () => {
  const h = makeHarness(USER_A);
  const { body } = await authorize(h, 'KernSifter mobile');
  const page = await h.call(req(`/device?code=${encodeURIComponent(body.user_code)}`));
  const html = await page.text();
  assert.equal(html.includes('KernSifter mobile'), true, 'the page did not name the requesting client');
  assert.equal(html.includes('Approve'), true, 'no approve control');
  assert.equal(html.includes('Deny'), true, 'no deny control');
  const csp = page.headers.get('Content-Security-Policy');
  assert.match(csp, /default-src 'none'/, `CSP was ${JSON.stringify(csp)}`);
  assert.match(csp, /form-action 'self'/, `CSP was ${JSON.stringify(csp)}`);
  assert.equal(page.headers.get('Cache-Control'), 'no-store');
});

// 26-28. CORS: the desktop webview is a browser, but it is allowlisted by name.
const TAURI_ORIGIN = 'http://tauri.localhost';

await check(26, 'CORS preflight is answered for the shell origin and refused otherwise', async () => {
  const h = makeHarness(USER_A);
  const allowed = await h.call(
    new Request(`${APP_ORIGIN}/api/device/authorize`, {
      method: 'OPTIONS',
      headers: {
        Origin: TAURI_ORIGIN,
        'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'content-type',
      },
    }),
  );
  assert.equal(allowed.status, 204, `allowed preflight status ${allowed.status}`);
  assert.equal(allowed.headers.get('Access-Control-Allow-Origin'), TAURI_ORIGIN);
  assert.notEqual(allowed.headers.get('Access-Control-Allow-Origin'), '*', 'a wildcard origin was returned');
  assert.equal(
    allowed.headers.get('Access-Control-Allow-Credentials'),
    null,
    'credentialed CORS was enabled, which would let a page ride a cookie',
  );
  assert.equal(allowed.headers.get('Vary'), 'Origin');

  const foreign = await h.call(
    new Request(`${APP_ORIGIN}/api/device/authorize`, {
      method: 'OPTIONS',
      headers: { Origin: FOREIGN_ORIGIN, 'Access-Control-Request-Method': 'POST' },
    }),
  );
  assert.equal(foreign.status, 403, `foreign preflight status ${foreign.status}`);
  assert.equal(foreign.headers.get('Access-Control-Allow-Origin'), null, 'a foreign origin was allowed');
});

await check(27, 'a web page cannot read a device code, but the shell can', async () => {
  const h = makeHarness(USER_A);
  // The endpoint is unauthenticated by design; the protection against the
  // device-flow phishing shape is that a foreign page gets no CORS headers, so
  // the browser will not hand it the device_code it just created.
  const fromPage = await h.call(
    req('/api/device/authorize', { method: 'POST', body: { client_name: 'phish' }, origin: FOREIGN_ORIGIN }),
  );
  assert.equal(fromPage.status, 200, `authorize status ${fromPage.status}`);
  assert.equal(fromPage.headers.get('Access-Control-Allow-Origin'), null, 'a foreign page could read the device code');
  assert.equal(fromPage.headers.get('Access-Control-Allow-Credentials'), null);

  const fromShell = await h.call(
    req('/api/device/authorize', { method: 'POST', body: { client_name: 'KernSifter desktop' }, origin: TAURI_ORIGIN }),
  );
  assert.equal(
    fromShell.headers.get('Access-Control-Allow-Origin'),
    TAURI_ORIGIN,
    'the shell origin was not allowed to read its own device code',
  );
});

await check(28, 'sync responses expose CORS only to the shell origin', async () => {
  const h = makeHarness(USER_A);
  const { token } = await tokenFor(h);

  const shell = await h.call(req('/api/sync', { token, origin: TAURI_ORIGIN }));
  assert.equal(shell.status, 200, `shell status ${shell.status}`);
  assert.equal(shell.headers.get('Access-Control-Allow-Origin'), TAURI_ORIGIN);

  const foreign = await h.call(req('/api/sync', { token, origin: FOREIGN_ORIGIN }));
  assert.equal(foreign.status, 200, 'a bearer call is not origin-gated, only its readable CORS headers are');
  assert.equal(foreign.headers.get('Access-Control-Allow-Origin'), null, 'a foreign page could read synced data');
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

const passed = results.filter((r) => r.ok).length;
const total = results.length;
if (passed === total) {
  console.log(`PASS ${passed}/${total} auth behaviours`);
  process.exit(0);
}
console.error(`FAIL ${passed}/${total} auth behaviours`);
console.error(`failing: ${results.filter((r) => !r.ok).map((r) => r.number).join(', ')}`);
process.exit(1);
