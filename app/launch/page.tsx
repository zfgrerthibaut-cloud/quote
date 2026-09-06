import { LaunchDesk } from '@/components/launch-desk';

export default function LaunchPage() {
  return (
    <main className="page-main">
      <section className="launch-page-stage">
        <header className="launch-page-copy">
          <span className="stage-kicker copy-en">Create / BNB Smart Chain</span>
          <span className="stage-kicker copy-zh">创建市场</span>
          <h1 className="copy-en">Build the<br /><i>market.</i></h1>
          <h1 className="copy-zh">发行</h1>
          <p className="copy-en">One token, any eligible quote. Choose the path, fees and reward logic before anything is signed.</p>
          <p className="copy-zh">一种代币，任意符合条件的计价资产。签名前选择发行路径、费用和奖励机制。</p>
        </header>
        <LaunchDesk />
      </section>
    </main>
  );
}
