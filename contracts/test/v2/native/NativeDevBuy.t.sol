// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { NativeDevBuy } from "../../../src/v2/native/NativeDevBuy.sol";
import {
    ILaunchPoolBuyAdapter,
    INativeQuoteSwapAdapter,
    IWBNB
} from "../../../src/v2/native/INativeDevBuyAdapters.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Taxed Quote", "TAX") { }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / 10;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract MockWBNB is ERC20, IWBNB {
    constructor() ERC20("Wrapped BNB", "WBNB") { }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount }("");
        require(ok, "WBNB_SEND_FAILED");
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockQuoteSwapAdapter is INativeQuoteSwapAdapter {
    using SafeERC20 for IERC20;

    struct Route {
        address wbnb;
        address quoteToken;
        bool enabled;
        uint256 numerator;
        uint256 denominator;
        uint256 wbnbSpendBps;
    }

    error MissingRoute();
    error Expired();

    mapping(bytes32 routeId => Route route) public routes;
    uint256 public calls;

    function setRoute(
        bytes32 routeId,
        address wbnb,
        address quoteToken,
        bool enabled,
        uint256 numerator,
        uint256 denominator,
        uint256 wbnbSpendBps
    ) external {
        routes[routeId] = Route({
            wbnb: wbnb,
            quoteToken: quoteToken,
            enabled: enabled,
            numerator: numerator,
            denominator: denominator,
            wbnbSpendBps: wbnbSpendBps
        });
    }

    function isRouteEnabled(bytes32 routeId, address wbnb, address quoteToken)
        external
        view
        returns (bool)
    {
        Route memory route = routes[routeId];
        return route.enabled && route.wbnb == wbnb && route.quoteToken == quoteToken;
    }

    function swapExactWbnbForQuote(SwapExactWbnbForQuoteParams calldata params)
        external
        returns (uint256 amountOut)
    {
        if (params.deadline < block.timestamp) revert Expired();

        Route memory route = routes[params.routeId];
        if (!route.enabled || route.wbnb != params.wbnb || route.quoteToken != params.quoteToken) {
            revert MissingRoute();
        }

        calls++;
        uint256 wbnbToSpend = (params.amountIn * route.wbnbSpendBps) / 10_000;
        IERC20(params.wbnb).safeTransferFrom(msg.sender, address(this), wbnbToSpend);

        amountOut = (params.amountIn * route.numerator) / route.denominator;
        IMintableERC20(params.quoteToken).mint(address(this), amountOut);
        IERC20(params.quoteToken).safeTransfer(params.recipient, amountOut);
    }
}

contract MockLaunchPoolBuyAdapter is ILaunchPoolBuyAdapter {
    using SafeERC20 for IERC20;

    struct PoolRoute {
        address launchedToken;
        address quoteToken;
        bool enabled;
        uint256 quoteToSpend;
        uint256 tokenNumerator;
        uint256 tokenDenominator;
    }

    error MissingPoolRoute();
    error Expired();

    mapping(bytes32 poolId => PoolRoute route) public poolRoutes;
    NativeDevBuy public reenterTarget;
    NativeDevBuy.DevBuyParams private _reenterParams;
    bool public shouldReenter;
    uint256 public calls;

    function setPoolRoute(
        bytes32 poolId,
        address launchedToken,
        address quoteToken,
        bool enabled,
        uint256 quoteToSpend,
        uint256 tokenNumerator,
        uint256 tokenDenominator
    ) external {
        poolRoutes[poolId] = PoolRoute({
            launchedToken: launchedToken,
            quoteToken: quoteToken,
            enabled: enabled,
            quoteToSpend: quoteToSpend,
            tokenNumerator: tokenNumerator,
            tokenDenominator: tokenDenominator
        });
    }

    function setReentry(NativeDevBuy target, NativeDevBuy.DevBuyParams calldata params) external {
        reenterTarget = target;
        _reenterParams = params;
        shouldReenter = true;
    }

    function callDevBuy(NativeDevBuy target, NativeDevBuy.DevBuyParams calldata params)
        external
        payable
        returns (NativeDevBuy.DevBuyResult memory)
    {
        return target.buy{ value: msg.value }(params);
    }

    function isPoolEnabled(bytes32 poolId, address launchedToken, address quoteToken)
        external
        view
        returns (bool)
    {
        PoolRoute memory route = poolRoutes[poolId];
        return
            route.enabled && route.launchedToken == launchedToken && route.quoteToken == quoteToken;
    }

    function buyWithQuote(BuyWithQuoteParams calldata params)
        external
        returns (uint256 quoteAmountIn, uint256 tokenAmountOut)
    {
        if (params.deadline < block.timestamp) revert Expired();

        PoolRoute memory route = poolRoutes[params.poolId];
        if (
            !route.enabled || route.launchedToken != params.launchedToken
                || route.quoteToken != params.quoteToken
        ) revert MissingPoolRoute();

        calls++;
        if (shouldReenter) {
            shouldReenter = false;
            reenterTarget.buy(_reenterParams);
        }

        quoteAmountIn = route.quoteToSpend;
        if (quoteAmountIn == type(uint256).max) quoteAmountIn = params.maxQuoteAmountIn;

        uint256 quoteBalanceBefore = IERC20(params.quoteToken).balanceOf(address(this));
        IERC20(params.quoteToken).safeTransferFrom(msg.sender, address(this), quoteAmountIn);
        uint256 quoteReceived =
            IERC20(params.quoteToken).balanceOf(address(this)) - quoteBalanceBefore;

        tokenAmountOut = (quoteReceived * route.tokenNumerator) / route.tokenDenominator;
        IMintableERC20(params.launchedToken).mint(msg.sender, tokenAmountOut);
    }
}

contract NativeDevBuyTest is Test {
    uint256 internal constant ONE_BNB = 1 ether;
    uint256 internal constant FULL_SPEND = type(uint256).max;
    bytes32 internal constant QUOTE_ROUTE_ID = keccak256("quote-route");
    bytes32 internal constant POOL_ID = keccak256("launch-pool");

    address internal launchpad = makeAddr("launchpad");
    address internal beneficiary = makeAddr("beneficiary");
    address internal attacker = makeAddr("attacker");

    MockWBNB internal wbnb;
    MockERC20 internal quote;
    MockERC20 internal launchedToken;
    MockQuoteSwapAdapter internal quoteAdapter;
    MockLaunchPoolBuyAdapter internal poolAdapter;
    NativeDevBuy internal devBuy;

    function setUp() external {
        wbnb = new MockWBNB();
        quote = new MockERC20("Quote", "QUOTE");
        launchedToken = new MockERC20("Launch", "LAUNCH");
        quoteAdapter = new MockQuoteSwapAdapter();
        poolAdapter = new MockLaunchPoolBuyAdapter();
        devBuy = new NativeDevBuy(launchpad, IWBNB(address(wbnb)), quoteAdapter, poolAdapter);

        quoteAdapter.setRoute(QUOTE_ROUTE_ID, address(wbnb), address(quote), true, 2, 1, 10_000);
        poolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(quote), true, FULL_SPEND, 1, 1
        );

        vm.deal(launchpad, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    function testConvertsBnbToQuoteAndBuysForBeneficiary() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);

        vm.prank(launchpad);
        NativeDevBuy.DevBuyResult memory result = devBuy.buy{ value: ONE_BNB }(params);

        assertEq(result.nativeAmountIn, ONE_BNB);
        assertEq(result.quoteAmountOut, 2 ether);
        assertEq(result.quoteAmountSpent, 2 ether);
        assertEq(result.tokenAmountOut, 2 ether);
        assertEq(result.wbnbRefundedAsNative, 0);
        assertEq(result.quoteRefunded, 0);
        assertEq(quoteAdapter.calls(), 1);
        assertEq(poolAdapter.calls(), 1);
        assertEq(launchedToken.balanceOf(beneficiary), 2 ether);
        assertEq(wbnb.balanceOf(address(devBuy)), 0);
        assertEq(quote.balanceOf(address(devBuy)), 0);
        assertEq(launchedToken.balanceOf(address(devBuy)), 0);
        assertEq(wbnb.allowance(address(devBuy), address(quoteAdapter)), 0);
        assertEq(quote.allowance(address(devBuy), address(poolAdapter)), 0);
    }

    function testSkipsQuoteSwapWhenQuoteIsWbnb() external {
        poolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(wbnb), true, FULL_SPEND, 1, 1
        );
        NativeDevBuy.DevBuyParams memory params = _params(address(wbnb), bytes32(0));

        vm.prank(launchpad);
        NativeDevBuy.DevBuyResult memory result = devBuy.buy{ value: ONE_BNB }(params);

        assertEq(result.quoteAmountOut, ONE_BNB);
        assertEq(result.quoteAmountSpent, ONE_BNB);
        assertEq(result.tokenAmountOut, ONE_BNB);
        assertEq(quoteAdapter.calls(), 0);
        assertEq(launchedToken.balanceOf(beneficiary), ONE_BNB);
        assertEq(wbnb.balanceOf(address(devBuy)), 0);
        assertEq(wbnb.allowance(address(devBuy), address(poolAdapter)), 0);
    }

    function testRejectsUnauthorizedCaller() external {
        vm.prank(attacker);
        vm.expectRevert(NativeDevBuy.NotLaunchpad.selector);
        devBuy.buy{ value: ONE_BNB }(_params(address(quote), QUOTE_ROUTE_ID));
    }

    function testRejectsExpiredDeadline() external {
        vm.warp(100);
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.deadline = 99;

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.DeadlineExpired.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsZeroBeneficiary() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.beneficiary = address(0);

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.BadBeneficiary.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsUnderfundedNativeAmount() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.BadNativeAmount.selector);
        devBuy.buy{ value: ONE_BNB - 1 }(params);
    }

    function testRejectsTooHighNativeAmount() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.BadNativeAmount.selector);
        devBuy.buy{ value: ONE_BNB + 1 }(params);
    }

    function testRejectsMissingQuoteRoute() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), keccak256("missing"));

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.QuoteRouteDisabled.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsDisabledQuoteRoute() external {
        bytes32 disabledRouteId = keccak256("disabled");
        quoteAdapter.setRoute(disabledRouteId, address(wbnb), address(quote), false, 2, 1, 10_000);
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), disabledRouteId);

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.QuoteRouteDisabled.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsRouteBoundToDifferentQuote() external {
        MockERC20 otherQuote = new MockERC20("Other Quote", "OTHER");
        NativeDevBuy.DevBuyParams memory params = _params(address(otherQuote), QUOTE_ROUTE_ID);
        poolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(otherQuote), true, FULL_SPEND, 1, 1
        );

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.QuoteRouteDisabled.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsMissingLaunchPoolRoute() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.launchPoolId = keccak256("missing-pool");

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.LaunchPoolDisabled.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsDisabledLaunchPoolRoute() external {
        bytes32 disabledPoolId = keccak256("disabled-pool");
        poolAdapter.setPoolRoute(
            disabledPoolId, address(launchedToken), address(quote), false, FULL_SPEND, 1, 1
        );
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.launchPoolId = disabledPoolId;

        vm.prank(launchpad);
        vm.expectRevert(NativeDevBuy.LaunchPoolDisabled.selector);
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsQuoteSlippage() external {
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.minQuoteOut = 3 ether;

        vm.prank(launchpad);
        vm.expectRevert(
            abi.encodeWithSelector(NativeDevBuy.QuoteSlippage.selector, 2 ether, 3 ether)
        );
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testRejectsTokenSlippage() external {
        poolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(quote), true, FULL_SPEND, 1, 2
        );
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.minTokenOut = 2 ether;

        vm.prank(launchpad);
        vm.expectRevert(
            abi.encodeWithSelector(NativeDevBuy.TokenSlippage.selector, 1 ether, 2 ether)
        );
        devBuy.buy{ value: ONE_BNB }(params);
    }

    function testFeeOnTransferQuoteUsesNetBalanceDelta() external {
        FeeOnTransferERC20 taxedQuote = new FeeOnTransferERC20();
        bytes32 taxedRouteId = keccak256("taxed-route");
        bytes32 taxedPoolId = keccak256("taxed-pool");
        quoteAdapter.setRoute(taxedRouteId, address(wbnb), address(taxedQuote), true, 1, 1, 10_000);
        poolAdapter.setPoolRoute(
            taxedPoolId, address(launchedToken), address(taxedQuote), true, FULL_SPEND, 1, 1
        );

        NativeDevBuy.DevBuyParams memory params = _params(address(taxedQuote), taxedRouteId);
        params.launchPoolId = taxedPoolId;
        params.minQuoteOut = 0.9 ether;
        params.minTokenOut = 0.81 ether;

        vm.prank(launchpad);
        NativeDevBuy.DevBuyResult memory result = devBuy.buy{ value: ONE_BNB }(params);

        assertEq(result.quoteAmountOut, 0.9 ether);
        assertEq(result.quoteAmountSpent, 0.9 ether);
        assertEq(result.tokenAmountOut, 0.81 ether);
        assertEq(launchedToken.balanceOf(beneficiary), 0.81 ether);
        assertEq(taxedQuote.balanceOf(address(devBuy)), 0);
    }

    function testRefundsUnspentWbnbDustOnly() external {
        poolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(wbnb), true, 0.4 ether, 1, 1
        );
        NativeDevBuy.DevBuyParams memory params = _params(address(wbnb), bytes32(0));
        params.minTokenOut = 0.4 ether;

        vm.prank(launchpad);
        NativeDevBuy.DevBuyResult memory result = devBuy.buy{ value: ONE_BNB }(params);

        assertEq(result.quoteAmountOut, ONE_BNB);
        assertEq(result.quoteAmountSpent, 0.4 ether);
        assertEq(result.tokenAmountOut, 0.4 ether);
        assertEq(result.wbnbRefundedAsNative, 0.6 ether);
        assertEq(result.quoteRefunded, 0);
        assertEq(beneficiary.balance, 0.6 ether);
        assertEq(launchedToken.balanceOf(beneficiary), 0.4 ether);
        assertEq(wbnb.balanceOf(address(devBuy)), 0);
        assertEq(address(devBuy).balance, 0);
    }

    function testRefundsUnspentConvertedQuoteDust() external {
        poolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(quote), true, 1.5 ether, 1, 1
        );
        NativeDevBuy.DevBuyParams memory params = _params(address(quote), QUOTE_ROUTE_ID);
        params.minTokenOut = 1.5 ether;

        vm.prank(launchpad);
        NativeDevBuy.DevBuyResult memory result = devBuy.buy{ value: ONE_BNB }(params);

        assertEq(result.quoteAmountOut, 2 ether);
        assertEq(result.quoteAmountSpent, 1.5 ether);
        assertEq(result.quoteRefunded, 0.5 ether);
        assertEq(quote.balanceOf(beneficiary), 0.5 ether);
        assertEq(quote.balanceOf(address(devBuy)), 0);
    }

    function testReentrancyGuardBlocksLaunchpadReentry() external {
        MockLaunchPoolBuyAdapter reentrantPoolAdapter = new MockLaunchPoolBuyAdapter();
        NativeDevBuy reentrantDevBuy = new NativeDevBuy(
            address(reentrantPoolAdapter), IWBNB(address(wbnb)), quoteAdapter, reentrantPoolAdapter
        );
        reentrantPoolAdapter.setPoolRoute(
            POOL_ID, address(launchedToken), address(wbnb), true, FULL_SPEND, 1, 1
        );
        NativeDevBuy.DevBuyParams memory params = _params(address(wbnb), bytes32(0));
        reentrantPoolAdapter.setReentry(reentrantDevBuy, params);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reentrantPoolAdapter.callDevBuy{ value: ONE_BNB }(reentrantDevBuy, params);
    }

    function _params(address quoteToken, bytes32 quoteRouteId)
        internal
        view
        returns (NativeDevBuy.DevBuyParams memory params)
    {
        params = NativeDevBuy.DevBuyParams({
            quoteRouteId: quoteRouteId,
            launchPoolId: POOL_ID,
            launchedToken: address(launchedToken),
            quoteToken: quoteToken,
            nativeAmountIn: ONE_BNB,
            minQuoteOut: quoteToken == address(wbnb) ? ONE_BNB : 2 ether,
            minTokenOut: quoteToken == address(wbnb) ? ONE_BNB : 2 ether,
            deadline: block.timestamp + 1 hours,
            beneficiary: beneficiary
        });
    }
}
