'use client';

import { Activity, ArrowDownUp, ArrowRight, Clock3, ExternalLink, Radio, WifiOff } from 'lucide-react';
import { AnimatePresence, motion } from 'motion/react';
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';

const QUOTE_API_URL = (process.env.NEXT_PUBLIC_QUOTE_API_URL ?? '').replace(/\/+$/, '');
const SNAPSHOT_PATH = '/v1/markets?sort=market_cap&limit=50';
const STREAM_PATH = '/v1/stream?channel=markets';

type SortMode = 'market_cap' | 'newest' | 'volume_24h';
type FilterMode = 'all' | 'direct' | 'curve' | 'reward';
type ConnectionState = 'offline' | 'loading' | 'connecting' | 'live' | 'reconnecting' | 'error';
type MarketEngine = 'direct' | 'curve';

type MarketRecord = {
  key: string;
  id: string;
  marketAddress?: string;
  tokenAddress?: string;
  quoteAddress?: string;
  tokenSymbol?: string;
  quoteSymbol?: string;
  tokenName?: string;
  engine?: MarketEngine;
  reward?: boolean;
  marketCapUsd?: number;
  volume24hUsd?: number;
  liquidityUsd?: number;
  priceUsd?: number;
  priceChange24h?: number;
  createdAtMs?: number;
  updatedAtMs?: number;
  indexedAtMs?: number;
  latencyMs?: number;
  blockNumber?: number;
  logIndex?: number;
  launchTxHash?: string;
  eventId?: string;
};

type ApiRecord = Record<string, unknown>;

const sortOptions: Array<{ value: SortMode; label: string; zh: string }> = [
  { value: 'market_cap', label: 'Market cap', zh: '市值' },
  { value: 'newest', label: 'Newest', zh: '最新' },
  { value: 'volume_24h', label: '24h volume', zh: '24小时成交量' },
];

const filterOptions: Array<{ value: FilterMode; label: string; zh: string }> = [
  { value: 'all', label: 'All', zh: '全部' },
  { value: 'direct', label: 'Direct', zh: '直开' },
  { value: 'curve', label: 'Curve', zh: '曲线' },
  { value: 'reward', label: 'Reward', zh: '奖励' },
];

const usdCompact = new Intl.NumberFormat('en-US', {
  compactDisplay: 'short',
  currency: 'USD',
  maximumFractionDigits: 2,
  notation: 'compact',
  style: 'currency',
});

const numberCompact = new Intl.NumberFormat('en-US', {
  compactDisplay: 'short',
  maximumFractionDigits: 2,
  notation: 'compact',
});

function isRecord(value: unknown): value is ApiRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function readPath(input: unknown, path: string): unknown {
  let current = input;
  for (const segment of path.split('.')) {
    if (!isRecord(current)) return undefined;
    current = current[segment];
  }
  return current;
}

function firstText(record: unknown, paths: string[]): string | undefined {
  for (const path of paths) {
    const value = readPath(record, path);
    if (typeof value === 'string') {
      const text = value.trim();
      if (text) return text;
    }
    if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  }
  return undefined;
}

function toFiniteNumber(value: unknown): number | undefined {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value !== 'string') return undefined;

  const normalized = value.trim().replace(/[$,%]/g, '').replace(/,/g, '');
  if (!normalized) return undefined;

  const number = Number(normalized);
  return Number.isFinite(number) ? number : undefined;
}

function firstNumber(record: unknown, paths: string[]): number | undefined {
  for (const path of paths) {
    const number = toFiniteNumber(readPath(record, path));
    if (number !== undefined) return number;
  }
  return undefined;
}

function firstBoolean(record: unknown, paths: string[]): boolean | undefined {
  for (const path of paths) {
    const value = readPath(record, path);
    if (typeof value === 'boolean') return value;
    if (typeof value === 'string') {
      const normalized = value.trim().toLowerCase();
      if (['true', 'yes', '1'].includes(normalized)) return true;
      if (['false', 'no', '0'].includes(normalized)) return false;
    }
  }
  return undefined;
}

function firstTimestamp(record: unknown, paths: string[]): number | undefined {
  for (const path of paths) {
    const value = readPath(record, path);
    const number = toFiniteNumber(value);
    if (number !== undefined) {
      if (number > 1_000_000_000_000) return number;
      if (number > 1_000_000_000) return number * 1000;
    }

    if (typeof value === 'string') {
      const parsed = Date.parse(value);
      if (Number.isFinite(parsed)) return parsed;
    }
  }
  return undefined;
}

function buildUrl(path: string) {
  return `${QUOTE_API_URL}${path}`;
}

function extractMarkets(payload: unknown): unknown[] {
  if (Array.isArray(payload)) return payload;
  if (!isRecord(payload)) return [];

  for (const key of ['markets', 'items', 'rows', 'data']) {
    const value = payload[key];
    if (Array.isArray(value)) return value;
  }

  for (const key of ['market', 'payload', 'record']) {
    const value = payload[key];
    const nested = extractMarkets(value);
    if (nested.length > 0) return nested;
    if (isRecord(value) && looksLikeMarket(value)) return [value];
  }

  return looksLikeMarket(payload) ? [payload] : [];
}

function looksLikeMarket(value: ApiRecord) {
  return Boolean(
    firstText(value, [
      'marketId',
      'market_id',
      'marketAddress',
      'market_address',
      'poolAddress',
      'pool_address',
      'pairAddress',
      'pair_address',
      'tokenAddress',
      'token_address',
      'quoteAddress',
      'quote_address',
      'launchTxHash',
      'launch_tx_hash',
      'txHash',
      'tx_hash',
    ]),
  );
}

function normalizeEngine(record: unknown): MarketEngine | undefined {
  const raw = firstText(record, ['engine', 'kind', 'type', 'marketType', 'market_type', 'path', 'launchPath', 'launch_path']);
  const value = raw?.toLowerCase();
  if (!value) return undefined;
  if (value.includes('curve') || value.includes('bonding')) return 'curve';
  if (value.includes('direct')) return 'direct';
  return undefined;
}

function normalizeReward(record: unknown): boolean | undefined {
  const explicit = firstBoolean(record, ['reward', 'rewards', 'hasRewards', 'has_rewards', 'isReward', 'is_reward', 'token.reward', 'token.hasRewards']);
  if (explicit !== undefined) return explicit;

  const raw = firstText(record, ['mode', 'tokenMode', 'token_mode', 'tokenType', 'token_type', 'features']);
  return raw?.toLowerCase().includes('reward') || undefined;
}

function identityFor(record: unknown): string | undefined {
  const explicit = firstText(record, [
    'marketId',
    'market_id',
    'marketAddress',
    'market_address',
    'poolAddress',
    'pool_address',
    'pairAddress',
    'pair_address',
    'address',
    'id',
    'launchId',
    'launch_id',
  ]);
  if (explicit) return explicit;

  const txHash = firstText(record, ['launchTxHash', 'launch_tx_hash', 'txHash', 'tx_hash', 'transactionHash', 'transaction_hash']);
  const logIndex = firstNumber(record, ['logIndex', 'log_index']);
  if (txHash && logIndex !== undefined) return `${txHash}:${logIndex}`;

  const tokenAddress = firstText(record, ['tokenAddress', 'token_address', 'token.address', 'baseToken.address', 'base_token.address']);
  const quoteAddress = firstText(record, ['quoteAddress', 'quote_address', 'quote.address', 'quoteToken.address', 'quote_token.address']);
  if (tokenAddress && quoteAddress) return `${tokenAddress}:${quoteAddress}`;

  return undefined;
}

function normalizeMarket(record: unknown, eventId?: string): MarketRecord | undefined {
  const id = identityFor(record);
  if (!id) return undefined;

  const market: MarketRecord = { id, key: id.toLowerCase() };
  const marketAddress = firstText(record, ['marketAddress', 'market_address', 'poolAddress', 'pool_address', 'pairAddress', 'pair_address', 'address']);
  const tokenAddress = firstText(record, ['tokenAddress', 'token_address', 'token.address', 'baseToken.address', 'base_token.address']);
  const quoteAddress = firstText(record, ['quoteAddress', 'quote_address', 'quote.address', 'quoteToken.address', 'quote_token.address']);
  const tokenSymbol = firstText(record, ['tokenSymbol', 'token_symbol', 'baseSymbol', 'base_symbol', 'token.symbol', 'baseToken.symbol', 'base_token.symbol', 'symbol']);
  const quoteSymbol = firstText(record, ['quoteSymbol', 'quote_symbol', 'quote.symbol', 'quoteToken.symbol', 'quote_token.symbol']);
  const tokenName = firstText(record, ['tokenName', 'token_name', 'token.name', 'baseToken.name', 'base_token.name', 'name']);
  const engine = normalizeEngine(record);
  const reward = normalizeReward(record);
  const marketCapUsd = firstNumber(record, ['marketCapUsd', 'market_cap_usd', 'marketCap', 'market_cap', 'stats.marketCapUsd', 'stats.market_cap_usd', 'metrics.marketCapUsd']);
  const volume24hUsd = firstNumber(record, ['volume24hUsd', 'volume_24h_usd', 'volume24h', 'volume_24h', 'volumeUsd24h', 'volume_usd_24h', 'stats.volume24hUsd', 'stats.volume_24h_usd']);
  const liquidityUsd = firstNumber(record, ['liquidityUsd', 'liquidity_usd', 'liquidity', 'stats.liquidityUsd', 'stats.liquidity_usd']);
  const priceUsd = firstNumber(record, ['priceUsd', 'price_usd', 'price', 'stats.priceUsd', 'stats.price_usd']);
  const priceChange24h = firstNumber(record, ['priceChange24h', 'price_change_24h', 'priceChange24hPct', 'price_change_24h_pct', 'stats.priceChange24h']);
  const createdAtMs = firstTimestamp(record, ['createdAt', 'created_at', 'launchTime', 'launch_time', 'launchedAt', 'launched_at', 'createdTimestamp', 'created_timestamp']);
  const updatedAtMs = firstTimestamp(record, ['updatedAt', 'updated_at', 'lastUpdate', 'last_update']);
  const indexedAtMs = firstTimestamp(record, ['indexedAt', 'indexed_at', 'seenAt', 'seen_at']);
  const latencyMs = firstNumber(record, ['latencyMs', 'latency_ms', 'indexerLatencyMs', 'indexer_latency_ms', 'streamLatencyMs', 'stream_latency_ms']);
  const blockNumber = firstNumber(record, ['blockNumber', 'block_number', 'launchBlock', 'launch_block']);
  const logIndex = firstNumber(record, ['logIndex', 'log_index']);
  const launchTxHash = firstText(record, ['launchTxHash', 'launch_tx_hash', 'txHash', 'tx_hash', 'transactionHash', 'transaction_hash']);

  if (marketAddress) market.marketAddress = marketAddress;
  if (tokenAddress) market.tokenAddress = tokenAddress;
  if (quoteAddress) market.quoteAddress = quoteAddress;
  if (tokenSymbol) market.tokenSymbol = tokenSymbol;
  if (quoteSymbol) market.quoteSymbol = quoteSymbol;
  if (tokenName) market.tokenName = tokenName;
  if (engine) market.engine = engine;
  if (reward !== undefined) market.reward = reward;
  if (marketCapUsd !== undefined) market.marketCapUsd = marketCapUsd;
  if (volume24hUsd !== undefined) market.volume24hUsd = volume24hUsd;
  if (liquidityUsd !== undefined) market.liquidityUsd = liquidityUsd;
  if (priceUsd !== undefined) market.priceUsd = priceUsd;
  if (priceChange24h !== undefined) market.priceChange24h = priceChange24h;
  if (createdAtMs !== undefined) market.createdAtMs = createdAtMs;
  if (updatedAtMs !== undefined) market.updatedAtMs = updatedAtMs;
  if (indexedAtMs !== undefined) market.indexedAtMs = indexedAtMs;
  if (latencyMs !== undefined) market.latencyMs = latencyMs;
  if (blockNumber !== undefined) market.blockNumber = blockNumber;
  if (logIndex !== undefined) market.logIndex = logIndex;
  if (launchTxHash) market.launchTxHash = launchTxHash;
  if (eventId) market.eventId = eventId;

  return market;
}

function mergeMarkets(current: MarketRecord[], incoming: MarketRecord[]) {
  const byKey = new Map(current.map((market) => [market.key, market]));
  for (const market of incoming) {
    byKey.set(market.key, { ...byKey.get(market.key), ...market });
  }
  return Array.from(byKey.values());
}

function removeMarkets(current: MarketRecord[], payload: unknown) {
  const keys = extractMarkets(payload)
    .map((market) => identityFor(market))
    .filter((key): key is string => Boolean(key))
    .map((key) => key.toLowerCase());

  if (keys.length === 0) return current;
  const deleted = new Set(keys);
  return current.filter((market) => !deleted.has(market.key));
}

function isDeleteEvent(payload: unknown, eventType: string) {
  if (['delete', 'deleted', 'remove', 'removed'].includes(eventType.toLowerCase())) return true;
  const action = firstText(payload, ['type', 'event', 'action', 'op'])?.toLowerCase();
  return Boolean(action && ['delete', 'deleted', 'remove', 'removed', 'market.deleted', 'market.removed'].includes(action));
}

function eventIdFromPayload(payload: unknown) {
  return firstText(payload, ['eventId', 'event_id', 'lastEventId', 'last_event_id', 'sequence', 'seq']);
}

function snapshotEventId(payload: unknown) {
  return firstText(payload, ['latestEventId', 'latest_event_id', 'lastEventId', 'last_event_id', 'cursor.eventId']);
}

function snapshotTimestamp(payload: unknown) {
  return firstTimestamp(payload, ['snapshotAt', 'snapshot_at', 'generatedAt', 'generated_at', 'indexedAt', 'indexed_at']);
}

function displayPair(market: MarketRecord) {
  const base = market.tokenSymbol || shortId(market.tokenAddress || market.id);
  const quote = market.quoteSymbol || shortId(market.quoteAddress || '');
  return quote ? `${base} / ${quote}` : base;
}

function shortId(value: string) {
  if (!value) return 'N/A';
  if (value.length <= 14) return value;
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function formatUsd(value?: number) {
  return value === undefined ? 'N/A' : usdCompact.format(value);
}

function formatNumber(value?: number) {
  return value === undefined ? 'N/A' : numberCompact.format(value);
}

function formatPercent(value?: number) {
  if (value === undefined) return 'N/A';
  return `${value >= 0 ? '+' : ''}${value.toFixed(2)}%`;
}

function formatDate(value?: number) {
  if (value === undefined) return 'N/A';
  return new Date(value).toLocaleString('en-US', { dateStyle: 'medium', timeStyle: 'short' });
}

function formatLatency(value?: number) {
  if (value === undefined) return 'N/A';
  return value < 1000 ? `${Math.round(value)} ms` : `${(value / 1000).toFixed(2)} s`;
}

function marketMatchesFilter(market: MarketRecord, filter: FilterMode) {
  if (filter === 'all') return true;
  if (filter === 'reward') return market.reward === true;
  return market.engine === filter;
}

function compareMarkets(sort: SortMode) {
  return (left: MarketRecord, right: MarketRecord) => {
    if (sort === 'newest') return (right.createdAtMs ?? 0) - (left.createdAtMs ?? 0);
    if (sort === 'volume_24h') return (right.volume24hUsd ?? -1) - (left.volume24hUsd ?? -1);
    return (right.marketCapUsd ?? -1) - (left.marketCapUsd ?? -1);
  };
}

function connectionText(status: ConnectionState) {
  if (status === 'offline') return 'Indexer offline';
  if (status === 'loading') return 'Loading snapshot';
  if (status === 'connecting') return 'Opening stream';
  if (status === 'live') return 'Live stream';
  if (status === 'reconnecting') return 'Reconnecting';
  return 'Indexer error';
}

function parseJson(data: string): unknown {
  if (!data.trim()) return undefined;
  return JSON.parse(data) as unknown;
}

export function RealtimeMarketFeed() {
  const [markets, setMarkets] = useState<MarketRecord[]>([]);
  const [sort, setSort] = useState<SortMode>('market_cap');
  const [filter, setFilter] = useState<FilterMode>('all');
  const [status, setStatus] = useState<ConnectionState>(QUOTE_API_URL ? 'loading' : 'offline');
  const [error, setError] = useState<string | null>(null);
  const [lastEventId, setLastEventId] = useState<string | null>(null);
  const [snapshotAt, setSnapshotAt] = useState<number | null>(null);

  useEffect(() => {
    if (!QUOTE_API_URL) return;

    const controller = new AbortController();
    let stream: EventSource | null = null;

    async function startFeed() {
      setStatus('loading');
      setError(null);

      try {
        const response = await fetch(buildUrl(SNAPSHOT_PATH), { cache: 'no-store', signal: controller.signal });
        if (!response.ok) throw new Error(`snapshot_${response.status}`);

        const payload = (await response.json()) as unknown;
        const eventId = snapshotEventId(payload);
        const snapshotTime = snapshotTimestamp(payload);
        const snapshotMarkets = extractMarkets(payload)
          .map((market) => normalizeMarket(market, eventId))
          .filter((market): market is MarketRecord => Boolean(market));

        setMarkets(mergeMarkets([], snapshotMarkets));
        setLastEventId(eventId ?? null);
        setSnapshotAt(snapshotTime ?? Date.now());
        setStatus('connecting');
      } catch (snapshotError) {
        if (controller.signal.aborted) return;
        setError(snapshotError instanceof Error ? 'Market data is temporarily unavailable.' : 'Market data is temporarily unavailable.');
        setStatus('connecting');
      }

      if (controller.signal.aborted) return;

      const streamUrl = new URL(buildUrl(STREAM_PATH));
      if (eventId) streamUrl.searchParams.set('after', eventId);
      stream = new EventSource(streamUrl.toString());
      stream.onopen = () => {
        setStatus('live');
        setError(null);
      };

      const handleMessage = (event: MessageEvent<string>) => {
        try {
          const payload = parseJson(event.data);
          const eventId = event.lastEventId || eventIdFromPayload(payload);
          if (eventId) setLastEventId(eventId);

          if (isDeleteEvent(payload, event.type)) {
            setMarkets((current) => removeMarkets(current, payload));
            setStatus('live');
            return;
          }

          const incoming = extractMarkets(payload)
            .map((market) => normalizeMarket(market, eventId))
            .filter((market): market is MarketRecord => Boolean(market));

          if (incoming.length > 0) {
            setMarkets((current) => mergeMarkets(current, incoming));
          }
          setStatus('live');
          setError(null);
        } catch (streamError) {
          setError(streamError instanceof Error ? streamError.message : 'stream_parse_error');
        }
      };

      stream.addEventListener('message', handleMessage);
      stream.addEventListener('market', handleMessage);
      stream.addEventListener('markets', handleMessage);
      stream.addEventListener('upsert', handleMessage);
      stream.addEventListener('delete', handleMessage);
      stream.addEventListener('market.launched', handleMessage);
      stream.addEventListener('market.updated', handleMessage);
      stream.addEventListener('market.deleted', handleMessage);
      stream.onerror = () => {
        setStatus((current) => (current === 'offline' ? current : 'reconnecting'));
      };
    }

    void startFeed();

    return () => {
      controller.abort();
      stream?.close();
    };
  }, []);

  const filteredMarkets = useMemo(
    () => markets.filter((market) => marketMatchesFilter(market, filter)).sort(compareMarkets(sort)),
    [filter, markets, sort],
  );

  const counts = useMemo(
    () => ({
      all: markets.length,
      curve: markets.filter((market) => market.engine === 'curve').length,
      direct: markets.filter((market) => market.engine === 'direct').length,
      reward: markets.filter((market) => market.reward === true).length,
    }),
    [markets],
  );

  const isBusy = status === 'loading' || status === 'connecting';
  const emptyTitle = status === 'offline' ? 'QUOTE indexer offline' : 'No QUOTE markets indexed';
  const emptyCopy = status === 'offline'
    ? 'The chain feed will appear here when the QUOTE indexer is online. No placeholder launches are shown.'
    : 'The feed is connected to the QUOTE indexer, but the backend returned zero markets for this view.';

  return (
    <section className="realtime-feed" aria-labelledby="quote-market-feed-title">
      <header className="feed-header">
        <div>
          <span className="section-label copy-en">Realtime index</span>
          <span className="section-label copy-zh">实时索引</span>
          <h2 id="quote-market-feed-title" className="copy-en">QUOTE market feed</h2>
          <h2 className="copy-zh">QUOTE 市场流</h2>
        </div>
        <Link className="feed-launch-link" href="/launch">
          <span className="copy-en">Create market</span>
          <span className="copy-zh">创建市场</span>
          <ArrowRight size={15} />
        </Link>
      </header>

      <div className="feed-shell">
        <aside className="feed-rail" aria-label="Feed status">
          <div className={`connection ${status}`}>
            {status === 'offline' ? <WifiOff size={17} /> : <Radio size={17} />}
            <span role="status" aria-live="polite">{connectionText(status)}</span>
          </div>
          <div className="rail-metric">
            <small>MARKETS</small>
            <b>{counts.all}</b>
          </div>
          <div className="rail-metric">
            <small>LAST EVENT</small>
            <b>{lastEventId ? shortId(lastEventId) : 'N/A'}</b>
          </div>
          <div className="rail-metric">
            <small>SNAPSHOT</small>
            <b>{snapshotAt ? formatDate(snapshotAt) : 'N/A'}</b>
          </div>
          {error ? <p className="rail-error">{error}</p> : null}
        </aside>

        <div className="feed-panel">
          <div className="feed-controls">
            <div className="control-group" role="group" aria-label="Filter markets">
              {filterOptions.map((option) => (
                <button
                  aria-pressed={filter === option.value}
                  className={filter === option.value ? 'active' : ''}
                  key={option.value}
                  onClick={() => setFilter(option.value)}
                  type="button"
                >
                  <span className="copy-en">{option.label}</span>
                  <span className="copy-zh">{option.zh}</span>
                  <small>{counts[option.value]}</small>
                </button>
              ))}
            </div>
            <div className="control-group sort" role="group" aria-label="Sort markets">
              {sortOptions.map((option) => (
                <button
                  aria-pressed={sort === option.value}
                  className={sort === option.value ? 'active' : ''}
                  key={option.value}
                  onClick={() => setSort(option.value)}
                  type="button"
                >
                  <ArrowDownUp size={12} />
                  <span className="copy-en">{option.label}</span>
                  <span className="copy-zh">{option.zh}</span>
                </button>
              ))}
            </div>
          </div>

          <div className="market-table" role="table" aria-busy={isBusy} aria-label="Realtime QUOTE markets">
            <div className="table-head" role="row">
              <span role="columnheader">Market</span>
              <span role="columnheader">Market cap</span>
              <span role="columnheader">24H volume</span>
              <span role="columnheader">Liquidity</span>
              <span role="columnheader">Latency</span>
            </div>

            <AnimatePresence initial={false}>
              {filteredMarkets.map((market) => (
                <motion.article
                  animate={{ opacity: 1, y: 0 }}
                  className="market-row"
                  exit={{ opacity: 0, y: -6 }}
                  initial={{ opacity: 0, y: 8 }}
                  key={market.key}
                  layout
                  role="row"
                  transition={{ damping: 34, stiffness: 420, type: 'spring' }}
                >
                  <div className="market-cell pair" role="cell">
                    <span className="seal" aria-hidden="true">{(market.tokenSymbol || '#').slice(0, 2).toUpperCase()}</span>
                    <div>
                      <b>{displayPair(market)}</b>
                      <small>{market.tokenName || shortId(market.marketAddress || market.tokenAddress || market.id)}</small>
                      <span className="tags">
                        {market.engine ? <i>{market.engine.toUpperCase()}</i> : null}
                        {market.reward ? <i>REWARD</i> : null}
                        {market.blockNumber !== undefined ? <i>#{formatNumber(market.blockNumber)}</i> : null}
                      </span>
                    </div>
                  </div>
                  <div className="market-cell metric" role="cell">
                    <b>{formatUsd(market.marketCapUsd)}</b>
                    <small>{formatPercent(market.priceChange24h)}</small>
                  </div>
                  <div className="market-cell metric" role="cell">
                    <b>{formatUsd(market.volume24hUsd)}</b>
                    <small>24H</small>
                  </div>
                  <div className="market-cell metric" role="cell">
                    <b>{formatUsd(market.liquidityUsd)}</b>
                    <small>{market.priceUsd !== undefined ? `${formatUsd(market.priceUsd)} price` : 'N/A price'}</small>
                  </div>
                  <div className="market-cell latency" role="cell">
                    <Clock3 size={13} />
                    <span>{formatLatency(market.latencyMs)}</span>
                    {market.launchTxHash ? (
                      <a href={`https://bscscan.com/tx/${market.launchTxHash}`} target="_blank" rel="noreferrer" aria-label={`Open launch transaction for ${displayPair(market)}`}>
                        <ExternalLink size={13} />
                      </a>
                    ) : null}
                  </div>
                </motion.article>
              ))}
            </AnimatePresence>

            {filteredMarkets.length === 0 ? (
              <div className="empty-state">
                <Activity size={18} />
                <div>
                  <b>{emptyTitle}</b>
                  <p>{emptyCopy}</p>
                </div>
              </div>
            ) : null}
          </div>
        </div>
      </div>

      <style>{`
        .realtime-feed {
          max-width: 1400px;
          margin: 0 auto;
          padding: 58px clamp(20px, 5vw, 72px) 94px;
        }

        .realtime-feed .feed-header {
          margin-bottom: 28px;
          display: flex;
          align-items: flex-end;
          justify-content: space-between;
          gap: 20px;
        }

        .realtime-feed .feed-header h2 {
          margin: 0;
          font: 700 clamp(36px, 4vw, 54px) / .9 var(--font-anybody);
          letter-spacing: -.05em;
        }

        .realtime-feed .feed-launch-link {
          padding: 10px 0;
          display: inline-flex;
          align-items: center;
          gap: 10px;
          border-bottom: 3px solid var(--acid);
          font-size: 12px;
          font-weight: 650;
        }

        .realtime-feed .feed-launch-link:hover {
          color: var(--acid);
        }

        .realtime-feed .feed-shell {
          display: grid;
          grid-template-columns: minmax(190px, .28fr) minmax(0, .72fr);
          gap: 16px;
        }

        .realtime-feed .feed-rail,
        .realtime-feed .feed-panel {
          border: 1px solid var(--line-strong);
          background: var(--bg-deep);
          box-shadow: 9px 9px 0 var(--rail);
        }

        .realtime-feed .feed-rail {
          min-height: 420px;
          padding: 16px;
          display: flex;
          flex-direction: column;
          gap: 12px;
        }

        .realtime-feed .connection {
          min-height: 44px;
          padding: 0 12px;
          display: flex;
          align-items: center;
          gap: 9px;
          border: 1px solid var(--line);
          background: var(--surface);
          color: var(--muted);
          font: 600 9px var(--font-plex-mono);
          letter-spacing: .08em;
          text-transform: uppercase;
        }

        .realtime-feed .connection.live {
          border-color: rgba(199, 214, 60, .45);
          color: var(--acid);
        }

        .realtime-feed .connection.reconnecting,
        .realtime-feed .connection.error,
        .realtime-feed .connection.offline {
          border-color: rgba(255, 90, 50, .45);
          color: var(--orange);
        }

        .realtime-feed .rail-metric {
          min-height: 76px;
          padding: 13px;
          display: flex;
          flex-direction: column;
          justify-content: space-between;
          border: 1px solid var(--line);
          background: var(--surface);
        }

        .realtime-feed :is(.rail-metric small, .rail-error, .table-head, .market-cell small, .tags, .control-group button) {
          font-family: var(--font-plex-mono);
        }

        .realtime-feed .rail-metric small {
          color: var(--muted);
          font-size: 8px;
          letter-spacing: .1em;
        }

        .realtime-feed .rail-metric b {
          overflow-wrap: anywhere;
          font-size: 17px;
          line-height: 1.08;
        }

        .realtime-feed .rail-error {
          margin: auto 0 0;
          padding: 11px;
          border-left: 4px solid var(--orange);
          background: var(--surface);
          color: var(--muted);
          font-size: 9px;
          line-height: 1.5;
          overflow-wrap: anywhere;
        }

        .realtime-feed .feed-panel {
          min-width: 0;
        }

        .realtime-feed .feed-controls {
          padding: 14px;
          display: flex;
          justify-content: space-between;
          gap: 12px;
          border-bottom: 1px solid var(--line);
        }

        .realtime-feed .control-group {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
        }

        .realtime-feed .control-group button {
          min-height: 34px;
          padding: 0 10px;
          display: inline-flex;
          align-items: center;
          gap: 7px;
          border: 1px solid var(--line);
          background: var(--surface);
          color: var(--muted);
          cursor: pointer;
          font-size: 8px;
          letter-spacing: .07em;
          text-transform: uppercase;
          transition: background .16s ease, color .16s ease, border-color .16s ease, transform .16s ease;
        }

        .realtime-feed .control-group button:hover,
        .realtime-feed .control-group button.active {
          border-color: var(--acid);
          background: var(--acid);
          color: var(--bg-deep);
        }

        .realtime-feed .control-group button:hover {
          transform: translateY(-1px);
        }

        .realtime-feed .control-group small {
          opacity: .68;
        }

        .realtime-feed .market-table {
          min-height: 330px;
        }

        .realtime-feed .table-head,
        .realtime-feed .market-row {
          display: grid;
          grid-template-columns: minmax(260px, 1.25fr) repeat(3, minmax(120px, .65fr)) minmax(128px, .55fr);
          align-items: center;
        }

        .realtime-feed .table-head {
          min-height: 43px;
          padding: 0 14px;
          color: var(--muted);
          font-size: 8px;
          letter-spacing: .1em;
          text-transform: uppercase;
          border-bottom: 1px solid var(--line);
        }

        .realtime-feed .market-row {
          min-height: 86px;
          padding: 0 14px;
          border-bottom: 1px solid var(--line);
          background: var(--surface);
        }

        .realtime-feed .market-row:nth-child(odd) {
          background: rgba(37, 22, 52, .72);
        }

        .realtime-feed .market-cell {
          min-width: 0;
          padding: 12px 8px;
        }

        .realtime-feed .pair {
          display: grid;
          grid-template-columns: 40px minmax(0, 1fr);
          gap: 11px;
          align-items: center;
        }

        .realtime-feed .seal {
          width: 38px;
          height: 38px;
          display: grid;
          place-items: center;
          border: 1px solid var(--line-strong);
          border-radius: 50%;
          background: var(--bg-deep);
          color: var(--acid);
          font: 700 10px var(--font-plex-mono);
        }

        .realtime-feed .pair b,
        .realtime-feed .metric b {
          display: block;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .realtime-feed .pair b {
          font-size: 15px;
        }

        .realtime-feed .pair small,
        .realtime-feed .metric small {
          display: block;
          margin-top: 4px;
          overflow: hidden;
          color: var(--muted);
          font-size: 9px;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        .realtime-feed .metric b {
          font-size: 13px;
        }

        .realtime-feed .tags {
          margin-top: 7px;
          display: flex;
          flex-wrap: wrap;
          gap: 4px;
        }

        .realtime-feed .tags i {
          padding: 3px 5px;
          border: 1px solid var(--line);
          color: var(--acid);
          font-size: 7px;
          font-style: normal;
          letter-spacing: .08em;
        }

        .realtime-feed .latency {
          display: flex;
          align-items: center;
          gap: 7px;
          color: var(--muted);
          font: 600 9px var(--font-plex-mono);
        }

        .realtime-feed .latency a {
          width: 28px;
          height: 28px;
          margin-left: auto;
          display: grid;
          place-items: center;
          color: var(--bone);
        }

        .realtime-feed .empty-state {
          min-height: 285px;
          padding: 34px;
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 13px;
          color: var(--muted);
          text-align: left;
        }

        .realtime-feed .empty-state b {
          display: block;
          color: var(--bone);
          font-size: 18px;
        }

        .realtime-feed .empty-state p {
          max-width: 520px;
          margin: 8px 0 0;
          font-size: 13px;
          line-height: 1.5;
        }

        @media (max-width: 980px) {
          .realtime-feed .feed-shell {
            grid-template-columns: 1fr;
          }

          .realtime-feed .feed-rail {
            min-height: auto;
            display: grid;
            grid-template-columns: repeat(4, 1fr);
          }

          .realtime-feed .connection {
            grid-column: 1 / -1;
          }

          .realtime-feed .rail-error {
            grid-column: 1 / -1;
          }

          .realtime-feed .feed-controls {
            flex-direction: column;
          }

          .realtime-feed .table-head {
            display: none;
          }

          .realtime-feed .market-row {
            grid-template-columns: 1fr 1fr;
            gap: 0 10px;
            padding: 10px 14px;
          }

          .realtime-feed .pair {
            grid-column: 1 / -1;
          }
        }

        @media (max-width: 680px) {
          .realtime-feed {
            padding: 46px 16px 76px;
          }

          .realtime-feed .feed-header {
            align-items: flex-start;
            flex-direction: column;
            gap: 22px;
          }

          .realtime-feed .feed-header h2 {
            font-size: 36px;
          }

          .realtime-feed .feed-rail {
            grid-template-columns: 1fr;
          }

          .realtime-feed .control-group button {
            flex: 1 1 auto;
            justify-content: center;
          }

          .realtime-feed .market-row {
            grid-template-columns: 1fr;
          }

          .realtime-feed .market-cell {
            padding: 8px 0;
          }

          .realtime-feed .latency a {
            margin-left: 0;
          }

          .realtime-feed .empty-state {
            min-height: 240px;
            padding: 22px;
            align-items: flex-start;
            flex-direction: column;
          }
        }

        @media (prefers-reduced-motion: reduce) {
          .realtime-feed .control-group button {
            transition: none;
          }
        }
      `}</style>
    </section>
  );
}
