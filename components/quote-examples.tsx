'use client';

import { ArrowUpRight, ExternalLink } from 'lucide-react';
import type { Address } from 'viem';

const quoteExamples: Array<{
  symbol: string;
  address: Address;
  role: string;
}> = [
  {
    symbol: 'WBNB',
    address: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
    role: 'Wrapped native quote',
  },
  {
    symbol: 'USDT',
    address: '0x55d398326f99059fF775485246999027B3197955',
    role: 'Stable quote example',
  },
  {
    symbol: 'BTCB',
    address: '0x7130d2A12B9BCbFAd4f2634d864A1Ee1Ce3Ead9c',
    role: 'Bitcoin quote example',
  },
];

function chooseQuote(address: Address) {
  window.dispatchEvent(new CustomEvent('forkpare:set-quote', { detail: address }));
  document.getElementById('launch')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
  window.setTimeout(() => document.getElementById('quote-token-input')?.focus(), 350);
}

export function QuoteExamples() {
  return (
    <section className="market-strip" id="markets">
      <header>
        <div>
          <span className="section-index">02 / QUOTE EXAMPLES</span>
          <h2>Examples, never an allowlist</h2>
        </div>
        <a href="https://bscscan.com" target="_blank" rel="noreferrer">
          BscScan <ExternalLink size={15} />
        </a>
      </header>
      <div className="market-table" role="table" aria-label="Example quote assets">
        <div className="market-row table-head" role="row">
          <span>Asset</span><span>Contract</span><span>Use</span><span>Boundary</span><span aria-hidden="true" />
        </div>
        {quoteExamples.map((market) => (
          <div className="market-row" role="row" key={market.symbol}>
            <span className="pair"><i>{market.symbol.slice(0, 1)}</i><b>{market.symbol}</b></span>
            <a
              className="market-address"
              href={`https://bscscan.com/token/${market.address}`}
              target="_blank"
              rel="noreferrer"
              aria-label={`Inspect ${market.symbol} on BscScan`}
            >
              {market.address}
            </a>
            <span>{market.role}</span>
            <span className="warning-copy">Unverified until checked</span>
            <button type="button" onClick={() => chooseQuote(market.address)} aria-label={`Use ${market.symbol} as quote`}>
              <ArrowUpRight size={16} />
            </button>
          </div>
        ))}
      </div>
      <p className="table-note">
        Each address is re-read from BSC when selected. Metadata success is not a safety rating.
      </p>
    </section>
  );
}
