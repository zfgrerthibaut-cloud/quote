import type { Pool } from 'pg';

import { listMarkets, parseMarketListQuery, readOutboxAfter } from './infra/postgres-markets.ts';
import { parseReplayAfter } from './realtime/market-hub.ts';

const MAX_SSE_REPLAY = 500;

export type MarketServerOptions = Readonly<{
  sseEnabled: boolean;
  maxSseClients: number;
  maxSseReplay: number;
  ssePollMs: number;
  sseHeartbeatMs: number;
}>;

export function configuredWebOrigins(raw = process.env.QUOTE_WEB_ORIGINS ?? '') {
  return new Set(raw.split(',').map((value) => value.trim()).filter(Boolean));
}

export function marketServerOptionsFromEnv(env: NodeJS.ProcessEnv = process.env): MarketServerOptions {
  return {
    sseEnabled: booleanEnv(env, 'QUOTE_SSE_ENABLED', true),
    maxSseClients: integerEnv(env, 'QUOTE_SSE_MAX_CLIENTS', 500, 0, 20_000),
    maxSseReplay: integerEnv(env, 'QUOTE_SSE_REPLAY_LIMIT', MAX_SSE_REPLAY, 1, 5_000),
    ssePollMs: integerEnv(env, 'QUOTE_SSE_POLL_MS', 750, 250, 60_000),
    sseHeartbeatMs: integerEnv(env, 'QUOTE_SSE_HEARTBEAT_MS', 15_000, 5_000, 120_000),
  };
}

export function createMarketHandler(
  pool: Pool,
  allowedOrigins = configuredWebOrigins(),
  options = marketServerOptionsFromEnv(),
) {
  let activeSseClients = 0;

  return async function handleMarketRequest(request: Request) {
    const url = new URL(request.url);
    const cors = corsHeaders(request, allowedOrigins);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'GET') return jsonResponse({ error: 'method_not_allowed' }, 405, cors);

    if (url.pathname === '/v1/markets') {
      const payload = await listMarkets(pool, parseMarketListQuery(url));
      return jsonResponse(payload, 200, new Headers({
        ...Object.fromEntries(cors),
        'cache-control': 'public, max-age=1, stale-while-revalidate=4',
      }));
    }

    if (url.pathname === '/v1/stream') {
      if (!options.sseEnabled) return jsonResponse({ error: 'sse_disabled' }, 404, cors);
      const after = parseReplayAfter(url.searchParams.get('after') ?? request.headers.get('last-event-id'));
      if (after === null) return jsonResponse({ error: 'invalid_after' }, 400, cors);
      if (activeSseClients >= options.maxSseClients) return jsonResponse({ error: 'sse_capacity' }, 503, cors);
      activeSseClients += 1;
      return sseResponse(pool, after, cors, options, () => {
        activeSseClients = Math.max(0, activeSseClients - 1);
      });
    }

    if (url.pathname === '/v1/health') {
      const status = await pool.query(`
        SELECT
          COALESCE((SELECT max(number) FROM chain_blocks WHERE canonical), 0)::text AS indexed_block,
          COALESCE((SELECT max(id) FROM outbox), 0)::text AS latest_event_id
      `);
      return jsonResponse({ status: 'ok', ...status.rows[0] }, 200, new Headers({ ...Object.fromEntries(cors), 'cache-control': 'no-store' }));
    }

    return jsonResponse({ error: 'not_found' }, 404, cors);
  };
}

function sseResponse(
  pool: Pool,
  initialEventId: bigint,
  cors: Headers,
  options: MarketServerOptions,
  releaseClient: () => void,
) {
  let cursor = initialEventId;
  let poll: NodeJS.Timeout | null = null;
  let heartbeat: NodeJS.Timeout | null = null;
  let busy = false;
  let closed = false;
  let released = false;
  const release = () => {
    if (released) return;
    released = true;
    releaseClient();
  };
  const cleanup = () => {
    if (poll) clearInterval(poll);
    if (heartbeat) clearInterval(heartbeat);
    poll = null;
    heartbeat = null;
    release();
  };
  let flushNow: (() => void) | null = null;

  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      const encoder = new TextEncoder();
      const send = (value: string, force = false) => {
        if (closed) return false;
        if (!force && controller.desiredSize !== null && controller.desiredSize <= 0) return false;
        try {
          controller.enqueue(encoder.encode(value));
          return true;
        } catch {
          closed = true;
          cleanup();
          return false;
        }
      };
      const close = () => {
        if (closed) return;
        closed = true;
        cleanup();
        try {
          controller.close();
        } catch {
          // already closed or cancelled
        }
      };
      const flush = async () => {
        if (busy || closed) return;
        busy = true;
        try {
          const events = await readOutboxAfter(pool, cursor, options.maxSseReplay + 1);
          if (closed) return;
          if (events.length > options.maxSseReplay) {
            send(`event: resync_required\ndata: ${JSON.stringify({ schemaVersion: 1, type: 'resync_required' })}\n\n`, true);
            close();
            return;
          }
          for (const event of events) {
            if (closed) return;
            const nextCursor = BigInt(event.id);
            if (!send(`id: ${event.id}\nevent: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)) return;
            cursor = nextCursor;
          }
        } catch {
          send(`event: stream_error\ndata: {"type":"stream_error"}\n\n`, true);
        } finally {
          busy = false;
        }
      };
      flushNow = () => void flush();
      send(': connected\n\n', true);
      void flush();
      poll = setInterval(() => void flush(), options.ssePollMs);
      heartbeat = setInterval(() => {
        if (send(`: heartbeat ${Date.now()}\n\n`)) void flush();
      }, options.sseHeartbeatMs);
    },
    pull() {
      flushNow?.();
    },
    cancel() {
      closed = true;
      cleanup();
    },
  });

  return new Response(stream, {
    status: 200,
    headers: new Headers({
      ...Object.fromEntries(cors),
      'cache-control': 'no-cache, no-transform',
      connection: 'keep-alive',
      'content-type': 'text/event-stream; charset=utf-8',
      'x-accel-buffering': 'no',
    }),
  });
}

function integerEnv(env: NodeJS.ProcessEnv, name: string, fallback: number, minimum: number, maximum: number) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${name}_invalid`);
  return value;
}

function booleanEnv(env: NodeJS.ProcessEnv, name: string, fallback: boolean) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  const normalized = raw.trim().toLowerCase();
  if (['1', 'true', 'yes'].includes(normalized)) return true;
  if (['0', 'false', 'no'].includes(normalized)) return false;
  throw new Error(`${name}_invalid`);
}

function corsHeaders(request: Request, allowedOrigins: Set<string>) {
  const headers = new Headers({ vary: 'Origin' });
  const origin = request.headers.get('origin');
  if (origin && allowedOrigins.has(origin)) {
    headers.set('access-control-allow-origin', origin);
    headers.set('access-control-allow-methods', 'GET, OPTIONS');
    headers.set('access-control-allow-headers', 'Last-Event-ID');
  }
  return headers;
}

function jsonResponse(payload: unknown, status: number, headers: Headers) {
  const responseHeaders = new Headers(headers);
  responseHeaders.set('content-type', 'application/json; charset=utf-8');
  responseHeaders.set('x-content-type-options', 'nosniff');
  return new Response(JSON.stringify(payload), { status, headers: responseHeaders });
}
