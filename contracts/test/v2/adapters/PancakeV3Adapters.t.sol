// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import { PancakeV3AdapterBase } from "../../../src/v2/adapters/PancakeV3AdapterBase.sol";
import {
    PancakeV3LaunchPoolBuyAdapter
} from "../../../src/v2/adapters/PancakeV3LaunchPoolBuyAdapter.sol";
import { PancakeV3QuoteSwapAdapter } from "../../../src/v2/adapters/PancakeV3QuoteSwapAdapter.sol";
import {
    IPancakeV3FactoryLike,
    IPancakeV3SwapRouterLike
} from "../../../src/v2/adapters/interfaces/IPancakeV3AdapterTypes.sol";
import { NativeDevBuy } from "../../../src/v2/native/NativeDevBuy.sol";
import {
    ILaunchPoolBuyAdapter,
    INativeQuoteSwapAdapter,
    IWBNB
} from "../../../src/v2/native/INativeDevBuyAdapters.sol";

contract V2AdapterERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract V2AdapterWBNB is V2AdapterERC20, IWBNB {
    constructor() V2AdapterERC20("Wrapped BNB", "WBNB") { }

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

contract V2AdapterTaxedERC20 is V2AdapterERC20 {
    constructor(string memory name_, string memory symbol_) V2AdapterERC20(name_, symbol_) { }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / 10;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}

contract V2MockPancakeV3Pool { }

contract V2MockPancakeV3Factory is IPancakeV3FactoryLike {
    mapping(bytes32 key => address pool) public pools;
    mapping(uint24 fee => int24 tickSpacing) public feeSpacings;

    function setFeeTier(uint24 fee, int24 tickSpacing) external {
        feeSpacings[fee] = tickSpacing;
    }

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function feeAmountTickSpacing(uint24 fee) external view returns (int24) {
        return feeSpacings[fee];
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract V2MockPancakeV3Router is IPancakeV3SwapRouterLike {
    using SafeERC20 for IERC20;

    bool public lastUsedExactInputSingle;
    bool public lastUsedExactInput;
    address public lastTokenIn;
    address public lastTokenOut;
    address public lastRecipient;
    uint24 public lastFee;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;
    bytes public lastPath;

    uint256 public nextGrossOutput;
    uint256 public nextReturnOutput;

    function setNextOutput(uint256 grossOutput, uint256 returnOutput) external {
        nextGrossOutput = grossOutput;
        nextReturnOutput = returnOutput;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(params.deadline >= block.timestamp, "expired");
        lastUsedExactInputSingle = true;
        lastUsedExactInput = false;
        lastTokenIn = params.tokenIn;
        lastTokenOut = params.tokenOut;
        lastRecipient = params.recipient;
        lastFee = params.fee;
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;
        delete lastPath;

        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        uint256 grossOutput = nextGrossOutput == 0 ? params.amountIn : nextGrossOutput;
        require(grossOutput >= params.amountOutMinimum, "router min");
        V2AdapterERC20(params.tokenOut).mint(params.recipient, grossOutput);

        amountOut = nextReturnOutput == 0 ? grossOutput : nextReturnOutput;
        nextGrossOutput = 0;
        nextReturnOutput = 0;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(params.deadline >= block.timestamp, "expired");
        require(params.path.length == 66, "path");
        lastUsedExactInputSingle = false;
        lastUsedExactInput = true;
        lastPath = params.path;
        lastTokenIn = _pathAddress(params.path, 0);
        lastTokenOut = _pathAddress(params.path, 46);
        lastRecipient = params.recipient;
        lastFee = _pathFee(params.path, 20);
        lastAmountIn = params.amountIn;
        lastAmountOutMinimum = params.amountOutMinimum;

        IERC20(lastTokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        uint256 grossOutput = nextGrossOutput == 0 ? params.amountIn : nextGrossOutput;
        require(grossOutput >= params.amountOutMinimum, "router min");
        V2AdapterERC20(lastTokenOut).mint(params.recipient, grossOutput);

        amountOut = nextReturnOutput == 0 ? grossOutput : nextReturnOutput;
        nextGrossOutput = 0;
        nextReturnOutput = 0;
    }

    function _pathAddress(bytes calldata path, uint256 offset)
        private
        pure
        returns (address token)
    {
        assembly {
            token := shr(96, calldataload(add(path.offset, offset)))
        }
    }

    function _pathFee(bytes calldata path, uint256 offset) private pure returns (uint24 fee) {
        assembly {
            fee := shr(232, calldataload(add(path.offset, offset)))
        }
    }
}

contract PancakeV3AdaptersTest is Test {
    uint24 internal constant FEE_LOW = 100;
    uint24 internal constant FEE_MEDIUM = 500;
    uint24 internal constant FEE_STABLE = 2_500;

    address internal beneficiary = makeAddr("beneficiary");
    address internal attacker = makeAddr("attacker");

    V2AdapterWBNB internal wbnb;
    V2AdapterERC20 internal stable;
    V2AdapterERC20 internal quote;
    V2AdapterERC20 internal launchedToken;
    V2MockPancakeV3Factory internal factory;
    V2MockPancakeV3Router internal router;
    PancakeV3QuoteSwapAdapter internal quoteAdapter;
    PancakeV3LaunchPoolBuyAdapter internal launchAdapter;

    address internal directPool;
    address internal wbnbStablePool;
    address internal stableQuotePool;
    address internal launchPool;
    bytes32 internal directRouteId;
    bytes32 internal viaStableRouteId;
    bytes32 internal launchPoolId;

    function setUp() external {
        wbnb = new V2AdapterWBNB();
        stable = new V2AdapterERC20("Stable", "USD");
        quote = new V2AdapterERC20("Quote", "QUOTE");
        launchedToken = new V2AdapterERC20("Launched", "LAUNCHED");
        factory = new V2MockPancakeV3Factory();
        router = new V2MockPancakeV3Router();

        factory.setFeeTier(FEE_LOW, 1);
        factory.setFeeTier(FEE_MEDIUM, 10);
        factory.setFeeTier(FEE_STABLE, 50);

        directPool = address(new V2MockPancakeV3Pool());
        wbnbStablePool = address(new V2MockPancakeV3Pool());
        stableQuotePool = address(new V2MockPancakeV3Pool());
        launchPool = address(new V2MockPancakeV3Pool());
        factory.setPool(address(wbnb), address(quote), FEE_MEDIUM, directPool);
        factory.setPool(address(wbnb), address(stable), FEE_MEDIUM, wbnbStablePool);
        factory.setPool(address(stable), address(quote), FEE_STABLE, stableQuotePool);
        factory.setPool(address(quote), address(launchedToken), FEE_LOW, launchPool);

        quoteAdapter = _deployStandardQuoteAdapter(address(this), address(this));
        launchAdapter = _deployStandardLaunchAdapter(address(this), address(this));
        directRouteId = quoteAdapter.quoteRouteId(address(quote), address(0), FEE_MEDIUM, 0);
        viaStableRouteId =
            quoteAdapter.quoteRouteId(address(quote), address(stable), FEE_MEDIUM, FEE_STABLE);
        launchPoolId =
            launchAdapter.launchPoolId(address(quote), address(launchedToken), FEE_LOW, launchPool);
    }

    function testDomainConstantsUseQuoteNamespace() external view {
        assertEq(quoteAdapter.QUOTE_ROUTE_DOMAIN(), keccak256("QUOTE.PancakeV3QuoteRoute.v1"));
        assertEq(launchAdapter.LAUNCH_POOL_DOMAIN(), keccak256("QUOTE.PancakeV3LaunchPool.v1"));
    }

    function testDirectQuoteSwapUsesExactInputSingleAndReturnsCoordinatorDelta() external {
        assertTrue(quoteAdapter.isRouteEnabled(directRouteId, address(wbnb), address(quote)));
        wbnb.mint(address(this), 1 ether);
        wbnb.approve(address(quoteAdapter), 1 ether);
        router.setNextOutput(750 ether, 123);

        uint256 amountOut = quoteAdapter.swapExactWbnbForQuote(_directQuoteSwap(1 ether, 700 ether));

        assertEq(amountOut, 750 ether);
        assertTrue(router.lastUsedExactInputSingle());
        assertFalse(router.lastUsedExactInput());
        assertEq(router.lastTokenIn(), address(wbnb));
        assertEq(router.lastTokenOut(), address(quote));
        assertEq(router.lastRecipient(), address(quoteAdapter));
        assertEq(router.lastFee(), FEE_MEDIUM);
        assertEq(router.lastAmountIn(), 1 ether);
        assertEq(router.lastAmountOutMinimum(), 700 ether);
        assertEq(wbnb.allowance(address(quoteAdapter), address(router)), 0);
        assertEq(wbnb.balanceOf(address(quoteAdapter)), 0);
        assertEq(quote.balanceOf(address(quoteAdapter)), 0);
        assertEq(quote.balanceOf(address(this)), 750 ether);
    }

    function testViaStableQuoteSwapUsesExactInputPathAndReturnsBalanceDelta() external {
        assertTrue(quoteAdapter.isRouteEnabled(viaStableRouteId, address(wbnb), address(quote)));
        wbnb.mint(address(this), 2 ether);
        wbnb.approve(address(quoteAdapter), 2 ether);
        router.setNextOutput(420 ether, 1);

        uint256 amountOut =
            quoteAdapter.swapExactWbnbForQuote(_viaStableQuoteSwap(2 ether, 400 ether));

        assertEq(amountOut, 420 ether);
        assertFalse(router.lastUsedExactInputSingle());
        assertTrue(router.lastUsedExactInput());
        assertEq(
            keccak256(router.lastPath()),
            keccak256(
                abi.encodePacked(
                    address(wbnb), FEE_MEDIUM, address(stable), FEE_STABLE, address(quote)
                )
            )
        );
        assertEq(router.lastRecipient(), address(quoteAdapter));
        assertEq(wbnb.allowance(address(quoteAdapter), address(router)), 0);
        assertEq(wbnb.balanceOf(address(quoteAdapter)), 0);
        assertEq(stable.balanceOf(address(quoteAdapter)), 0);
        assertEq(quote.balanceOf(address(quoteAdapter)), 0);
        assertEq(quote.balanceOf(address(this)), 420 ether);
    }

    function testQuoteSwapRejectsNonCoordinatorDisabledRouteAndMissingPool() external {
        vm.prank(attacker);
        vm.expectRevert(PancakeV3AdapterBase.NotCoordinator.selector);
        quoteAdapter.swapExactWbnbForQuote(_directQuoteSwap(1 ether, 1));

        INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams memory disabled =
            _directQuoteSwap(1 ether, 1);
        disabled.routeId = bytes32("disabled-route");
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3QuoteSwapAdapter.QuoteRouteDisabled.selector, disabled.routeId
            )
        );
        quoteAdapter.swapExactWbnbForQuote(disabled);

        factory.setPool(address(wbnb), address(quote), FEE_MEDIUM, address(0));
        assertFalse(quoteAdapter.isRouteEnabled(directRouteId, address(wbnb), address(quote)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3AdapterBase.PoolMissing.selector, address(wbnb), address(quote), FEE_MEDIUM
            )
        );
        quoteAdapter.swapExactWbnbForQuote(_directQuoteSwap(1 ether, 1));
    }

    function testQuoteRouteRegistrationIsRegistrarOnlyOneShotAndPoolChecked() external {
        V2AdapterERC20 otherQuote = new V2AdapterERC20("Other Quote", "OTHER");
        address otherPool = address(new V2MockPancakeV3Pool());
        factory.setPool(address(wbnb), address(otherQuote), FEE_MEDIUM, otherPool);
        PancakeV3QuoteSwapAdapter emptyAdapter =
            _deployEmptyQuoteAdapter(address(this), address(this));
        PancakeV3QuoteSwapAdapter.QuoteRouteConfig memory config =
            _directQuoteRoute(address(otherQuote));

        vm.prank(attacker);
        vm.expectRevert(PancakeV3AdapterBase.NotRegistrar.selector);
        emptyAdapter.registerQuoteRoute(config);

        bytes32 routeId = emptyAdapter.registerQuoteRoute(config);
        assertTrue(emptyAdapter.isRouteEnabled(routeId, address(wbnb), address(otherQuote)));

        vm.expectRevert(
            abi.encodeWithSelector(PancakeV3AdapterBase.AlreadyRegistered.selector, routeId)
        );
        emptyAdapter.registerQuoteRoute(config);

        V2AdapterERC20 missingPoolQuote = new V2AdapterERC20("Missing Pool", "MISS");
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3AdapterBase.PoolMissing.selector,
                address(wbnb),
                address(missingPoolQuote),
                FEE_MEDIUM
            )
        );
        emptyAdapter.registerQuoteRoute(_directQuoteRoute(address(missingPoolQuote)));
    }

    function testQuoteRouteConfigBindsQuoteAndStableRefs() external {
        V2AdapterERC20 otherQuote = new V2AdapterERC20("Other Quote", "OTHER");
        factory.setPool(
            address(wbnb), address(otherQuote), FEE_MEDIUM, address(new V2MockPancakeV3Pool())
        );

        INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams memory wrongQuote =
            _directQuoteSwap(1 ether, 1);
        wrongQuote.quoteToken = address(otherQuote);
        assertFalse(quoteAdapter.isRouteEnabled(directRouteId, address(wbnb), address(otherQuote)));
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3QuoteSwapAdapter.QuoteRouteDisabled.selector, directRouteId
            )
        );
        quoteAdapter.swapExactWbnbForQuote(wrongQuote);

        V2AdapterERC20 unapprovedStable = new V2AdapterERC20("Other Stable", "OSTABLE");
        PancakeV3QuoteSwapAdapter.QuoteRouteConfig[] memory routes =
            new PancakeV3QuoteSwapAdapter.QuoteRouteConfig[](1);
        routes[0] = PancakeV3QuoteSwapAdapter.QuoteRouteConfig({
            quoteToken: address(quote),
            refStable: address(unapprovedStable),
            firstFee: FEE_MEDIUM,
            secondFee: FEE_STABLE
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3QuoteSwapAdapter.UnsupportedStableRef.selector, address(unapprovedStable)
            )
        );
        new PancakeV3QuoteSwapAdapter(
            address(this),
            address(this),
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            address(wbnb),
            _stableRefs(address(stable)),
            _feeTiers(),
            routes
        );
    }

    function testQuoteSwapRejectsMalformedRouteInputsAndUnsupportedFees() external {
        INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams memory wrongWbnb =
            _directQuoteSwap(1 ether, 1);
        wrongWbnb.wbnb = address(stable);
        vm.expectRevert(PancakeV3QuoteSwapAdapter.BadQuoteRoute.selector);
        quoteAdapter.swapExactWbnbForQuote(wrongWbnb);

        uint24[] memory badFeeTiers = new uint24[](1);
        badFeeTiers[0] = 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(PancakeV3AdapterBase.UnsupportedFeeTier.selector, 10_000)
        );
        new PancakeV3QuoteSwapAdapter(
            address(this),
            address(this),
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            address(wbnb),
            _stableRefs(address(stable)),
            badFeeTiers,
            new PancakeV3QuoteSwapAdapter.QuoteRouteConfig[](0)
        );
    }

    function testQuoteSwapReportsReceivedDeltaAndRejectsNetOutputBelowMinOut() external {
        V2AdapterTaxedERC20 taxedQuote = new V2AdapterTaxedERC20("Taxed Quote", "TQUOTE");
        factory.setPool(
            address(wbnb), address(taxedQuote), FEE_MEDIUM, address(new V2MockPancakeV3Pool())
        );
        PancakeV3QuoteSwapAdapter taxedAdapter =
            _deployEmptyQuoteAdapter(address(this), address(this));
        bytes32 taxedRouteId =
            taxedAdapter.registerQuoteRoute(_directQuoteRoute(address(taxedQuote)));

        wbnb.mint(address(this), 2 ether);
        wbnb.approve(address(taxedAdapter), 2 ether);

        router.setNextOutput(100 ether, 0);
        INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams memory swap =
            INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams({
                routeId: taxedRouteId,
                wbnb: address(wbnb),
                quoteToken: address(taxedQuote),
                amountIn: 1 ether,
                minAmountOut: 90 ether,
                recipient: address(this),
                deadline: block.timestamp + 1 hours
            });
        uint256 amountOut = taxedAdapter.swapExactWbnbForQuote(swap);
        assertEq(amountOut, 90 ether);
        assertEq(taxedQuote.balanceOf(address(this)), 90 ether);
        assertEq(taxedQuote.balanceOf(address(taxedAdapter)), 0);

        router.setNextOutput(100 ether, 0);
        swap.minAmountOut = 95 ether;
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3AdapterBase.InsufficientOutput.selector, 90 ether, 95 ether
            )
        );
        taxedAdapter.swapExactWbnbForQuote(swap);
    }

    function testLaunchPoolBuyUsesDirectExactInputSingleAndValidatesExpectedPool() external {
        assertTrue(
            launchAdapter.isPoolEnabled(launchPoolId, address(launchedToken), address(quote))
        );
        quote.mint(address(this), 100 ether);
        quote.approve(address(launchAdapter), 100 ether);
        router.setNextOutput(1_000 ether, 777);

        (uint256 quoteAmountIn, uint256 tokenAmountOut) =
            launchAdapter.buyWithQuote(_buyWithQuote(100 ether, 900 ether));

        assertEq(quoteAmountIn, 100 ether);
        assertEq(tokenAmountOut, 1_000 ether);
        assertTrue(router.lastUsedExactInputSingle());
        assertFalse(router.lastUsedExactInput());
        assertEq(router.lastTokenIn(), address(quote));
        assertEq(router.lastTokenOut(), address(launchedToken));
        assertEq(router.lastRecipient(), address(launchAdapter));
        assertEq(router.lastFee(), FEE_LOW);
        assertEq(router.lastAmountIn(), 100 ether);
        assertEq(router.lastAmountOutMinimum(), 900 ether);
        assertEq(quote.allowance(address(launchAdapter), address(router)), 0);
        assertEq(quote.balanceOf(address(launchAdapter)), 0);
        assertEq(launchedToken.balanceOf(address(launchAdapter)), 0);
        assertEq(launchedToken.balanceOf(address(this)), 1_000 ether);
    }

    function testLaunchPoolRegistrationIsRegistrarOnlyOneShotAndPoolChecked() external {
        V2AdapterERC20 otherLaunch = new V2AdapterERC20("Other Launch", "OTHER");
        address otherPool = address(new V2MockPancakeV3Pool());
        factory.setPool(address(quote), address(otherLaunch), FEE_LOW, otherPool);
        PancakeV3LaunchPoolBuyAdapter emptyAdapter =
            _deployEmptyLaunchAdapter(address(this), address(this));
        PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig memory config =
            _launchPoolConfig(address(quote), address(otherLaunch), FEE_LOW, otherPool);

        vm.prank(attacker);
        vm.expectRevert(PancakeV3AdapterBase.NotRegistrar.selector);
        emptyAdapter.registerLaunchPool(config);

        bytes32 poolId = emptyAdapter.registerLaunchPool(config);
        assertTrue(emptyAdapter.isPoolEnabled(poolId, address(otherLaunch), address(quote)));

        vm.expectRevert(
            abi.encodeWithSelector(PancakeV3AdapterBase.AlreadyRegistered.selector, poolId)
        );
        emptyAdapter.registerLaunchPool(config);

        V2AdapterERC20 missingPoolLaunch = new V2AdapterERC20("Missing Launch", "MISS");
        address orphanPool = address(new V2MockPancakeV3Pool());
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3AdapterBase.PoolMissing.selector,
                address(quote),
                address(missingPoolLaunch),
                FEE_LOW
            )
        );
        emptyAdapter.registerLaunchPool(
            _launchPoolConfig(address(quote), address(missingPoolLaunch), FEE_LOW, orphanPool)
        );
    }

    function testLaunchPoolBuyRejectsNonCoordinatorDisabledPoolAndFactoryMismatch() external {
        vm.prank(attacker);
        vm.expectRevert(PancakeV3AdapterBase.NotCoordinator.selector);
        launchAdapter.buyWithQuote(_buyWithQuote(1 ether, 1));

        ILaunchPoolBuyAdapter.BuyWithQuoteParams memory disabled = _buyWithQuote(1 ether, 1);
        disabled.poolId = bytes32("disabled-pool");
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3LaunchPoolBuyAdapter.LaunchPoolDisabled.selector, disabled.poolId
            )
        );
        launchAdapter.buyWithQuote(disabled);

        address wrongPool = address(new V2MockPancakeV3Pool());
        factory.setPool(address(quote), address(launchedToken), FEE_LOW, wrongPool);
        assertFalse(
            launchAdapter.isPoolEnabled(launchPoolId, address(launchedToken), address(quote))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3LaunchPoolBuyAdapter.UnexpectedPool.selector, launchPool, wrongPool
            )
        );
        launchAdapter.buyWithQuote(_buyWithQuote(1 ether, 1));

        factory.setPool(address(quote), address(launchedToken), FEE_LOW, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3AdapterBase.PoolMissing.selector,
                address(quote),
                address(launchedToken),
                FEE_LOW
            )
        );
        launchAdapter.buyWithQuote(_buyWithQuote(1 ether, 1));
    }

    function testLaunchPoolBuyReportsReceivedDeltaForTaxedLaunchToken() external {
        V2AdapterTaxedERC20 taxedLaunch = new V2AdapterTaxedERC20("Taxed Launch", "TLAUNCH");
        address taxedPool = address(new V2MockPancakeV3Pool());
        factory.setPool(address(quote), address(taxedLaunch), FEE_LOW, taxedPool);
        PancakeV3LaunchPoolBuyAdapter taxedAdapter =
            _deployEmptyLaunchAdapter(address(this), address(this));
        bytes32 taxedPoolId = taxedAdapter.registerLaunchPool(
            _launchPoolConfig(address(quote), address(taxedLaunch), FEE_LOW, taxedPool)
        );

        quote.mint(address(this), 10 ether);
        quote.approve(address(taxedAdapter), 10 ether);
        router.setNextOutput(100 ether, 0);

        ILaunchPoolBuyAdapter.BuyWithQuoteParams memory buy =
            ILaunchPoolBuyAdapter.BuyWithQuoteParams({
                poolId: taxedPoolId,
                launchedToken: address(taxedLaunch),
                quoteToken: address(quote),
                maxQuoteAmountIn: 10 ether,
                minTokenAmountOut: 90 ether,
                deadline: block.timestamp + 1 hours
            });
        (, uint256 tokenAmountOut) = taxedAdapter.buyWithQuote(buy);

        assertEq(tokenAmountOut, 90 ether);
        assertEq(taxedLaunch.balanceOf(address(this)), 90 ether);
        assertEq(taxedLaunch.balanceOf(address(taxedAdapter)), 0);
    }

    function testConstructorsRejectBadDependenciesAndAllowEmptyInitialRegistries() external {
        PancakeV3QuoteSwapAdapter emptyQuoteAdapter =
            _deployEmptyQuoteAdapter(address(this), address(this));
        PancakeV3LaunchPoolBuyAdapter emptyLaunchAdapter =
            _deployEmptyLaunchAdapter(address(this), address(this));
        assertEq(emptyQuoteAdapter.registrar(), address(this));
        assertEq(emptyLaunchAdapter.registrar(), address(this));

        uint24[] memory badFeeTiers = new uint24[](1);
        badFeeTiers[0] = 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(PancakeV3AdapterBase.UnsupportedFeeTier.selector, 10_000)
        );
        new PancakeV3LaunchPoolBuyAdapter(
            address(this),
            address(this),
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            badFeeTiers,
            new PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig[](0)
        );

        address[] memory badStableRefs = new address[](1);
        badStableRefs[0] = address(wbnb);
        vm.expectRevert(PancakeV3AdapterBase.BadAdapterConfiguration.selector);
        new PancakeV3QuoteSwapAdapter(
            address(this),
            address(this),
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            address(wbnb),
            badStableRefs,
            _feeTiers(),
            new PancakeV3QuoteSwapAdapter.QuoteRouteConfig[](0)
        );

        PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig[] memory badPools =
            new PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig[](1);
        badPools[0] = _launchPoolConfig(address(quote), address(launchedToken), FEE_LOW, address(0));
        vm.expectRevert(PancakeV3LaunchPoolBuyAdapter.BadLaunchPoolBuy.selector);
        new PancakeV3LaunchPoolBuyAdapter(
            address(this),
            address(this),
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            _feeTiers(),
            badPools
        );
    }

    function testNativeDevBuyCanCallPancakeAdaptersEndToEnd() external {
        uint256 nonce = vm.getNonce(address(this));
        address predictedDevBuy = vm.computeCreateAddress(address(this), nonce + 2);

        PancakeV3QuoteSwapAdapter nativeQuoteAdapter =
            _deployEmptyQuoteAdapter(predictedDevBuy, address(this));
        PancakeV3LaunchPoolBuyAdapter nativeLaunchAdapter =
            _deployEmptyLaunchAdapter(predictedDevBuy, address(this));
        NativeDevBuy devBuy = new NativeDevBuy(
            address(this),
            IWBNB(address(wbnb)),
            INativeQuoteSwapAdapter(address(nativeQuoteAdapter)),
            ILaunchPoolBuyAdapter(address(nativeLaunchAdapter))
        );
        assertEq(address(devBuy), predictedDevBuy);

        bytes32 routeId = nativeQuoteAdapter.registerQuoteRoute(_directQuoteRoute(address(quote)));
        bytes32 poolId = nativeLaunchAdapter.registerLaunchPool(
            _launchPoolConfig(address(quote), address(launchedToken), FEE_LOW, launchPool)
        );

        NativeDevBuy.DevBuyResult memory result = devBuy.buy{ value: 1 ether }(
            NativeDevBuy.DevBuyParams({
                quoteRouteId: routeId,
                launchPoolId: poolId,
                launchedToken: address(launchedToken),
                quoteToken: address(quote),
                nativeAmountIn: 1 ether,
                minQuoteOut: 1,
                minTokenOut: 1,
                deadline: block.timestamp + 1 hours,
                beneficiary: beneficiary
            })
        );

        assertEq(result.nativeAmountIn, 1 ether);
        assertEq(result.quoteAmountOut, 1 ether);
        assertEq(result.quoteAmountSpent, 1 ether);
        assertEq(result.tokenAmountOut, 1 ether);
        assertEq(launchedToken.balanceOf(beneficiary), 1 ether);
        assertEq(wbnb.allowance(address(devBuy), address(nativeQuoteAdapter)), 0);
        assertEq(quote.allowance(address(devBuy), address(nativeLaunchAdapter)), 0);
    }

    function _directQuoteSwap(uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams memory swap)
    {
        swap = INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams({
            routeId: directRouteId,
            wbnb: address(wbnb),
            quoteToken: address(quote),
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            recipient: address(this),
            deadline: block.timestamp + 1 hours
        });
    }

    function _viaStableQuoteSwap(uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams memory swap)
    {
        swap = INativeQuoteSwapAdapter.SwapExactWbnbForQuoteParams({
            routeId: viaStableRouteId,
            wbnb: address(wbnb),
            quoteToken: address(quote),
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            recipient: address(this),
            deadline: block.timestamp + 1 hours
        });
    }

    function _buyWithQuote(uint256 amountIn, uint256 minAmountOut)
        internal
        view
        returns (ILaunchPoolBuyAdapter.BuyWithQuoteParams memory buy)
    {
        buy = ILaunchPoolBuyAdapter.BuyWithQuoteParams({
            poolId: launchPoolId,
            launchedToken: address(launchedToken),
            quoteToken: address(quote),
            maxQuoteAmountIn: amountIn,
            minTokenAmountOut: minAmountOut,
            deadline: block.timestamp + 1 hours
        });
    }

    function _deployStandardQuoteAdapter(address coordinator_, address registrar_)
        internal
        returns (PancakeV3QuoteSwapAdapter adapter)
    {
        PancakeV3QuoteSwapAdapter.QuoteRouteConfig[] memory routes =
            new PancakeV3QuoteSwapAdapter.QuoteRouteConfig[](2);
        routes[0] = _directQuoteRoute(address(quote));
        routes[1] = _viaStableQuoteRoute(address(quote), address(stable));

        adapter = new PancakeV3QuoteSwapAdapter(
            coordinator_,
            registrar_,
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            address(wbnb),
            _stableRefs(address(stable)),
            _feeTiers(),
            routes
        );
    }

    function _deployEmptyQuoteAdapter(address coordinator_, address registrar_)
        internal
        returns (PancakeV3QuoteSwapAdapter adapter)
    {
        adapter = new PancakeV3QuoteSwapAdapter(
            coordinator_,
            registrar_,
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            address(wbnb),
            _stableRefs(address(stable)),
            _feeTiers(),
            new PancakeV3QuoteSwapAdapter.QuoteRouteConfig[](0)
        );
    }

    function _deployStandardLaunchAdapter(address coordinator_, address registrar_)
        internal
        returns (PancakeV3LaunchPoolBuyAdapter adapter)
    {
        PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig[] memory pools =
            new PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig[](1);
        pools[0] = _launchPoolConfig(address(quote), address(launchedToken), FEE_LOW, launchPool);

        adapter = new PancakeV3LaunchPoolBuyAdapter(
            coordinator_,
            registrar_,
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            _feeTiers(),
            pools
        );
    }

    function _deployEmptyLaunchAdapter(address coordinator_, address registrar_)
        internal
        returns (PancakeV3LaunchPoolBuyAdapter adapter)
    {
        adapter = new PancakeV3LaunchPoolBuyAdapter(
            coordinator_,
            registrar_,
            IPancakeV3SwapRouterLike(address(router)),
            IPancakeV3FactoryLike(address(factory)),
            _feeTiers(),
            new PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig[](0)
        );
    }

    function _directQuoteRoute(address quoteToken)
        internal
        pure
        returns (PancakeV3QuoteSwapAdapter.QuoteRouteConfig memory route)
    {
        route = PancakeV3QuoteSwapAdapter.QuoteRouteConfig({
            quoteToken: quoteToken, refStable: address(0), firstFee: FEE_MEDIUM, secondFee: 0
        });
    }

    function _viaStableQuoteRoute(address quoteToken, address refStable)
        internal
        pure
        returns (PancakeV3QuoteSwapAdapter.QuoteRouteConfig memory route)
    {
        route = PancakeV3QuoteSwapAdapter.QuoteRouteConfig({
            quoteToken: quoteToken,
            refStable: refStable,
            firstFee: FEE_MEDIUM,
            secondFee: FEE_STABLE
        });
    }

    function _launchPoolConfig(address quoteToken, address token, uint24 fee, address pool)
        internal
        pure
        returns (PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig memory config)
    {
        config = PancakeV3LaunchPoolBuyAdapter.LaunchPoolConfig({
            quoteToken: quoteToken, launchedToken: token, fee: fee, expectedPool: pool
        });
    }

    function _stableRefs(address refStable) internal pure returns (address[] memory stableRefs) {
        stableRefs = new address[](1);
        stableRefs[0] = refStable;
    }

    function _feeTiers() internal pure returns (uint24[] memory feeTiers) {
        feeTiers = new uint24[](3);
        feeTiers[0] = FEE_LOW;
        feeTiers[1] = FEE_MEDIUM;
        feeTiers[2] = FEE_STABLE;
    }
}
