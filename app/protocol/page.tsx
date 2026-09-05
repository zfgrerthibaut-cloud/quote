import { LaunchCurve } from '@/components/launch-curve';

export default function ProtocolPage() {
  return (
    <main className="page-main">
      <section className="page-hero quote-page-hero" data-mast="MECHANICS">
        <span className="stage-kicker copy-en">Protocol</span>
        <span className="stage-kicker copy-zh">协议机制</span>
        <h1 className="copy-en">Market mechanics</h1>
        <h1 className="copy-zh">市场机制</h1>
      </section>
      <section className="protocol-section standalone">
        <div className="protocol-copy">
          <span className="section-label">PancakeSwap V3</span>
          <h2 className="copy-en">The position opens the market.</h2>
          <h2 className="copy-zh">流动性头寸即为市场。</h2>
          <p className="copy-en">The final configuration is shown from contract state before signature and resolved again from the launch receipt.</p>
          <p className="copy-zh">签名前从合约状态读取最终配置，并在交易回执中再次确认。</p>
        </div>
        <div className="curve-shell">
          <div className="curve-head"><span>OPENING RANGE</span><span>QUOTE / TOKEN</span></div>
          <LaunchCurve />
        </div>
        <dl className="protocol-facts">
          <div><dt>01</dt><dd><b>Token</b><span>Deterministic deployment and fixed launch supply.</span></dd></div>
          <div><dt>02</dt><dd><b>Quote</b><span>Compatible BEP-20 selected at launch.</span></dd></div>
          <div><dt>03</dt><dd><b>Position</b><span>One-sided Pancake V3 opening range.</span></dd></div>
          <div><dt>04</dt><dd><b>Receipt</b><span>Token, pool and position resolved from logs.</span></dd></div>
        </dl>
      </section>
    </main>
  );
}
