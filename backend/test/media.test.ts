import assert from 'node:assert/strict';
import test from 'node:test';

import {
  BSC_CHAIN_ID,
  type ClaimedMediaResolution,
  type CompleteMissInput,
  type CompleteReadyInput,
  detectSafeImageMime,
  type FailMediaResolutionInput,
  NEGATIVE_TTL_MS,
  PENDING_CACHE_SECONDS,
  POSITIVE_TTL_MS,
  processNextMediaResolution,
  resolveClaimedTokenMedia,
  resolveTokenMedia,
  type ContentAddressedStorage,
  type DecodedMedia,
  type MediaCacheRecord,
  type MediaMime,
  type MediaRequestStatus,
  type MediaWorkerRepository,
  type StoredMediaObject,
} from '../src/domain/media.ts';
import { createMediaHandler } from '../src/server.ts';

const TOKEN = '0xe5ae318389b8d6d09370a675479c64862152d126';
const OTHER = '0x1111111111111111111111111111111111111111';
const PNG = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
  0x00, 0x00, 0x00, 0x00,
]);
const SANITIZED_PNG = new Uint8Array([...PNG, 0x51, 0x54]);
const JPEG = new Uint8Array([
  0xff, 0xd8,
  0xff, 0xc0, 0x00, 0x11, 0x08,
  0x00, 0x01, 0x00, 0x01,
  0x03,
  0x01, 0x11, 0x00,
  0x02, 0x11, 0x00,
  0x03, 0x11, 0x00,
  0xff, 0xd9,
]);
const APNG = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x61, 0x63, 0x54, 0x4c,
  0x00, 0x00, 0x00, 0x00,
]);
const STATIC_WEBP = new Uint8Array([
  0x52, 0x49, 0x46, 0x46, 0x16, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58,
  0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]);
const ANIMATED_WEBP = new Uint8Array([
  0x52, 0x49, 0x46, 0x46, 0x16, 0x00, 0x00, 0x00,
  0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x58,
  0x0a, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
]);
const sanitizeImage = async (input: DecodedMedia): Promise<DecodedMedia> => ({
  bytes: SANITIZED_PNG,
  mime: 'image/png',
  width: input.width,
  height: input.height,
});

test('resolves DexScreener images only from exact BSC base-token matches', async () => {
  const store = new MemoryMediaStore();
  const fetcher = createFetch([
    jsonResponse([
        {
          chainId: 'bsc',
          baseToken: { address: OTHER },
          quoteToken: { address: TOKEN },
          liquidity: { usd: 9000000 },
          info: { imageUrl: 'https://cdn.dexscreener.com/cms/images/coin-a.png' },
        },
        {
          chainId: 'ethereum',
          baseToken: { address: TOKEN },
          liquidity: { usd: 9000000 },
          info: { imageUrl: 'https://cdn.dexscreener.com/cms/images/coin-b.png' },
        },
        {
          chainId: 'bsc',
          baseToken: { address: TOKEN },
          liquidity: { usd: 1 },
          info: { imageUrl: 'https://cdn.dexscreener.com/cms/images/coin-c.png' },
        },
      ]),
    bytesResponse(PNG),
  ]);

  const result = await resolveClaimedTokenMedia(claimFor(TOKEN), {
    repository: store,
    storage: store,
    fetch: fetcher,
    sanitizeImage,
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');

  assert.equal(result, 'completed');
  assert.equal(store.record?.status, 'ready');
  assert.equal(store.record?.source, 'dexscreener');
  assert.deepEqual(store.readyBytes(), [...SANITIZED_PNG]);
  assert.notDeepEqual(store.readyBytes(), [...PNG]);
  assert.equal(fetcher.calls.length, 2);
  assert.equal(fetcher.calls[0], `https://api.dexscreener.com/tokens/v1/bsc/${TOKEN}`);
  assert.match(fetcher.calls[1], /^https:\/\/cdn\.dexscreener\.com\//);
});

test('falls back to gated GMGN OpenAPI and requires exact returned address', async () => {
  const store = new MemoryMediaStore();
  const fetcher = createFetch([
    jsonResponse([]),
    jsonResponse({ data: { address: TOKEN, logo: 'https://gmgn.ai/external-res/token.png' } }),
    bytesResponse(PNG),
  ]);

  const result = await resolveClaimedTokenMedia(claimFor(TOKEN), {
    repository: store,
    storage: store,
    fetch: fetcher,
    sanitizeImage,
    gmgn: { apiKey: 'secret-key', clientId: 'client-id' },
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');

  assert.equal(result, 'completed');
  assert.equal(store.record?.source, 'gmgn');
  assert.match(fetcher.calls[1], /^https:\/\/openapi\.gmgn\.ai\/v1\/token\/info\?/);
  assert.equal(fetcher.headers[1]?.['x-apikey'], 'secret-key');
});

test('falls back to the official Codex API used by Defined when configured', async () => {
  const store = new MemoryMediaStore();
  const fetcher = createFetch([
    jsonResponse([]),
    jsonResponse({ data: { token: { address: TOKEN, networkId: 56, info: { imageSmallUrl: 'https://token-media.defined.fi/56_token_small.png' } } } }),
    bytesResponse(PNG),
  ]);

  const result = await resolveClaimedTokenMedia(claimFor(TOKEN), {
    repository: store,
    storage: store,
    fetch: fetcher,
    sanitizeImage,
    codex: { apiKey: 'codex-secret' },
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');

  assert.equal(result, 'completed');
  assert.equal(store.record?.source, 'codex');
  assert.equal(fetcher.calls[1], 'https://graph.codex.io/graphql');
  assert.equal(fetcher.headers[1]?.authorization, 'codex-secret');
});

test('public token media requests only read cache and enqueue known tokens', async () => {
  const store = new MemoryMediaStore();
  const dependencies = {
    repository: store,
    storage: store,
    nowMs: () => 1_000_000,
  };
  const [left, right] = await Promise.all([
    resolveTokenMedia(BSC_CHAIN_ID, TOKEN, dependencies),
    resolveTokenMedia(BSC_CHAIN_ID, TOKEN, dependencies),
  ]);

  assert.equal(left.kind, 'not_found');
  assert.equal(right.kind, 'not_found');
  assert.equal(left.kind === 'not_found' ? left.cacheSeconds : 0, PENDING_CACHE_SECONDS);
  assert.equal(store.requests, 1);
  assert.equal(store.requestStatuses[0], 'queued');
  assert.equal(store.requestStatuses[1], 'rate_limited');

  const unknownStore = new MemoryMediaStore();
  unknownStore.knownTokens.delete(OTHER);
  const unknown = await resolveTokenMedia(BSC_CHAIN_ID, OTHER, {
    repository: unknownStore,
    storage: unknownStore,
    nowMs: () => 1_000_000,
  });
  assert.equal(unknown.kind, 'not_found');
  assert.equal(unknownStore.requests, 0);
  assert.equal(unknownStore.requestStatuses[0], 'unknown');
});

test('stale ready media is served while a bounded refresh is enqueued', async () => {
  const store = new MemoryMediaStore();
  const object = await store.put(SANITIZED_PNG, 'image/png');
  store.record = {
    chainId: BSC_CHAIN_ID,
    tokenAddress: TOKEN,
    status: 'ready',
    source: 'dexscreener',
    contentHashHex: object.contentHashHex,
    objectKey: object.objectKey,
    mime: object.mime,
    expiresAtMs: 900_000,
  };

  const result = await resolveTokenMedia(BSC_CHAIN_ID, TOKEN, {
    repository: store,
    storage: store,
    nowMs: () => 1_000_000,
  });

  assert.equal(result.kind, 'ok');
  assert.equal(result.kind === 'ok' ? result.cacheSeconds : 1, 0);
  assert.equal(store.requests, 1);
});

test('negative results are cached for five minutes without refetching', async () => {
  const store = new MemoryMediaStore();
  store.record = {
    chainId: BSC_CHAIN_ID,
    tokenAddress: TOKEN,
    status: 'negative',
    source: null,
    contentHashHex: null,
    objectKey: null,
    mime: null,
    expiresAtMs: 2_000_000 + NEGATIVE_TTL_MS,
  };
  const dependencies = {
    repository: store,
    storage: store,
    nowMs: () => 2_000_000,
  };

  const first = await resolveTokenMedia(BSC_CHAIN_ID, TOKEN, dependencies);
  const second = await resolveTokenMedia(BSC_CHAIN_ID, TOKEN, dependencies);

  assert.equal(first.kind, 'not_found');
  assert.equal(second.kind, 'not_found');
  assert.equal(store.requests, 0);
  assert.equal(store.record?.status, 'negative');
  assert.equal(first.kind === 'not_found' ? first.cacheSeconds : 0, NEGATIVE_TTL_MS / 1_000);
});

test('retries only temporary provider failures', async () => {
  const retryStore = new MemoryMediaStore();
  const retryFetch = createFetch([
    statusResponse(500),
    statusResponse(429),
    jsonResponse([]),
  ]);
  const retryResult = await resolveClaimedTokenMedia(claimFor(TOKEN), {
    repository: retryStore,
    storage: retryStore,
    fetch: retryFetch,
    sanitizeImage,
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');
  assert.equal(retryResult, 'completed');
  assert.equal(retryFetch.calls.length, 3);
  assert.equal(retryStore.record?.status, 'negative');

  const noRetryStore = new MemoryMediaStore();
  const noRetryFetch = createFetch([statusResponse(404)]);
  await resolveClaimedTokenMedia(claimFor(OTHER), {
    repository: noRetryStore,
    storage: noRetryStore,
    fetch: noRetryFetch,
    sanitizeImage,
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');
  assert.equal(noRetryFetch.calls.length, 1);

  const transientStore = new MemoryMediaStore();
  const transientFetch = createFetch([statusResponse(500), statusResponse(500), statusResponse(500)]);
  const transientResult = await resolveClaimedTokenMedia(claimFor(TOKEN), {
    repository: transientStore,
    storage: transientStore,
    fetch: transientFetch,
    sanitizeImage,
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');
  assert.equal(transientResult, 'retry_scheduled');
  assert.equal(transientStore.failed?.errorCode, 'upstream_error');
});

test('times out and cancels slow image response bodies', async () => {
  const store = new MemoryMediaStore();
  const slowBodies = [slowBodyResponse(), slowBodyResponse(), slowBodyResponse()];
  const fetcher = createFetch([
    jsonResponse([{
        chainId: 'bsc',
        baseToken: { address: TOKEN },
        liquidity: { usd: 10 },
        info: { imageUrl: 'https://cdn.dexscreener.com/cms/images/slow-token.png' },
      }]),
    ...slowBodies,
  ]);

  const result = await resolveClaimedTokenMedia(claimFor(TOKEN), {
    repository: store,
    storage: store,
    fetch: fetcher,
    sanitizeImage,
    imageTimeoutMs: 5,
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1');

  assert.equal(result, 'completed');
  assert.equal(store.record?.status, 'rejected');
  assert.equal(store.record?.source, 'dexscreener');
  assert.equal(fetcher.calls.length, 4);
  assert.equal(slowBodies.every((response) => response.cancelled()), true);
});

test('accepts only JPEG, PNG and static WebP bytes', () => {
  assert.equal(detectSafeImageMime(JPEG), 'image/jpeg');
  assert.equal(detectSafeImageMime(PNG), 'image/png');
  assert.equal(detectSafeImageMime(STATIC_WEBP), 'image/webp');
  assert.equal(detectSafeImageMime(APNG), null);
  assert.equal(detectSafeImageMime(ANIMATED_WEBP), null);
  assert.equal(detectSafeImageMime(new TextEncoder().encode('<svg></svg>')), null);
  assert.equal(detectSafeImageMime(new TextEncoder().encode('GIF89a')), null);
});

test('media handler exposes GET /v1/media/token/56/:address with cache hardening headers', async () => {
  const store = new MemoryMediaStore();
  const object = await store.put(SANITIZED_PNG, 'image/png');
  store.record = {
    chainId: BSC_CHAIN_ID,
    tokenAddress: TOKEN,
    status: 'ready',
    source: 'dexscreener',
    contentHashHex: object.contentHashHex,
    objectKey: object.objectKey,
    mime: object.mime,
    expiresAtMs: 1_000_000 + POSITIVE_TTL_MS,
  };
  const handler = createMediaHandler({
    repository: store,
    storage: store,
    nowMs: () => 1_000_000,
  });

  const response = await handler(new Request(`http://quote.local/v1/media/token/56/${TOKEN}`));
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'image/png');
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(response.headers.get('cross-origin-resource-policy'), 'same-origin');
  assert.match(response.headers.get('cache-control') ?? '', /^public, max-age=86400/);
  assert.equal((await response.arrayBuffer()).byteLength, SANITIZED_PNG.byteLength);
  assert.equal(store.requests, 0);
});

test('processNextMediaResolution claims one leased media row', async () => {
  const store = new MemoryMediaStore();
  store.claim = claimFor(TOKEN);
  const fetcher = createFetch([
    jsonResponse([{
        chainId: 'bsc',
        baseToken: { address: TOKEN },
        liquidity: { usd: 10 },
        info: { imageUrl: 'https://cdn.dexscreener.com/cms/images/token.png' },
      }]),
    bytesResponse(PNG),
  ]);

  const result = await processNextMediaResolution({
    repository: store,
    storage: store,
    fetch: fetcher,
    sanitizeImage,
    sleepMs: async () => undefined,
    random: () => 0,
  }, 'worker-1', 120);

  assert.equal(result, 'completed');
  assert.equal(store.claims, 1);
  assert.equal(store.record?.status, 'ready');
});

class MemoryMediaStore implements MediaWorkerRepository, ContentAddressedStorage {
  record: MediaCacheRecord | null = null;
  objects = new Map<string, StoredMediaObject>();
  knownTokens = new Set([TOKEN, OTHER]);
  requests = 0;
  requestStatuses: MediaRequestStatus[] = [];
  claim: ClaimedMediaResolution | null = null;
  claims = 0;
  failed: FailMediaResolutionInput | null = null;
  private readonly lastRequests = new Map<string, number>();

  async getCached(chainId: number, tokenAddress: string, nowMs: number) {
    if (!this.record) return null;
    if (this.record.chainId !== chainId || this.record.tokenAddress !== tokenAddress) return null;
    if (this.record.status !== 'ready' && this.record.expiresAtMs <= nowMs) return null;
    return this.record;
  }

  async request(chainId: number, tokenAddress: string, nowMs: number) {
    const key = `${chainId}:${tokenAddress}`;
    if (!this.knownTokens.has(tokenAddress)) {
      this.requestStatuses.push('unknown');
      return 'unknown' as const;
    }
    const previous = this.lastRequests.get(key);
    if (previous !== undefined && nowMs - previous < 30_000) {
      this.requestStatuses.push('rate_limited');
      return 'rate_limited' as const;
    }
    this.requests += 1;
    this.lastRequests.set(key, nowMs);
    this.requestStatuses.push('queued');
    return 'queued' as const;
  }

  async claimNext() {
    this.claims += 1;
    const claim = this.claim;
    this.claim = null;
    return claim;
  }

  async completeReady(input: CompleteReadyInput) {
    this.record = {
      chainId: input.chainId,
      tokenAddress: input.tokenAddress,
      status: 'ready',
      source: input.source,
      contentHashHex: input.contentHashHex,
      objectKey: input.objectKey,
      mime: input.mime,
      expiresAtMs: input.expiresAtMs,
    };
    return true;
  }

  async completeMiss(input: CompleteMissInput) {
    this.record = {
      chainId: input.chainId,
      tokenAddress: input.tokenAddress,
      status: input.status,
      source: input.source,
      contentHashHex: null,
      objectKey: null,
      mime: null,
      expiresAtMs: input.cacheSeconds * 1_000,
    };
    return true;
  }

  async fail(input: FailMediaResolutionInput) {
    this.failed = input;
    return true;
  }

  async put(bytes: Uint8Array, mime: MediaMime) {
    const contentHashHex = Buffer.from(bytes).toString('hex').padEnd(64, '0').slice(0, 64);
    const objectKey = `media/sha256/${contentHashHex}.${mime.slice('image/'.length)}`;
    const object = { objectKey, contentHashHex, mime, bytes };
    this.objects.set(objectKey, object);
    return object;
  }

  async get(objectKey: string) {
    return this.objects.get(objectKey) ?? null;
  }

  readyBytes() {
    return [...(this.record?.objectKey ? this.objects.get(this.record.objectKey)?.bytes ?? [] : [])];
  }
}

function claimFor(tokenAddress: string, attemptCount = 1): ClaimedMediaResolution {
  return {
    chainId: BSC_CHAIN_ID,
    tokenAddress,
    previousStatus: 'pending',
    attemptCount,
    leaseGeneration: 1n,
    staleObjectKey: null,
  };
}

function createFetch(responses: Response[]) {
  const calls: string[] = [];
  const headers: Array<Record<string, string> | undefined> = [];
  const fetcher = async (input: string | URL | Request, init?: RequestInit) => {
    calls.push(input.toString());
    headers.push(init?.headers as Record<string, string> | undefined);
    const response = responses.shift();
    if (!response) throw new Error('unexpected_fetch');
    return response;
  };
  return Object.assign(fetcher as typeof fetch, { calls, headers });
}

function jsonResponse(value: unknown) {
  return new Response(JSON.stringify(value), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
}

function bytesResponse(bytes: Uint8Array) {
  return new Response(toArrayBuffer(bytes), {
    status: 200,
    headers: { 'content-type': 'application/octet-stream', 'content-length': String(bytes.byteLength) },
  });
}

function toArrayBuffer(bytes: Uint8Array) {
  const copy = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(copy).set(bytes);
  return copy;
}

function statusResponse(status: number) {
  return new Response(null, { status });
}

function slowBodyResponse() {
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    pull() {
      return new Promise<void>(() => undefined);
    },
    cancel() {
      cancelled = true;
    },
  });
  return Object.assign(new Response(stream, {
    status: 200,
    headers: { 'content-type': 'application/octet-stream' },
  }), { cancelled: () => cancelled });
}
