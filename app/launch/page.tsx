import { LaunchDesk } from '@/components/launch-desk';

export default function LaunchPage() {
  return (
    <main className="page-main">
      <section className="launch-page-stage">
        <header className="launch-page-copy">
          <span className="stage-kicker copy-en">New market</span>
          <span className="stage-kicker copy-zh">创建市场</span>
          <h1 className="copy-en">Token <i>/</i> Quote</h1>
          <h1 className="copy-zh">发行</h1>
          <p className="copy-en">Create the token. Choose any compatible BEP-20 as its quote asset.</p>
          <p className="copy-zh">创建代币，并选择任意兼容的 BEP-20 作为计价币。</p>
        </header>
        <LaunchDesk />
      </section>
    </main>
  );
}
