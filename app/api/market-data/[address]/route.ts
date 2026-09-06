const DEXSCREENER_TOKEN_URL = 'https://api.dexscreener.com/latest/dex/tokens/';
const ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
const MAX_DEX_BODY_BYTES = 512_000;
const DEX_TIMEOUT_MS = 4_500;
const MIN_QUOTE_LIQUIDITY_USD = 10_000;

const CORE_LIQUIDITY_TOKENS = new Set([
  '0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c', // WBNB
  '0x55d398326f99059ff775485246999027b3197955', // USDT
  '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d', // USDC
  '0xe9e7cea3dedca5984780bafc599bd69add087d56', // BUSD
  '0xc5f0f7b66764f6ec8c8dff7ba683102295e16409', // FDUSD
]);

type DexToken = {
  address?: unknown;
  name?: unknown;
  symbol?: unknown;
};

type DexPair = {
  chainId?: unknown;
  dexId?: unknown;
  url?: unknown;
  pairAddress?: unknown;
  baseToken?: DexToken;
  quoteToken?: DexToken;
  priceUsd?: unknown;
  marketCap?: unknown;
  fdv?: unknown;
  liquidity?: { usd?: unknown };
  volume?: { h24?: unknown };
  priceChange?: { h24?: unknown };
  info?: { imageUrl?: unknown };
};

type RouteContext = {
  params: Promise<{ address: string }>;
};

function json(data: unknown, init?: ResponseInit) {
  return Response.json(data, {
    ...init,
    headers: {
      'cache-control': init?.status && init.status >= 400 ? 'no-store' : 'public, max-age=20, s-maxage=60, stale-while-revalidate=300',
      'content-type': 'application/json',
      'x-content-type-options': 'nosniff',
      'cross-origin-resource-policy': 'same-origin',
      ...init?.headers,
    },
  });
}

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

function tokenSymbol(token: DexToken) {
  return asString(token.symbol) || 'UNKNOWN';
}

function tokenName(token: DexToken) {
  return asString(token.name) || tokenSymbol(token);
}

function liquidityUsd(pair: DexPair) {
  return asNumber(pair.liquidity?.usd) || 0;
}

function isSafeDexImageUrl(value: unknown) {
  const raw = asString(value);
  if (!raw) return false;

  try {
    const url = new URL(raw);
    return url.protocol === 'https:' && url.hostname === 'cdn.dexscreener.com';
  } catch {
    return false;
  }
}

async function readLimitedText(response: Response, byteLimit: number) {
  const reader = response.body?.getReader();
  if (!reader) {
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > byteLimit) {
      throw new Error('upstream_too_large');
    }
    return text;
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

  return new TextDecoder().decode(body);
}

async function fetchDexScreener(address: string) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), DEX_TIMEOUT_MS);

  try {
    const response = await fetch(`${DEXSCREENER_TOKEN_URL}${address}`, {
      headers: { accept: 'application/json' },
      redirect: 'error',
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(`dexscreener_${response.status}`);
    }

    return JSON.parse(await readLimitedText(response, MAX_DEX_BODY_BYTES)) as { pairs?: unknown };
  } finally {
    clearTimeout(timeout);
  }
}

function selectBscPairs(payload: { pairs?: unknown }, address: string) {
  const normalizedAddress = address.toLowerCase();
  const pairs = Array.isArray(payload.pairs) ? payload.pairs.filter(isDexPair) : [];

  return pairs
    .filter((pair) => {
      if (asString(pair.chainId)?.toLowerCase() !== 'bsc') return false;

      // DexScreener's price, market-cap and image fields describe baseToken.
      // Exact base-side matching prevents an unrelated token from inheriting
      // the requested quote token's identity or metrics.
      const baseAddress = tokenAddress(asToken(pair.baseToken));
      return baseAddress === normalizedAddress;
    })
    .sort((left, right) => liquidityUsd(right) - liquidityUsd(left));
}

function pairedTokenFor(pair: DexPair, token: string) {
  const baseToken = asToken(pair.baseToken);
  const quoteToken = asToken(pair.quoteToken);
  return tokenAddress(baseToken) === token ? quoteToken : baseToken;
}

export async function GET(_request: Request, { params }: RouteContext) {
  const { address } = await params;

  if (!ADDRESS_RE.test(address)) {
    return json({ error: 'invalid_address' }, { status: 400 });
  }

  try {
    const normalizedAddress = address.toLowerCase();
    const payload = await fetchDexScreener(normalizedAddress);
    const pairs = selectBscPairs(payload, normalizedAddress);
    const pair = pairs[0];

    if (!pair) {
      return json({
        source: 'dexscreener',
        chainId: 'bsc',
        address: normalizedAddress,
        found: false,
        minQuoteLiquidityUsd: MIN_QUOTE_LIQUIDITY_USD,
        fetchedAt: new Date().toISOString(),
      });
    }

    const baseToken = asToken(pair.baseToken);
    const quoteToken = asToken(pair.quoteToken);
    const baseAddress = tokenAddress(baseToken);
    const token = baseAddress === normalizedAddress ? baseToken : quoteToken;
    const pairedToken = baseAddress === normalizedAddress ? quoteToken : baseToken;
    const pairedAddress = tokenAddress(pairedToken);
    const liquidity = liquidityUsd(pair);
    const corePair = pairs.find((candidate) => {
      const coreAddress = tokenAddress(pairedTokenFor(candidate, normalizedAddress));
      return coreAddress ? CORE_LIQUIDITY_TOKENS.has(coreAddress) : false;
    });
    const corePairedAddress = corePair ? tokenAddress(pairedTokenFor(corePair, normalizedAddress)) : pairedAddress;
    const coreLiquidity = corePair ? liquidityUsd(corePair) : 0;
    const isCoreLiquidityPair = Boolean(corePair);
    const imageAvailable = pairs.some((candidate) => (
      tokenAddress(asToken(candidate.baseToken)) === normalizedAddress && isSafeDexImageUrl(candidate.info?.imageUrl)
    ));

    return json({
      source: 'dexscreener',
      chainId: 'bsc',
      address: normalizedAddress,
      found: true,
      fetchedAt: new Date().toISOString(),
      minQuoteLiquidityUsd: MIN_QUOTE_LIQUIDITY_USD,
      quoteEligibility: {
        eligible: coreLiquidity >= MIN_QUOTE_LIQUIDITY_USD && isCoreLiquidityPair,
        liquidityUsd: coreLiquidity,
        bestPairLiquidityUsd: liquidity,
        isCoreLiquidityPair,
        pairedWith: corePairedAddress,
      },
      token: {
        address: normalizedAddress,
        symbol: tokenSymbol(token),
        name: tokenName(token),
        imagePath: imageAvailable ? `/api/token-image/${normalizedAddress}` : null,
      },
      pair: {
        address: asString(pair.pairAddress),
        dexId: asString(pair.dexId),
        url: asString(pair.url),
        baseSymbol: tokenSymbol(baseToken),
        quoteSymbol: tokenSymbol(quoteToken),
        pairedSymbol: tokenSymbol(pairedToken),
        priceUsd: asString(pair.priceUsd),
        marketCapUsd: asNumber(pair.marketCap),
        fdvUsd: asNumber(pair.fdv),
        liquidityUsd: liquidity,
        volume24hUsd: asNumber(pair.volume?.h24),
        priceChange24h: asNumber(pair.priceChange?.h24),
      },
    });
  } catch {
    return json({ error: 'dexscreener_unavailable' }, { status: 502 });
  }
}
