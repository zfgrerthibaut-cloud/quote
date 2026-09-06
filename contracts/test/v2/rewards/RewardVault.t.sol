// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import { IRewardBalanceChangeReceiver } from "../../../src/v2/rewards/IRewardVault.sol";
import { RewardVault } from "../../../src/v2/rewards/RewardVault.sol";

contract MockRewardQuote is ERC20 {
    constructor() ERC20("Quote", "QUOTE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract FeeOnTransferRewardQuote is MockRewardQuote {
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / 10;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract RevertingBalanceQuote is ERC20 {
    constructor() ERC20("Reverting Quote", "RQUOTE") { }

    function balanceOf(address) public pure override returns (uint256) {
        revert("BALANCE_DISABLED");
    }
}

contract NotifyingLaunchToken is ERC20 {
    IRewardBalanceChangeReceiver public rewardVault;

    error RewardVaultAlreadySet();

    constructor() ERC20("Launch", "LAUNCH") { }

    function setRewardVault(IRewardBalanceChangeReceiver rewardVault_) external {
        if (address(rewardVault) != address(0)) revert RewardVaultAlreadySet();
        rewardVault = rewardVault_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fromBefore = from == address(0) ? 0 : balanceOf(from);
        uint256 toBefore = to == address(0) ? 0 : balanceOf(to);

        super._update(from, to, value);

        IRewardBalanceChangeReceiver vault = rewardVault;
        if (address(vault) == address(0)) return;

        if (from == to) {
            if (from != address(0)) vault.notifyBalanceChange(from, fromBefore, balanceOf(from));
            return;
        }
        if (from != address(0)) vault.notifyBalanceChange(from, fromBefore, balanceOf(from));
        if (to != address(0)) vault.notifyBalanceChange(to, toBefore, balanceOf(to));
    }
}

contract RewardVaultTest is Test {
    uint256 internal constant MIN_ELIGIBLE_BALANCE = 10 ether;
    uint256 internal constant SCALE = 1e36;

    address internal rewardHook = makeAddr("rewardHook");
    address internal poolManager = makeAddr("poolManager");
    address internal locker = makeAddr("locker");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal dust = makeAddr("dust");
    address internal attacker = makeAddr("attacker");

    NotifyingLaunchToken internal launchToken;
    MockRewardQuote internal quoteToken;
    RewardVault internal vault;

    function setUp() external {
        launchToken = new NotifyingLaunchToken();
        quoteToken = new MockRewardQuote();
        vault = _deployVault(IERC20(address(quoteToken)), MIN_ELIGIBLE_BALANCE);
        launchToken.setRewardVault(IRewardBalanceChangeReceiver(address(vault)));
    }

    function testConstructorStoresImmutableAssetsAndFixedExclusions() external view {
        assertEq(vault.launchToken(), address(launchToken));
        assertEq(vault.quoteToken(), address(quoteToken));
        assertEq(vault.rewardHook(), rewardHook);
        assertEq(vault.minEligibleBalance(), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.ACCUMULATOR_SCALE(), SCALE);

        assertTrue(vault.isExcluded(address(0)));
        assertTrue(vault.isExcluded(address(vault)));
        assertTrue(vault.isExcluded(address(launchToken)));
        assertTrue(vault.isExcluded(address(quoteToken)));
        assertTrue(vault.isExcluded(rewardHook));
        assertTrue(vault.isExcluded(poolManager));
        assertTrue(vault.isExcluded(locker));
        assertTrue(vault.isExcluded(treasury));
        assertFalse(vault.isExcluded(alice));
    }

    function testConstructorRejectsInvalidConfig() external {
        address[] memory exclusions = new address[](0);

        vm.expectRevert(RewardVault.InvalidRewardVaultConfig.selector);
        new RewardVault(
            address(0), address(quoteToken), rewardHook, MIN_ELIGIBLE_BALANCE, exclusions
        );

        vm.expectRevert(RewardVault.InvalidRewardVaultConfig.selector);
        new RewardVault(
            address(launchToken), address(0), rewardHook, MIN_ELIGIBLE_BALANCE, exclusions
        );

        vm.expectRevert(RewardVault.InvalidRewardVaultConfig.selector);
        new RewardVault(
            address(launchToken), address(quoteToken), address(0), MIN_ELIGIBLE_BALANCE, exclusions
        );

        vm.expectRevert(RewardVault.InvalidRewardVaultConfig.selector);
        new RewardVault(address(launchToken), address(quoteToken), rewardHook, 0, exclusions);

        vm.expectRevert(RewardVault.InvalidRewardVaultConfig.selector);
        new RewardVault(
            address(launchToken), address(launchToken), rewardHook, MIN_ELIGIBLE_BALANCE, exclusions
        );

        vm.expectRevert(RewardVault.InvalidRewardVaultConfig.selector);
        new RewardVault(
            address(launchToken),
            address(quoteToken),
            address(launchToken),
            MIN_ELIGIBLE_BALANCE,
            exclusions
        );
    }

    function testBalanceNotifierIsLaunchTokenOnlyAndDoesNotTouchQuote() external {
        RevertingBalanceQuote revertingQuote = new RevertingBalanceQuote();
        NotifyingLaunchToken token = new NotifyingLaunchToken();
        RewardVault localVault =
            _deployVaultForToken(token, IERC20(address(revertingQuote)), MIN_ELIGIBLE_BALANCE);
        token.setRewardVault(IRewardBalanceChangeReceiver(address(localVault)));

        token.mint(alice, MIN_ELIGIBLE_BALANCE);

        assertEq(localVault.trackedBalanceOf(alice), MIN_ELIGIBLE_BALANCE);
        assertEq(localVault.eligibleSharesOf(alice), MIN_ELIGIBLE_BALANCE);
        assertEq(localVault.totalEligibleShares(), MIN_ELIGIBLE_BALANCE);

        vm.expectRevert(abi.encodeWithSelector(RewardVault.NotLaunchToken.selector, attacker));
        vm.prank(attacker);
        localVault.notifyBalanceChange(alice, MIN_ELIGIBLE_BALANCE, 0);
    }

    function testNotifyRewardDistributesReceivedQuoteByTrackedEligibleShares() external {
        launchToken.mint(alice, 100 ether);
        launchToken.mint(bob, 300 ether);
        launchToken.mint(dust, MIN_ELIGIBLE_BALANCE - 1);
        launchToken.mint(treasury, 1_000 ether);

        assertEq(vault.totalEligibleShares(), 400 ether);
        assertEq(vault.eligibleSharesOf(dust), 0);
        assertEq(vault.eligibleSharesOf(treasury), 0);

        (uint256 received, uint256 delta) = _notifyReward(40 ether);

        assertEq(received, 40 ether);
        assertEq(delta, (40 ether * SCALE) / 400 ether);
        assertEq(vault.claimable(alice), 10 ether);
        assertEq(vault.claimable(bob), 30 ether);
        assertEq(vault.claimable(dust), 0);
        assertEq(vault.claimable(treasury), 0);
        assertEq(vault.accountedQuoteBalance(), 40 ether);
        assertEq(vault.totalRewardsNotified(), 40 ether);

        vm.prank(alice);
        assertEq(vault.claim(), 10 ether);
        assertEq(quoteToken.balanceOf(alice), 10 ether);
        assertEq(vault.accountedQuoteBalance(), 30 ether);
        assertEq(vault.totalRewardsClaimed(), 10 ether);
        assertEq(vault.claimable(alice), 0);

        vm.prank(bob);
        assertEq(vault.claim(), 30 ether);
        assertEq(quoteToken.balanceOf(bob), 30 ether);
        assertEq(vault.accountedQuoteBalance(), 0);
        assertEq(quoteToken.balanceOf(address(vault)), 0);
        assertEq(vault.totalRewardsClaimed(), 40 ether);
    }

    function testTinyRewardCarriesUntilLaterTopUpCanDistribute() external {
        NotifyingLaunchToken token = new NotifyingLaunchToken();
        MockRewardQuote quote = new MockRewardQuote();
        RewardVault localVault = _deployVaultForToken(token, IERC20(address(quote)), 1);
        token.setRewardVault(IRewardBalanceChangeReceiver(address(localVault)));
        token.mint(alice, 3);

        (uint256 received, uint256 delta) = _notifyReward(localVault, quote, 1);

        assertEq(received, 1);
        assertEq(delta, SCALE / 3);
        assertEq(localVault.accountedQuoteBalance(), 1);
        assertEq(localVault.undistributedRewardScaled(), SCALE % 3);
        assertEq(localVault.claimable(alice), 0);

        (received, delta) = _notifyReward(localVault, quote, 2);

        assertEq(received, 2);
        assertEq(delta, ((2 * SCALE) + (SCALE % 3)) / 3);
        assertEq(localVault.undistributedRewardScaled(), 0);
        assertEq(localVault.rewardPerShareStored(), SCALE);
        assertEq(localVault.claimable(alice), 3);

        vm.prank(alice);
        assertEq(localVault.claim(), 3);
        assertEq(quote.balanceOf(alice), 3);
        assertEq(localVault.accountedQuoteBalance(), 0);
        assertEq(quote.balanceOf(address(localVault)), 0);
    }

    function testTransfersSettleRewardsBeforeChangingShares() external {
        launchToken.mint(alice, 100 ether);
        launchToken.mint(bob, 100 ether);
        _notifyReward(20 ether);

        vm.prank(alice);
        assertTrue(launchToken.transfer(bob, 50 ether));

        assertEq(vault.accruedRewards(alice), 10 ether);
        assertEq(vault.accruedRewards(bob), 10 ether);
        assertEq(vault.eligibleSharesOf(alice), 50 ether);
        assertEq(vault.eligibleSharesOf(bob), 150 ether);
        assertEq(vault.totalEligibleShares(), 200 ether);

        _notifyReward(30 ether);

        assertEq(vault.claimable(alice), 17 ether + 0.5 ether);
        assertEq(vault.claimable(bob), 32 ether + 0.5 ether);
    }

    function testDustThresholdStartsAndStopsEligibility() external {
        launchToken.mint(alice, MIN_ELIGIBLE_BALANCE - 1);
        launchToken.mint(bob, MIN_ELIGIBLE_BALANCE);

        assertEq(vault.eligibleSharesOf(alice), 0);
        assertEq(vault.eligibleSharesOf(bob), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.totalEligibleShares(), MIN_ELIGIBLE_BALANCE);

        _notifyReward(10 ether);
        assertEq(vault.claimable(alice), 0);
        assertEq(vault.claimable(bob), 10 ether);

        launchToken.mint(alice, 1);
        assertEq(vault.eligibleSharesOf(alice), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.totalEligibleShares(), MIN_ELIGIBLE_BALANCE * 2);

        _notifyReward(20 ether);
        assertEq(vault.claimable(alice), 10 ether);
        assertEq(vault.claimable(bob), 20 ether);

        vm.prank(alice);
        assertTrue(launchToken.transfer(bob, 1 ether));

        assertEq(vault.eligibleSharesOf(alice), 0);
        assertEq(vault.eligibleSharesOf(bob), MIN_ELIGIBLE_BALANCE + 1 ether);
        assertEq(vault.claimable(alice), 10 ether);

        _notifyReward(11 ether);
        assertEq(vault.claimable(alice), 10 ether);
        assertEq(vault.claimable(bob), 31 ether);
    }

    function testNotifyRewardIsHookOnlyAndRequiresReceivedQuote() external {
        launchToken.mint(alice, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(RewardVault.NotRewardHook.selector, attacker));
        vm.prank(attacker);
        vault.notifyReward();

        vm.expectRevert(RewardVault.NoRewardReceived.selector);
        vm.prank(rewardHook);
        vault.notifyReward();
    }

    function testNotifyRewardRejectsNoEligibleShares() external {
        quoteToken.mint(address(vault), 1 ether);

        vm.expectRevert(RewardVault.NoEligibleShares.selector);
        vm.prank(rewardHook);
        vault.notifyReward();
    }

    function testBalanceCheckpointMismatchProtectsShareAccounting() external {
        launchToken.mint(alice, 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardVault.BalanceCheckpointMismatch.selector, alice, 0, 100 ether
            )
        );
        vm.prank(address(launchToken));
        vault.notifyBalanceChange(alice, 0, 50 ether);
    }

    function testIncomingFeeOnTransferQuoteUsesNetReceivedAndBadClaimDeltaReverts() external {
        FeeOnTransferRewardQuote taxedQuote = new FeeOnTransferRewardQuote();
        NotifyingLaunchToken token = new NotifyingLaunchToken();
        RewardVault localVault =
            _deployVaultForToken(token, IERC20(address(taxedQuote)), MIN_ELIGIBLE_BALANCE);
        token.setRewardVault(IRewardBalanceChangeReceiver(address(localVault)));
        token.mint(alice, 100 ether);

        taxedQuote.mint(rewardHook, 100 ether);
        vm.startPrank(rewardHook);
        assertTrue(taxedQuote.transfer(address(localVault), 100 ether));
        (uint256 received,) = localVault.notifyReward();
        vm.stopPrank();

        assertEq(received, 90 ether);
        assertEq(taxedQuote.balanceOf(address(localVault)), 90 ether);
        assertEq(localVault.claimable(alice), 90 ether);

        vm.expectRevert(
            abi.encodeWithSelector(RewardVault.BadQuoteRecipientDelta.selector, 90 ether, 81 ether)
        );
        vm.prank(alice);
        localVault.claim();

        assertEq(localVault.claimable(alice), 90 ether);
        assertEq(taxedQuote.balanceOf(address(localVault)), 90 ether);
        assertEq(taxedQuote.balanceOf(alice), 0);
    }

    function testQuoteBalanceLossRevertsBeforeAccountingOrClaiming() external {
        launchToken.mint(alice, 100 ether);
        _notifyReward(10 ether);

        quoteToken.burn(address(vault), 1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardVault.QuoteBalanceBelowAccounted.selector, 9 ether, 10 ether
            )
        );
        vm.prank(rewardHook);
        vault.notifyReward();

        vm.expectRevert(
            abi.encodeWithSelector(
                RewardVault.QuoteBalanceBelowAccounted.selector, 9 ether, 10 ether
            )
        );
        vm.prank(alice);
        vault.claim();
    }

    function testClaimRevertsWhenNothingIsClaimable() external {
        launchToken.mint(alice, 100 ether);

        vm.expectRevert(abi.encodeWithSelector(RewardVault.NoRewardsClaimable.selector, alice));
        vm.prank(alice);
        vault.claim();
    }

    function _notifyReward(uint256 amount) internal returns (uint256 received, uint256 delta) {
        return _notifyReward(vault, quoteToken, amount);
    }

    function _notifyReward(RewardVault rewardVault, MockRewardQuote quote, uint256 amount)
        internal
        returns (uint256 received, uint256 delta)
    {
        quote.mint(rewardHook, amount);
        vm.startPrank(rewardHook);
        assertTrue(quote.transfer(address(rewardVault), amount));
        (received, delta) = rewardVault.notifyReward();
        vm.stopPrank();
    }

    function _deployVault(IERC20 quote, uint256 minEligibleBalance)
        internal
        returns (RewardVault rewardVault)
    {
        return _deployVaultForToken(launchToken, quote, minEligibleBalance);
    }

    function _deployVaultForToken(
        NotifyingLaunchToken token,
        IERC20 quote,
        uint256 minEligibleBalance
    ) internal returns (RewardVault rewardVault) {
        address[] memory exclusions = new address[](3);
        exclusions[0] = poolManager;
        exclusions[1] = locker;
        exclusions[2] = treasury;
        rewardVault = new RewardVault(
            address(token), address(quote), rewardHook, minEligibleBalance, exclusions
        );
    }
}
