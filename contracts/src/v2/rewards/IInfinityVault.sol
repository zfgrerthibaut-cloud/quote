// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

type Currency is address;

interface IInfinityVaultLockCallback {
    function lockAcquired(bytes calldata data) external returns (bytes memory);
}

interface IInfinityVault {
    function balanceOf(address account, Currency currency) external view returns (uint256);
    function lock(bytes calldata data) external returns (bytes memory);
    function burn(address from, Currency currency, uint256 amount) external;
    function take(Currency currency, address to, uint256 amount) external;
}
