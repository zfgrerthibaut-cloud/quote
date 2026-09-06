import { Interface } from 'ethers';

import { canonicalAbiVersionHash } from './registry.ts';
import type { Address, DecodedQuoteLog, Hex, RpcLog } from './types.ts';

export const PANCAKE_V3_SWAP_ABI = [{
  type: 'event',
  name: 'Swap',
  anonymous: false,
  inputs: [
    { name: 'sender', type: 'address', indexed: true },
    { name: 'recipient', type: 'address', indexed: true },
    { name: 'amount0', type: 'int256', indexed: false },
    { name: 'amount1', type: 'int256', indexed: false },
    { name: 'sqrtPriceX96', type: 'uint160', indexed: false },
    { name: 'liquidity', type: 'uint128', indexed: false },
    { name: 'tick', type: 'int24', indexed: false },
  ],
}] as const;

const PANCAKE_V3_SWAP_INTERFACE = new Interface(PANCAKE_V3_SWAP_ABI);

export const PANCAKE_V3_SWAP_TOPIC = PANCAKE_V3_SWAP_INTERFACE
  .getEvent('Swap')!
  .topicHash
  .toLowerCase() as Hex;

export const PANCAKE_V3_SWAP_ABI_VERSION_HASH = canonicalAbiVersionHash(PANCAKE_V3_SWAP_ABI);

export type QuoteDirectMarket = Readonly<{
  chainId: number;
  launchpad: Address;
  launchId: string;
  token: Address;
  quoteToken: Address;
  market: Address;
}>;

export type ProjectedPancakeV3Trade = Readonly<{
  chainId: number;
  launchpad: Address;
  launchId: string;
  phase: 'pool';
  tradeType: 'buy' | 'sell';
  venue: Address;
  trader: Address;
  recipient: Address;
  tokenIn: Address;
  tokenOut: Address;
  amountInRaw: string;
  amountOutRaw: string;
  tokenAmountRaw: string;
  quoteAmountRaw: string;
  tokenAmountSignedRaw: string;
  quoteAmountSignedRaw: string;
  priceNumeratorRaw: string;
  priceDenominatorRaw: string;
}>;

export function isPancakeV3SwapTopic(topic: Hex | undefined) {
  return topic?.toLowerCase() === PANCAKE_V3_SWAP_TOPIC;
}

export function decodePancakeV3SwapLog(log: RpcLog): DecodedQuoteLog {
  if (!isPancakeV3SwapTopic(log.topics[0])) throw new Error('pancake_v3_swap_topic_mismatch');
  const parsed = PANCAKE_V3_SWAP_INTERFACE.parseLog({ topics: [...log.topics], data: log.data });
  if (!parsed) throw new Error('pancake_v3_swap_decode_failed');
  const args: Record<string, unknown> = {};
  parsed.fragment.inputs.forEach((input, index) => {
    args[input.name || String(index)] = jsonSafe(parsed.args[index]);
  });
  return {
    ...log,
    address: normalizeAddress(log.address),
    eventName: parsed.name,
    eventSignature: parsed.signature,
    abiVersionHash: PANCAKE_V3_SWAP_ABI_VERSION_HASH,
    args,
  };
}

export function projectPancakeV3Swap(
  log: DecodedQuoteLog,
  market: QuoteDirectMarket,
): ProjectedPancakeV3Trade {
  if (log.eventName !== 'Swap') throw new Error('not_pancake_v3_swap');
  if (normalizeAddress(log.address) !== normalizeAddress(market.market)) {
    throw new Error('pancake_v3_swap_market_mismatch');
  }

  const amount0 = signedIntArg(log, 'amount0');
  const amount1 = signedIntArg(log, 'amount1');
  if (amount0 === 0n || amount1 === 0n || sameSign(amount0, amount1)) {
    throw new Error('pancake_v3_swap_invalid_amounts');
  }

  const tokenIsToken0 = normalizeAddress(market.token) < normalizeAddress(market.quoteToken);
  const tokenDelta = tokenIsToken0 ? amount0 : amount1;
  const quoteDelta = tokenIsToken0 ? amount1 : amount0;
  if (tokenDelta === 0n || quoteDelta === 0n || sameSign(tokenDelta, quoteDelta)) {
    throw new Error('pancake_v3_swap_invalid_orientation');
  }

  const trader = addressArg(log, 'sender');
  const recipient = addressArg(log, 'recipient');
  const tokenAbs = abs(tokenDelta);
  const quoteAbs = abs(quoteDelta);
  const price = reduceRatio(quoteAbs, tokenAbs);

  if (quoteDelta > 0n && tokenDelta < 0n) {
    return {
      chainId: market.chainId,
      launchpad: market.launchpad,
      launchId: market.launchId,
      phase: 'pool',
      tradeType: 'buy',
      venue: market.market,
      trader,
      recipient,
      tokenIn: market.quoteToken,
      tokenOut: market.token,
      amountInRaw: quoteAbs.toString(),
      amountOutRaw: tokenAbs.toString(),
      tokenAmountRaw: tokenAbs.toString(),
      quoteAmountRaw: quoteAbs.toString(),
      tokenAmountSignedRaw: tokenDelta.toString(),
      quoteAmountSignedRaw: quoteDelta.toString(),
      priceNumeratorRaw: price.numerator.toString(),
      priceDenominatorRaw: price.denominator.toString(),
    };
  }
  if (tokenDelta > 0n && quoteDelta < 0n) {
    return {
      chainId: market.chainId,
      launchpad: market.launchpad,
      launchId: market.launchId,
      phase: 'pool',
      tradeType: 'sell',
      venue: market.market,
      trader,
      recipient,
      tokenIn: market.token,
      tokenOut: market.quoteToken,
      amountInRaw: tokenAbs.toString(),
      amountOutRaw: quoteAbs.toString(),
      tokenAmountRaw: tokenAbs.toString(),
      quoteAmountRaw: quoteAbs.toString(),
      tokenAmountSignedRaw: tokenDelta.toString(),
      quoteAmountSignedRaw: quoteDelta.toString(),
      priceNumeratorRaw: price.numerator.toString(),
      priceDenominatorRaw: price.denominator.toString(),
    };
  }

  throw new Error('pancake_v3_swap_unknown_side');
}

function signedIntArg(log: DecodedQuoteLog, name: string) {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^-?\d+$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return BigInt(value);
}

function addressArg(log: DecodedQuoteLog, name: string): Address {
  const value = log.args[name];
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`invalid_${log.eventName}_${name}`);
  return normalizeAddress(value as Address);
}

function sameSign(left: bigint, right: bigint) {
  return (left > 0n && right > 0n) || (left < 0n && right < 0n);
}

function abs(value: bigint) {
  return value < 0n ? -value : value;
}

function reduceRatio(numerator: bigint, denominator: bigint) {
  const divisor = gcd(numerator, denominator);
  return { numerator: numerator / divisor, denominator: denominator / divisor };
}

function gcd(left: bigint, right: bigint): bigint {
  let a = abs(left);
  let b = abs(right);
  while (b !== 0n) {
    const remainder = a % b;
    a = b;
    b = remainder;
  }
  return a;
}

function normalizeAddress(value: Address): Address {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error('invalid_address');
  return value.toLowerCase() as Address;
}

function jsonSafe(value: unknown): unknown {
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map(jsonSafe);
  if (value instanceof Uint8Array) return `0x${Buffer.from(value).toString('hex')}`;
  if (isRecord(value)) return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, jsonSafe(item)]));
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
