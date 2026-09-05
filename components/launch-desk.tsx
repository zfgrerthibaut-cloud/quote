'use client';

import { zodResolver } from '@hookform/resolvers/zod';
import { ArrowUpRight, Check, LoaderCircle, ShieldCheck, TriangleAlert } from 'lucide-react';
import { AnimatePresence, motion } from 'motion/react';
import { useEffect, useMemo, useState } from 'react';
import { useForm, useWatch } from 'react-hook-form';
import { erc20Abi, formatEther, isAddress, keccak256, parseEventLogs, stringToHex, type Address, type Hash } from 'viem';
import {
  useAccount,
  useChainId,
  usePublicClient,
  useSwitchChain,
  useWaitForTransactionReceipt,
  useWriteContract,
} from 'wagmi';
import { bsc } from 'wagmi/chains';
import { z } from 'zod';

import {
  buildPriceRange,
  configuredFactory,
  DEFAULT_FEE_TIER,
  FEE_TICK_SPACING,
  FIXED_SUPPLY,
  forkPareFactoryAbi,
  type SupportedFeeTier,
  type LaunchParams,
} from '@/lib/forkpare';

const launchSchema = z.object({
  name: z.string().trim().min(1, 'Enter a token name').max(64, '64 characters maximum'),
  symbol: z.string().trim().min(1, 'Enter a ticker').max(12, '12 characters maximum').regex(/^[A-Za-z0-9]+$/, 'Letters and numbers only'),
  quoteToken: z.string().trim().refine(isAddress, 'Enter a valid BEP-20 address'),
  startingPrice: z.string().trim().regex(/^\d+(\.\d+)?$/, 'Enter a positive decimal price').refine((value) => Number(value) > 0, 'Price must be above zero'),
  feeTier: z.coerce.number().refine((value) => value === 100 || value === 500 || value === 2500 || value === 10000, 'Choose a Pancake V3 fee tier'),
});

type LaunchForm = z.infer<typeof launchSchema>;
type QuoteState = { status: 'idle' | 'checking' | 'valid' | 'invalid'; symbol?: string; decimals?: number; note?: string };
type PreparedLaunch = { params: LaunchParams; predictedToken: Address; creationFee: bigint };

function addressNumber(address: Address) {
  return BigInt(address.toLowerCase());
}

export function LaunchDesk() {
  const publicClient = usePublicClient();
  const chainId = useChainId();
  const { address, isConnected } = useAccount();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const { writeContract, data: transactionHash, isPending: isSigning, error: writeError } = useWriteContract();
  const receipt = useWaitForTransactionReceipt({ hash: transactionHash as Hash | undefined });
  const [quote, setQuote] = useState<QuoteState>({ status: 'idle' });
  const [prepared, setPrepared] = useState<PreparedLaunch>();
  const [prepareError, setPrepareError] = useState<string>();
  const factory = configuredFactory();

  const form = useForm<LaunchForm>({
    resolver: zodResolver(launchSchema),
    defaultValues: {
      name: 'Fork Market',
      symbol: 'FORK',
      quoteToken: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
      startingPrice: '0.000001',
      feeTier: DEFAULT_FEE_TIER,
    },
  });
  const selectedFeeTier = useWatch({ control: form.control, name: 'feeTier' });

  useEffect(() => {
    const selectQuote = (event: Event) => {
      const address = (event as CustomEvent<Address>).detail;
      if (!isAddress(address)) return;
      form.setValue('quoteToken', address, { shouldDirty: true, shouldValidate: true });
      setQuote({ status: 'idle' });
      resetPreparation();
    };
    window.addEventListener('forkpare:set-quote', selectQuote);
    return () => window.removeEventListener('forkpare:set-quote', selectQuote);
  }, [form]);

  const launchedMarket = useMemo(() => {
    if (!receipt.data) return undefined;
    const logs = parseEventLogs({
      abi: forkPareFactoryAbi,
      eventName: 'MarketLaunched',
      logs: receipt.data.logs,
      strict: false,
    });
    return logs[0]?.args;
  }, [receipt.data]);

  function resetPreparation() {
    setPrepared(undefined);
    setPrepareError(undefined);
  }

  async function buildPreparedLaunch(values: LaunchForm, quoteDecimals: number, deadline: bigint) {
    if (!publicClient || !factory || !address) return;
    const quoteToken = values.quoteToken as Address;
    const creationFee = await publicClient.readContract({
      address: factory,
      abi: forkPareFactoryAbi,
      functionName: 'creationFee',
    });

    for (let attempt = 0; attempt < 64; attempt += 1) {
      for (const launchTokenIsToken0 of [true, false]) {
        const feeTier = values.feeTier as SupportedFeeTier;
        const range = buildPriceRange(
          values.startingPrice,
          quoteDecimals,
          launchTokenIsToken0,
          FEE_TICK_SPACING[feeTier],
        );
        const userSalt = keccak256(stringToHex(`${address}:${values.name}:${values.symbol}:${attempt}`));
        const params: LaunchParams = {
          name: values.name.trim(),
          symbol: values.symbol.trim().toUpperCase(),
          supply: FIXED_SUPPLY,
          quoteToken,
          feeTier,
          sqrtPriceX96: range.sqrtPriceX96,
          tickLower: range.tickLower,
          tickUpper: range.tickUpper,
          deadline,
          userSalt,
        };
        const predictedToken = await publicClient.readContract({
          address: factory,
          abi: forkPareFactoryAbi,
          functionName: 'predictToken',
          args: [address, params],
        });
        const consistent = launchTokenIsToken0
          ? addressNumber(predictedToken) < addressNumber(quoteToken)
          : addressNumber(predictedToken) > addressNumber(quoteToken);
        if (!consistent) continue;

        await publicClient.simulateContract({
          account: address,
          address: factory,
          abi: forkPareFactoryAbi,
          functionName: 'launch',
          args: [params],
          value: creationFee,
        });
        setPrepared({ params, predictedToken, creationFee });
        return;
      }
    }
    throw new Error('Could not derive a deterministic token ordering. Change the token name and retry.');
  }

  const validateAndPrepare = form.handleSubmit(async (values) => {
    if (!publicClient) return;
    resetPreparation();
    setQuote({ status: 'checking' });
    let metadataValid = false;
    try {
      const quoteToken = values.quoteToken as Address;
      const bytecode = await publicClient.getCode({ address: quoteToken });
      if (!bytecode || bytecode === '0x') {
        setQuote({ status: 'invalid', note: 'No contract code at this address on BSC.' });
        return;
      }
      const [symbol, decimals] = await Promise.all([
        publicClient.readContract({ address: quoteToken, abi: erc20Abi, functionName: 'symbol' }),
        publicClient.readContract({ address: quoteToken, abi: erc20Abi, functionName: 'decimals' }),
      ]);
      const validQuote: QuoteState = {
        status: 'valid', symbol, decimals,
        note: 'ERC-20 metadata responds. Transfer behavior is not guaranteed.',
      };
      setQuote(validQuote);
      metadataValid = true;
      if (factory && address) {
        const latestBlock = await publicClient.getBlock({ blockTag: 'latest' });
        const deadline = latestBlock.timestamp + 600n;
        await buildPreparedLaunch(values, decimals, deadline);
      }
    } catch (error) {
      if (metadataValid) {
        setPrepareError(error instanceof Error ? error.message : 'Launch simulation failed.');
      } else {
        setQuote({ status: 'invalid', note: 'Metadata or launch simulation did not pass.' });
      }
    }
  });

  function submitPreparedLaunch() {
    if (!factory || !prepared) return;
    writeContract({
      address: factory,
      abi: forkPareFactoryAbi,
      functionName: 'launch',
      args: [prepared.params],
      value: prepared.creationFee,
    });
  }

  const wrongNetwork = isConnected && chainId !== bsc.id;
  const isBusy = quote.status === 'checking' || isSwitching || isSigning || receipt.isLoading;
  const ctaLabel = wrongNetwork
    ? 'Switch to BSC'
    : isSigning
      ? 'Confirm in wallet…'
      : receipt.isLoading
        ? 'Waiting for receipt…'
        : prepared
          ? `Launch · ${formatEther(prepared.creationFee)} BNB`
          : quote.status === 'checking'
            ? 'Reading BSC state…'
            : quote.status === 'valid' && !factory
              ? 'Read-only preview ready'
              : 'Validate and simulate';

  return (
    <div className="launch-desk" id="launch">
      <div className="desk-head">
        <div><span className="section-index">01 / CREATE MARKET</span><h2>Configure the pair</h2></div>
        <span className="network-pill"><span /> BSC · 56</span>
      </div>

      <form onSubmit={prepared ? (event) => { event.preventDefault(); submitPreparedLaunch(); } : validateAndPrepare} noValidate>
        <div className="field-grid">
          <label>
            <span>Token name</span>
            <input aria-invalid={Boolean(form.formState.errors.name)} {...form.register('name', { onChange: resetPreparation })} />
            {form.formState.errors.name && <small className="field-error">{form.formState.errors.name.message}</small>}
          </label>
          <label>
            <span>Ticker</span>
            <input aria-invalid={Boolean(form.formState.errors.symbol)} maxLength={12} {...form.register('symbol', { onChange: resetPreparation })} />
            {form.formState.errors.symbol && <small className="field-error">{form.formState.errors.symbol.message}</small>}
          </label>
        </div>

        <label className="quote-field">
          <span>Quote token address</span>
          <div className="quote-address-field">
            <input id="quote-token-input" aria-invalid={Boolean(form.formState.errors.quoteToken)} {...form.register('quoteToken', { onChange: () => { setQuote({ status: 'idle' }); resetPreparation(); } })} />
            {quote.status === 'checking' && <LoaderCircle className="spin" size={17} />}
            {quote.status === 'valid' && <Check size={17} />}
          </div>
          {form.formState.errors.quoteToken && <small className="field-error">{form.formState.errors.quoteToken.message}</small>}
        </label>

        <div className="price-fee-grid">
          <label className="price-field">
            <span>Starting price · quote per 1 token</span>
            <input inputMode="decimal" aria-invalid={Boolean(form.formState.errors.startingPrice)} {...form.register('startingPrice', { onChange: resetPreparation })} />
            {form.formState.errors.startingPrice && <small className="field-error">{form.formState.errors.startingPrice.message}</small>}
          </label>
          <label className="fee-field">
            <span>Pool fee</span>
            <select aria-invalid={Boolean(form.formState.errors.feeTier)} {...form.register('feeTier', { onChange: resetPreparation })}>
              <option value="100">0.01%</option>
              <option value="500">0.05%</option>
              <option value="2500">0.25%</option>
              <option value="10000">1.00%</option>
            </select>
            {form.formState.errors.feeTier && <small className="field-error">{form.formState.errors.feeTier.message}</small>}
          </label>
        </div>

        <AnimatePresence initial={false}>
          {quote.status !== 'idle' && quote.status !== 'checking' && (
            <motion.div className={`quote-result ${quote.status}`} role="status" initial={{ opacity: 0, y: -4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} transition={{ duration: 0.16 }}>
              {quote.status === 'valid' ? <Check size={15} /> : <TriangleAlert size={15} />}
              <span>{quote.symbol && <b>{quote.symbol} · {quote.decimals} decimals</b>}{quote.note}</span>
            </motion.div>
          )}
        </AnimatePresence>

        {prepared && <div className="prepared-launch"><span>Predicted token</span><b>{prepared.predictedToken}</b><span>Range</span><b>{prepared.params.tickLower} → {prepared.params.tickUpper}</b><span>Pool fee</span><b>{prepared.params.feeTier / 10_000}%</b></div>}
        {(prepareError || writeError) && <p className="transaction-error" role="alert"><TriangleAlert size={14} /> {prepareError || writeError?.message}</p>}
        {receipt.isSuccess && (
          <div className="transaction-success" role="status">
            <Check size={14} />
            <span>
              Included in block {receipt.data.blockNumber.toString()} ·{' '}
              <a href={`https://bscscan.com/tx/${transactionHash}`} target="_blank" rel="noreferrer">receipt</a>
              {launchedMarket?.token && (
                <> · <a href={`https://bscscan.com/token/${launchedMarket.token}`} target="_blank" rel="noreferrer">token</a></>
              )}
              {launchedMarket?.pool && (
                <> · <a href={`https://bscscan.com/address/${launchedMarket.pool}`} target="_blank" rel="noreferrer">pool</a></>
              )}
            </span>
          </div>
        )}

        <div className="launch-summary">
          <div><span>Supply</span><b>100,000,000</b></div>
          <div><span>Pool fee</span><b>{Number(selectedFeeTier) / 10_000}%</b></div>
          <div><span>Creator fees</span><b>70%</b></div>
          <div><span>LP position</span><b><ShieldCheck size={14} /> Permanent</b></div>
        </div>

        <button
          className="launch-button"
          type={wrongNetwork ? 'button' : 'submit'}
          disabled={isBusy || (prepared ? !factory : false)}
          onClick={wrongNetwork ? () => switchChain({ chainId: bsc.id }) : undefined}
        >
          {ctaLabel} <ArrowUpRight size={18} />
        </button>
      </form>

      <p className="desk-note"><Check size={13} /> {factory ? 'Factory configured · simulation and exact receipt required' : 'Read-only prototype · factory not deployed'}</p>
    </div>
  );
}
