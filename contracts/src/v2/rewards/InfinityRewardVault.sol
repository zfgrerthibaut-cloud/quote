// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { Currency, IInfinityVault, IInfinityVaultLockCallback } from "./IInfinityVault.sol";
import { IInfinityRewardVault } from "./IRewardVault.sol";

/// @notice Pull-based holder rewards backed by Pancake Infinity VaultToken quote claims.
/// @dev The hook mints VaultToken claims to this contract, then calls notifyVaultReward(amount).
///      Holders claim real ERC20 quote through the Infinity vault lock callback.
contract InfinityRewardVault is IInfinityRewardVault, IInfinityVaultLockCallback, ReentrancyGuard {
    uint256 public constant ACCUMULATOR_SCALE = 1e36;
    bytes32 private constant CLAIM_LOCK_ACTION = keccak256("QUOTE.InfinityRewardVault.claim.v1");
    uint256 private constant LOCK_ACTION_NONE = 0;
    uint256 private constant LOCK_ACTION_CLAIM = 1;
    uint256 private constant LOCK_ACTION_CLAIM_EXECUTED = 2;

    address public immutable launchToken;
    IInfinityVault public immutable infinityVault;
    address public immutable quoteToken;
    Currency public immutable quoteCurrency;
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

    uint256 private _lockAction;
    address private _lockAccount;
    uint256 private _lockAmount;

    error InvalidInfinityRewardVaultConfig();
    error NotLaunchToken(address caller);
    error NotRewardHook(address caller);
    error NotInfinityVault(address caller);
    error InvalidRewardAccount();
    error BalanceCheckpointMismatch(
        address account, uint256 expectedPreviousBalance, uint256 actualTrackedBalance
    );
    error VaultBalanceBelowAccounted(uint256 actualBalance, uint256 accountedBalance);
    error NoRewardReceived();
    error NoEligibleShares();
    error NoRewardsClaimable(address account);
    error InsufficientAccountedQuote(uint256 requested, uint256 accountedBalance);
    error VaultRewardDeltaMismatch(uint256 expectedDelta, uint256 actualDelta);
    error BadVaultClaimDelta(uint256 expectedDelta, uint256 actualDelta);
    error BadQuoteRecipientDelta(uint256 expectedDelta, uint256 actualDelta);
    error InvalidLockAction();
    error InvalidLockData();
    error LockCallbackMissing();

    event RewardVaultExcluded(address indexed account);
    event RewardBalanceChanged(
        address indexed account,
        uint256 previousBalance,
        uint256 newBalance,
        uint256 previousShares,
        uint256 newShares
    );
    event VaultRewardNotified(
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
        IInfinityVault infinityVault_,
        address quoteToken_,
        address rewardHook_,
        uint256 minEligibleBalance_,
        address[] memory excludedAccounts_
    ) {
        if (
            launchToken_ == address(0) || address(infinityVault_) == address(0)
                || quoteToken_ == address(0) || rewardHook_ == address(0)
                || minEligibleBalance_ == 0 || launchToken_ == quoteToken_
                || launchToken_ == rewardHook_ || quoteToken_ == rewardHook_
        ) revert InvalidInfinityRewardVaultConfig();

        launchToken = launchToken_;
        infinityVault = infinityVault_;
        quoteToken = quoteToken_;
        quoteCurrency = Currency.wrap(quoteToken_);
        rewardHook = rewardHook_;
        minEligibleBalance = minEligibleBalance_;

        _setExcluded(address(0));
        _setExcluded(address(this));
        _setExcluded(launchToken_);
        _setExcluded(address(infinityVault_));
        _setExcluded(quoteToken_);
        _setExcluded(rewardHook_);

        uint256 length = excludedAccounts_.length;
        for (uint256 i; i < length; ++i) {
            _setExcluded(excludedAccounts_[i]);
        }
    }

    function isExcluded(address account) external view returns (bool) {
        return _isExcluded[account];
    }

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

    function notifyVaultReward(uint256 amount)
        external
        nonReentrant
        returns (uint256 received, uint256 delta)
    {
        if (msg.sender != rewardHook) revert NotRewardHook(msg.sender);
        if (amount == 0) revert NoRewardReceived();

        uint256 balance = infinityVault.balanceOf(address(this), quoteCurrency);
        uint256 accounted = accountedQuoteBalance;
        if (balance < accounted) revert VaultBalanceBelowAccounted(balance, accounted);

        received = balance - accounted;
        if (received < amount) revert VaultRewardDeltaMismatch(amount, received);

        uint256 totalShares = totalEligibleShares;
        if (totalShares == 0) revert NoEligibleShares();

        uint256 scaledCarry = undistributedRewardScaled;
        (delta, undistributedRewardScaled) =
            _rewardPerShareDelta(received, scaledCarry, totalShares);
        if (delta != 0) rewardPerShareStored += delta;

        accountedQuoteBalance = balance;
        totalRewardsNotified += received;

        emit VaultRewardNotified(
            msg.sender,
            received,
            totalShares,
            delta,
            rewardPerShareStored,
            undistributedRewardScaled
        );
    }

    function claim() external nonReentrant returns (uint256 amount) {
        address account = msg.sender;
        _checkpoint(account);

        amount = accruedRewards[account];
        if (amount == 0) revert NoRewardsClaimable(account);

        uint256 accounted = accountedQuoteBalance;
        if (amount > accounted) revert InsufficientAccountedQuote(amount, accounted);

        uint256 vaultBalanceBefore = infinityVault.balanceOf(address(this), quoteCurrency);
        if (vaultBalanceBefore < accounted) {
            revert VaultBalanceBelowAccounted(vaultBalanceBefore, accounted);
        }

        IERC20 quote = IERC20(quoteToken);
        uint256 recipientBalanceBefore = quote.balanceOf(account);

        accruedRewards[account] = 0;
        _lockAction = LOCK_ACTION_CLAIM;
        _lockAccount = account;
        _lockAmount = amount;

        infinityVault.lock(abi.encode(CLAIM_LOCK_ACTION, account, amount));
        if (_lockAction != LOCK_ACTION_CLAIM_EXECUTED) revert LockCallbackMissing();

        _lockAction = LOCK_ACTION_NONE;
        _lockAccount = address(0);
        _lockAmount = 0;

        uint256 vaultBalanceAfter = infinityVault.balanceOf(address(this), quoteCurrency);
        if (vaultBalanceAfter > vaultBalanceBefore) revert BadVaultClaimDelta(amount, 0);
        uint256 vaultDelta = vaultBalanceBefore - vaultBalanceAfter;
        if (vaultDelta != amount) revert BadVaultClaimDelta(amount, vaultDelta);

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

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(infinityVault)) revert NotInfinityVault(msg.sender);
        if (_lockAction != LOCK_ACTION_CLAIM) revert InvalidLockAction();
        if (data.length != 96) revert InvalidLockData();

        (bytes32 action, address account, uint256 amount) =
            abi.decode(data, (bytes32, address, uint256));
        if (action != CLAIM_LOCK_ACTION || account != _lockAccount || amount != _lockAmount) {
            revert InvalidLockData();
        }

        _lockAction = LOCK_ACTION_CLAIM_EXECUTED;
        infinityVault.burn(address(this), quoteCurrency, amount);
        infinityVault.take(quoteCurrency, account, amount);

        return "";
    }

    function claimable(address account) external view returns (uint256) {
        return _claimable(account);
    }

    function _checkpoint(address account) private {
        uint256 delta = rewardPerShareStored - rewardPerSharePaid[account];
        accruedRewards[account] = _claimable(account);
        rewardRemainderScaledOf[account] = _claimableRemainder(account, delta);
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
