-- KernSifter sync schema (D1).
-- Apply locally:  npx wrangler d1 execute kernsifter-sync-db --local  --file=src/db-schema.sql
-- Apply remotely: npx wrangler d1 execute kernsifter-sync-db --remote --file=src/db-schema.sql
--
-- Every statement is IF NOT EXISTS, so re-applying this file against a database
-- that already holds data is safe. Adding the device/token tables does not touch
-- kernsifter_items.

-- ---------------------------------------------------------------------------
-- Synced items (web client and native clients alike; always owner-scoped).
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS kernsifter_items (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id    TEXT    NOT NULL,
  kind         TEXT    NOT NULL,
  owner_sub    TEXT    NOT NULL,
  payload      TEXT    NOT NULL,
  payload_hash TEXT    NOT NULL,
  meta         TEXT    NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL DEFAULT (unixepoch() * 1000)
);

-- One row per (owner, client item). This is what makes a retried push an
-- update instead of a duplicate.
CREATE UNIQUE INDEX IF NOT EXISTS idx_items_owner_client ON kernsifter_items(owner_sub, client_id);

CREATE INDEX IF NOT EXISTS idx_items_owner      ON kernsifter_items(owner_sub);
CREATE INDEX IF NOT EXISTS idx_items_owner_kind ON kernsifter_items(owner_sub, kind);

-- ---------------------------------------------------------------------------
-- Device authorizations (RFC 8628), started by a native client.
--
-- The native app holds the plaintext `device_code`; this table holds only its
-- SHA-256, so a database read cannot be turned into a credential. `user_code`
-- is what the human types on the consent page, and it is likewise hashed.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS kernsifter_device_codes (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  device_code_hash      TEXT    NOT NULL,
  user_code_hash        TEXT    NOT NULL,
  -- pending -> approved -> redeemed, or pending -> denied
  status                TEXT    NOT NULL DEFAULT 'pending',
  -- Set at approval time from the signed-in session `sub`, never from the client.
  owner_sub             TEXT,
  client_name           TEXT    NOT NULL DEFAULT '',
  created_at            INTEGER NOT NULL,
  expires_at            INTEGER NOT NULL,
  -- Enforced polling interval; widened on slow_down (RFC 8628 §3.5).
  poll_interval_seconds INTEGER NOT NULL DEFAULT 5,
  last_poll_at          INTEGER,
  approved_at           INTEGER,
  denied_at             INTEGER,
  redeemed_at           INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_device_codes_device_hash ON kernsifter_device_codes(device_code_hash);
CREATE INDEX IF NOT EXISTS idx_device_codes_user_hash ON kernsifter_device_codes(user_code_hash);
-- Supports the opportunistic sweep of expired codes.
CREATE INDEX IF NOT EXISTS idx_device_codes_expires_at ON kernsifter_device_codes(expires_at);

-- ---------------------------------------------------------------------------
-- Per-user API tokens: the bearer credential a native client presents instead
-- of a session cookie. Only the SHA-256 of the token is stored.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS kernsifter_tokens (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  token_hash   TEXT    NOT NULL,
  owner_sub    TEXT    NOT NULL,
  label        TEXT    NOT NULL DEFAULT '',
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at   INTEGER
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tokens_hash  ON kernsifter_tokens(token_hash);
CREATE INDEX        IF NOT EXISTS idx_tokens_owner ON kernsifter_tokens(owner_sub);
