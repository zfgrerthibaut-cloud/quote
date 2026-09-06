import type { Pool } from 'pg';

import { clampOutboxEventId } from './outbox-id.ts';

export type MarketSort = 'market_cap' | 'newest' | 'volume_24h';
export type MarketEngineFilter = 'direct' | 'curve' | null;

export type MarketListQuery = Readonly<{
  sort: MarketSort;
  engine: MarketEngineFilter;
  rewardOnly: boolean;
  quoteAddress: string | null;
  search: string;
  limit: number;
  cursor: string | null;
}>;

type CursorPayload = Readonly<{
  v: 1;
  sort: MarketSort;
  value: string | null;
  launchId: string;
}>;

type MarketRow = Record<string, unknown> & {
  launch_id: string;
  sort_value: string | null;
};

const SORT_COLUMNS: Record<MarketSort, string> = {
  market_cap: 'sort_market_cap_usd',
  newest: 'sort_newest',
  volume_24h: 'sort_volume_24h_usd',
};

export function parseMarketListQuery(url: URL): MarketListQuery {
  const requestedSort = url.searchParams.get('sort');
  const sort: MarketSort = requestedSort === 'newest' || requestedSort === 'volume_24h' ? requestedSort : 'market_cap';
  const requestedEngine = url.searchParams.get('engine');
  const engine: MarketEngineFilter = requestedEngine === 'direct' || requestedEngine === 'curve' ? requestedEngine : null;
  const requestedLimit = Number(url.searchParams.get('limit') || 30);
  const limit = Number.isInteger(requestedLimit) ? Math.max(1, Math.min(requestedLimit, 100)) : 30;
  const search = (url.searchParams.get('q') || '').trim().slice(0, 128);
  const reward = url.searchParams.get('reward');
  const requestedQuote = (url.searchParams.get('quote') || '').trim().toLowerCase();
  const quoteAddress = /^0x[0-9a-f]{40}$/.test(requestedQuote) ? requestedQuote : null;
  return {
    sort,
    engine,
    rewardOnly: reward === 'true' || reward === '1',
    quoteAddress,
    search,
    limit,
    cursor: url.searchParams.get('cursor'),
  };
}

export async function listMarkets(pool: Pool, query: MarketListQuery) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const latest = await client.query('SELECT COALESCE(max(id), 0)::text AS id, clock_timestamp() AS snapshot_at FROM outbox');
    const rawSnapshotAt = latest.rows[0]?.snapshot_at;
    const snapshotAt = rawSnapshotAt instanceof Date
      ? rawSnapshotAt
      : typeof rawSnapshotAt === 'string'
        ? new Date(rawSnapshotAt)
        : new Date();
    const cursor = decodeCursor(query.cursor, query.sort);
    const values: unknown[] = [query.limit + 1, snapshotAt];
    const where: string[] = [];

    if (query.engine) {
      values.push(query.engine === 'direct' ? 1 : 2);
      where.push(`market.engine_kind = $${values.length}`);
    }
    if (query.rewardOnly) where.push('market.reward_fee_bps > 0');
    if (query.quoteAddress) {
      values.push(Buffer.from(query.quoteAddress.slice(2), 'hex'));
      where.push(`market.quote_token = $${values.length}`);
    }
    if (query.search) {
      values.push(`%${query.search.toLowerCase()}%`);
      const index = values.length;
      where.push(`(
        lower(COALESCE(token_meta.name, '')) LIKE $${index}
        OR lower(COALESCE(token_meta.symbol, '')) LIKE $${index}
        OR lower(COALESCE(quote_meta.name, '')) LIKE $${index}
        OR lower(COALESCE(quote_meta.symbol, '')) LIKE $${index}
        OR lower('0x' || encode(market.token, 'hex')) LIKE $${index}
        OR lower('0x' || encode(market.quote_token, 'hex')) LIKE $${index}
        OR lower('0x' || encode(market.market, 'hex')) LIKE $${index}
      )`);
    }

    const sortColumn = SORT_COLUMNS[query.sort];
    const volumeSortJoin = query.sort === 'volume_24h' ? `
        LEFT JOIN LATERAL (
          SELECT coalesce(sum(trade.quote_amount_raw), 0) AS quote_volume_raw_24h
          FROM market_trade_events AS trade
          WHERE trade.chain_id = market.chain_id
            AND trade.launchpad = market.launchpad
            AND trade.launch_id = market.launch_id
            AND trade.canonical
            AND trade.trade_time >= $2::timestamptz - interval '24 hours'
        ) AS sort_rolling ON true
    ` : '';
    const volumeSortExpression = query.sort === 'volume_24h'
      ? `CASE
          WHEN sort_rolling.quote_volume_raw_24h = 0 THEN 0::numeric
          ELSE quote_raw_usd_value(
            sort_rolling.quote_volume_raw_24h,
            market.quote_price_usd_wad,
            COALESCE(market.quote_decimals, quote_meta.decimals)
          )
        END`
      : 'COALESCE(stats.volume_24h_usd, market.volume_24h_usd)';
    const cursorWhere: string[] = [];
    if (cursor) {
      values.push(cursor.value, cursor.launchId);
      const valueIndex = values.length - 1;
      const launchIndex = values.length;
      cursorWhere.push(`(
        ($${valueIndex}::numeric IS NULL AND ${sortColumn} IS NULL AND launch_id < $${launchIndex}::numeric)
        OR ($${valueIndex}::numeric IS NOT NULL AND (
          ${sortColumn} < $${valueIndex}::numeric
          OR (${sortColumn} = $${valueIndex}::numeric AND launch_id < $${launchIndex}::numeric)
          OR ${sortColumn} IS NULL
        ))
      )`);
    }

    const result = await client.query(`
      WITH filtered AS (
        SELECT
          market.chain_id,
          market.launch_id,
          '0x' || encode(market.launchpad, 'hex') AS launchpad,
          '0x' || encode(market.token, 'hex') AS token_address,
          '0x' || encode(market.quote_token, 'hex') AS quote_address,
          '0x' || encode(market.market, 'hex') AS market_address,
          '0x' || encode(market.creator, 'hex') AS creator_address,
          CASE market.engine_kind WHEN 1 THEN 'direct' WHEN 2 THEN 'curve' END AS engine,
          market.reward_fee_bps > 0 AS reward,
          token_meta.name AS token_name,
          token_meta.symbol AS token_symbol,
          quote_meta.symbol AS quote_symbol,
          COALESCE(market.quote_decimals, quote_meta.decimals) AS effective_quote_decimals,
          market.supply::text AS legacy_supply_raw,
          market.requested_supply::text AS requested_supply_raw,
          COALESCE(market.deposited_supply, market.supply)::text AS deposited_supply_raw,
          market.target_fdv_usd_wad::text AS target_fdv_usd_wad,
          quote_wad_to_usd(market.target_fdv_usd_wad)::text AS target_fdv_usd,
          market.quote_price_usd_wad::text AS quote_price_usd_wad,
          quote_wad_to_usd(market.quote_price_usd_wad)::text AS quote_price_usd,
          market.quote_price_observed_at,
          market.quote_price_attested_deadline,
          market.quote_price_liquidity_usd_wad::text AS quote_price_liquidity_usd_wad,
          quote_wad_to_usd(market.quote_price_liquidity_usd_wad)::text AS quote_price_liquidity_usd,
          CASE WHEN market.quote_reference_token IS NULL THEN NULL ELSE '0x' || encode(market.quote_reference_token, 'hex') END AS quote_reference_token,
          CASE WHEN market.quote_reference_pool IS NULL THEN NULL ELSE '0x' || encode(market.quote_reference_pool, 'hex') END AS quote_reference_pool,
          CASE WHEN market.quote_price_attestation_digest IS NULL THEN NULL ELSE '0x' || encode(market.quote_price_attestation_digest, 'hex') END AS quote_price_attestation_digest,
          market.initial_sqrt_price_x96::text,
          market.tick_lower,
          market.tick_upper,
          market.pool_fee,
          CASE
            WHEN stats.last_price_numerator_raw IS NOT NULL THEN quote_market_cap_usd(
              COALESCE(market.deposited_supply, market.supply),
              stats.last_price_numerator_raw,
              stats.last_price_denominator_raw,
              market.quote_price_usd_wad,
              COALESCE(market.quote_decimals, quote_meta.decimals)
            )
            WHEN market.engine_kind = 1 THEN quote_wad_to_usd(market.target_fdv_usd_wad)
            ELSE market.market_cap_usd
          END AS sort_market_cap_usd,
          market.launch_block::numeric AS sort_newest,
          ${volumeSortExpression} AS sort_volume_24h_usd,
          CASE
            WHEN market.quote_price_usd_wad IS NULL THEN NULL
            WHEN market.quote_price_observed_at IS NULL THEN 'launch_attestation_without_timestamp'
            WHEN market.quote_price_attested_deadline IS NOT NULL AND market.quote_price_attested_deadline < $2::timestamptz THEN 'expired_launch_attestation'
            ELSE 'launch_attestation_as_of'
          END AS quote_price_status,
          stats.total_trade_count::text,
          stats.buy_trade_count::text,
          stats.sell_trade_count::text,
          stats.last_price_numerator_raw::text,
          stats.last_price_denominator_raw::text,
          stats.last_trade_at,
          market.creator_fee_bps,
          market.reward_fee_bps,
          market.creator_lp_share_bps,
          market.liquidity_usd::text AS liquidity_usd,
          market.launch_block,
          market.launch_log_index,
          '0x' || encode(market.launch_tx_hash, 'hex') AS launch_tx_hash,
          market.launched_at,
          COALESCE(stats.updated_at, market.updated_at) AS updated_at
        FROM markets AS market
        LEFT JOIN market_live_stats AS stats
          ON stats.chain_id = market.chain_id
          AND stats.launchpad = market.launchpad
          AND stats.launch_id = market.launch_id
        LEFT JOIN token_metadata AS token_meta
          ON token_meta.chain_id = market.chain_id AND token_meta.token_address = market.token
        LEFT JOIN token_metadata AS quote_meta
          ON quote_meta.chain_id = market.chain_id AND quote_meta.token_address = market.quote_token
        ${volumeSortJoin}
        ${where.length > 0 ? `WHERE ${where.join(' AND ')}` : ''}
      ),
      page AS (
        SELECT *
        FROM filtered
        ${cursorWhere.length > 0 ? `WHERE ${cursorWhere.join(' AND ')}` : ''}
        ORDER BY ${sortColumn} DESC NULLS LAST, launch_id DESC
        LIMIT $1
      )
      SELECT
        page.*,
        page.launch_id::text AS launch_id,
        CASE
          WHEN page.last_price_numerator_raw IS NOT NULL THEN quote_market_cap_usd(
            page.deposited_supply_raw::numeric,
            page.last_price_numerator_raw::numeric,
            page.last_price_denominator_raw::numeric,
            page.quote_price_usd_wad::numeric,
            page.effective_quote_decimals
          )
          WHEN page.engine = 'direct' THEN quote_wad_to_usd(page.target_fdv_usd_wad::numeric)
          ELSE page.sort_market_cap_usd
        END::text AS market_cap_usd,
        CASE
          WHEN page.last_price_numerator_raw IS NOT NULL AND quote_market_cap_usd(
            page.deposited_supply_raw::numeric,
            page.last_price_numerator_raw::numeric,
            page.last_price_denominator_raw::numeric,
            page.quote_price_usd_wad::numeric,
            page.effective_quote_decimals
          ) IS NOT NULL THEN 'last_pool_swap_at_launch_quote'
          WHEN page.last_price_numerator_raw IS NULL AND page.engine = 'direct' AND page.target_fdv_usd_wad IS NOT NULL THEN 'launch_target_fdv'
          WHEN page.engine <> 'direct' AND page.sort_market_cap_usd IS NOT NULL THEN 'legacy_projection'
          ELSE NULL
        END AS market_cap_source,
        rolling.quote_volume_raw_24h::text,
        CASE
          WHEN rolling.quote_volume_raw_24h = 0 THEN '0'
          ELSE quote_raw_usd_value(
            rolling.quote_volume_raw_24h,
            page.quote_price_usd_wad::numeric,
            page.effective_quote_decimals
          )::text
        END AS volume_24h_usd,
        ($2::timestamptz - interval '24 hours') AS volume_24h_from,
        $2::timestamptz AS volume_24h_as_of,
        rolling.last_trade_at_24h,
        page.${sortColumn}::text AS sort_value
      FROM page
      LEFT JOIN LATERAL (
        SELECT
          coalesce(sum(trade.quote_amount_raw), 0) AS quote_volume_raw_24h,
          max(trade.trade_time) AS last_trade_at_24h
        FROM market_trade_events AS trade
        WHERE trade.chain_id = page.chain_id
          AND trade.launchpad = decode(substr(page.launchpad, 3), 'hex')
          AND trade.launch_id = page.launch_id
          AND trade.canonical
          AND trade.trade_time >= $2::timestamptz - interval '24 hours'
      ) AS rolling ON true
      ORDER BY page.${sortColumn} DESC NULLS LAST, page.launch_id DESC
    `, values);
    await client.query('COMMIT');

    const rows = result.rows as MarketRow[];
    const hasMore = rows.length > query.limit;
    const page = rows.slice(0, query.limit);
    const last = hasMore ? page.at(-1) : null;
    return {
      markets: page.map(toApiMarket),
      latestEventId: String(latest.rows[0]?.id ?? '0'),
      nextCursor: last ? encodeCursor({ v: 1, sort: query.sort, value: last.sort_value, launchId: last.launch_id }) : null,
      snapshotAt: snapshotAt.toISOString(),
    };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw error;
  } finally {
    client.release();
  }
}

export async function readOutboxAfter(pool: Pool, after: bigint, limit = 500) {
  const boundedAfter = clampOutboxEventId(after);
  const result = await pool.query(
    `SELECT id::text, topic, aggregate_id, payload, created_at
     FROM outbox WHERE id > $1 ORDER BY id ASC LIMIT $2`,
    [boundedAfter.toString(), Math.max(1, Math.min(limit, 1_000))],
  );
  return result.rows.map((row) => ({
    schemaVersion: 1,
    id: String(row.id),
    type: String(row.topic),
    aggregateId: String(row.aggregate_id),
    occurredAt: row.created_at instanceof Date ? row.created_at.toISOString() : String(row.created_at),
    data: row.payload,
  }));
}

function toApiMarket(row: MarketRow) {
  const launchpad = String(row.launchpad);
  const launchId = String(row.launch_id);
  return {
    id: `${row.chain_id}:${launchpad}:${launchId}`,
    chainId: Number(row.chain_id),
    launchId,
    launchpad,
    marketAddress: row.market_address,
    tokenAddress: row.token_address,
    quoteAddress: row.quote_address,
    creatorAddress: row.creator_address,
    tokenName: row.token_name,
    tokenSymbol: row.token_symbol,
    quoteSymbol: row.quote_symbol,
    engine: row.engine,
    reward: row.reward,
    marketCapUsd: row.market_cap_usd,
    marketCapSource: row.market_cap_source,
    volume24hUsd: row.volume_24h_usd,
    volume24hQuoteRaw: row.quote_volume_raw_24h,
    volume24hFrom: row.volume_24h_from,
    volume24hAsOf: row.volume_24h_as_of,
    lastTradeAt24h: row.last_trade_at_24h,
    liquidityUsd: row.liquidity_usd,
    totalTradeCount: row.total_trade_count,
    buyTradeCount: row.buy_trade_count,
    sellTradeCount: row.sell_trade_count,
    lastPriceNumeratorRaw: row.last_price_numerator_raw,
    lastPriceDenominatorRaw: row.last_price_denominator_raw,
    lastTradeAt: row.last_trade_at,
    supplyRaw: row.legacy_supply_raw,
    requestedSupplyRaw: row.requested_supply_raw,
    depositedSupplyRaw: row.deposited_supply_raw,
    targetFdvUsd: row.target_fdv_usd,
    targetFdvUsdWad: row.target_fdv_usd_wad,
    quoteDecimals: row.effective_quote_decimals,
    quotePriceUsd: row.quote_price_usd,
    quotePriceUsdWad: row.quote_price_usd_wad,
    quotePriceSource: row.quote_price_usd_wad ? 'launch_attestation' : null,
    quotePriceStatus: row.quote_price_status,
    quotePriceIsLive: false,
    quotePriceObservedAt: row.quote_price_observed_at,
    quotePriceAttestationDeadline: row.quote_price_attested_deadline,
    quotePriceLiquidityUsd: row.quote_price_liquidity_usd,
    quotePriceLiquidityUsdWad: row.quote_price_liquidity_usd_wad,
    quoteReferenceToken: row.quote_reference_token,
    quoteReferencePool: row.quote_reference_pool,
    quotePriceAttestationDigest: row.quote_price_attestation_digest,
    initialSqrtPriceX96: row.initial_sqrt_price_x96,
    tickLower: row.tick_lower,
    tickUpper: row.tick_upper,
    poolFee: row.pool_fee,
    creatorFeeBps: row.creator_fee_bps,
    rewardFeeBps: row.reward_fee_bps,
    creatorLpShareBps: row.creator_lp_share_bps,
    blockNumber: row.launch_block,
    logIndex: row.launch_log_index,
    launchTxHash: row.launch_tx_hash,
    createdAt: row.launched_at,
    updatedAt: row.updated_at,
  };
}

function encodeCursor(cursor: CursorPayload) {
  return Buffer.from(JSON.stringify(cursor), 'utf8').toString('base64url');
}

function decodeCursor(raw: string | null, sort: MarketSort): CursorPayload | null {
  if (!raw || raw.length > 512) return null;
  try {
    const value = JSON.parse(Buffer.from(raw, 'base64url').toString('utf8')) as Partial<CursorPayload>;
    if (value.v !== 1 || value.sort !== sort || typeof value.launchId !== 'string') return null;
    if (value.value !== null && typeof value.value !== 'string') return null;
    if (!/^\d+$/.test(value.launchId) || (value.value !== null && !/^-?\d+(\.\d+)?$/.test(value.value))) return null;
    return value as CursorPayload;
  } catch {
    return null;
  }
}
