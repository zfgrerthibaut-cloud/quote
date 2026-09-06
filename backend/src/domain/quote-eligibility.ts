import { Interface, getAddress, keccak256 } from 'ethers';

export const QUOTE_ELIGIBILITY_CHAIN_ID = 56;

type FetchLike = typeof fetch;

export type QuoteEligibilityInput = Readonly<{
  quoteToken: string;
  referenceToken: string;
  referencePool: string;
}>;

export type QuoteEligibilityChainlinkFeed = Readonly<{
  feed: string;
  maxAgeSeconds: number;
}>;

export type QuoteEligibilityConfig = Readonly<{
  rpcUrl: string;
  factoryAddress: string;
  quoterV2Address: string;
  quoterV2RuntimeCodeHash: string;
  allowedPoolFees: readonly number[];
  minQuoteDepthUsd: Rational;
  maxPriceImpactBps: number;
  twapWindowSeconds: number;
  rpcTimeoutMs: number;
  rpcMaxAttempts: number;
  stableUsdTokens: ReadonlySet<string>;
  chainlinkFeeds: ReadonlyMap<string, QuoteEligibilityChainlinkFeed>;
}>;

export type QuoteEligibilityResult = Readonly<{
  eligible: boolean;
  reason: string;
  evidence: QuoteEligibilityEvidence;
}>;

export type QuoteEligibilityEvidence = {
  chainId?: number;
  block?: BlockEvidence;
  factory?: string;
  quoter?: QuoterEvidence;
  quoteToken?: TokenEvidence;
  referenceToken?: TokenEvidence;
  pool?: PoolEvidence;
  twap?: TwapEvidence;
  referenceUsd?: ReferenceUsdEvidence;
  price?: PriceEvidence;
  liquidity?: LiquidityEvidence;
  checks: string[];
};

export type BlockEvidence = Readonly<{
  number: string;
  tag: string;
  timestamp: number;
}>;

export type QuoterEvidence = Readonly<{
  address: string;
  codePresent: boolean;
  runtimeCodeHash?: string;
  expectedRuntimeCodeHash: string;
  factory?: string;
}>;

export type TokenEvidence = Readonly<{
  address: string;
  codePresent: boolean;
  decimals?: number;
}>;

export type PoolEvidence = Readonly<{
  requested: string;
  canonical: string;
  codePresent: boolean;
  token0: string;
  token1: string;
  fee: number;
  allowedFees: readonly number[];
  tickSpacing: number;
  factoryTickSpacing: number;
  sqrtPriceX96: string;
  tick: number;
  liquidity: string;
  observationIndex: number;
  observationCardinality: number;
  observationCardinalityNext: number;
  unlocked: boolean;
}>;

export type TwapEvidence = Readonly<{
  windowSeconds: number;
  tickCumulativeAgo: string;
  tickCumulativeNow: string;
  arithmeticMeanTick: number;
  sqrtPriceX96: string;
}>;

export type ReferenceUsdEvidence = Readonly<{
  source: 'stable_allowlist' | 'chainlink_feed';
  token: string;
  feed?: string;
  answer?: string;
  decimals?: number;
  updatedAt?: number;
  blockTimestamp?: number;
  maxAgeSeconds?: number;
  priceUsd: SerializedRational;
}>;

export type PriceEvidence = Readonly<{
  referencePerQuoteCurrent: SerializedRationalWithDecimal;
  referencePerQuoteTwap: SerializedRationalWithDecimal;
  quotePerReferenceCurrent: SerializedRationalWithDecimal;
  quotePerReferenceTwap: SerializedRationalWithDecimal;
  quoteUsdCurrent: SerializedRationalWithDecimal;
  quoteUsdTwap: SerializedRationalWithDecimal;
  conservativeQuoteUsd: SerializedRationalWithDecimal;
}>;

export type LiquidityEvidence = Readonly<{
  rule: 'pancake_v3_quoter_v2_exact_output_and_reverse_exact_input';
  targetQuoteRaw: string;
  targetQuoteDecimal: string;
  targetQuoteUsd: SerializedRationalWithDecimal;
  quotePoolBalanceRaw: string;
  quotePoolBalanceDecimal: string;
  quotePoolBalanceUsd: SerializedRationalWithDecimal;
  referenceToQuoteInputRaw: string;
  referenceToQuoteInputDecimal: string;
  referenceToQuoteInputUsd: SerializedRationalWithDecimal;
  referenceToQuoteMaxInputUsd: SerializedRationalWithDecimal;
  referenceToQuoteSqrtPriceX96After: string;
  referenceToQuoteInitializedTicksCrossed: number;
  quoteToReferenceOutputRaw: string;
  quoteToReferenceOutputDecimal: string;
  quoteToReferenceOutputUsd: SerializedRationalWithDecimal;
  quoteToReferenceMinOutputUsd: SerializedRationalWithDecimal;
  quoteToReferenceSqrtPriceX96After: string;
  quoteToReferenceInitializedTicksCrossed: number;
  maxPriceImpactBps: number;
  minQuoteDepthUsd: SerializedRationalWithDecimal;
}>;

export type SerializedRational = Readonly<{
  numerator: string;
  denominator: string;
}>;

export type SerializedRationalWithDecimal = SerializedRational & Readonly<{
  decimalApprox: string;
}>;

export type Rational = Readonly<{
  numerator: bigint;
  denominator: bigint;
}>;

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const Q96 = 2n ** 96n;
const Q192 = 2n ** 192n;
const MIN_TICK = -887272;
const MAX_TICK = 887272;

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

const QUOTER_V2_IFACE = new Interface([
  'function factory() view returns (address)',
  'function quoteExactOutputSingle((address tokenIn,address tokenOut,uint256 amount,uint24 fee,uint160 sqrtPriceLimitX96) params) returns (uint256 amountIn,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)',
  'function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96) params) returns (uint256 amountOut,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)',
]);

const CHAINLINK_IFACE = new Interface([
  'function decimals() view returns (uint8)',
  'function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)',
]);

export function loadQuoteEligibilityConfig(env: NodeJS.ProcessEnv = process.env): QuoteEligibilityConfig | null {
  const rpcUrl = env.BSC_HTTP_RPC_URL?.trim();
  const factoryAddress = normalizeAddress(env.QUOTE_ELIGIBILITY_FACTORY_ADDRESS ?? '');
  const quoterV2Address = normalizeAddress(env.QUOTE_ELIGIBILITY_QUOTER_V2_ADDRESS ?? '');
  const quoterV2RuntimeCodeHash = normalizeHash(env.QUOTE_ELIGIBILITY_QUOTER_V2_RUNTIME_CODE_HASH ?? '');
  if (!rpcUrl || !factoryAddress || !quoterV2Address || !quoterV2RuntimeCodeHash) return null;

  validateRpcUrl(rpcUrl);
  const allowedPoolFees = parseAllowedPoolFees(env.QUOTE_ELIGIBILITY_ALLOWED_POOL_FEES ?? '10000');
  return {
    rpcUrl,
    factoryAddress,
    quoterV2Address,
    quoterV2RuntimeCodeHash,
    allowedPoolFees,
    minQuoteDepthUsd: parseDecimalRational(env.QUOTE_ELIGIBILITY_MIN_QUOTE_DEPTH_USD ?? '10000', 'QUOTE_ELIGIBILITY_MIN_QUOTE_DEPTH_USD'),
    maxPriceImpactBps: integerEnv(env, 'QUOTE_ELIGIBILITY_MAX_PRICE_IMPACT_BPS', 500, 0, 5_000),
    twapWindowSeconds: integerEnv(env, 'QUOTE_ELIGIBILITY_TWAP_WINDOW_SECONDS', 900, 1, 86_400),
    rpcTimeoutMs: integerEnv(env, 'QUOTE_ELIGIBILITY_RPC_TIMEOUT_MS', 5_000, 250, 30_000),
    rpcMaxAttempts: integerEnv(env, 'QUOTE_ELIGIBILITY_RPC_MAX_ATTEMPTS', 2, 1, 5),
    stableUsdTokens: parseAddressSet(env.QUOTE_ELIGIBILITY_STABLE_USD_TOKENS ?? '', 'QUOTE_ELIGIBILITY_STABLE_USD_TOKENS'),
    chainlinkFeeds: parseChainlinkFeeds(env.QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON ?? '{}'),
  };
}

export async function evaluateQuoteTokenEligibility(
  input: QuoteEligibilityInput,
  config: QuoteEligibilityConfig,
  fetchImpl: FetchLike = fetch,
): Promise<QuoteEligibilityResult> {
  const evidence: QuoteEligibilityEvidence = {
    factory: config.factoryAddress,
    checks: [],
  };
  const fail = (reason: string): QuoteEligibilityResult => ({ eligible: false, reason, evidence });

  const quoteToken = normalizeAddress(input.quoteToken);
  const referenceToken = normalizeAddress(input.referenceToken);
  const referencePool = normalizeAddress(input.referencePool);
  if (!quoteToken || !referenceToken || !referencePool) return fail('invalid_address');
  if (quoteToken === referenceToken) return fail('tokens_must_differ');
  if (referencePool === ZERO_ADDRESS) return fail('reference_pool_zero');

  const rpc = new EligibilityRpcClient(config.rpcUrl, fetchImpl, config.rpcTimeoutMs, config.rpcMaxAttempts);

  try {
    const chainId = await rpc.getChainId();
    evidence.chainId = chainId;
    if (chainId !== QUOTE_ELIGIBILITY_CHAIN_ID) return fail('rpc_chain_id_mismatch');
    evidence.checks.push('chain_id_56');

    const block = await rpc.getLatestBlock();
    evidence.block = {
      number: block.number.toString(),
      tag: block.tag,
      timestamp: block.timestamp,
    };
    evidence.checks.push('single_block_tag');

    const quoter = await readQuoterEvidence(rpc, config, block.tag);
    evidence.quoter = quoter;
    if (!quoter.codePresent) return fail('quoter_code_missing');
    if (quoter.runtimeCodeHash !== config.quoterV2RuntimeCodeHash) return fail('quoter_codehash_mismatch');
    if (quoter.factory !== config.factoryAddress) return fail('quoter_factory_mismatch');
    evidence.checks.push('quoter_v2_pinned');

    const [quoteCode, referenceCode] = await Promise.all([
      rpc.getCode(quoteToken, block.tag),
      rpc.getCode(referenceToken, block.tag),
    ]);
    const [quoteDecimals, referenceDecimals] = await Promise.all([
      quoteCode !== '0x' ? readTokenDecimals(rpc, quoteToken, block.tag) : Promise.resolve<number | null>(null),
      referenceCode !== '0x' ? readTokenDecimals(rpc, referenceToken, block.tag) : Promise.resolve<number | null>(null),
    ]);
    evidence.quoteToken = {
      address: quoteToken,
      codePresent: quoteCode !== '0x',
      decimals: quoteDecimals ?? undefined,
    };
    evidence.referenceToken = {
      address: referenceToken,
      codePresent: referenceCode !== '0x',
      decimals: referenceDecimals ?? undefined,
    };
    if (quoteCode === '0x' || referenceCode === '0x') return fail('token_code_missing');
    if (quoteDecimals === null || referenceDecimals === null) return fail('token_decimals_unreadable');
    if (!safeTokenDecimals(quoteDecimals) || !safeTokenDecimals(referenceDecimals)) return fail('token_decimals_unsupported');
    evidence.checks.push('token_code_and_decimals');

    const poolCode = await rpc.getCode(referencePool, block.tag);
    if (poolCode === '0x') {
      evidence.pool = missingPoolEvidence(config, referencePool);
      return fail('pool_code_missing');
    }

    const pool = await readPoolEvidence(rpc, config, referencePool, poolCode, block.tag);
    evidence.pool = pool;
    if (!config.allowedPoolFees.includes(pool.fee)) return fail('pool_fee_not_allowed');
    if (pool.canonical !== referencePool) return fail('canonical_pool_mismatch');
    if (pool.factoryTickSpacing <= 0 || pool.factoryTickSpacing !== pool.tickSpacing) return fail('tick_spacing_mismatch');
    if (!pool.unlocked) return fail('pool_locked');
    if (pool.sqrtPriceX96 === '0') return fail('pool_uninitialized');
    if (BigInt(pool.liquidity) <= 0n) return fail('pool_liquidity_empty');

    const quoteIsToken0 = pool.token0 === quoteToken && pool.token1 === referenceToken;
    const quoteIsToken1 = pool.token1 === quoteToken && pool.token0 === referenceToken;
    if (!quoteIsToken0 && !quoteIsToken1) return fail('pool_token_pair_mismatch');
    evidence.checks.push('canonical_pool_and_pairing');

    const twap = await readTwapEvidence(rpc, referencePool, config.twapWindowSeconds, block.tag);
    evidence.twap = twap;
    evidence.checks.push('twap_window_observed');

    const referenceUsd = await readReferenceUsd(rpc, config, referenceToken, block.timestamp, block.tag);
    if (!referenceUsd) return fail('reference_usd_source_missing');
    evidence.referenceUsd = referenceUsd;
    evidence.checks.push('reference_usd_source');

    const currentSqrt = BigInt(pool.sqrtPriceX96);
    const twapSqrt = BigInt(twap.sqrtPriceX96);
    const liquidity = BigInt(pool.liquidity);
    const referencePerQuoteCurrent = referencePerQuotePrice(currentSqrt, quoteIsToken0, quoteDecimals, referenceDecimals);
    const referencePerQuoteTwap = referencePerQuotePrice(twapSqrt, quoteIsToken0, quoteDecimals, referenceDecimals);
    const quotePerReferenceCurrent = inverseRatio(referencePerQuoteCurrent);
    const quotePerReferenceTwap = inverseRatio(referencePerQuoteTwap);
    const referenceUsdPrice = parseSerializedRational(referenceUsd.priceUsd);
    const quoteUsdCurrent = multiplyRatio(referencePerQuoteCurrent, referenceUsdPrice);
    const quoteUsdTwap = multiplyRatio(referencePerQuoteTwap, referenceUsdPrice);
    const conservativeQuoteUsd = minRatio(quoteUsdCurrent, quoteUsdTwap);

    if (liquidity <= 0n) return fail('pool_liquidity_empty');

    const poolBalance = await readTokenBalanceOf(rpc, quoteToken, referencePool, block.tag);
    if (poolBalance === null) return fail('quote_pool_balance_unreadable');
    const referenceUsdPrice = parseSerializedRational(referenceUsd.priceUsd);

    evidence.price = {
      referencePerQuoteCurrent: serializeRatio(referencePerQuoteCurrent),
      referencePerQuoteTwap: serializeRatio(referencePerQuoteTwap),
      quotePerReferenceCurrent: serializeRatio(quotePerReferenceCurrent),
      quotePerReferenceTwap: serializeRatio(quotePerReferenceTwap),
      quoteUsdCurrent: serializeRatio(quoteUsdCurrent),
      quoteUsdTwap: serializeRatio(quoteUsdTwap),
      conservativeQuoteUsd: serializeRatio(conservativeQuoteUsd),
    };

    let depth: LiquidityEvidence;
    try {
      depth = await readExecutableDepthEvidence({
        rpc,
        config,
        blockTag: block.tag,
        quoteToken,
        referenceToken,
        referencePool,
        poolFee: pool.fee,
        quoteDecimals,
        referenceDecimals,
        quoteUsd: conservativeQuoteUsd,
        referenceUsd: referenceUsdPrice,
        quotePoolBalanceRaw: poolBalance,
      });
    } catch (error) {
      evidence.checks.push(`quoter_depth_call_failed:${safeError(error)}`);
      return fail('quote_depth_not_executable');
    }

    evidence.liquidity = depth;
    const inputOverMax = compareSerializedRatio(depth.referenceToQuoteInputUsd, depth.referenceToQuoteMaxInputUsd) > 0;
    const outputUnderMin = compareSerializedRatio(depth.quoteToReferenceOutputUsd, depth.quoteToReferenceMinOutputUsd) < 0;
    const balanceUnderTarget = poolBalance < BigInt(depth.targetQuoteRaw);
    if (inputOverMax || outputUnderMin || balanceUnderTarget) {
      return fail('quote_depth_below_threshold');
    }

    evidence.checks.push('executable_quote_depth_threshold');
    return { eligible: true, reason: 'eligible', evidence };
  } catch (error) {
    evidence.checks.push(safeError(error));
    return fail('verification_failed');
  }
}

function parseSerializedRational(value: SerializedRational): Rational {
  return makeRatio(BigInt(value.numerator), BigInt(value.denominator));
}

async function readQuoterEvidence(
  rpc: EligibilityRpcClient,
  config: QuoteEligibilityConfig,
  blockTag: string,
): Promise<QuoterEvidence> {
  const code = await rpc.getCode(config.quoterV2Address, blockTag);
  if (code === '0x') {
    return {
      address: config.quoterV2Address,
      codePresent: false,
      expectedRuntimeCodeHash: config.quoterV2RuntimeCodeHash,
    };
  }
  const runtimeCodeHash = keccak256(code).toLowerCase();
  const factoryRaw = await rpc.callContract(config.quoterV2Address, QUOTER_V2_IFACE, 'factory', [], blockTag);
  return {
    address: config.quoterV2Address,
    codePresent: true,
    runtimeCodeHash,
    expectedRuntimeCodeHash: config.quoterV2RuntimeCodeHash,
    factory: normalizeAddress(stringValue(factoryRaw[0], 'quoter.factory')) ?? ZERO_ADDRESS,
  };
}

async function readPoolEvidence(
  rpc: EligibilityRpcClient,
  config: QuoteEligibilityConfig,
  referencePool: string,
  poolCode: string,
  blockTag: string,
): Promise<PoolEvidence> {
  const [token0Raw, token1Raw, feeRaw, tickSpacingRaw, liquidityRaw, slot0Raw] = await Promise.all([
    rpc.callContract(referencePool, POOL_IFACE, 'token0', [], blockTag),
    rpc.callContract(referencePool, POOL_IFACE, 'token1', [], blockTag),
    rpc.callContract(referencePool, POOL_IFACE, 'fee', [], blockTag),
    rpc.callContract(referencePool, POOL_IFACE, 'tickSpacing', [], blockTag),
    rpc.callContract(referencePool, POOL_IFACE, 'liquidity', [], blockTag),
    rpc.callContract(referencePool, POOL_IFACE, 'slot0', [], blockTag),
  ]);

  const token0 = normalizeAddress(stringValue(token0Raw[0], 'pool.token0')) ?? ZERO_ADDRESS;
  const token1 = normalizeAddress(stringValue(token1Raw[0], 'pool.token1')) ?? ZERO_ADDRESS;
  const fee = safeNumber(bigintValue(feeRaw[0], 'pool.fee'), 'pool.fee');
  const tickSpacing = signedSafeNumber(bigintValue(tickSpacingRaw[0], 'pool.tickSpacing'), 'pool.tickSpacing');
  const canonicalRaw = await rpc.callContract(config.factoryAddress, FACTORY_IFACE, 'getPool', [token0, token1, fee], blockTag);
  const factoryTickSpacingRaw = await rpc.callContract(config.factoryAddress, FACTORY_IFACE, 'feeAmountTickSpacing', [fee], blockTag);
  const slot0 = slot0Values(slot0Raw);

  return {
    requested: referencePool,
    canonical: normalizeAddress(stringValue(canonicalRaw[0], 'factory.getPool')) ?? ZERO_ADDRESS,
    codePresent: poolCode !== '0x',
    token0,
    token1,
    fee,
    allowedFees: config.allowedPoolFees,
    tickSpacing,
    factoryTickSpacing: signedSafeNumber(bigintValue(factoryTickSpacingRaw[0], 'factory.tickSpacing'), 'factory.tickSpacing'),
    sqrtPriceX96: bigintValue(slot0.sqrtPriceX96, 'slot0.sqrtPriceX96').toString(),
    tick: signedSafeNumber(bigintValue(slot0.tick, 'slot0.tick'), 'slot0.tick'),
    liquidity: bigintValue(liquidityRaw[0], 'pool.liquidity').toString(),
    observationIndex: safeNumber(bigintValue(slot0.observationIndex, 'slot0.observationIndex'), 'slot0.observationIndex'),
    observationCardinality: safeNumber(bigintValue(slot0.observationCardinality, 'slot0.observationCardinality'), 'slot0.observationCardinality'),
    observationCardinalityNext: safeNumber(bigintValue(slot0.observationCardinalityNext, 'slot0.observationCardinalityNext'), 'slot0.observationCardinalityNext'),
    unlocked: booleanValue(slot0.unlocked, 'slot0.unlocked'),
  };
}

function missingPoolEvidence(config: QuoteEligibilityConfig, referencePool: string): PoolEvidence {
  return {
    requested: referencePool,
    canonical: ZERO_ADDRESS,
    codePresent: false,
    token0: ZERO_ADDRESS,
    token1: ZERO_ADDRESS,
    fee: 0,
    allowedFees: config.allowedPoolFees,
    tickSpacing: 0,
    factoryTickSpacing: 0,
    sqrtPriceX96: '0',
    tick: 0,
    liquidity: '0',
    observationIndex: 0,
    observationCardinality: 0,
    observationCardinalityNext: 0,
    unlocked: false,
  };
}

async function readTwapEvidence(rpc: EligibilityRpcClient, pool: string, windowSeconds: number, blockTag: string): Promise<TwapEvidence> {
  const observed = await rpc.callContract(pool, POOL_IFACE, 'observe', [[windowSeconds, 0]], blockTag);
  const tickCumulatives = observed[0];
  if (!Array.isArray(tickCumulatives) || tickCumulatives.length !== 2) throw new Error('twap_tick_cumulatives_invalid');
  const tickCumulativeAgo = bigintValue(tickCumulatives[0], 'twap.tickCumulativeAgo');
  const tickCumulativeNow = bigintValue(tickCumulatives[1], 'twap.tickCumulativeNow');
  const meanTick = arithmeticMeanTick(tickCumulativeNow - tickCumulativeAgo, windowSeconds);
  return {
    windowSeconds,
    tickCumulativeAgo: tickCumulativeAgo.toString(),
    tickCumulativeNow: tickCumulativeNow.toString(),
    arithmeticMeanTick: meanTick,
    sqrtPriceX96: getSqrtRatioAtTick(meanTick).toString(),
  };
}

async function readReferenceUsd(
  rpc: EligibilityRpcClient,
  config: QuoteEligibilityConfig,
  referenceToken: string,
  latestBlockTimestamp: number,
  blockTag: string,
): Promise<ReferenceUsdEvidence | null> {
  if (config.stableUsdTokens.has(referenceToken)) {
    return {
      source: 'stable_allowlist',
      token: referenceToken,
      blockTimestamp: latestBlockTimestamp,
      priceUsd: serializeBaseRatio(makeRatio(1n, 1n)),
    };
  }

  const feedConfig = config.chainlinkFeeds.get(referenceToken);
  if (!feedConfig) return null;

  const [decimalsRaw, roundRaw] = await Promise.all([
    rpc.callContract(feedConfig.feed, CHAINLINK_IFACE, 'decimals', [], blockTag),
    rpc.callContract(feedConfig.feed, CHAINLINK_IFACE, 'latestRoundData', [], blockTag),
  ]);
  const feedDecimals = safeNumber(bigintValue(decimalsRaw[0], 'feed.decimals'), 'feed.decimals');
  if (feedDecimals > 36) throw new Error('feed_decimals_unsupported');
  const [roundId, answer, , updatedAt, answeredInRound] = roundRaw;
  const parsedAnswer = bigintValue(answer, 'feed.answer');
  const parsedUpdatedAt = safeNumber(bigintValue(updatedAt, 'feed.updatedAt'), 'feed.updatedAt');
  if (parsedAnswer <= 0n) throw new Error('feed_answer_non_positive');
  if (parsedUpdatedAt <= 0) throw new Error('feed_updated_at_missing');
  if (bigintValue(answeredInRound, 'feed.answeredInRound') < bigintValue(roundId, 'feed.roundId')) throw new Error('feed_round_incomplete');
  if (parsedUpdatedAt > latestBlockTimestamp + 300) throw new Error('feed_timestamp_in_future');
  if (latestBlockTimestamp - parsedUpdatedAt > feedConfig.maxAgeSeconds) throw new Error('feed_price_stale');

  return {
    source: 'chainlink_feed',
    token: referenceToken,
    feed: feedConfig.feed,
    answer: parsedAnswer.toString(),
    decimals: feedDecimals,
    updatedAt: parsedUpdatedAt,
    blockTimestamp: latestBlockTimestamp,
    maxAgeSeconds: feedConfig.maxAgeSeconds,
    priceUsd: serializeBaseRatio(makeRatio(parsedAnswer, pow10(feedDecimals))),
  };
}

async function readTokenDecimals(rpc: EligibilityRpcClient, token: string, blockTag: string): Promise<number | null> {
  try {
    const raw = await rpc.callContract(token, ERC20_IFACE, 'decimals', [], blockTag);
    return safeNumber(bigintValue(raw[0], 'token.decimals'), 'token.decimals');
  } catch {
    return null;
  }
}

async function readTokenBalanceOf(rpc: EligibilityRpcClient, token: string, account: string, blockTag: string): Promise<bigint | null> {
  try {
    const raw = await rpc.callContract(token, ERC20_IFACE, 'balanceOf', [account], blockTag);
    return bigintValue(raw[0], 'token.balanceOf');
  } catch {
    return null;
  }
}

async function readExecutableDepthEvidence(params: {
  rpc: EligibilityRpcClient;
  config: QuoteEligibilityConfig;
  blockTag: string;
  quoteToken: string;
  referenceToken: string;
  referencePool: string;
  poolFee: number;
  quoteDecimals: number;
  referenceDecimals: number;
  quoteUsd: Rational;
  referenceUsd: Rational;
  quotePoolBalanceRaw: bigint;
}): Promise<LiquidityEvidence> {
  const {
    rpc,
    config,
    blockTag,
    quoteToken,
    referenceToken,
    referencePool: _referencePool,
    poolFee,
    quoteDecimals,
    referenceDecimals,
    quoteUsd,
    referenceUsd,
    quotePoolBalanceRaw,
  } = params;
  const targetQuoteRaw = rawAmountForUsd(config.minQuoteDepthUsd, quoteUsd, quoteDecimals);
  if (targetQuoteRaw <= 0n) throw new Error('target_quote_raw_zero');

  const referenceToQuoteRaw = await rpc.callContract(
    config.quoterV2Address,
    QUOTER_V2_IFACE,
    'quoteExactOutputSingle',
    [[referenceToken, quoteToken, targetQuoteRaw, poolFee, 0n]],
    blockTag,
  );
  const quoteToReferenceRaw = await rpc.callContract(
    config.quoterV2Address,
    QUOTER_V2_IFACE,
    'quoteExactInputSingle',
    [[quoteToken, referenceToken, targetQuoteRaw, poolFee, 0n]],
    blockTag,
  );

  const referenceInputRaw = bigintValue(referenceToQuoteRaw[0], 'quoter.referenceToQuote.amountIn');
  const referenceToQuoteSqrtAfter = bigintValue(referenceToQuoteRaw[1], 'quoter.referenceToQuote.sqrtPriceX96After');
  const referenceToQuoteTicksCrossed = safeNumber(bigintValue(referenceToQuoteRaw[2], 'quoter.referenceToQuote.initializedTicksCrossed'), 'quoter.referenceToQuote.initializedTicksCrossed');
  const referenceOutputRaw = bigintValue(quoteToReferenceRaw[0], 'quoter.quoteToReference.amountOut');
  const quoteToReferenceSqrtAfter = bigintValue(quoteToReferenceRaw[1], 'quoter.quoteToReference.sqrtPriceX96After');
  const quoteToReferenceTicksCrossed = safeNumber(bigintValue(quoteToReferenceRaw[2], 'quoter.quoteToReference.initializedTicksCrossed'), 'quoter.quoteToReference.initializedTicksCrossed');

  const quotePoolBalanceUsd = tokenRawValueUsd(quotePoolBalanceRaw, quoteDecimals, quoteUsd);
  const targetQuoteUsd = tokenRawValueUsd(targetQuoteRaw, quoteDecimals, quoteUsd);
  const referenceInputUsd = tokenRawValueUsd(referenceInputRaw, referenceDecimals, referenceUsd);
  const referenceOutputUsd = tokenRawValueUsd(referenceOutputRaw, referenceDecimals, referenceUsd);
  const referenceToQuoteMaxInputUsd = ratioByBps(config.minQuoteDepthUsd, 10_000 + config.maxPriceImpactBps);
  const quoteToReferenceMinOutputUsd = ratioByBps(config.minQuoteDepthUsd, 10_000 - config.maxPriceImpactBps);

  return {
    rule: 'pancake_v3_quoter_v2_exact_output_and_reverse_exact_input',
    targetQuoteRaw: targetQuoteRaw.toString(),
    targetQuoteDecimal: formatTokenAmount(targetQuoteRaw, quoteDecimals),
    targetQuoteUsd: serializeRatio(targetQuoteUsd),
    quotePoolBalanceRaw: quotePoolBalanceRaw.toString(),
    quotePoolBalanceDecimal: formatTokenAmount(quotePoolBalanceRaw, quoteDecimals),
    quotePoolBalanceUsd: serializeRatio(quotePoolBalanceUsd),
    referenceToQuoteInputRaw: referenceInputRaw.toString(),
    referenceToQuoteInputDecimal: formatTokenAmount(referenceInputRaw, referenceDecimals),
    referenceToQuoteInputUsd: serializeRatio(referenceInputUsd),
    referenceToQuoteMaxInputUsd: serializeRatio(referenceToQuoteMaxInputUsd),
    referenceToQuoteSqrtPriceX96After: referenceToQuoteSqrtAfter.toString(),
    referenceToQuoteInitializedTicksCrossed: referenceToQuoteTicksCrossed,
    quoteToReferenceOutputRaw: referenceOutputRaw.toString(),
    quoteToReferenceOutputDecimal: formatTokenAmount(referenceOutputRaw, referenceDecimals),
    quoteToReferenceOutputUsd: serializeRatio(referenceOutputUsd),
    quoteToReferenceMinOutputUsd: serializeRatio(quoteToReferenceMinOutputUsd),
    quoteToReferenceSqrtPriceX96After: quoteToReferenceSqrtAfter.toString(),
    quoteToReferenceInitializedTicksCrossed: quoteToReferenceTicksCrossed,
    maxPriceImpactBps: config.maxPriceImpactBps,
    minQuoteDepthUsd: serializeRatio(config.minQuoteDepthUsd),
  };
}

function referencePerQuotePrice(sqrtPriceX96: bigint, quoteIsToken0: boolean, quoteDecimals: number, referenceDecimals: number): Rational {
  if (sqrtPriceX96 <= 0n) throw new Error('sqrt_price_zero');
  const squared = sqrtPriceX96 * sqrtPriceX96;
  const quoteScale = pow10(quoteDecimals);
  const referenceScale = pow10(referenceDecimals);
  return quoteIsToken0
    ? makeRatio(squared * quoteScale, Q192 * referenceScale)
    : makeRatio(Q192 * quoteScale, squared * referenceScale);
}

function inverseRatio(value: Rational): Rational {
  if (value.numerator === 0n) throw new Error('ratio_zero_inverse');
  return makeRatio(value.denominator, value.numerator);
}

function arithmeticMeanTick(delta: bigint, windowSeconds: number) {
  const divisor = BigInt(windowSeconds);
  let mean = delta / divisor;
  if (delta < 0n && delta % divisor !== 0n) mean -= 1n;
  return signedSafeNumber(mean, 'twap.meanTick');
}

function safeTokenDecimals(value: number) {
  return Number.isInteger(value) && value >= 0 && value <= 36;
}

function validateRpcUrl(value: string) {
  const parsed = new URL(value);
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') throw new Error('BSC_HTTP_RPC_URL_invalid');
}

function normalizeHash(value: string): string | null {
  const trimmed = value.trim();
  if (!/^0x[0-9a-fA-F]{64}$/.test(trimmed)) return null;
  return trimmed.toLowerCase();
}

function parseAllowedPoolFees(value: string) {
  const fees = value.split(',').map((part) => {
    const trimmed = part.trim();
    if (!/^\d+$/.test(trimmed)) throw new Error('QUOTE_ELIGIBILITY_ALLOWED_POOL_FEES_invalid');
    const fee = Number(trimmed);
    if (!Number.isSafeInteger(fee) || fee <= 0 || fee > 1_000_000) throw new Error('QUOTE_ELIGIBILITY_ALLOWED_POOL_FEES_invalid');
    return fee;
  });
  if (fees.length === 0) throw new Error('QUOTE_ELIGIBILITY_ALLOWED_POOL_FEES_required');
  return [...new Set(fees)];
}

function parseAddressSet(value: string, field: string) {
  const addresses = value.split(',').map((part) => part.trim()).filter(Boolean);
  const normalized = addresses.map((address) => {
    const parsed = normalizeAddress(address);
    if (!parsed) throw new Error(`${field}_invalid`);
    return parsed;
  });
  return new Set(normalized);
}

function parseChainlinkFeeds(value: string) {
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error('QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON_invalid');
  }
  if (!isRecord(parsed)) throw new Error('QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON_invalid');
  const feeds = new Map<string, QuoteEligibilityChainlinkFeed>();
  for (const [rawToken, rawConfig] of Object.entries(parsed)) {
    const token = normalizeAddress(rawToken);
    if (!token) throw new Error('QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON_token_invalid');
    let feed: string | null = null;
    let maxAgeSeconds = 3_600;
    if (typeof rawConfig === 'string') {
      feed = normalizeAddress(rawConfig);
    } else if (isRecord(rawConfig)) {
      feed = normalizeAddress(String(rawConfig.feed ?? ''));
      if (rawConfig.maxAgeSeconds !== undefined) {
        const rawMaxAge = Number(rawConfig.maxAgeSeconds);
        if (!Number.isSafeInteger(rawMaxAge) || rawMaxAge < 1 || rawMaxAge > 604_800) {
          throw new Error('QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON_maxAgeSeconds_invalid');
        }
        maxAgeSeconds = rawMaxAge;
      }
    }
    if (!feed) throw new Error('QUOTE_ELIGIBILITY_CHAINLINK_FEEDS_JSON_feed_invalid');
    feeds.set(token, { feed, maxAgeSeconds });
  }
  return feeds;
}

function integerEnv(env: NodeJS.ProcessEnv, name: string, fallback: number, minimum: number, maximum: number) {
  const raw = env[name];
  if (raw === undefined || raw.trim() === '') return fallback;
  if (!/^\d+$/.test(raw)) throw new Error(`${name}_invalid`);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`${name}_invalid`);
  return value;
}

export function normalizeAddress(value: string): string | null {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) return null;
  try {
    return getAddress(value).toLowerCase();
  } catch {
    return null;
  }
}

function makeRatio(numerator: bigint, denominator: bigint): Rational {
  if (denominator <= 0n) throw new Error('ratio_denominator_invalid');
  if (numerator < 0n) throw new Error('ratio_negative');
  const divisor = gcd(numerator, denominator);
  return {
    numerator: numerator / divisor,
    denominator: denominator / divisor,
  };
}

function multiplyRatio(left: Rational, right: Rational) {
  return makeRatio(left.numerator * right.numerator, left.denominator * right.denominator);
}

function minRatio(left: Rational, right: Rational) {
  return compareRatio(left, right) <= 0 ? left : right;
}

function ratioByBps(value: Rational, bps: number) {
  return makeRatio(value.numerator * BigInt(bps), value.denominator * 10_000n);
}

function tokenRawValueUsd(raw: bigint, decimals: number, tokenUsd: Rational) {
  return multiplyRatio(makeRatio(raw, pow10(decimals)), tokenUsd);
}

function rawAmountForUsd(usd: Rational, tokenUsd: Rational, decimals: number) {
  if (tokenUsd.numerator <= 0n) throw new Error('token_usd_zero');
  return ceilDiv(usd.numerator * tokenUsd.denominator * pow10(decimals), usd.denominator * tokenUsd.numerator);
}

function ceilDiv(numerator: bigint, denominator: bigint) {
  if (denominator <= 0n) throw new Error('ceil_div_denominator_invalid');
  return numerator === 0n ? 0n : ((numerator - 1n) / denominator) + 1n;
}

function compareRatio(left: Rational, right: Rational) {
  const lhs = left.numerator * right.denominator;
  const rhs = right.numerator * left.denominator;
  return lhs === rhs ? 0 : lhs < rhs ? -1 : 1;
}

function compareSerializedRatio(left: SerializedRational, right: SerializedRational) {
  return compareRatio(parseSerializedRational(left), parseSerializedRational(right));
}

function serializeRatio(value: Rational): SerializedRationalWithDecimal {
  return {
    ...serializeBaseRatio(value),
    decimalApprox: formatRatio(value, 18),
  };
}

function serializeBaseRatio(value: Rational): SerializedRational {
  return {
    numerator: value.numerator.toString(),
    denominator: value.denominator.toString(),
  };
}

function parseDecimalRational(value: string, field: string): Rational {
  const trimmed = value.trim();
  if (!/^\d+(?:\.\d{1,18})?$/.test(trimmed)) throw new Error(`${field}_invalid`);
  const [whole, fraction = ''] = trimmed.split('.');
  const numerator = BigInt(`${whole}${fraction}`);
  return makeRatio(numerator, pow10(fraction.length));
}

function formatRatio(value: Rational, precision: number) {
  const integer = value.numerator / value.denominator;
  let remainder = value.numerator % value.denominator;
  if (remainder === 0n || precision === 0) return integer.toString();
  let fraction = '';
  for (let i = 0; i < precision && remainder !== 0n; i += 1) {
    remainder *= 10n;
    fraction += (remainder / value.denominator).toString();
    remainder %= value.denominator;
  }
  return `${integer}.${fraction.replace(/0+$/, '') || '0'}`;
}

function formatTokenAmount(raw: bigint, decimals: number) {
  return formatRatio(makeRatio(raw, pow10(decimals)), 18);
}

function pow10(decimals: number) {
  return 10n ** BigInt(decimals);
}

function gcd(left: bigint, right: bigint): bigint {
  let a = left;
  let b = right;
  while (b !== 0n) {
    const next = a % b;
    a = b;
    b = next;
  }
  return a === 0n ? 1n : a;
}

function slot0Values(values: readonly unknown[]) {
  if (values.length < 7) throw new Error('slot0_invalid');
  return {
    sqrtPriceX96: values[0],
    tick: values[1],
    observationIndex: values[2],
    observationCardinality: values[3],
    observationCardinalityNext: values[4],
    unlocked: values[6],
  };
}

function bigintValue(value: unknown, field: string) {
  if (typeof value !== 'bigint') throw new Error(`${field}_invalid`);
  return value;
}

function stringValue(value: unknown, field: string) {
  if (typeof value !== 'string') throw new Error(`${field}_invalid`);
  return value;
}

function booleanValue(value: unknown, field: string) {
  if (typeof value !== 'boolean') throw new Error(`${field}_invalid`);
  return value;
}

function safeNumber(value: bigint, field: string) {
  const number = Number(value);
  if (!Number.isSafeInteger(number) || number < 0) throw new Error(`${field}_invalid`);
  return number;
}

function signedSafeNumber(value: bigint, field: string) {
  const number = Number(value);
  if (!Number.isSafeInteger(number)) throw new Error(`${field}_invalid`);
  return number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function safeError(error: unknown) {
  if (!(error instanceof Error)) return 'unknown_error';
  return error.message.replace(/[^a-zA-Z0-9_:.-]/g, '_').slice(0, 160);
}

class EligibilityRpcClient {
  private nextId = 1;
  private readonly url: string;
  private readonly fetchImpl: FetchLike;
  private readonly timeoutMs: number;
  private readonly maxAttempts: number;

  constructor(
    url: string,
    fetchImpl: FetchLike,
    timeoutMs: number,
    maxAttempts: number,
  ) {
    this.url = url;
    this.fetchImpl = fetchImpl;
    this.timeoutMs = timeoutMs;
    this.maxAttempts = maxAttempts;
  }

  async getChainId() {
    return Number(parseQuantity(await this.request('eth_chainId', []), 'eth_chainId'));
  }

  async getLatestBlock() {
    const block = await this.request('eth_getBlockByNumber', ['latest', false]);
    if (!isRecord(block)) throw new Error('latest_block_invalid');
    const number = parseQuantity(block.number, 'block.number');
    return {
      number,
      tag: toQuantity(number),
      timestamp: safeNumber(parseQuantity(block.timestamp, 'block.timestamp'), 'block.timestamp'),
    };
  }

  async getCode(address: string, blockTag: string) {
    return parseData(await this.request('eth_getCode', [address, blockTag]), 'eth_getCode');
  }

  async callContract(address: string, contractInterface: Interface, functionName: string, args: readonly unknown[], blockTag: string) {
    const data = contractInterface.encodeFunctionData(functionName, args);
    const raw = parseData(await this.request('eth_call', [{ to: address, data }, blockTag]), 'eth_call');
    return contractInterface.decodeFunctionResult(functionName, raw).toArray();
  }

  private async request(method: string, params: readonly unknown[]): Promise<unknown> {
    const id = this.nextId;
    this.nextId += 1;
    let lastError: unknown;
    for (let attempt = 0; attempt < this.maxAttempts; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const response = await this.fetchImpl(this.url, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),
          signal: controller.signal,
        });
        if (!response.ok) throw new Error(`rpc_http_${response.status}`);
        const payload = await response.json() as {
          jsonrpc?: unknown;
          id?: unknown;
          result?: unknown;
          error?: { code?: unknown };
        };
        if (payload.id !== id || payload.jsonrpc !== '2.0') throw new Error('rpc_response_mismatch');
        if (payload.error) {
          const code = typeof payload.error.code === 'number' ? payload.error.code : 'unknown';
          throw new Error(`rpc_error_${code}`);
        }
        return payload.result;
      } catch (error) {
        lastError = error;
        if (attempt + 1 >= this.maxAttempts) break;
        await new Promise((resolve) => setTimeout(resolve, Math.min(2_000, 250 * (2 ** attempt))));
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError instanceof Error ? lastError : new Error('rpc_request_failed');
  }
}

function parseQuantity(value: unknown, field: string) {
  if (typeof value !== 'string' || !/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value)) throw new Error(`${field}_invalid`);
  return BigInt(value);
}

function toQuantity(value: bigint) {
  if (value < 0n) throw new Error('quantity_negative');
  return `0x${value.toString(16)}`;
}

function parseData(value: unknown, field: string) {
  if (typeof value !== 'string' || !/^0x(?:[0-9a-fA-F]{2})*$/.test(value)) throw new Error(`${field}_invalid`);
  return value.toLowerCase();
}

function getSqrtRatioAtTick(tick: number) {
  if (tick < MIN_TICK || tick > MAX_TICK) throw new Error('tick_out_of_range');
  const absTick = tick < 0 ? -tick : tick;
  let ratio = (absTick & 0x1) !== 0
    ? 0xfffcb933bd6fad37aa2d162d1a594001n
    : 0x100000000000000000000000000000000n;
  if ((absTick & 0x2) !== 0) ratio = (ratio * 0xfff97272373d413259a46990580e213an) >> 128n;
  if ((absTick & 0x4) !== 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdccn) >> 128n;
  if ((absTick & 0x8) !== 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0n) >> 128n;
  if ((absTick & 0x10) !== 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644n) >> 128n;
  if ((absTick & 0x20) !== 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0n) >> 128n;
  if ((absTick & 0x40) !== 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861n) >> 128n;
  if ((absTick & 0x80) !== 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053n) >> 128n;
  if ((absTick & 0x100) !== 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4n) >> 128n;
  if ((absTick & 0x200) !== 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54n) >> 128n;
  if ((absTick & 0x400) !== 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3n) >> 128n;
  if ((absTick & 0x800) !== 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9n) >> 128n;
  if ((absTick & 0x1000) !== 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825n) >> 128n;
  if ((absTick & 0x2000) !== 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5n) >> 128n;
  if ((absTick & 0x4000) !== 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7n) >> 128n;
  if ((absTick & 0x8000) !== 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6n) >> 128n;
  if ((absTick & 0x10000) !== 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9n) >> 128n;
  if ((absTick & 0x20000) !== 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604n) >> 128n;
  if ((absTick & 0x40000) !== 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98n) >> 128n;
  if ((absTick & 0x80000) !== 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2n) >> 128n;
  if (tick > 0) ratio = ((1n << 256n) - 1n) / ratio;
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}
