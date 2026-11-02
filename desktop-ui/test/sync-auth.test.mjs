// Dependency-free tests for the desktop device-authorization client.
//
// Run with:  node test/sync-auth.test.mjs   (or: npm test)
//
// `fetch`, `sleep` and the token store are all injected, so this exercises the
// real flow — polling, slow_down backoff, error mapping, token custody — with no
// network, no Tauri and no waiting.

import assert from 'node:assert/strict';

import { DeviceAuthError, DeviceAuthFailure, createDeviceAuthClient } from '../src/sync-auth.js';

const ORIGIN = 'https://sync.example.com';
const TOKEN = 'ks_' + 'a'.repeat(64);

/** Records what was stored, so "did it persist exactly once?" is assertable. */
function memoryStore(initial = null) {
  const state = { token: initial, writes: 0, clears: 0 };
  return {
    state,
    async read() {
      return state.token;
    },
    async write(token) {
      state.writes += 1;
      state.token = token;
    },
    async clear() {
      state.clears += 1;
      state.token = null;
    },
  };
}

/** Scripted fetch: one queued response per call, and every request recorded. */
function makeFetch(script) {
  const requests = [];
  let index = 0;
  return {
    requests,
    async fetchImpl(url, init) {
      requests.push({
        url: String(url),
        method: init.method,
        headers: init.headers ?? {},
        body: init.body === undefined ? undefined : JSON.parse(init.body),
      });
      const step = script[index];
      index += 1;
      if (!step) throw new Error(`unexpected request #${index} to ${url}`);
      return { status: step.status, text: async () => JSON.stringify(step.body ?? {}) };
    },
  };
}

function clientFor(script, store = memoryStore()) {
  const { requests, fetchImpl } = makeFetch(script);
  const slept = [];
  const client = createDeviceAuthClient({
    origin: ORIGIN,
    store,
    fetchImpl,
    sleep: async (ms) => slept.push(ms),
  });
  return { client, store, requests, slept };
}

const GRANT = {
  device_code: 'ksd_' + 'b'.repeat(64),
  user_code: 'BCDF-GHJK',
  verification_uri: `${ORIGIN}/device`,
  verification_uri_complete: `${ORIGIN}/device?code=BCDF-GHJK`,
  expires_in: 600,
  interval: 5,
};

const results = [];
async function check(number, name, fn) {
  try {
    await fn();
    results.push({ number, ok: true });
    console.log(`ok ${number} - ${name}`);
  } catch (error) {
    results.push({ number, ok: false });
    console.error(`not ok ${number} - ${name}\n    ${error?.message ?? error}`);
  }
}

await check(1, 'startDeviceLogin posts JSON and maps the grant', async () => {
  const { client, requests } = clientFor([{ status: 200, body: GRANT }]);
  const authorization = await client.startDeviceLogin();

  assert.equal(authorization.deviceCode, GRANT.device_code);
  assert.equal(authorization.userCode, 'BCDF-GHJK');
  assert.equal(authorization.verificationUriComplete, GRANT.verification_uri_complete);
  assert.equal(authorization.interval, 5);
  assert.equal(authorization.expiresIn, 600);

  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, `${ORIGIN}/api/device/authorize`);
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].headers['Content-Type'], 'application/json');
  assert.deepEqual(requests[0].body, { client_name: 'KernSifter desktop' });
  // The unauthenticated endpoints must never see the token.
  assert.equal(requests[0].headers.Authorization, undefined, 'a token was sent to the authorize endpoint');

  await assert.rejects(
    () => clientFor([{ status: 200, body: { device_code: 'x' } }]).client.startDeviceLogin(),
    (error) => error instanceof DeviceAuthError && error.reason === DeviceAuthFailure.malformed,
    'an incomplete grant was accepted',
  );
});

await check(2, 'connect polls pending/slow_down, backsoff, and stores the token once', async () => {
  // connect() = startDeviceLogin() then pollForToken(), so the grant comes first.
  const { client, store, requests, slept } = clientFor([
    { status: 200, body: GRANT },
    { status: 400, body: { error: 'authorization_pending' } },
    { status: 400, body: { error: 'slow_down' } },
    { status: 200, body: { access_token: TOKEN, token_type: 'Bearer', expires_in: 2592000 } },
  ]);

  const codes = [];
  const token = await client.connect({ onCode: (grant) => codes.push(grant.userCode) });

  assert.equal(token, TOKEN);
  assert.deepEqual(codes, ['BCDF-GHJK'], 'the user code was not surfaced for display');
  assert.deepEqual(slept, [5000, 10000], `slow_down did not widen the interval: ${JSON.stringify(slept)}`);
  assert.equal(store.state.writes, 1, `expected exactly one write, got ${store.state.writes}`);
  assert.equal(requests.length, 4, `expected authorize + 3 polls, got ${requests.length} requests`);
  assert.equal(requests[3].url, `${ORIGIN}/api/device/token`);
  assert.deepEqual(requests[3].body, { device_code: GRANT.device_code });
  assert.equal(requests[3].headers.Authorization, undefined, 'a token was sent to the token endpoint');
  assert.equal(
    requests.every((request) => !request.url.includes(TOKEN)),
    true,
    'the token appeared in a URL',
  );
});

await check(3, 'access_denied surfaces a typed error and stores nothing', async () => {
  const { client, store } = clientFor([
    { status: 200, body: GRANT },
    { status: 400, body: { error: 'authorization_pending' } },
    { status: 400, body: { error: 'access_denied' } },
  ]);
  await assert.rejects(
    () => client.connect(),
    (error) => error instanceof DeviceAuthError && error.reason === DeviceAuthFailure.accessDenied,
  );
  assert.equal(store.state.writes, 0, 'a token was stored after a denial');
  assert.equal(store.state.token, null);
});

await check(4, 'expired_token and invalid_grant map to distinct reasons', async () => {
  const expired = clientFor([
    { status: 200, body: GRANT },
    { status: 400, body: { error: 'expired_token' } },
  ]);
  await assert.rejects(
    () => expired.client.connect(),
    (error) => error.reason === DeviceAuthFailure.expired,
  );

  const invalid = clientFor([
    { status: 200, body: GRANT },
    { status: 400, body: { error: 'invalid_grant' } },
  ]);
  await assert.rejects(
    () => invalid.client.connect(),
    (error) => error.reason === DeviceAuthFailure.invalidGrant,
  );
});

await check(5, 'a 401 on sync clears the stored token and reports it', async () => {
  const store = memoryStore(TOKEN);
  const { client } = clientFor([{ status: 401, body: { error: 'sign_in_required' } }], store);
  await assert.rejects(
    () => client.sync.list(),
    (error) => error instanceof DeviceAuthError && error.reason === DeviceAuthFailure.invalidGrant,
  );
  assert.equal(store.state.clears, 1, 'the dead token was kept');
  assert.equal(store.state.token, null);
});

await check(6, 'disconnect revokes the current token server-side, then clears locally', async () => {
  const store = memoryStore(TOKEN);
  const { client, requests } = clientFor(
    [
      { status: 200, body: { tokens: [{ id: 8, current: false }, { id: 7, current: true }] } },
      { status: 200, body: { revoked: 1 } },
    ],
    store,
  );

  await client.disconnect();

  assert.equal(requests[0].url, `${ORIGIN}/api/tokens`);
  assert.equal(requests[0].headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(requests[1].url, `${ORIGIN}/api/tokens/revoke`);
  assert.deepEqual(requests[1].body, { id: 7 }, 'the wrong token id was revoked');
  assert.equal(store.state.token, null, 'the local copy survived a sign-out');
});

await check(7, 'authenticated sync calls carry the bearer token and return the body', async () => {
  const store = memoryStore(TOKEN);
  const { client, requests } = clientFor(
    [{ status: 200, body: { saved: [{ clientId: 'a1', ok: true }] } }],
    store,
  );

  const saved = await client.sync.save([{ clientId: 'a1', kind: 'note', payload: { n: 1 } }]);
  assert.deepEqual(saved, { saved: [{ clientId: 'a1', ok: true }] });
  assert.equal(requests[0].headers.Authorization, `Bearer ${TOKEN}`);
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].url, `${ORIGIN}/api/sync`);

  // A call with no credential is refused before it reaches the network.
  const empty = clientFor([]);
  await assert.rejects(
    () => empty.client.sync.list(),
    (error) => error.reason === DeviceAuthFailure.invalidGrant,
  );
  assert.equal(empty.requests.length, 0, 'an unauthenticated call was sent anyway');
});

const passed = results.filter((r) => r.ok).length;
const total = results.length;
if (passed === total) {
  console.log(`PASS ${passed}/${total} desktop auth behaviours`);
  process.exit(0);
}
console.error(`FAIL ${passed}/${total} desktop auth behaviours`);
console.error(`failing: ${results.filter((r) => !r.ok).map((r) => r.number).join(', ')}`);
process.exit(1);
