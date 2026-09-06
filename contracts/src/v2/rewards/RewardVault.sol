// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IRewardVault } from "./IRewardVault.sol";

/// @notice Pull-based holder reward accounting for one launch token and one quote token.
/// @dev The launch token is the only balance notifier. The future Pancake Infinity hook is the
///      only reward notifier. This vault does not know reward bps or platform fees.
contract RewardVault is IRewardVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ACCUMULATOR_SCALE = 1e36;

    address public immutable launchToken;
    address public immutable quoteToken;
    address public immutable rewardHook;
    uint256 public immutable minEligibleBalance;

    uint256 public totalEligibleShares;
    uint256 public rewardPerShareStored;
    uint256 public accountedQuoteBalance;
    uint256 public undistributedRewardScaled;
    uint256 public totalRewardsNotified;
    uint256 public totalRewardsClaimed;

    mapping(address account => uint256 balance) public trackedBalanceOf;
    mapping(address account => uint256 shares) public eligibleSharesOf;
    mapping(address account => uint256 rewardPerShare) public rewardPerSharePaid;
    mapping(address account => uint256 remainder) public rewardRemainderScaledOf;
    mapping(address account => uint256 amount) public accruedRewards;

    mapping(address account => bool excluded) private _isExcluded;

    error InvalidRewardVaultConfig();
    error NotLaunchToken(address caller);
    error NotRewardHook(address caller);
    error InvalidRewardAccount();
    error BalanceCheckpointMismatch(
        address account, uint256 expectedPreviousBalance, uint256 actualTrackedBalance
    );
    error QuoteBalanceBelowAccounted(uint256 actualBalance, uint256 accountedBalance);
    error NoRewardReceived();
    error NoEligibleShares();
    error NoRewardsClaimable(address account);
    error InsufficientAccountedQuote(uint256 requested, uint256 accountedBalance);
    error BadQuoteTransferDelta(uint256 expectedDelta, uint256 actualDelta);
    error BadQuoteRecipientDelta(uint256 expectedDelta, uint256 actualDelta);

    event RewardVaultExcluded(address indexed account);
    event RewardBalanceChanged(
        address indexed account,
        uint256 previousBalance,
        uint256 newBalance,
        uint256 previousShares,
        uint256 newShares
    );
    event RewardNotified(
        address indexed hook,
        uint256 received,
        uint256 totalShares,
        uint256 rewardPerShareDelta,
        uint256 rewardPerShare,
        uint256 undistributedRewardScaled
    );
    event RewardClaimed(address indexed account, uint256 amount);

    constructor(
        address launchToken_,
        address quoteToken_,
        address rewardHook_,
        uint256 minEligibleBalance_,
        address[] memory excludedAccounts_
    ) {
        if (
            launchToken_ == address(0) || quoteToken_ == address(0) || rewardHook_ == address(0)
                || minEligibleBalance_ == 0 || launchToken_ == quoteToken_
                || launchToken_ == rewardHook_ || quoteToken_ == rewardHook_
        ) revert InvalidRewardVaultConfig();

        launchToken = launchToken_;
        quoteToken = quoteToken_;
        rewardHook = rewardHook_;
        minEligibleBalance = minEligibleBalance_;

        _setExcluded(address(0));
        _setExcluded(address(this));
        _setExcluded(launchToken_);
        _setExcluded(quoteToken_);
        _setExcluded(rewardHook_);

        uint256 length = excludedAccounts_.length;
        for (uint256 i; i < length; ++i) {
            _setExcluded(excludedAccounts_[i]);
        }
    }

    /// @notice Returns true for accounts that can never receive reward shares.
    function isExcluded(address account) external view returns (bool) {
        return _isExcluded[account];
    }

    /// @notice Called by the linked launch token after an account balance changes.
    /// @dev This path is deliberately arithmetic-only: it does not read quote balances, token
    ///      balances, or call arbitrary external contracts.
    function notifyBalanceChange(address account, uint256 previousBalance, uint256 newBalance)
        external
    {
        if (msg.sender != launchToken) revert NotLaunchToken(msg.sender);
        if (account == address(0)) revert InvalidRewardAccount();

        uint256 trackedBalance = trackedBalanceOf[account];
        if (trackedBalance != previousBalance) {
            revert BalanceCheckpointMismatch(account, previousBalance, trackedBalance);
        }

        _checkpoint(account);

        uint256 previousShares = eligibleSharesOf[account];
        uint256 newShares = _sharesFor(account, newBalance);

        trackedBalanceOf[account] = newBalance;
        eligibleSharesOf[account] = newShares;
        if (newShares > previousShares) {
            totalEligibleShares += newShares - previousShares;
        } else {
            totalEligibleShares -= previousShares - newShares;
        }

        emit RewardBalanceChanged(account, previousBalance, newBalance, previousShares, newShares);
    }

    /// @notice Accounts for quote tokens already transferred into the vault by the reward hook.
    /// @dev The hook/factory own all fee-rate policy. This function only measures net quote received.
    function notifyReward() external nonReentrant returns (uint256 received, uint256 delta) {
        if (msg.sender != rewardHook) revert NotRewardHook(msg.sender);

        uint256 balance = IERC20(quoteToken).balanceOf(address(this));
        uint256 accounted = accountedQuoteBalance;
        if (balance < accounted) revert QuoteBalanceBelowAccounted(balance, accounted);

        received = balance - accounted;

        uint256 totalShares = totalEligibleShares;
        if (totalShares == 0) revert NoEligibleShares();

        uint256 scaledCarry = undistributedRewardScaled;
        if (received == 0 && scaledCarry == 0) revert NoRewardReceived();

        (delta, undistributedRewardScaled) =
            _rewardPerShareDelta(received, scaledCarry, totalShares);
        if (delta != 0) rewardPerShareStored += delta;

        accountedQuoteBalance = balance;
        totalRewardsNotified += received;

        emit RewardNotified(
            msg.sender,
            received,
            totalShares,
            delta,
            rewardPerShareStored,
            undistributedRewardScaled
        );
    }

    /// @notice Claims the caller's accrued quote rewards.
    function claim() external nonReentrant returns (uint256 amount) {
        address account = msg.sender;
        _checkpoint(account);

        amount = accruedRewards[account];
        if (amount == 0) revert NoRewardsClaimable(account);

        uint256 accounted = accountedQuoteBalance;
        if (amount > accounted) revert InsufficientAccountedQuote(amount, accounted);

        IERC20 quote = IERC20(quoteToken);
        uint256 vaultBalanceBefore = quote.balanceOf(address(this));
        if (vaultBalanceBefore < accounted) {
            revert QuoteBalanceBelowAccounted(vaultBalanceBefore, accounted);
        }

        uint256 recipientBalanceBefore = quote.balanceOf(account);
        accruedRewards[account] = 0;

        quote.safeTransfer(account, amount);

        uint256 vaultBalanceAfter = quote.balanceOf(address(this));
        if (vaultBalanceAfter > vaultBalanceBefore) revert BadQuoteTransferDelta(amount, 0);
        uint256 vaultDelta = vaultBalanceBefore - vaultBalanceAfter;
        if (vaultDelta != amount) revert BadQuoteTransferDelta(amount, vaultDelta);

        uint256 recipientBalanceAfter = quote.balanceOf(account);
        if (recipientBalanceAfter < recipientBalanceBefore) {
            revert BadQuoteRecipientDelta(amount, 0);
        }
        uint256 recipientDelta = recipientBalanceAfter - recipientBalanceBefore;
        if (recipientDelta != amount) revert BadQuoteRecipientDelta(amount, recipientDelta);

        accountedQuoteBalance = accounted - amount;
        totalRewardsClaimed += amount;

        emit RewardClaimed(account, amount);
    }

    /// @notice Returns the quote amount currently claimable by an account.
    function claimable(address account) external view returns (uint256) {
        return _claimable(account);
    }

    function _checkpoint(address account) private {
        uint256 accumulated = _claimable(account);
        accruedRewards[account] = accumulated;
        rewardRemainderScaledOf[account] =
            _claimableRemainder(account, rewardPerShareStored - rewardPerSharePaid[account]);
        rewardPerSharePaid[account] = rewardPerShareStored;
    }

    function _claimable(address account) private view returns (uint256) {
        uint256 pending = accruedRewards[account];
        uint256 shares = eligibleSharesOf[account];
        if (shares == 0) return pending;

        uint256 delta = rewardPerShareStored - rewardPerSharePaid[account];
        if (delta == 0) return pending;
        uint256 wholeReward = Math.mulDiv(shares, delta, ACCUMULATOR_SCALE);
        uint256 scaledRemainder =
            rewardRemainderScaledOf[account] + mulmod(shares, delta, ACCUMULATOR_SCALE);
        return pending + wholeReward + (scaledRemainder / ACCUMULATOR_SCALE);
    }

    function _claimableRemainder(address account, uint256 delta) private view returns (uint256) {
        uint256 shares = eligibleSharesOf[account];
        if (shares == 0 || delta == 0) return rewardRemainderScaledOf[account];

        uint256 scaledRemainder =
            rewardRemainderScaledOf[account] + mulmod(shares, delta, ACCUMULATOR_SCALE);
        return scaledRemainder % ACCUMULATOR_SCALE;
    }

    function _rewardPerShareDelta(uint256 received, uint256 scaledCarry, uint256 totalShares)
        private
        pure
        returns (uint256 delta, uint256 nextScaledCarry)
    {
        delta = Math.mulDiv(received, ACCUMULATOR_SCALE, totalShares);
        uint256 productRemainder = mulmod(received, ACCUMULATOR_SCALE, totalShares);

        delta += scaledCarry / totalShares;
        uint256 carryRemainder = scaledCarry % totalShares;
        if (productRemainder >= totalShares - carryRemainder) {
            ++delta;
            nextScaledCarry = productRemainder - (totalShares - carryRemainder);
        } else {
            nextScaledCarry = productRemainder + carryRemainder;
        }
    }

    function _sharesFor(address account, uint256 balance) private view returns (uint256) {
        if (_isExcluded[account] || balance < minEligibleBalance) return 0;
        return balance;
    }

    function _setExcluded(address account) private {
        if (_isExcluded[account]) return;
        _isExcluded[account] = true;
        emit RewardVaultExcluded(account);
    }
}
