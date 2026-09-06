'use client';

import { ImagePlus, LoaderCircle, LockKeyhole, MousePointer2, ShieldCheck, Sparkles, TriangleAlert } from 'lucide-react';
import { motion } from 'motion/react';
import Image from 'next/image';
import { useEffect, useMemo, useState } from 'react';
import { erc20Abi, isAddress, type Address } from 'viem';
import { usePublicClient } from 'wagmi';

const quoteAssets = [
  { symbol: 'MARSCOIN', address: '0xfe189e97832da1573e4e4ff034f4ffc3a15c7777', image: '/tokens/marscoin.png' },
  { symbol: 'BABAB', address: '0xe5ae318389b8d6d09370a675479c64862152d126', image: '/tokens/alibaba.png' },
  { symbol: 'ASTER', address: '0x000Ae314E2A2172a039B26378814C252734f556A', image: '/tokens/aster.jpg' },
] as const;

const PLATFORM_FEE_BPS = 25;

type TokenMode = 'Standard' | 'Reward';
type QuoteStatus = { state: 'idle' | 'loading' | 'valid' | 'invalid'; symbol?: string; decimals?: number; note?: string };

function Choice<T extends string>({ value, current, onSelect, label, note }: { value: T; current: T; onSelect: (value: T) => void; label: string; note: string }) {
  const active = value === current;
  return (
    <button className={`choice-card ${active ? 'active' : ''}`} type="button" onClick={() => onSelect(value)} aria-pressed={active}>
      {active && <motion.i layoutId="choice-mode" transition={{ type: 'spring', stiffness: 430, damping: 36 }} />}
      <span>{label}</span><small>{note}</small>
    </button>
  );
}

function FeeRail({ label, detail, values, value, onChange }: { label: string; detail: string; values: number[]; value: number; onChange: (value: number) => void }) {
  return (
    <div className="fee-control">
      <div className="control-copy"><b>{label}</b><small>{detail}</small></div>
      <div className="fee-buttons">
        {values.map((fee) => (
          <button key={fee} type="button" className={fee === value ? 'active' : ''} onClick={() => onChange(fee)}>
            {fee === value && <motion.i layoutId={`fee-${label}`} transition={{ type: 'spring', stiffness: 460, damping: 38 }} />}
            <span>{fee === 0 ? 'Off' : `${(fee / 100).toFixed(2)}%`}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

export function LaunchDesk() {
  const publicClient = usePublicClient();
  const [name, setName] = useState('');
  const [symbol, setSymbol] = useState('');
  const [mode, setMode] = useState<TokenMode>('Standard');
  const [quoteAddress, setQuoteAddress] = useState<string>(quoteAssets[0].address);
  const [quote, setQuote] = useState<QuoteStatus>({ state: 'idle', symbol: 'MARSCOIN' });
  const [quoteImageFailed, setQuoteImageFailed] = useState(false);
  const [imageUrl, setImageUrl] = useState<string>();
  const [devBuy, setDevBuy] = useState(false);
  const [devBuyBnb, setDevBuyBnb] = useState('0.25');
  const [creatorFee, setCreatorFee] = useState(25);
  const [rewardFee, setRewardFee] = useState(50);
  const [creatorLpShare, setCreatorLpShare] = useState(7000);
  const [reviewed, setReviewed] = useState(false);

  const totalTax = PLATFORM_FEE_BPS + creatorFee + (mode === 'Reward' ? rewardFee : 0);
  const activeQuote = quoteAssets.find((asset) => asset.address.toLowerCase() === quoteAddress.toLowerCase());
  const resolvedQuoteImage = isAddress(quoteAddress) && quote.state === 'valid' && !quoteImageFailed
    ? `/api/token-image/${quoteAddress.toLowerCase()}`
    : activeQuote?.image;
  const previewImage = imageUrl || undefined;
  const complete = Boolean(name.trim() && symbol.trim() && quote.state === 'valid');

  useEffect(() => () => { if (imageUrl?.startsWith('blob:')) URL.revokeObjectURL(imageUrl); }, [imageUrl]);

  useEffect(() => {
    const address = new URLSearchParams(window.location.search).get('quote');
    if (address && isAddress(address)) queueMicrotask(() => setQuoteAddress(address));
  }, []);

  useEffect(() => {
    let cancelled = false;
    const timer = window.setTimeout(async () => {
      if (!publicClient || !isAddress(quoteAddress)) {
        setQuote({ state: quoteAddress ? 'invalid' : 'idle', note: quoteAddress ? 'Enter a valid BSC token address.' : undefined });
        return;
      }
      setQuote({ state: 'loading' });
      try {
        const address = quoteAddress as Address;
        const code = await publicClient.getCode({ address });
        if (!code || code === '0x') throw new Error('No contract found at this address on BSC.');
        const [tokenSymbol, decimals] = await Promise.all([
          publicClient.readContract({ address, abi: erc20Abi, functionName: 'symbol' }),
          publicClient.readContract({ address, abi: erc20Abi, functionName: 'decimals' }),
        ]);
        if (!cancelled) setQuote({ state: 'valid', symbol: tokenSymbol, decimals, note: 'Contract and metadata read from BSC.' });
      } catch (error) {
        if (!cancelled) setQuote({ state: 'invalid', note: error instanceof Error ? error.message : 'Token could not be verified.' });
      }
    }, 380);
    return () => { cancelled = true; window.clearTimeout(timer); };
  }, [publicClient, quoteAddress]);

  const receiptRows = useMemo(() => [
    ['Market', 'Pancake V3'],
    ['Initial FDV', '$7,000 target'],
    ['Token', mode],
    ['Supply', '100,000,000'],
    ['Quote', quote.symbol || '—'],
    ['Dev buy', devBuy ? `${devBuyBnb || '0'} BNB` : 'Off'],
    ['Pool sell fee', 'Pool default'],
    ['Platform fee', `${(PLATFORM_FEE_BPS / 100).toFixed(2)}%`],
    ['Creator swap fee', creatorFee ? `${(creatorFee / 100).toFixed(2)}%` : 'Off'],
    ['Reward fee', mode === 'Reward' ? `${(rewardFee / 100).toFixed(2)}%` : '—'],
    ['Creator fee split', `${(creatorLpShare / 100).toFixed(0)}%`],
    ['Hook total', `${(totalTax / 100).toFixed(2)}%`],
  ], [creatorFee, creatorLpShare, devBuy, devBuyBnb, mode, quote.symbol, rewardFee, totalTax]);

  function selectQuote(asset: typeof quoteAssets[number]) {
    setQuoteAddress(asset.address);
    setQuote({ state: 'idle', symbol: asset.symbol });
    setQuoteImageFailed(false);
    setReviewed(false);
  }

  function handleImage(file?: File) {
    if (!file) return;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type) || file.size > 4 * 1024 * 1024) return;
    setImageUrl((current) => {
      if (current?.startsWith('blob:')) URL.revokeObjectURL(current);
      return URL.createObjectURL(file);
    });
  }

  return (
    <div className="launch-workbench">
      <form className="launch-form" onSubmit={(event) => { event.preventDefault(); if (complete) setReviewed(true); }}>
        <header className="form-head"><div><span>CREATE / 01</span><h2>Token / Quote</h2></div><b>V2 DRAFT</b></header>

        <div className="route-plate" aria-hidden="true">
          <div className="route-disc base">
            <small>TOKEN</small>
            <strong>{symbol || 'QUOTE'}</strong>
            <i />
          </div>
          <div className="route-blade">/</div>
          <div className="route-disc asset">
            {resolvedQuoteImage ? <Image src={resolvedQuoteImage} alt="" fill unoptimized onError={() => setQuoteImageFailed(true)} /> : <span>?</span>}
            <small>QUOTE</small>
          </div>
          <div className="route-cursor"><MousePointer2 size={22} /><i /></div>
        </div>

        <section className="form-section">
          <div className="section-number"><span>01</span><div><b>Identity</b><small className="copy-en">Permanent token details</small><small className="copy-zh">永久代币信息</small></div></div>
          <div className="identity-grid">
            <label><span className="copy-en">Token name</span><span className="copy-zh">代币名称</span><input value={name} onChange={(event) => { setName(event.target.value); setReviewed(false); }} placeholder="Mars Station" maxLength={64} /></label>
            <label><span className="copy-en">Ticker</span><span className="copy-zh">代码</span><input value={symbol} onChange={(event) => { setSymbol(event.target.value.replace(/[^a-zA-Z0-9]/g, '').toUpperCase()); setReviewed(false); }} placeholder="MARS" maxLength={12} /></label>
            <label className="image-drop">
              <input type="file" accept="image/png,image/jpeg,image/webp" onChange={(event) => handleImage(event.target.files?.[0])} />
              <span>{previewImage ? <Image src={previewImage} alt="Token preview" fill unoptimized /> : <ImagePlus size={19} />}</span>
              <div><b className="copy-en">{previewImage ? 'Image selected' : 'Add image'}</b><b className="copy-zh">{previewImage ? '已选择图片' : '添加图片'}</b><small>PNG, JPG, WebP / 4 MB</small></div>
            </label>
          </div>
        </section>

        <section className="form-section">
          <div className="section-number"><span>02</span><div><b>Market</b><small className="copy-en">Direct liquidity from block one</small><small className="copy-zh">首区块直接开放流动性</small></div></div>
          <div className="fixed-market-path">
            <div><b>PancakeSwap V3</b><small>Permanent LP position</small></div>
            <span><b>$7,000</b><small>INITIAL FDV TARGET</small></span>
          </div>
          <div className="choice-grid">
            <Choice value="Standard" current={mode} onSelect={(next) => { setMode(next); setReviewed(false); }} label="Standard token" note="Simple fixed supply" />
            <Choice value="Reward" current={mode} onSelect={(next) => { setMode(next); setReviewed(false); }} label="Reward token" note="Fees accrue to holders" />
          </div>
        </section>

        <section className="form-section">
          <div className="section-number"><span>03</span><div><b>Quote asset</b><small className="copy-en">Any eligible BEP-20</small><small className="copy-zh">任意合格 BEP-20</small></div></div>
          <div className="quote-picks">
            {quoteAssets.map((asset) => <button className={activeQuote?.symbol === asset.symbol ? 'active' : ''} key={asset.symbol} type="button" onClick={() => selectQuote(asset)}><Image src={asset.image} alt="" width={28} height={28} /><b>{asset.symbol}</b></button>)}
            <button className={!activeQuote ? 'active' : ''} type="button" onClick={() => { setQuoteAddress(''); setQuote({ state: 'idle' }); setQuoteImageFailed(false); setReviewed(false); }}>+ CUSTOM</button>
          </div>
          <label className="address-field"><span className="copy-en">Contract address</span><span className="copy-zh">合约地址</span><div><input value={quoteAddress} onChange={(event) => { setQuoteAddress(event.target.value.trim()); setQuoteImageFailed(false); setReviewed(false); }} spellCheck={false} />{quote.state === 'loading' && <LoaderCircle className="spin" size={16} />}{quote.state === 'valid' && <ShieldCheck size={16} />}</div></label>
          {quote.note && <p className={`quote-check ${quote.state}`}><span />{quote.symbol && <b>{quote.symbol} · {quote.decimals} decimals</b>}{quote.note}</p>}
          <p className="eligibility-note"><LockKeyhole size={13} /> Launch requires at least $10,000 of verifiable quote-token liquidity against stablecoin or BNB.</p>
        </section>

        <section className="form-section economics">
          <div className="section-number"><span>04</span><div><b>Economics</b><small className="copy-en">Set before launch</small><small className="copy-zh">发行前固定</small></div></div>
          <div className="fixed-fee-row"><div><b>Pool sell fee</b><small>Base pool default</small></div><span>READ ONLY</span></div>
          <FeeRail label="Creator swap fee" detail="Max 1.00%" values={[0, 25, 50, 100]} value={creatorFee} onChange={(next) => { setCreatorFee(next); setReviewed(false); }} />
          {mode === 'Reward' && <motion.div initial={{ opacity: 0, height: 0 }} animate={{ opacity: 1, height: 'auto' }}><FeeRail label="Reward fee" detail="Distributed to holders" values={[25, 50, 100, 300]} value={rewardFee} onChange={(next) => { setRewardFee(next); setReviewed(false); }} /></motion.div>}
          <FeeRail label="Creator fee split" detail="Collected pool fees" values={[0, 5000, 7000, 10000]} value={creatorLpShare} onChange={(next) => { setCreatorLpShare(next); setReviewed(false); }} />
          <div className="dev-buy-row">
            <button type="button" className={devBuy ? 'active' : ''} onClick={() => { setDevBuy(!devBuy); setReviewed(false); }}><span>{devBuy && <motion.i layoutId="dev-buy-toggle" />}</span><div><b>Creator buy</b><small>Buy at launch directly with BNB</small></div></button>
            {devBuy && <motion.label initial={{ opacity: 0, x: -8 }} animate={{ opacity: 1, x: 0 }}><input value={devBuyBnb} onChange={(event) => setDevBuyBnb(event.target.value)} inputMode="decimal" /><b>BNB</b></motion.label>}
          </div>
        </section>

        <button className={`review-button ${reviewed ? 'reviewed' : ''}`} type="submit" disabled={!complete}>{reviewed ? <><ShieldCheck size={17} /> Configuration ready</> : <><span>Review configuration</span><Sparkles size={16} /></>}</button>
        <p className="form-caveat"><TriangleAlert size={12} /> Nothing is sent. V2 contracts are not deployed yet.</p>
      </form>

      <aside className="launch-receipt">
        <div className="receipt-top"><span>LAUNCH RECEIPT</span><b>{reviewed ? 'READY' : 'DRAFT'}</b></div>
        <div className="receipt-art">
          <div className="receipt-token">{previewImage ? <Image src={previewImage} alt="" fill unoptimized /> : <span>{symbol.slice(0, 2) || 'QT'}</span>}</div>
          <i>/</i>
          <div className="receipt-token quote">{resolvedQuoteImage ? <Image src={resolvedQuoteImage} alt="" fill unoptimized onError={() => setQuoteImageFailed(true)} /> : <span>{(quote.symbol || '?').slice(0, 2)}</span>}</div>
          <div><small>MARKET</small><strong>{symbol || 'TOKEN'} / {quote.symbol || 'QUOTE'}</strong></div>
        </div>
        <div className="receipt-rows">{receiptRows.map(([label, value]) => <div key={label}><span>{label}</span><b>{value}</b></div>)}</div>
        <div className="fee-composition"><span style={{ width: `${Math.min(100, (PLATFORM_FEE_BPS / totalTax) * 100)}%` }} /><span style={{ width: `${Math.min(100, (creatorFee / totalTax) * 100)}%` }} />{mode === 'Reward' && <span style={{ width: `${Math.min(100, (rewardFee / totalTax) * 100)}%` }} />}</div>
        <p><LockKeyhole size={12} /> Market rules become permanent at launch.</p>
      </aside>
    </div>
  );
}
