// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/// @notice Decimal-aware initial price and one-sided range construction for Pancake V3.
/// @dev The launch token always has 18 decimals. No caller-provided sqrt price or ticks are used.
library DirectV3PriceMath {
    uint8 internal constant MAX_QUOTE_DECIMALS = 36;
    int24 internal constant MIN_TICK = -887_272;
    int24 internal constant MAX_TICK = 887_272;
    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    error UnsupportedQuoteDecimals(uint8 decimals);
    error InvalidPriceInputs();
    error PriceOutOfRange(uint256 sqrtPriceX96);
    error InvalidTickSpacing(int24 tickSpacing);
    error InvalidCurrentTick(int24 currentTick);
    error NoOneSidedRange(int24 currentTick, int24 tickSpacing, bool launchTokenIsToken0);
    error MultiplicationOverflow();

    function initialSqrtPriceX96(
        uint256 targetFdvUsdWad,
        uint256 supply,
        uint256 quotePriceUsdWad,
        uint8 quoteDecimals,
        bool launchTokenIsToken0
    ) internal pure returns (uint160 sqrtPriceX96) {
        if (targetFdvUsdWad == 0 || supply == 0 || quotePriceUsdWad == 0) {
            revert InvalidPriceInputs();
        }
        if (quoteDecimals > MAX_QUOTE_DECIMALS) {
            revert UnsupportedQuoteDecimals(quoteDecimals);
        }

        uint256 quoteScale = 10 ** uint256(quoteDecimals);
        uint256 targetTimesScale = _checkedMul(targetFdvUsdWad, quoteScale);
        uint256 supplyTimesQuotePrice = _checkedMul(supply, quotePriceUsdWad);

        // Pancake encodes sqrt(token1Raw / token0Raw) * 2^96. The launch token has
        // 18 decimals; those 1e18 factors cancel when target FDV and quote price are WADs.
        uint256 numerator = launchTokenIsToken0 ? targetTimesScale : supplyTimesQuotePrice;
        uint256 denominator = launchTokenIsToken0 ? supplyTimesQuotePrice : targetTimesScale;
        uint256 sqrtRatio = _sqrtRatioX96(numerator, denominator);

        if (sqrtRatio < MIN_SQRT_RATIO || sqrtRatio >= MAX_SQRT_RATIO) {
            revert PriceOutOfRange(sqrtRatio);
        }
        sqrtPriceX96 = uint160(sqrtRatio);
    }

    function oneSidedTicks(int24 currentTick, int24 tickSpacing, bool launchTokenIsToken0)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        if (tickSpacing <= 0) revert InvalidTickSpacing(tickSpacing);
        if (currentTick < MIN_TICK || currentTick > MAX_TICK) {
            revert InvalidCurrentTick(currentTick);
        }

        int24 minUsableTick = (MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxUsableTick = (MAX_TICK / tickSpacing) * tickSpacing;
        int24 flooredCurrentTick = _floorToSpacing(currentTick, tickSpacing);

        if (launchTokenIsToken0) {
            tickLower = flooredCurrentTick + tickSpacing;
            tickUpper = maxUsableTick;
            if (tickLower >= tickUpper) {
                revert NoOneSidedRange(currentTick, tickSpacing, true);
            }
        } else {
            tickLower = minUsableTick;
            tickUpper = flooredCurrentTick;
            if (tickLower >= tickUpper) {
                revert NoOneSidedRange(currentTick, tickSpacing, false);
            }
        }
    }

    function _floorToSpacing(int24 tick, int24 tickSpacing) private pure returns (int24 result) {
        result = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) result -= tickSpacing;
    }

    function _checkedMul(uint256 a, uint256 b) private pure returns (uint256 result) {
        unchecked {
            result = a * b;
        }
        if (a != 0 && result / a != b) revert MultiplicationOverflow();
    }

    function _sqrtRatioX96(uint256 numerator, uint256 denominator)
        private
        pure
        returns (uint256 sqrtRatio)
    {
        // Starting with 192 fractional bits gives the exact Q96 square-root scale for ratios <= 1
        // and maximum precision for ordinary market prices. For large ratios, reduce the scaling
        // by an even number of bits so mulDiv's uint256 result cannot overflow, then restore the
        // corresponding power of two after sqrt. This still covers the complete V3 price domain.
        uint256 scalingBits = 192;
        if (numerator > denominator) {
            uint256 numeratorBits = Math.log2(numerator) + 1;
            uint256 denominatorFloorLog2 = Math.log2(denominator);
            uint256 upperRatioBits = numeratorBits - denominatorFloorLog2;
            if (upperRatioBits > 255) revert PriceOutOfRange(type(uint256).max);

            uint256 safeScalingBits = 255 - upperRatioBits;
            if (safeScalingBits < scalingBits) scalingBits = safeScalingBits & ~uint256(1);
        }

        uint256 scaledRatio = Math.mulDiv(numerator, uint256(1) << scalingBits, denominator);
        uint256 root = Math.sqrt(scaledRatio);
        uint256 restoreBits = (192 - scalingBits) / 2;
        if (root > type(uint256).max >> restoreBits) {
            revert PriceOutOfRange(type(uint256).max);
        }
        sqrtRatio = root << restoreBits;
    }
}
