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
          <span className="section-label">Two launch paths</span>
          <h2 className="copy-en">Direct now.<br />Curve first.</h2>
          <h2 className="copy-zh">流动性头寸即为市场。</h2>
          <p className="copy-en">Every launch binds its engine, quote asset and fee configuration. The final market is indexed from the onchain receipt.</p>
          <p className="copy-zh">签名前从合约状态读取最终配置，并在交易回执中再次确认。</p>
        </div>
        <div className="curve-shell">
          <div className="curve-head"><span>BONDING PATH / ILLUSTRATIVE</span><span>QUOTE / TOKEN</span></div>
          <LaunchCurve />
        </div>
        <dl className="protocol-facts">
          <div><dt>01</dt><dd><b>Any eligible quote</b><span>At least $10k verifiable liquidity against BNB or stablecoin.</span></dd></div>
          <div><dt>02</dt><dd><b>Direct or curve</b><span>Open the market immediately or graduate after price discovery.</span></dd></div>
          <div><dt>03</dt><dd><b>Standard or Reward</b><span>Simple fixed supply or optional holder rewards from trading fees.</span></dd></div>
          <div><dt>04</dt><dd><b>Exact receipt</b><span>Engine, token, quote, pool and modules resolved from logs.</span></dd></div>
        </dl>
      </section>
    </main>
  );
}
