// Schema bootstrap tests for the KernSifter sync Worker.
//
// Run with:  node test/schema.test.mjs
//
// Two things are under test, and they are different questions:
//
//   1. Parity. `src/schema.ts` holds the DDL the Worker executes on a deployed
//      database, and `src/db-schema.sql` is the copy the `d1:schema:*` scripts
//      apply locally. Two copies of one schema is exactly the kind of thing that
//      drifts silently, so both directions are asserted: every statement in the
//      code must exist in the file, and every statement in the file must exist in
//      the code.
//
//   2. Sufficiency on an EMPTY database. The deployed D1 has no other client, so
//      whatever `ensureSchema` creates is all there will ever be. These tests
//      therefore start from a database with no tables at all and drive real
//      requests — the old harness pre-created the schema, which would have made
//      a missing statement invisible until production.
//
// The database is real (node:sqlite running the DDL), so unique indexes and
// conditional UPDATE row counts are genuinely exercised. Only the platform
// bindings and the session are stubbed.

import { registerHooks } from 'node:module';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const APP_ORIGIN = 'https://sync.example.com';
const SCHEMA_SQL = readFileSync(new URL('../src/db-schema.sql', import.meta.url), 'utf8');

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
}

const { SCHEMA_STATEMENTS, ensureSchema, resetSchemaCache } = await import('../src/schema.ts');
const { handleRequest } = await import('../src/index.ts');

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
            meta: { changes: Number(result.changes), last_row_id: Number(result.lastInsertRowid) },
          };
        },
        async first() {
          return db.prepare(sql).get(...params) ?? null;
        },
      };
      return statement;
    },
    // The real batch is one transaction. This stub runs the statements in order,
    // which is enough for DDL that is uniformly IF NOT EXISTS — and the point of
    // the test is which statements exist, not atomicity.
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

/** A harness whose database is EMPTY — no schema applied. */
function makeEmptyHarness(user = null) {
  const db = new DatabaseSync(':memory:');
  resetSchemaCache();
  const env = {
    SYNC_DB: makeD1(db),
    FILES: makeFakeR2(),
    APP_ORIGIN,
    FREEBUFF_CLIENT_ID: 'test-client-id',
    FREEBUFF_ISSUER: undefined,
    ASSETS: { fetch: async () => new Response('asset', { status: 200 }) },
  };
  const state = { user };
  const signedIn = { getUser: async () => state.user };
  return { db, env, state, call: (request) => handleRequest(request, env, signedIn) };
}

const USER_A = { sub: 'user-abc' };

function req(path, { method = 'GET', body, token } = {}) {
  const headers = {};
  let payload;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  if (token) headers.Authorization = `Bearer ${token}`;
  // Same-origin, as the real consent page and web client are.
  headers.Origin = APP_ORIGIN;
  headers['Sec-Fetch-Site'] = 'same-origin';
  return new Request(`${APP_ORIGIN}${path}`, {
    method,
    headers,
    ...(payload === undefined ? {} : { body: payload }),
  });
}

const tableNames = (db) =>
  db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .all()
    .map((row) => row.name);

/**
 * Strip comments FIRST, then split on ';'.
 *
 * The order is not cosmetic: the .sql file's comments contain semicolons of
 * their own ("...clients alike; always owner-scoped"), so splitting first tears
 * a comment in half and welds the prose onto the next statement. That produces a
 * parity failure that looks like a schema difference and is not one.
 */
function stripComments(sql) {
  return String(sql).replace(/--[^\n]*/g, ' ');
}

/** Collapse whitespace so formatting is not what is being compared. */
function normalise(sql) {
  return String(sql).replace(/\s+/g, ' ').replace(/;\s*$/, '').trim();
}

const fileStatements = stripComments(SCHEMA_SQL).split(';').map(normalise).filter(Boolean);
const codeStatements = SCHEMA_STATEMENTS.map((statement) => normalise(stripComments(statement)));

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

// 1. Parity, code -> file.
await check(1, 'every statement the Worker runs also exists in db-schema.sql', () => {
  const missing = codeStatements.filter((statement) => !fileStatements.includes(statement));
  assert.deepEqual(missing, [], `statements only in src/schema.ts:\n  ${missing.join('\n  ')}`);
  assert.equal(
    codeStatements.length,
    fileStatements.length,
    `count mismatch: ${codeStatements.length} in code, ${fileStatements.length} in the file`,
  );
});

// 2. Parity, file -> code. Catches a statement added to the .sql and forgotten
//    in the Worker, which is the direction that breaks a fresh deployment.
await check(2, 'every statement in db-schema.sql is applied by the Worker', () => {
  const unapplied = fileStatements.filter((statement) => !codeStatements.includes(statement));
  assert.deepEqual(unapplied, [], `statements only in src/db-schema.sql:\n  ${unapplied.join('\n  ')}`);
});

// 3. The bootstrap actually creates the tables an empty database lacks.
await check(3, 'bootstrap creates all three tables on an empty database, idempotently', async () => {
  const h = makeEmptyHarness();
  assert.deepEqual(tableNames(h.db), [], 'the fixture database was not empty');

  await ensureSchema(h.env.SYNC_DB);
  const created = tableNames(h.db);
  for (const table of ['kernsifter_items', 'kernsifter_device_codes', 'kernsifter_tokens']) {
    assert.equal(created.includes(table), true, `${table} was not created (tables: ${created.join(', ')})`);
  }

  // Second and third application must be silent no-ops, not errors.
  await ensureSchema(h.env.SYNC_DB);
  resetSchemaCache();
  await ensureSchema(h.env.SYNC_DB);
  assert.deepEqual(tableNames(h.db), created, 're-applying the schema changed the table set');
});

// 4. Sufficiency: an empty database plus one real request set is enough for the
//    whole native flow. This is the test that would have caught a table the
//    Worker needs but never creates.
await check(4, 'the full device flow works on a database the Worker bootstraps itself', async () => {
  const h = makeEmptyHarness(USER_A);
  assert.deepEqual(tableNames(h.db), [], 'the fixture database was not empty');

  // A native client starts an authorization — the first request ever served.
  // Read each body before any assertion message mentions it: template arguments
  // are evaluated eagerly, so `await response.text()` inside a message would
  // consume the body and break the read that follows.
  const authorize = await h.call(req('/api/device/authorize', { method: 'POST', body: { client_name: 'KernSifter desktop' } }));
  const grant = await authorize.json();
  assert.equal(authorize.status, 200, `authorize status ${authorize.status}: ${JSON.stringify(grant)}`);
  assert.match(grant.user_code, /^[0-9A-Z]{4}-[0-9A-Z]{4}$/, `user_code shape: ${grant.user_code}`);

  // The human approves with a session on the consent page.
  const approve = await h.call(req('/api/device/approve', { method: 'POST', body: { user_code: grant.user_code } }));
  const approveBody = await approve.json();
  assert.equal(approve.status, 200, `approve status ${approve.status}: ${JSON.stringify(approveBody)}`);

  // The client redeems it.
  const polled = await h.call(req('/api/device/token', { method: 'POST', body: { device_code: grant.device_code } }));
  const granted = await polled.json();
  assert.equal(polled.status, 200, `poll status ${polled.status}: ${JSON.stringify(granted)}`);
  const token = granted.access_token;
  assert.match(token, /^ks_[0-9a-f]{64}$/, `token shape: ${token}`);

  // And the token writes and reads back through all three tables plus R2.
  const save = await h.call(req('/api/sync', { method: 'POST', token, body: { items: [{ clientId: 'c1', kind: 'note', payload: { hello: 'world' } }] } }));
  const saved = await save.json();
  assert.equal(save.status, 200, `save status ${save.status}: ${JSON.stringify(saved)}`);
  assert.equal(saved.saved[0].ok, true, `the item was not saved: ${JSON.stringify(saved.saved[0])}`);

  const list = await h.call(req('/api/sync', { token }));
  assert.equal(list.status, 200, `list status ${list.status}`);
  assert.equal((await list.json()).items.length, 1, 'the saved item did not come back');

  const read = await h.call(req('/api/sync/note/c1', { token }));
  assert.equal(read.status, 200, `payload read status ${read.status}`);
  assert.deepEqual((await read.json()).payload, { hello: 'world' }, 'the payload came back wrong');

  const tokens = await h.call(req('/api/tokens', { token }));
  assert.equal(tokens.status, 200, `token list status ${tokens.status}`);
  assert.equal((await tokens.json()).tokens.length, 1, 'the token was not listed');
});

// 5. A failed bootstrap must not be memoised, or one unreachable moment on a
//    cold isolate would report 503 for that isolate's whole life.
await check(5, 'a failed bootstrap is retried rather than cached', async () => {
  resetSchemaCache();
  let attempts = 0;
  const flaky = {
    prepare: () => ({ run: async () => ({}) }),
    batch: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error('database unavailable');
      return [];
    },
  };

  await assert.rejects(() => ensureSchema(flaky), /database unavailable/);
  await ensureSchema(flaky);
  assert.equal(attempts, 2, `expected a retry after failure, saw ${attempts} attempt(s)`);
});

// 6. A database that cannot be initialised must 503, not 500 and not 401 — and
//    the response must say so rather than pretending the caller is unauthorised.
await check(6, 'a database failure surfaces as 503, not as a policy refusal', async () => {
  resetSchemaCache();
  const env = {
    SYNC_DB: {
      prepare: () => ({ run: async () => ({}) }),
      batch: async () => {
        throw new Error('boom');
      },
    },
    FILES: makeFakeR2(),
    APP_ORIGIN,
    FREEBUFF_CLIENT_ID: 'test-client-id',
    ASSETS: { fetch: async () => new Response('asset', { status: 200 }) },
  };
  const signedIn = { getUser: async () => USER_A };
  const response = await handleRequest(req('/api/sync'), env, signedIn);
  assert.equal(response.status, 503, `expected 503, got ${response.status}`);
  assert.deepEqual(await response.json(), { error: 'temporarily_unavailable' });
});

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

const passed = results.filter((r) => r.ok).length;
const total = results.length;
if (passed === total) {
  console.log(`PASS ${passed}/${total} schema behaviours`);
  process.exit(0);
}
console.error(`FAIL ${passed}/${total} schema behaviours`);
console.error(`failing: ${results.filter((r) => !r.ok).map((r) => r.number).join(', ')}`);
process.exit(1);
