const ADDRESS_RE = /^0x[a-fA-F0-9]{40}$/;
const LOOKUP_TIMEOUT_MS = 1_500;
const MAX_IMAGE_BYTES = 1_500_000;

type RouteContext = { params: Promise<{ address: string }> };

function configuredOrigin(raw: string | undefined) {
  if (!raw) return null;
  try {
    const url = new URL(raw);
    const localHttp = process.env.NODE_ENV !== 'production'
      && url.protocol === 'http:'
      && (url.hostname === '127.0.0.1' || url.hostname === 'localhost');
    if ((url.protocol !== 'https:' && !localHttp) || url.username || url.password || url.search || url.hash) return null;
    return url.origin;
  } catch {
    return null;
  }
}

function reject(status: number, retryAfter?: string) {
  const headers = new Headers({
    'cache-control': status === 404 ? 'public, max-age=15, s-maxage=30' : 'no-store',
    'cross-origin-resource-policy': 'same-origin',
    'x-content-type-options': 'nosniff',
  });
  if (retryAfter) headers.set('retry-after', retryAfter);
  return new Response(null, { status, headers });
}

async function readLimitedBytes(response: Response) {
  const declared = Number(response.headers.get('content-length') || 0);
  if (declared > MAX_IMAGE_BYTES) throw new Error('oversized_media');
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength < 1 || bytes.byteLength > MAX_IMAGE_BYTES) throw new Error('oversized_media');
  return bytes;
}

function asBody(bytes: Uint8Array) {
  const body = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(body).set(bytes);
  return body;
}

export async function GET(_request: Request, { params }: RouteContext) {
  const { address } = await params;
  if (!ADDRESS_RE.test(address)) return reject(400);

  const backendOrigin = configuredOrigin(process.env.QUOTE_BACKEND_URL);
  if (!backendOrigin) return reject(404);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), LOOKUP_TIMEOUT_MS);
  try {
    const response = await fetch(`${backendOrigin}/v1/media/token/56/${address.toLowerCase()}`, {
      cache: 'no-store',
      headers: { accept: 'image/webp,image/png' },
      redirect: 'error',
      signal: controller.signal,
    });

    if (response.status === 404 || response.status === 202) return reject(404);
    if (response.status === 429) return reject(429, response.headers.get('retry-after') || '60');
    if (!response.ok) return reject(502);

    const contentType = response.headers.get('content-type');
    if (contentType !== 'image/png' && contentType !== 'image/webp') return reject(502);
    const bytes = await readLimitedBytes(response);
    const headers = new Headers({
      'cache-control': 'public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800',
      'content-length': String(bytes.byteLength),
      'content-type': contentType,
      'cross-origin-resource-policy': 'same-origin',
      'x-content-type-options': 'nosniff',
    });
    const etag = response.headers.get('etag');
    if (etag) headers.set('etag', etag);
    return new Response(asBody(bytes), { status: 200, headers });
  } catch {
    return reject(502);
  } finally {
    clearTimeout(timeout);
  }
}
