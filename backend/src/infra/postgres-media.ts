import pg from 'pg';
import type { Pool as PgPool, PoolClient, PoolConfig } from 'pg';

import {
  contentHashHex,
  objectKeyFor,
  type ClaimedMediaResolution,
  type CompleteMissInput,
  type CompleteReadyInput,
  type ContentAddressedStorage,
  type FailMediaResolutionInput,
  type MediaCacheRecord,
  type MediaMime,
  type MediaRepository,
  type MediaRequestStatus,
  type MediaWorkerRepository,
  type StoredMediaObject,
} from '../domain/media.ts';

const { Pool } = pg;
const PUBLIC_REQUEST_MIN_INTERVAL_SECONDS = 30;

export type PgPoolRuntimeOptions = Readonly<{
  max: number;
  connectionTimeoutMillis: number;
  idleTimeoutMillis: number;
  query_timeout: number;
  statement_timeout: number;
  idle_in_transaction_session_timeout: number;
}>;

export function loadPgPoolRuntimeOptions(env: NodeJS.ProcessEnv = process.env): PgPoolRuntimeOptions {
  return {
    max: integerEnv(env, 'QUOTE_PG_POOL_MAX', 8, 1, 40),
    connectionTimeoutMillis: integerEnv(env, 'QUOTE_PG_CONNECT_TIMEOUT_MS', 5_000, 250, 60_000),
    idleTimeoutMillis: integerEnv(env, 'QUOTE_PG_IDLE_TIMEOUT_MS', 30_000, 1_000, 300_000),
    query_timeout: integerEnv(env, 'QUOTE_PG_QUERY_TIMEOUT_MS', 15_000, 500, 300_000),
    statement_timeout: integerEnv(env, 'QUOTE_PG_STATEMENT_TIMEOUT_MS', 15_000, 500, 300_000),
    idle_in_transaction_session_timeout: integerEnv(env, 'QUOTE_PG_IDLE_IN_TRANSACTION_TIMEOUT_MS', 10_000, 500, 300_000),
  };
}

export function createPgPool(connectionString: string, env: NodeJS.ProcessEnv = process.env) {
  const options = loadPgPoolRuntimeOptions(env);
  return new Pool({
    connectionString,
    ...options,
  } satisfies PoolConfig);
}

export class PgMediaRepository implements MediaWorkerRepository {
  private readonly pool: PgPool;

  constructor(pool: PgPool) {
    this.pool = pool;
  }

  async getCached(chainId: number, tokenAddress: string, nowMs: number): Promise<MediaCacheRecord | null> {
    const result = await this.pool.query(
      `
        SELECT
          status,
          source,
          encode(content_hash, 'hex') AS content_hash_hex,
          object_key,
          mime,
          expires_at
        FROM media_resolution_cache
        WHERE chain_id = $1
          AND token_address = $2
          AND (
            status = 'ready'
            OR (
              status IN ('negative', 'rejected')
              AND expires_at > to_timestamp($3::double precision / 1000)
            )
          )
        LIMIT 1
      `,
      [chainId, addressToBuffer(tokenAddress), nowMs],
    );
    const row = result.rows[0] as Record<string, unknown> | undefined;
    if (!row) return null;

    return {
      chainId,
      tokenAddress,
      status: row.status as MediaCacheRecord['status'],
      source: row.source as MediaCacheRecord['source'],
      contentHashHex: typeof row.content_hash_hex === 'string' ? row.content_hash_hex : null,
      objectKey: typeof row.object_key === 'string' ? row.object_key : null,
      mime: row.mime as MediaMime | null,
      expiresAtMs: toEpochMs(row.expires_at),
    };
  }

  async request(chainId: number, tokenAddress: string, nowMs: number): Promise<MediaRequestStatus> {
    const result = await this.pool.query(
      `
        SELECT request_known_token_media(
          $1,
          $2,
          $3,
          to_timestamp($4::double precision / 1000)
        ) AS status
      `,
      [chainId, addressToBuffer(tokenAddress), PUBLIC_REQUEST_MIN_INTERVAL_SECONDS, nowMs],
    );
    const status = result.rows[0]?.status;
    return status === 'queued' || status === 'unknown' || status === 'rate_limited' ? status : 'rate_limited';
  }

  async claimNext(workerId: string, leaseSeconds: number): Promise<ClaimedMediaResolution | null> {
    const result = await this.pool.query(
      `
        SELECT
          chain_id::text,
          token_address,
          previous_status,
          attempt_count,
          lease_generation::text,
          stale_object_key
        FROM claim_media_resolution($1, $2)
        LIMIT 1
      `,
      [workerId, leaseSeconds],
    );
    const row = result.rows[0] as Record<string, unknown> | undefined;
    if (!row) return null;
    return {
      chainId: Number(row.chain_id),
      tokenAddress: bufferToAddress(row.token_address),
      previousStatus: row.previous_status === 'ready' ? 'ready' : 'pending',
      attemptCount: Number(row.attempt_count),
      leaseGeneration: BigInt(String(row.lease_generation)),
      staleObjectKey: typeof row.stale_object_key === 'string' ? row.stale_object_key : null,
    };
  }

  async completeReady(input: CompleteReadyInput): Promise<boolean> {
    const result = await this.pool.query(
      `
        SELECT complete_media_resolution(
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13
        ) AS completed
      `,
      [
        input.workerId,
        input.chainId,
        addressToBuffer(input.tokenAddress),
        input.leaseGeneration.toString(),
        input.source,
        input.providerRef,
        input.providerPayloadHashHex ? Buffer.from(input.providerPayloadHashHex, 'hex') : null,
        Buffer.from(input.contentHashHex, 'hex'),
        input.mime,
        input.byteSize,
        input.width,
        input.height,
        Math.ceil((input.expiresAtMs - Date.now()) / 1_000),
      ],
    );
    return result.rows[0]?.completed === true;
  }

  async completeMiss(input: CompleteMissInput): Promise<boolean> {
    const result = await this.pool.query(
      `
        SELECT complete_media_miss(
          $1, $2, $3, $4, $5, $6, $7, $8
        ) AS completed
      `,
      [
        input.workerId,
        input.chainId,
        addressToBuffer(input.tokenAddress),
        input.leaseGeneration.toString(),
        input.status,
        input.source,
        input.errorCode,
        input.cacheSeconds,
      ],
    );
    return result.rows[0]?.completed === true;
  }

  async fail(input: FailMediaResolutionInput): Promise<boolean> {
    const result = await this.pool.query(
      `
        SELECT fail_media_resolution(
          $1, $2, $3, $4, $5, $6
        ) AS failed
      `,
      [
        input.workerId,
        input.chainId,
        addressToBuffer(input.tokenAddress),
        input.leaseGeneration.toString(),
        input.errorCode,
        input.retrySeconds,
      ],
    );
    return result.rows[0]?.failed === true;
  }
}

export class PgContentAddressedStorage implements ContentAddressedStorage {
  private readonly pool: PgPool;

  constructor(pool: PgPool) {
    this.pool = pool;
  }

  async put(bytes: Uint8Array, mime: MediaMime): Promise<StoredMediaObject> {
    if (mime !== 'image/png' && mime !== 'image/webp') throw new Error('sanitizer_output_must_be_png_or_webp');
    const contentHash = contentHashHex(bytes);
    const objectKey = objectKeyFor(contentHash, mime);
    await this.pool.query(
      `
        INSERT INTO media_objects (content_hash, mime, bytes, byte_length, created_at)
        VALUES ($1, $2, $3, $4, now())
        ON CONFLICT (content_hash) DO NOTHING
      `,
      [Buffer.from(contentHash, 'hex'), mime, Buffer.from(bytes), bytes.byteLength],
    );
    return { objectKey, contentHashHex: contentHash, mime, bytes };
  }

  async get(objectKey: string): Promise<StoredMediaObject | null> {
    const result = await this.pool.query(
      `
        SELECT encode(content_hash, 'hex') AS content_hash_hex, object_key, mime, bytes
        FROM media_objects
        WHERE object_key = $1
        LIMIT 1
      `,
      [objectKey],
    );
    const row = result.rows[0] as Record<string, unknown> | undefined;
    if (!row || !(row.bytes instanceof Buffer) || typeof row.object_key !== 'string' || typeof row.content_hash_hex !== 'string') return null;
    return {
      objectKey: row.object_key,
      contentHashHex: row.content_hash_hex,
      mime: row.mime as MediaMime,
      bytes: new Uint8Array(row.bytes),
    };
  }
}

function addressToBuffer(address: string) {
  return Buffer.from(address.slice(2), 'hex');
}

function bufferToAddress(value: unknown) {
  if (!(value instanceof Uint8Array) || value.byteLength !== 20) throw new Error('invalid_database_address');
  return `0x${Buffer.from(value).toString('hex')}`;
}

function toEpochMs(value: unknown) {
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'string') return new Date(value).getTime();
  return 0;
}

function integerEnv(env: NodeJS.ProcessEnv, name: string, fallback: number, minimum: number, maximum: number) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${name}_invalid`);
  return value;
}

export async function withPgClient<T>(pool: PgPool, run: (client: PoolClient) => Promise<T>) {
  const client = await pool.connect();
  try {
    return await run(client);
  } finally {
    client.release();
  }
}
