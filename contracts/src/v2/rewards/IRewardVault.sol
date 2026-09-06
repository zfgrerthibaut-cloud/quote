// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal callback surface used by the launch token to update holder reward shares.
interface IRewardBalanceChangeReceiver {
    function notifyBalanceChange(address account, uint256 previousBalance, uint256 newBalance)
        external;
}

/// @notice Pull-based reward vault surface used by the future swap hook and holders.
interface IRewardVault is IRewardBalanceChangeReceiver {
    function notifyReward() external returns (uint256 received, uint256 rewardPerShareDelta);
    function claim() external returns (uint256 amount);
}

/// @notice Pull-based Infinity VaultToken reward surface used by the future swap hook and holders.
interface IInfinityRewardVault is IRewardBalanceChangeReceiver {
    function notifyVaultReward(uint256 amount)
        external
        returns (uint256 received, uint256 rewardPerShareDelta);

    function claim() external returns (uint256 amount);
}
