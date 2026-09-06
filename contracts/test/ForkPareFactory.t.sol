// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { IERC721Receiver } from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

import { ForkPareFactory } from "../src/ForkPareFactory.sol";
import { ForkPareToken } from "../src/ForkPareToken.sol";
import { PermanentV3Locker } from "../src/PermanentV3Locker.sol";
import { INonfungiblePositionManager, IPancakeV3Factory } from "../src/interfaces/IPancakeV3.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Quote", "QUOTE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferQuote is ERC20 {
    constructor() ERC20("Taxed Quote", "TAX") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

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

contract SenderTaxQuote is ERC20 {
    constructor() ERC20("Sender Tax Quote", "STAX") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || value == 0) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = value / 10;
        super._update(from, to, value);
        super._update(from, address(0), fee);
    }
}

contract FalseReturnQuote is ERC20 {
    constructor() ERC20("False Quote", "FALSE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract MockPool {
    int24 public tick;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;

    constructor(int24 tick_) {
        tick = tick_;
    }

    function setState(uint160 sqrtPriceX96_, int24 tick_, uint128 liquidity_) external {
        sqrtPriceX96 = sqrtPriceX96_;
        tick = tick_;
        liquidity = liquidity_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract MockPancakeFactory is IPancakeV3Factory {
    mapping(bytes32 key => address pool) public pools;
    mapping(uint24 fee => int24 spacing) public spacings;
    int24 public nextTick;

    constructor() {
        spacings[500] = 10;
    }

    function setNextTick(int24 tick_) external {
        nextTick = tick_;
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
        pool = address(new MockPool(nextTick));
        pools[key] = pool;
    }

    function _key(address tokenA, address tokenB, uint24 fee) private pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, fee));
    }
}

contract MockPositionManager {
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    MockPancakeFactory public immutable factory;
    uint256 public nextTokenId = 1;
    uint256 public collectAmount0;
    uint256 public collectAmount1;
    uint256 public mintDust;
    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => PositionData data) public positionData;

    constructor(MockPancakeFactory factory_) {
        factory = factory_;
    }

    function setCollectAmounts(uint256 amount0, uint256 amount1) external {
        collectAmount0 = amount0;
        collectAmount1 = amount1;
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
        (uint160 currentPrice,,,,,,) = MockPool(pool).slot0();
        if (currentPrice == 0) MockPool(pool).setState(sqrtPriceX96, factory.nextTick(), 0);
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
        IERC721Receiver(params.recipient)
            .onERC721Received(address(this), address(0), tokenId, bytes(""));
    }

    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        require(ownerOf[params.tokenId] == msg.sender, "not owner");
        amount0 = collectAmount0;
        amount1 = collectAmount1;
        collectAmount0 = 0;
        collectAmount1 = 0;
        if (amount0 != 0) IERC20(_token0(params.tokenId)).transfer(params.recipient, amount0);
        if (amount1 != 0) IERC20(_token1(params.tokenId)).transfer(params.recipient, amount1);
    }

    address public lastToken0;
    address public lastToken1;

    function setPositionTokens(address token0, address token1) external {
        lastToken0 = token0;
        lastToken1 = token1;
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

    function _token0(uint256) private view returns (address) {
        return lastToken0;
    }

    function _token1(uint256) private view returns (address) {
        return lastToken1;
    }
}

contract ForkPareFactoryTest is Test {
    uint256 internal constant CREATION_FEE = 0.01 ether;
    uint256 internal constant SUPPLY = 100_000_000 ether;

    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");
    address internal quote = address(type(uint160).max - 1);

    MockPancakeFactory internal pancakeFactory;
    MockPositionManager internal positionManager;
    ForkPareFactory internal launchFactory;

    function setUp() external {
        pancakeFactory = new MockPancakeFactory();
        positionManager = new MockPositionManager(pancakeFactory);
        launchFactory = new ForkPareFactory(
            pancakeFactory,
            INonfungiblePositionManager(address(positionManager)),
            treasury,
            CREATION_FEE
        );

        MockERC20 implementation = new MockERC20();
        vm.etch(quote, address(implementation).code);
        vm.deal(creator, 10 ether);
    }

    function testLaunchCreatesFixedSupplyTokenAndPermanentLocker() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("one"));
        address predicted = launchFactory.predictToken(creator, params);
        assertLt(uint160(predicted), uint160(quote));

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        assertEq(record.token, predicted);
        assertEq(record.creator, creator);
        assertEq(record.quoteToken, quote);
        assertEq(record.feeTier, 500);
        assertEq(launchFactory.launchCount(), 1);
        assertEq(launchFactory.launchIdByToken(record.token), 1);
        assertEq(ForkPareToken(record.token).totalSupply(), SUPPLY);
        assertEq(ForkPareToken(record.token).balanceOf(record.pool), SUPPLY);
        assertEq(positionManager.ownerOf(record.positionTokenId), record.locker);
        assertTrue(PermanentV3Locker(record.locker).initialized());

        vm.prank(creator);
        vm.expectRevert(ForkPareToken.NotFactory.selector);
        ForkPareToken(record.token).burnUnspent(1);

        (bool ok,) = record.locker.call(abi.encodeWithSignature("decreaseLiquidity(uint256)", 1));
        assertFalse(ok, "locker must expose no principal withdrawal path");
    }

    function testRejectsMissingOrMismatchedCanonicalDependencies() external {
        vm.expectRevert(ForkPareFactory.BadDependencies.selector);
        new ForkPareFactory(
            IPancakeV3Factory(address(0x1234)),
            INonfungiblePositionManager(address(positionManager)),
            treasury,
            CREATION_FEE
        );

        MockPancakeFactory otherFactory = new MockPancakeFactory();
        vm.expectRevert(ForkPareFactory.BadDependencies.selector);
        new ForkPareFactory(
            otherFactory,
            INonfungiblePositionManager(address(positionManager)),
            treasury,
            CREATION_FEE
        );
    }

    function testCollectedQuoteFeesSplitSeventyThirty() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("fees"));
        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        positionManager.setPositionTokens(record.token, quote);
        MockERC20(quote).mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);

        PermanentV3Locker(record.locker).collect();

        assertEq(PermanentV3Locker(record.locker).claimable(creator, quote), 70 ether);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, quote), 30 ether);

        vm.prank(creator);
        PermanentV3Locker(record.locker).claim(quote);
        vm.prank(treasury);
        PermanentV3Locker(record.locker).claim(quote);

        assertEq(IERC20(quote).balanceOf(creator), 70 ether);
        assertEq(IERC20(quote).balanceOf(treasury), 30 ether);
    }

    function testFuzzCollectedQuoteFeesAreConserved(uint128 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 0, 1_000_000_000 ether);
        ForkPareFactory.LaunchParams memory params = _params(keccak256(abi.encode(rawAmount)));
        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        positionManager.setPositionTokens(record.token, quote);
        MockERC20(quote).mint(address(positionManager), amount);
        positionManager.setCollectAmounts(0, amount);
        PermanentV3Locker(record.locker).collect();

        uint256 creatorAmount = PermanentV3Locker(record.locker).claimable(creator, quote);
        uint256 treasuryAmount = PermanentV3Locker(record.locker).claimable(treasury, quote);
        assertEq(creatorAmount + treasuryAmount, amount);
        assertEq(creatorAmount, (amount * 7_000) / 10_000);
    }

    function testFragmentedFeeCollectionsUseCumulativeRounding() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("fragmented-fees"));
        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        positionManager.setPositionTokens(record.token, quote);
        MockERC20(quote).mint(address(positionManager), 2);

        positionManager.setCollectAmounts(0, 1);
        PermanentV3Locker(record.locker).collect();
        assertEq(PermanentV3Locker(record.locker).claimable(creator, quote), 0);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, quote), 1);

        positionManager.setCollectAmounts(0, 1);
        PermanentV3Locker(record.locker).collect();
        assertEq(PermanentV3Locker(record.locker).claimable(creator, quote), 1);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, quote), 1);
    }

    function testFeeOnTransferQuoteCreditsOnlyNetReceived() external {
        address taxedQuote = address(type(uint160).max - 2);
        FeeOnTransferQuote implementation = new FeeOnTransferQuote();
        vm.etch(taxedQuote, address(implementation).code);
        ForkPareFactory.LaunchParams memory params = _params(bytes32("taxed-quote"));
        params.quoteToken = taxedQuote;

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        positionManager.setPositionTokens(record.token, taxedQuote);
        FeeOnTransferQuote(taxedQuote).mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);

        (, uint256 netReceived) = PermanentV3Locker(record.locker).collect();
        assertEq(netReceived, 90 ether);
        assertEq(PermanentV3Locker(record.locker).claimable(creator, taxedQuote), 63 ether);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, taxedQuote), 27 ether);

        vm.prank(creator);
        PermanentV3Locker(record.locker).claim(taxedQuote);
        assertEq(IERC20(taxedQuote).balanceOf(creator), (63 ether * 9) / 10);
    }

    function testSenderTaxedClaimCannotDebitOtherBeneficiary() external {
        address taxedQuote = address(type(uint160).max - 4);
        SenderTaxQuote implementation = new SenderTaxQuote();
        vm.etch(taxedQuote, address(implementation).code);
        ForkPareFactory.LaunchParams memory params = _params(bytes32("sender-taxed-claim"));
        params.quoteToken = taxedQuote;

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        positionManager.setPositionTokens(record.token, taxedQuote);
        SenderTaxQuote(taxedQuote).mint(address(positionManager), 110 ether);
        positionManager.setCollectAmounts(0, 100 ether);
        (, uint256 netReceived) = PermanentV3Locker(record.locker).collect();

        assertEq(netReceived, 100 ether);
        assertEq(PermanentV3Locker(record.locker).claimable(creator, taxedQuote), 70 ether);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, taxedQuote), 30 ether);

        vm.prank(creator);
        vm.expectRevert(PermanentV3Locker.BadBalanceDelta.selector);
        PermanentV3Locker(record.locker).claim(taxedQuote);

        assertEq(PermanentV3Locker(record.locker).claimable(creator, taxedQuote), 70 ether);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, taxedQuote), 30 ether);
        assertEq(IERC20(taxedQuote).balanceOf(record.locker), 100 ether);
    }

    function testFalseReturnQuoteCannotCreatePhantomClaims() external {
        address falseQuote = address(type(uint160).max - 3);
        FalseReturnQuote implementation = new FalseReturnQuote();
        vm.etch(falseQuote, address(implementation).code);
        ForkPareFactory.LaunchParams memory params = _params(bytes32("false-quote"));
        params.quoteToken = falseQuote;

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        positionManager.setPositionTokens(record.token, falseQuote);
        FalseReturnQuote(falseQuote).mint(address(positionManager), 100 ether);
        positionManager.setCollectAmounts(0, 100 ether);

        (, uint256 netReceived) = PermanentV3Locker(record.locker).collect();
        assertEq(netReceived, 0);
        assertEq(PermanentV3Locker(record.locker).claimable(creator, falseQuote), 0);
        assertEq(PermanentV3Locker(record.locker).claimable(treasury, falseQuote), 0);
    }

    function testBurnsOnlyBoundedV3RoundingDust() external {
        uint256 allowedDust = SUPPLY / launchFactory.MAX_DUST_DIVISOR();
        positionManager.setMintDust(allowedDust);
        ForkPareFactory.LaunchParams memory params = _params(bytes32("dust"));

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        assertEq(record.supply, SUPPLY - allowedDust);
        assertEq(ForkPareToken(record.token).totalSupply(), record.supply);
        assertEq(ForkPareToken(record.token).balanceOf(record.pool), record.supply);
        assertEq(ForkPareToken(record.token).balanceOf(address(launchFactory)), 0);
    }

    function testBurnsBoundedV3RoundingDustWhenLaunchTokenIsToken1() external {
        address lowQuote = address(0x1000);
        MockERC20 implementation = new MockERC20();
        vm.etch(lowQuote, address(implementation).code);

        uint256 allowedDust = SUPPLY / launchFactory.MAX_DUST_DIVISOR();
        positionManager.setMintDust(allowedDust);
        ForkPareFactory.LaunchParams memory params = ForkPareFactory.LaunchParams({
            name: "Fork Reverse Market",
            symbol: "RFORK",
            supply: SUPPLY,
            quoteToken: lowQuote,
            feeTier: 500,
            sqrtPriceX96: uint160(1 << 96),
            tickLower: -100,
            tickUpper: -10,
            deadline: block.timestamp + 1 hours,
            userSalt: bytes32("reverse-dust")
        });
        assertGt(
            uint256(uint160(launchFactory.predictToken(creator, params))),
            uint256(uint160(lowQuote))
        );

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        assertEq(record.supply, SUPPLY - allowedDust);
        assertEq(ForkPareToken(record.token).totalSupply(), record.supply);
        assertEq(ForkPareToken(record.token).balanceOf(record.pool), record.supply);
    }

    function testRejectsSupplyBelowDustSafetyFloor() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("small-supply"));
        params.supply = launchFactory.MIN_SUPPLY() - 1;

        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.BadSupply.selector);
        launchFactory.launch{ value: CREATION_FEE }(params);
    }

    function testRejectsMaterialLiquidityUnderconsumption() external {
        uint256 allowedDust = SUPPLY / launchFactory.MAX_DUST_DIVISOR();
        positionManager.setMintDust(allowedDust + 1);
        ForkPareFactory.LaunchParams memory params = _params(bytes32("too-much-dust"));

        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.ExcessiveLiquidityDust.selector);
        launchFactory.launch{ value: CREATION_FEE }(params);
    }

    function testAcceptsPrecreatedCanonicalUninitializedPool() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("blocked"));
        address predicted = launchFactory.predictToken(creator, params);
        pancakeFactory.createPool(predicted, quote, params.feeTier);

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);
        assertEq(record.token, predicted);
    }

    function testSkipsSquattedPoolAtConflictingPrice() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("wrong-price"));
        address squatted = launchFactory.predictToken(creator, params);
        address pool = pancakeFactory.createPool(squatted, quote, params.feeTier);
        MockPool(pool).setState(uint160(1 << 95), 0, 0);

        address replacement = launchFactory.predictToken(creator, params);
        assertNotEq(replacement, squatted);

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        assertEq(record.token, replacement);
        assertNotEq(record.pool, pool);
        assertEq(squatted.code.length, 0);
    }

    function testSkipsPreinitializedPoolAtExactPriceWithZeroActiveLiquidity() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("same-price-no-liquidity"));
        address squatted = launchFactory.predictToken(creator, params);
        address pool = pancakeFactory.createPool(squatted, quote, params.feeTier);
        MockPool(pool).setState(params.sqrtPriceX96, 0, 0);

        address replacement = launchFactory.predictToken(creator, params);
        assertNotEq(replacement, squatted);

        vm.prank(creator);
        ForkPareFactory.LaunchRecord memory record =
            launchFactory.launch{ value: CREATION_FEE }(params);

        assertEq(record.token, replacement);
        assertNotEq(record.pool, pool);
        assertEq(squatted.code.length, 0);
    }

    function testRevertsWhenAllSaltCandidatesAreSquatted() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("exhausted"));

        for (uint256 i; i < launchFactory.MAX_SALT_CANDIDATES(); ++i) {
            address predicted = launchFactory.predictToken(creator, params);
            address pool = pancakeFactory.createPool(predicted, quote, params.feeTier);
            MockPool(pool).setState(uint160(1 << 95), 0, 0);
        }

        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.NoLaunchableSalt.selector);
        launchFactory.launch{ value: CREATION_FEE }(params);
    }

    function testRejectsWrongOneSidedOrientation() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("orientation"));
        pancakeFactory.setNextTick(20);

        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.BadOrientation.selector);
        launchFactory.launch{ value: CREATION_FEE }(params);
    }

    function testRejectsUnsupportedFeeTierAndExpiredDeadline() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("bad-tier"));
        params.feeTier = 123;
        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.BadFeeTier.selector);
        launchFactory.launch{ value: CREATION_FEE }(params);

        params = _params(bytes32("expired"));
        params.deadline = block.timestamp - 1;
        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.DeadlineExpired.selector);
        launchFactory.launch{ value: CREATION_FEE }(params);
    }

    function testOnlyTreasuryWithdrawsCreationFees() external {
        ForkPareFactory.LaunchParams memory params = _params(bytes32("native-fee"));
        vm.prank(creator);
        launchFactory.launch{ value: CREATION_FEE }(params);

        vm.prank(creator);
        vm.expectRevert(ForkPareFactory.NotTreasury.selector);
        launchFactory.withdrawCreationFees(payable(creator));

        uint256 beforeBalance = treasury.balance;
        vm.prank(treasury);
        launchFactory.withdrawCreationFees(payable(treasury));
        assertEq(treasury.balance - beforeBalance, CREATION_FEE);
    }

    function _params(bytes32 salt)
        internal
        view
        returns (ForkPareFactory.LaunchParams memory params)
    {
        params = ForkPareFactory.LaunchParams({
            name: "Fork Market",
            symbol: "FORK",
            supply: SUPPLY,
            quoteToken: quote,
            feeTier: 500,
            sqrtPriceX96: uint160(1 << 96),
            tickLower: 10,
            tickUpper: 100,
            deadline: block.timestamp + 1 hours,
            userSalt: salt
        });
    }
}
