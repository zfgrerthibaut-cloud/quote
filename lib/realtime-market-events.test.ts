import assert from 'node:assert/strict';
import test from 'node:test';

import { normalizeRealtimeMessage } from './realtime-market-events.ts';

test('unwraps backend outbox envelopes and data.args payloads', () => {
  const normalized = normalizeRealtimeMessage({
    id: 42,
    type: 'market.upsert',
    data: {
      args: {
        marketAddress: '0x1111111111111111111111111111111111111111',
        tokenSymbol: 'MARS',
      },
    },
  });

  assert.equal(normalized.id, '42');
  assert.equal(normalized.type, 'market.upsert');
  assert.deepEqual(normalized.payload, {
    marketAddress: '0x1111111111111111111111111111111111111111',
    tokenSymbol: 'MARS',
  });
  assert.equal(normalized.shouldRefetch, false);
});

test('marks trade upserts and reorg rebuilds as snapshot refetch events', () => {
  const trade = normalizeRealtimeMessage({
    id: '103',
    type: 'market.trade.upsert',
    data: { args: { marketAddress: '0x2222222222222222222222222222222222222222' } },
  });
  const reorg = normalizeRealtimeMessage({ type: 'chain.reorg', data: { depth: 2 } });
  const rebuilt = normalizeRealtimeMessage({ type: 'markets.rebuilt', data: { generation: 9 } });

  assert.equal(trade.shouldRefetch, true);
  assert.equal(reorg.shouldRefetch, true);
  assert.equal(rebuilt.shouldRefetch, true);
});
