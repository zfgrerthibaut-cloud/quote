'use client';

import { ArrowRight, ExternalLink } from 'lucide-react';
import type { Address } from 'viem';
import { PairWeave } from '@/components/pair-weave';

const quoteExamples: Array<{ symbol: string; address: Address; role: string }> = [
  { symbol: 'WBNB', address: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', role: 'Wrapped BNB' },
  { symbol: 'USDT', address: '0x55d398326f99059fF775485246999027B3197955', role: 'Stablecoin' },
  { symbol: 'BTCB', address: '0x7130d2A12B9BCbFAd4f2634d864A1Ee1Ce3Ead9c', role: 'Bitcoin' },
];

function chooseQuote(address: Address) {
  window.dispatchEvent(new CustomEvent('forkpare:set-quote', { detail: address }));
  document.getElementById('launch')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  window.setTimeout(() => document.getElementById('quote-token-input')?.focus(), 350);
}

export function QuoteExamples() {
  return (
    <section className="market-floor" id="markets">
      <header className="floor-header">
        <div>
          <span className="section-label copy-en">Market index</span>
          <span className="section-label copy-zh">市场列表</span>
          <h2 className="copy-en">Latest markets</h2>
          <h2 className="copy-zh">最新市场</h2>
        </div>
        <div className="market-tabs" aria-label="Market filters">
          <button className="active" type="button">All</button>
          <button type="button">WBNB</button>
          <button type="button">Stables</button>
          <button type="button">Other</button>
        </div>
      </header>

      <div className="market-grid">
        <article className="empty-market">
          <div className="empty-art"><PairWeave symbol="NEW" quote="WBNB" /></div>
          <div className="empty-body">
            <div><span>MARKETS</span><b>0 verified</b></div>
            <p className="copy-en">Markets will appear from verified <code>MarketLaunched</code> events after the factory is deployed.</p>
            <p className="copy-zh">工厂部署后，已验证的市场将在这里显示。</p>
          </div>
        </article>

        <aside className="quote-rack">
          <div className="rack-head">
            <span className="copy-en">Quote shortcuts</span><span className="copy-zh">计价代币</span>
            <small>BSC</small>
          </div>
          {quoteExamples.map((quote) => (
            <div className="quote-row" key={quote.symbol}>
              <span className="quote-seal">{quote.symbol.slice(0, 1)}</span>
              <div><b>{quote.symbol}</b><small>{quote.role}</small></div>
              <a href={`https://bscscan.com/token/${quote.address}`} target="_blank" rel="noreferrer" aria-label={`Inspect ${quote.symbol} on BscScan`}><ExternalLink size={14} /></a>
              <button type="button" onClick={() => chooseQuote(quote.address)} aria-label={`Use ${quote.symbol} as quote`}><ArrowRight size={15} /></button>
            </div>
          ))}
          <p className="rack-note copy-en">Shortcuts only. Each contract is re-read from BSC before launch.</p>
          <p className="rack-note copy-zh">仅为快捷方式。创建前将从 BSC 重新读取合约。</p>
        </aside>
      </div>
    </section>
  );
}
