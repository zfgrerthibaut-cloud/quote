import { QuoteExamples } from '@/components/quote-examples';

export default function ExplorePage() {
  return (
    <main className="page-main">
      <section className="page-hero compact quote-page-hero" data-mast="MARKETS">
        <span className="stage-kicker copy-en">Market index</span>
        <span className="stage-kicker copy-zh">链上市场</span>
        <h1 className="copy-en">Explore markets</h1>
        <h1 className="copy-zh">浏览市场</h1>
        <p className="copy-en">Every market created through QUOTE, indexed from its launch receipt.</p>
        <p className="copy-zh">所有通过 QUOTE 创建的市场，均从链上交易回执索引。</p>
      </section>
      <QuoteExamples />
    </main>
  );
}
