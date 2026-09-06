import { ArrowRight } from 'lucide-react';
import Link from 'next/link';
import { QuoteSwitchboard } from '@/components/quote-switchboard';

export default function Home() {
  return (
    <main>
      <section className="quote-home">
        <div className="stage-title" aria-hidden="true"><span>QU</span><span>OTE</span></div>
        <div className="quote-intro">
          <h1 className="copy-en">Launch your token.<br />Quote it in any token.</h1>
          <h1 className="copy-zh">发行你的代币。<br />用任意代币计价。</h1>
          <p className="copy-en">Choose any compatible BEP-20 as the quote asset.</p>
          <p className="copy-zh">选择任意兼容的 BEP-20 作为计价币。</p>
        </div>

        <QuoteSwitchboard />

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
        <div className="stage-glyphs" aria-hidden="true"><span>+</span><i /><span>⌁</span><b>05</b></div>
      </section>
    </main>
  );
}
