// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { IPancakeV3Factory, IPancakeV3Pool } from "../../interfaces/IPancakeV3.sol";
import { IPancakeV3SwapRouterLike } from "../adapters/interfaces/IPancakeV3AdapterTypes.sol";
import { IWBNB } from "../native/INativeDevBuyAdapters.sol";

/// @notice Typed BNB developer-buy path owned by one direct V3 engine.
/// @dev It can only wrap BNB and execute canonical Pancake V3 exact-input single-pool swaps.
contract DirectV3NativeBuy is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable engine;
    IWBNB public immutable wbnb;
    IPancakeV3SwapRouterLike public immutable swapRouter;
    IPancakeV3Factory public immutable pancakeFactory;

    struct DevBuyParams {
        uint256 nativeAmountIn;
        uint256 minQuoteOut;
        uint256 minTokenOut;
        uint256 deadline;
        uint24 quoteFeeTier;
        address expectedQuotePool;
        uint160 quoteSqrtPriceLimitX96;
        uint160 launchSqrtPriceLimitX96;
        address beneficiary;
    }

    struct DevBuyResult {
        uint256 nativeAmountIn;
        uint256 quoteAmountOut;
        uint256 quoteAmountSpent;
        uint256 tokenAmountOut;
        uint256 wbnbRefundedAsNative;
        uint256 quoteRefunded;
    }

    error BadDependencies();
    error NotEngine();
    error InvalidDevBuy();
    error NativeValueMismatch(uint256 actual, uint256 expected);
    error DeadlineExpired();
    error UnsupportedFeeTier(uint24 feeTier);
    error QuotePoolMismatch(address expected, address actual);
    error PoolNotInitialized(address pool);
    error NativeWrapFailed();
    error NativeTransferFailed();
    error QuoteSlippage(uint256 amountOut, uint256 minAmountOut);
    error TokenSlippage(uint256 amountOut, uint256 minAmountOut);
    error ResidualBalance(address token, uint256 expected, uint256 actual);

    event NativeDeveloperBuy(
        address indexed beneficiary,
        address indexed quoteToken,
        address indexed launchedToken,
        uint256 nativeAmountIn,
        uint256 quoteAmountOut,
        uint256 quoteAmountSpent,
        uint256 tokenAmountOut,
        uint256 wbnbRefundedAsNative,
        uint256 quoteRefunded
    );

    constructor(
        address engine_,
        IWBNB wbnb_,
        IPancakeV3SwapRouterLike swapRouter_,
        IPancakeV3Factory pancakeFactory_
    ) {
        if (
            engine_ == address(0) || address(wbnb_) == address(0) || address(wbnb_).code.length == 0
                || address(swapRouter_) == address(0) || address(swapRouter_).code.length == 0
                || address(pancakeFactory_) == address(0)
                || address(pancakeFactory_).code.length == 0
        ) revert BadDependencies();
        engine = engine_;
        wbnb = wbnb_;
        swapRouter = swapRouter_;
        pancakeFactory = pancakeFactory_;
    }

    receive() external payable {
        if (msg.sender != address(wbnb)) revert NativeTransferFailed();
    }

    function buy(
        address launchedToken,
        address quoteToken,
        uint24 launchFeeTier,
        uint256 launchDeadline,
        DevBuyParams calldata params
    ) external payable nonReentrant returns (DevBuyResult memory result) {
        if (msg.sender != engine) revert NotEngine();
        _validate(launchedToken, quoteToken, launchFeeTier, launchDeadline, params);
        if (msg.value != params.nativeAmountIn) {
            revert NativeValueMismatch(msg.value, params.nativeAmountIn);
        }

        IERC20 wbnbToken = IERC20(address(wbnb));
        IERC20 quote = IERC20(quoteToken);
        uint256 nativeBalanceBaseline = address(this).balance - msg.value;
        uint256 wbnbBalanceBaseline = wbnbToken.balanceOf(address(this));
        uint256 quoteBalanceBaseline =
            quoteToken == address(wbnb) ? wbnbBalanceBaseline : quote.balanceOf(address(this));

        wbnb.deposit{ value: params.nativeAmountIn }();
        if (wbnbToken.balanceOf(address(this)) != wbnbBalanceBaseline + params.nativeAmountIn) {
            revert NativeWrapFailed();
        }

        uint256 quoteAmountOut;
        uint256 wbnbRefundedAsNative;
        if (quoteToken == address(wbnb)) {
            quoteAmountOut = params.nativeAmountIn;
        } else {
            wbnbToken.forceApprove(address(swapRouter), params.nativeAmountIn);
            swapRouter.exactInputSingle(
                IPancakeV3SwapRouterLike.ExactInputSingleParams({
                    tokenIn: address(wbnb),
                    tokenOut: quoteToken,
                    fee: params.quoteFeeTier,
                    recipient: address(this),
                    deadline: params.deadline,
                    amountIn: params.nativeAmountIn,
                    amountOutMinimum: params.minQuoteOut,
                    sqrtPriceLimitX96: params.quoteSqrtPriceLimitX96
                })
            );
            wbnbToken.forceApprove(address(swapRouter), 0);
            quoteAmountOut = quote.balanceOf(address(this)) - quoteBalanceBaseline;

            uint256 unspentWbnb = wbnbToken.balanceOf(address(this)) - wbnbBalanceBaseline;
            wbnbRefundedAsNative = _refundWbnb(params.beneficiary, unspentWbnb);
        }
        if (quoteAmountOut < params.minQuoteOut) {
            revert QuoteSlippage(quoteAmountOut, params.minQuoteOut);
        }

        IERC20 launched = IERC20(launchedToken);
        uint256 beneficiaryTokenBefore = launched.balanceOf(params.beneficiary);
        uint256 quoteBalanceBeforeBuy = quote.balanceOf(address(this));
        quote.forceApprove(address(swapRouter), quoteAmountOut);
        swapRouter.exactInputSingle(
            IPancakeV3SwapRouterLike.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: launchedToken,
                fee: launchFeeTier,
                recipient: params.beneficiary,
                deadline: params.deadline,
                amountIn: quoteAmountOut,
                amountOutMinimum: params.minTokenOut,
                sqrtPriceLimitX96: params.launchSqrtPriceLimitX96
            })
        );
        quote.forceApprove(address(swapRouter), 0);

        uint256 quoteBalanceAfterBuy = quote.balanceOf(address(this));
        uint256 quoteAmountSpent = quoteBalanceBeforeBuy - quoteBalanceAfterBuy;
        uint256 tokenAmountOut = launched.balanceOf(params.beneficiary) - beneficiaryTokenBefore;
        if (tokenAmountOut < params.minTokenOut) {
            revert TokenSlippage(tokenAmountOut, params.minTokenOut);
        }

        uint256 quoteRefunded;
        uint256 quoteDust = quoteBalanceAfterBuy - quoteBalanceBaseline;
        if (quoteDust != 0) {
            if (quoteToken == address(wbnb)) {
                wbnbRefundedAsNative += _refundWbnb(params.beneficiary, quoteDust);
            } else {
                quote.safeTransfer(params.beneficiary, quoteDust);
                quoteRefunded = quoteDust;
            }
        }

        _requireBalance(wbnbToken, wbnbBalanceBaseline);
        if (quoteToken != address(wbnb)) _requireBalance(quote, quoteBalanceBaseline);
        if (address(this).balance != nativeBalanceBaseline) {
            revert ResidualBalance(address(0), nativeBalanceBaseline, address(this).balance);
        }

        result = DevBuyResult({
            nativeAmountIn: params.nativeAmountIn,
            quoteAmountOut: quoteAmountOut,
            quoteAmountSpent: quoteAmountSpent,
            tokenAmountOut: tokenAmountOut,
            wbnbRefundedAsNative: wbnbRefundedAsNative,
            quoteRefunded: quoteRefunded
        });
        emit NativeDeveloperBuy(
            params.beneficiary,
            quoteToken,
            launchedToken,
            params.nativeAmountIn,
            quoteAmountOut,
            quoteAmountSpent,
            tokenAmountOut,
            wbnbRefundedAsNative,
            quoteRefunded
        );
    }

    function _validate(
        address launchedToken,
        address quoteToken,
        uint24 launchFeeTier,
        uint256 launchDeadline,
        DevBuyParams calldata params
    ) private view {
        if (
            launchedToken == address(0) || launchedToken.code.length == 0
                || quoteToken == address(0) || quoteToken.code.length == 0
                || launchedToken == quoteToken || params.nativeAmountIn == 0
                || params.minQuoteOut == 0 || params.minTokenOut == 0
                || params.beneficiary == address(0) || params.beneficiary == address(this)
        ) revert InvalidDevBuy();
        if (params.deadline < block.timestamp || params.deadline > launchDeadline) {
            revert DeadlineExpired();
        }
        _requireInitializedPool(quoteToken, launchedToken, launchFeeTier, address(0));

        if (quoteToken == address(wbnb)) {
            if (
                params.quoteFeeTier != 0 || params.expectedQuotePool != address(0)
                    || params.quoteSqrtPriceLimitX96 != 0
            ) revert InvalidDevBuy();
        } else {
            if (params.expectedQuotePool == address(0)) revert InvalidDevBuy();
            if (pancakeFactory.feeAmountTickSpacing(params.quoteFeeTier) <= 0) {
                revert UnsupportedFeeTier(params.quoteFeeTier);
            }
            _requireInitializedPool(
                address(wbnb), quoteToken, params.quoteFeeTier, params.expectedQuotePool
            );
        }
    }

    function _requireInitializedPool(
        address tokenA,
        address tokenB,
        uint24 feeTier,
        address expectedPool
    ) private view returns (address pool) {
        pool = pancakeFactory.getPool(tokenA, tokenB, feeTier);
        if (
            pool == address(0) || pool.code.length == 0
                || (expectedPool != address(0) && pool != expectedPool)
        ) revert QuotePoolMismatch(expectedPool, pool);
        (uint160 sqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(pool);
    }

    function _refundWbnb(address recipient, uint256 amount) private returns (uint256) {
        if (amount == 0) return 0;
        uint256 beforeBalance = address(this).balance;
        wbnb.withdraw(amount);
        if (address(this).balance != beforeBalance + amount) revert NativeTransferFailed();
        (bool ok,) = payable(recipient).call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
        return amount;
    }

    function _requireBalance(IERC20 token, uint256 expected) private view {
        uint256 actual = token.balanceOf(address(this));
        if (actual != expected) revert ResidualBalance(address(token), expected, actual);
    }
}
