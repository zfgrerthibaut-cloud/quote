import { ArrowRight } from 'lucide-react';
import Link from 'next/link';
import { QuoteField } from '@/components/quote-field';

export default function Home() {
  return (
    <main>
      <section className="quote-home">
        <QuoteField symbol="TOKEN" quote="ANY" />
        <div className="quote-mast" aria-hidden="true">QUOTE</div>

        <div className="quote-intro">
          <span className="stage-kicker copy-en">BNB Chain token launchpad</span>
          <span className="stage-kicker copy-zh">BNB Chain 代币发行平台</span>
          <h1 className="copy-en">Launch your token.<br /><em>Quote it in any token.</em></h1>
          <h1 className="copy-zh">发行你的代币。<br /><em>用任意代币计价。</em></h1>
          <p className="copy-en">Choose any compatible BEP-20 as the quote asset.</p>
          <p className="copy-zh">选择任意兼容的 BEP-20 作为计价币。</p>
        </div>

        <div className="denominator" aria-label="Your token can be quoted in any compatible BEP-20">
          <div className="denominator-base">
            <small>BASE</small>
            <strong>YOUR TOKEN</strong>
          </div>
          <span className="denominator-slash">/</span>
          <div className="denominator-quotes">
            <small>QUOTE</small>
            <div><b>WBNB</b><b>USDT</b><b>BTCB</b><b>ANY BEP-20</b></div>
          </div>
        </div>

        <div className="home-actions quote-actions">
          <Link className="home-action primary" href="/launch">
            <span><b className="copy-en">Launch token</b><b className="copy-zh">创建代币</b><small>01</small></span>
            <ArrowRight size={18} />
          </Link>
          <Link className="home-action" href="/explore">
            <span><b className="copy-en">Explore markets</b><b className="copy-zh">浏览市场</b><small>02</small></span>
            <ArrowRight size={18} />
          </Link>
        </div>
        <div className="quote-index" aria-hidden="true"><span>BASE</span><i /><span>QUOTE</span></div>
      </section>
    </main>
  );
}
