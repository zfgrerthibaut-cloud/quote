// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { ILaunchPoolBuyAdapter, INativeQuoteSwapAdapter, IWBNB } from "./INativeDevBuyAdapters.sol";

/// @notice Atomic native-BNB developer buy helper for v2 launch flows.
/// @dev The launchpad calls this after creating the launch pool. Route and pool validation
///      live in immutable typed adapters; no arbitrary target or calldata is accepted here.
contract NativeDevBuy is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable launchpad;
    IWBNB public immutable wbnb;
    INativeQuoteSwapAdapter public immutable quoteSwapAdapter;
    ILaunchPoolBuyAdapter public immutable launchPoolBuyAdapter;

    struct DevBuyParams {
        bytes32 quoteRouteId;
        bytes32 launchPoolId;
        address launchedToken;
        address quoteToken;
        uint256 nativeAmountIn;
        uint256 minQuoteOut;
        uint256 minTokenOut;
        uint256 deadline;
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
    error NotLaunchpad();
    error BadBeneficiary();
    error BadAsset();
    error BadNativeAmount();
    error DeadlineExpired();
    error QuoteRouteDisabled();
    error LaunchPoolDisabled();
    error NativeWrapFailed();
    error NativeTransferFailed();
    error BadBalanceDelta();
    error QuoteSlippage(uint256 amountOut, uint256 minAmountOut);
    error TokenSlippage(uint256 amountOut, uint256 minAmountOut);

    event NativeDeveloperBuy(
        address indexed launchpad,
        address indexed beneficiary,
        address indexed launchedToken,
        address quoteToken,
        bytes32 quoteRouteId,
        bytes32 launchPoolId,
        uint256 nativeAmountIn,
        uint256 quoteAmountOut,
        uint256 quoteAmountSpent,
        uint256 tokenAmountOut,
        uint256 wbnbRefundedAsNative,
        uint256 quoteRefunded
    );

    constructor(
        address launchpad_,
        IWBNB wbnb_,
        INativeQuoteSwapAdapter quoteSwapAdapter_,
        ILaunchPoolBuyAdapter launchPoolBuyAdapter_
    ) {
        if (
            launchpad_ == address(0) || address(wbnb_) == address(0)
                || address(quoteSwapAdapter_) == address(0)
                || address(launchPoolBuyAdapter_) == address(0) || address(wbnb_).code.length == 0
                || address(quoteSwapAdapter_).code.length == 0
                || address(launchPoolBuyAdapter_).code.length == 0
        ) revert BadDependencies();

        launchpad = launchpad_;
        wbnb = wbnb_;
        quoteSwapAdapter = quoteSwapAdapter_;
        launchPoolBuyAdapter = launchPoolBuyAdapter_;
    }

    receive() external payable {
        if (msg.sender != address(wbnb)) revert NativeTransferFailed();
    }

    function buy(DevBuyParams calldata params)
        external
        payable
        nonReentrant
        returns (DevBuyResult memory result)
    {
        if (msg.sender != launchpad) revert NotLaunchpad();
        _validateParams(params);
        bool needsQuoteSwap = params.quoteToken != address(wbnb);
        if (
            needsQuoteSwap
                && !quoteSwapAdapter.isRouteEnabled(
                    params.quoteRouteId, address(wbnb), params.quoteToken
                )
        ) {
            revert QuoteRouteDisabled();
        }
        if (!launchPoolBuyAdapter.isPoolEnabled(
                params.launchPoolId, params.launchedToken, params.quoteToken
            )) {
            revert LaunchPoolDisabled();
        }

        address wbnbAddress = address(wbnb);
        IERC20 wbnbToken = IERC20(wbnbAddress);
        IERC20 quoteToken = IERC20(params.quoteToken);

        uint256 wbnbBalanceBefore = wbnbToken.balanceOf(address(this));
        uint256 quoteBalanceBefore = quoteToken.balanceOf(address(this));

        wbnb.deposit{ value: params.nativeAmountIn }();
        uint256 wrappedAmount = wbnbToken.balanceOf(address(this)) - wbnbBalanceBefore;
        if (wrappedAmount != params.nativeAmountIn) revert NativeWrapFailed();

        uint256 wbnbRefundedAsNative;
        uint256 quoteAmountOut;
        if (!needsQuoteSwap) {
            quoteAmountOut = wrappedAmount;
        } else {
            wbnbToken.forceApprove(address(quoteSwapAdapter), wrappedAmount);
            quoteSwapAdapter.swapExactWbnbForQuote(
                INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams({
                    routeId: params.quoteRouteId,
                    wbnb: wbnbAddress,
                    quoteToken: params.quoteToken,
                    amountIn: wrappedAmount,
                    minAmountOut: params.minQuoteOut,
                    recipient: address(this),
                    deadline: params.deadline
                })
            );
            wbnbToken.forceApprove(address(quoteSwapAdapter), 0);

            quoteAmountOut = quoteToken.balanceOf(address(this)) - quoteBalanceBefore;
            uint256 unspentWbnb = wbnbToken.balanceOf(address(this)) - wbnbBalanceBefore;
            wbnbRefundedAsNative += _refundWbnbAsNative(params.beneficiary, unspentWbnb);
        }
        if (quoteAmountOut < params.minQuoteOut) {
            revert QuoteSlippage(quoteAmountOut, params.minQuoteOut);
        }

        IERC20 launchedToken = IERC20(params.launchedToken);
        uint256 tokenBalanceBefore = launchedToken.balanceOf(address(this));
        uint256 beneficiaryTokenBalanceBefore = launchedToken.balanceOf(params.beneficiary);
        uint256 quoteBalanceBeforeBuy = quoteToken.balanceOf(address(this));
        if (quoteBalanceBeforeBuy < quoteBalanceBefore + quoteAmountOut) revert BadBalanceDelta();

        quoteToken.forceApprove(address(launchPoolBuyAdapter), quoteAmountOut);
        launchPoolBuyAdapter.buyWithQuote(
            ILaunchPoolBuyAdapter.BuyWithQuoteParams({
                poolId: params.launchPoolId,
                launchedToken: params.launchedToken,
                quoteToken: params.quoteToken,
                maxQuoteAmountIn: quoteAmountOut,
                minTokenAmountOut: params.minTokenOut,
                deadline: params.deadline
            })
        );
        quoteToken.forceApprove(address(launchPoolBuyAdapter), 0);

        uint256 quoteBalanceAfterBuy = quoteToken.balanceOf(address(this));
        if (quoteBalanceAfterBuy > quoteBalanceBeforeBuy) revert BadBalanceDelta();
        uint256 quoteAmountSpent = quoteBalanceBeforeBuy - quoteBalanceAfterBuy;

        uint256 tokenReceived = launchedToken.balanceOf(address(this)) - tokenBalanceBefore;
        if (tokenReceived != 0) launchedToken.safeTransfer(params.beneficiary, tokenReceived);
        uint256 tokenAmountOut =
            launchedToken.balanceOf(params.beneficiary) - beneficiaryTokenBalanceBefore;
        if (tokenAmountOut < params.minTokenOut) {
            revert TokenSlippage(tokenAmountOut, params.minTokenOut);
        }

        uint256 quoteRefunded;
        if (quoteBalanceAfterBuy > quoteBalanceBefore) {
            uint256 quoteDust = quoteBalanceAfterBuy - quoteBalanceBefore;
            if (params.quoteToken == wbnbAddress) {
                wbnbRefundedAsNative += _refundWbnbAsNative(params.beneficiary, quoteDust);
            } else {
                quoteToken.safeTransfer(params.beneficiary, quoteDust);
                quoteRefunded = quoteDust;
            }
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
            launchpad,
            params.beneficiary,
            params.launchedToken,
            params.quoteToken,
            params.quoteRouteId,
            params.launchPoolId,
            params.nativeAmountIn,
            quoteAmountOut,
            quoteAmountSpent,
            tokenAmountOut,
            wbnbRefundedAsNative,
            quoteRefunded
        );
    }

    function _validateParams(DevBuyParams calldata params) private view {
        if (params.beneficiary == address(0)) revert BadBeneficiary();
        if (params.deadline < block.timestamp) revert DeadlineExpired();
        if (params.nativeAmountIn == 0 || msg.value != params.nativeAmountIn) {
            revert BadNativeAmount();
        }
        if (
            params.launchPoolId == bytes32(0) || params.launchedToken == address(0)
                || params.quoteToken == address(0) || params.launchedToken == params.quoteToken
                || params.launchedToken.code.length == 0 || params.quoteToken.code.length == 0
        ) revert BadAsset();
    }

    function _refundWbnbAsNative(address recipient, uint256 amount)
        private
        returns (uint256 refunded)
    {
        if (amount == 0) return 0;

        uint256 nativeBalanceBefore = address(this).balance;
        wbnb.withdraw(amount);
        if (address(this).balance != nativeBalanceBefore + amount) revert NativeTransferFailed();
        return _sendNative(recipient, amount);
    }

    function _sendNative(address recipient, uint256 amount) private returns (uint256 refunded) {
        if (amount == 0) return 0;

        (bool ok,) = payable(recipient).call{ value: amount }("");
        if (!ok) revert NativeTransferFailed();
        return amount;
    }
}
