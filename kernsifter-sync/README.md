# kernsifter-sync — self-managed Cloudflare Worker

Sync/storage/auth for KernSifter on **your own Cloudflare account**: a Worker with
D1 (structured state), R2 (payload blobs) and **Sign in with Freebuff** (OIDC, no secrets).
Cloudflare keeps the API surface; Freebuff only issues identity.

## What is already verified locally

Run in workerd via `wrangler dev` on 2026-10-13:

| Check | Result |
| --- | --- |
| `tsc --noEmit` | exit 0 |
| `node test/routes.test.mjs` | `PASS 9/9 route behaviours` |
| `wrangler d1 execute --local --file=src/db-schema.sql` | exit 0 |
| Upsert replayed twice against real local SQLite | 1 row, updated in place |
| `GET /` | 200 `text/html` (assets served) |
| `GET /some/spa/route` | 200 SPA fallback |
| `GET /auth/freebuff/session` | 200 `{"user":null}` — auth routes reach the SDK, not the asset handler |
| `GET`/`POST`/`PUT /api/sync` while signed out | 401 `{"error":"sign_in_required"}` |

The route test additionally pins down, with a stubbed session:
a foreign-`Origin` POST gets **403** with no writes; the session `sub` is what gets
bound to the row; a body carrying someone else's `owner_sub`/`sub` never reaches
storage; R2 receives `<sub>/<kind>/<clientId>.json`; replayed `clientId` upserts;
listing is owner-scoped and `Cache-Control: private, no-store`; bad input is a 4xx
per item, never a 500; unknown payload → 404; `PUT` → 405 with `Allow`.

## Live URL (route surface only) — 2026-10-13

Deployed with `wrangler deploy -c wrangler.preview.toml --temporary`:

**https://kernsifter-sync-preview.immediate-snail.workers.dev**

Probed over the public internet, not localhost:

| Request | Result |
| --- | --- |
| `GET /` | 200 `text/html` — page renders ("Kernsifter Sync" + "Sync now") |
| `GET /spa/route` | 200 SPA fallback |
| `GET /auth/freebuff/session` | 200 `{"user":null}` |
| `GET` / `POST /api/sync` | 401 `{"error":"sign_in_required"}` |
| Clicking "Sync now" in the browser | `GET /api/sync` → 401, no other console or asset errors |

**Read the limits honestly.** This is a temporary wrangler preview account, so it
carries **no D1 and no R2** (`wrangler.preview.toml` has neither binding) and it
expires — a temporary deployment can be claimed within 60 minutes. It proves the
deploy pipeline, the asset path, the auth mounting and the 401 gate; it does not
prove storage. A temporary account cannot hold D1 or R2 at all, and
`wrangler d1 create` / `wrangler r2 bucket create` both require a real API token.

## What is NOT verified — and why

- **No production URL with storage.** The real `kernsifter-sync` (D1 + R2) is not
  deployed, because both resources must be created in your account and every
  command that does so needs your credentials.
- **No completed sign-in.** The deployed and local runs use a placeholder client
  ID, so `/auth/freebuff/signin` cannot complete. A redirect is not a login.

## Finish it: 5 commands

```sh
cd kernsifter-sync
export CLOUDFLARE_API_TOKEN=...        # PowerShell: $env:CLOUDFLARE_API_TOKEN="..."
export CLOUDFLARE_ACCOUNT_ID=...

# 1. Freebuff client IDs (public values). Needs YOUR Freebuff login. --project stays
#    the same across environments so user IDs are stable; use a new slug per project.
npx @freebuff/auth register --project kernsifter --name "KernSifter" \
  --environment development --redirect-uri http://localhost:8787/auth/freebuff/callback
npx @freebuff/auth register --project kernsifter --name "KernSifter" \
  --environment production  --redirect-uri https://<your-worker-host>/auth/freebuff/callback

# 2. Real D1 + R2. R2 needs its subscription activated once in the dashboard.
npx wrangler d1 create kernsifter-sync-db --binding SYNC_DB --update-config
npx wrangler r2 bucket create kernsifter-sync-files

# 3. Put the printed database_id into wrangler.toml, set APP_ORIGIN and
#    FREEBUFF_CLIENT_ID from step 1, then create the table:
npx wrangler d1 execute kernsifter-sync-db --remote --file=src/db-schema.sql

# 4. Deploy.
npx wrangler deploy
```

Token scopes: **Workers Scripts: Edit** (Admin to create the Worker the first time),
plus **D1: Edit** and **Workers R2 Storage: Edit** if the token also creates the
resources. Deploying a Worker that merely *binds* D1/R2 does not need the D1/R2 scopes.

Then open the deployed origin, sign in, and repeat the full
sign-in → callback → session → sign-out flow. `APP_ORIGIN` must be the deployed
origin exactly, and `FREEBUFF_CLIENT_ID` must be the *production* client.

## Cost

Workers **Free** already includes D1 and R2 bindings in production: 100k requests/day,
D1 5M rows read + 100k rows written/day and 5 GB stored, R2 10 GB-month storage with
free egress. Workers Paid ($5/mo) is only needed to exceed those, and R2 needs its
subscription activated (free tier included). There is no "$100 Sites credit" to rely
on — that never traced to a Freebuff or Cloudflare page.

## API

- `GET /api/sync` → `{ items: [{ id, client_id, kind, owner_sub, payload_hash, meta, created_at }] }` for the session user.
- `POST /api/sync` `{ items: [{ clientId, kind, payload, meta? }] }` → `{ saved: [{ clientId, ok, id?, error? }] }`. Owner is always the session `sub`; `clientId` makes retries idempotent. Limits: 100 items, 256 KiB payload, 4 KiB meta.
- `GET /api/sync/<kind>/<clientId>` → `{ payload, payloadHash }` from R2, or 404.

**Known gap:** the desktop/mobile apps are not same-origin browsers, so the
cookie-session model plus `isSameOriginRequest` covers the web client only. Native
clients need a device-authorization flow or a per-user token stored in D1 — deliberately
not weakened here, since same-origin enforcement is a security control.
