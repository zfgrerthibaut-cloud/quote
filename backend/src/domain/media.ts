import { createHash, randomUUID } from 'node:crypto';

export const BSC_CHAIN_ID = 56;
export const ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
export const DEXSCREENER_TOKEN_URL = 'https://api.dexscreener.com/tokens/v1/bsc/';
export const GMGN_OPENAPI_HOST = 'https://openapi.gmgn.ai';
export const CODEX_GRAPHQL_URL = 'https://graph.codex.io/graphql';
export const MAX_JSON_BYTES = 512_000;
export const MAX_IMAGE_BYTES = 1_500_000;
export const PROVIDER_TIMEOUT_MS = 4_500;
export const IMAGE_TIMEOUT_MS = 4_500;
export const POSITIVE_TTL_MS = 24 * 60 * 60 * 1_000;
export const NEGATIVE_TTL_MS = 5 * 60 * 1_000;
export const PENDING_CACHE_SECONDS = 15;
export const MAX_RETRY_ATTEMPTS = 3;

export type MediaMime = 'image/jpeg' | 'image/png' | 'image/webp';
export type MediaProviderName = 'dexscreener' | 'gmgn' | 'codex';
export type MediaCacheStatus = 'ready' | 'negative' | 'rejected';
export type MediaRequestStatus = 'queued' | 'unknown' | 'rate_limited';

export type MediaCacheRecord = Readonly<{
  chainId: number;
  tokenAddress: string;
  status: MediaCacheStatus;
  source: MediaProviderName | null;
  contentHashHex: string | null;
  objectKey: string | null;
  mime: MediaMime | null;
  expiresAtMs: number;
}>;

export type StoredMediaObject = Readonly<{
  objectKey: string;
  contentHashHex: string;
  mime: MediaMime;
  bytes: Uint8Array;
}>;

export type DecodedMedia = Readonly<{
  bytes: Uint8Array;
  mime: MediaMime;
  width: number;
  height: number;
}>;

export type ImageSanitizer = (input: DecodedMedia) => Promise<DecodedMedia>;

export type StoreReadyInput = Readonly<{
  chainId: number;
  tokenAddress: string;
  source: MediaProviderName;
  providerRef: string;
  objectKey: string;
  contentHashHex: string;
  mime: MediaMime;
  byteSize: number;
  width: number;
  height: number;
  expiresAtMs: number;
}>;

export type StoreMissInput = Readonly<{
  chainId: number;
  tokenAddress: string;
  status: 'negative' | 'rejected';
  source: MediaProviderName | null;
  expiresAtMs: number;
  nextRetryAtMs: number | null;
}>;

export type MediaRepository = Readonly<{
  getCached(chainId: number, tokenAddress: string, nowMs: number): Promise<MediaCacheRecord | null>;
  request(chainId: number, tokenAddress: string, nowMs: number): Promise<MediaRequestStatus>;
}>;

export type ClaimedMediaResolution = Readonly<{
  chainId: number;
  tokenAddress: string;
  previousStatus: 'pending' | 'ready';
  attemptCount: number;
  leaseGeneration: bigint;
  staleObjectKey: string | null;
}>;

export type CompleteReadyInput = StoreReadyInput & Readonly<{
  workerId: string;
  leaseGeneration: bigint;
  providerPayloadHashHex: string | null;
}>;

export type CompleteMissInput = Readonly<{
  workerId: string;
  chainId: number;
  tokenAddress: string;
  leaseGeneration: bigint;
  status: 'negative' | 'rejected';
  source: MediaProviderName | null;
  errorCode: string;
  cacheSeconds: number;
}>;

export type FailMediaResolutionInput = Readonly<{
  workerId: string;
  chainId: number;
  tokenAddress: string;
  leaseGeneration: bigint;
  errorCode: string;
  retrySeconds: number;
}>;

export type MediaWorkerRepository = MediaRepository & Readonly<{
  claimNext(workerId: string, leaseSeconds: number): Promise<ClaimedMediaResolution | null>;
  completeReady(input: CompleteReadyInput): Promise<boolean>;
  completeMiss(input: CompleteMissInput): Promise<boolean>;
  fail(input: FailMediaResolutionInput): Promise<boolean>;
}>;

export type ContentAddressedStorage = Readonly<{
  put(bytes: Uint8Array, mime: MediaMime): Promise<StoredMediaObject>;
  get(objectKey: string): Promise<StoredMediaObject | null>;
}>;

export type GmgnCredentials = Readonly<{
  apiKey: string;
  clientId: string;
}>;

export type CodexCredentials = Readonly<{
  apiKey: string;
}>;

export type MediaResolverDependencies = Readonly<{
  repository: MediaWorkerRepository;
  storage: ContentAddressedStorage;
  fetch: typeof fetch;
  sanitizeImage: ImageSanitizer;
  gmgn?: GmgnCredentials | null;
  codex?: CodexCredentials | null;
  providerTimeoutMs?: number;
  imageTimeoutMs?: number;
  nowMs?: () => number;
  random?: () => number;
  sleepMs?: (ms: number) => Promise<void>;
}>;

export type MediaHandlerDependencies = Readonly<{
  repository: MediaRepository;
  storage: ContentAddressedStorage;
  nowMs?: () => number;
}>;

export type ResolveMediaResult =
  | Readonly<{
      kind: 'ok';
      chainId: number;
      tokenAddress: string;
      source: MediaProviderName;
      objectKey: string;
      contentHashHex: string;
      mime: MediaMime;
      bytes: Uint8Array;
      cacheSeconds: number;
    }>
  | Readonly<{
      kind: 'not_found';
      chainId: number;
      tokenAddress: string;
      cacheSeconds: number;
    }>
  | Readonly<{
      kind: 'bad_request';
      status: 400 | 404 | 502;
      cacheSeconds: number;
    }>;

type DexToken = Readonly<{
  address?: unknown;
}>;

type DexPair = Readonly<{
  chainId?: unknown;
  baseToken?: DexToken;
  liquidity?: { usd?: unknown };
  info?: { imageUrl?: unknown };
}>;

type ProviderImage = Readonly<{
  source: MediaProviderName;
  url: URL;
}>;

type RetryContext = Readonly<{
  random: () => number;
  sleepMs: (ms: number) => Promise<void>;
}>;

type ProviderResolverDependencies = Readonly<{
  fetch: typeof fetch;
  sanitizeImage: ImageSanitizer;
  gmgn?: GmgnCredentials | null;
  codex?: CodexCredentials | null;
  providerTimeoutMs?: number;
  imageTimeoutMs?: number;
}>;

class RetryableUpstreamError extends Error {
  constructor(message = 'retryable_upstream') {
    super(message);
  }
}

class PermanentUpstreamError extends Error {
  constructor(message = 'permanent_upstream') {
    super(message);
  }
}

const defaultSleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));
export function normalizeEvmAddress(address: string) {
  return ADDRESS_RE.test(address) ? address.toLowerCase() : null;
}

export function contentHashHex(bytes: Uint8Array) {
  return createHash('sha256').update(bytes).digest('hex');
}

export function objectKeyFor(contentHash: string, mime: MediaMime) {
  const extension = mime === 'image/jpeg' ? 'jpg' : mime.slice('image/'.length);
  return `media/sha256/${contentHash}.${extension}`;
}

export function retryDelayMs(attemptIndex: number, entropy: number) {
  const boundedAttempt = Math.max(0, Math.min(attemptIndex, MAX_RETRY_ATTEMPTS - 1));
  const jitter = Math.max(0, Math.min(entropy, 1));
  return Math.round(250 * (2 ** boundedAttempt) * (0.75 + jitter * 0.5));
}

export function mediaQueueRetrySeconds(attemptCount: number, entropy: number) {
  const boundedAttempt = Math.max(0, Math.min(attemptCount - 1, 5));
  const jitter = 0.75 + Math.max(0, Math.min(entropy, 1)) * 0.5;
  return Math.round(60 * (2 ** boundedAttempt) * jitter);
}

export function detectSafeImageMime(bytes: Uint8Array): MediaMime | null {
  return detectSafeImageMetadata(bytes)?.mime ?? null;
}

export function detectSafeImageMetadata(bytes: Uint8Array): DecodedMedia | null {
  if (isJpeg(bytes)) return jpegDimensions(bytes, bytes);
  if (isPng(bytes)) {
    if (pngHasChunk(bytes, 'acTL')) return null;
    return pngDimensions(bytes, bytes);
  }
  if (isWebp(bytes)) {
    if (webpIsAnimated(bytes)) return null;
    return webpDimensions(bytes, bytes);
  }
  return null;
}

export async function resolveTokenMedia(chainId: number, address: string, dependencies: MediaHandlerDependencies): Promise<ResolveMediaResult> {
  const normalizedAddress = normalizeEvmAddress(address);
  if (chainId !== BSC_CHAIN_ID || !normalizedAddress) {
    return { kind: 'bad_request', status: chainId === BSC_CHAIN_ID ? 400 : 404, cacheSeconds: 0 };
  }

  const now = dependencies.nowMs?.() ?? Date.now();
  const tokenAddress = normalizedAddress;
  const cached = await readCached(chainId, tokenAddress, dependencies, now);
  if (cached?.kind === 'ok' && cached.cacheSeconds > 0) return cached;
  if (cached?.kind === 'not_found') return cached;

  await dependencies.repository.request(chainId, tokenAddress, now);
  if (cached) return cached;
  return { kind: 'not_found', chainId, tokenAddress, cacheSeconds: PENDING_CACHE_SECONDS };
}

async function readCached(
  chainId: number,
  tokenAddress: string,
  dependencies: MediaHandlerDependencies,
  nowMs: number,
): Promise<ResolveMediaResult | null> {
  const cached = await dependencies.repository.getCached(chainId, tokenAddress, nowMs);
  if (!cached) return null;
  return cachedRecordToResult(chainId, tokenAddress, cached, dependencies.storage, nowMs);
}

async function cachedRecordToResult(
  chainId: number,
  tokenAddress: string,
  cached: MediaCacheRecord,
  storage: ContentAddressedStorage,
  nowMs: number,
): Promise<ResolveMediaResult | null> {
  if (cached.status !== 'ready') {
    return { kind: 'not_found', chainId, tokenAddress, cacheSeconds: Math.max(0, Math.ceil((cached.expiresAtMs - nowMs) / 1_000)) };
  }

  if (!cached.objectKey || !cached.contentHashHex || !cached.mime || !cached.source) return null;
  const stored = await storage.get(cached.objectKey);
  if (!stored) return null;

  return {
    kind: 'ok',
    chainId,
    tokenAddress,
    source: cached.source,
    objectKey: stored.objectKey,
    contentHashHex: stored.contentHashHex,
    mime: stored.mime,
    bytes: stored.bytes,
    cacheSeconds: Math.max(0, Math.ceil((cached.expiresAtMs - nowMs) / 1_000)),
  };
}

export type MediaWorkerResult = 'idle' | 'completed' | 'retry_scheduled' | 'lost_lease';

export async function processNextMediaResolution(
  dependencies: MediaResolverDependencies,
  workerId: string,
  leaseSeconds: number,
): Promise<MediaWorkerResult> {
  const claim = await dependencies.repository.claimNext(workerId, leaseSeconds);
  if (!claim) return 'idle';
  return resolveClaimedTokenMedia(claim, dependencies, workerId);
}

export async function resolveClaimedTokenMedia(
  claim: ClaimedMediaResolution,
  dependencies: MediaResolverDependencies,
  workerId: string,
): Promise<MediaWorkerResult> {
  const retryContext: RetryContext = {
    random: dependencies.random ?? Math.random,
    sleepMs: dependencies.sleepMs ?? defaultSleep,
  };
  const resolved = await resolveFromProviders(claim.tokenAddress, dependencies, retryContext);

  if (resolved.kind === 'ok') {
    const stored = await dependencies.storage.put(resolved.bytes, resolved.mime);
    const completed = await dependencies.repository.completeReady({
      workerId,
      chainId: claim.chainId,
      tokenAddress: claim.tokenAddress,
      leaseGeneration: claim.leaseGeneration,
      source: resolved.source,
      providerRef: resolved.providerRef,
      providerPayloadHashHex: null,
      objectKey: stored.objectKey,
      contentHashHex: stored.contentHashHex,
      mime: stored.mime,
      byteSize: stored.bytes.byteLength,
      width: resolved.width,
      height: resolved.height,
      expiresAtMs: (dependencies.nowMs?.() ?? Date.now()) + POSITIVE_TTL_MS,
    });
    return completed ? 'completed' : 'lost_lease';
  }

  if (resolved.kind === 'upstream_error') {
    const retrySeconds = mediaQueueRetrySeconds(claim.attemptCount, retryContext.random());
    const failed = await dependencies.repository.fail({
      workerId,
      chainId: claim.chainId,
      tokenAddress: claim.tokenAddress,
      leaseGeneration: claim.leaseGeneration,
      errorCode: 'upstream_error',
      retrySeconds,
    });
    return failed ? 'retry_scheduled' : 'lost_lease';
  }

  const completed = await dependencies.repository.completeMiss({
    workerId,
    chainId: claim.chainId,
    tokenAddress: claim.tokenAddress,
    leaseGeneration: claim.leaseGeneration,
    status: resolved.kind === 'rejected' ? 'rejected' : 'negative',
    source: resolved.source,
    errorCode: resolved.kind,
    cacheSeconds: NEGATIVE_TTL_MS / 1_000,
  });
  return completed ? 'completed' : 'lost_lease';
}

async function resolveFromProviders(tokenAddress: string, dependencies: ProviderResolverDependencies, retryContext: RetryContext) {
  const providers = [
    () => findDexScreenerImage(tokenAddress, dependencies.fetch, dependencies.providerTimeoutMs, retryContext),
    ...(dependencies.gmgn ? [() => findGmgnImage(tokenAddress, dependencies.fetch, dependencies.gmgn!, dependencies.providerTimeoutMs, retryContext)] : []),
    ...(dependencies.codex ? [() => findCodexImage(tokenAddress, dependencies.fetch, dependencies.codex!, dependencies.providerTimeoutMs, retryContext)] : []),
  ];
  let sawTransientError = false;
  let rejectedSource: MediaProviderName | null = null;

  for (const provider of providers) {
    let image: ProviderImage | null = null;
    try {
      image = await provider();
    } catch (error) {
      if (isRetryable(error)) sawTransientError = true;
      continue;
    }
    if (!image) continue;

    try {
      const media = await fetchAndValidateImage(image.url, dependencies.fetch, dependencies.imageTimeoutMs, retryContext);
      const sanitized = await dependencies.sanitizeImage(media);
      return {
        kind: 'ok' as const,
        source: image.source,
        providerRef: image.url.toString(),
        bytes: sanitized.bytes,
        mime: sanitized.mime,
        width: sanitized.width,
        height: sanitized.height,
      };
    } catch (error) {
      rejectedSource = image.source;
      if (isRetryable(error)) sawTransientError = true;
    }
  }

  if (rejectedSource) return { kind: 'rejected' as const, source: rejectedSource };
  if (sawTransientError) return { kind: 'upstream_error' as const };
  return { kind: 'negative' as const, source: null };
}

async function findDexScreenerImage(
  tokenAddress: string,
  fetcher: typeof fetch,
  timeoutMs: number | undefined,
  retryContext: RetryContext,
): Promise<ProviderImage | null> {
  const payload = await withRetries(async () => {
    return fetchJsonWithTimeout(fetcher, `${DEXSCREENER_TOKEN_URL}${tokenAddress}`, boundedTimeoutMs(timeoutMs, PROVIDER_TIMEOUT_MS), {
      accept: 'application/json',
    }, MAX_JSON_BYTES);
  }, retryContext);
  const pairs = selectBscBasePairs(payload, tokenAddress);
  const url = pairs.map((pair) => parseAllowedProviderImageUrl('dexscreener', pair.info?.imageUrl)).find((value) => value);
  return url ? { source: 'dexscreener', url } : null;
}

async function findGmgnImage(
  tokenAddress: string,
  fetcher: typeof fetch,
  credentials: GmgnCredentials,
  timeoutMs: number | undefined,
  retryContext: RetryContext,
): Promise<ProviderImage | null> {
  const payload = await withRetries(async () => {
    const requestUrl = new URL('/v1/token/info', GMGN_OPENAPI_HOST);
    requestUrl.searchParams.set('chain', 'bsc');
    requestUrl.searchParams.set('address', tokenAddress);
    requestUrl.searchParams.set('timestamp', String(Math.floor(Date.now() / 1_000)));
    requestUrl.searchParams.set('client_id', credentials.clientId || randomUUID());
    return fetchJsonWithTimeout(fetcher, requestUrl.toString(), boundedTimeoutMs(timeoutMs, PROVIDER_TIMEOUT_MS), {
      accept: 'application/json',
      'content-type': 'application/json',
      'user-agent': 'quote-backend/0.1',
      'x-apikey': credentials.apiKey,
    }, MAX_JSON_BYTES);
  }, retryContext);

  const token = unwrapGmgnToken(payload);
  if (!token) return null;
  const returnedAddress = normalizeEvmAddress(asString(token.address) ?? asString(token.token_address) ?? '');
  if (returnedAddress !== tokenAddress) return null;
  const url = parseAllowedProviderImageUrl('gmgn', token.logo);
  return url ? { source: 'gmgn', url } : null;
}

async function findCodexImage(
  tokenAddress: string,
  fetcher: typeof fetch,
  credentials: CodexCredentials,
  timeoutMs: number | undefined,
  retryContext: RetryContext,
): Promise<ProviderImage | null> {
  const payload = await withRetries(async () => {
    return fetchJsonWithTimeout(fetcher, CODEX_GRAPHQL_URL, boundedTimeoutMs(timeoutMs, PROVIDER_TIMEOUT_MS), {
      accept: 'application/json',
      authorization: credentials.apiKey,
      'content-type': 'application/json',
      'user-agent': 'quote-backend/0.1',
    }, {
      method: 'POST',
      body: JSON.stringify({
        query: 'query QuoteTokenMedia($input: TokenInput!) { token(input: $input) { address networkId info { imageSmallUrl imageThumbUrl } } }',
        variables: { input: { address: tokenAddress, networkId: BSC_CHAIN_ID } },
      }),
    }, MAX_JSON_BYTES) as Promise<unknown>;
  }, retryContext);

  const root = payload && typeof payload === 'object' ? payload as Record<string, unknown> : {};
  const data = root.data && typeof root.data === 'object' ? root.data as Record<string, unknown> : {};
  const token = data.token && typeof data.token === 'object' ? data.token as Record<string, unknown> : {};
  const info = token.info && typeof token.info === 'object' ? token.info as Record<string, unknown> : {};
  if (normalizeEvmAddress(asString(token.address) ?? '') !== tokenAddress || token.networkId !== BSC_CHAIN_ID) return null;
  const url = parseAllowedProviderImageUrl('codex', info.imageSmallUrl ?? info.imageThumbUrl);
  return url ? { source: 'codex', url } : null;
}

async function fetchAndValidateImage(
  url: URL,
  fetcher: typeof fetch,
  timeoutMs: number | undefined,
  retryContext: RetryContext,
) {
  return withRetries(async () => {
    const bytes = await fetchBytesWithTimeout(fetcher, url.toString(), boundedTimeoutMs(timeoutMs, IMAGE_TIMEOUT_MS), {
      accept: 'image/webp,image/png,image/jpeg,*/*;q=0.1',
    }, MAX_IMAGE_BYTES);
    const metadata = detectSafeImageMetadata(bytes);
    if (!metadata) throw new PermanentUpstreamError('unsupported_media');
    return metadata;
  }, retryContext);
}

async function withRetries<T>(run: () => Promise<T>, retryContext: RetryContext): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < MAX_RETRY_ATTEMPTS; attempt += 1) {
    try {
      return await run();
    } catch (error) {
      lastError = error;
      if (!isRetryable(error) || attempt === MAX_RETRY_ATTEMPTS - 1) break;
      await retryContext.sleepMs(retryDelayMs(attempt, retryContext.random()));
    }
  }
  throw lastError;
}

async function fetchJsonWithTimeout(
  fetcher: typeof fetch,
  url: string,
  timeoutMs: number,
  headers: HeadersInit,
  byteLimit: number,
): Promise<unknown>;
async function fetchJsonWithTimeout(
  fetcher: typeof fetch,
  url: string,
  timeoutMs: number,
  headers: HeadersInit,
  init: Pick<RequestInit, 'method' | 'body'>,
  byteLimit: number,
): Promise<unknown>;
async function fetchJsonWithTimeout(
  fetcher: typeof fetch,
  url: string,
  timeoutMs: number,
  headers: HeadersInit,
  initOrByteLimit: Pick<RequestInit, 'method' | 'body'> | number,
  maybeByteLimit?: number,
) {
  const init = typeof initOrByteLimit === 'number' ? {} : initOrByteLimit;
  const byteLimit = typeof initOrByteLimit === 'number' ? initOrByteLimit : maybeByteLimit;
  if (!byteLimit) throw new Error('json_byte_limit_required');
  const text = await fetchWithTimeout(fetcher, url, timeoutMs, headers, init, (response, signal) => readLimitedText(response, byteLimit, signal));
  return JSON.parse(text) as unknown;
}

async function fetchBytesWithTimeout(
  fetcher: typeof fetch,
  url: string,
  timeoutMs: number,
  headers: HeadersInit,
  byteLimit: number,
) {
  return fetchWithTimeout(fetcher, url, timeoutMs, headers, {}, (response, signal) => readLimitedBytes(response, byteLimit, signal));
}

async function fetchWithTimeout<T>(
  fetcher: typeof fetch,
  url: string,
  timeoutMs: number,
  headers: HeadersInit,
  init: Pick<RequestInit, 'method' | 'body'> = {},
  consume: (response: Response, signal: AbortSignal) => Promise<T>,
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetcher(url, {
      headers,
      ...init,
      redirect: 'error',
      signal: controller.signal,
    });
    if (response.status === 429 || response.status >= 500) {
      throw new RetryableUpstreamError('temporary_upstream');
    }
    if (!response.ok) {
      throw new PermanentUpstreamError('bad_upstream_status');
    }
    return await consume(response, controller.signal);
  } catch (error) {
    if (controller.signal.aborted || isAbortError(error)) throw new RetryableUpstreamError('upstream_timeout');
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

async function readLimitedBytes(response: Response, byteLimit: number, signal?: AbortSignal) {
  const contentLength = Number(response.headers.get('content-length') || 0);
  if (contentLength > byteLimit) throw new PermanentUpstreamError('upstream_too_large');

  const reader = response.body?.getReader();
  if (!reader) {
    if (signal?.aborted) throw new RetryableUpstreamError('upstream_timeout');
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (signal?.aborted) throw new RetryableUpstreamError('upstream_timeout');
    if (bytes.byteLength > byteLimit) throw new PermanentUpstreamError('upstream_too_large');
    return bytes;
  }

  const chunks: Uint8Array[] = [];
  let received = 0;
  const abortReader = () => {
    void reader.cancel().catch(() => undefined);
  };
  signal?.addEventListener('abort', abortReader, { once: true });

  try {
    while (true) {
      if (signal?.aborted) {
        await reader.cancel().catch(() => undefined);
        throw new RetryableUpstreamError('upstream_timeout');
      }
      const { done, value } = await reader.read();
      if (signal?.aborted) throw new RetryableUpstreamError('upstream_timeout');
      if (done) break;
      if (!value) continue;

      received += value.byteLength;
      if (received > byteLimit) {
        await reader.cancel();
        throw new PermanentUpstreamError('upstream_too_large');
      }
      chunks.push(value);
    }
  } finally {
    signal?.removeEventListener('abort', abortReader);
  }

  const body = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return body;
}

async function readLimitedText(response: Response, byteLimit: number, signal?: AbortSignal) {
  return new TextDecoder().decode(await readLimitedBytes(response, byteLimit, signal));
}

function selectBscBasePairs(payload: unknown, tokenAddress: string) {
  const pairs = Array.isArray(payload) ? payload.filter(isDexPair) : [];
  return pairs
    .filter((pair) => asString(pair.chainId)?.toLowerCase() === 'bsc')
    .filter((pair) => tokenAddressOf(pair.baseToken) === tokenAddress)
    .sort((left, right) => liquidityUsd(right) - liquidityUsd(left));
}

function parseAllowedProviderImageUrl(source: MediaProviderName, value: unknown) {
  const raw = asString(value);
  if (!raw) return null;

  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:') return null;

    if (source === 'dexscreener') {
      if (url.hostname !== 'cdn.dexscreener.com' || !url.pathname.startsWith('/cms/images/')) return null;
      url.searchParams.set('width', '256');
      url.searchParams.set('height', '256');
      url.searchParams.set('quality', '88');
      return url;
    }

    if (source === 'gmgn') {
      if (url.hostname !== 'gmgn.ai' || !url.pathname.startsWith('/external-res/')) return null;
      return url;
    }

    if (url.hostname !== 'token-media.defined.fi') return null;
    return url;
  } catch {
    return null;
  }
}

function boundedTimeoutMs(value: number | undefined, fallback: number) {
  return Number.isSafeInteger(value) && value! >= 1 && value! <= 30_000 ? value! : fallback;
}

function unwrapGmgnToken(payload: unknown) {
  if (!payload || typeof payload !== 'object') return null;
  const root = payload as Record<string, unknown>;
  const data = root.data && typeof root.data === 'object' ? root.data as Record<string, unknown> : root;
  if (Array.isArray(data)) return null;
  if (data.info && typeof data.info === 'object') return data.info as Record<string, unknown>;
  return data;
}

function isDexPair(value: unknown): value is DexPair {
  return Boolean(value && typeof value === 'object');
}

function tokenAddressOf(token: DexToken | undefined) {
  const address = asString(token?.address);
  return address && ADDRESS_RE.test(address) ? address.toLowerCase() : null;
}

function liquidityUsd(pair: DexPair) {
  const value = pair.liquidity?.usd;
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

function asString(value: unknown) {
  return typeof value === 'string' ? value : null;
}

function isRetryable(error: unknown) {
  return error instanceof RetryableUpstreamError;
}

function isAbortError(error: unknown) {
  return Boolean(error && typeof error === 'object' && 'name' in error && error.name === 'AbortError');
}

function isJpeg(bytes: Uint8Array) {
  return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

function isPng(bytes: Uint8Array) {
  return (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  );
}

function isWebp(bytes: Uint8Array) {
  return bytes.length >= 12 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP';
}

function pngHasChunk(bytes: Uint8Array, chunkType: string) {
  let offset = 8;
  while (offset + 8 <= bytes.length) {
    const length = readUint32be(bytes, offset);
    const type = ascii(bytes, offset + 4, offset + 8);
    if (type === chunkType) return true;
    if (length < 0 || offset + 12 + length > bytes.length) return false;
    offset += 12 + length;
  }
  return false;
}

function pngDimensions(bytes: Uint8Array, originalBytes: Uint8Array) {
  if (bytes.length < 33 || ascii(bytes, 12, 16) !== 'IHDR') return null;
  const width = readUint32be(bytes, 16);
  const height = readUint32be(bytes, 20);
  return validDimensions(width, height) ? { bytes: originalBytes, mime: 'image/png' as const, width, height } : null;
}

function jpegDimensions(bytes: Uint8Array, originalBytes: Uint8Array) {
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) return null;
    const marker = bytes[offset + 1];
    offset += 2;
    if (marker === 0xd8 || marker === 0xd9) continue;
    if (marker >= 0xd0 && marker <= 0xd7) continue;

    const length = readUint16be(bytes, offset);
    if (length < 2 || offset + length > bytes.length) return null;
    if (isSofJpegMarker(marker)) {
      const height = readUint16be(bytes, offset + 3);
      const width = readUint16be(bytes, offset + 5);
      return validDimensions(width, height) ? { bytes: originalBytes, mime: 'image/jpeg' as const, width, height } : null;
    }
    offset += length;
  }
  return null;
}

function webpIsAnimated(bytes: Uint8Array) {
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const type = ascii(bytes, offset, offset + 4);
    const length = readUint32le(bytes, offset + 4);
    if (type === 'ANIM' || type === 'ANMF') return true;
    if (type === 'VP8X' && offset + 9 < bytes.length && (bytes[offset + 8] & 0x02) === 0x02) return true;
    offset += 8 + length + (length % 2);
  }
  return false;
}

function webpDimensions(bytes: Uint8Array, originalBytes: Uint8Array) {
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const type = ascii(bytes, offset, offset + 4);
    const length = readUint32le(bytes, offset + 4);
    const dataOffset = offset + 8;
    if (length < 0 || dataOffset + length > bytes.length) return null;

    if (type === 'VP8X' && length >= 10) {
      const width = readUint24le(bytes, dataOffset + 4) + 1;
      const height = readUint24le(bytes, dataOffset + 7) + 1;
      return validDimensions(width, height) ? { bytes: originalBytes, mime: 'image/webp' as const, width, height } : null;
    }

    if (type === 'VP8 ' && length >= 10 && bytes[dataOffset + 3] === 0x9d && bytes[dataOffset + 4] === 0x01 && bytes[dataOffset + 5] === 0x2a) {
      const width = readUint16le(bytes, dataOffset + 6) & 0x3fff;
      const height = readUint16le(bytes, dataOffset + 8) & 0x3fff;
      return validDimensions(width, height) ? { bytes: originalBytes, mime: 'image/webp' as const, width, height } : null;
    }

    if (type === 'VP8L' && length >= 5 && bytes[dataOffset] === 0x2f) {
      const width = 1 + (((bytes[dataOffset + 2] & 0x3f) << 8) | bytes[dataOffset + 1]);
      const height = 1 + (((bytes[dataOffset + 4] & 0x0f) << 10) | (bytes[dataOffset + 3] << 2) | ((bytes[dataOffset + 2] & 0xc0) >> 6));
      return validDimensions(width, height) ? { bytes: originalBytes, mime: 'image/webp' as const, width, height } : null;
    }

    offset += 8 + length + (length % 2);
  }
  return null;
}

function isSofJpegMarker(marker: number) {
  return (
    (marker >= 0xc0 && marker <= 0xc3) ||
    (marker >= 0xc5 && marker <= 0xc7) ||
    (marker >= 0xc9 && marker <= 0xcb) ||
    (marker >= 0xcd && marker <= 0xcf)
  );
}

function validDimensions(width: number, height: number) {
  return Number.isInteger(width) && Number.isInteger(height) && width >= 1 && height >= 1 && width <= 4096 && height <= 4096;
}

function ascii(bytes: Uint8Array, start: number, end: number) {
  let output = '';
  for (let index = start; index < end && index < bytes.length; index += 1) {
    output += String.fromCharCode(bytes[index]);
  }
  return output;
}

function readUint16be(bytes: Uint8Array, offset: number) {
  if (offset + 2 > bytes.length) return -1;
  return (bytes[offset] << 8) | bytes[offset + 1];
}

function readUint16le(bytes: Uint8Array, offset: number) {
  if (offset + 2 > bytes.length) return -1;
  return bytes[offset] | (bytes[offset + 1] << 8);
}

function readUint24le(bytes: Uint8Array, offset: number) {
  if (offset + 3 > bytes.length) return -1;
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

function readUint32be(bytes: Uint8Array, offset: number) {
  if (offset + 4 > bytes.length) return -1;
  return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]) >>> 0;
}

function readUint32le(bytes: Uint8Array, offset: number) {
  if (offset + 4 > bytes.length) return -1;
  return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24)) >>> 0;
}
