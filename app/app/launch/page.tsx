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
          <p className="copy-en">One token, any eligible quote. Review the market and LP fee split before contracts are live.</p>
          <p className="copy-zh">一种代币，任意符合条件的计价资产。合约上线前仅用于检查市场配置与 LP 费用分配。</p>
        </header>
        <LaunchDesk />
      </section>
    </main>
  );
}
