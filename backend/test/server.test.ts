import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { connect } from 'node:net';
import { once } from 'node:events';
import test from 'node:test';

import { loadPgPoolRuntimeOptions } from '../src/infra/postgres-media.ts';
import { createMarketHandler, marketServerOptionsFromEnv } from '../src/market-server.ts';
import { parseReplayAfter } from '../src/realtime/market-hub.ts';
import { createBackendHandler, serveRequest } from '../src/server.ts';
import { websocketOriginAllowed, websocketRuntimeConfigFromEnv } from '../src/server.ts';

test('routes media and market APIs without exposing unrelated paths', async () => {
  const calls: string[] = [];
  const handler = createBackendHandler(
    async (request) => {
      calls.push(`media:${new URL(request.url).pathname}`);
      return new Response('media', { status: 200 });
    },
    async (request) => {
      calls.push(`market:${new URL(request.url).pathname}`);
      return new Response('market', { status: 200 });
    },
    async (request) => {
      calls.push(`eligibility:${new URL(request.url).pathname}`);
      return new Response('eligibility', { status: 200 });
    },
  );

  const media = await handler(new Request('https://api.quote.test/v1/media/token/56/0x0000000000000000000000000000000000000001'));
  const markets = await handler(new Request('https://api.quote.test/v1/markets'));
  const stream = await handler(new Request('https://api.quote.test/v1/stream'));
  const health = await handler(new Request('https://api.quote.test/v1/health'));
  const eligibility = await handler(new Request('https://api.quote.test/v1/quote-token/eligibility', { method: 'POST' }));
  const websocketOverHttp = await handler(new Request('https://api.quote.test/v1/ws'));
  const unrelated = await handler(new Request('https://api.quote.test/admin'));

  assert.equal(await media.text(), 'media');
  assert.equal(await markets.text(), 'market');
  assert.equal(await stream.text(), 'market');
  assert.equal(await health.text(), 'market');
  assert.equal(await eligibility.text(), 'eligibility');
  assert.equal(websocketOverHttp.status, 404);
  assert.equal(unrelated.status, 404);
  assert.deepEqual(calls, [
    'media:/v1/media/token/56/0x0000000000000000000000000000000000000001',
    'market:/v1/markets',
    'market:/v1/stream',
    'market:/v1/health',
    'eligibility:/v1/quote-token/eligibility',
  ]);
});

test('forwards request headers and cancels an SSE body when the client disconnects', async () => {
  let cancelStream: (() => void) | undefined;
  const cancelled = new Promise<void>((resolve) => { cancelStream = resolve; });
  let observedOrigin: string | null = null;
  let observedLastEventId: string | null = null;

  const server = createServer((request, response) => {
    void serveRequest(request, response, async (webRequest) => {
      observedOrigin = webRequest.headers.get('origin');
      observedLastEventId = webRequest.headers.get('last-event-id');
      return new Response(new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new TextEncoder().encode(': connected\n\n'));
        },
        cancel() {
          cancelStream?.();
        },
      }), {
        headers: { 'content-type': 'text/event-stream' },
      });
    }).catch(() => undefined);
  });

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address === 'object');

  try {
    const socket = connect(address.port, '127.0.0.1');
    socket.write([
      'GET /v1/stream HTTP/1.1',
      `Host: 127.0.0.1:${address.port}`,
      'Origin: https://quote.test',
      'Last-Event-ID: 42',
      'Connection: close',
      '',
      '',
    ].join('\r\n'));
    await once(socket, 'data');
    socket.destroy();
    await Promise.race([
      cancelled,
      new Promise<never>((_, reject) => setTimeout(() => reject(new Error('stream_not_cancelled')), 1_000)),
    ]);

    assert.equal(observedOrigin, 'https://quote.test');
    assert.equal(observedLastEventId, '42');
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('forwards bounded POST bodies into web requests', async () => {
  const server = createServer((request, response) => {
    void serveRequest(request, response, async (webRequest) => {
      assert.equal(webRequest.headers.get('x-quote-client-address'), '127.0.0.1');
      return new Response(await webRequest.text(), {
        headers: { 'content-type': 'application/json' },
      });
    }).catch(() => undefined);
  });

  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  assert.ok(address && typeof address === 'object');

  try {
    const response = await fetch(`http://127.0.0.1:${address.port}/v1/quote-token/eligibility`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{"quoteToken":"0x0000000000000000000000000000000000000001"}',
    });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), '{"quoteToken":"0x0000000000000000000000000000000000000001"}');
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test('loads bounded Postgres and realtime runtime limits from env', () => {
  assert.deepEqual(loadPgPoolRuntimeOptions({
    QUOTE_PG_POOL_MAX: '6',
    QUOTE_PG_CONNECT_TIMEOUT_MS: '7000',
    QUOTE_PG_IDLE_TIMEOUT_MS: '45000',
    QUOTE_PG_QUERY_TIMEOUT_MS: '12000',
    QUOTE_PG_STATEMENT_TIMEOUT_MS: '13000',
    QUOTE_PG_IDLE_IN_TRANSACTION_TIMEOUT_MS: '9000',
  }), {
    max: 6,
    connectionTimeoutMillis: 7000,
    idleTimeoutMillis: 45000,
    query_timeout: 12000,
    statement_timeout: 13000,
    idle_in_transaction_session_timeout: 9000,
  });

  assert.deepEqual(websocketRuntimeConfigFromEnv({
    QUOTE_WS_MAX_CLIENTS: '9',
    QUOTE_WS_MAX_REPLAY_LAG: '500',
    QUOTE_WS_MAX_BUFFERED_BYTES: '65536',
    QUOTE_WS_ALLOW_MISSING_ORIGIN: 'true',
  }), {
    maxClients: 9,
    maxReplayLag: 500n,
    maxBufferedBytes: 65536,
    allowMissingOrigin: true,
  });

  assert.deepEqual(marketServerOptionsFromEnv({
    QUOTE_SSE_ENABLED: 'false',
    QUOTE_SSE_MAX_CLIENTS: '3',
    QUOTE_SSE_REPLAY_LIMIT: '100',
    QUOTE_SSE_POLL_MS: '1000',
    QUOTE_SSE_HEARTBEAT_MS: '5000',
  }), {
    sseEnabled: false,
    maxSseClients: 3,
    maxSseReplay: 100,
    ssePollMs: 1000,
    sseHeartbeatMs: 5000,
  });

  assert.throws(() => loadPgPoolRuntimeOptions({ QUOTE_PG_POOL_MAX: '0' }), /QUOTE_PG_POOL_MAX_invalid/);
});

test('validates websocket origins and bounded replay cursors', () => {
  const origins = new Set(['https://quote.test']);

  assert.equal(websocketOriginAllowed(undefined, origins, false), false);
  assert.equal(websocketOriginAllowed(undefined, origins, true), true);
  assert.equal(websocketOriginAllowed('https://quote.test', origins, false), true);
  assert.equal(websocketOriginAllowed('https://evil.test', origins, false), false);

  assert.equal(parseReplayAfter(null), 0n);
  assert.equal(parseReplayAfter('42'), 42n);
  assert.equal(parseReplayAfter('9223372036854775807'), 9223372036854775807n);
  assert.equal(parseReplayAfter('9223372036854775808'), null);
  assert.equal(parseReplayAfter('1'.repeat(64)), null);
  assert.equal(parseReplayAfter('-1'), null);
});

test('caps and can explicitly disable SSE streams', async () => {
  const pool = {
    query: async () => ({ rows: [] }),
  };
  const capped = createMarketHandler(pool as never, new Set(['https://quote.test']), {
    sseEnabled: true,
    maxSseClients: 1,
    maxSseReplay: 10,
    ssePollMs: 60_000,
    sseHeartbeatMs: 60_000,
  });

  const first = await capped(new Request('https://api.quote.test/v1/stream', {
    headers: { origin: 'https://quote.test' },
  }));
  const second = await capped(new Request('https://api.quote.test/v1/stream', {
    headers: { origin: 'https://quote.test' },
  }));
  assert.equal(first.status, 200);
  assert.equal(second.status, 503);
  assert.deepEqual(await second.json(), { error: 'sse_capacity' });

  await first.body?.cancel();
  const third = await capped(new Request('https://api.quote.test/v1/stream?after=not-a-number', {
    headers: { origin: 'https://quote.test' },
  }));
  assert.equal(third.status, 400);
  assert.deepEqual(await third.json(), { error: 'invalid_after' });

  const disabled = createMarketHandler(pool as never, new Set(['https://quote.test']), {
    sseEnabled: false,
    maxSseClients: 1,
    maxSseReplay: 10,
    ssePollMs: 60_000,
    sseHeartbeatMs: 60_000,
  });
  const response = await disabled(new Request('https://api.quote.test/v1/stream', {
    headers: { origin: 'https://quote.test' },
  }));
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: 'sse_disabled' });
});
