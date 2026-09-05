'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { LocaleToggle } from '@/components/locale-toggle';
import { WalletControl } from '@/components/wallet-control';

export function SiteHeader() {
  const pathname = usePathname();

  return (
    <nav className="topbar" aria-label="Primary navigation">
      <Link className="brand" href="/" aria-label="Spot home">
        <span className="wordmark">SP<span>O</span>T</span>
      </Link>
      <div className="nav-links">
        <Link className={pathname === '/explore' ? 'active' : ''} href="/explore"><span className="copy-en">Explore</span><span className="copy-zh">市场</span></Link>
        <Link className={pathname === '/launch' ? 'active' : ''} href="/launch"><span className="copy-en">Launch</span><span className="copy-zh">创建</span></Link>
        <Link className={pathname === '/protocol' ? 'active' : ''} href="/protocol"><span className="copy-en">Protocol</span><span className="copy-zh">机制</span></Link>
      </div>
      <div className="nav-actions">
        <LocaleToggle />
        <span className="chain-light"><i /> BSC · 56</span>
        <WalletControl />
      </div>
    </nav>
  );
}
