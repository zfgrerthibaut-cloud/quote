// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC721Receiver } from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

import {
    INonfungiblePositionManager,
    IPancakeV3Factory
} from "../../../src/interfaces/IPancakeV3.sol";
import { TokenMode, V2FeeConfig } from "../../../src/v2/QuoteV2Types.sol";
import {
    QuoteLaunchArtifacts,
    QuoteLaunchContext,
    QuoteLaunchEngineKind,
    QuoteLaunchRecord,
    QuoteLaunchRequest
} from "../../../src/v2/core/IQuoteLaunchEngine.sol";
import { QuoteLaunchpad } from "../../../src/v2/core/QuoteLaunchpad.sol";
import { DirectV3PriceMath } from "../../../src/v2/direct/DirectV3PriceMath.sol";
import { DirectV3NativeBuy } from "../../../src/v2/direct/DirectV3NativeBuy.sol";
import { PancakeV3DirectEngine } from "../../../src/v2/direct/PancakeV3DirectEngine.sol";
import { QuoteDirectToken } from "../../../src/v2/direct/QuoteDirectToken.sol";
import { PermanentPancakeV3Locker } from "../../../src/v2/locker/PermanentPancakeV3Locker.sol";
import { IWBNB } from "../../../src/v2/native/INativeDevBuyAdapters.sol";
import { V2QuoteUsdPriceVerifier } from "../../../src/v2/oracle/V2QuoteUsdPriceVerifier.sol";
import {
    IPancakeV3SwapRouterLike
} from "../../../src/v2/adapters/interfaces/IPancakeV3AdapterTypes.sol";

contract DirectMockERC20 is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DirectMutableDecimalsERC20 is ERC20 {
    uint8 private _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function setDecimals(uint8 decimals_) external {
        _tokenDecimals = decimals_;
    }
}

contract DirectNoDecimals { }

contract DirectMockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") { }

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{ value: amount }("");
        require(ok, "native send");
    }
}

contract DirectReferencePool { }

contract DirectMockPool {
    uint160 public sqrtPriceX96;
    int24 public tick;
    uint128 public liquidity;

    function initialize(uint160 sqrtPriceX96_, int24 tick_) external {
        require(sqrtPriceX96 == 0, "initialized");
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
    }

    function setState(uint160 sqrtPriceX96_, int24 tick_, uint128 liquidity_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
        liquidity = liquidity_;
    }

    function sendToken(address token, address recipient, uint256 amount) external {
        IERC20(token).transfer(recipient, amount);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract DirectMockPancakeFactory is IPancakeV3Factory {
    mapping(bytes32 key => address pool) public pools;
    mapping(uint24 fee => int24 spacing) public spacings;
    int24 public nextTick;

    constructor() {
        spacings[100] = 1;
        spacings[500] = 10;
        spacings[2_500] = 50;
        spacings[10_000] = 200;
    }

    function setNextTick(int24 tick_) external {
        nextTick = tick_;
    }

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function feeAmountTickSpacing(uint24 fee) external view returns (int24) {
        return spacings[fee];
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function createPool(address tokenA, address tokenB, uint24 fee)
        external
        returns (address pool)
    {
        bytes32 key = _key(tokenA, tokenB, fee);
        require(pools[key] == address(0), "exists");
        pool = address(new DirectMockPool());
        pools[key] = pool;
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract DirectMockPositionManager {
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    DirectMockPancakeFactory public immutable factory;
    uint256 public nextTokenId = 1;
    uint256 public mintDust;
    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => PositionData position) public positionData;

    constructor(DirectMockPancakeFactory factory_) {
        factory = factory_;
    }

    function setMintDust(uint256 mintDust_) external {
        mintDust = mintDust_;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address pool) {
        pool = factory.getPool(token0, token1, fee);
        if (pool == address(0)) pool = factory.createPool(token0, token1, fee);
        if (DirectMockPool(pool).sqrtPriceX96() == 0) {
            DirectMockPool(pool).initialize(sqrtPriceX96, factory.nextTick());
        }
    }

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = params.amount0Desired == 0 ? 0 : params.amount0Desired - mintDust;
        amount1 = params.amount1Desired == 0 ? 0 : params.amount1Desired - mintDust;
        address pool = factory.getPool(params.token0, params.token1, params.fee);
        if (amount0 != 0) IERC20(params.token0).transferFrom(msg.sender, pool, amount0);
        if (amount1 != 0) IERC20(params.token1).transferFrom(msg.sender, pool, amount1);

        tokenId = nextTokenId++;
        liquidity = uint128(amount0 + amount1);
        ownerOf[tokenId] = params.recipient;
        positionData[tokenId] = PositionData({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity
        });
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from && msg.sender == from, "not owner");
        ownerOf[tokenId] = to;
        IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        PositionData memory position = positionData[tokenId];
        return (
            0,
            address(0),
            position.token0,
            position.token1,
            position.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            0,
            0,
            0,
            0
        );
    }

    function collect(INonfungiblePositionManager.CollectParams calldata)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    { }
}

contract DirectMockRouter is IPancakeV3SwapRouterLike {
    DirectMockPancakeFactory public immutable factory;
    uint256 public amountOut = 10 ether;
    uint16 public defaultSpendBps = 10_000;
    mapping(bytes32 route => uint256 amount) public pairAmountOut;
    mapping(bytes32 route => uint16 bps) public pairSpendBps;

    constructor(DirectMockPancakeFactory factory_) {
        factory = factory_;
    }

    function setAmountOut(uint256 amountOut_) external {
        amountOut = amountOut_;
    }

    function setDefaultSpendBps(uint16 spendBps) external {
        defaultSpendBps = spendBps;
    }

    function setRoute(address tokenIn, address tokenOut, uint256 amountOut_, uint16 spendBps)
        external
    {
        pairAmountOut[_key(tokenIn, tokenOut)] = amountOut_;
        pairSpendBps[_key(tokenIn, tokenOut)] = spendBps;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256)
    {
        address pool = factory.getPool(params.tokenIn, params.tokenOut, params.fee);
        bytes32 key = _key(params.tokenIn, params.tokenOut);
        uint16 spendBps = pairSpendBps[key];
        if (spendBps == 0) spendBps = defaultSpendBps;
        uint256 spent = (params.amountIn * spendBps) / 10_000;
        uint256 output = pairAmountOut[key];
        if (output == 0) output = amountOut;
        IERC20(params.tokenIn).transferFrom(msg.sender, pool, spent);
        DirectMockPool(pool).sendToken(params.tokenOut, params.recipient, output);
        return output;
    }

    function exactInput(ExactInputParams calldata) external payable returns (uint256) {
        revert("unused");
    }

    function _key(address tokenIn, address tokenOut) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut));
    }
}

contract DirectLaunchpadCaller {
    function launch(
        PancakeV3DirectEngine engine,
        QuoteLaunchContext calldata context,
        bytes calldata payload
    ) external payable returns (QuoteLaunchArtifacts memory) {
        return engine.launch{ value: msg.value }(context, payload);
    }
}

contract PancakeV3DirectEngineTest is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant SUPPLY = 100_000_000 ether;
    uint256 internal constant MIN_LIQUIDITY = 10_000e18;
    bytes32 internal constant ENGINE_VERSION = keccak256("QUOTE:DIRECT:V3:1");

    address internal creator = makeAddr("creator");
    address internal beneficiary = makeAddr("beneficiary");
    address internal treasury = makeAddr("treasury");

    DirectMockERC20 internal quote;
    DirectMockWBNB internal wbnb;
    DirectReferencePool internal referencePool;
    DirectMockPancakeFactory internal factory;
    DirectMockPositionManager internal positionManager;
    DirectMockRouter internal router;
    DirectLaunchpadCaller internal launchpad;
    V2QuoteUsdPriceVerifier internal verifier;
    PancakeV3DirectEngine internal engine;

    function setUp() external {
        vm.warp(1_800_000_000);
        quote = new DirectMockERC20("Quote", "QUOTE", 18);
        wbnb = new DirectMockWBNB();
        referencePool = new DirectReferencePool();
        factory = new DirectMockPancakeFactory();
        positionManager = new DirectMockPositionManager(factory);
        router = new DirectMockRouter(factory);
        launchpad = new DirectLaunchpadCaller();

        address[] memory references = new address[](1);
        references[0] = address(quote);
        verifier = new V2QuoteUsdPriceVerifier(
            address(this), vm.addr(SIGNER_KEY), MIN_LIQUIDITY, 15 minutes, references
        );
        engine = new PancakeV3DirectEngine(
            address(launchpad),
            ENGINE_VERSION,
            factory,
            INonfungiblePositionManager(address(positionManager)),
            router,
            IWBNB(address(wbnb)),
            verifier,
            treasury
        );
    }

    function testLaunchDerivesSevenThousandDollarPriceAndLocksToken0Position() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("token0"));
        _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("token0-attestation"));

        QuoteLaunchArtifacts memory artifacts = _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);

        assertEq(artifacts.token, record.token);
        assertEq(artifacts.market, record.pool);
        assertEq(artifacts.locker, record.locker);
        assertEq(record.requestedSupply, SUPPLY);
        assertEq(record.depositedSupply, SUPPLY);
        assertEq(record.quotePriceUsdWad, 1e18);
        assertEq(record.observedLiquidityUsdWad, MIN_LIQUIDITY);
        assertEq(record.quoteDecimals, 18);
        assertEq(record.feeTier, engine.POOL_FEE());
        assertEq(record.tickLower, 200);
        assertEq(record.tickUpper, 887_200);
        assertEq(record.tickLower % 200, 0);
        assertEq(record.tickUpper % 200, 0);
        assertLt(uint160(record.token), uint160(address(quote)));
        assertEq(positionManager.ownerOf(record.positionTokenId), record.locker);
        assertTrue(PermanentPancakeV3Locker(record.locker).finalized());
        assertEq(QuoteDirectToken(record.token).balanceOf(record.pool), SUPPLY);
        assertEq(QuoteDirectToken(record.token).totalSupply(), SUPPLY);
        assertTrue(verifier.consumedDigests(record.attestationDigest));
    }

    function testRegistersAndLaunchesThroughQuoteLaunchpad() external {
        QuoteLaunchpad implementation = new QuoteLaunchpad();
        QuoteLaunchpad realLaunchpad = QuoteLaunchpad(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeCall(
                        QuoteLaunchpad.initialize,
                        (QuoteLaunchpad.InitParams({
                                upgradeAdmin: address(this), pauseGuardian: address(this)
                            }))
                    )
                )
            )
        );
        PancakeV3DirectEngine integratedEngine = new PancakeV3DirectEngine(
            address(realLaunchpad),
            ENGINE_VERSION,
            factory,
            INonfungiblePositionManager(address(positionManager)),
            router,
            IWBNB(address(wbnb)),
            verifier,
            treasury
        );
        realLaunchpad.registerEngine(
            ENGINE_VERSION, address(integratedEngine), QuoteLaunchEngineKind.DIRECT, true
        );

        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("integrated"));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _findOrderForEngine(integratedEngine, payload, context, true);
        payload.quoteAttestation = V2QuoteUsdPriceVerifier.QuotePriceAttestation({
            consumer: address(integratedEngine),
            creator: creator,
            launchRequestHash: integratedEngine.launchRequestHash(context, payload),
            quoteToken: address(quote),
            referenceToken: address(quote),
            referencePool: address(referencePool),
            priceUsdWad: 1e18,
            liquidityUsdWad: MIN_LIQUIDITY,
            observationTimestamp: uint64(block.timestamp - 1 minutes),
            deadline: uint64(block.timestamp + 10 minutes),
            nonce: bytes32("integrated-attestation")
        });
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, verifier.hashAttestation(payload.quoteAttestation));
        payload.quoteAttestationSignature = abi.encodePacked(r, s, v);

        QuoteLaunchRequest memory request = QuoteLaunchRequest({
            creator: creator,
            quoteToken: address(quote),
            supply: SUPPLY,
            nativeAmount: 0,
            deadline: block.timestamp + 30 minutes,
            tokenMode: TokenMode.STANDARD,
            feeConfig: V2FeeConfig({
                creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 7_000
            }),
            creatorFeeRecipient: creator,
            rewardFeeRecipient: address(0),
            engineKind: QuoteLaunchEngineKind.DIRECT,
            engineVersion: bytes32(0),
            enginePayload: abi.encode(payload)
        });

        vm.prank(creator);
        QuoteLaunchRecord memory launchRecord = realLaunchpad.launch(request);
        assertEq(launchRecord.engine, address(integratedEngine));
        assertEq(launchRecord.artifacts.market, integratedEngine.recordAt(0).pool);
        assertEq(launchRecord.artifacts.locker, integratedEngine.recordAt(0).locker);
        assertEq(realLaunchpad.launchCount(), 1);
    }

    function testLaunchHandlesReverseOrderAndSixDecimalQuote() external {
        DirectMockERC20 sixDecimalQuote = new DirectMockERC20("USD", "USD", 6);
        DirectReferencePool sixDecimalPool = new DirectReferencePool();
        vm.prank(address(this));
        verifier.setReferenceTokenAllowed(address(sixDecimalQuote), true);

        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("token1-six"));
        payload.referenceToken = address(sixDecimalQuote);
        payload.referencePool = address(sixDecimalPool);
        _findOrderForQuote(payload, address(sixDecimalQuote), false);
        QuoteLaunchContext memory context = _context(address(sixDecimalQuote), SUPPLY);
        _signPayload(payload, context, bytes32("six-decimal-attestation"));

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);

        assertGt(uint160(record.token), uint160(address(sixDecimalQuote)));
        assertEq(record.quoteDecimals, 6);
        assertEq(record.tickLower, -887_200);
        assertEq(record.tickUpper, 0);
        assertEq(QuoteDirectToken(record.token).balanceOf(record.pool), SUPPLY);
        assertEq(positionManager.ownerOf(record.positionTokenId), record.locker);
    }

    function testPricePreviewIsDecimalAwareAndInvertsWithAddressOrder() external view {
        uint256 supply = 7_000 ether;
        uint160 q96 = uint160(1 << 96);

        uint160 sameDecimalsToken0 =
            engine.previewInitialPrice(address(1), address(2), supply, 1e18, 18);
        uint160 sameDecimalsToken1 =
            engine.previewInitialPrice(address(2), address(1), supply, 1e18, 18);
        assertEq(sameDecimalsToken0, q96);
        assertEq(sameDecimalsToken1, q96);

        uint160 sixDecimalsToken0 =
            engine.previewInitialPrice(address(1), address(2), supply, 1e18, 6);
        uint160 sixDecimalsToken1 =
            engine.previewInitialPrice(address(2), address(1), supply, 1e18, 6);
        assertApproxEqAbs(sixDecimalsToken0, uint256(q96) / 1_000_000, 1);
        assertApproxEqAbs(sixDecimalsToken1, uint256(q96) * 1_000_000, 1);
    }

    function testFuzzPriceOrientationIsReciprocalAcrossDecimals(
        uint96 rawSupply,
        uint96 rawQuotePrice,
        uint8 rawDecimals
    ) external view {
        uint256 supply = bound(uint256(rawSupply), 1_000 ether, 1_000_000_000_000 ether);
        uint256 quotePriceUsdWad = bound(uint256(rawQuotePrice), 0.01e18, 1_000_000e18);
        uint8 quoteDecimals = uint8(bound(uint256(rawDecimals), 6, 18));

        uint160 token0Price = engine.previewInitialPrice(
            address(1), address(2), supply, quotePriceUsdWad, quoteDecimals
        );
        uint160 token1Price = engine.previewInitialPrice(
            address(2), address(1), supply, quotePriceUsdWad, quoteDecimals
        );
        uint256 q192 = 1 << 192;
        uint256 reciprocalProduct = uint256(token0Price) * uint256(token1Price);

        assertApproxEqAbs(reciprocalProduct, q192, uint256(token0Price) + uint256(token1Price) + 3);
    }

    function testFallsBackWhenFirstCandidatePoolIsPreinitialized() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("squatted-first"));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _findOrder(payload, true);
        _signPayload(payload, context, bytes32("squatted-first-attestation"));

        (address squattedToken, address squattedPool) = _preinitializeCandidate(context, payload, 0);

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        assertNotEq(record.token, squattedToken);
        assertEq(factory.getPool(record.token, address(quote), engine.POOL_FEE()), record.pool);
        assertEq(DirectMockPool(squattedPool).liquidity(), 0);
        assertGt(DirectMockPool(squattedPool).sqrtPriceX96(), 0);
    }

    function testRejectsWhenAllBoundedCandidatesArePreinitialized() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("all-squatted"));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _findOrder(payload, true);
        _signPayload(payload, context, bytes32("all-squatted-attestation"));

        for (uint256 i; i < engine.MAX_TOKEN_CANDIDATES(); ++i) {
            _preinitializeCandidate(context, payload, i);
        }

        vm.expectRevert(PancakeV3DirectEngine.NoUnsquattedPoolCandidate.selector);
        _launch(context, payload);
        assertEq(engine.recordAt(0).token, address(0));
        assertFalse(verifier.consumedDigests(verifier.hashAttestation(payload.quoteAttestation)));
    }

    function testAcceptsOnlyBoundedMintDustAndBurnsItAtomically() external {
        uint256 maxDust = SUPPLY / engine.MAX_DUST_DIVISOR();
        positionManager.setMintDust(maxDust);
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("bounded-dust"));
        _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("bounded-dust-attestation"));

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        assertEq(record.depositedSupply, SUPPLY - maxDust);
        assertEq(QuoteDirectToken(record.token).totalSupply(), record.depositedSupply);
        assertEq(QuoteDirectToken(record.token).balanceOf(record.pool), record.depositedSupply);
        assertEq(QuoteDirectToken(record.token).balanceOf(address(engine)), 0);
    }

    function testRejectsLiquidityDustAboveBound() external {
        uint256 maxDust = SUPPLY / engine.MAX_DUST_DIVISOR();
        positionManager.setMintDust(maxDust + 1);
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("excess-dust"));
        _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("excess-dust-attestation"));

        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3DirectEngine.ExcessiveLiquidityDust.selector, maxDust + 1, maxDust
            )
        );
        _launch(context, payload);
        assertEq(engine.recordAt(0).token, address(0));
    }

    function testNativeDevBuyRoutesBnbThroughQuoteThenLaunchPool() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("dev-buy"));
        _findOrder(payload, true);
        address quotePool = _createQuoteRoute(address(quote), 500);
        payload.devBuy = DirectV3NativeBuy.DevBuyParams({
            nativeAmountIn: 2 ether,
            minQuoteOut: 4 ether,
            minTokenOut: 9 ether,
            deadline: block.timestamp + 10 minutes,
            quoteFeeTier: 500,
            expectedQuotePool: quotePool,
            quoteSqrtPriceLimitX96: 0,
            launchSqrtPriceLimitX96: 0,
            beneficiary: beneficiary
        });
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 2 ether;
        _signPayload(payload, context, bytes32("dev-buy-attestation"));
        router.setRoute(address(wbnb), address(quote), 5 ether, 10_000);

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        assertEq(record.devBuyNativeIn, 2 ether);
        assertEq(record.devBuyQuoteOut, 5 ether);
        assertEq(record.devBuyTokenOut, 10 ether);
        assertEq(QuoteDirectToken(record.token).balanceOf(beneficiary), 10 ether);
        assertEq(IERC20(address(quote)).balanceOf(address(engine)), 0);
        assertEq(IERC20(address(quote)).balanceOf(address(engine.nativeBuy())), 0);
        assertEq(IERC20(address(wbnb)).balanceOf(address(engine.nativeBuy())), 0);
    }

    function testNativeDevBuyUsesSingleLaunchSwapWhenQuoteIsWbnb() external {
        verifier.setReferenceTokenAllowed(address(wbnb), true);
        DirectReferencePool wbnbReferencePool = new DirectReferencePool();
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("wbnb-dev-buy"));
        payload.referenceToken = address(wbnb);
        payload.referencePool = address(wbnbReferencePool);
        _findOrderForQuote(payload, address(wbnb), true);
        payload.devBuy = DirectV3NativeBuy.DevBuyParams({
            nativeAmountIn: 1 ether,
            minQuoteOut: 1 ether,
            minTokenOut: 9 ether,
            deadline: block.timestamp + 10 minutes,
            quoteFeeTier: 0,
            expectedQuotePool: address(0),
            quoteSqrtPriceLimitX96: 0,
            launchSqrtPriceLimitX96: 0,
            beneficiary: beneficiary
        });
        QuoteLaunchContext memory context = _context(address(wbnb), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("wbnb-dev-buy-attestation"));

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        assertEq(record.devBuyNativeIn, 1 ether);
        assertEq(record.devBuyQuoteOut, 1 ether);
        assertEq(record.devBuyTokenOut, 10 ether);
        assertEq(QuoteDirectToken(record.token).balanceOf(beneficiary), 10 ether);
        assertEq(IERC20(address(wbnb)).balanceOf(address(engine.nativeBuy())), 0);
    }

    function testNativeDevBuyRefundsUnspentWbnbAndQuote() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("dev-buy-refund"));
        _findOrder(payload, true);
        address quotePool = _createQuoteRoute(address(quote), 500);
        payload.devBuy = DirectV3NativeBuy.DevBuyParams({
            nativeAmountIn: 1 ether,
            minQuoteOut: 5 ether,
            minTokenOut: 9 ether,
            deadline: block.timestamp + 10 minutes,
            quoteFeeTier: 500,
            expectedQuotePool: quotePool,
            quoteSqrtPriceLimitX96: 0,
            launchSqrtPriceLimitX96: 0,
            beneficiary: beneficiary
        });
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("dev-buy-refund-attestation"));
        router.setDefaultSpendBps(5_000);
        router.setRoute(address(wbnb), address(quote), 5 ether, 5_000);

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        assertEq(beneficiary.balance, 0.5 ether);
        assertEq(quote.balanceOf(beneficiary), 2.5 ether);
        assertEq(record.devBuyNativeRefund, 0.5 ether);
        assertEq(record.devBuyQuoteRefund, 2.5 ether);
        assertEq(address(engine.nativeBuy()).balance, 0);
        assertEq(quote.balanceOf(address(engine.nativeBuy())), 0);
        assertEq(wbnb.balanceOf(address(engine.nativeBuy())), 0);
    }

    function testNativeDevBuyRejectsValueMismatch() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("value-mismatch"));
        _findOrder(payload, true);
        payload.devBuy = _nativeBuyParams(2 ether, address(1));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3DirectEngine.NativeValueMismatch.selector, 1 ether, 2 ether
            )
        );
        _launch(context, payload);
    }

    function testNativeDevBuyRejectsExpiredDeadlineAtomically() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("expired-dev-buy"));
        _findOrder(payload, true);
        address quotePool = _createQuoteRoute(address(quote), 500);
        payload.devBuy = _nativeBuyParams(1 ether, quotePool);
        payload.devBuy.deadline = block.timestamp - 1;
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("expired-dev-buy-attestation"));

        vm.expectRevert(DirectV3NativeBuy.DeadlineExpired.selector);
        _launch(context, payload);
        assertEq(engine.recordAt(0).token, address(0));
        assertFalse(verifier.consumedDigests(verifier.hashAttestation(payload.quoteAttestation)));
    }

    function testNativeDevBuyRejectsMeasuredSlippageAtomically() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("slippage-dev-buy"));
        _findOrder(payload, true);
        address quotePool = _createQuoteRoute(address(quote), 500);
        payload.devBuy = _nativeBuyParams(1 ether, quotePool);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("slippage-dev-buy-attestation"));
        router.setAmountOut(8 ether);
        router.setRoute(address(wbnb), address(quote), 5 ether, 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(DirectV3NativeBuy.TokenSlippage.selector, 8 ether, 9 ether)
        );
        _launch(context, payload);
        assertEq(engine.recordAt(0).token, address(0));
        assertFalse(verifier.consumedDigests(verifier.hashAttestation(payload.quoteAttestation)));
    }

    function testNativeDevBuyRejectsQuoteSlippageAtomically() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("quote-slippage"));
        _findOrder(payload, true);
        address quotePool = _createQuoteRoute(address(quote), 500);
        payload.devBuy = _nativeBuyParams(1 ether, quotePool);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("quote-slippage-attestation"));
        router.setRoute(address(wbnb), address(quote), 4 ether, 10_000);

        vm.expectRevert(
            abi.encodeWithSelector(DirectV3NativeBuy.QuoteSlippage.selector, 4 ether, 5 ether)
        );
        _launch(context, payload);
        assertEq(engine.recordAt(0).token, address(0));
        assertFalse(verifier.consumedDigests(verifier.hashAttestation(payload.quoteAttestation)));
    }

    function testNativeDevBuyRejectsQuotePoolMismatch() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("route-mismatch"));
        _findOrder(payload, true);
        address actualQuotePool = _createQuoteRoute(address(quote), 500);
        address wrongQuotePool = makeAddr("wrong-quote-pool");
        payload.devBuy = _nativeBuyParams(1 ether, wrongQuotePool);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("route-mismatch-attestation"));

        vm.expectRevert(
            abi.encodeWithSelector(
                DirectV3NativeBuy.QuotePoolMismatch.selector, wrongQuotePool, actualQuotePool
            )
        );
        _launch(context, payload);
    }

    function testRejectsQuoteWithoutCodeOrDecimalsAndReferenceAddressesWithoutCode() external {
        address noCode = makeAddr("no-code-quote");
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("no-code"));
        QuoteLaunchContext memory context = _context(noCode, SUPPLY);
        vm.expectRevert(PancakeV3DirectEngine.InvalidContext.selector);
        _launch(context, payload);

        DirectNoDecimals noDecimals = new DirectNoDecimals();
        context = _context(address(noDecimals), SUPPLY);
        vm.expectRevert(PancakeV3DirectEngine.QuoteDecimalsUnavailable.selector);
        _launch(context, payload);

        payload = _payload(bytes32("no-code-reference-pool"));
        payload.referencePool = makeAddr("no-code-reference-pool");
        context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("no-code-reference-attestation"));
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.AddressHasNoCode.selector, payload.referencePool
            )
        );
        _launch(context, payload);
    }

    function testRejectsUnsupportedQuoteDecimals() external {
        DirectMockERC20 badDecimals = new DirectMockERC20("Bad", "BAD", 37);
        DirectReferencePool badPool = new DirectReferencePool();
        verifier.setReferenceTokenAllowed(address(badDecimals), true);
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("bad-decimals"));
        payload.referenceToken = address(badDecimals);
        payload.referencePool = address(badPool);
        QuoteLaunchContext memory context = _context(address(badDecimals), SUPPLY);
        _signPayload(payload, context, bytes32("bad-decimals-attestation"));

        vm.expectRevert(
            abi.encodeWithSelector(DirectV3PriceMath.UnsupportedQuoteDecimals.selector, uint8(37))
        );
        _launch(context, payload);
    }

    function testPoolFeeIsProtocolFixedAndAlternativeTierIsNeverCreated() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("fixed-fee"));
        address predicted = _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("fixed-fee-attestation"));

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        assertEq(engine.POOL_FEE(), 10_000);
        assertEq(record.feeTier, 10_000);
        assertEq(factory.getPool(predicted, address(quote), 10_000), record.pool);
        assertEq(factory.getPool(predicted, address(quote), 500), address(0));
        assertEq(factory.getPool(predicted, address(quote), 2_500), address(0));
    }

    function testCreatorLpShareUsesCreatorFeeRecipientAsLockerBeneficiary() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("lp-beneficiary"));
        _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        address feeRecipient = makeAddr("creator-fee-recipient");
        context.creatorFeeRecipient = feeRecipient;
        _signPayload(payload, context, bytes32("lp-beneficiary-attestation"));

        _launch(context, payload);
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        PermanentPancakeV3Locker locker = PermanentPancakeV3Locker(record.locker);
        assertEq(locker.creator(), feeRecipient);
        assertEq(locker.creatorFeeBps(), context.feeConfig.creatorLpShareBps);
    }

    function testAttestationCannotBeFrontRunByAnotherCreator() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("creator-binding"));
        _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("creator-binding-attestation"));

        address attacker = makeAddr("front-runner");
        context.creator = attacker;
        vm.expectRevert(
            abi.encodeWithSelector(
                PancakeV3DirectEngine.AttestedCreatorMismatch.selector, creator, attacker
            )
        );
        _launch(context, payload);
    }

    function testLaunchAuthorizationDoesNotBindLaunchId() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("launch-id-free"));
        QuoteLaunchContext memory signedContext = _context(address(quote), SUPPLY);
        _signPayload(payload, signedContext, bytes32("launch-id-free-attestation"));

        QuoteLaunchContext memory executedContext = signedContext;
        executedContext.launchId = 42;
        assertEq(
            engine.launchRequestHash(signedContext, payload),
            engine.launchRequestHash(executedContext, payload)
        );

        QuoteLaunchArtifacts memory artifacts = _launch(executedContext, payload);
        assertEq(engine.recordAt(42).token, artifacts.token);
        assertEq(engine.recordAt(0).token, address(0));
    }

    function testLaunchRequestHashBindsFullEconomicContextAndEngineIdentity() external view {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("full-binding"));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        bytes32 baseHash = engine.launchRequestHash(context, payload);

        QuoteLaunchContext memory changed = context;
        changed.launchId = 99;
        assertEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.tokenMode = TokenMode.REWARD;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.feeConfig.creatorSwapFeeBps = 1;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.feeConfig.rewardFeeBps = 1;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.feeConfig.creatorLpShareBps = 6_999;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.creatorFeeRecipient = beneficiary;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.rewardFeeRecipient = beneficiary;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.engineKind = QuoteLaunchEngineKind.CURVE;
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);

        changed = context;
        changed.engineVersion = keccak256("QUOTE:DIRECT:V3:other");
        assertNotEq(engine.launchRequestHash(changed, payload), baseHash);
    }

    function testAttestationRequestHashBindsEngineObservedQuoteDecimals() external {
        DirectMutableDecimalsERC20 mutableQuote =
            new DirectMutableDecimalsERC20("Mutable Quote", "MQUOTE", 18);
        DirectReferencePool mutablePool = new DirectReferencePool();
        verifier.setReferenceTokenAllowed(address(mutableQuote), true);

        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("mutable-decimals"));
        payload.referenceToken = address(mutableQuote);
        payload.referencePool = address(mutablePool);
        QuoteLaunchContext memory context = _context(address(mutableQuote), SUPPLY);
        _findOrderForQuote(payload, address(mutableQuote), true);
        _signPayload(payload, context, bytes32("mutable-decimals-attestation"));

        mutableQuote.setDecimals(6);

        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, payload);
        assertFalse(verifier.consumedDigests(verifier.hashAttestation(payload.quoteAttestation)));
    }

    function testAttestationRequestHashRejectsSupplyMetadataSaltAndLaunchDeadlineTampering()
        external
    {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("request-binding"));
        _findOrder(payload, true);
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        _signPayload(payload, context, bytes32("request-binding-attestation"));

        QuoteLaunchContext memory tamperedContext = context;
        tamperedContext.supply = SUPPLY + 1 ether;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(tamperedContext, payload);

        tamperedContext = context;
        tamperedContext.deadline += 1;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(tamperedContext, payload);

        tamperedContext = context;
        tamperedContext.feeConfig.creatorLpShareBps = 6_999;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(tamperedContext, payload);

        tamperedContext = context;
        tamperedContext.creatorFeeRecipient = beneficiary;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(tamperedContext, payload);

        tamperedContext = context;
        tamperedContext.rewardFeeRecipient = beneficiary;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(tamperedContext, payload);

        PancakeV3DirectEngine.LaunchPayload memory tamperedPayload = payload;
        tamperedPayload.name = "Tampered";
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.symbol = "BAD";
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.userSalt = bytes32("tampered-salt");
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);
    }

    function testAttestationRequestHashRejectsDevBuyRouteSlippageAndDeadlineTampering() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("dev-binding"));
        _findOrder(payload, true);
        payload.devBuy = _nativeBuyParams(1 ether, makeAddr("signed-quote-pool"));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("dev-binding-attestation"));

        PancakeV3DirectEngine.LaunchPayload memory tamperedPayload = payload;
        tamperedPayload.devBuy.quoteFeeTier = 2_500;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.devBuy.expectedQuotePool = makeAddr("other-quote-pool");
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.devBuy.minQuoteOut += 1;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.devBuy.minTokenOut += 1;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.devBuy.deadline += 1;
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);

        tamperedPayload = payload;
        tamperedPayload.devBuy.beneficiary = makeAddr("other-beneficiary");
        vm.expectPartialRevert(PancakeV3DirectEngine.AttestedRequestHashMismatch.selector);
        _launch(context, tamperedPayload);
    }

    function testNativeDevBuyRequiresExplicitCanonicalQuotePool() external {
        PancakeV3DirectEngine.LaunchPayload memory payload = _payload(bytes32("explicit-route"));
        _findOrder(payload, true);
        payload.devBuy = _nativeBuyParams(1 ether, address(0));
        QuoteLaunchContext memory context = _context(address(quote), SUPPLY);
        context.nativeAmount = 1 ether;
        _signPayload(payload, context, bytes32("explicit-route-attestation"));

        vm.expectRevert(DirectV3NativeBuy.InvalidDevBuy.selector);
        _launch(context, payload);
    }

    function testTickEndpointsAreAlignedAndStrictlyOneSided() external view {
        (int24 lower0, int24 upper0) = engine.previewOneSidedTicks(-1, 10, true);
        assertEq(lower0, 0);
        assertEq(upper0, 887_270);

        (int24 lower1, int24 upper1) = engine.previewOneSidedTicks(-1, 10, false);
        assertEq(lower1, -887_270);
        assertEq(upper1, -10);
    }

    function testRejectsTicksWithoutRoomAtProtocolEndpoints() external {
        vm.expectPartialRevert(DirectV3PriceMath.NoOneSidedRange.selector);
        engine.previewOneSidedTicks(887_271, 10, true);

        vm.expectPartialRevert(DirectV3PriceMath.NoOneSidedRange.selector);
        engine.previewOneSidedTicks(-887_271, 10, false);
    }

    function testFuzzAlignedTicksRemainOneSided(int24 rawTick, uint8 spacingSeed, bool token0)
        external
        view
    {
        int24 currentTick = int24(bound(int256(rawTick), -887_000, 887_000));
        int24[4] memory spacings = [int24(1), int24(10), int24(50), int24(200)];
        int24 spacing = spacings[spacingSeed % 4];
        (int24 lower, int24 upper) = engine.previewOneSidedTicks(currentTick, spacing, token0);

        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertLt(lower, upper);
        if (token0) {
            assertGt(lower, currentTick);
            assertEq(upper, (int24(887_272) / spacing) * spacing);
        } else {
            assertLe(upper, currentTick);
            assertEq(lower, (int24(-887_272) / spacing) * spacing);
        }
    }

    function _context(address quoteToken, uint256 supply)
        internal
        view
        returns (QuoteLaunchContext memory context)
    {
        context = QuoteLaunchContext({
            launchId: 0,
            creator: creator,
            quoteToken: quoteToken,
            supply: supply,
            nativeAmount: 0,
            deadline: block.timestamp + 30 minutes,
            tokenMode: TokenMode.STANDARD,
            feeConfig: V2FeeConfig({
                creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 7_000
            }),
            creatorFeeRecipient: creator,
            rewardFeeRecipient: address(0),
            engineKind: QuoteLaunchEngineKind.DIRECT,
            engineVersion: ENGINE_VERSION
        });
    }

    function _payload(bytes32 salt)
        internal
        view
        returns (PancakeV3DirectEngine.LaunchPayload memory payload)
    {
        payload.name = "Direct V3 Launch";
        payload.symbol = "DV3";
        payload.userSalt = salt;
        payload.referenceToken = address(quote);
        payload.referencePool = address(referencePool);
    }

    function _signPayload(
        PancakeV3DirectEngine.LaunchPayload memory payload,
        QuoteLaunchContext memory context,
        bytes32 nonce
    ) internal view {
        payload.quoteAttestation =
            V2QuoteUsdPriceVerifier.QuotePriceAttestation({
                consumer: address(engine),
                creator: context.creator,
                launchRequestHash: engine.launchRequestHash(context, payload),
                quoteToken: context.quoteToken,
                referenceToken: payload.referenceToken,
                referencePool: payload.referencePool,
                priceUsdWad: 1e18,
                liquidityUsdWad: MIN_LIQUIDITY,
                observationTimestamp: uint64(block.timestamp - 1 minutes),
                deadline: uint64(block.timestamp + 10 minutes),
                nonce: nonce
            });
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, verifier.hashAttestation(payload.quoteAttestation));
        payload.quoteAttestationSignature = abi.encodePacked(r, s, v);
    }

    function _launch(
        QuoteLaunchContext memory context,
        PancakeV3DirectEngine.LaunchPayload memory payload
    ) internal returns (QuoteLaunchArtifacts memory) {
        if (context.nativeAmount != 0) vm.deal(address(this), context.nativeAmount);
        return launchpad.launch{ value: context.nativeAmount }(engine, context, abi.encode(payload));
    }

    function _nativeBuyParams(uint256 nativeAmount, address expectedQuotePool)
        internal
        view
        returns (DirectV3NativeBuy.DevBuyParams memory params)
    {
        params = DirectV3NativeBuy.DevBuyParams({
            nativeAmountIn: nativeAmount,
            minQuoteOut: 5 ether,
            minTokenOut: 9 ether,
            deadline: block.timestamp + 10 minutes,
            quoteFeeTier: 500,
            expectedQuotePool: expectedQuotePool,
            quoteSqrtPriceLimitX96: 0,
            launchSqrtPriceLimitX96: 0,
            beneficiary: beneficiary
        });
    }

    function _createQuoteRoute(address quoteToken, uint24 feeTier) internal returns (address pool) {
        pool = factory.createPool(address(wbnb), quoteToken, feeTier);
        DirectMockPool(pool).initialize(uint160(1 << 96), 0);
        DirectMockERC20(quoteToken).mint(pool, 1_000_000 ether);
    }

    function _findOrder(PancakeV3DirectEngine.LaunchPayload memory payload, bool token0)
        internal
        view
        returns (address predicted)
    {
        return _findOrderForQuote(payload, address(quote), token0);
    }

    function _findOrderForQuote(
        PancakeV3DirectEngine.LaunchPayload memory payload,
        address quoteToken,
        bool token0
    ) internal view returns (address predicted) {
        QuoteLaunchContext memory context = _context(quoteToken, SUPPLY);
        return _findOrderForEngine(engine, payload, context, token0);
    }

    function _findOrderForEngine(
        PancakeV3DirectEngine engine_,
        PancakeV3DirectEngine.LaunchPayload memory payload,
        QuoteLaunchContext memory context,
        bool token0
    ) internal view returns (address predicted) {
        for (uint256 i; i < 512; ++i) {
            payload.userSalt = bytes32(i);
            predicted = _candidateToken(engine_, context, payload, 0);
            if ((predicted < context.quoteToken) == token0) return predicted;
        }
        revert("order not found");
    }

    function _preinitializeCandidate(
        QuoteLaunchContext memory context,
        PancakeV3DirectEngine.LaunchPayload memory payload,
        uint256 candidate
    ) internal returns (address predicted, address pool) {
        predicted = _candidateToken(engine, context, payload, candidate);
        pool = factory.createPool(predicted, context.quoteToken, engine.POOL_FEE());
        uint160 expectedPrice = engine.previewInitialPrice(
            predicted, context.quoteToken, context.supply, 1e18, _quoteDecimals(context.quoteToken)
        );
        DirectMockPool(pool).setState(expectedPrice, -100, 0);
    }

    function _candidateToken(
        PancakeV3DirectEngine engine_,
        QuoteLaunchContext memory context,
        PancakeV3DirectEngine.LaunchPayload memory payload,
        uint256 candidate
    ) internal view returns (address predicted) {
        bytes32 salt = keccak256(
            abi.encode(
                engine_.TOKEN_SALT_DOMAIN(),
                block.chainid,
                address(engine_),
                address(engine_.tokenDeployer()),
                context.launchId,
                context.creator,
                context.quoteToken,
                context.supply,
                _quoteDecimals(context.quoteToken),
                keccak256(bytes(payload.name)),
                keccak256(bytes(payload.symbol)),
                payload.userSalt,
                _executionTokenEntropy(),
                candidate
            )
        );
        predicted =
            engine_.tokenDeployer().predict(salt, payload.name, payload.symbol, context.supply);
    }

    function _executionTokenEntropy() internal view returns (bytes32) {
        bytes32 parentHash = block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
        return keccak256(abi.encode(parentHash, block.prevrandao, block.timestamp, block.coinbase));
    }

    function _quoteDecimals(address quoteToken) internal view returns (uint8) {
        return IERC20Metadata(quoteToken).decimals();
    }
}
