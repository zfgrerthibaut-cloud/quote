import assert from 'node:assert/strict';
import test from 'node:test';
import { Interface } from 'ethers';

import {
  evaluateQuoteTokenEligibility,
  loadQuoteEligibilityConfig,
  type QuoteEligibilityConfig,
} from '../src/domain/quote-eligibility.ts';
import { createQuoteEligibilityHandler } from '../src/quote-eligibility-server.ts';

const QUOTE = '0x00000000000000000000000000000000000000a1';
const REFERENCE = '0x00000000000000000000000000000000000000b2';
const POOL = '0x00000000000000000000000000000000000000c3';
const FACTORY = '0x00000000000000000000000000000000000000f0';
const OTHER_POOL = '0x00000000000000000000000000000000000000d4';
const FEED = '0x00000000000000000000000000000000000000e5';
const Q96 = 2n ** 96n;
const LIQUIDITY = 20_000n * 10n ** 18n;

const ERC20_IFACE = new Interface([
  'function decimals() view returns (uint8)',
  'function balanceOf(address account) view returns (uint256)',
]);
const FACTORY_IFACE = new Interface([
  'function getPool(address tokenA, address tokenB, uint24 fee) view returns (address pool)',
  'function feeAmountTickSpacing(uint24 fee) view returns (int24 tickSpacing)',
]);
const POOL_IFACE = new Interface([
  'function token0() view returns (address)',
  'function token1() view returns (address)',
  'function fee() view returns (uint24)',
  'function tickSpacing() view returns (int24)',
  'function liquidity() view returns (uint128)',
  'function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint32 feeProtocol, bool unlocked)',
  'function observe(uint32[] secondsAgos) view returns (int56[] tickCumulatives, uint160[] secondsPerLiquidityCumulativeX128s)',
]);
const CHAINLINK_IFACE = new Interface([
  'function decimals() view returns (uint8)',
  'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
]);

test('evaluates a canonical stable quote pool with exact USD depth evidence', async () => {
  const rpc = new FakeRpc();
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config(), rpc.fetch);

  assert.equal(result.eligible, true);
  assert.equal(result.reason, 'eligible');
  assert.equal(result.evidence.chainId, 56);
  assert.equal(result.evidence.pool?.canonical, POOL);
  assert.equal(result.evidence.price?.referencePerQuoteCurrent.numerator, '1');
  assert.equal(result.evidence.price?.referencePerQuoteCurrent.denominator, '1');
  assert.equal(result.evidence.price?.quotePerReferenceCurrent.numerator, '1');
  assert.equal(result.evidence.price?.quotePerReferenceCurrent.denominator, '1');
  assert.equal(result.evidence.liquidity?.quoteReserveRawCurrent, LIQUIDITY.toString());
  assert.equal(result.evidence.liquidity?.quotePoolBalanceRaw, LIQUIDITY.toString());
  assert.equal(result.evidence.liquidity?.conservativeQuoteDepthUsd.decimalApprox, '20000');
  assert.deepEqual(result.evidence.checks, [
    'chain_id_56',
    'token_code_and_decimals',
    'canonical_pool_and_pairing',
    'twap_window_observed',
    'reference_usd_source',
    'quote_depth_threshold',
  ]);
});

test('reports price orientation correctly when the quote token is pool token0', async () => {
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config(), new FakeRpc({ sqrtPriceX96: Q96 * 2n }).fetch);

  assert.equal(result.eligible, true);
  assert.equal(result.evidence.price?.referencePerQuoteCurrent.decimalApprox, '4');
  assert.equal(result.evidence.price?.quotePerReferenceCurrent.decimalApprox, '0.25');
  assert.equal(result.evidence.price?.quoteUsdCurrent.decimalApprox, '4');
});

test('reports price orientation correctly when the quote token is pool token1', async () => {
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config(), new FakeRpc({
    token0: REFERENCE,
    token1: QUOTE,
    sqrtPriceX96: Q96 * 2n,
    quotePoolBalance: 40_000n * 10n ** 18n,
  }).fetch);

  assert.equal(result.eligible, true);
  assert.equal(result.evidence.price?.referencePerQuoteCurrent.decimalApprox, '0.25');
  assert.equal(result.evidence.price?.quotePerReferenceCurrent.decimalApprox, '4');
  assert.equal(result.evidence.price?.quoteUsdCurrent.decimalApprox, '0.25');
});

test('uses real quote token pool balance as a conservative depth cap', async () => {
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config(), new FakeRpc({ quotePoolBalance: 9_999n * 10n ** 18n }).fetch);

  assert.equal(result.eligible, false);
  assert.equal(result.reason, 'quote_depth_below_threshold');
  assert.equal(result.evidence.liquidity?.quotePoolBalanceUsd.decimalApprox, '9999');
  assert.equal(result.evidence.liquidity?.conservativeQuoteDepthUsd.decimalApprox, '9999');
});

test('fails closed when the requested pool is not canonical from the configured factory', async () => {
  const rpc = new FakeRpc({ canonicalPool: OTHER_POOL });
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config(), rpc.fetch);

  assert.equal(result.eligible, false);
  assert.equal(result.reason, 'canonical_pool_mismatch');
  assert.equal(result.evidence.pool?.canonical, OTHER_POOL);
});

test('reports missing pool bytecode before decoding pool state', async () => {
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config(), new FakeRpc({ poolCodePresent: false }).fetch);

  assert.equal(result.eligible, false);
  assert.equal(result.reason, 'pool_code_missing');
  assert.equal(result.evidence.pool?.requested, POOL);
  assert.equal(result.evidence.pool?.codePresent, false);
});

test('fails closed without an explicit USD source for the reference token', async () => {
  const rpc = new FakeRpc();
  const result = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config({ stableUsdTokens: new Set() }), rpc.fetch);

  assert.equal(result.eligible, false);
  assert.equal(result.reason, 'reference_usd_source_missing');
  assert.equal(result.evidence.referenceUsd, undefined);
});

test('accepts an explicit Chainlink USD feed and rejects stale answers', async () => {
  const feeds = new Map([[REFERENCE, { feed: FEED, maxAgeSeconds: 60 }]]);
  const live = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config({ stableUsdTokens: new Set(), chainlinkFeeds: feeds }), new FakeRpc({ feedUpdatedAt: 1000 }).fetch);

  const stale = await evaluateQuoteTokenEligibility({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }, config({ stableUsdTokens: new Set(), chainlinkFeeds: feeds }), new FakeRpc({ feedUpdatedAt: 900 }).fetch);

  assert.equal(live.eligible, true);
  assert.equal(live.evidence.referenceUsd?.source, 'chainlink_feed');
  assert.equal(stale.eligible, false);
  assert.equal(stale.reason, 'verification_failed');
  assert.ok(stale.evidence.checks.includes('feed_price_stale'));
});

test('handler rejects arbitrary fields and rate-limits bounded POST checks', async () => {
  let now = 0;
  const handler = createQuoteEligibilityHandler(
    config(),
    new FakeRpc().fetch,
    new Set(['https://quote.test']),
    { maxBodyBytes: 512, rateLimitPerMinute: 1, nowMs: () => now },
  );

  const extraField = await handler(jsonRequest({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
    imageUrl: 'https://attacker.test/token.png',
  }));
  assert.equal(extraField.status, 400);
  assert.deepEqual(await extraField.json(), { error: 'unexpected_fields' });

  const first = await handler(jsonRequest({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }));
  const second = await handler(jsonRequest({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }));
  now = 60_000;
  const third = await handler(jsonRequest({
    quoteToken: QUOTE,
    referenceToken: REFERENCE,
    referencePool: POOL,
  }));

  assert.equal(first.status, 200);
  assert.equal((await first.json() as { eligible: boolean }).eligible, true);
  assert.equal(second.status, 429);
  assert.equal((await second.json() as { reason: string }).reason, 'rate_limited');
  assert.equal(third.status, 200);
  assert.equal(third.headers.get('access-control-allow-origin'), 'https://quote.test');
});

test('loads eligibility config only from explicit RPC, factory, stable and feed settings', () => {
  const loaded = loadQuoteEligibilityConfig({
    BSC_HTTP_RPC_URL: 'https://bsc-rpc.example',
    QUOTE_ELIGIBILITY_FACTORY_ADDRESS: FACTORY,
    QUOTE_ELIGIBILITY_STABLE_USD_TOKENS: REFERENCE,
    QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON: JSON.stringify({
      [QUOTE]: { feed: FEED, maxAgeSeconds: 120 },
    }),
  });

  assert.ok(loaded);
  assert.equal(loaded.rpcUrl, 'https://bsc-rpc.example');
  assert.equal(loaded.factoryAddress, FACTORY);
  assert.deepEqual(loaded.allowedPoolFees, [10000]);
  assert.equal(loaded.stableUsdTokens.has(REFERENCE), true);
  assert.deepEqual(loaded.chainlinkFeeds.get(QUOTE), { feed: FEED, maxAgeSeconds: 120 });
});

function config(overrides: Partial<QuoteEligibilityConfig> = {}): QuoteEligibilityConfig {
  return {
    rpcUrl: 'https://rpc.quote.test',
    factoryAddress: FACTORY,
    allowedPoolFees: [10000],
    minQuoteDepthUsd: { numerator: 10_000n, denominator: 1n },
    twapWindowSeconds: 900,
    rpcTimeoutMs: 1_000,
    rpcMaxAttempts: 1,
    stableUsdTokens: new Set([REFERENCE]),
    chainlinkFeeds: new Map(),
    ...overrides,
  };
}

function jsonRequest(body: unknown) {
  return new Request('https://api.quote.test/v1/quote-token/eligibility', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      origin: 'https://quote.test',
      'x-quote-client-address': '127.0.0.1',
    },
    body: JSON.stringify(body),
  });
}

class FakeRpc {
  readonly fetch: typeof fetch;
  private readonly canonicalPool: string;
  private readonly feedUpdatedAt: number;
  private readonly token0: string;
  private readonly token1: string;
  private readonly sqrtPriceX96: bigint;
  private readonly quotePoolBalance: bigint;
  private readonly poolCodePresent: boolean;

  constructor(options: {
    canonicalPool?: string;
    feedUpdatedAt?: number;
    token0?: string;
    token1?: string;
    sqrtPriceX96?: bigint;
    quotePoolBalance?: bigint;
    poolCodePresent?: boolean;
  } = {}) {
    this.canonicalPool = options.canonicalPool ?? POOL;
    this.feedUpdatedAt = options.feedUpdatedAt ?? 1000;
    this.token0 = options.token0 ?? QUOTE;
    this.token1 = options.token1 ?? REFERENCE;
    this.sqrtPriceX96 = options.sqrtPriceX96 ?? Q96;
    this.quotePoolBalance = options.quotePoolBalance ?? LIQUIDITY;
    this.poolCodePresent = options.poolCodePresent ?? true;
    this.fetch = async (_url, init) => {
      const request = JSON.parse(String(init?.body)) as {
        id: number;
        method: string;
        params: unknown[];
      };
      return jsonRpcResponse(request.id, this.handle(request.method, request.params));
    };
  }

  private handle(method: string, params: unknown[]) {
    if (method === 'eth_chainId') return '0x38';
    if (method === 'eth_getCode') return this.codeFor(String(params[0]));
    if (method === 'eth_getBlockByNumber') return { timestamp: '0x3e8' };
    if (method === 'eth_call') return this.call((params[0] as { to: string; data: string }).to.toLowerCase(), (params[0] as { data: string }).data);
    throw new Error(`unexpected_rpc:${method}`);
  }

  private codeFor(address: string) {
    const normalized = address.toLowerCase();
    if (normalized === POOL) return this.poolCodePresent ? '0x01' : '0x';
    return new Set([QUOTE, REFERENCE, FACTORY, FEED]).has(normalized) ? '0x01' : '0x';
  }

  private call(to: string, data: string) {
    const interfaces = to === FEED ? [CHAINLINK_IFACE] : [POOL_IFACE, FACTORY_IFACE, ERC20_IFACE];
    for (const contractInterface of interfaces) {
      const parsed = contractInterface.parseTransaction({ data });
      if (!parsed) continue;
      if (contractInterface === POOL_IFACE) return this.poolCall(to, parsed.name);
      if (contractInterface === FACTORY_IFACE) return this.factoryCall(to, parsed.name);
      if (contractInterface === ERC20_IFACE) return this.erc20Call(to, parsed.name);
      if (contractInterface === CHAINLINK_IFACE) return this.chainlinkCall(to, parsed.name);
    }
    throw new Error('unknown_call');
  }

  private poolCall(to: string, name: string) {
    assert.equal(to, POOL);
    switch (name) {
      case 'token0':
        return POOL_IFACE.encodeFunctionResult('token0', [this.token0]);
      case 'token1':
        return POOL_IFACE.encodeFunctionResult('token1', [this.token1]);
      case 'fee':
        return POOL_IFACE.encodeFunctionResult('fee', [10000]);
      case 'tickSpacing':
        return POOL_IFACE.encodeFunctionResult('tickSpacing', [200]);
      case 'liquidity':
        return POOL_IFACE.encodeFunctionResult('liquidity', [LIQUIDITY]);
      case 'slot0':
        return POOL_IFACE.encodeFunctionResult('slot0', [this.sqrtPriceX96, 0, 1, 8, 8, 0, true]);
      case 'observe':
        return POOL_IFACE.encodeFunctionResult('observe', [[0, 0], [0, 0]]);
      default:
        throw new Error(`unknown_pool_call:${name}`);
    }
  }

  private erc20Call(to: string, name: string) {
    switch (name) {
      case 'decimals':
        return ERC20_IFACE.encodeFunctionResult('decimals', [18]);
      case 'balanceOf':
        return ERC20_IFACE.encodeFunctionResult('balanceOf', [to === QUOTE ? this.quotePoolBalance : 0n]);
      default:
        throw new Error(`unknown_erc20_call:${name}`);
    }
  }

  private factoryCall(to: string, name: string) {
    assert.equal(to, FACTORY);
    switch (name) {
      case 'getPool':
        return FACTORY_IFACE.encodeFunctionResult('getPool', [this.canonicalPool]);
      case 'feeAmountTickSpacing':
        return FACTORY_IFACE.encodeFunctionResult('feeAmountTickSpacing', [200]);
      default:
        throw new Error(`unknown_factory_call:${name}`);
    }
  }

  private chainlinkCall(to: string, name: string) {
    assert.equal(to, FEED);
    switch (name) {
      case 'decimals':
        return CHAINLINK_IFACE.encodeFunctionResult('decimals', [8]);
      case 'latestRoundData':
        return CHAINLINK_IFACE.encodeFunctionResult('latestRoundData', [7, 100_000_000n, 990, this.feedUpdatedAt, 7]);
      default:
        throw new Error(`unknown_feed_call:${name}`);
    }
  }
}

function jsonRpcResponse(id: number, result: unknown) {
  return new Response(JSON.stringify({ jsonrpc: '2.0', id, result }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  });
}
