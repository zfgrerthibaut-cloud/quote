import { ArrowRight, ExternalLink } from 'lucide-react';
import Image from 'next/image';
import Link from 'next/link';
import type { Address } from 'viem';

const quoteExamples: Array<{ symbol: string; address: Address; role: string; icon?: string; mark?: string }> = [
  { symbol: 'MARSCOIN', address: '0xfe189e97832da1573e4e4ff034f4ffc3a15c7777', role: 'Flap native', icon: '/tokens/marscoin.png' },
  { symbol: 'BABAB', address: '0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec', role: 'Alibaba bStock', icon: '/tokens/alibaba.png' },
  { symbol: 'ASTER', address: '0x000Ae314E2A2172a039B26378814C252734f556A', role: 'Protocol token', icon: '/tokens/aster.jpg' },
];

export function QuoteExamples() {
  return (
    <section className="market-floor" id="markets">
      <header className="floor-header">
        <div>
          <span className="section-label copy-en">Market index</span>
          <span className="section-label copy-zh">市场列表</span>
          <h2 className="copy-en">Latest markets</h2>
          <h2 className="copy-zh">最新市场</h2>
        </div>
        <Link className="index-launch-link" href="/launch"><span className="copy-en">Launch a market</span><span className="copy-zh">创建市场</span><ArrowRight size={15} /></Link>
      </header>

      <div className="market-grid">
        <article className="empty-market">
          <div className="empty-art"><div className="empty-rack">{Array.from({ length: 6 }, (_, index) => <i key={index}><span>{String(index + 1).padStart(2, '0')}</span></i>)}</div></div>
          <div className="empty-body">
            <div><span>MARKETS</span><b>0 verified</b></div>
            <p className="copy-en">Markets will appear from verified <code>MarketLaunched</code> events after the factory is deployed.</p>
            <p className="copy-zh">工厂部署后，已验证的市场将在这里显示。</p>
          </div>
        </article>

        <aside className="quote-rack">
          <div className="rack-head">
            <span className="copy-en">Quote shortcuts</span><span className="copy-zh">计价代币</span>
            <small>BSC</small>
          </div>
          {quoteExamples.map((quote) => (
            <div className="quote-row" key={quote.symbol}>
              <span className={`quote-seal ${quote.mark ? 'quote-seal-stock' : ''}`}>
                {quote.icon ? <Image src={quote.icon} alt="" width={32} height={32} /> : <b>{quote.mark}</b>}
              </span>
              <div><b>{quote.symbol}</b><small>{quote.role}</small></div>
              <a href={`https://bscscan.com/token/${quote.address}`} target="_blank" rel="noreferrer" aria-label={`Inspect ${quote.symbol} on BscScan`}><ExternalLink size={14} /></a>
              <Link href={`/launch?quote=${quote.address}`} aria-label={`Use ${quote.symbol} as quote`}><ArrowRight size={15} /></Link>
            </div>
          ))}
          <p className="rack-note copy-en">Shortcuts only. Each contract is re-read from BSC before launch.</p>
          <p className="rack-note copy-zh">仅为快捷方式。创建前将从 BSC 重新读取合约。</p>
        </aside>
      </div>
    </section>
  );
}
