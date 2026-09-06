'use client';

import { ArrowLeft, ExternalLink, Radio } from 'lucide-react';
import Image from 'next/image';
import { useEffect, useState } from 'react';
import { isAddress } from 'viem';

const API_URL = (process.env.NEXT_PUBLIC_QUOTE_API_URL ?? '').replace(/\/+$/, '');

type Market = {
  marketAddress?: string;
  tokenAddress?: string;
  quoteAddress?: string;
  tokenName?: string;
  tokenSymbol?: string;
  quoteSymbol?: string;
  marketCapUsd?: string;
  marketCapSource?: string;
  volume24hUsd?: string;
  volume24hQuoteRaw?: string;
  volume24hAsOf?: string;
  liquidityUsd?: string;
  quotePriceUsd?: string;
  quotePriceStatus?: string;
  quotePriceObservedAt?: string;
  poolFee?: number;
  creatorLpShareBps?: number;
  totalTradeCount?: string;
  engine?: string;
  reward?: boolean;
  blockNumber?: string;
  launchTxHash?: string;
};

const usd = new Intl.NumberFormat('en-US', {
  compactDisplay: 'short', currency: 'USD', maximumFractionDigits: 2, notation: 'compact', style: 'currency',
});

function money(value?: string) {
  const number = value ? Number(value) : Number.NaN;
  return Number.isFinite(number) ? usd.format(number) : 'N/A';
}

function short(value?: string) {
  if (!value) return 'N/A';
  return value.length > 16 ? `${value.slice(0, 8)}…${value.slice(-6)}` : value;
}

function observed(value?: string) {
  if (!value) return 'Not available';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? 'Not available' : date.toLocaleString('en-US', { timeZone: 'UTC', timeZoneName: 'short' });
}

export function MarketDetail({ address }: { address: string }) {
  const normalizedAddress = isAddress(address) ? address.toLowerCase() : '';
  const [market, setMarket] = useState<Market | null>(null);
  const [state, setState] = useState<'loading' | 'ready' | 'offline' | 'missing'>(API_URL ? 'loading' : 'offline');

  useEffect(() => {
    if (!API_URL || !normalizedAddress) {
      setState(API_URL ? 'missing' : 'offline');
      return;
    }
    const controller = new AbortController();
    void fetch(`${API_URL}/v1/markets?q=${normalizedAddress}&limit=10&sort=newest`, { cache: 'no-store', signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error('market_fetch_failed');
        const payload = await response.json() as { markets?: Market[] };
        const exact = payload.markets?.find((item) =>
          item.marketAddress?.toLowerCase() === normalizedAddress
          || item.tokenAddress?.toLowerCase() === normalizedAddress,
        );
        setMarket(exact ?? null);
        setState(exact ? 'ready' : 'missing');
      })
      .catch(() => {
        if (!controller.signal.aborted) setState('offline');
      });
    return () => controller.abort();
  }, [normalizedAddress]);

  return (
    <main className="page-main market-detail-page">
      <a className="market-back" href="/explore"><ArrowLeft size={14} /> Explore markets</a>
      {state !== 'ready' || !market ? (
        <section className="market-detail-empty">
          <Radio size={18} />
          <div><h1>{state === 'loading' ? 'Loading market' : state === 'missing' ? 'Market not found' : 'Indexer offline'}</h1><p>No placeholder market data is shown.</p></div>
        </section>
      ) : (
        <section className="market-detail-card">
          <header>
            <span className="market-detail-seal">
              {market.tokenAddress ? <Image src={`/api/token-image/${market.tokenAddress.toLowerCase()}`} alt="" fill unoptimized /> : (market.tokenSymbol || 'QT').slice(0, 2)}
            </span>
            <div><small>DIRECT PANCAKESWAP V3</small><h1>{market.tokenSymbol || short(market.tokenAddress)} / {market.quoteSymbol || short(market.quoteAddress)}</h1><p>{market.tokenName || 'QUOTE market'}</p></div>
            {market.reward ? <b>REWARD</b> : null}
          </header>
          <div className="market-detail-metrics">
            <div><small>MARKET CAP</small><strong>{money(market.marketCapUsd)}</strong></div>
            <div><small>24H VOLUME</small><strong>{money(market.volume24hUsd)}</strong></div>
            <div><small>LIQUIDITY</small><strong>{money(market.liquidityUsd)}</strong></div>
          </div>
          <div className="market-detail-addresses">
            <div><span>Token</span><b>{short(market.tokenAddress)}</b></div>
            <div><span>Quote</span><b>{short(market.quoteAddress)}</b></div>
            <div><span>Pool</span><b>{short(market.marketAddress)}</b></div>
            <div><span>Pool fee</span><b>{market.poolFee ? `${(market.poolFee / 10_000).toFixed(2)}%` : 'N/A'}</b></div>
            <div><span>Creator LP share</span><b>{market.creatorLpShareBps !== undefined ? `${(market.creatorLpShareBps / 100).toFixed(0)}%` : 'N/A'}</b></div>
            <div><span>Canonical trades</span><b>{market.totalTradeCount ?? '0'}</b></div>
          </div>
          <div className="market-evidence">
            <div><span>VALUATION BASIS</span><b>{market.marketCapSource === 'last_pool_swap_at_launch_quote' ? 'Latest confirmed pool swap' : market.marketCapSource === 'launch_target_fdv' ? 'Launch target FDV' : 'Unavailable'}</b></div>
            <div><span>QUOTE USD OBSERVATION</span><b>{money(market.quotePriceUsd)} · {market.quotePriceStatus || 'unavailable'}</b><small>{observed(market.quotePriceObservedAt)}</small></div>
            <div><span>24H WINDOW AS OF</span><b>{observed(market.volume24hAsOf)}</b><small>{market.volume24hQuoteRaw ? `${market.volume24hQuoteRaw} raw quote volume` : 'No confirmed volume'}</small></div>
          </div>
          <footer>
            {market.marketAddress ? <a href={`https://bscscan.com/address/${market.marketAddress}`} target="_blank" rel="noreferrer">Pool on BscScan <ExternalLink size={13} /></a> : null}
            {market.launchTxHash ? <a href={`https://bscscan.com/tx/${market.launchTxHash}`} target="_blank" rel="noreferrer">Launch transaction <ExternalLink size={13} /></a> : null}
          </footer>
        </section>
      )}
      <style jsx>{`
        .market-detail-page { width: min(1120px, calc(100% - 36px)); margin: 0 auto; padding: 116px 0 80px; }
        .market-back { display: inline-flex; align-items: center; gap: 7px; color: var(--muted); font: 600 9px var(--font-plex-mono); text-decoration: none; }
        .market-detail-card, .market-detail-empty { margin-top: 22px; border: 1px solid var(--line); border-radius: 14px; background: var(--surface); overflow: hidden; }
        .market-detail-empty { min-height: 240px; display: flex; align-items: center; justify-content: center; gap: 12px; color: var(--muted); }
        .market-detail-empty h1 { margin: 0 0 5px; color: var(--bone); font-size: 20px; }
        .market-detail-empty p { margin: 0; font: 500 9px var(--font-plex-mono); }
        .market-detail-card header { min-height: 150px; padding: 30px; display: flex; align-items: center; gap: 18px; background: radial-gradient(circle at 18% 20%, rgba(199,214,60,.09), transparent 36%), var(--bg-deep); }
        .market-detail-card header > div { flex: 1; }
        .market-detail-card header small { color: var(--acid); font: 600 8px var(--font-plex-mono); letter-spacing: .12em; }
        .market-detail-card h1 { margin: 6px 0 3px; font-size: clamp(25px, 5vw, 48px); font-weight: 540; }
        .market-detail-card header p { margin: 0; color: var(--muted); }
        .market-detail-card header > b { color: var(--acid); font: 600 8px var(--font-plex-mono); }
        .market-detail-seal { position: relative; width: 72px; height: 72px; display: grid; place-items: center; overflow: hidden; border: 1px solid var(--line); border-radius: 50%; background: var(--surface-2); font-weight: 700; }
        .market-detail-seal img { object-fit: cover; }
        .market-detail-metrics { display: grid; grid-template-columns: repeat(3, 1fr); }
        .market-detail-metrics > div { min-height: 112px; padding: 24px; display: flex; flex-direction: column; gap: 8px; border-top: 1px solid var(--line); border-right: 1px solid var(--line); }
        .market-detail-metrics > div:last-child { border-right: 0; }
        .market-detail-metrics small, .market-detail-addresses span { color: var(--muted); font: 600 8px var(--font-plex-mono); letter-spacing: .08em; }
        .market-detail-metrics strong { font-size: 23px; }
        .market-detail-addresses { padding: 16px 24px; border-top: 1px solid var(--line); }
        .market-detail-addresses > div { min-height: 38px; display: flex; align-items: center; justify-content: space-between; border-bottom: 1px solid var(--line); }
        .market-detail-addresses b { font: 550 9px var(--font-plex-mono); }
        .market-evidence { display: grid; grid-template-columns: repeat(3, 1fr); border-top: 1px solid var(--line); background: var(--bg-deep); }
        .market-evidence > div { min-height: 92px; padding: 18px 24px; display: flex; flex-direction: column; gap: 6px; border-right: 1px solid var(--line); }
        .market-evidence > div:last-child { border-right: 0; }
        .market-evidence span { color: var(--acid); font: 600 8px var(--font-plex-mono); letter-spacing: .08em; }
        .market-evidence b { font-size: 12px; font-weight: 600; }
        .market-evidence small { color: var(--muted); font: 500 8px var(--font-plex-mono); }
        .market-detail-card footer { padding: 18px 24px; display: flex; gap: 9px; flex-wrap: wrap; border-top: 1px solid var(--line); }
        .market-detail-card footer a { padding: 9px 11px; display: inline-flex; gap: 7px; align-items: center; border: 1px solid var(--line); border-radius: 7px; color: var(--bone); font: 600 8px var(--font-plex-mono); text-decoration: none; }
        @media (max-width: 650px) { .market-detail-card header { padding: 20px; } .market-detail-metrics, .market-evidence { grid-template-columns: 1fr; } .market-detail-metrics > div, .market-evidence > div { border-right: 0; } }
      `}</style>
    </main>
  );
}
