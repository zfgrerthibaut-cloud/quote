import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

import { BSC_CHAIN_ID, resolveTokenMedia, type CodexCredentials, type GmgnCredentials, type MediaHandlerDependencies } from './domain/media.ts';
import { createPgPool, PgContentAddressedStorage, PgMediaRepository } from './infra/postgres-media.ts';
import { configuredWebOrigins, createMarketHandler } from './market-server.ts';
import { createQuoteEligibilityHandlerFromEnv } from './quote-eligibility-server.ts';
import { MarketRealtimeHub, parseReplayAfter } from './realtime/market-hub.ts';

const BASE_HEADERS = {
  'x-content-type-options': 'nosniff',
  'cross-origin-resource-policy': 'same-origin',
};

export function createMediaHandler(dependencies: MediaHandlerDependencies) {
  return async function handleMediaRequest(request: Request) {
    const url = new URL(request.url);
    const match = /^\/v1\/media\/token\/(\d+)\/(0x[a-fA-F0-9]{40})$/.exec(url.pathname);
    if (request.method !== 'GET' || !match) {
      return emptyResponse(404, 0);
    }

    const chainId = Number(match[1]);
    const address = match[2];
    const result = await resolveTokenMedia(chainId, address, dependencies);

    if (result.kind === 'ok') {
      return new Response(toArrayBuffer(result.bytes), {
        status: 200,
        headers: {
          ...BASE_HEADERS,
          'cache-control': result.cacheSeconds > 0 ? `public, max-age=${result.cacheSeconds}, immutable` : 'no-store',
          etag: `"${result.contentHashHex}"`,
          'content-type': result.mime,
          'content-length': String(result.bytes.byteLength),
        },
      });
    }

    if (result.kind === 'not_found') {
      return emptyResponse(404, result.cacheSeconds);
    }

    return emptyResponse(result.status, result.cacheSeconds);
  };
}

export function createDefaultMediaHandlerFromEnv() {
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) throw new Error('DATABASE_URL_required');

  const pool = createPgPool(databaseUrl);
  return createMediaHandler({
    repository: new PgMediaRepository(pool),
    storage: new PgContentAddressedStorage(pool),
  });
}

export function createBackendHandler(
  mediaHandler: (request: Request) => Promise<Response>,
  marketHandler: (request: Request) => Promise<Response>,
  quoteEligibilityHandler?: (request: Request) => Promise<Response>,
) {
  return async function handleBackendRequest(request: Request) {
    const pathname = new URL(request.url).pathname;
    if (pathname.startsWith('/v1/media/')) return mediaHandler(request);
    if (pathname === '/v1/markets' || pathname === '/v1/stream' || pathname === '/v1/health') {
      return marketHandler(request);
    }
    if (pathname === '/v1/quote-token/eligibility' && quoteEligibilityHandler) {
      return quoteEligibilityHandler(request);
    }
    return emptyResponse(404, 0);
  };
}

export function getGmgnCredentialsFromEnv(): GmgnCredentials | null {
  const apiKey = process.env.GMGN_API_KEY;
  const clientId = process.env.GMGN_CLIENT_ID;
  if (!apiKey || !clientId) return null;
  return { apiKey, clientId };
}

export function getCodexCredentialsFromEnv(): CodexCredentials | null {
  const apiKey = process.env.CODEX_API_KEY;
  return apiKey ? { apiKey } : null;
}

export async function serveRequest(request: IncomingMessage, response: ServerResponse, handler: (request: Request) => Promise<Response>) {
  const host = request.headers.host ?? `127.0.0.1:${process.env.PORT ?? 8787}`;
  const url = new URL(request.url ?? '/', `http://${host}`);
  const headers = new Headers();
  for (const [name, rawValue] of Object.entries(request.headers)) {
    if (Array.isArray(rawValue)) {
      for (const value of rawValue) headers.append(name, value);
    } else if (rawValue !== undefined) {
      headers.set(name, rawValue);
    }
  }
  headers.set('x-quote-client-address', request.socket.remoteAddress ?? 'unknown');

  const abortController = new AbortController();
  let completed = false;
  let bodyDone = false;
  let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  const abort = () => {
    if (!completed) {
      abortController.abort();
      void reader?.cancel().catch(() => undefined);
    }
  };
  request.once('aborted', abort);
  response.once('close', abort);
  response.once('error', abort);

  try {
    const body = await readIncomingBody(request, abortController.signal, httpBodyLimitBytes());
    const webRequest = new Request(url, {
      method: request.method,
      headers,
      body,
      signal: abortController.signal,
    });
    const webResponse = await handler(webRequest);

    if (abortController.signal.aborted || response.destroyed) return;
    response.writeHead(webResponse.status, Object.fromEntries(webResponse.headers.entries()));
    if (!webResponse.body) {
      completed = true;
      response.end();
      return;
    }

    reader = webResponse.body.getReader();
    while (!abortController.signal.aborted) {
      const { done, value } = await reader.read().catch((error) => {
        if (abortController.signal.aborted) return { done: true, value: undefined };
        throw error;
      });
      if (done) break;
      if (response.destroyed) break;
      if (!(await writeResponseChunk(response, value, abortController.signal))) break;
    }
    bodyDone = true;
    if (!response.destroyed) {
      completed = true;
      response.end();
    }
  } catch (error) {
    if (abortController.signal.aborted || (error instanceof Error && error.message === 'request_aborted')) return;
    if (!(error instanceof PayloadTooLargeError)) throw error;
    if (!response.destroyed) {
      response.writeHead(413, {
        ...BASE_HEADERS,
        'cache-control': 'no-store',
      });
      completed = true;
      response.end();
    }
  } finally {
    if (reader && !bodyDone) await reader.cancel().catch(() => undefined);
    completed = true;
    request.off('aborted', abort);
    response.off('close', abort);
    response.off('error', abort);
  }
}

async function writeResponseChunk(response: ServerResponse, value: Uint8Array, signal: AbortSignal) {
  if (signal.aborted || response.destroyed) return false;
  if (response.write(value)) return true;
  await waitForDrain(response, signal);
  return !signal.aborted && !response.destroyed;
}

function waitForDrain(response: ServerResponse, signal: AbortSignal) {
  if (signal.aborted || response.destroyed) return Promise.resolve();

  return new Promise<void>((resolve, reject) => {
    const cleanup = () => {
      signal.removeEventListener('abort', resolveSafely);
      response.off('drain', resolveSafely);
      response.off('close', resolveSafely);
      response.off('error', rejectSafely);
    };
    const resolveSafely = () => {
      cleanup();
      resolve();
    };
    const rejectSafely = (error: Error) => {
      cleanup();
      reject(error);
    };

    signal.addEventListener('abort', resolveSafely, { once: true });
    response.once('drain', resolveSafely);
    response.once('close', resolveSafely);
    response.once('error', rejectSafely);
  });
}

class PayloadTooLargeError extends Error {}

async function readIncomingBody(request: IncomingMessage, signal: AbortSignal, maxBytes: number): Promise<ArrayBuffer | undefined> {
  const method = request.method?.toUpperCase();
  if (!method || method === 'GET' || method === 'HEAD') return undefined;

  const contentLength = request.headers['content-length'];
  if (typeof contentLength === 'string' && /^\d+$/.test(contentLength) && Number(contentLength) > maxBytes) {
    throw new PayloadTooLargeError('request_body_too_large');
  }

  const chunks: Buffer[] = [];
  let received = 0;
  for await (const chunk of request) {
    if (signal.aborted) throw new Error('request_aborted');
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    received += buffer.byteLength;
    if (received > maxBytes) throw new PayloadTooLargeError('request_body_too_large');
    chunks.push(buffer);
  }
  const body = Buffer.concat(chunks, received);
  const copy = new ArrayBuffer(body.byteLength);
  new Uint8Array(copy).set(body);
  return copy;
}

function httpBodyLimitBytes() {
  return integerEnv(process.env, 'QUOTE_HTTP_MAX_BODY_BYTES', 32_768, 256, 1_048_576);
}

export type WebSocketRuntimeConfig = Readonly<{
  maxClients: number;
  maxReplayLag: bigint;
  maxBufferedBytes: number;
  allowMissingOrigin: boolean;
}>;

export function websocketRuntimeConfigFromEnv(env: NodeJS.ProcessEnv = process.env): WebSocketRuntimeConfig {
  return {
    maxClients: integerEnv(env, 'QUOTE_WS_MAX_CLIENTS', 2_000, 1, 50_000),
    maxReplayLag: bigintEnv(env, 'QUOTE_WS_MAX_REPLAY_LAG', 50_000n, 0n, 9_223_372_036_854_775_807n),
    maxBufferedBytes: integerEnv(env, 'QUOTE_WS_MAX_BUFFERED_BYTES', 1_000_000, 16_384, 16_777_216),
    allowMissingOrigin: booleanEnv(env, 'QUOTE_WS_ALLOW_MISSING_ORIGIN', false),
  };
}

export function websocketOriginAllowed(origin: string | undefined, allowedOrigins: Set<string>, allowMissingOrigin: boolean) {
  if (!origin) return allowMissingOrigin;
  return allowedOrigins.has(origin);
}

function integerEnv(env: NodeJS.ProcessEnv, name: string, fallback: number, minimum: number, maximum: number) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${name}_invalid`);
  return value;
}

function bigintEnv(env: NodeJS.ProcessEnv, name: string, fallback: bigint, minimum: bigint, maximum: bigint) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = BigInt(raw);
  if (value < minimum || value > maximum) throw new Error(`${name}_invalid`);
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

function toArrayBuffer(bytes: Uint8Array) {
  const copy = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(copy).set(bytes);
  return copy;
}

function emptyResponse(status: number, cacheSeconds: number) {
  return new Response(null, {
    status,
    headers: {
      ...BASE_HEADERS,
      'cache-control': cacheSeconds > 0 ? `public, max-age=${cacheSeconds}` : 'no-store',
    },
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT ?? 8787);
  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) throw new Error('DATABASE_URL_required');

  const pool = createPgPool(databaseUrl);
  const allowedOrigins = configuredWebOrigins();
  const wsConfig = websocketRuntimeConfigFromEnv();
  const mediaHandler = createMediaHandler({
    repository: new PgMediaRepository(pool),
    storage: new PgContentAddressedStorage(pool),
  });
  const quoteEligibilityHandler = createQuoteEligibilityHandlerFromEnv(process.env, fetch, allowedOrigins);
  const handler = createBackendHandler(mediaHandler, createMarketHandler(pool, allowedOrigins), quoteEligibilityHandler);
  const realtimeHub = new MarketRealtimeHub(pool, {
    maxClients: wsConfig.maxClients,
    maxReplayLag: wsConfig.maxReplayLag,
    maxBufferedBytes: wsConfig.maxBufferedBytes,
  });
  const websocketServer = new WebSocketServer({ noServer: true, maxPayload: 2_048, perMessageDeflate: false });
  const server = createServer((request, response) => {
    serveRequest(request, response, handler).catch(() => {
      response.writeHead(500, {
        ...BASE_HEADERS,
        'cache-control': 'no-store',
      });
      response.end();
    });
  });

  server.on('upgrade', (request, socket, head) => {
    const host = request.headers.host ?? `127.0.0.1:${port}`;
    const url = new URL(request.url ?? '/', `http://${host}`);
    const origin = typeof request.headers.origin === 'string' ? request.headers.origin : undefined;
    if (url.pathname !== '/v1/ws' || !websocketOriginAllowed(origin, allowedOrigins, wsConfig.allowMissingOrigin)) {
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    if (!realtimeHub.canAcceptClient()) {
      socket.write('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    const afterValue = url.searchParams.get('after');
    const after = parseReplayAfter(afterValue);
    if (after === null) {
      socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    websocketServer.handleUpgrade(request, socket, head, (websocket) => {
      realtimeHub.add(websocket, after);
    });
  });

  const shutdown = async () => {
    server.close();
    websocketServer.close();
    await realtimeHub.stop().catch(() => undefined);
    await pool.end().catch(() => undefined);
  };
  process.once('SIGINT', () => void shutdown());
  process.once('SIGTERM', () => void shutdown());

  await realtimeHub.start();
  server.listen(port, '0.0.0.0');
  console.log(`QUOTE backend listening on :${port}; media chain=${BSC_CHAIN_ID}; markets REST/SSE/WS enabled`);
}
