import { RealtimeMarketFeed } from '@/components/realtime-market-feed';

export default function ExplorePage() {
  return (
    <main className="page-main">
      <section className="page-hero compact quote-page-hero" data-mast="MARKETS">
        <span className="stage-kicker copy-en">Market index</span>
        <span className="stage-kicker copy-zh">链上市场</span>
        <h1 className="copy-en">Explore markets</h1>
        <h1 className="copy-zh">浏览市场</h1>
        <p className="copy-en">Every QUOTE market from the live indexer: snapshot first, then realtime stream updates.</p>
        <p className="copy-zh">来自实时索引器的 QUOTE 市场：先读取快照，再接收实时流更新。</p>
      </section>
      <RealtimeMarketFeed />
    </main>
  );
}
