import { fileURLToPath } from 'node:url';

import { createPgPool } from './infra/postgres-media.ts';
import { HttpJsonRpcClient } from './indexer/http-rpc.ts';
import { QuoteIndexer } from './indexer/indexer.ts';
import { PostgresIndexerStore } from './indexer/postgres-store.ts';
import { QuoteRegistry } from './indexer/registry.ts';
import { WssWakeSource } from './indexer/wss-wakeup.ts';

export function loadIndexerConfig(env: NodeJS.ProcessEnv = process.env) {
  const databaseUrl = required(env, 'DATABASE_URL');
  const httpRpcUrl = required(env, 'BSC_HTTP_RPC_URL');
  const wssRpcUrl = required(env, 'BSC_WSS_RPC_URL');
  const registry = QuoteRegistry.fromEnv(required(env, 'QUOTE_INDEXER_REGISTRY_JSON'));
  return {
    databaseUrl,
    httpRpcUrl,
    wssRpcUrl,
    registry,
    confirmationDepth: integerEnv(env, 'QUOTE_INDEXER_CONFIRMATION_DEPTH', 15, 0, 10_000),
    chunkSize: integerEnv(env, 'QUOTE_INDEXER_CHUNK_SIZE', 250, 1, 10_000),
    maxReorgDepth: integerEnv(env, 'QUOTE_INDEXER_MAX_REORG_DEPTH', 256, 1, 100_000),
    pollMs: integerEnv(env, 'QUOTE_INDEXER_POLL_MS', 15_000, 1_000, 300_000),
  };
}

export async function runIndexer(env: NodeJS.ProcessEnv = process.env) {
  const config = loadIndexerConfig(env);
  const pool = createPgPool(config.databaseUrl);
  const rpc = new HttpJsonRpcClient(config.httpRpcUrl);
  const indexer = new QuoteIndexer(rpc, new PostgresIndexerStore(pool), config.registry, {
    confirmationDepth: BigInt(config.confirmationDepth),
    chunkSize: BigInt(config.chunkSize),
    maxReorgDepth: BigInt(config.maxReorgDepth),
  });

  let stopped = false;
  let running = false;
  let pending = false;
  const requestSync = () => {
    if (stopped) return;
    pending = true;
    if (running) return;
    running = true;
    void (async () => {
      while (pending && !stopped) {
        pending = false;
        try {
          const result = await indexer.sync();
          console.log(JSON.stringify({
            level: 'info',
            event: 'indexer_sync',
            observedHead: result.observedHead.toString(),
            confirmedHead: result.confirmedHead.toString(),
            indexedThrough: result.indexedThrough.toString(),
            blocksCommitted: result.blocksCommitted,
            logsCommitted: result.logsCommitted,
            reorgs: result.reorgs,
          }));
        } catch (error) {
          console.error(JSON.stringify({
            level: 'error',
            event: 'indexer_sync_failed',
            code: error instanceof Error ? error.message.slice(0, 160) : 'unknown_error',
          }));
        }
      }
      running = false;
      if (pending && !stopped) requestSync();
    })();
  };

  await indexer.initialize();
  const wakeSource = new WssWakeSource(
    config.wssRpcUrl,
    config.registry.addresses,
    config.registry.topic0,
    requestSync,
  );
  wakeSource.start();
  const poll = setInterval(requestSync, config.pollMs);
  requestSync();

  const shutdown = async () => {
    if (stopped) return;
    stopped = true;
    clearInterval(poll);
    wakeSource.stop();
    while (running) await new Promise<void>((resolve) => setTimeout(resolve, 25));
    await pool.end();
  };
  process.once('SIGINT', () => void shutdown());
  process.once('SIGTERM', () => void shutdown());
}

function required(env: NodeJS.ProcessEnv, name: string) {
  const value = env[name]?.trim();
  if (!value) throw new Error(`${name}_required`);
  return value;
}

function integerEnv(env: NodeJS.ProcessEnv, name: string, fallback: number, minimum: number, maximum: number) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${name}_invalid`);
  return value;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await runIndexer();
}
