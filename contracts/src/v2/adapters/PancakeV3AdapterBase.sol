// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {
    IPancakeV3FactoryLike,
    IPancakeV3SwapRouterLike
} from "./interfaces/IPancakeV3AdapterTypes.sol";

abstract contract PancakeV3AdapterBase is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IPancakeV3SwapRouterLike public immutable pancakeV3Router;
    IPancakeV3FactoryLike public immutable pancakeV3Factory;
    address public immutable coordinator;
    address public immutable registrar;

    mapping(uint24 fee => bool allowed) public isFeeTierAllowed;

    error BadAdapterConfiguration();
    error NotCoordinator();
    error NotRegistrar();
    error AlreadyRegistered(bytes32 id);
    error DeadlineExpired();
    error BadAmount();
    error UnsupportedFeeTier(uint24 fee);
    error PoolMissing(address tokenA, address tokenB, uint24 fee);
    error InputTransferMismatch(address token, uint256 expectedAmount, uint256 actualAmount);
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error AdapterDust(address token, uint256 expectedBalance, uint256 actualBalance);

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert NotCoordinator();
        _;
    }

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    constructor(
        address coordinator_,
        address registrar_,
        IPancakeV3SwapRouterLike pancakeV3Router_,
        IPancakeV3FactoryLike pancakeV3Factory_,
        uint24[] memory allowedFeeTiers_
    ) {
        if (
            coordinator_ == address(0) || registrar_ == address(0)
                || address(pancakeV3Router_) == address(0)
                || address(pancakeV3Factory_) == address(0)
                || address(pancakeV3Router_).code.length == 0
                || address(pancakeV3Factory_).code.length == 0 || allowedFeeTiers_.length == 0
        ) revert BadAdapterConfiguration();

        coordinator = coordinator_;
        registrar = registrar_;
        pancakeV3Router = pancakeV3Router_;
        pancakeV3Factory = pancakeV3Factory_;

        for (uint256 i; i < allowedFeeTiers_.length; ++i) {
            uint24 fee = allowedFeeTiers_[i];
            if (pancakeV3Factory_.feeAmountTickSpacing(fee) <= 0) {
                revert UnsupportedFeeTier(fee);
            }
            isFeeTierAllowed[fee] = true;
        }
    }

    function _validateDeadlineAndAmounts(uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        internal
        view
    {
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (amountIn == 0 || minAmountOut == 0) revert BadAmount();
    }

    function _requireAllowedFee(uint24 fee) internal view {
        if (!isFeeTierAllowed[fee]) revert UnsupportedFeeTier(fee);
    }

    function _requirePool(address tokenA, address tokenB, uint24 fee)
        internal
        view
        returns (address pool)
    {
        _requireAllowedFee(fee);
        pool = pancakeV3Factory.getPool(tokenA, tokenB, fee);
        if (pool == address(0) || pool.code.length == 0) revert PoolMissing(tokenA, tokenB, fee);
    }

    function _poolExists(address tokenA, address tokenB, uint24 fee) internal view returns (bool) {
        if (!isFeeTierAllowed[fee]) return false;
        address pool = pancakeV3Factory.getPool(tokenA, tokenB, fee);
        return pool != address(0) && pool.code.length != 0;
    }

    function _pullExact(IERC20 token, uint256 amount) internal {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 actualAmount = token.balanceOf(address(this)) - balanceBefore;
        if (actualAmount != amount) {
            revert InputTransferMismatch(address(token), amount, actualAmount);
        }
    }

    function _restoreBalance(IERC20 token, uint256 expectedBalance) internal view {
        uint256 actualBalance = token.balanceOf(address(this));
        if (actualBalance != expectedBalance) {
            revert AdapterDust(address(token), expectedBalance, actualBalance);
        }
    }
}
