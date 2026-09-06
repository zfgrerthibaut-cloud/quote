import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeEventLog, encodeAbiParameters, encodeEventTopics } from 'viem';

import {
  buildPriceRange,
  FEE_TICK_SPACING,
  quoteFactoryAbi,
  getTickAtSqrtRatio,
  sqrtRatioAtTick,
} from './quote.ts';

const Q96 = 1n << 96n;

test('builds exact 1:1 raw boundary in both token orders', () => {
  const token0 = buildPriceRange('1', 18, true);
  const token1 = buildPriceRange('1', 18, false);

  assert.equal(token0.sqrtPriceX96, Q96);
  assert.equal(token0.tickLower, 0);
  assert.equal(token0.tickUpper, 887_200);
  assert.equal(token1.sqrtPriceX96, Q96);
  assert.equal(token1.tickLower, -887_200);
  assert.equal(token1.tickUpper, 0);
});

test('accounts for quote decimals without floating point amount parsing', () => {
  const token0 = buildPriceRange('1.25', 6, true);
  const token1 = buildPriceRange('1.25', 6, false);

  assert.ok(token0.sqrtPriceX96 < Q96);
  assert.ok(token1.sqrtPriceX96 > Q96);
  assert.equal(Math.abs(token0.tickLower % 10), 0);
  assert.equal(Math.abs(token1.tickUpper % 10), 0);
});

test('aligns launch boundaries for every supported Pancake fee tier', () => {
  for (const spacing of Object.values(FEE_TICK_SPACING)) {
    const token0 = buildPriceRange('0.000001', 18, true, spacing);
    const token1 = buildPriceRange('0.000001', 18, false, spacing);
    assert.equal(Math.abs(token0.tickLower % spacing), 0);
    assert.equal(Math.abs(token0.tickUpper % spacing), 0);
    assert.equal(Math.abs(token1.tickLower % spacing), 0);
    assert.equal(Math.abs(token1.tickUpper % spacing), 0);
  }
});

test('round-trips canonical V3 ticks without floating point math', () => {
  for (const tick of [-887_271, -500_000, -138_163, -1, 0, 1, 138_162, 500_000, 887_271]) {
    const sqrtPriceX96 = sqrtRatioAtTick(tick);
    assert.equal(getTickAtSqrtRatio(sqrtPriceX96), tick);
    if (tick > -887_272) assert.equal(getTickAtSqrtRatio(sqrtPriceX96 - 1n), tick - 1);
  }
});

test('rejects V3 sqrt-ratio endpoints exactly', () => {
  assert.throws(() => getTickAtSqrtRatio(sqrtRatioAtTick(-887_272) - 1n), /price_out_of_range/);
  assert.throws(() => getTickAtSqrtRatio(sqrtRatioAtTick(887_272)), /price_out_of_range/);
});

test('rejects unsupported metadata decimals and zero price', () => {
  assert.throws(() => buildPriceRange('1', 37, true), /unsupported_decimals/);
  assert.throws(() => buildPriceRange('0', 18, true), /zero_price/);
});

test('decodes the exact MarketLaunched receipt used by the UI', () => {
  const creator = '0x1111111111111111111111111111111111111111';
  const token = '0x2222222222222222222222222222222222222222';
  const quoteToken = '0x3333333333333333333333333333333333333333';
  const pool = '0x4444444444444444444444444444444444444444';
  const locker = '0x5555555555555555555555555555555555555555';
  const topics = encodeEventTopics({
    abi: quoteFactoryAbi,
    eventName: 'MarketLaunched',
    args: { launchId: 7n, creator, token },
  });
  const data = encodeAbiParameters(
    [
      { type: 'address' }, { type: 'address' }, { type: 'address' },
      { type: 'uint256' }, { type: 'uint256' }, { type: 'uint160' },
      { type: 'int24' }, { type: 'int24' }, { type: 'uint24' },
    ],
    [quoteToken, pool, locker, 99n, 100_000_000n * 10n ** 18n, Q96, 0, 887_200, 10_000],
  );

  const decoded = decodeEventLog({ abi: quoteFactoryAbi, eventName: 'MarketLaunched', topics, data });
  assert.equal(decoded.args.token, token);
  assert.equal(decoded.args.pool, pool);
  assert.equal(decoded.args.locker, locker);
});
