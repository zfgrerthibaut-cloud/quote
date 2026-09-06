// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface INativeQuoteSwapAdapter {
    struct SwapExactWbnbForQuoteParams {
        bytes32 routeId;
        address wbnb;
        address quoteToken;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        uint256 deadline;
    }

    /// @notice Returns true only for approved WBNB -> quote routes.
    /// @dev Production adapters should back this with the external quote attestation policy
    ///      (for example, >= $10k liquidity vs approved stable or WBNB). This helper only
    ///      consumes the typed route decision and does not duplicate oracle logic.
    function isRouteEnabled(bytes32 routeId, address wbnb, address quoteToken)
        external
        view
        returns (bool);

    function swapExactWbnbForQuote(SwapExactWbnbForQuoteParams calldata params)
        external
        returns (uint256 amountOut);
}

interface ILaunchPoolBuyAdapter {
    struct BuyWithQuoteParams {
        bytes32 poolId;
        address launchedToken;
        address quoteToken;
        uint256 maxQuoteAmountIn;
        uint256 minTokenAmountOut;
        uint256 deadline;
    }

    function isPoolEnabled(bytes32 poolId, address launchedToken, address quoteToken)
        external
        view
        returns (bool);

    function buyWithQuote(BuyWithQuoteParams calldata params)
        external
        returns (uint256 quoteAmountIn, uint256 tokenAmountOut);
}
