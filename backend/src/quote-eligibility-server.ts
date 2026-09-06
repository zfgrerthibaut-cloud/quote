import {
  evaluateQuoteTokenEligibility,
  loadQuoteEligibilityConfig,
  normalizeAddress,
  type QuoteEligibilityConfig,
  type QuoteEligibilityInput,
} from './domain/quote-eligibility.ts';
import { configuredWebOrigins } from './market-server.ts';

type FetchLike = typeof fetch;

export type QuoteEligibilityHandlerOptions = Readonly<{
  maxBodyBytes: number;
  rateLimitPerMinute: number;
  nowMs?: () => number;
}>;

const DEFAULT_OPTIONS: QuoteEligibilityHandlerOptions = {
  maxBodyBytes: 1_024,
  rateLimitPerMinute: 30,
};

export function createQuoteEligibilityHandlerFromEnv(
  env: NodeJS.ProcessEnv = process.env,
  fetchImpl: FetchLike = fetch,
  allowedOrigins = configuredWebOrigins(env.QUOTE_WEB_ORIGINS ?? ''),
) {
  const config = loadQuoteEligibilityConfig(env);
  const options = {
    maxBodyBytes: integerEnv(env, 'QUOTE_ELIGIBILITY_MAX_BODY_BYTES', DEFAULT_OPTIONS.maxBodyBytes, 256, 8_192),
    rateLimitPerMinute: integerEnv(env, 'QUOTE_ELIGIBILITY_RATE_LIMIT_PER_MINUTE', DEFAULT_OPTIONS.rateLimitPerMinute, 1, 600),
  };
  return createQuoteEligibilityHandler(config, fetchImpl, allowedOrigins, options);
}

export function createQuoteEligibilityHandler(
  config: QuoteEligibilityConfig | null,
  fetchImpl: FetchLike = fetch,
  allowedOrigins = configuredWebOrigins(),
  options: QuoteEligibilityHandlerOptions = DEFAULT_OPTIONS,
) {
  const limiter = new FixedWindowRateLimiter(options.rateLimitPerMinute, options.nowMs ?? Date.now);

  return async function handleQuoteEligibilityRequest(request: Request) {
    const cors = corsHeaders(request, allowedOrigins);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'POST') return jsonResponse({ error: 'method_not_allowed' }, 405, cors);
    if (!config) return jsonResponse({ eligible: false, reason: 'service_unconfigured', evidence: { checks: [] } }, 503, cors);

    let input: QuoteEligibilityInput;
    try {
      input = await readInput(request, options.maxBodyBytes);
    } catch (error) {
      return jsonResponse({ error: safeError(error) }, 400, cors);
    }

    const clientKey = request.headers.get('x-quote-client-address') ?? request.headers.get('origin') ?? 'local';
    if (!limiter.allow(clientKey)) return jsonResponse({ eligible: false, reason: 'rate_limited', evidence: { checks: [] } }, 429, cors);

    const result = await evaluateQuoteTokenEligibility(input, config, fetchImpl);
    return jsonResponse(result, 200, new Headers({
      ...Object.fromEntries(cors),
      'cache-control': 'no-store',
    }));
  };
}

async function readInput(request: Request, maxBodyBytes: number): Promise<QuoteEligibilityInput> {
  const contentType = request.headers.get('content-type') ?? '';
  if (!contentType.toLowerCase().split(';').some((part) => part.trim() === 'application/json')) {
    throw new Error('content_type_json_required');
  }
  const contentLength = request.headers.get('content-length');
  if (contentLength && /^\d+$/.test(contentLength) && Number(contentLength) > maxBodyBytes) {
    throw new Error('body_too_large');
  }
  const raw = await request.text();
  if (Buffer.byteLength(raw, 'utf8') > maxBodyBytes) throw new Error('body_too_large');

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error('json_invalid');
  }
  if (!isRecord(parsed)) throw new Error('json_object_required');

  const keys = Object.keys(parsed);
  const allowedKeys = new Set(['quoteToken', 'referenceToken', 'referencePool']);
  if (keys.length !== allowedKeys.size || keys.some((key) => !allowedKeys.has(key))) throw new Error('unexpected_fields');

  const quoteToken = addressField(parsed.quoteToken, 'quoteToken');
  const referenceToken = addressField(parsed.referenceToken, 'referenceToken');
  const referencePool = addressField(parsed.referencePool, 'referencePool');
  return { quoteToken, referenceToken, referencePool };
}

function addressField(value: unknown, field: string) {
  if (typeof value !== 'string') throw new Error(`${field}_invalid`);
  const normalized = normalizeAddress(value);
  if (!normalized) throw new Error(`${field}_invalid`);
  return normalized;
}

function corsHeaders(request: Request, allowedOrigins: Set<string>) {
  const headers = new Headers({
    vary: 'Origin',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-allow-headers': 'Content-Type',
    'access-control-max-age': '600',
  });
  const origin = request.headers.get('origin');
  if (origin && allowedOrigins.has(origin)) {
    headers.set('access-control-allow-origin', origin);
  }
  return headers;
}

function jsonResponse(payload: unknown, status: number, headers: Headers) {
  const responseHeaders = new Headers(headers);
  responseHeaders.set('content-type', 'application/json; charset=utf-8');
  responseHeaders.set('x-content-type-options', 'nosniff');
  return new Response(JSON.stringify(payload), { status, headers: responseHeaders });
}

function integerEnv(env: NodeJS.ProcessEnv, name: string, fallback: number, minimum: number, maximum: number) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${name}_invalid`);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function safeError(error: unknown) {
  return error instanceof Error ? error.message : 'bad_request';
}

class FixedWindowRateLimiter {
  private readonly windows = new Map<string, { startsAt: number; count: number }>();
  private readonly limit: number;
  private readonly nowMs: () => number;

  constructor(
    limit: number,
    nowMs: () => number,
  ) {
    this.limit = limit;
    this.nowMs = nowMs;
  }

  allow(key: string) {
    const now = this.nowMs();
    const current = this.windows.get(key);
    if (!current || now - current.startsAt >= 60_000) {
      this.windows.set(key, { startsAt: now, count: 1 });
      this.collect(now);
      return true;
    }
    if (current.count >= this.limit) return false;
    current.count += 1;
    return true;
  }

  private collect(now: number) {
    for (const [key, window] of this.windows) {
      if (now - window.startsAt >= 120_000) this.windows.delete(key);
    }
  }
}
