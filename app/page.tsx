import {
  ArrowDownRight,
  ArrowUpRight,
  CircleDot,
} from 'lucide-react';
import { LaunchDesk } from '@/components/launch-desk';
import { LaunchCurve } from '@/components/launch-curve';
import { QuoteExamples } from '@/components/quote-examples';
import { WalletControl } from '@/components/wallet-control';

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

      <QuoteExamples />

      <section className="curve-section" aria-labelledby="curve-title">
        <div>
          <span className="section-index">03 / PRICE RANGE</span>
          <h2 id="curve-title">The pool is the curve.</h2>
          <p>No private market maker and no graduation switch. The one-sided Pancake V3 range releases supply as buyers move the price. Exact ticks are shown before signature.</p>
          <small>Illustrative shape · not a live quote</small>
        </div>
        <LaunchCurve />
      </section>

      <section className="mechanism" id="protocol">
        <div className="mechanism-title"><span className="section-index">04 / THE CONTRACT</span><h2>One launch.<br />No hidden sequel.</h2></div>
        <ol>
          <li><span>01</span><div><h3>Deploy</h3><p>A deterministic, fixed-supply token is created from published bytecode.</p></div></li>
          <li><span>02</span><div><h3>Pair</h3><p>The quote contract, fee tier, price and range are checked onchain before signature.</p></div></li>
          <li><span>03</span><div><h3>Lock</h3><p>Supply enters the liquidity position; ownership cannot be reclaimed.</p></div></li>
          <li><span>04</span><div><h3>Trade</h3><p>Users route directly through PancakeSwap with explicit slippage.</p></div></li>
        </ol>
      </section>

      <footer><span>ForkPare / BNB Smart Chain</span><span>Local prototype · contracts not deployed</span></footer>
    </main>
  );
}
