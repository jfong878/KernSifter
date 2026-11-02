# Native client authentication — device flow + per-user tokens

How the Tauri desktop app and the Flutter mobile app authenticate to the sync
Worker, and why it looks like this.

## Why the native apps cannot reuse the Freebuff session

The web client is authorised by the `__Host-freebuff_session` cookie. A native
client has no browser and cannot obtain one of those sessions:

- `@freebuff/auth` is OIDC + PKCE for a browser, with no device grant, and
- it explicitly **refuses token requests from browsers**, so a native app
  cannot hold a Freebuff token either.

So the native apps never touch Freebuff credentials. They start a device
authorization with **our** Worker, a human approves it in a browser using the
Freebuff session they already have, and what comes back is a **KernSifter**
bearer token scoped to that person's `sub`. Freebuff issues identity; this
Worker issues the machine credential.

## Endpoints

### `POST /api/device/authorize` — unauthenticated

Started by the native client. Body:

```json
{ "client_name": "KernSifter desktop" }
```

`client_name` is shown to the human on the consent page, so keep it short and
recognisable. Response `200`:

```json
{
  "device_code": "ksd_<64 hex>",
  "user_code": "BCDF-GHJK",
  "verification_uri": "https://<origin>/device",
  "verification_uri_complete": "https://<origin>/device?code=BCDF-GHJK",
  "expires_in": 600,
  "interval": 5
}
```

`device_code` is a secret: it is the only thing that redeems the approval, and
it is stored server-side only as a SHA-256. `user_code` is what the human
reads and types.

### `POST /api/device/token` — unauthenticated, polled

Body `{ "device_code": "ksd_..." }`. Poll no faster than `interval` seconds.

`200` once approved:

```json
{ "access_token": "ks_<64 hex>", "token_type": "Bearer", "expires_in": 2592000 }
```

Otherwise `400` with an RFC 8628 error, and the client must react:

| `error` | meaning | what the client does |
| --- | --- | --- |
| `authorization_pending` | the human has not approved yet | keep polling |
| `slow_down` | polled too fast | add 5s to the interval and keep polling |
| `access_denied` | the human pressed Deny | stop; nothing was shared |
| `expired_token` | the code timed out (10 min) | stop; offer to start again |
| `invalid_grant` | unknown, or already redeemed | stop; start a new authorization |

The whole grant is single-use: one approval mints exactly one token. The
authorization's polling interval only ever widens, per RFC 8628 §3.5.

### `GET /device?code=BCDF-GHJK` — the consent page

Server-rendered, no JavaScript, locked down with
`Content-Security-Policy: default-src 'none'`. If the visitor is signed out it
offers sign-in and returns to the same page with the code filled in. It names
the requesting client so the human can tell what they are approving.

### `POST /api/device/lookup`, `POST /api/device/approve`, `POST /api/device/deny`

The browser half. Require a **session** (`403 session_required` for a bearer
token — a machine credential must not mint another one) and require a
**same-origin** post (`403 forbidden` otherwise). A form post re-renders HTML;
a JSON post gets JSON.

### `GET /api/tokens`, `POST /api/tokens/revoke`

Authenticated by either credential. `GET` returns the caller's own live
tokens and marks the one making the request:

```json
{ "tokens": [ { "id": 3, "label": "KernSifter desktop", "createdAt": 0, "expiresAt": 0, "lastUsedAt": null, "current": true } ] }
```

`POST` with `{"id": 3}` revokes one; `{"all": true}` revokes every other token
and spares the caller's own.

### Existing sync routes

`GET /api/sync`, `POST /api/sync` and `GET /api/sync/<kind>/<clientId>` now
accept `Authorization: Bearer <token>` as well as the session cookie. The owner
is always the credential's `sub`; nothing in a request body can change it.

## Client algorithm

1. `POST /api/device/authorize` with `client_name`.
2. Show `user_code` prominently and open `verification_uri_complete` in the
   system browser.
3. Poll `POST /api/device/token` every `interval` seconds until the token,
   honouring `slow_down`, and giving up at `expires_in`.
4. Store `access_token` in the platform keystore, not in a settings file.
5. Send `Authorization: Bearer <access_token>` on every sync call.
6. On any `401`, discard the token and re-run from step 1.
7. Sign-out means `POST /api/tokens/revoke` with the current `id`, then delete
   the local copy. Removing it locally alone leaves a live credential behind.

## Security properties, and the deliberate tradeoff

- **Secrets are hashed at rest.** Device codes and tokens are stored only as
  SHA-256, so a database read cannot be turned into a credential.
- **Same-origin enforcement is tied to the credential, not the method.** This is
  the one change to the security model. A cookie is *ambient* authority — the
  browser attaches it to a request the page did not intend — so a
  cookie-authenticated state change still must be same-origin, exactly as
  before. An `Authorization: Bearer` header is not ambient: no browser adds it
  by itself, a cross-site page cannot set it without a preflight this Worker
  never approves, and the Worker sends no permissive CORS headers. So a
  token-authenticated request needs no origin check, and a native client — which
  has no origin — is authenticated without weakening the web client.
- **No fallback between credentials.** A request carrying an unusable
  `Authorization` header is a `401`, never silently treated as a session. That
  closes the one confused-deputy path between the two models.
- **Revocation is real.** Tokens expire (30 days) and can be revoked
  individually or all at once; both are owner-scoped, so an id from another
  account is a no-op.
- **Known limitation.** A token outlives the Freebuff session that created it.
  If an account is banned or the person signs out of Freebuff, their
  KernSifter tokens keep working until they expire or are revoked. Bounding this
  properly needs a refresh flow, which this deliberately does not have yet.

## Testing

`node test/auth.test.mjs` runs the real schema in `node:sqlite` and exercises
all of the above through the real router: 25 behaviours, including that a
cross-origin approval is refused, that a device code is single-use, that a
token cannot read another owner's data, that an unusable `Authorization`
header never becomes a session, and that a hostile `client_name` cannot escape
the consent page.

## Client integration

Both shells implement the same algorithm above; only the keystore differs.

### Flutter (mobile-ui)

- `lib/auth.dart` — the whole flow, importing nothing but the Dart SDK. The
  `HttpClient` and the `TokenStore` are injected, so the state machine is
  exercised without a network or a device.
- `lib/token_store.dart` — `SecureTokenStore`, backed by
  `flutter_secure_storage` (Android Keystore / iOS Keychain). Deliberately not
  `shared_preferences`, which is plain XML on disk.
- `lib/main.dart` — a cloud button in the app bar starts the flow and renders the
  user code inline; cancelling stops the poll loop before a token is minted.

Point it at your Worker at build time:

```sh
flutter run --dart-define=KERNSIFTER_SYNC_ORIGIN=https://kernsifter-sync.<sub>.workers.dev
```

Left unset, the app reports that sync is unconfigured instead of failing in a
way that looks like a bug.

### Tauri (desktop-ui)

- `src/sync-auth.js` — the same flow for the webview, with `fetch`, `sleep` and
  the token store injected.
- `src-tauri/src/auth.rs` — `store_token`, `load_token`, `clear_token`, backed by
  the OS credential store through the `keyring` crate.
- `src/index.html` — a "Connect to sync" button and the code panel; set
  `SYNC_ORIGIN` in that file to the Worker origin.

The webview is a browser, so its calls are cross-origin — that is what
`ALLOWED_WEBVIEW_ORIGINS` (default `http://tauri.localhost`) is for, and why it
is an allowlist rather than `*`.

### What has been verified

| Check | Result |
| --- | --- |
| `node test/auth.test.mjs` (Worker) | `PASS 28/28` |
| `node test/routes.test.mjs` (Worker, unchanged) | `PASS 9/9` |
| `cd desktop-ui && node test/sync-auth.test.mjs` | `PASS 7/7` |
| `dart analyze lib` (mobile) | no issues |
| `npx tsc --noEmit` (Worker) | exit 0 |

**Not verified: the Rust commands have never been compiled.** `cargo check`
fails in this environment before it reaches them — the linker named by
`KernSifter/.cargo/config.toml` (`WinLibs` MinGW `gcc.exe`) is absent, and there
is no `gcc` or `dlltool` on PATH, so the Tauri crate cannot build here at all.
The `keyring` dependency itself resolved and downloaded (v3.6.3), so the manifest
is sound; `auth.rs` still needs a `cargo check` on a machine with that toolchain
restored. Nothing in this change caused that breakage.
