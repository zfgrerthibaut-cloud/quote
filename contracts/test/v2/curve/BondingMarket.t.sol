// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import { BondingMarket } from "../../../src/v2/curve/BondingMarket.sol";
import { QuoteV2FeePolicy, TokenMode, V2FeeConfig } from "../../../src/v2/QuoteV2Types.sol";

contract CurveMockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TaxedQuoteToken is CurveMockERC20 {
    constructor() CurveMockERC20("Taxed Quote", "TAX") { }

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

contract CurveSenderTaxQuote is CurveMockERC20 {
    constructor() CurveMockERC20("Sender Tax Quote", "CSTAX") { }

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

contract ReenteringQuoteToken is CurveMockERC20 {
    address public target;
    bytes public payload;
    bool public armed;

    constructor() CurveMockERC20("Reentering Quote", "REQUOTE") { }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (armed && from != address(0) && to == target && value != 0) {
            armed = false;
            (bool ok, bytes memory revertData) = target.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(revertData, 0x20), mload(revertData))
                }
            }
        }
    }
}

contract BondingMarketTest is Test {
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant VIRTUAL_QUOTE_RESERVE = 1_000_000 ether;
    uint256 internal constant GRADUATION_THRESHOLD = 500_000 ether;
    bytes32 internal constant POOL_ID = keccak256("curve-pool");

    address internal factory = makeAddr("factory");
    address internal platform = makeAddr("platform");
    address internal creator = makeAddr("creator");
    address internal reward = makeAddr("reward");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal quoteReceiver = makeAddr("quoteReceiver");
    address internal tokenReceiver = makeAddr("tokenReceiver");

    CurveMockERC20 internal quote;
    CurveMockERC20 internal launchedToken;
    BondingMarket internal market;

    function setUp() external {
        quote = new CurveMockERC20("Quote", "QUOTE");
        launchedToken = new CurveMockERC20("Quote V2 Launch", "LAUNCH");
        market = _deployInitializedMarket(
            launchedToken, quote, TokenMode.REWARD, _rewardFeeConfig(), GRADUATION_THRESHOLD
        );
    }

    function testInitializeStoresFeeConfigAndPullsLaunchSupply() external {
        BondingMarket.FeeConfigView memory config = market.feeConfig();

        assertEq(uint256(config.tokenMode), uint256(TokenMode.REWARD));
        assertEq(config.platformSwapFeeBps, 25);
        assertEq(config.creatorSwapFeeBps, 100);
        assertEq(config.rewardFeeBps, 300);
        assertEq(config.creatorLpShareBps, 7_000);
        assertEq(config.totalSwapFeeBps, 425);
        assertEq(config.platformRecipient, platform);
        assertEq(config.creatorRecipient, creator);
        assertEq(config.rewardRecipient, reward);
        assertEq(address(market.launchedToken()), address(launchedToken));
        assertEq(address(market.quoteToken()), address(quote));
        assertEq(market.poolId(), POOL_ID);
        assertEq(uint256(market.state()), uint256(BondingMarket.MarketState.Trading));
        assertEq(market.tokenReserve(), SUPPLY);
        assertEq(launchedToken.balanceOf(address(market)), SUPPLY);
        assertTrue(market.isPoolEnabled(POOL_ID, address(launchedToken), address(quote)));

        vm.startPrank(factory);
        launchedToken.approve(address(market), SUPPLY);
        vm.expectRevert(BondingMarket.AlreadyInitialized.selector);
        market.initialize(
            BondingMarket.InitParams({
                poolId: POOL_ID,
                launchedToken: address(launchedToken),
                quoteToken: address(quote),
                tokenAmount: SUPPLY
            })
        );
        vm.stopPrank();
    }

    function testRejectsNonFactoryInitializeAndInvalidSharedFeeModes() external {
        BondingMarket uninitialized = new BondingMarket(
            factory,
            platform,
            creator,
            address(0),
            TokenMode.STANDARD,
            _standardFeeConfig(),
            VIRTUAL_QUOTE_RESERVE,
            GRADUATION_THRESHOLD
        );

        vm.expectRevert(BondingMarket.NotFactory.selector);
        uninitialized.initialize(
            BondingMarket.InitParams({
                poolId: POOL_ID,
                launchedToken: address(launchedToken),
                quoteToken: address(quote),
                tokenAmount: SUPPLY
            })
        );

        V2FeeConfig memory invalidStandard =
            V2FeeConfig({ creatorSwapFeeBps: 0, rewardFeeBps: 1, creatorLpShareBps: 0 });
        vm.expectRevert(QuoteV2FeePolicy.RewardFeeForbidden.selector);
        new BondingMarket(
            factory,
            platform,
            creator,
            reward,
            TokenMode.STANDARD,
            invalidStandard,
            VIRTUAL_QUOTE_RESERVE,
            GRADUATION_THRESHOLD
        );

        V2FeeConfig memory invalidReward =
            V2FeeConfig({ creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 0 });
        vm.expectRevert(QuoteV2FeePolicy.RewardFeeRequired.selector);
        new BondingMarket(
            factory,
            platform,
            creator,
            reward,
            TokenMode.REWARD,
            invalidReward,
            VIRTUAL_QUOTE_RESERVE,
            GRADUATION_THRESHOLD
        );
    }

    function testBuyUsesNetQuoteFeesAndDocumentedCeilRounding() external {
        uint256 grossQuoteIn = 100 ether;
        ExpectedBuy memory expected = _expectedBuy(0, SUPPLY, grossQuoteIn, 425);

        BondingMarket.BuyQuote memory quoted = market.quoteBuy(grossQuoteIn);
        assertEq(quoted.grossQuoteIn, grossQuoteIn);
        assertEq(quoted.feeAmount, expected.feeAmount);
        assertEq(quoted.netQuoteIn, expected.netQuoteIn);
        assertEq(quoted.tokenAmountOut, expected.tokenAmountOut);
        assertEq(quoted.quoteReserveAfter, expected.quoteReserveAfter);
        assertEq(quoted.tokenReserveAfter, expected.tokenReserveAfter);

        _mintAndApproveQuote(buyer, grossQuoteIn);
        vm.prank(buyer);
        (uint256 quoteAmountReceived, uint256 tokenAmountOut) =
            market.buy(grossQuoteIn, expected.tokenAmountOut, buyer, block.timestamp + 1 hours);

        assertEq(quoteAmountReceived, grossQuoteIn);
        assertEq(tokenAmountOut, expected.tokenAmountOut);
        assertEq(launchedToken.balanceOf(buyer), expected.tokenAmountOut);
        assertEq(market.quoteReserve(), expected.netQuoteIn);
        assertEq(market.tokenReserve(), expected.tokenReserveAfter);
        assertEq(market.feeReserve(), expected.feeAmount);
        assertEq(market.claimableFees(platform), 0.25 ether);
        assertEq(market.claimableFees(creator), 1 ether);
        assertEq(market.claimableFees(reward), 3 ether);
        assertEq(quote.balanceOf(address(market)), grossQuoteIn);
    }

    function testTinyBuyUsesCeilFeeSoFragmentsCannotAvoidFees() external view {
        BondingMarket.BuyQuote memory quoted = market.quoteBuy(23);

        assertEq(quoted.grossQuoteIn, 23);
        assertEq(quoted.feeAmount, 1);
        assertEq(quoted.netQuoteIn, 22);
        assertGt(quoted.tokenAmountOut, 0);
    }

    function testTinyBuyRevertsWhenCeilFeeConsumesInput() external {
        vm.expectRevert(BondingMarket.InsufficientOutput.selector);
        market.quoteBuy(1);
    }

    function testSellAddsNetTokenInputAndDeductsQuoteFeesFromOutput() external {
        uint256 buyAmount = 250 ether;
        ExpectedBuy memory expectedBuy = _expectedBuy(0, SUPPLY, buyAmount, 425);
        _buy(buyer, buyAmount, expectedBuy.tokenAmountOut);

        uint256 tokenAmountIn = expectedBuy.tokenAmountOut / 2;
        ExpectedSell memory expectedSell = _expectedSell(
            expectedBuy.quoteReserveAfter, expectedBuy.tokenReserveAfter, tokenAmountIn, 425
        );

        vm.startPrank(buyer);
        launchedToken.approve(address(market), tokenAmountIn);
        (uint256 tokenAmountReceived, uint256 quoteAmountOut) =
            market.sell(tokenAmountIn, expectedSell.netQuoteOut, buyer, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(tokenAmountReceived, tokenAmountIn);
        assertEq(quoteAmountOut, expectedSell.netQuoteOut);
        assertEq(market.quoteReserve(), expectedSell.quoteReserveAfter);
        assertEq(market.tokenReserve(), expectedSell.tokenReserveAfter);
        assertEq(market.feeReserve(), expectedBuy.feeAmount + expectedSell.feeAmount, "fee reserve");
        assertEq(quote.balanceOf(buyer), expectedSell.netQuoteOut);
    }

    function testFeeOnTransferQuoteUsesReceivedBalanceDeltaOnBuy() external {
        TaxedQuoteToken taxedQuote = new TaxedQuoteToken();
        CurveMockERC20 token = new CurveMockERC20("Taxed Launch", "TLAUNCH");
        BondingMarket taxedMarket = _deployInitializedMarket(
            token, taxedQuote, TokenMode.STANDARD, _standardFeeConfig(), GRADUATION_THRESHOLD
        );

        uint256 transferAmount = 100 ether;
        uint256 receivedByMarket = 90 ether;
        ExpectedBuy memory expected = _expectedBuy(0, SUPPLY, receivedByMarket, 125);

        taxedQuote.mint(buyer, transferAmount);
        vm.startPrank(buyer);
        taxedQuote.approve(address(taxedMarket), transferAmount);
        (uint256 quoteAmountReceived, uint256 tokenAmountOut) =
            taxedMarket.buy(transferAmount, expected.tokenAmountOut, buyer, block.timestamp + 1);
        vm.stopPrank();

        assertEq(quoteAmountReceived, receivedByMarket);
        assertEq(tokenAmountOut, expected.tokenAmountOut);
        assertEq(taxedMarket.quoteReserve(), expected.netQuoteIn);
        assertEq(taxedMarket.feeReserve(), expected.feeAmount);
        assertEq(taxedQuote.balanceOf(address(taxedMarket)), receivedByMarket);
    }

    function testClaimFeesRejectsSenderTaxedExtraDebitEvenWithSurplus() external {
        CurveSenderTaxQuote senderTaxedQuote = new CurveSenderTaxQuote();
        CurveMockERC20 token = new CurveMockERC20("Sender Taxed Launch", "STLAUNCH");
        BondingMarket taxedMarket = _deployInitializedMarket(
            token, senderTaxedQuote, TokenMode.STANDARD, _standardFeeConfig(), GRADUATION_THRESHOLD
        );

        uint256 grossQuoteIn = 100 ether;
        uint256 senderTax = grossQuoteIn / 10;
        senderTaxedQuote.mint(buyer, grossQuoteIn + senderTax);

        vm.startPrank(buyer);
        senderTaxedQuote.approve(address(taxedMarket), grossQuoteIn);
        taxedMarket.buy(grossQuoteIn, 0, buyer, block.timestamp + 1);
        vm.stopPrank();

        uint256 creatorClaim = taxedMarket.claimableFees(creator);
        assertEq(creatorClaim, 1 ether);

        senderTaxedQuote.mint(address(taxedMarket), 1 ether);
        uint256 balanceBefore = senderTaxedQuote.balanceOf(address(taxedMarket));

        vm.prank(creator);
        vm.expectRevert(BondingMarket.BadBalanceDelta.selector);
        taxedMarket.claimFees();

        assertEq(taxedMarket.claimableFees(creator), creatorClaim);
        assertEq(taxedMarket.feeReserve(), Math.mulDiv(grossQuoteIn, 125, 10_000));
        assertEq(senderTaxedQuote.balanceOf(address(taxedMarket)), balanceBefore);
    }

    function testFactoryOnlyPrepaidBuyConsumesUnaccountedQuoteDelta() external {
        uint256 prepaidAmount = 75 ether;
        ExpectedBuy memory expected = _expectedBuy(0, SUPPLY, prepaidAmount, 425);
        quote.mint(factory, prepaidAmount);

        vm.prank(factory);
        quote.transfer(address(market), prepaidAmount);

        BondingMarket.PrepaidBuyParams memory params = BondingMarket.PrepaidBuyParams({
            poolId: POOL_ID,
            launchedToken: address(launchedToken),
            quoteToken: address(quote),
            minTokenAmountOut: expected.tokenAmountOut,
            beneficiary: buyer,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(buyer);
        vm.expectRevert(BondingMarket.NotFactory.selector);
        market.prepaidBuy(params);

        vm.prank(factory);
        (uint256 quoteAmountIn, uint256 tokenAmountOut) = market.prepaidBuy(params);

        assertEq(quoteAmountIn, prepaidAmount);
        assertEq(tokenAmountOut, expected.tokenAmountOut);
        assertEq(launchedToken.balanceOf(buyer), expected.tokenAmountOut);
        assertEq(market.quoteReserve(), expected.netQuoteIn);
        assertEq(market.feeReserve(), expected.feeAmount);
    }

    function testRejectsExpiredDeadlineAndSlippage() external {
        vm.warp(100);
        _mintAndApproveQuote(buyer, 10 ether);

        vm.prank(buyer);
        vm.expectRevert(BondingMarket.DeadlineExpired.selector);
        market.buy(10 ether, 0, buyer, 99);

        ExpectedBuy memory expected = _expectedBuy(0, SUPPLY, 10 ether, 425);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                BondingMarket.Slippage.selector,
                expected.tokenAmountOut,
                expected.tokenAmountOut + 1
            )
        );
        market.buy(10 ether, expected.tokenAmountOut + 1, buyer, 101);
    }

    function testGraduationIsOneWayAndPrincipalOnlyLeavesAfterFactoryMark() external {
        CurveMockERC20 graduatingToken = new CurveMockERC20("Graduating Launch", "GLAUNCH");
        BondingMarket graduatingMarket = _deployInitializedMarket(
            graduatingToken, quote, TokenMode.REWARD, _rewardFeeConfig(), 50 ether
        );
        uint256 grossQuoteIn = 60 ether;
        ExpectedBuy memory expected = _expectedBuy(0, SUPPLY, grossQuoteIn, 425);

        vm.prank(factory);
        vm.expectRevert(BondingMarket.NotGraduationReady.selector);
        graduatingMarket.markGraduated();

        quote.mint(buyer, grossQuoteIn);
        vm.prank(buyer);
        quote.approve(address(graduatingMarket), grossQuoteIn);
        vm.prank(buyer);
        graduatingMarket.buy(grossQuoteIn, 0, buyer, block.timestamp + 1 hours);

        assertEq(
            uint256(graduatingMarket.state()), uint256(BondingMarket.MarketState.GraduationReady)
        );
        assertTrue(graduatingMarket.graduationReached());
        assertFalse(
            graduatingMarket.isPoolEnabled(POOL_ID, address(graduatingToken), address(quote))
        );

        vm.prank(buyer);
        vm.expectRevert(BondingMarket.NotTrading.selector);
        graduatingMarket.buy(1, 0, buyer, block.timestamp + 1);

        vm.prank(factory);
        vm.expectRevert(BondingMarket.NotGraduated.selector);
        graduatingMarket.takeGraduationReserves(quoteReceiver, tokenReceiver);

        vm.prank(buyer);
        vm.expectRevert(BondingMarket.NotFactory.selector);
        graduatingMarket.markGraduated();

        vm.prank(factory);
        graduatingMarket.markGraduated();
        assertEq(uint256(graduatingMarket.state()), uint256(BondingMarket.MarketState.Graduated));

        uint256 platformClaim = graduatingMarket.claimableFees(platform);
        vm.prank(factory);
        (uint256 quoteAmount, uint256 tokenAmount) =
            graduatingMarket.takeGraduationReserves(quoteReceiver, tokenReceiver);

        assertEq(quoteAmount, expected.netQuoteIn);
        assertEq(tokenAmount, expected.tokenReserveAfter);
        assertEq(quote.balanceOf(quoteReceiver), expected.netQuoteIn);
        assertEq(graduatingToken.balanceOf(tokenReceiver), expected.tokenReserveAfter);
        assertEq(graduatingMarket.quoteReserve(), 0);
        assertEq(graduatingMarket.tokenReserve(), 0);
        assertEq(graduatingMarket.feeReserve(), expected.feeAmount);
        assertEq(graduatingMarket.claimableFees(platform), platformClaim);

        vm.prank(factory);
        vm.expectRevert(BondingMarket.GraduationReservesAlreadyTaken.selector);
        graduatingMarket.takeGraduationReserves(quoteReceiver, tokenReceiver);
    }

    function testRejectsSellThatWouldUseVirtualQuoteAsRealLiquidity() external {
        launchedToken.mint(seller, SUPPLY);

        vm.startPrank(seller);
        launchedToken.approve(address(market), SUPPLY);
        vm.expectRevert(BondingMarket.InsufficientLiquidity.selector);
        market.sell(SUPPLY, 0, seller, block.timestamp + 1);
        vm.stopPrank();
    }

    function testReentrancyGuardBlocksQuoteTokenCallback() external {
        ReenteringQuoteToken reenteringQuote = new ReenteringQuoteToken();
        CurveMockERC20 token = new CurveMockERC20("Reentry Launch", "RLAUNCH");
        BondingMarket reentryMarket = _deployInitializedMarket(
            token, reenteringQuote, TokenMode.STANDARD, _standardFeeConfig(), GRADUATION_THRESHOLD
        );

        reenteringQuote.mint(buyer, 10 ether);
        reenteringQuote.arm(address(reentryMarket), abi.encodeCall(BondingMarket.claimFees, ()));

        vm.startPrank(buyer);
        reenteringQuote.approve(address(reentryMarket), 10 ether);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reentryMarket.buy(10 ether, 0, buyer, block.timestamp + 1);
        vm.stopPrank();
    }

    function testNoAdminPrincipalRescueSurface() external {
        _assertMissingSelector(
            address(market),
            "rescueTokens(address,address,uint256)",
            abi.encode(address(quote), platform, 1)
        );
        _assertMissingSelector(address(market), "withdrawPrincipal(address)", abi.encode(platform));
        _assertMissingSelector(address(market), "skim(address)", abi.encode(platform));
        _assertMissingSelector(address(market), "setFeeConfig(uint16,uint16)", abi.encode(1, 1));
    }

    function _buy(address user, uint256 quoteAmountIn, uint256 minTokenAmountOut) internal {
        _mintAndApproveQuote(user, quoteAmountIn);
        vm.prank(user);
        market.buy(quoteAmountIn, minTokenAmountOut, user, block.timestamp + 1 hours);
    }

    function _deployInitializedMarket(
        CurveMockERC20 token,
        CurveMockERC20 quoteToken,
        TokenMode mode,
        V2FeeConfig memory config,
        uint256 graduationThreshold
    ) internal returns (BondingMarket deployed) {
        deployed = new BondingMarket(
            factory,
            platform,
            creator,
            config.rewardFeeBps == 0 ? address(0) : reward,
            mode,
            config,
            VIRTUAL_QUOTE_RESERVE,
            graduationThreshold
        );
        token.mint(factory, SUPPLY);

        vm.startPrank(factory);
        token.approve(address(deployed), SUPPLY);
        deployed.initialize(
            BondingMarket.InitParams({
                poolId: POOL_ID,
                launchedToken: address(token),
                quoteToken: address(quoteToken),
                tokenAmount: SUPPLY
            })
        );
        vm.stopPrank();
    }

    function _mintAndApproveQuote(address user, uint256 amount) internal {
        quote.mint(user, amount);
        vm.prank(user);
        quote.approve(address(market), amount);
    }

    struct ExpectedBuy {
        uint256 feeAmount;
        uint256 netQuoteIn;
        uint256 tokenAmountOut;
        uint256 quoteReserveAfter;
        uint256 tokenReserveAfter;
    }

    struct ExpectedSell {
        uint256 grossQuoteOut;
        uint256 feeAmount;
        uint256 netQuoteOut;
        uint256 quoteReserveAfter;
        uint256 tokenReserveAfter;
    }

    function _expectedBuy(
        uint256 quoteReserve,
        uint256 tokenReserve,
        uint256 grossQuoteIn,
        uint256 feeBps
    ) internal pure returns (ExpectedBuy memory expected) {
        expected.feeAmount = Math.mulDiv(grossQuoteIn, feeBps, 10_000, Math.Rounding.Ceil);
        expected.netQuoteIn = grossQuoteIn - expected.feeAmount;
        uint256 x = VIRTUAL_QUOTE_RESERVE + quoteReserve;
        uint256 yAfter = Math.mulDiv(x, tokenReserve, x + expected.netQuoteIn, Math.Rounding.Ceil);
        expected.tokenAmountOut = tokenReserve - yAfter;
        expected.quoteReserveAfter = quoteReserve + expected.netQuoteIn;
        expected.tokenReserveAfter = yAfter;
    }

    function _expectedSell(
        uint256 quoteReserve,
        uint256 tokenReserve,
        uint256 tokenAmountIn,
        uint256 feeBps
    ) internal pure returns (ExpectedSell memory expected) {
        uint256 x = VIRTUAL_QUOTE_RESERVE + quoteReserve;
        uint256 xAfter =
            Math.mulDiv(x, tokenReserve, tokenReserve + tokenAmountIn, Math.Rounding.Ceil);
        expected.grossQuoteOut = x - xAfter;
        expected.feeAmount = Math.mulDiv(expected.grossQuoteOut, feeBps, 10_000, Math.Rounding.Ceil);
        expected.netQuoteOut = expected.grossQuoteOut - expected.feeAmount;
        expected.quoteReserveAfter = quoteReserve - expected.grossQuoteOut;
        expected.tokenReserveAfter = tokenReserve + tokenAmountIn;
    }

    function _rewardFeeConfig() internal pure returns (V2FeeConfig memory config) {
        config =
            V2FeeConfig({ creatorSwapFeeBps: 100, rewardFeeBps: 300, creatorLpShareBps: 7_000 });
    }

    function _standardFeeConfig() internal pure returns (V2FeeConfig memory config) {
        config = V2FeeConfig({ creatorSwapFeeBps: 100, rewardFeeBps: 0, creatorLpShareBps: 7_000 });
    }

    function _assertMissingSelector(address target, string memory signature, bytes memory args)
        internal
    {
        (bool ok,) = target.call(bytes.concat(abi.encodeWithSignature(signature), args));
        assertFalse(ok, signature);
    }
}

contract BondingMarketHandler is Test {
    uint256 internal constant MAX_BUY = 5_000 ether;

    BondingMarket public market;
    CurveMockERC20 public quote;
    CurveMockERC20 public launchedToken;
    address[4] public users;
    address public platform;
    address public creator;
    address public reward;

    constructor(
        BondingMarket market_,
        CurveMockERC20 quote_,
        CurveMockERC20 launchedToken_,
        address platform_,
        address creator_,
        address reward_
    ) {
        market = market_;
        quote = quote_;
        launchedToken = launchedToken_;
        platform = platform_;
        creator = creator_;
        reward = reward_;
        users = [
            address(uint160(uint256(keccak256("user-0")))),
            address(uint160(uint256(keccak256("user-1")))),
            address(uint160(uint256(keccak256("user-2")))),
            address(uint160(uint256(keccak256("user-3"))))
        ];
    }

    function buy(uint96 rawAmount, uint8 userSeed) external {
        if (market.state() != BondingMarket.MarketState.Trading) return;

        address user = users[userSeed % users.length];
        uint256 amount = bound(uint256(rawAmount), 1, MAX_BUY);

        quote.mint(user, amount);
        vm.startPrank(user);
        quote.approve(address(market), amount);
        try market.buy(amount, 0, user, block.timestamp + 1) { } catch { }
        vm.stopPrank();
    }

    function sell(uint96 rawAmount, uint8 userSeed) external {
        if (market.state() != BondingMarket.MarketState.Trading) return;

        address user = users[userSeed % users.length];
        uint256 balance = launchedToken.balanceOf(user);
        if (balance == 0) return;

        uint256 amount = bound(uint256(rawAmount), 1, balance);
        vm.startPrank(user);
        launchedToken.approve(address(market), amount);
        try market.sell(amount, 0, user, block.timestamp + 1) { } catch { }
        vm.stopPrank();
    }

    function claim(uint8 recipientSeed) external {
        address recipient = _feeRecipient(recipientSeed);
        vm.prank(recipient);
        try market.claimFees() { } catch { }
    }

    function _feeRecipient(uint8 seed) private view returns (address) {
        if (seed % 3 == 0) return platform;
        if (seed % 3 == 1) return creator;
        return reward;
    }
}

contract BondingMarketInvariantTest is Test {
    uint256 internal constant SUPPLY = 100_000 ether;
    uint256 internal constant VIRTUAL_QUOTE_RESERVE = 100_000 ether;
    bytes32 internal constant POOL_ID = keccak256("invariant-pool");

    address internal factory = makeAddr("factory");
    address internal platform = makeAddr("platform");
    address internal creator = makeAddr("creator");
    address internal reward = makeAddr("reward");

    CurveMockERC20 internal quote;
    CurveMockERC20 internal launchedToken;
    BondingMarket internal market;

    function setUp() external {
        quote = new CurveMockERC20("Invariant Quote", "IQUOTE");
        launchedToken = new CurveMockERC20("Invariant Launch", "ILAUNCH");
        V2FeeConfig memory config =
            V2FeeConfig({ creatorSwapFeeBps: 100, rewardFeeBps: 300, creatorLpShareBps: 0 });

        market = new BondingMarket(
            factory,
            platform,
            creator,
            reward,
            TokenMode.REWARD,
            config,
            VIRTUAL_QUOTE_RESERVE,
            50_000 ether
        );
        launchedToken.mint(factory, SUPPLY);

        vm.startPrank(factory);
        launchedToken.approve(address(market), SUPPLY);
        market.initialize(
            BondingMarket.InitParams({
                poolId: POOL_ID,
                launchedToken: address(launchedToken),
                quoteToken: address(quote),
                tokenAmount: SUPPLY
            })
        );
        vm.stopPrank();

        BondingMarketHandler handler =
            new BondingMarketHandler(market, quote, launchedToken, platform, creator, reward);
        targetContract(address(handler));
    }

    function invariantQuoteAccountingIsBackedByBalance() external view {
        assertGe(quote.balanceOf(address(market)), market.quoteReserve() + market.feeReserve());
    }

    function invariantTokenReserveIsBackedByBalance() external view {
        assertGe(launchedToken.balanceOf(address(market)), market.tokenReserve());
    }

    function invariantFeeReserveEqualsClaimableRecipients() external view {
        assertEq(
            market.feeReserve(),
            market.claimableFees(platform) + market.claimableFees(creator)
                + market.claimableFees(reward)
        );
    }

    function invariantConstantProductNeverDecreases() external view {
        uint256 currentProduct =
            (VIRTUAL_QUOTE_RESERVE + market.quoteReserve()) * market.tokenReserve();
        assertGe(currentProduct, VIRTUAL_QUOTE_RESERVE * SUPPLY);
    }

    function invariantLaunchTokenSupplyIsFixed() external view {
        assertEq(launchedToken.totalSupply(), SUPPLY);
    }
}
