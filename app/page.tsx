import {
  ArrowDownRight,
  ArrowUpRight,
  CircleDot,
  ExternalLink,
  Search,
} from 'lucide-react';
import { LaunchDesk } from '@/components/launch-desk';
import { WalletControl } from '@/components/wallet-control';

const markets = [
  { symbol: 'WBNB', address: '0xbb4C…095c', role: 'Native route', status: 'Code found' },
  { symbol: 'USDT', address: '0x55d3…7955', role: 'Stable quote', status: 'Code found' },
  { symbol: 'BTCB', address: '0x7130…ad9c', role: 'Bitcoin quote', status: 'Code found' },
];

export default function Home() {
  return (
    <main>
      <nav className="topbar" aria-label="Primary navigation">
        <a className="brand" href="#top" aria-label="ForkPare home">
          <span className="brand-cut" aria-hidden="true">F/P</span>
          <span>ForkPare</span>
        </a>
        <div className="nav-links">
          <a href="#markets">Markets</a>
          <a href="#launch">Launch</a>
          <a href="#protocol">Protocol</a>
        </div>
        <div className="nav-actions">
          <button className="search-button" type="button" aria-label="Search markets">
            <Search size={16} /> <span>Search</span><kbd>/</kbd>
          </button>
          <WalletControl />
        </div>
      </nav>

      <section className="hero" id="top">
        <div className="hero-copy">
          <div className="eyebrow"><CircleDot size={13} /> BNB Smart Chain · permissionless markets</div>
          <h1>Launch a token.<br /><em>Choose what it trades against.</em></h1>
          <p className="lede">
            Fixed supply, single transaction, permanent liquidity position. Pair against WBNB,
            stables, BTCB—or any compatible BEP-20 you can verify.
          </p>
          <div className="hero-actions">
            <a className="primary-cta" href="#launch">Open launch desk <ArrowDownRight size={18} /></a>
            <a className="text-link" href="#protocol">Read the mechanism <ArrowUpRight size={16} /></a>
          </div>
        </div>

        <LaunchDesk />
      </section>

      <section className="market-strip" id="markets">
        <header>
          <div><span className="section-index">02 / QUOTE EXAMPLES</span><h2>Quote assets, not an allowlist</h2></div>
          <a href="https://bscscan.com" target="_blank" rel="noreferrer">BscScan <ExternalLink size={15} /></a>
        </header>
        <div className="market-table" role="table" aria-label="Example quote assets">
          <div className="market-row table-head" role="row">
            <span>Asset</span><span>Address</span><span>Use</span><span>RPC check</span><span aria-hidden="true" />
          </div>
          {markets.map((market) => (
            <div className="market-row" role="row" key={market.symbol}>
              <span className="pair"><i>{market.symbol.slice(0, 1)}</i><b>{market.symbol}</b></span>
              <span>{market.address}</span><span>{market.role}</span>
              <span className="positive">{market.status}</span>
              <button type="button" aria-label={`Use ${market.symbol} as quote`}><ArrowUpRight size={16} /></button>
            </div>
          ))}
        </div>
        <p className="table-note">Read-only snapshot · BSC block 120,162,155. Contract code is not a safety rating.</p>
      </section>

      <section className="mechanism" id="protocol">
        <div className="mechanism-title"><span className="section-index">03 / THE CONTRACT</span><h2>One launch.<br />No hidden sequel.</h2></div>
        <ol>
          <li><span>01</span><div><h3>Deploy</h3><p>A deterministic fixed-supply token is created from audited bytecode.</p></div></li>
          <li><span>02</span><div><h3>Pair</h3><p>The chosen quote asset and fee tier are validated onchain.</p></div></li>
          <li><span>03</span><div><h3>Lock</h3><p>Supply enters the liquidity position; ownership cannot be reclaimed.</p></div></li>
          <li><span>04</span><div><h3>Trade</h3><p>Users route directly through PancakeSwap with explicit slippage.</p></div></li>
        </ol>
      </section>

      <footer><span>ForkPare / BNB Smart Chain</span><span>Local prototype · contracts not deployed</span></footer>
    </main>
  );
}
