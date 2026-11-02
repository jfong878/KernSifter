// Native-client authentication for the KernSifter desktop shell.
//
// Implements RFC 8628 device authorization against the `kernsifter-sync` Worker
// and then holds a KernSifter-issued per-user bearer token. Freebuff issues
// identity; the Worker issues the machine credential. Protocol and rationale:
// `kernsifter-sync/docs/DEVICE-AUTH.md`.
//
// The flow runs in the webview (so no Rust HTTP client and no new Cargo
// dependency is needed), which is why `fetch` here is a cross-origin call and
// why the Worker keeps an explicit CORS allowlist for the shell's origin.
// Persistence is delegated to an injected store — in the app that is the Rust
// keystore commands, in tests it is a Map — so this module has no dependency on
// Tauri and can be exercised with plain `node`.

/** Why a device authorization failed. Mirrors the Dart client's reasons. */
export const DeviceAuthFailure = Object.freeze({
  accessDenied: 'access_denied',
  expired: 'expired_token',
  invalidGrant: 'invalid_grant',
  network: 'network',
  malformed: 'malformed',
});

/** Thrown for every non-retryable outcome, so callers never parse strings. */
export class DeviceAuthError extends Error {
  constructor(reason, message) {
    super(message);
    this.name = 'DeviceAuthError';
    this.reason = reason;
  }
}

const REASONS_BY_ERROR_CODE = {
  access_denied: DeviceAuthFailure.accessDenied,
  expired_token: DeviceAuthFailure.expired,
  invalid_grant: DeviceAuthFailure.invalidGrant,
};

const MESSAGES_BY_ERROR_CODE = {
  access_denied: 'the request was denied in the browser',
  expired_token: 'the code expired before it was approved',
  invalid_grant: 'the device code is unknown or has already been used',
};

/**
 * @param {object} options
 * @param {string} options.origin            Canonical Worker origin, no trailing slash.
 * @param {string} [options.clientName]      Shown to the human on the consent page.
 * @param {object} options.store             { read(), write(token), clear() }
 * @param {Function} [options.fetchImpl]     Injected for tests.
 * @param {Function} [options.sleep]         Injected for tests.
 */
export function createDeviceAuthClient({
  origin,
  clientName = 'KernSifter desktop',
  store,
  fetchImpl = (...args) => globalThis.fetch(...args),
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
  if (!origin) throw new Error('origin is required');
  if (!store) throw new Error('store is required');
  const base = String(origin).replace(/\/+$/, '');

  async function send(method, path, { body, token, signal } = {}) {
    const headers = { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    // The server never accepts a cookie for these calls; the header is the
    // whole credential. It is also why a cross-site page cannot forge this.
    if (token) headers.Authorization = `Bearer ${token}`;

    let response;
    try {
      response = await fetchImpl(`${base}${path}`, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal,
      });
    } catch (error) {
      if (error?.name === 'AbortError') throw new DeviceAuthError(DeviceAuthFailure.invalidGrant, 'cancelled');
      throw new DeviceAuthError(DeviceAuthFailure.network, `could not reach ${base}: ${error?.message ?? error}`);
    }

    const text = await response.text();
    let parsed = {};
    if (text) {
      try {
        parsed = JSON.parse(text);
      } catch {
        throw new DeviceAuthError(DeviceAuthFailure.malformed, `invalid JSON from ${path}`);
      }
    }
    if (typeof parsed !== 'object' || parsed === null) {
      throw new DeviceAuthError(DeviceAuthFailure.malformed, `expected a JSON object from ${path}`);
    }
    return { status: response.status, body: parsed };
  }

  /** Step 1: start an authorization. */
  async function startDeviceLogin() {
    const { status, body } = await send('POST', '/api/device/authorize', { body: { client_name: clientName } });
    if (status !== 200) {
      throw new DeviceAuthError(DeviceAuthFailure.malformed, `authorize returned ${status}`);
    }
    for (const field of ['device_code', 'user_code', 'verification_uri', 'verification_uri_complete']) {
      if (typeof body[field] !== 'string' || body[field] === '') {
        throw new DeviceAuthError(DeviceAuthFailure.malformed, `authorize response was missing ${field}`);
      }
    }
    return {
      deviceCode: body.device_code,
      userCode: body.user_code,
      verificationUri: body.verification_uri,
      verificationUriComplete: body.verification_uri_complete,
      expiresIn: Number(body.expires_in ?? 600),
      interval: Number(body.interval ?? 5),
    };
  }

  /**
   * Step 2: poll until approved. Honours `slow_down` by widening the interval,
   * and gives up at the authorization's own deadline rather than polling
   * forever.
   */
  async function pollForToken(authorization, { signal, onTick } = {}) {
    let intervalMs = authorization.interval * 1000;
    const deadline = Date.now() + authorization.expiresIn * 1000;

    for (;;) {
      if (signal?.aborted) throw new DeviceAuthError(DeviceAuthFailure.invalidGrant, 'cancelled');
      const { status, body } = await send('POST', '/api/device/token', {
        body: { device_code: authorization.deviceCode },
        signal,
      });

      if (status === 200) {
        if (typeof body.access_token !== 'string' || body.access_token === '') {
          throw new DeviceAuthError(DeviceAuthFailure.malformed, 'token response carried no access_token');
        }
        return body.access_token;
      }

      if (body.error === 'authorization_pending') {
        // keep waiting
      } else if (body.error === 'slow_down') {
        // RFC 8628 §3.5: back off five seconds and keep waiting.
        intervalMs += 5000;
      } else if (REASONS_BY_ERROR_CODE[body.error]) {
        throw new DeviceAuthError(REASONS_BY_ERROR_CODE[body.error], MESSAGES_BY_ERROR_CODE[body.error]);
      } else {
        throw new DeviceAuthError(DeviceAuthFailure.malformed, `unexpected token response: ${body.error ?? status}`);
      }

      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) {
        throw new DeviceAuthError(DeviceAuthFailure.expired, MESSAGES_BY_ERROR_CODE.expired_token);
      }
      onTick?.({ remainingMs, intervalMs });
      await sleep(intervalMs);
    }
  }

  /**
   * The whole flow. `onCode` receives the authorization so the UI can show the
   * user code and open the browser; the token is stored on success.
   */
  async function connect({ onCode, signal } = {}) {
    const authorization = await startDeviceLogin();
    onCode?.(authorization);
    const token = await pollForToken(authorization, { signal });
    await store.write(token);
    return token;
  }

  async function getToken() {
    return store.read();
  }

  /** `true` only if the server accepts the stored token. Clears it on a 401. */
  async function isConnected() {
    const token = await store.read();
    if (!token) return false;
    const { status } = await send('GET', '/api/sync', { token });
    if (status === 401) {
      await store.clear();
      return false;
    }
    return status === 200;
  }

  /** Sign out. Revokes on the server too — clearing it locally is not enough. */
  async function disconnect({ revoke = true } = {}) {
    const token = await store.read();
    await store.clear();
    if (!revoke || !token) return;
    const listed = await send('GET', '/api/tokens', { token });
    if (listed.status !== 200 || !Array.isArray(listed.body.tokens)) return;
    const current = listed.body.tokens.find((entry) => entry?.current === true);
    if (!current || typeof current.id !== 'number') return;
    await send('POST', '/api/tokens/revoke', { body: { id: current.id }, token });
  }

  /** An authenticated sync call. The server scopes data to the token's owner. */
  async function syncRequest(method, path, body) {
    const token = await store.read();
    if (!token) throw new DeviceAuthError(DeviceAuthFailure.invalidGrant, 'no token: connect first');
    const { status, body: parsed } = await send(method, path, { body, token });
    if (status === 401) {
      await store.clear();
      throw new DeviceAuthError(DeviceAuthFailure.invalidGrant, 'the access token was rejected (401)');
    }
    return parsed;
  }

  return {
    startDeviceLogin,
    pollForToken,
    connect,
    getToken,
    isConnected,
    disconnect,
    // `_send` is exported for the tests, which assert the wire contract.
    _send: send,
    sync: {
      list: () => syncRequest('GET', '/api/sync'),
      save: (items) => syncRequest('POST', '/api/sync', { items }),
      read: (kind, clientId) =>
        syncRequest('GET', `/api/sync/${encodeURIComponent(kind)}/${encodeURIComponent(clientId)}`),
    },
  };
}
