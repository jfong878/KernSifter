/**
 * The D1 schema, and the bootstrap that applies it.
 *
 * Why the DDL lives in the Worker at all: the deployed database is provisioned
 * by the hosting platform, and nothing else can reach it — no SQL client, no
 * `wrangler d1 execute`, no console. The only writer is this Worker, so the
 * tables have to be created from here on the first request that needs them.
 *
 * `src/db-schema.sql` stays as the human-facing copy used by the `d1:schema:*`
 * scripts, and `test/schema.test.mjs` fails if the two drift apart — so this is
 * not a second source of truth in any practical sense.
 *
 * Every statement is guarded by IF NOT EXISTS, which is what makes running this
 * against a database that already holds data safe.
 */

export const SCHEMA_STATEMENTS: readonly string[] = [
  // -------------------------------------------------------------------------
  // Synced items (web and native clients alike; always owner-scoped).
  // -------------------------------------------------------------------------
  `CREATE TABLE IF NOT EXISTS kernsifter_items (
     id           INTEGER PRIMARY KEY AUTOINCREMENT,
     client_id    TEXT    NOT NULL,
     kind         TEXT    NOT NULL,
     owner_sub    TEXT    NOT NULL,
     payload      TEXT    NOT NULL,
     payload_hash TEXT    NOT NULL,
     meta         TEXT    NOT NULL DEFAULT '',
     created_at   INTEGER NOT NULL DEFAULT (unixepoch() * 1000)
   )`,
  // One row per (owner, client item): what makes a retried push an update
  // rather than a duplicate.
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_items_owner_client ON kernsifter_items(owner_sub, client_id)',
  'CREATE INDEX IF NOT EXISTS idx_items_owner      ON kernsifter_items(owner_sub)',
  'CREATE INDEX IF NOT EXISTS idx_items_owner_kind ON kernsifter_items(owner_sub, kind)',

  // -------------------------------------------------------------------------
  // Device authorizations (RFC 8628), started by a native client. Only the
  // SHA-256 of each secret is stored, so a database read is not a credential.
  // -------------------------------------------------------------------------
  `CREATE TABLE IF NOT EXISTS kernsifter_device_codes (
     id                    INTEGER PRIMARY KEY AUTOINCREMENT,
     device_code_hash      TEXT    NOT NULL,
     user_code_hash        TEXT    NOT NULL,
     status                TEXT    NOT NULL DEFAULT 'pending',
     owner_sub             TEXT,
     client_name           TEXT    NOT NULL DEFAULT '',
     created_at            INTEGER NOT NULL,
     expires_at            INTEGER NOT NULL,
     poll_interval_seconds INTEGER NOT NULL DEFAULT 5,
     last_poll_at          INTEGER,
     approved_at           INTEGER,
     denied_at             INTEGER,
     redeemed_at           INTEGER
   )`,
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_device_codes_device_hash ON kernsifter_device_codes(device_code_hash)',
  'CREATE INDEX IF NOT EXISTS idx_device_codes_user_hash ON kernsifter_device_codes(user_code_hash)',
  // Supports the opportunistic sweep of expired codes.
  'CREATE INDEX IF NOT EXISTS idx_device_codes_expires_at ON kernsifter_device_codes(expires_at)',

  // -------------------------------------------------------------------------
  // Per-user API tokens: the bearer credential a native client presents
  // instead of a session cookie. Only the SHA-256 is stored.
  // -------------------------------------------------------------------------
  `CREATE TABLE IF NOT EXISTS kernsifter_tokens (
     id           INTEGER PRIMARY KEY AUTOINCREMENT,
     token_hash   TEXT    NOT NULL,
     owner_sub    TEXT    NOT NULL,
     label        TEXT    NOT NULL DEFAULT '',
     created_at   INTEGER NOT NULL,
     expires_at   INTEGER NOT NULL,
     last_used_at INTEGER,
     revoked_at   INTEGER
   )`,
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_tokens_hash  ON kernsifter_tokens(token_hash)',
  'CREATE INDEX        IF NOT EXISTS idx_tokens_owner ON kernsifter_tokens(owner_sub)',
];

/**
 * Memoised per isolate. D1 has no "has this been initialised" signal cheap
 * enough to check per request, and the statements are all IF NOT EXISTS, so an
 * isolate applies them once and then answers from this promise. Cold starts
 * cost one `batch` round trip.
 */
let ready: Promise<void> | null = null;

/**
 * Create the tables if they are not there yet.
 *
 * A failure is deliberately *not* memoised: if the first request on a cold
 * isolate cannot reach the database, the next one must be able to try again
 * rather than have that isolate report 503 until it is recycled.
 */
export function ensureSchema(db: D1Database): Promise<void> {
  if (!ready) {
    ready = db.batch(SCHEMA_STATEMENTS.map((sql) => db.prepare(sql))).then(
      () => undefined,
      (error: unknown) => {
        ready = null;
        throw error;
      },
    );
  }
  return ready;
}

/** Test seam: forget the memoised result so a bootstrap can be re-exercised. */
export function resetSchemaCache(): void {
  ready = null;
}
