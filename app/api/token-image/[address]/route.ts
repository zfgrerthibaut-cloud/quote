const DEXSCREENER_TOKEN_URL = 'https://api.dexscreener.com/tokens/v1/bsc/';
const GMGN_TOKEN_URL = 'https://openapi.gmgn.ai/v1/token/info';
const ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
const MAX_JSON_BYTES = 512_000;
const MAX_IMAGE_BYTES = 1_500_000;
const MAX_DIMENSION = 4_096;
const MAX_PIXELS = 16_777_216;
const REQUEST_TIMEOUT_MS = 2_500;
const POSITIVE_TTL_MS = 24 * 60 * 60 * 1_000;
const NEGATIVE_TTL_MS = 5 * 60 * 1_000;

type DexToken = { address?: unknown };
type DexPair = {
  chainId?: unknown;
  baseToken?: DexToken;
  liquidity?: { usd?: unknown };
  info?: { imageUrl?: unknown };
};
type RouteContext = { params: Promise<{ address: string }> };
type ImageSource = 'dexscreener' | 'gmgn';
type ResolvedImage = { bytes: Uint8Array; contentType: string; source: ImageSource };
type MemoryEntry = { expiresAt: number; image: ResolvedImage | null };
type EdgeCacheStorage = CacheStorage & { default?: Cache };

const memoryCache = new Map<string, MemoryEntry>();
const inFlight = new Map<string, Promise<ResolvedImage | null>>();

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function asString(value: unknown) {
  return typeof value === 'string' ? value : null;
}

function asNumber(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function tokenAddress(value: unknown) {
  const address = asString(asRecord(value).address);
  return address && ADDRESS_RE.test(address) ? address.toLowerCase() : null;
}

function isDexPair(value: unknown): value is DexPair {
  return Boolean(value && typeof value === 'object');
}

function liquidityUsd(pair: DexPair) {
  return asNumber(pair.liquidity?.usd) || 0;
}

function edgeCache() {
  return (globalThis as typeof globalThis & { caches?: EdgeCacheStorage }).caches?.default;
}

function canonicalCacheRequest(request: Request, address: string) {
  const url = new URL(request.url);
  url.pathname = `/api/token-image/${address}`;
  url.search = '';
  return new Request(url.toString(), { method: 'GET' });
}

function safeImageUrl(value: unknown, source: ImageSource) {
  const raw = asString(value);
  if (!raw) return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || url.hash) return null;
    if (source === 'dexscreener') {
      if (url.hostname !== 'cdn.dexscreener.com' || !url.pathname.startsWith('/cms/images/')) return null;
      url.searchParams.set('width', '256');
      url.searchParams.set('height', '256');
      url.searchParams.set('quality', '88');
      url.searchParams.set('format', 'webp');
      return url;
    }
    if (url.hostname !== 'gmgn.ai' || !url.pathname.startsWith('/external-res/')) return null;
    return url;
  } catch {
    return null;
  }
}

async function readLimitedBytes(response: Response, limit: number) {
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > limit) throw new Error('too_large');
  const reader = response.body?.getReader();
  if (!reader) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength > limit) throw new Error('too_large');
    return bytes;
  }
  const chunks: Uint8Array[] = [];
  let received = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    received += value.byteLength;
    if (received > limit) {
      await reader.cancel();
      throw new Error('too_large');
    }
    chunks.push(value);
  }
  const body = new Uint8Array(received);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function delay(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}

async function fetchRetry(url: string, headers: HeadersInit, byteLimit: number) {
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const response = await fetch(url, { headers, redirect: 'error', signal: controller.signal });
      if (!response.ok) {
        if (response.status !== 429 && response.status < 500) throw new Error('upstream_rejected');
        throw new Error('upstream_retryable');
      }
      return await readLimitedBytes(response, byteLimit);
    } catch (error) {
      lastError = error;
      if (error instanceof Error && error.message === 'upstream_rejected') throw error;
      if (attempt < 2) await delay(140 * (2 ** attempt) + Math.floor(Math.random() * 70));
    } finally {
      clearTimeout(timeout);
    }
  }
  throw lastError instanceof Error ? lastError : new Error('upstream_unavailable');
}

async function fetchJson(url: string, headers: HeadersInit) {
  const bytes = await fetchRetry(url, headers, MAX_JSON_BYTES);
  return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
}

async function resolveDexScreener(address: string) {
  const payload = await fetchJson(`${DEXSCREENER_TOKEN_URL}${address}`, { accept: 'application/json' });
  const pairs = Array.isArray(payload) ? payload.filter(isDexPair) : [];
  return pairs
    .filter((pair) => asString(pair.chainId)?.toLowerCase() === 'bsc' && tokenAddress(pair.baseToken) === address)
    .sort((left, right) => liquidityUsd(right) - liquidityUsd(left))
    .map((pair) => safeImageUrl(pair.info?.imageUrl, 'dexscreener'))
    .find((url) => url) || null;
}

async function resolveGmgn(address: string) {
  const apiKey = process.env.GMGN_API_KEY;
  const clientId = process.env.GMGN_CLIENT_ID;
  if (!apiKey || !clientId) return null;
  const url = new URL(GMGN_TOKEN_URL);
  url.searchParams.set('chain', 'bsc');
  url.searchParams.set('address', address);
  url.searchParams.set('timestamp', String(Math.floor(Date.now() / 1_000)));
  url.searchParams.set('client_id', clientId);
  const payload = asRecord(await fetchJson(url.toString(), { accept: 'application/json', 'x-apikey': apiKey }));
  const data = asRecord(payload.data);
  if (tokenAddress(data) !== address) return null;
  return safeImageUrl(data.logo, 'gmgn');
}

function ascii(bytes: Uint8Array, start: number, end: number) {
  return String.fromCharCode(...bytes.slice(start, end));
}

function containsAscii(bytes: Uint8Array, value: string) {
  for (let index = 0; index <= bytes.length - value.length; index += 1) {
    if (ascii(bytes, index, index + value.length) === value) return true;
  }
  return false;
}

function u24le(bytes: Uint8Array, offset: number) {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

function dimensions(bytes: Uint8Array, type: string): [number, number] | null {
  if (type === 'image/png' && bytes.length >= 24) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return [view.getUint32(16), view.getUint32(20)];
  }
  if (type === 'image/webp' && bytes.length >= 30) {
    const chunk = ascii(bytes, 12, 16);
    if (chunk === 'VP8X') return [u24le(bytes, 24) + 1, u24le(bytes, 27) + 1];
    if (chunk === 'VP8 ' && bytes[23] === 0x9d && bytes[24] === 0x01 && bytes[25] === 0x2a) {
      return [(bytes[26] | (bytes[27] << 8)) & 0x3fff, (bytes[28] | (bytes[29] << 8)) & 0x3fff];
    }
    if (chunk === 'VP8L' && bytes[20] === 0x2f) {
      return [1 + bytes[21] + ((bytes[22] & 0x3f) << 8), 1 + (bytes[22] >> 6) + (bytes[23] << 2) + ((bytes[24] & 0x0f) << 10)];
    }
  }
  if (type === 'image/jpeg') {
    let offset = 2;
    while (offset + 8 < bytes.length) {
      if (bytes[offset] !== 0xff) { offset += 1; continue; }
      const marker = bytes[offset + 1];
      const length = (bytes[offset + 2] << 8) | bytes[offset + 3];
      if (length < 2 || offset + length + 2 > bytes.length) return null;
      if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
        return [(bytes[offset + 7] << 8) | bytes[offset + 8], (bytes[offset + 5] << 8) | bytes[offset + 6]];
      }
      offset += length + 2;
    }
  }
  return null;
}

function validateRaster(bytes: Uint8Array) {
  let type: string | null = null;
  if (bytes.length >= 12 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff && bytes.at(-2) === 0xff && bytes.at(-1) === 0xd9) {
    type = 'image/jpeg';
  } else if (bytes.length >= 32 && bytes[0] === 0x89 && ascii(bytes, 1, 4) === 'PNG' && ascii(bytes, bytes.length - 8, bytes.length - 4) === 'IEND' && !containsAscii(bytes, 'acTL')) {
    type = 'image/png';
  } else if (bytes.length >= 30 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP' && !containsAscii(bytes, 'ANIM') && !containsAscii(bytes, 'ANMF')) {
    const declared = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(4, true) + 8;
    if (declared === bytes.byteLength) type = 'image/webp';
  }
  if (!type) return null;
  const size = dimensions(bytes, type);
  if (!size || size[0] < 1 || size[1] < 1 || size[0] > MAX_DIMENSION || size[1] > MAX_DIMENSION || size[0] * size[1] > MAX_PIXELS) return null;
  return type;
}

async function resolveAndFetch(address: string): Promise<ResolvedImage | null> {
  const candidates: Array<{ source: ImageSource; url: URL | null }> = [];
  try { candidates.push({ source: 'dexscreener', url: await resolveDexScreener(address) }); } catch { /* fallback below */ }
  if (!candidates[0]?.url) {
    try { candidates.push({ source: 'gmgn', url: await resolveGmgn(address) }); } catch { /* negative cache below */ }
  }
  for (const candidate of candidates) {
    if (!candidate.url) continue;
    try {
      const bytes = await fetchRetry(candidate.url.toString(), { accept: 'image/webp,image/png,image/jpeg' }, MAX_IMAGE_BYTES);
      const contentType = validateRaster(bytes);
      if (contentType) return { bytes, contentType, source: candidate.source };
    } catch { /* try the next approved source */ }
  }
  return null;
}

async function sharedResolve(address: string) {
  const cached = memoryCache.get(address);
  if (cached && cached.expiresAt > Date.now()) return cached.image;
  const existing = inFlight.get(address);
  if (existing) return existing;
  const promise = resolveAndFetch(address)
    .then((image) => {
      memoryCache.set(address, { expiresAt: Date.now() + (image ? POSITIVE_TTL_MS : NEGATIVE_TTL_MS), image });
      return image;
    })
    .finally(() => inFlight.delete(address));
  inFlight.set(address, promise);
  return promise;
}

function imageResponse(image: ResolvedImage) {
  return new Response(image.bytes, {
    status: 200,
    headers: {
      'cache-control': 'public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800',
      'content-type': image.contentType,
      'content-length': String(image.bytes.byteLength),
      'x-content-type-options': 'nosniff',
      'cross-origin-resource-policy': 'same-origin',
      'x-quote-image-source': image.source,
    },
  });
}

function reject(status: number, cacheable = false) {
  return new Response(null, {
    status,
    headers: {
      'cache-control': cacheable ? 'public, max-age=60, s-maxage=300' : 'no-store',
      'x-content-type-options': 'nosniff',
      'cross-origin-resource-policy': 'same-origin',
    },
  });
}

export async function GET(request: Request, { params }: RouteContext) {
  const { address } = await params;
  if (!ADDRESS_RE.test(address)) return reject(400);
  const normalized = address.toLowerCase();
  const cache = edgeCache();
  const cacheKey = canonicalCacheRequest(request, normalized);
  let cached: Response | undefined;
  try { cached = await cache?.match(cacheKey); } catch { /* some runtimes expose Cache API without request context */ }
  if (cached) return cached;
  const image = await sharedResolve(normalized);
  const response = image ? imageResponse(image) : reject(404, true);
  if (cache) {
    try { await cache.put(cacheKey, response.clone()); } catch { /* cache loss is non-fatal */ }
  }
  return response;
}
