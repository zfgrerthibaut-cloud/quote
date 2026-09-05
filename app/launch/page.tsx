import { LaunchDesk } from '@/components/launch-desk';
import { PairWeave } from '@/components/pair-weave';

export default function LaunchPage() {
  return (
    <main className="page-main">
      <section className="launch-page-stage">
        <PairWeave />
        <header className="launch-page-copy">
          <span className="stage-kicker copy-en">Create market</span>
          <span className="stage-kicker copy-zh">创建市场</span>
          <h1 className="copy-en">Launch</h1>
          <h1 className="copy-zh">发行</h1>
          <p className="copy-en">Create the token, then choose any compatible BEP-20 as its quote asset.</p>
          <p className="copy-zh">创建代币，然后选择任意兼容的 BEP-20 作为计价资产。</p>
        </header>
        <LaunchDesk />
      </section>
    </main>
  );
}
