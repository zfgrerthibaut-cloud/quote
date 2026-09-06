import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { processNextMediaResolution } from './domain/media.ts';
import { createPgPool, PgContentAddressedStorage, PgMediaRepository } from './infra/postgres-media.ts';
import { sanitizeImageWithSharp } from './infra/sharp-sanitizer.ts';
import { getCodexCredentialsFromEnv, getGmgnCredentialsFromEnv } from './server.ts';

const DEFAULT_CONCURRENCY = 2;
const MAX_CONCURRENCY = 4;

export async function runMediaWorker(env: NodeJS.ProcessEnv = process.env, signal?: AbortSignal) {
  const databaseUrl = required(env, 'DATABASE_URL');
  const pool = createPgPool(databaseUrl);
  const repository = new PgMediaRepository(pool);
  const storage = new PgContentAddressedStorage(pool);
  const workerId = (env.MEDIA_WORKER_ID?.trim() || `media-${process.pid}-${randomUUID()}`).slice(0, 96);
  const concurrency = envInteger(env.MEDIA_WORKER_CONCURRENCY, DEFAULT_CONCURRENCY, 1, MAX_CONCURRENCY);
  const leaseSeconds = envInteger(env.MEDIA_WORKER_LEASE_SECONDS, 120, 30, 300);
  const idleMs = envInteger(env.MEDIA_WORKER_IDLE_MS, 1_000, 100, 60_000);
  const errorMs = envInteger(env.MEDIA_WORKER_ERROR_MS, 5_000, 500, 60_000);

  const dependencies = {
    repository,
    storage,
    fetch,
    sanitizeImage: sanitizeImageWithSharp,
    gmgn: getGmgnCredentialsFromEnv(),
    codex: getCodexCredentialsFromEnv(),
  };

  console.log(JSON.stringify({ level: 'info', event: 'media_worker_started', workerId, concurrency, leaseSeconds }));
  try {
    await Promise.all(Array.from({ length: concurrency }, (_, index) => (
      runWorkerLane(`${workerId}:${index}`, dependencies, leaseSeconds, idleMs, errorMs, signal)
    )));
  } finally {
    await pool.end().catch(() => undefined);
  }
}

async function runWorkerLane(
  workerId: string,
  dependencies: Parameters<typeof processNextMediaResolution>[0],
  leaseSeconds: number,
  idleMs: number,
  errorMs: number,
  signal: AbortSignal | undefined,
) {
  while (!signal?.aborted) {
    try {
      const result = await processNextMediaResolution(dependencies, workerId, leaseSeconds);
      if (result === 'idle') {
        await sleep(idleMs, signal);
      } else if (result === 'lost_lease') {
        console.warn(JSON.stringify({ level: 'warn', event: 'media_worker_lost_lease', workerId }));
      }
    } catch (error) {
      console.error(JSON.stringify({
        level: 'error',
        event: 'media_worker_error',
        workerId,
        message: error instanceof Error ? error.message : String(error),
      }));
      await sleep(errorMs, signal);
    }
  }
}

function envInteger(raw: string | undefined, fallback: number, minimum: number, maximum: number) {
  const parsed = Number(raw);
  if (!Number.isInteger(parsed)) return fallback;
  return Math.max(minimum, Math.min(parsed, maximum));
}

function required(env: NodeJS.ProcessEnv, name: string) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name}_required`);
  return value;
}

function sleep(milliseconds: number, signal?: AbortSignal) {
  if (signal?.aborted) return Promise.resolve();
  return new Promise<void>((resolve) => {
    const timeout = setTimeout(resolve, milliseconds);
    signal?.addEventListener('abort', () => {
      clearTimeout(timeout);
      resolve();
    }, { once: true });
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const controller = new AbortController();
  process.once('SIGINT', () => controller.abort());
  process.once('SIGTERM', () => controller.abort());
  await runMediaWorker(process.env, controller.signal);
}
