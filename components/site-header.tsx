'use client';

import { usePathname } from 'next/navigation';
import { LocaleToggle } from '@/components/locale-toggle';
import { WalletControl } from '@/components/wallet-control';

export function SiteHeader() {
  const pathname = usePathname();

  return (
    <nav className="topbar" aria-label="Primary navigation">
      <a className="brand" href="/" aria-label="Quote home">
        <span className="quote-mark" aria-hidden="true"><i /></span>
        <span className="wordmark">QUOTE</span>
      </a>
      <div className="nav-links">
        <a className={pathname === '/explore' ? 'active' : ''} href="/explore"><span className="copy-en">Explore</span><span className="copy-zh">市场</span></a>
        <a className={pathname === '/launch' ? 'active' : ''} href="/launch"><span className="copy-en">Launch</span><span className="copy-zh">创建</span></a>
        <a className={pathname === '/protocol' ? 'active' : ''} href="/protocol"><span className="copy-en">Protocol</span><span className="copy-zh">机制</span></a>
      </div>
      <div className="nav-actions">
        <LocaleToggle />
        <WalletControl />
      </div>
    </nav>
  );
}
