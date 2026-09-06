import { LaunchCurve } from '@/components/launch-curve';

export default function ProtocolPage() {
  return (
    <main className="page-main">
      <section className="page-hero quote-page-hero" data-mast="RULES">
        <span className="stage-kicker copy-en">Protocol / V2 design</span>
        <span className="stage-kicker copy-zh">协议机制</span>
        <h1 className="copy-en">Rules you can read.</h1>
        <h1 className="copy-zh">市场机制</h1>
      </section>
      <section className="protocol-section standalone">
        <div className="protocol-copy">
          <span className="section-label">Direct V3 launch</span>
          <h2 className="copy-en">Launch into<br />liquidity.</h2>
          <h2 className="copy-zh">流动性头寸即为市场。</h2>
          <p className="copy-en">Every token opens directly on PancakeSwap V3. The quote asset, initial price, LP range and LP fee split are verified before launch.</p>
          <p className="copy-zh">签名前从合约状态读取最终配置，并在交易回执中再次确认。</p>
        </div>
        <div className="curve-shell">
          <div className="curve-head"><span>PANCAKESWAP V3 / INITIAL PRICE</span><span>QUOTE / TOKEN</span></div>
          <LaunchCurve />
        </div>
        <dl className="protocol-facts">
          <div><dt>01</dt><dd><b>Any eligible quote</b><span>At least $10k verifiable liquidity against BNB or stablecoin.</span></dd></div>
          <div><dt>02</dt><dd><b>$7k initial FDV</b><span>The target price is converted into exact quote-token units before pool initialization.</span></dd></div>
          <div><dt>03</dt><dd><b>Standard live, Reward planned</b><span>Reward mode stays disabled until the transfer and accounting design clears review.</span></dd></div>
          <div><dt>04</dt><dd><b>Exact receipt</b><span>Token, quote, pool, initialized price and LP range resolved from logs.</span></dd></div>
        </dl>
      </section>
    </main>
  );
}
