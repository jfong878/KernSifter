import type { FreebuffUser } from '@freebuff/auth';

/** Bindings and configuration the sync core needs. */
export interface SyncEnv {
  SYNC_DB: D1Database;
  FILES: R2Bucket;
  APP_ORIGIN: string;
}

export interface SyncItemInput {
  clientId: string;
  kind: string;
  payload: unknown;
  meta?: string;
}

export interface SyncRow {
  id: number;
  client_id: string;
  kind: string;
  owner_sub: string;
  payload_hash: string;
  meta: string;
  created_at: number;
}

export interface SavedItem {
  clientId: string;
  ok: boolean;
  id?: number;
  error?: string;
}

export const MAX_ITEMS_PER_REQUEST = 100;
export const MAX_PAYLOAD_BYTES = 256 * 1024;
export const MAX_META_BYTES = 4 * 1024;

const KIND_PATTERN = /^[a-zA-Z0-9._-]{1,64}$/;
const CLIENT_ID_PATTERN = /^[a-zA-Z0-9._:-]{1,128}$/;

/** A rejected item/request that should surface as a 4xx, not a 500. */
export class SyncError extends Error {
  readonly status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.name = 'SyncError';
    this.status = status;
  }
}

export function jsonResponse(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'private, no-store',
      ...extraHeaders,
    },
  });
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Owner-scoped R2 key for a stored payload. */
export function payloadKey(ownerSub: string, kind: string, clientId: string): string {
  return `${ownerSub}/${kind}/${clientId}.json`;
}

function serialisePayload(payload: unknown): string {
  if (typeof payload === 'string') return payload;
  return JSON.stringify(payload ?? null);
}

function byteLength(value: string): number {
  return new TextEncoder().encode(value).length;
}

/** Validate and normalise one item, or throw SyncError. */
export function normaliseItem(raw: unknown): SyncItemInput {
  if (typeof raw !== 'object' || raw === null) throw new SyncError('item must be an object');
  const item = raw as Record<string, unknown>;
  const kind = item.kind;
  const clientId = item.clientId;
  if (typeof kind !== 'string' || !KIND_PATTERN.test(kind)) {
    throw new SyncError('item.kind must match /^[a-zA-Z0-9._-]{1,64}$/');
  }
  if (typeof clientId !== 'string' || !CLIENT_ID_PATTERN.test(clientId)) {
    throw new SyncError('item.clientId must match /^[a-zA-Z0-9._:-]{1,128}$/');
  }
  const meta = item.meta === undefined || item.meta === null ? '' : String(item.meta);
  if (byteLength(meta) > MAX_META_BYTES) throw new SyncError('item.meta is too large');
  const serialised = serialisePayload(item.payload);
  if (byteLength(serialised) > MAX_PAYLOAD_BYTES) throw new SyncError('item.payload is too large');
  let payload: unknown;
  try {
    payload = JSON.parse(serialised);
  } catch {
    throw new SyncError('item.payload must be JSON');
  }
  return { clientId, kind, payload, meta };
}

/** Item metadata for the signed-in user, newest last. */
export async function listItems(env: SyncEnv, user: FreebuffUser): Promise<SyncRow[]> {
  const { results } = await env.SYNC_DB.prepare(
    'SELECT id, client_id, kind, owner_sub, payload_hash, meta, created_at FROM kernsifter_items WHERE owner_sub = ? ORDER BY id',
  )
    .bind(user.sub)
    .all<SyncRow>();
  return results ?? [];
}

/**
 * Upsert items for the signed-in user. The owner always comes from the session,
 * never from the request body. Replaying the same clientId updates in place, so
 * a retried push cannot create duplicates.
 */
export async function saveItems(env: SyncEnv, user: FreebuffUser, raws: unknown[]): Promise<SavedItem[]> {
  if (raws.length > MAX_ITEMS_PER_REQUEST) {
    throw new SyncError(`at most ${MAX_ITEMS_PER_REQUEST} items per request`, 413);
  }
  const saved: SavedItem[] = [];
  for (const raw of raws) {
    let item: SyncItemInput;
    try {
      item = normaliseItem(raw);
    } catch (error) {
      const message = error instanceof SyncError ? error.message : 'invalid item';
      const clientId = typeof (raw as Record<string, unknown>)?.clientId === 'string'
        ? String((raw as Record<string, unknown>).clientId)
        : '';
      saved.push({ clientId, ok: false, error: message });
      continue;
    }
    const payloadJson = JSON.stringify(item.payload);
    const payloadHash = await sha256Hex(payloadJson);
    const statement = env.SYNC_DB.prepare(
      `INSERT INTO kernsifter_items (client_id, kind, owner_sub, payload, payload_hash, meta, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(owner_sub, client_id) DO UPDATE SET
         kind = excluded.kind,
         payload = excluded.payload,
         payload_hash = excluded.payload_hash,
         meta = excluded.meta,
         created_at = excluded.created_at`,
    )
      .bind(item.clientId, item.kind, user.sub, payloadJson, payloadHash, item.meta ?? '', Date.now());
    try {
      const result = await statement.run();
      const id = Number(result.meta.last_row_id ?? 0);
      await env.FILES.put(payloadKey(user.sub, item.kind, item.clientId), payloadJson, {
        httpMetadata: { contentType: 'application/json' },
        customMetadata: { owner: user.sub, kind: item.kind, payloadHash },
      });
      saved.push({ clientId: item.clientId, ok: true, id });
    } catch (error) {
      saved.push({ clientId: item.clientId, ok: false, error: String(error) });
    }
  }
  return saved;
}

/** Read one stored payload from R2, owner-scoped. */
export async function readPayload(
  env: SyncEnv,
  user: FreebuffUser,
  kind: string,
  clientId: string,
): Promise<{ payload: unknown; payloadHash: string | null } | null> {
  if (!KIND_PATTERN.test(kind) || !CLIENT_ID_PATTERN.test(clientId)) {
    throw new SyncError('invalid kind or clientId');
  }
  const object = await env.FILES.get(payloadKey(user.sub, kind, clientId));
  if (!object) return null;
  const text = await object.text();
  let payload: unknown;
  try {
    payload = JSON.parse(text);
  } catch {
    payload = text;
  }
  return { payload, payloadHash: object.customMetadata?.payloadHash ?? null };
}
