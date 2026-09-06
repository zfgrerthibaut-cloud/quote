import assert from 'node:assert/strict';
import test from 'node:test';

import { listMarkets, parseMarketListQuery } from '../src/infra/postgres-markets.ts';

test('parses an exact quote-address filter with the other market controls', () => {
  const quote = '0xE5Ae318389B8D6d09370A675479c64862152D126';
  const query = parseMarketListQuery(new URL(
    `https://api.quote.test/v1/markets?sort=newest&engine=direct&reward=1&quote=${quote}&q=baba&limit=999`,
  ));

  assert.deepEqual(query, {
    sort: 'newest',
    engine: 'direct',
    rewardOnly: true,
    quoteAddress: quote.toLowerCase(),
    search: 'baba',
    limit: 100,
    cursor: null,
  });
});

test('fails closed to no quote filter for malformed addresses', () => {
  const query = parseMarketListQuery(new URL(
    'https://api.quote.test/v1/markets?quote=0x1234&limit=not-a-number',
  ));

  assert.equal(query.quoteAddress, null);
  assert.equal(query.limit, 30);
});

test('markets API computes displayed 24h volume from canonical trades on the selected page', async () => {
  const client = new FakeMarketClient([{
    chain_id: '56',
    launch_id: '7',
    launchpad: '0x1111111111111111111111111111111111111111',
    token_address: '0x2222222222222222222222222222222222222222',
    quote_address: '0x3333333333333333333333333333333333333333',
    market_address: '0x4444444444444444444444444444444444444444',
    creator_address: '0x5555555555555555555555555555555555555555',
    engine: 'direct',
    reward: false,
    token_name: 'Mars Coin',
    token_symbol: 'MARS',
    quote_symbol: 'BABA',
    effective_quote_decimals: 18,
    legacy_supply_raw: '1000000000000000000000',
    requested_supply_raw: '1000000000000000000000',
    deposited_supply_raw: '1000000000000000000000',
    target_fdv_usd: '7000',
    target_fdv_usd_wad: '7000000000000000000000',
    quote_price_usd: '1',
    quote_price_usd_wad: '1000000000000000000',
    quote_price_status: 'launch_attestation_as_of',
    market_cap_usd: '7100',
    market_cap_source: 'last_pool_swap_at_launch_quote',
    volume_24h_usd: '250',
    quote_volume_raw_24h: '250000000000000000000',
    volume_24h_from: new Date('2026-09-05T10:00:00.000Z'),
    volume_24h_as_of: new Date('2026-09-06T10:00:00.000Z'),
    liquidity_usd: null,
    total_trade_count: '3',
    buy_trade_count: '2',
    sell_trade_count: '1',
    last_price_numerator_raw: '71',
    last_price_denominator_raw: '10',
    last_trade_at: new Date('2026-09-06T09:59:00.000Z'),
    creator_fee_bps: 0,
    reward_fee_bps: 0,
    creator_lp_share_bps: 2500,
    pool_fee: 10000,
    launch_block: '123',
    launch_log_index: 9,
    launch_tx_hash: '0x6666666666666666666666666666666666666666666666666666666666666666',
    launched_at: new Date('2026-09-06T09:00:00.000Z'),
    updated_at: new Date('2026-09-06T10:00:00.000Z'),
    sort_value: '7100',
  }]);

  const response = await listMarkets({ connect: async () => client } as never, parseMarketListQuery(new URL(
    'https://api.quote.test/v1/markets?sort=volume_24h&engine=direct&limit=30',
  )));

  assert.equal(response.markets[0]?.volume24hUsd, '250');
  assert.equal(response.markets[0]?.volume24hQuoteRaw, '250000000000000000000');
  assert.equal(response.markets[0]?.marketCapSource, 'last_pool_swap_at_launch_quote');
  assert.equal(response.markets[0]?.quotePriceIsLive, false);
  assert.match(client.marketSql, /LEFT JOIN LATERAL/);
  assert.match(client.marketSql, /sort_rolling\.quote_volume_raw_24h/);
  assert.match(client.marketSql, /market_trade_events AS trade/);
  assert.match(client.marketSql, /trade\.canonical/);
  assert.match(client.marketSql, /trade\.trade_time >= \$2::timestamptz - interval '24 hours'/);
  assert.equal(client.marketValues[1] instanceof Date, true);
});

class FakeMarketClient {
  marketSql = '';
  marketValues: unknown[] = [];
  private readonly marketRows: Record<string, unknown>[];

  constructor(marketRows: Record<string, unknown>[]) {
    this.marketRows = marketRows;
  }

  async query(sql: string, values: unknown[] = []) {
    if (sql.includes('COALESCE(max(id), 0)::text')) {
      return { rows: [{ id: '12', snapshot_at: new Date('2026-09-06T10:00:00.000Z') }] };
    }
    if (sql.includes('WITH filtered AS')) {
      this.marketSql = sql;
      this.marketValues = values;
      return { rows: this.marketRows };
    }
    return { rows: [] };
  }

  release() {}
}
