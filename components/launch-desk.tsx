'use client';

import { zodResolver } from '@hookform/resolvers/zod';
import { ArrowUpRight, Check, LoaderCircle, ShieldCheck, TriangleAlert } from 'lucide-react';
import { AnimatePresence, motion } from 'motion/react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { erc20Abi, isAddress } from 'viem';
import { useAccount, useChainId, usePublicClient, useSwitchChain } from 'wagmi';
import { bsc } from 'wagmi/chains';
import { z } from 'zod';

const launchSchema = z.object({
  name: z.string().trim().min(1, 'Enter a token name').max(64, '64 characters maximum'),
  symbol: z.string().trim().min(1, 'Enter a ticker').max(12, '12 characters maximum').regex(/^[A-Za-z0-9]+$/, 'Letters and numbers only'),
  quoteToken: z.string().trim().refine(isAddress, 'Enter a valid BEP-20 address'),
});

type LaunchForm = z.infer<typeof launchSchema>;
type QuoteState = { status: 'idle' | 'checking' | 'valid' | 'invalid'; symbol?: string; decimals?: number; note?: string };

export function LaunchDesk() {
  const publicClient = usePublicClient();
  const chainId = useChainId();
  const { isConnected } = useAccount();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const [quote, setQuote] = useState<QuoteState>({ status: 'idle' });
  const form = useForm<LaunchForm>({
    resolver: zodResolver(launchSchema),
    defaultValues: {
      name: 'Fork Market',
      symbol: 'FORK',
      quoteToken: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
    },
  });

  const validateQuote = form.handleSubmit(async ({ quoteToken }) => {
    if (!publicClient) return;
    setQuote({ status: 'checking' });
    try {
      const bytecode = await publicClient.getCode({ address: quoteToken as `0x${string}` });
      if (!bytecode || bytecode === '0x') {
        setQuote({ status: 'invalid', note: 'No contract code at this address on BSC.' });
        return;
      }

      const [symbol, decimals] = await Promise.all([
        publicClient.readContract({ address: quoteToken as `0x${string}`, abi: erc20Abi, functionName: 'symbol' }),
        publicClient.readContract({ address: quoteToken as `0x${string}`, abi: erc20Abi, functionName: 'decimals' }),
      ]);
      setQuote({ status: 'valid', symbol, decimals, note: 'ERC-20 metadata responds. Transfer behavior is not guaranteed.' });
    } catch {
      setQuote({ status: 'invalid', note: 'This contract does not expose standard ERC-20 metadata.' });
    }
  });

  const wrongNetwork = isConnected && chainId !== bsc.id;
  const ctaLabel = wrongNetwork ? 'Switch to BSC' : quote.status === 'checking' ? 'Reading BSC state…' : quote.status === 'valid' ? 'Launch preview ready' : 'Validate quote on BSC';

  return (
    <div className="launch-desk" id="launch">
      <div className="desk-head">
        <div><span className="section-index">01 / CREATE MARKET</span><h2>Configure the pair</h2></div>
        <span className="network-pill"><span /> BSC · 56</span>
      </div>

      <form onSubmit={validateQuote} noValidate>
        <div className="field-grid">
          <label>
            <span>Token name</span>
            <input aria-invalid={Boolean(form.formState.errors.name)} {...form.register('name')} />
            {form.formState.errors.name && <small className="field-error">{form.formState.errors.name.message}</small>}
          </label>
          <label>
            <span>Ticker</span>
            <input aria-invalid={Boolean(form.formState.errors.symbol)} maxLength={12} {...form.register('symbol')} />
            {form.formState.errors.symbol && <small className="field-error">{form.formState.errors.symbol.message}</small>}
          </label>
        </div>

        <label className="quote-field">
          <span>Quote token address</span>
          <div className="quote-address-field">
            <input aria-invalid={Boolean(form.formState.errors.quoteToken)} {...form.register('quoteToken', { onChange: () => setQuote({ status: 'idle' }) })} />
            {quote.status === 'checking' && <LoaderCircle className="spin" size={17} />}
            {quote.status === 'valid' && <Check size={17} />}
          </div>
          {form.formState.errors.quoteToken && <small className="field-error">{form.formState.errors.quoteToken.message}</small>}
        </label>

        <AnimatePresence initial={false}>
          {quote.status !== 'idle' && quote.status !== 'checking' && (
            <motion.div
              className={`quote-result ${quote.status}`}
              role="status"
              initial={{ opacity: 0, y: -4 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.16 }}
            >
              {quote.status === 'valid' ? <Check size={15} /> : <TriangleAlert size={15} />}
              <span>{quote.symbol && <b>{quote.symbol} · {quote.decimals} decimals</b>}{quote.note}</span>
            </motion.div>
          )}
        </AnimatePresence>

        <div className="launch-summary">
          <div><span>Supply</span><b>100,000,000</b></div>
          <div><span>Creator fees</span><b>70%</b></div>
          <div><span>LP position</span><b><ShieldCheck size={14} /> Permanent</b></div>
        </div>

        <button
          className="launch-button"
          type={wrongNetwork ? 'button' : 'submit'}
          disabled={quote.status === 'checking' || isSwitching}
          onClick={wrongNetwork ? () => switchChain({ chainId: bsc.id }) : undefined}
        >
          {ctaLabel} <ArrowUpRight size={18} />
        </button>
      </form>

      <p className="desk-note"><Check size={13} /> No mint key · no creator allocation · no transaction sent during preview</p>
    </div>
  );
}
