const PUBLIC_BSC_RPC = 'https://bsc-dataseed.bnbchain.org';
const MAX_BODY_BYTES = 32_768;
const MAX_BATCH_SIZE = 20;
const UPSTREAM_TIMEOUT_MS = 8_000;
const RATE_LIMIT_WINDOW_MS = 10_000;
const RATE_LIMIT_MAX_COST = 80;
const RATE_LIMIT_MAX_KEYS = 512;

const READ_METHODS = new Set([
  'eth_blockNumber',
  'eth_call',
  'eth_chainId',
  'eth_estimateGas',
  'eth_feeHistory',
  'eth_gasPrice',
  'eth_getBalance',
  'eth_getBlockByNumber',
  'eth_getCode',
  'eth_getTransactionByHash',
  'eth_getTransactionCount',
  'eth_getTransactionReceipt',
  'net_version',
]);

type RpcRequest = { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown };
type RateBucket = { cost: number; resetAt: number };

const rateBuckets = new Map<string, RateBucket>();

function clientKey(request: Request) {
  return (
    request.headers.get('cf-connecting-ip') ||
    request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ||
    'local'
  ).slice(0, 80);
}

function pruneBuckets(now: number) {
  for (const [key, bucket] of rateBuckets) {
    if (bucket.resetAt <= now || rateBuckets.size > RATE_LIMIT_MAX_KEYS) rateBuckets.delete(key);
  }
}

function chargeRateLimit(key: string, cost: number) {
  const now = Date.now();
  pruneBuckets(now);
  const current = rateBuckets.get(key);
  if (!current || current.resetAt <= now) {
    rateBuckets.set(key, { cost, resetAt: now + RATE_LIMIT_WINDOW_MS });
    return true;
  }
  if (current.cost + cost > RATE_LIMIT_MAX_COST) return false;
  current.cost += cost;
  return true;
}

function validId(value: unknown) {
  return value === undefined || value === null || typeof value === 'string' || (typeof value === 'number' && Number.isFinite(value));
}

function validRequest(value: unknown): value is RpcRequest {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const call = value as RpcRequest;
  if (call.jsonrpc !== undefined && call.jsonrpc !== '2.0') return false;
  if (!validId(call.id)) return false;
  if (typeof call.method !== 'string' || !READ_METHODS.has(call.method)) return false;
  if (call.params !== undefined && !Array.isArray(call.params)) return false;
  if (call.method === 'eth_getBlockByNumber') {
    const [blockTag, includeTransactions] = call.params ?? [];
    const validTag = typeof blockTag === 'string' && /^(latest|safe|finalized|pending|0x[0-9a-fA-F]+)$/.test(blockTag);
    return validTag && (includeTransactions === undefined || includeTransactions === false);
  }
  return true;
}

function upstreamUrl() {
  const url = new URL(process.env.BSC_RPC_URL || PUBLIC_BSC_RPC);
  if (url.protocol !== 'https:' && url.protocol !== 'http:') throw new Error('invalid_rpc_url');
  return url.toString();
}

export function __resetRpcRateLimitForTests() {
  rateBuckets.clear();
}

export async function POST(request: Request) {
  const contentLength = Number(request.headers.get('content-length') || 0);
  if (contentLength > MAX_BODY_BYTES) {
    return Response.json({ error: 'request_too_large' }, { status: 413 });
  }

  let body: unknown;
  let bodyText: string;
  try {
    bodyText = await request.text();
    if (new TextEncoder().encode(bodyText).byteLength > MAX_BODY_BYTES) {
      return Response.json({ error: 'request_too_large' }, { status: 413 });
    }
    body = JSON.parse(bodyText) as unknown;
  } catch {
    return Response.json({ error: 'invalid_json' }, { status: 400 });
  }

  const calls = Array.isArray(body) ? body : [body];
  if (calls.length === 0 || calls.length > MAX_BATCH_SIZE || !calls.every(validRequest)) {
    return Response.json({ error: 'read_method_required' }, { status: 403 });
  }

  if (!chargeRateLimit(clientKey(request), calls.length)) {
    return Response.json({ error: 'rate_limited' }, { status: 429, headers: { 'retry-after': '10' } });
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), UPSTREAM_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(upstreamUrl(), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: bodyText,
      signal: controller.signal,
    });
  } catch {
    return Response.json({ error: 'upstream_unavailable' }, { status: 502 });
  } finally {
    clearTimeout(timeout);
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      'content-type': response.headers.get('content-type') || 'application/json',
      'cache-control': 'no-store',
    },
  });
}
