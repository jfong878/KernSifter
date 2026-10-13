-- KernSifter sync schema (D1).
-- Apply locally:  npx wrangler d1 execute kernsifter-sync-db --local  --file=src/db-schema.sql
-- Apply remotely: npx wrangler d1 execute kernsifter-sync-db --remote --file=src/db-schema.sql

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
