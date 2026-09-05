const PUBLIC_BSC_RPC = 'https://bsc-dataseed.bnbchain.org';
const MAX_BODY_BYTES = 32_768;
const MAX_BATCH_SIZE = 20;

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
  'eth_getLogs',
  'eth_getTransactionByHash',
  'eth_getTransactionCount',
  'eth_getTransactionReceipt',
  'net_version',
]);

type RpcRequest = { jsonrpc?: unknown; id?: unknown; method?: unknown; params?: unknown };

function validRequest(value: unknown): value is RpcRequest {
  return Boolean(
    value &&
      typeof value === 'object' &&
      typeof (value as RpcRequest).method === 'string' &&
      READ_METHODS.has((value as RpcRequest).method as string),
  );
}

export async function POST(request: Request) {
  const contentLength = Number(request.headers.get('content-length') || 0);
  if (contentLength > MAX_BODY_BYTES) {
    return Response.json({ error: 'request_too_large' }, { status: 413 });
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: 'invalid_json' }, { status: 400 });
  }

  const calls = Array.isArray(body) ? body : [body];
  if (calls.length === 0 || calls.length > MAX_BATCH_SIZE || !calls.every(validRequest)) {
    return Response.json({ error: 'read_method_required' }, { status: 403 });
  }

  const upstream = process.env.BSC_RPC_URL || PUBLIC_BSC_RPC;
  const response = await fetch(upstream, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });

  return new Response(response.body, {
    status: response.status,
    headers: {
      'content-type': response.headers.get('content-type') || 'application/json',
      'cache-control': 'no-store',
    },
  });
}
