const DEXSCREENER_TOKEN_URL = 'https://api.dexscreener.com/latest/dex/tokens/';
const ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
const MAX_DEX_BODY_BYTES = 512_000;
const MAX_IMAGE_BYTES = 1_500_000;
const DEX_TIMEOUT_MS = 4_500;
const IMAGE_TIMEOUT_MS = 4_500;

type DexToken = {
  address?: unknown;
};

type DexPair = {
  chainId?: unknown;
  baseToken?: DexToken;
  quoteToken?: DexToken;
  liquidity?: { usd?: unknown };
  info?: { imageUrl?: unknown };
};

type RouteContext = {
  params: Promise<{ address: string }>;
};

function isDexPair(value: unknown): value is DexPair {
  return Boolean(value && typeof value === 'object');
}

function asToken(value: unknown): DexToken {
  return value && typeof value === 'object' ? (value as DexToken) : {};
}

function asString(value: unknown) {
  return typeof value === 'string' ? value : null;
}

function asNumber(value: unknown) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function tokenAddress(token: DexToken) {
  const address = asString(token.address);
  return address && ADDRESS_RE.test(address) ? address.toLowerCase() : null;
}

function liquidityUsd(pair: DexPair) {
  return asNumber(pair.liquidity?.usd) || 0;
}

function parseSafeDexImageUrl(value: unknown) {
  const raw = asString(value);
  if (!raw) return null;

  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || url.hostname !== 'cdn.dexscreener.com') return null;
    url.searchParams.set('width', '256');
    url.searchParams.set('height', '256');
    url.searchParams.set('quality', '88');
    url.searchParams.set('format', 'webp');
    return url;
  } catch {
    return null;
  }
}

async function readLimitedBytes(response: Response, byteLimit: number) {
  const contentLength = Number(response.headers.get('content-length') || 0);
  if (contentLength > byteLimit) {
    throw new Error('upstream_too_large');
  }

  const reader = response.body?.getReader();
  if (!reader) {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.byteLength > byteLimit) {
      throw new Error('upstream_too_large');
    }
    return bytes;
  }

  const chunks: Uint8Array[] = [];
  let received = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;

    received += value.byteLength;
    if (received > byteLimit) {
      await reader.cancel();
      throw new Error('upstream_too_large');
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

async function readLimitedText(response: Response, byteLimit: number) {
  return new TextDecoder().decode(await readLimitedBytes(response, byteLimit));
}

async function fetchWithTimeout(url: string, timeoutMs: number, headers: HeadersInit) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const response = await fetch(url, {
      headers,
      redirect: 'error',
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(`upstream_${response.status}`);
    }

    return response;
  } finally {
    clearTimeout(timeout);
  }
}

async function fetchDexScreener(address: string) {
  const response = await fetchWithTimeout(`${DEXSCREENER_TOKEN_URL}${address}`, DEX_TIMEOUT_MS, { accept: 'application/json' });
  return JSON.parse(await readLimitedText(response, MAX_DEX_BODY_BYTES)) as { pairs?: unknown };
}

function selectBscPairs(payload: { pairs?: unknown }, address: string) {
  const normalizedAddress = address.toLowerCase();
  const pairs = Array.isArray(payload.pairs) ? payload.pairs.filter(isDexPair) : [];

  return pairs
    .filter((pair) => {
      if (asString(pair.chainId)?.toLowerCase() !== 'bsc') return false;

      const baseAddress = tokenAddress(asToken(pair.baseToken));
      return baseAddress === normalizedAddress;
    })
    .sort((left, right) => liquidityUsd(right) - liquidityUsd(left));
}

function ascii(bytes: Uint8Array, start: number, end: number) {
  return String.fromCharCode(...bytes.slice(start, end));
}

function detectImageType(bytes: Uint8Array) {
  if (bytes.length >= 12 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'image/jpeg';
  }

  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return 'image/png';
  }

  if (bytes.length >= 12 && ascii(bytes, 0, 4) === 'RIFF' && ascii(bytes, 8, 12) === 'WEBP') {
    return 'image/webp';
  }

  return null;
}

function reject(status: number) {
  return new Response(null, {
    status,
    headers: {
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      'cross-origin-resource-policy': 'same-origin',
    },
  });
}

export async function GET(_request: Request, { params }: RouteContext) {
  const { address } = await params;

  if (!ADDRESS_RE.test(address)) {
    return reject(400);
  }

  try {
    const payload = await fetchDexScreener(address.toLowerCase());
    const pairs = selectBscPairs(payload, address);
    const imageUrl = pairs.map((pair) => parseSafeDexImageUrl(pair.info?.imageUrl)).find((url) => url);

    if (!imageUrl) {
      return reject(404);
    }

    const imageResponse = await fetchWithTimeout(imageUrl.toString(), IMAGE_TIMEOUT_MS, {
      accept: 'image/avif,image/webp,image/png,image/jpeg,image/gif;q=0.8,*/*;q=0.1',
    });
    const bytes = await readLimitedBytes(imageResponse, MAX_IMAGE_BYTES);
    const contentType = detectImageType(bytes);

    if (!contentType) {
      return reject(415);
    }

    return new Response(bytes, {
      status: 200,
      headers: {
        'cache-control': 'public, max-age=300, s-maxage=900, stale-while-revalidate=86400',
        'content-type': contentType,
        'content-length': String(bytes.byteLength),
        'x-content-type-options': 'nosniff',
        'cross-origin-resource-policy': 'same-origin',
      },
    });
  } catch {
    return reject(502);
  }
}
