import assert from 'node:assert/strict';
import test from 'node:test';
import { decodeEventLog, encodeAbiParameters, encodeEventTopics } from 'viem';

import { buildPriceRange, forkPareFactoryAbi } from './forkpare.ts';

const Q96 = 1n << 96n;

test('builds exact 1:1 raw boundary in both token orders', () => {
  const token0 = buildPriceRange('1', 18, true);
  const token1 = buildPriceRange('1', 18, false);

  assert.equal(token0.sqrtPriceX96, Q96);
  assert.equal(token0.tickLower, 0);
  assert.equal(token0.tickUpper, 887_270);
  assert.equal(token1.sqrtPriceX96, Q96);
  assert.equal(token1.tickLower, -887_270);
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
    abi: forkPareFactoryAbi,
    eventName: 'MarketLaunched',
    args: { launchId: 7n, creator, token },
  });
  const data = encodeAbiParameters(
    [
      { type: 'address' }, { type: 'address' }, { type: 'address' },
      { type: 'uint256' }, { type: 'uint256' }, { type: 'uint160' },
      { type: 'int24' }, { type: 'int24' }, { type: 'uint24' },
    ],
    [quoteToken, pool, locker, 99n, 100_000_000n * 10n ** 18n, Q96, 0, 887_270, 500],
  );

  const decoded = decodeEventLog({ abi: forkPareFactoryAbi, eventName: 'MarketLaunched', topics, data });
  assert.equal(decoded.args.token, token);
  assert.equal(decoded.args.pool, pool);
  assert.equal(decoded.args.locker, locker);
});
