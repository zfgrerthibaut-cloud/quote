import assert from 'node:assert/strict';
import test from 'node:test';
import { assertContiguous, compareLogs, dedupeLogs, findCommonAncestor, retryDelayMs, type ChainBlock } from '../src/domain/reorg.ts';

const h = (value: string) => `0x${value.padStart(64, '0')}` as `0x${string}`;
const block = (number: bigint, hash: string, parent: string): ChainBlock => ({ number, hash: h(hash), parentHash: h(parent) });

test('finds the last shared block before a reorg', () => {
  const canonical = [block(10n, '10', '09'), block(11n, '11a', '10'), block(12n, '12a', '11a')];
  const replacement = [block(10n, '10', '09'), block(11n, '11b', '10'), block(12n, '12b', '11b')];
  assert.equal(findCommonAncestor(canonical, replacement)?.hash, h('10'));
});

test('rejects gaps and incorrect parent hashes before commit', () => {
  assert.throws(() => assertContiguous([block(12n, '12', '11'), block(14n, '14', '13')]), /non_contiguous_chain/);
  assert.throws(() => assertContiguous([block(12n, '12', 'bad')], h('11')), /unexpected_parent/);
});

test('deduplicates logs and retains canonical EVM ordering', () => {
  const logs = [
    { blockNumber: 4n, transactionIndex: 1, logIndex: 2, transactionHash: h('b') },
    { blockNumber: 4n, transactionIndex: 0, logIndex: 3, transactionHash: h('a') },
    { blockNumber: 4n, transactionIndex: 1, logIndex: 2, transactionHash: h('b') },
  ];
  const result = dedupeLogs(logs);
  assert.equal(result.length, 2);
  assert.ok(compareLogs(result[0], result[1]) < 0);
});

test('bounds exponential media retry delay with deterministic jitter', () => {
  assert.equal(retryDelayMs(0, 0), 800);
  assert.equal(retryDelayMs(2, 0.5), 4_000);
  assert.ok(retryDelayMs(99, 1) <= 300_000);
});
