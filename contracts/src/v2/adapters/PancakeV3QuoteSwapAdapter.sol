// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { PancakeV3AdapterBase } from "./PancakeV3AdapterBase.sol";
import {
    IPancakeV3FactoryLike,
    IPancakeV3SwapRouterLike
} from "./interfaces/IPancakeV3AdapterTypes.sol";
import { INativeQuoteSwapAdapter } from "../native/INativeDevBuyAdapters.sol";

contract PancakeV3QuoteSwapAdapter is PancakeV3AdapterBase, INativeQuoteSwapAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant QUOTE_ROUTE_DOMAIN = keccak256("QUOTE.PancakeV3QuoteRoute.v1");

    struct QuoteRouteConfig {
        address quoteToken;
        address refStable;
        uint24 firstFee;
        uint24 secondFee;
    }

    struct QuoteRoute {
        address quoteToken;
        address refStable;
        uint24 firstFee;
        uint24 secondFee;
        bool enabled;
    }

    address public immutable wbnb;
    mapping(address stableRef => bool allowed) public isStableRefAllowed;
    mapping(bytes32 routeId => QuoteRoute route) public quoteRoutes;

    error BadQuoteRoute();
    error UnsupportedStableRef(address stableRef);
    error QuoteRouteDisabled(bytes32 routeId);

    event QuoteRouteRegistered(
        bytes32 indexed routeId,
        address indexed quote,
        address indexed refStable,
        uint24 firstFee,
        uint24 secondFee
    );
    event QuoteSwapped(
        address indexed quote,
        address indexed refStable,
        uint24 firstFee,
        uint24 secondFee,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        address coordinator_,
        address registrar_,
        IPancakeV3SwapRouterLike pancakeV3Router_,
        IPancakeV3FactoryLike pancakeV3Factory_,
        address wbnb_,
        address[] memory stableRefs_,
        uint24[] memory allowedFeeTiers_,
        QuoteRouteConfig[] memory quoteRoutes_
    )
        PancakeV3AdapterBase(
            coordinator_, registrar_, pancakeV3Router_, pancakeV3Factory_, allowedFeeTiers_
        )
    {
        if (wbnb_ == address(0) || wbnb_.code.length == 0) revert BadAdapterConfiguration();
        wbnb = wbnb_;

        for (uint256 i; i < stableRefs_.length; ++i) {
            address stableRef = stableRefs_[i];
            if (stableRef == address(0) || stableRef == wbnb_ || stableRef.code.length == 0) {
                revert BadAdapterConfiguration();
            }
            isStableRefAllowed[stableRef] = true;
        }

        for (uint256 i; i < quoteRoutes_.length; ++i) {
            _registerQuoteRoute(quoteRoutes_[i]);
        }
    }

    function registerQuoteRoute(QuoteRouteConfig calldata config)
        external
        onlyRegistrar
        returns (bytes32 routeId)
    {
        return _registerQuoteRoute(config);
    }

    function isRouteEnabled(bytes32 routeId, address requestedWbnb, address quoteToken)
        external
        view
        returns (bool)
    {
        QuoteRoute memory route = quoteRoutes[routeId];
        if (!route.enabled || requestedWbnb != wbnb || route.quoteToken != quoteToken) {
            return false;
        }
        if (route.refStable == address(0)) return _poolExists(wbnb, quoteToken, route.firstFee);
        return _poolExists(wbnb, route.refStable, route.firstFee)
            && _poolExists(route.refStable, quoteToken, route.secondFee);
    }

    function swapExactWbnbForQuote(SwapExactWbnbForQuoteParams calldata params)
        external
        onlyCoordinator
        nonReentrant
        returns (uint256 amountOut)
    {
        _validateDeadlineAndAmounts(params.amountIn, params.minAmountOut, params.deadline);
        if (
            params.wbnb != wbnb || params.quoteToken == address(0) || params.quoteToken == wbnb
                || params.quoteToken.code.length == 0 || params.recipient == address(0)
                || params.recipient == address(this)
        ) revert BadQuoteRoute();

        QuoteRoute memory route = quoteRoutes[params.routeId];
        if (!route.enabled || route.quoteToken != params.quoteToken) {
            revert QuoteRouteDisabled(params.routeId);
        }

        bool direct = route.refStable == address(0);
        if (direct) {
            _requirePool(wbnb, params.quoteToken, route.firstFee);
            return _swapDirect(params, route.firstFee);
        } else {
            _requirePool(wbnb, route.refStable, route.firstFee);
            _requirePool(route.refStable, params.quoteToken, route.secondFee);
            return _swapViaStable(params, route);
        }
    }

    function quoteRouteId(address quoteToken, address refStable, uint24 firstFee, uint24 secondFee)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                QUOTE_ROUTE_DOMAIN,
                block.chainid,
                address(pancakeV3Router),
                wbnb,
                quoteToken,
                refStable,
                firstFee,
                secondFee
            )
        );
    }

    function _swapDirect(SwapExactWbnbForQuoteParams calldata params, uint24 fee)
        private
        returns (uint256 amountOut)
    {
        IERC20 input = IERC20(wbnb);
        IERC20 output = IERC20(params.quoteToken);
        uint256 inputBalanceBefore = input.balanceOf(address(this));
        uint256 outputBalanceBefore = output.balanceOf(address(this));
        uint256 recipientOutputBefore = output.balanceOf(params.recipient);

        _pullExact(input, params.amountIn);
        input.forceApprove(address(pancakeV3Router), params.amountIn);
        pancakeV3Router.exactInputSingle(
            IPancakeV3SwapRouterLike.ExactInputSingleParams({
                tokenIn: wbnb,
                tokenOut: params.quoteToken,
                fee: fee,
                recipient: address(this),
                deadline: params.deadline,
                amountIn: params.amountIn,
                amountOutMinimum: params.minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        input.forceApprove(address(pancakeV3Router), 0);

        amountOut = _settleOutput(
            input,
            output,
            inputBalanceBefore,
            outputBalanceBefore,
            params.recipient,
            recipientOutputBefore,
            params.minAmountOut
        );

        emit QuoteSwapped(params.quoteToken, address(0), fee, 0, params.amountIn, amountOut);
    }

    function _swapViaStable(SwapExactWbnbForQuoteParams calldata params, QuoteRoute memory route)
        private
        returns (uint256 amountOut)
    {
        IERC20 input = IERC20(wbnb);
        IERC20 output = IERC20(params.quoteToken);
        uint256 inputBalanceBefore = input.balanceOf(address(this));
        uint256 outputBalanceBefore = output.balanceOf(address(this));
        uint256 recipientOutputBefore = output.balanceOf(params.recipient);
        uint256 stableBalanceBefore = IERC20(route.refStable).balanceOf(address(this));

        _pullExact(input, params.amountIn);
        input.forceApprove(address(pancakeV3Router), params.amountIn);
        pancakeV3Router.exactInput(
            IPancakeV3SwapRouterLike.ExactInputParams({
                path: abi.encodePacked(
                    wbnb, route.firstFee, route.refStable, route.secondFee, params.quoteToken
                ),
                recipient: address(this),
                deadline: params.deadline,
                amountIn: params.amountIn,
                amountOutMinimum: params.minAmountOut
            })
        );
        input.forceApprove(address(pancakeV3Router), 0);

        amountOut = _settleOutput(
            input,
            output,
            inputBalanceBefore,
            outputBalanceBefore,
            params.recipient,
            recipientOutputBefore,
            params.minAmountOut
        );
        _restoreBalance(IERC20(route.refStable), stableBalanceBefore);

        emit QuoteSwapped(
            params.quoteToken,
            route.refStable,
            route.firstFee,
            route.secondFee,
            params.amountIn,
            amountOut
        );
    }

    function _settleOutput(
        IERC20 input,
        IERC20 output,
        uint256 inputBalanceBefore,
        uint256 outputBalanceBefore,
        address recipient,
        uint256 recipientOutputBefore,
        uint256 minAmountOut
    ) private returns (uint256 amountOut) {
        uint256 grossOutput =
            output.balanceOf(address(this)) - outputBalanceBefore;
        if (grossOutput != 0) output.safeTransfer(recipient, grossOutput);
        amountOut = output.balanceOf(recipient) - recipientOutputBefore;
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);

        _restoreBalance(input, inputBalanceBefore);
        _restoreBalance(output, outputBalanceBefore);
    }

    function _registerQuoteRoute(QuoteRouteConfig memory config) private returns (bytes32 routeId) {
        _validateQuoteRoute(config);
        routeId =
            quoteRouteId(config.quoteToken, config.refStable, config.firstFee, config.secondFee);
        if (routeId == bytes32(0)) revert BadQuoteRoute();
        if (quoteRoutes[routeId].enabled) revert AlreadyRegistered(routeId);
        quoteRoutes[routeId] = QuoteRoute({
            quoteToken: config.quoteToken,
            refStable: config.refStable,
            firstFee: config.firstFee,
            secondFee: config.secondFee,
            enabled: true
        });
        emit QuoteRouteRegistered(
            routeId, config.quoteToken, config.refStable, config.firstFee, config.secondFee
        );
    }

    function _validateQuoteRoute(QuoteRouteConfig memory config) private view {
        if (
            config.quoteToken == address(0) || config.quoteToken == wbnb
                || config.quoteToken.code.length == 0
        ) revert BadQuoteRoute();
        _requireAllowedFee(config.firstFee);

        if (config.refStable == address(0)) {
            if (config.secondFee != 0) revert BadQuoteRoute();
            _requirePool(wbnb, config.quoteToken, config.firstFee);
            return;
        }

        if (
            config.refStable == config.quoteToken || config.refStable.code.length == 0
                || config.secondFee == 0
        ) revert BadQuoteRoute();
        if (!isStableRefAllowed[config.refStable]) {
            revert UnsupportedStableRef(config.refStable);
        }
        _requireAllowedFee(config.secondFee);
        _requirePool(wbnb, config.refStable, config.firstFee);
        _requirePool(config.refStable, config.quoteToken, config.secondFee);
    }
}
