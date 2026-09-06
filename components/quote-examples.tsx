'use client';

import { ArrowRight, ExternalLink, RefreshCw } from 'lucide-react';
import Image from 'next/image';
import Link from 'next/link';
import { useEffect, useMemo, useState } from 'react';
import type { Address } from 'viem';

type QuoteAsset = {
  symbol: string;
  address: Address;
  role: string;
  icon: string;
  mark: string;
};

type MarketResponse = {
  found: boolean;
  token?: {
    symbol: string;
    name: string;
    imagePath: string | null;
  };
  quoteEligibility?: {
    eligible: boolean;
    liquidityUsd: number;
    isCoreLiquidityPair: boolean;
  };
  pair?: {
    url: string | null;
    pairedSymbol: string;
    marketCapUsd: number | null;
    fdvUsd: number | null;
    liquidityUsd: number;
    volume24hUsd: number | null;
    priceChange24h: number | null;
  };
  error?: string;
};

type RadarState = Record<string, { loading: boolean; data: MarketResponse | null; error: string | null }>;

const quoteAssets: QuoteAsset[] = [
  { symbol: 'MARSCOIN', address: '0xfe189e97832da1573e4e4ff034f4ffc3a15c7777', role: 'Flap native', icon: '/tokens/marscoin.png', mark: 'M' },
  { symbol: 'BABAB', address: '0xe5ae318389b8d6d09370a675479c64862152d126', role: 'Alibaba bStock', icon: '/tokens/alibaba.png', mark: 'BABA' },
  { symbol: 'ASTER', address: '0x000Ae314E2A2172a039B26378814C252734f556A', role: 'Protocol token', icon: '/tokens/aster.jpg', mark: 'A' },
];

const usd = new Intl.NumberFormat('en-US', {
  compactDisplay: 'short',
  currency: 'USD',
  maximumFractionDigits: 2,
  notation: 'compact',
  style: 'currency',
});

function formatUsd(value: number | null | undefined) {
  return typeof value === 'number' && Number.isFinite(value) ? usd.format(value) : 'N/A';
}

function formatChange(value: number | null | undefined) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return '0.00%';
  return `${value >= 0 ? '+' : ''}${value.toFixed(2)}%`;
}

function keyOf(address: Address) {
  return address.toLowerCase();
}

export function QuoteExamples() {
  const [refreshNonce, setRefreshNonce] = useState(0);
  const [imageErrors, setImageErrors] = useState<Record<string, boolean>>({});
  const [radar, setRadar] = useState<RadarState>(() =>
    Object.fromEntries(quoteAssets.map((asset) => [keyOf(asset.address), { loading: true, data: null, error: null }])),
  );

  const isLoading = useMemo(() => Object.values(radar).some((entry) => entry.loading), [radar]);

  useEffect(() => {
    const controller = new AbortController();

    for (const asset of quoteAssets) {
      const key = keyOf(asset.address);

      fetch(`/api/market-data/${asset.address}`, { cache: 'no-store', signal: controller.signal })
        .then(async (response) => {
          if (!response.ok) throw new Error(`market_${response.status}`);
          return (await response.json()) as MarketResponse;
        })
        .then((data) => {
          setRadar((current) => ({
            ...current,
            [key]: { loading: false, data, error: null },
          }));
        })
        .catch((error: unknown) => {
          if (controller.signal.aborted) return;

          setRadar((current) => ({
            ...current,
            [key]: { loading: false, data: current[key]?.data || null, error: error instanceof Error ? error.message : 'market_error' },
          }));
        });
    }

    return () => controller.abort();
  }, [refreshNonce]);

  function refreshRadar() {
    setImageErrors({});
    setRadar((current) =>
      Object.fromEntries(
        quoteAssets.map((asset) => {
          const key = keyOf(asset.address);
          return [key, { loading: true, data: current[key]?.data || null, error: null }];
        }),
      ),
    );
    setRefreshNonce((value) => value + 1);
  }

  return (
    <section className="market-floor" id="markets">
      <header className="floor-header">
        <div>
          <span className="section-label copy-en">Quote radar</span>
          <span className="section-label copy-zh">计价雷达</span>
          <h2 className="copy-en">BSC quote assets</h2>
          <h2 className="copy-zh">BSC 计价资产</h2>
        </div>
        <Link className="index-launch-link" href="/launch"><span className="copy-en">Launch a market</span><span className="copy-zh">创建市场</span><ArrowRight size={15} /></Link>
      </header>

      <div className="market-grid">
        <article className="empty-market">
          <div className="empty-art"><div className="empty-rack">{Array.from({ length: 6 }, (_, index) => <i key={index}><span>{String(index + 1).padStart(2, '0')}</span></i>)}</div></div>
          <div className="empty-body">
            <div><span>QUOTE MARKETS</span><b>0 indexed</b></div>
            <p className="copy-en">This is the empty QUOTE market index. The live rows below are eligible quote assets watched on BSC, not QUOTE-launched markets.</p>
            <p className="copy-zh">这里是空的 QUOTE 市场索引。下方为 BSC 计价资产雷达，并非 QUOTE 已创建市场。</p>
          </div>
        </article>

        <aside className="quote-rack">
          <div className="rack-head">
            <span className="copy-en">Live quote radar</span><span className="copy-zh">实时计价雷达</span>
            <button
              aria-label="Refresh quote radar"
              disabled={isLoading}
              onClick={refreshRadar}
              style={{
                alignItems: 'center',
                background: 'var(--surface)',
                border: '1px solid var(--line)',
                color: 'var(--bone)',
                cursor: isLoading ? 'wait' : 'pointer',
                display: 'inline-flex',
                gap: 6,
                height: 27,
                justifyContent: 'center',
                width: 58,
              }}
              type="button"
            >
              <RefreshCw className={isLoading ? 'spin' : undefined} size={13} />
              <small>BSC</small>
            </button>
          </div>
          {quoteAssets.map((quote) => {
            const key = keyOf(quote.address);
            const entry = radar[key];
            const data = entry?.data;
            const pair = data?.pair;
            const displaySymbol = data?.token?.symbol || quote.symbol;
            const marketCap = pair?.marketCapUsd ?? pair?.fdvUsd ?? null;
            const imagePath = data?.token?.imagePath && !imageErrors[key] ? data.token.imagePath : quote.icon;
            const eligible = Boolean(data?.quoteEligibility?.eligible);
            const status = entry?.loading
              ? 'Reading liquidity'
              : entry?.error
                ? 'DexScreener unavailable'
                : !data?.found
                  ? 'No BSC pair yet'
                  : eligible
                    ? `10k+ core liquidity / ${pair?.pairedSymbol || 'pair'}`
                    : 'Below quote threshold';

            return (
            <div className="quote-row" key={quote.symbol}>
              <span className={`quote-seal ${quote.mark ? 'quote-seal-stock' : ''}`}>
                {imagePath ? (
                  <Image
                    alt=""
                    height={32}
                    onError={() => setImageErrors((current) => ({ ...current, [key]: true }))}
                    src={imagePath}
                    unoptimized
                    width={32}
                  />
                ) : (
                  <b>{quote.mark}</b>
                )}
              </span>
              <div>
                <b>
                  {displaySymbol}
                  {eligible ? <span style={{ color: 'var(--orange)', fontSize: 9, marginLeft: 6 }}>10K OK</span> : null}
                </b>
                <small>{entry?.loading ? quote.role : data?.found ? `${eligible ? 'Core pair OK' : 'Needs core 10k'} / ${formatUsd(marketCap)} MC` : status}</small>
                <small>{data?.found ? `${formatUsd(pair?.liquidityUsd)} liq / 24H ${formatUsd(pair?.volume24hUsd)} / ${formatChange(pair?.priceChange24h)}` : status}</small>
              </div>
              <a href={`https://bscscan.com/token/${quote.address}`} target="_blank" rel="noreferrer" aria-label={`Inspect ${quote.symbol} on BscScan`}><ExternalLink size={14} /></a>
              <Link href={`/launch?quote=${quote.address}`} aria-label={`Use ${quote.symbol} as quote`}><ArrowRight size={15} /></Link>
            </div>
            );
          })}
          <p className="rack-note copy-en">DexScreener BSC radar. Address and chain are exact-matched; liquidity must clear the 10k core-pair gate before launch.</p>
          <p className="rack-note copy-zh">DexScreener BSC 雷达。地址与链精确匹配；创建前需通过 10k 核心交易对流动性门槛。</p>
        </aside>
      </div>
    </section>
  );
}
