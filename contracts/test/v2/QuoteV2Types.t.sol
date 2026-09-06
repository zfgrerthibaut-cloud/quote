// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { QuoteV2FeePolicy, TokenMode, V2FeeConfig } from "../../src/v2/QuoteV2Types.sol";

contract FeePolicyHarness {
    function validate(TokenMode mode, V2FeeConfig calldata config) external pure {
        QuoteV2FeePolicy.validate(mode, config);
    }

    function hookFeeBps(V2FeeConfig calldata config) external pure returns (uint16) {
        return QuoteV2FeePolicy.hookFeeBps(config);
    }
}

contract QuoteV2TypesTest is Test {
    FeePolicyHarness private harness = new FeePolicyHarness();

    function testStandardAllowsOptionalCreatorFeeAndNoRewardFee() external view {
        V2FeeConfig memory config =
            V2FeeConfig({ creatorSwapFeeBps: 75, rewardFeeBps: 0, creatorLpShareBps: 10_000 });

        harness.validate(TokenMode.STANDARD, config);
        assertEq(harness.hookFeeBps(config), 100);
    }

    function testRewardRequiresPositiveBoundedRewardFee() external {
        V2FeeConfig memory config =
            V2FeeConfig({ creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 8_000 });

        vm.expectRevert(QuoteV2FeePolicy.RewardFeeRequired.selector);
        harness.validate(TokenMode.REWARD, config);

        config.rewardFeeBps = 300;
        harness.validate(TokenMode.REWARD, config);
        assertEq(harness.hookFeeBps(config), 325);
    }

    function testStandardRejectsRewardFee() external {
        V2FeeConfig memory config =
            V2FeeConfig({ creatorSwapFeeBps: 0, rewardFeeBps: 1, creatorLpShareBps: 10_000 });

        vm.expectRevert(QuoteV2FeePolicy.RewardFeeForbidden.selector);
        harness.validate(TokenMode.STANDARD, config);
    }

    function testRejectsFeeCaps() external {
        V2FeeConfig memory config =
            V2FeeConfig({ creatorSwapFeeBps: 101, rewardFeeBps: 0, creatorLpShareBps: 10_000 });
        vm.expectRevert(
            abi.encodeWithSelector(QuoteV2FeePolicy.CreatorSwapFeeTooHigh.selector, 101)
        );
        harness.validate(TokenMode.STANDARD, config);

        config = V2FeeConfig({ creatorSwapFeeBps: 0, rewardFeeBps: 301, creatorLpShareBps: 10_000 });
        vm.expectRevert(abi.encodeWithSelector(QuoteV2FeePolicy.RewardFeeTooHigh.selector, 301));
        harness.validate(TokenMode.REWARD, config);

        config = V2FeeConfig({ creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 10_001 });
        vm.expectRevert(
            abi.encodeWithSelector(QuoteV2FeePolicy.CreatorLpShareTooHigh.selector, 10_001)
        );
        harness.validate(TokenMode.STANDARD, config);
    }

    function testFuzzEveryValidConfigHasBoundedHookFee(
        uint16 creatorFee,
        uint16 rewardFee,
        uint16 lpShare,
        bool rewardMode
    ) external view {
        creatorFee = uint16(bound(creatorFee, 0, 100));
        lpShare = uint16(bound(lpShare, 0, 10_000));
        rewardFee = rewardMode ? uint16(bound(rewardFee, 1, 300)) : 0;
        V2FeeConfig memory config = V2FeeConfig({
            creatorSwapFeeBps: creatorFee, rewardFeeBps: rewardFee, creatorLpShareBps: lpShare
        });

        harness.validate(rewardMode ? TokenMode.REWARD : TokenMode.STANDARD, config);
        assertLe(harness.hookFeeBps(config), 425);
    }
}
