// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

enum MarketEngine {
    DIRECT,
    CURVE
}

enum TokenMode {
    STANDARD,
    REWARD
}

/// @notice Immutable fee choices committed by one V2 launch.
/// @dev The platform swap fee is deliberately not configurable per launch.
struct V2FeeConfig {
    uint16 creatorSwapFeeBps;
    uint16 rewardFeeBps;
    uint16 creatorLpShareBps;
}

library QuoteV2FeePolicy {
    uint16 internal constant BPS = 10_000;
    uint16 internal constant PLATFORM_SWAP_FEE_BPS = 25;
    uint16 internal constant MAX_CREATOR_SWAP_FEE_BPS = 100;
    uint16 internal constant MAX_REWARD_FEE_BPS = 300;
    uint16 internal constant MAX_TOTAL_HOOK_FEE_BPS = 425;

    error CreatorSwapFeeTooHigh(uint16 value);
    error RewardFeeTooHigh(uint16 value);
    error RewardFeeRequired();
    error RewardFeeForbidden();
    error CreatorLpShareTooHigh(uint16 value);
    error TotalHookFeeTooHigh(uint256 value);

    function validate(TokenMode mode, V2FeeConfig memory config) internal pure {
        if (config.creatorSwapFeeBps > MAX_CREATOR_SWAP_FEE_BPS) {
            revert CreatorSwapFeeTooHigh(config.creatorSwapFeeBps);
        }
        if (config.rewardFeeBps > MAX_REWARD_FEE_BPS) {
            revert RewardFeeTooHigh(config.rewardFeeBps);
        }
        if (config.creatorLpShareBps > BPS) {
            revert CreatorLpShareTooHigh(config.creatorLpShareBps);
        }

        if (mode == TokenMode.STANDARD) {
            if (config.rewardFeeBps != 0) revert RewardFeeForbidden();
        } else if (config.rewardFeeBps == 0) {
            revert RewardFeeRequired();
        }

        uint256 hookFee =
            uint256(PLATFORM_SWAP_FEE_BPS) + config.creatorSwapFeeBps + config.rewardFeeBps;
        if (hookFee > MAX_TOTAL_HOOK_FEE_BPS) revert TotalHookFeeTooHigh(hookFee);
    }

    function hookFeeBps(V2FeeConfig memory config) internal pure returns (uint16) {
        return PLATFORM_SWAP_FEE_BPS + config.creatorSwapFeeBps + config.rewardFeeBps;
    }
}
