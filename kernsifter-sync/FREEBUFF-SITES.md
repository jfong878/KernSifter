# Freebuff Sites project (created 2026-10-13 during diagnosis)

    siteId: 6f0a1e2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b
    name:   KernSifter Sync

Nothing is deployed: both environments report `deployed_at: null`, and both URLs
answer HTTP 404 (verified by request).

| Environment | id | worker_name | URL |
| --- | --- | --- | --- |
| preview | 81d8ac1a-f73a-41a3-ad7b-13bc418ded93 | site-81d8ac1af73a41a3ad7b13bc418ded93 | https://site-81d8ac1af73a41a3ad7b13bc418ded93.freebuff.page |
| production | 6fc61d60-e508-497c-8a03-d0883671e9b1 | site-6fc61d60e508497c8a03d088367e9b1 | https://site-6fc61d60e508497c8a03d088367e9b1.freebuff.page |

Both run in Freebuff's own Cloudflare account `6e5a40dd9362fb315de7ecbaad2ca12b`,
namespace `freebuff-sites-prod`, on the `freebuff.page` domain.

## Allowances reported by the API (state: active, all unused)

| Allowance | Limit |
| --- | --- |
| Site requests | 100,000/month (10,000/day) |
| CPU time | 5,000,000 ms/month (500,000/day) |
| D1 storage | 100,000,000 bytes (100 MB) |
| D1 rows read | 50,000,000/month |
| D1 rows written | 100,000/month (10,000/day) |
| R2 storage | 1,000,000,000 bytes (1 GB) |
| R2 write/list ops | 25,000/month (2,500/day) |
| R2 read ops | 250,000/month |
| R2 Infrequent Access | not available (Standard only) |

There is no "$100 credit": the capacity is a metered free allowance. For comparison,
Cloudflare's own free tier is larger (5 GB D1, 10 GB R2, 100k requests/day).

## Why the earlier creation attempts failed

Not accounts, not credits, not eligibility. The `sites_create` argument parser is:

    object({ siteId: uuid3, name: string().min(1).max(80) }).strict()
    uuid3 = exports_external.string().uuid()
    invalid = (message) => new SitesClientError(400, "invalid_site_request", message)

`.strict()` rejects unknown keys, and any parse failure is reported as HTTP 400
`invalid_site_request`. With a well-formed UUIDv4 `siteId` and a 1–80 character
`name`, the call succeeds on the first attempt.

## Why this matters for the hosting decision

- Hosting runs in **Freebuff's** Cloudflare account, so this route needs **no
  Cloudflare token or account id** from the user — unlike the self-managed route,
  which is blocked on exactly that.
- D1 and R2 are provisioned per environment by Freebuff, and identity comes from
  Sign in with Freebuff.
- The KernSifter sync Worker built here targets the same runtime (a prebuilt Worker
  plus static assets), so it is deployable on this path without a rewrite.
