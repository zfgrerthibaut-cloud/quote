import { QuoteExamples } from '@/components/quote-examples';

export default function ExplorePage() {
  return (
    <main className="page-main">
      <section className="page-hero compact">
        <span className="stage-kicker copy-en">Onchain markets</span>
        <span className="stage-kicker copy-zh">链上市场</span>
        <h1 className="copy-en">Explore</h1>
        <h1 className="copy-zh">浏览市场</h1>
        <p className="copy-en">Markets created by the verified SPOT factory.</p>
        <p className="copy-zh">由已验证的 SPOT 工厂创建的市场。</p>
      </section>
      <QuoteExamples />
    </main>
  );
}
