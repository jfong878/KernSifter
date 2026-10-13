# wrangler 4.149.0 install plan (durable note)

## What we know
- The current `kernsifter-sync/node_modules/wrangler` tree cannot start:
  - `wrangler --version` fails with `Cannot find module 'miniflare'`.
  - `require('wrangler')` also fails with `Cannot find module 'miniflare'`.
- The tarball `scripts/node/wrangler-4.149.0.tgz` was downloaded from
  `https://registry.npmjs.org/wrangler/-/wrangler-4.149.0.tgz` and verifies as
  `wrangler` `4.149.0` with the real dist payload (`wrangler-dist/cli.js` etc.).

## Known limitation of the tarball-only approach
- The npm tarball for wrangler 4.149.0 does NOT include wrangler's own
  `wrangler-dist/package.json`, and it does NOT include wrangler's runtime deps
  (miniflare, blake3-wasm, esbuild, path-to-regexp, unenv, workerd,
  @cloudflare/unenv-preset, @cloudflare/kv-asset-handler, @cloudflare/workers-utils,
  @cloudflare/types, yargs, semiver, undici, etc.).
- So a bare tarball unpack into node_modules is NOT sufficient. We still need a
  real dependency resolution for those deps.

## Planned fix
1. Prefer a bounded `npm install wrangler@4.149.0` inside
   `kernsifter-sync`, with a hard timeout and a captured log.
2. If that fails/timeouts again, fall back to unpacking the durable tarball into
   `kernsifter-sync/node_modules/wrangler`, then installing ONLY the missing
   runtime deps explicitly one at a time (bounded each), so we never depend on a
   single giant npm resolution pass that keeps timing out.
3. After install, re-verify:
   - `bash node_modules/.bin/wrangler --version` succeeds
   - `npx wrangler --version` succeeds
   - runtime deps like `miniflare`, `blake3-wasm`, `workerd`, `esbuild`,
     `undici`, `@cloudflare/kv-asset-handler` resolve from inside the project.

## Why not chase a cleaner root-cause theory forever
- This machine has repeatedly produced partial node_modules trees and npm
  timeouts. The pragmatic goal is a working wrangler 4.149.0 install we can run
  and redeploy, not a perfect theoretical install.
