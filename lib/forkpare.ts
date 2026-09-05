import { isAddress, parseUnits, type Address, type Hex } from 'viem';

export const FIXED_SUPPLY = 100_000_000n * 10n ** 18n;
export const DEFAULT_FEE_TIER = 500;
export const FEE_TICK_SPACING = {
  100: 1,
  500: 10,
  2500: 50,
  10000: 200,
} as const;
export type SupportedFeeTier = keyof typeof FEE_TICK_SPACING;
export const DEFAULT_TICK_SPACING = FEE_TICK_SPACING[DEFAULT_FEE_TIER];
const Q192 = 1n << 192n;
const ONE_TOKEN = 10n ** 18n;
const MIN_TICK = -887_272;
const MAX_TICK = 887_272;

export type LaunchParams = {
  name: string;
  symbol: string;
  supply: bigint;
  quoteToken: Address;
  feeTier: number;
  sqrtPriceX96: bigint;
  tickLower: number;
  tickUpper: number;
  deadline: bigint;
  userSalt: Hex;
};

const launchParamComponents = [
  { name: 'name', type: 'string' },
  { name: 'symbol', type: 'string' },
  { name: 'supply', type: 'uint256' },
  { name: 'quoteToken', type: 'address' },
  { name: 'feeTier', type: 'uint24' },
  { name: 'sqrtPriceX96', type: 'uint160' },
  { name: 'tickLower', type: 'int24' },
  { name: 'tickUpper', type: 'int24' },
  { name: 'deadline', type: 'uint256' },
  { name: 'userSalt', type: 'bytes32' },
] as const;

export const forkPareFactoryAbi = [
  {
    type: 'event',
    name: 'MarketLaunched',
    inputs: [
      { indexed: true, name: 'launchId', type: 'uint256' },
      { indexed: true, name: 'creator', type: 'address' },
      { indexed: true, name: 'token', type: 'address' },
      { indexed: false, name: 'quoteToken', type: 'address' },
      { indexed: false, name: 'pool', type: 'address' },
      { indexed: false, name: 'locker', type: 'address' },
      { indexed: false, name: 'positionTokenId', type: 'uint256' },
      { indexed: false, name: 'supply', type: 'uint256' },
      { indexed: false, name: 'sqrtPriceX96', type: 'uint160' },
      { indexed: false, name: 'tickLower', type: 'int24' },
      { indexed: false, name: 'tickUpper', type: 'int24' },
      { indexed: false, name: 'feeTier', type: 'uint24' },
    ],
  },
  {
    type: 'function', name: 'creationFee', stateMutability: 'view', inputs: [],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function', name: 'predictToken', stateMutability: 'view',
    inputs: [{ name: 'creator', type: 'address' }, { name: 'params', type: 'tuple', components: launchParamComponents }],
    outputs: [{ name: '', type: 'address' }],
  },
  {
    type: 'function', name: 'launch', stateMutability: 'payable',
    inputs: [{ name: 'params', type: 'tuple', components: launchParamComponents }],
    outputs: [],
  },
] as const;

export function configuredFactory(): Address | undefined {
  const value = process.env.NEXT_PUBLIC_FORKPARE_FACTORY;
  return value && isAddress(value) ? value : undefined;
}

function integerSqrt(value: bigint) {
  if (value < 0n) throw new Error('negative_sqrt');
  if (value < 2n) return value;
  let x0 = 1n << BigInt((value.toString(2).length + 1) >> 1);
  let x1 = (x0 + value / x0) >> 1n;
  while (x1 < x0) {
    x0 = x1;
    x1 = (x0 + value / x0) >> 1n;
  }
  return x0;
}

function rawRatio(price: string, quoteDecimals: number, launchTokenIsToken0: boolean) {
  if (quoteDecimals < 0 || quoteDecimals > 36) throw new Error('unsupported_decimals');
  const quoteForOneToken = parseUnits(price, quoteDecimals);
  if (quoteForOneToken <= 0n) throw new Error('zero_price');
  return launchTokenIsToken0
    ? { numerator: quoteForOneToken, denominator: ONE_TOKEN }
    : { numerator: ONE_TOKEN, denominator: quoteForOneToken };
}

export function buildPriceRange(
  price: string,
  quoteDecimals: number,
  launchTokenIsToken0: boolean,
  tickSpacing = DEFAULT_TICK_SPACING,
) {
  const { numerator, denominator } = rawRatio(price, quoteDecimals, launchTokenIsToken0);
  const sqrtPriceX96 = integerSqrt((numerator * Q192) / denominator);
  if (sqrtPriceX96 <= 4_295_128_739n || sqrtPriceX96 >= 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342n) {
    throw new Error('price_out_of_range');
  }

  const ratio = Number(numerator) / Number(denominator);
  const currentTick = Math.floor(Math.log(ratio) / Math.log(1.0001));
  const minUsable = Math.ceil(MIN_TICK / tickSpacing) * tickSpacing;
  const maxUsable = Math.floor(MAX_TICK / tickSpacing) * tickSpacing;

  if (launchTokenIsToken0) {
    return {
      sqrtPriceX96,
      tickLower: Math.ceil(currentTick / tickSpacing) * tickSpacing,
      tickUpper: maxUsable,
    };
  }
  return {
    sqrtPriceX96,
    tickLower: minUsable,
    tickUpper: Math.floor(currentTick / tickSpacing) * tickSpacing,
  };
}
