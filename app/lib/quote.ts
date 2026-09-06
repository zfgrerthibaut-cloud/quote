import { isAddress, parseUnits, type Address, type Hex } from 'viem';

export const FIXED_SUPPLY = 100_000_000n * 10n ** 18n;
export const DEFAULT_FEE_TIER = 10_000;
export const FEE_TICK_SPACING = {
  100: 1,
  500: 10,
  2500: 50,
  10000: 200,
} as const;
export type SupportedFeeTier = keyof typeof FEE_TICK_SPACING;
export const DEFAULT_TICK_SPACING = FEE_TICK_SPACING[DEFAULT_FEE_TIER];
const Q192 = 1n << 192n;
const Q32 = 1n << 32n;
const Q128 = 1n << 128n;
const MAX_UINT256 = (1n << 256n) - 1n;
const ONE_TOKEN = 10n ** 18n;
const MIN_TICK = -887_272;
const MAX_TICK = 887_272;
const TICK_MULTIPLIERS = [
  0xfffcb933bd6fad37aa2d162d1a594001n,
  0xfff97272373d413259a46990580e213an,
  0xfff2e50f5f656932ef12357cf3c7fdccn,
  0xffe5caca7e10e4e61c3624eaa0941cd0n,
  0xffcb9843d60f6159c9db58835c926644n,
  0xff973b41fa98c081472e6896dfb254c0n,
  0xff2ea16466c96a3843ec78b326b52861n,
  0xfe5dee046a99a2a811c461f1969c3053n,
  0xfcbe86c7900a88aedcffc83b479aa3a4n,
  0xf987a7253ac413176f2b074cf7815e54n,
  0xf3392b0822b70005940c7a398e4b70f3n,
  0xe7159475a2c29b7443b29c7fa6e889d9n,
  0xd097f3bdfd2022b8845ad8f792aa5825n,
  0xa9f746462d870fdf8a65dc1f90e061e5n,
  0x70d869a156d2a1b890bb3df62baf32f7n,
  0x31be135f97d08fd981231505542fcfa6n,
  0x9aa508b5b7a84e1c677de54f3e99bc9n,
  0x5d6af8dedb81196699c329225ee604n,
  0x2216e584f5fa1ea926041bedfe98n,
  0x48a170391f7dc42444e8fa2n,
] as const;

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

const launchRecordComponents = [
  { name: 'creator', type: 'address' },
  { name: 'token', type: 'address' },
  { name: 'quoteToken', type: 'address' },
  { name: 'pool', type: 'address' },
  { name: 'locker', type: 'address' },
  { name: 'positionTokenId', type: 'uint256' },
  { name: 'supply', type: 'uint256' },
  { name: 'sqrtPriceX96', type: 'uint160' },
  { name: 'tickLower', type: 'int24' },
  { name: 'tickUpper', type: 'int24' },
  { name: 'feeTier', type: 'uint24' },
] as const;

export const quoteFactoryAbi = [
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
    outputs: [{ name: 'record', type: 'tuple', components: launchRecordComponents }],
  },
] as const;

export function configuredFactory(): Address | undefined {
  const value = process.env.NEXT_PUBLIC_QUOTE_LAUNCHPAD;
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

export function sqrtRatioAtTick(tick: number) {
  if (!Number.isInteger(tick) || tick < MIN_TICK || tick > MAX_TICK) {
    throw new Error('tick_out_of_range');
  }
  const absoluteTick = Math.abs(tick);
  let ratio = Q128;
  for (let bit = 0; bit < TICK_MULTIPLIERS.length; bit += 1) {
    if ((absoluteTick & (1 << bit)) !== 0) {
      ratio = (ratio * TICK_MULTIPLIERS[bit]) >> 128n;
    }
  }
  if (tick > 0) ratio = MAX_UINT256 / ratio;
  return (ratio >> 32n) + (ratio % Q32 === 0n ? 0n : 1n);
}

export function getTickAtSqrtRatio(sqrtPriceX96: bigint) {
  if (sqrtPriceX96 < sqrtRatioAtTick(MIN_TICK) || sqrtPriceX96 >= sqrtRatioAtTick(MAX_TICK)) {
    throw new Error('price_out_of_range');
  }
  let low = MIN_TICK;
  let high = MAX_TICK - 1;
  while (low < high) {
    const middle = Math.ceil((low + high) / 2);
    if (sqrtRatioAtTick(middle) <= sqrtPriceX96) low = middle;
    else high = middle - 1;
  }
  return low === 0 ? 0 : low;
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

  const currentTick = getTickAtSqrtRatio(sqrtPriceX96);
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
