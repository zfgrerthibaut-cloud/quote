'use client';

import Image from 'next/image';
import { useEffect, useMemo, useState, type CSSProperties } from 'react';

const quotes = [
  { symbol: 'MARSCOIN', icon: '/tokens/marscoin.png', kind: 'MEME' },
  { symbol: 'BABAB', icon: '/tokens/babab.jpg', kind: 'STOCK' },
  { symbol: 'ASTER', icon: '/tokens/aster.jpg', kind: 'PROTO' },
  { symbol: '牛来', icon: '/tokens/niulai.jpg', kind: 'BSC' },
  { symbol: 'ANY BEP-20', icon: null, kind: 'CUSTOM' },
] as const;

function hash32(value: string) {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

export function PunchStrip({ value }: { value: string }) {
  const holes = useMemo(() => {
    const seed = hash32(value || 'QUOTE');
    return Array.from({ length: 20 }, (_, index) => ({
      top: 4 + ((seed >>> (index % 24)) & 3) * 5,
      tall: ((seed >>> ((index + 9) % 24)) & 1) === 1,
    }));
  }, [value]);

  return (
    <span className="punch-strip" aria-hidden="true">
      {holes.map((hole, index) => <i key={index} className={hole.tall ? 'tall' : ''} style={{ top: hole.top }} />)}
    </span>
  );
}

export function QuoteSwitchboard() {
  const [active, setActive] = useState(0);

  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const timer = window.setInterval(() => setActive((current) => (current + 1) % quotes.length), 3000);
    return () => window.clearInterval(timer);
  }, []);

  return (
    <div className="switchboard" aria-label={`Your token quoted in ${quotes[active].symbol}`}>
      <div className="board-cap">
        <span>QUOTE / SWITCHBOARD</span>
        <span>05 INPUTS · 01 MARKET</span>
      </div>
      <div className="board-body">
        <section className="base-module">
          <span className="module-slot">BASE / 00</span>
          <strong>YOUR<br />TOKEN</strong>
          <PunchStrip value="YOUR TOKEN" />
          <small>FIXED MODULE</small>
        </section>
        <div className={`slash-lock slash-${active}`} aria-hidden="true"><span>/</span><i /></div>
        <section className="quote-rack-stage">
          <div className="rack-label"><span>QUOTE INPUTS</span><b>01—05</b></div>
          <div className="cartridge-stack">
            {quotes.map((quote, index) => (
              <button
                type="button"
                className={`quote-cartridge ${index === active ? 'active' : ''}`}
                key={quote.symbol}
                onClick={() => setActive(index)}
                aria-pressed={index === active}
                aria-label={`Select ${quote.symbol} as quote token`}
              >
                <span className="cartridge-index">{String(index + 1).padStart(2, '0')}</span>
                <span className={`token-icon token-icon-${quote.kind.toLowerCase()}`}>
                  {quote.icon ? <Image src={quote.icon} alt="" width={42} height={42} /> : <i>+</i>}
                </span>
                <b>{quote.symbol}</b>
                <PunchStrip value={quote.symbol} />
              </button>
            ))}
          </div>
          <span className="selection-cursor" style={{ '--cursor-row': active } as CSSProperties} aria-hidden="true">
            <svg viewBox="0 0 28 34"><path d="M2 2v25l7-7 5 11 6-3-5-10h10z" /></svg>
            <i />
          </span>
        </section>
      </div>
      <div className="board-feet"><i /><span>SELECT / ALIGN / LOCK</span><i /></div>
    </div>
  );
}
