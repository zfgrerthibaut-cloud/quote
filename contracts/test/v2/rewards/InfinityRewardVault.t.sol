// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    Currency,
    IInfinityVault,
    IInfinityVaultLockCallback
} from "../../../src/v2/rewards/IInfinityVault.sol";
import { IRewardBalanceChangeReceiver } from "../../../src/v2/rewards/IRewardVault.sol";
import { InfinityRewardVault } from "../../../src/v2/rewards/InfinityRewardVault.sol";

contract MockInfinityQuote is ERC20 {
    constructor() ERC20("Quote", "QUOTE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferInfinityQuote is MockInfinityQuote {
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / 10;
        if (fee == 0) {
            super._update(from, to, value);
            return;
        }

        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract MockInfinityLaunchToken is ERC20 {
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

contract MockInfinityVault is IInfinityVault {
    using SafeERC20 for IERC20;

    mapping(address account => mapping(address currency => uint256 amount)) internal _balances;

    address public activeLocker;
    bool public skipCallback;
    bool public shortBurn;

    error NotLocked();
    error ReentrantLock();

    modifier onlyActiveLocker() {
        if (activeLocker == address(0) || msg.sender != activeLocker) revert NotLocked();
        _;
    }

    function setSkipCallback(bool skipCallback_) external {
        skipCallback = skipCallback_;
    }

    function setShortBurn(bool shortBurn_) external {
        shortBurn = shortBurn_;
    }

    function mint(address to, Currency currency, uint256 amount) external {
        _balances[to][Currency.unwrap(currency)] += amount;
    }

    function balanceOf(address account, Currency currency) external view returns (uint256) {
        return _balances[account][Currency.unwrap(currency)];
    }

    function lock(bytes calldata data) external returns (bytes memory result) {
        if (activeLocker != address(0)) revert ReentrantLock();
        activeLocker = msg.sender;
        if (!skipCallback) result = IInfinityVaultLockCallback(msg.sender).lockAcquired(data);
        activeLocker = address(0);
    }

    function burn(address from, Currency currency, uint256 amount) external onlyActiveLocker {
        uint256 burnAmount = shortBurn ? amount - 1 : amount;
        _balances[from][Currency.unwrap(currency)] -= burnAmount;
    }

    function take(Currency currency, address to, uint256 amount) external onlyActiveLocker {
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }

    function callLockAcquired(address target, bytes calldata data) external returns (bytes memory) {
        return IInfinityVaultLockCallback(target).lockAcquired(data);
    }
}

contract InfinityRewardVaultTest is Test {
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

    MockInfinityLaunchToken internal launchToken;
    MockInfinityQuote internal quoteToken;
    MockInfinityVault internal infinityVault;
    InfinityRewardVault internal vault;
    Currency internal quoteCurrency;

    function setUp() external {
        launchToken = new MockInfinityLaunchToken();
        quoteToken = new MockInfinityQuote();
        infinityVault = new MockInfinityVault();
        quoteCurrency = Currency.wrap(address(quoteToken));
        vault = _deployVault(launchToken, quoteToken, infinityVault, MIN_ELIGIBLE_BALANCE);
        launchToken.setRewardVault(IRewardBalanceChangeReceiver(address(vault)));
    }

    function testConstructorStoresImmutableAssetsAndFixedExclusions() external view {
        assertEq(vault.launchToken(), address(launchToken));
        assertEq(address(vault.infinityVault()), address(infinityVault));
        assertEq(vault.quoteToken(), address(quoteToken));
        assertEq(Currency.unwrap(vault.quoteCurrency()), address(quoteToken));
        assertEq(vault.rewardHook(), rewardHook);
        assertEq(vault.minEligibleBalance(), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.ACCUMULATOR_SCALE(), SCALE);

        assertTrue(vault.isExcluded(address(0)));
        assertTrue(vault.isExcluded(address(vault)));
        assertTrue(vault.isExcluded(address(launchToken)));
        assertTrue(vault.isExcluded(address(infinityVault)));
        assertTrue(vault.isExcluded(address(quoteToken)));
        assertTrue(vault.isExcluded(rewardHook));
        assertTrue(vault.isExcluded(poolManager));
        assertTrue(vault.isExcluded(locker));
        assertTrue(vault.isExcluded(treasury));
        assertFalse(vault.isExcluded(alice));
    }

    function testNotifyVaultRewardAndClaimThroughInfinityLock() external {
        launchToken.mint(alice, 100 ether);
        launchToken.mint(bob, 300 ether);
        launchToken.mint(dust, MIN_ELIGIBLE_BALANCE - 1);
        launchToken.mint(treasury, 1_000 ether);

        assertEq(vault.totalEligibleShares(), 400 ether);
        assertEq(vault.eligibleSharesOf(dust), 0);
        assertEq(vault.eligibleSharesOf(treasury), 0);

        (uint256 received, uint256 delta) = _creditVaultReward(40 ether);

        assertEq(received, 40 ether);
        assertEq(delta, (40 ether * SCALE) / 400 ether);
        assertEq(vault.claimable(alice), 10 ether);
        assertEq(vault.claimable(bob), 30 ether);
        assertEq(vault.accountedQuoteBalance(), 40 ether);
        assertEq(infinityVault.balanceOf(address(vault), quoteCurrency), 40 ether);
        assertEq(vault.totalRewardsNotified(), 40 ether);

        vm.prank(alice);
        assertEq(vault.claim(), 10 ether);
        assertEq(quoteToken.balanceOf(alice), 10 ether);
        assertEq(vault.accountedQuoteBalance(), 30 ether);
        assertEq(infinityVault.balanceOf(address(vault), quoteCurrency), 30 ether);
        assertEq(vault.totalRewardsClaimed(), 10 ether);

        vm.prank(bob);
        assertEq(vault.claim(), 30 ether);
        assertEq(quoteToken.balanceOf(bob), 30 ether);
        assertEq(vault.accountedQuoteBalance(), 0);
        assertEq(infinityVault.balanceOf(address(vault), quoteCurrency), 0);
        assertEq(quoteToken.balanceOf(address(infinityVault)), 0);
        assertEq(vault.totalRewardsClaimed(), 40 ether);
    }

    function testNotifyVaultRewardChecksHookAndRejectsShortVaultBalanceDelta() external {
        launchToken.mint(alice, 100 ether);
        _fundInfinityVault(10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(InfinityRewardVault.NotRewardHook.selector, attacker)
        );
        vm.prank(attacker);
        vault.notifyVaultReward(10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                InfinityRewardVault.VaultRewardDeltaMismatch.selector, 11 ether, 10 ether
            )
        );
        vm.prank(rewardHook);
        vault.notifyVaultReward(11 ether);

        vm.prank(rewardHook);
        (uint256 received,) = vault.notifyVaultReward(10 ether);
        assertEq(received, 10 ether);
    }

    function testNotifyVaultRewardDistributesMeasuredSurplus() external {
        launchToken.mint(alice, 100 ether);
        launchToken.mint(bob, 300 ether);

        _fundInfinityVault(5 ether);
        quoteToken.mint(address(infinityVault), 40 ether);
        infinityVault.mint(address(vault), quoteCurrency, 40 ether);

        vm.prank(rewardHook);
        (uint256 received, uint256 delta) = vault.notifyVaultReward(40 ether);

        assertEq(received, 45 ether);
        assertEq(delta, (45 ether * SCALE) / 400 ether);
        assertEq(vault.accountedQuoteBalance(), 45 ether);
        assertEq(vault.totalRewardsNotified(), 45 ether);
        assertEq(vault.claimable(alice), 11.25 ether);
        assertEq(vault.claimable(bob), 33.75 ether);
    }

    function testTinyVaultRewardCarriesUntilLaterTopUpCanDistribute() external {
        MockInfinityLaunchToken token = new MockInfinityLaunchToken();
        MockInfinityQuote quote = new MockInfinityQuote();
        MockInfinityVault infinity = new MockInfinityVault();
        InfinityRewardVault localVault = _deployVault(token, quote, infinity, 1);
        token.setRewardVault(IRewardBalanceChangeReceiver(address(localVault)));
        token.mint(alice, 3);

        (uint256 received, uint256 delta) =
            _creditVaultReward(localVault, quote, infinity, Currency.wrap(address(quote)), 1);

        assertEq(received, 1);
        assertEq(delta, SCALE / 3);
        assertEq(localVault.accountedQuoteBalance(), 1);
        assertEq(localVault.undistributedRewardScaled(), SCALE % 3);
        assertEq(localVault.claimable(alice), 0);

        (received, delta) =
            _creditVaultReward(localVault, quote, infinity, Currency.wrap(address(quote)), 2);

        assertEq(received, 2);
        assertEq(delta, ((2 * SCALE) + (SCALE % 3)) / 3);
        assertEq(localVault.undistributedRewardScaled(), 0);
        assertEq(localVault.rewardPerShareStored(), SCALE);
        assertEq(localVault.claimable(alice), 3);

        vm.prank(alice);
        assertEq(localVault.claim(), 3);
        assertEq(quote.balanceOf(alice), 3);
        assertEq(localVault.accountedQuoteBalance(), 0);
        assertEq(infinity.balanceOf(address(localVault), Currency.wrap(address(quote))), 0);
    }

    function testBalanceNotifierTracksDustAndExclusions() external {
        launchToken.mint(alice, MIN_ELIGIBLE_BALANCE - 1);
        launchToken.mint(bob, MIN_ELIGIBLE_BALANCE);
        launchToken.mint(treasury, 100 ether);

        assertEq(vault.trackedBalanceOf(alice), MIN_ELIGIBLE_BALANCE - 1);
        assertEq(vault.trackedBalanceOf(bob), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.trackedBalanceOf(treasury), 100 ether);
        assertEq(vault.eligibleSharesOf(alice), 0);
        assertEq(vault.eligibleSharesOf(bob), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.eligibleSharesOf(treasury), 0);
        assertEq(vault.totalEligibleShares(), MIN_ELIGIBLE_BALANCE);

        launchToken.mint(alice, 1);
        assertEq(vault.eligibleSharesOf(alice), MIN_ELIGIBLE_BALANCE);
        assertEq(vault.totalEligibleShares(), MIN_ELIGIBLE_BALANCE * 2);
    }

    function testLockCallbackRejectsWrongCallerAndInactiveVaultCallback() external {
        bytes memory lockData = abi.encode(bytes32(0), alice, uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(InfinityRewardVault.NotInfinityVault.selector, attacker)
        );
        vm.prank(attacker);
        vault.lockAcquired(lockData);

        vm.expectRevert(InfinityRewardVault.InvalidLockAction.selector);
        infinityVault.callLockAcquired(address(vault), lockData);
    }

    function testClaimRequiresLockCallback() external {
        launchToken.mint(alice, 100 ether);
        _creditVaultReward(10 ether);
        infinityVault.setSkipCallback(true);

        vm.expectRevert(InfinityRewardVault.LockCallbackMissing.selector);
        vm.prank(alice);
        vault.claim();

        assertEq(vault.claimable(alice), 10 ether);
        assertEq(vault.accountedQuoteBalance(), 10 ether);
        assertEq(infinityVault.balanceOf(address(vault), quoteCurrency), 10 ether);
    }

    function testClaimRejectsBadVaultClaimDelta() external {
        launchToken.mint(alice, 100 ether);
        _creditVaultReward(10 ether);
        infinityVault.setShortBurn(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                InfinityRewardVault.BadVaultClaimDelta.selector, 10 ether, 10 ether - 1
            )
        );
        vm.prank(alice);
        vault.claim();

        assertEq(vault.claimable(alice), 10 ether);
        assertEq(vault.accountedQuoteBalance(), 10 ether);
        assertEq(infinityVault.balanceOf(address(vault), quoteCurrency), 10 ether);
        assertEq(quoteToken.balanceOf(alice), 0);
    }

    function testClaimRejectsFeeOnTransferQuoteRecipientDelta() external {
        MockInfinityLaunchToken token = new MockInfinityLaunchToken();
        FeeOnTransferInfinityQuote quote = new FeeOnTransferInfinityQuote();
        MockInfinityVault infinity = new MockInfinityVault();
        InfinityRewardVault localVault = _deployVault(token, quote, infinity, MIN_ELIGIBLE_BALANCE);
        Currency currency = Currency.wrap(address(quote));
        token.setRewardVault(IRewardBalanceChangeReceiver(address(localVault)));
        token.mint(alice, 100 ether);

        _creditVaultReward(localVault, quote, infinity, currency, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                InfinityRewardVault.BadQuoteRecipientDelta.selector, 10 ether, 9 ether
            )
        );
        vm.prank(alice);
        localVault.claim();

        assertEq(localVault.claimable(alice), 10 ether);
        assertEq(localVault.accountedQuoteBalance(), 10 ether);
        assertEq(infinity.balanceOf(address(localVault), currency), 10 ether);
        assertEq(quote.balanceOf(alice), 0);
    }

    function testClaimRevertsWhenNothingIsClaimable() external {
        launchToken.mint(alice, 100 ether);

        vm.expectRevert(
            abi.encodeWithSelector(InfinityRewardVault.NoRewardsClaimable.selector, alice)
        );
        vm.prank(alice);
        vault.claim();
    }

    function testNotifyVaultRewardRejectsNoEligibleShares() external {
        _fundInfinityVault(1 ether);

        vm.expectRevert(InfinityRewardVault.NoEligibleShares.selector);
        vm.prank(rewardHook);
        vault.notifyVaultReward(1 ether);
    }

    function _creditVaultReward(uint256 amount) internal returns (uint256 received, uint256 delta) {
        return _creditVaultReward(vault, quoteToken, infinityVault, quoteCurrency, amount);
    }

    function _creditVaultReward(
        InfinityRewardVault rewardVault,
        MockInfinityQuote quote,
        MockInfinityVault infinity,
        Currency currency,
        uint256 amount
    ) internal returns (uint256 received, uint256 delta) {
        quote.mint(address(infinity), amount);
        infinity.mint(address(rewardVault), currency, amount);
        vm.prank(rewardHook);
        (received, delta) = rewardVault.notifyVaultReward(amount);
    }

    function _fundInfinityVault(uint256 amount) internal {
        quoteToken.mint(address(infinityVault), amount);
        infinityVault.mint(address(vault), quoteCurrency, amount);
    }

    function _deployVault(
        MockInfinityLaunchToken token,
        MockInfinityQuote quote,
        MockInfinityVault infinity,
        uint256 minEligibleBalance
    ) internal returns (InfinityRewardVault rewardVault) {
        address[] memory exclusions = new address[](3);
        exclusions[0] = poolManager;
        exclusions[1] = locker;
        exclusions[2] = treasury;
        rewardVault = new InfinityRewardVault(
            address(token),
            IInfinityVault(address(infinity)),
            address(quote),
            rewardHook,
            minEligibleBalance,
            exclusions
        );
    }
}
