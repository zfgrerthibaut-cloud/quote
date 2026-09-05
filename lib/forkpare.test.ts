import assert from 'node:assert/strict';
import test from 'node:test';

import { buildPriceRange } from './forkpare.ts';

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
