import { ArrowRight } from 'lucide-react';
import Link from 'next/link';
import { PairWeave } from '@/components/pair-weave';

export default function Home() {
  return (
    <main>
      <section className="home-stage">
        <PairWeave />
        <div className="home-seam" aria-hidden="true"><span /><i /></div>

        <div className="home-copy">
          <span className="stage-kicker copy-en">Any quote. One market.</span>
          <span className="stage-kicker copy-zh">任意计价资产，一个市场。</span>
          <h1 className="copy-en">Launch a token.<br />Pair it with any token.</h1>
          <h1 className="copy-zh">发行代币，<br />选择任意代币配对。</h1>
          <p className="copy-en">Choose any compatible BEP-20 as the quote asset.</p>
          <p className="copy-zh">选择任意兼容的 BEP-20 作为计价资产。</p>
        </div>

        <div className="home-actions">
          <Link className="home-action primary" href="/launch">
            <span><b className="copy-en">Launch token</b><b className="copy-zh">创建代币</b><small>01</small></span>
            <ArrowRight size={18} />
          </Link>
          <Link className="home-action" href="/explore">
            <span><b className="copy-en">Explore markets</b><b className="copy-zh">浏览市场</b><small>02</small></span>
            <ArrowRight size={18} />
          </Link>
        </div>

      </section>
    </main>
  );
}
