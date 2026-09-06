// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { PancakeV3AdapterBase } from "./PancakeV3AdapterBase.sol";
import {
    IPancakeV3FactoryLike,
    IPancakeV3SwapRouterLike
} from "./interfaces/IPancakeV3AdapterTypes.sol";
import { ILaunchPoolBuyAdapter } from "../native/INativeDevBuyAdapters.sol";

contract PancakeV3LaunchPoolBuyAdapter is PancakeV3AdapterBase, ILaunchPoolBuyAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant LAUNCH_POOL_DOMAIN = keccak256("QUOTE.PancakeV3LaunchPool.v1");

    struct LaunchPoolConfig {
        address quoteToken;
        address launchedToken;
        uint24 fee;
        address expectedPool;
    }

    struct LaunchPool {
        address quoteToken;
        address launchedToken;
        uint24 fee;
        address expectedPool;
        bool enabled;
    }

    mapping(bytes32 poolId => LaunchPool pool) public launchPools;

    error BadLaunchPoolBuy();
    error LaunchPoolDisabled(bytes32 poolId);
    error UnexpectedPool(address expectedPool, address actualPool);

    event LaunchPoolRegistered(
        bytes32 indexed poolId,
        address indexed quote,
        address indexed launchedToken,
        uint24 fee,
        address pool
    );
    event LaunchTokenBought(
        address indexed quote,
        address indexed launchedToken,
        uint24 fee,
        address indexed pool,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address coordinator_,
        address registrar_,
        IPancakeV3SwapRouterLike pancakeV3Router_,
        IPancakeV3FactoryLike pancakeV3Factory_,
        uint24[] memory allowedFeeTiers_,
        LaunchPoolConfig[] memory launchPools_
    )
        PancakeV3AdapterBase(
            coordinator_, registrar_, pancakeV3Router_, pancakeV3Factory_, allowedFeeTiers_
        )
    {
        for (uint256 i; i < launchPools_.length; ++i) {
            _registerLaunchPool(launchPools_[i]);
        }
    }

    function registerLaunchPool(LaunchPoolConfig calldata config)
        external
        onlyRegistrar
        returns (bytes32 poolId)
    {
        return _registerLaunchPool(config);
    }

    function isPoolEnabled(bytes32 poolId, address launchedToken, address quoteToken)
        external
        view
        returns (bool)
    {
        LaunchPool memory pool = launchPools[poolId];
        if (!pool.enabled || pool.launchedToken != launchedToken || pool.quoteToken != quoteToken) {
            return false;
        }
        address actualPool = pancakeV3Factory.getPool(quoteToken, launchedToken, pool.fee);
        return actualPool == pool.expectedPool && actualPool.code.length != 0;
    }

    function buyWithQuote(BuyWithQuoteParams calldata params)
        external
        onlyCoordinator
        nonReentrant
        returns (uint256 quoteAmountIn, uint256 tokenAmountOut)
    {
        _validateDeadlineAndAmounts(
            params.maxQuoteAmountIn, params.minTokenAmountOut, params.deadline
        );
        if (
            params.quoteToken == address(0) || params.launchedToken == address(0)
                || params.quoteToken == params.launchedToken || params.quoteToken.code.length == 0
                || params.launchedToken.code.length == 0
        ) revert BadLaunchPoolBuy();

        LaunchPool memory pool = launchPools[params.poolId];
        if (
            !pool.enabled || pool.quoteToken != params.quoteToken
                || pool.launchedToken != params.launchedToken
        ) revert LaunchPoolDisabled(params.poolId);

        address actualPool = _requirePool(params.quoteToken, params.launchedToken, pool.fee);
        if (actualPool != pool.expectedPool) revert UnexpectedPool(pool.expectedPool, actualPool);

        IERC20 input = IERC20(params.quoteToken);
        IERC20 output = IERC20(params.launchedToken);
        uint256 inputBalanceBefore = input.balanceOf(address(this));
        uint256 outputBalanceBefore = output.balanceOf(address(this));
        uint256 coordinatorOutputBefore = output.balanceOf(msg.sender);

        quoteAmountIn = params.maxQuoteAmountIn;
        _pullExact(input, quoteAmountIn);
        input.forceApprove(address(pancakeV3Router), quoteAmountIn);
        pancakeV3Router.exactInputSingle(
            IPancakeV3SwapRouterLike.ExactInputSingleParams({
                tokenIn: params.quoteToken,
                tokenOut: params.launchedToken,
                fee: pool.fee,
                recipient: address(this),
                deadline: params.deadline,
                amountIn: quoteAmountIn,
                amountOutMinimum: params.minTokenAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        input.forceApprove(address(pancakeV3Router), 0);

        uint256 grossOutput = output.balanceOf(address(this)) - outputBalanceBefore;
        if (grossOutput != 0) output.safeTransfer(msg.sender, grossOutput);
        tokenAmountOut = output.balanceOf(msg.sender) - coordinatorOutputBefore;
        if (tokenAmountOut < params.minTokenAmountOut) {
            revert InsufficientOutput(tokenAmountOut, params.minTokenAmountOut);
        }

        _restoreBalance(input, inputBalanceBefore);
        _restoreBalance(output, outputBalanceBefore);

        emit LaunchTokenBought(
            params.quoteToken,
            params.launchedToken,
            pool.fee,
            actualPool,
            quoteAmountIn,
            tokenAmountOut
        );
    }

    function launchPoolId(
        address quoteToken,
        address launchedToken,
        uint24 fee,
        address expectedPool
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                LAUNCH_POOL_DOMAIN,
                block.chainid,
                address(pancakeV3Factory),
                quoteToken,
                launchedToken,
                fee,
                expectedPool
            )
        );
    }

    function _registerLaunchPool(LaunchPoolConfig memory config) private returns (bytes32 poolId) {
        _validateLaunchPool(config);
        poolId =
            launchPoolId(config.quoteToken, config.launchedToken, config.fee, config.expectedPool);
        if (poolId == bytes32(0)) revert BadLaunchPoolBuy();
        if (launchPools[poolId].enabled) revert AlreadyRegistered(poolId);
        launchPools[poolId] = LaunchPool({
            quoteToken: config.quoteToken,
            launchedToken: config.launchedToken,
            fee: config.fee,
            expectedPool: config.expectedPool,
            enabled: true
        });
        emit LaunchPoolRegistered(
            poolId, config.quoteToken, config.launchedToken, config.fee, config.expectedPool
        );
    }

    function _validateLaunchPool(LaunchPoolConfig memory config) private view {
        if (
            config.quoteToken == address(0) || config.launchedToken == address(0)
                || config.quoteToken == config.launchedToken || config.quoteToken.code.length == 0
                || config.launchedToken.code.length == 0 || config.expectedPool == address(0)
        ) revert BadLaunchPoolBuy();
        address actualPool = _requirePool(config.quoteToken, config.launchedToken, config.fee);
        if (actualPool != config.expectedPool) {
            revert UnexpectedPool(config.expectedPool, actualPool);
        }
    }
}
