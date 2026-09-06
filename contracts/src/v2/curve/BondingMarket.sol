// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import { QuoteV2FeePolicy, TokenMode, V2FeeConfig } from "../QuoteV2Types.sol";

/// @notice Per-launch constant-product bonding market for fixed-supply QUOTE V2 tokens.
/// @dev Rounding is trader-conservative:
///      buy tokenOut = tokenReserve - ceil((virtualQuoteReserve + quoteReserve) * tokenReserve
///      / (virtualQuoteReserve + quoteReserve + netQuoteIn)).
///      sell grossQuoteOut = (virtualQuoteReserve + quoteReserve)
///      - ceil((virtualQuoteReserve + quoteReserve) * tokenReserve
///      / (tokenReserve + tokenIn)).
///      Fees are quote-denominated. Buy fees are charged on quote actually received. Sell fees
///      are deducted from gross quote output. Total fees round up so fragmented trades cannot
///      bypass sub-BPS fees; per-recipient floors assign residue to the platform recipient.
contract BondingMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum MarketState {
        Uninitialized,
        Trading,
        GraduationReady,
        Graduated
    }

    struct InitParams {
        bytes32 poolId;
        address launchedToken;
        address quoteToken;
        uint256 tokenAmount;
    }

    struct PrepaidBuyParams {
        bytes32 poolId;
        address launchedToken;
        address quoteToken;
        uint256 minTokenAmountOut;
        address beneficiary;
        uint256 deadline;
    }

    struct BuyQuote {
        uint256 grossQuoteIn;
        uint256 feeAmount;
        uint256 netQuoteIn;
        uint256 tokenAmountOut;
        uint256 quoteReserveAfter;
        uint256 tokenReserveAfter;
        bool reachesGraduation;
    }

    struct SellQuote {
        uint256 tokenAmountIn;
        uint256 grossQuoteOut;
        uint256 feeAmount;
        uint256 netQuoteOut;
        uint256 quoteReserveAfter;
        uint256 tokenReserveAfter;
    }

    struct FeeConfigView {
        TokenMode tokenMode;
        uint16 platformSwapFeeBps;
        uint16 creatorSwapFeeBps;
        uint16 rewardFeeBps;
        uint16 creatorLpShareBps;
        uint16 totalSwapFeeBps;
        address platformRecipient;
        address creatorRecipient;
        address rewardRecipient;
    }

    address public immutable factory;
    address public immutable platformRecipient;
    address public immutable creatorRecipient;
    address public immutable rewardRecipient;
    TokenMode public immutable tokenMode;
    uint16 public immutable creatorSwapFeeBps;
    uint16 public immutable rewardFeeBps;
    uint16 public immutable creatorLpShareBps;
    uint16 public immutable totalSwapFeeBps;
    uint256 public immutable virtualQuoteReserve;
    uint256 public immutable graduationQuoteThreshold;

    IERC20 public launchedToken;
    IERC20 public quoteToken;
    bytes32 public poolId;
    MarketState public state;
    uint256 public quoteReserve;
    uint256 public tokenReserve;
    uint256 public feeReserve;
    bool public graduationReservesTaken;

    mapping(address recipient => uint256 amount) public claimableFees;

    error InvalidConfiguration();
    error AlreadyInitialized();
    error NotFactory();
    error NotTrading();
    error NotGraduationReady();
    error NotGraduated();
    error GraduationReservesAlreadyTaken();
    error DeadlineExpired();
    error BadBeneficiary();
    error BadAsset();
    error BadAmount();
    error BadBalanceDelta();
    error InsufficientLiquidity();
    error InsufficientOutput();
    error Slippage(uint256 amountOut, uint256 minAmountOut);

    event MarketInitialized(
        bytes32 indexed poolId,
        address indexed launchedToken,
        address indexed quoteToken,
        uint256 tokenReserve,
        uint256 virtualQuoteReserve,
        uint256 graduationQuoteThreshold
    );
    event Bought(
        address indexed buyer,
        address indexed beneficiary,
        uint256 grossQuoteIn,
        uint256 feeAmount,
        uint256 netQuoteIn,
        uint256 tokenAmountOut,
        uint256 quoteReserveAfter,
        uint256 tokenReserveAfter
    );
    event Sold(
        address indexed seller,
        address indexed beneficiary,
        uint256 tokenAmountIn,
        uint256 grossQuoteOut,
        uint256 feeAmount,
        uint256 quoteAmountSent,
        uint256 quoteAmountOut,
        uint256 quoteReserveAfter,
        uint256 tokenReserveAfter
    );
    event GraduationReady(uint256 quoteReserve, uint256 tokenReserve);
    event MarketGraduated(uint256 quoteReserve, uint256 tokenReserve);
    event GraduationReservesTaken(
        address indexed quoteReceiver,
        address indexed tokenReceiver,
        uint256 quoteAmount,
        uint256 tokenAmount
    );
    event FeesClaimed(address indexed recipient, address indexed quoteToken, uint256 amount);

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    constructor(
        address factory_,
        address platformRecipient_,
        address creatorRecipient_,
        address rewardRecipient_,
        TokenMode tokenMode_,
        V2FeeConfig memory feeConfig_,
        uint256 virtualQuoteReserve_,
        uint256 graduationQuoteThreshold_
    ) {
        QuoteV2FeePolicy.validate(tokenMode_, feeConfig_);
        if (
            factory_ == address(0) || platformRecipient_ == address(0) || virtualQuoteReserve_ == 0
                || graduationQuoteThreshold_ == 0
                || (feeConfig_.creatorSwapFeeBps != 0 && creatorRecipient_ == address(0))
                || (feeConfig_.rewardFeeBps != 0 && rewardRecipient_ == address(0))
        ) revert InvalidConfiguration();

        factory = factory_;
        platformRecipient = platformRecipient_;
        creatorRecipient = creatorRecipient_;
        rewardRecipient = rewardRecipient_;
        tokenMode = tokenMode_;
        creatorSwapFeeBps = feeConfig_.creatorSwapFeeBps;
        rewardFeeBps = feeConfig_.rewardFeeBps;
        creatorLpShareBps = feeConfig_.creatorLpShareBps;
        totalSwapFeeBps = QuoteV2FeePolicy.hookFeeBps(feeConfig_);
        virtualQuoteReserve = virtualQuoteReserve_;
        graduationQuoteThreshold = graduationQuoteThreshold_;
    }

    function initialize(InitParams calldata params) external nonReentrant onlyFactory {
        if (state != MarketState.Uninitialized) revert AlreadyInitialized();
        if (
            params.poolId == bytes32(0) || params.launchedToken == address(0)
                || params.quoteToken == address(0) || params.launchedToken == params.quoteToken
                || params.tokenAmount == 0 || params.launchedToken.code.length == 0
                || params.quoteToken.code.length == 0
        ) revert BadAsset();

        IERC20 launch = IERC20(params.launchedToken);
        uint256 balanceBefore = launch.balanceOf(address(this));
        launch.safeTransferFrom(msg.sender, address(this), params.tokenAmount);
        uint256 balanceAfter = launch.balanceOf(address(this));
        if (balanceAfter <= balanceBefore || balanceAfter - balanceBefore != params.tokenAmount) {
            revert BadBalanceDelta();
        }

        poolId = params.poolId;
        launchedToken = launch;
        quoteToken = IERC20(params.quoteToken);
        tokenReserve = params.tokenAmount;
        state = MarketState.Trading;

        emit MarketInitialized(
            params.poolId,
            params.launchedToken,
            params.quoteToken,
            params.tokenAmount,
            virtualQuoteReserve,
            graduationQuoteThreshold
        );
    }

    function feeConfig() external view returns (FeeConfigView memory config) {
        config = FeeConfigView({
            tokenMode: tokenMode,
            platformSwapFeeBps: QuoteV2FeePolicy.PLATFORM_SWAP_FEE_BPS,
            creatorSwapFeeBps: creatorSwapFeeBps,
            rewardFeeBps: rewardFeeBps,
            creatorLpShareBps: creatorLpShareBps,
            totalSwapFeeBps: totalSwapFeeBps,
            platformRecipient: platformRecipient,
            creatorRecipient: creatorRecipient,
            rewardRecipient: rewardRecipient
        });
    }

    function isPoolEnabled(bytes32 requestedPoolId, address launchedToken_, address quoteToken_)
        external
        view
        returns (bool)
    {
        return state == MarketState.Trading && requestedPoolId == poolId
            && address(launchedToken) == launchedToken_ && address(quoteToken) == quoteToken_;
    }

    function graduationReached() public view returns (bool) {
        return state == MarketState.GraduationReady || state == MarketState.Graduated
            || quoteReserve >= graduationQuoteThreshold;
    }

    function quoteBuy(uint256 grossQuoteIn) external view returns (BuyQuote memory quoted) {
        _ensureTrading();
        return _quoteBuy(grossQuoteIn);
    }

    function quoteSell(uint256 tokenAmountIn) external view returns (SellQuote memory quoted) {
        _ensureTrading();
        return _quoteSell(tokenAmountIn);
    }

    function buy(
        uint256 quoteAmountIn,
        uint256 minTokenAmountOut,
        address beneficiary,
        uint256 deadline
    ) external nonReentrant returns (uint256 quoteAmountReceived, uint256 tokenAmountOut) {
        _validateTrade(beneficiary, deadline);
        if (quoteAmountIn == 0) revert BadAmount();

        uint256 quoteBalanceBefore = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), quoteAmountIn);
        uint256 quoteBalanceAfter = quoteToken.balanceOf(address(this));
        if (quoteBalanceAfter <= quoteBalanceBefore) revert BadBalanceDelta();

        quoteAmountReceived = quoteBalanceAfter - quoteBalanceBefore;
        tokenAmountOut =
            _executeBuy(msg.sender, beneficiary, quoteAmountReceived, minTokenAmountOut);
    }

    /// @notice Uses quote already transferred into this market, intended for factory-led dev buys.
    function prepaidBuy(PrepaidBuyParams calldata params)
        external
        nonReentrant
        onlyFactory
        returns (uint256 quoteAmountIn, uint256 tokenAmountOut)
    {
        _validatePool(params.poolId, params.launchedToken, params.quoteToken);
        _validateTrade(params.beneficiary, params.deadline);

        uint256 quoteBalance = quoteToken.balanceOf(address(this));
        uint256 accounted = _accountedQuoteBalance();
        if (quoteBalance <= accounted) revert BadBalanceDelta();

        quoteAmountIn = quoteBalance - accounted;
        tokenAmountOut =
            _executeBuy(msg.sender, params.beneficiary, quoteAmountIn, params.minTokenAmountOut);
    }

    function sell(
        uint256 tokenAmountIn,
        uint256 minQuoteAmountOut,
        address beneficiary,
        uint256 deadline
    ) external nonReentrant returns (uint256 tokenAmountReceived, uint256 quoteAmountOut) {
        _validateTrade(beneficiary, deadline);
        if (tokenAmountIn == 0) revert BadAmount();

        uint256 tokenBalanceBefore = launchedToken.balanceOf(address(this));
        launchedToken.safeTransferFrom(msg.sender, address(this), tokenAmountIn);
        uint256 tokenBalanceAfter = launchedToken.balanceOf(address(this));
        if (tokenBalanceAfter <= tokenBalanceBefore) revert BadBalanceDelta();

        tokenAmountReceived = tokenBalanceAfter - tokenBalanceBefore;
        SellQuote memory quoted = _quoteSell(tokenAmountReceived);
        if (quoted.netQuoteOut == 0) revert InsufficientOutput();

        quoteReserve = quoted.quoteReserveAfter;
        tokenReserve = quoted.tokenReserveAfter;
        _accrueFees(quoted.grossQuoteOut, quoted.feeAmount);

        uint256 beneficiaryBalanceBefore = quoteToken.balanceOf(beneficiary);
        quoteToken.safeTransfer(beneficiary, quoted.netQuoteOut);
        uint256 beneficiaryBalanceAfter = quoteToken.balanceOf(beneficiary);
        if (beneficiaryBalanceAfter < beneficiaryBalanceBefore) revert BadBalanceDelta();

        quoteAmountOut = beneficiaryBalanceAfter - beneficiaryBalanceBefore;
        if (quoteAmountOut < minQuoteAmountOut) {
            revert Slippage(quoteAmountOut, minQuoteAmountOut);
        }
        _assertQuoteBacking();

        emit Sold(
            msg.sender,
            beneficiary,
            tokenAmountReceived,
            quoted.grossQuoteOut,
            quoted.feeAmount,
            quoted.netQuoteOut,
            quoteAmountOut,
            quoted.quoteReserveAfter,
            quoted.tokenReserveAfter
        );
    }

    function markGraduated() external nonReentrant onlyFactory {
        if (state != MarketState.GraduationReady) revert NotGraduationReady();
        if (quoteReserve < graduationQuoteThreshold) revert NotGraduationReady();

        state = MarketState.Graduated;
        emit MarketGraduated(quoteReserve, tokenReserve);
    }

    function takeGraduationReserves(address quoteReceiver, address tokenReceiver)
        external
        nonReentrant
        onlyFactory
        returns (uint256 quoteAmount, uint256 tokenAmount)
    {
        if (state != MarketState.Graduated) revert NotGraduated();
        if (graduationReservesTaken) revert GraduationReservesAlreadyTaken();
        if (
            quoteReceiver == address(0) || tokenReceiver == address(0)
                || quoteReceiver == address(this) || tokenReceiver == address(this)
        ) revert BadBeneficiary();
        if (quoteReserve < graduationQuoteThreshold) revert NotGraduated();
        _assertQuoteBacking();
        if (launchedToken.balanceOf(address(this)) < tokenReserve) revert BadBalanceDelta();

        quoteAmount = quoteReserve;
        tokenAmount = tokenReserve;
        quoteReserve = 0;
        tokenReserve = 0;
        graduationReservesTaken = true;

        if (quoteAmount != 0) quoteToken.safeTransfer(quoteReceiver, quoteAmount);
        if (tokenAmount != 0) launchedToken.safeTransfer(tokenReceiver, tokenAmount);
        _assertQuoteBacking();

        emit GraduationReservesTaken(quoteReceiver, tokenReceiver, quoteAmount, tokenAmount);
    }

    function claimFees() external nonReentrant returns (uint256 amount) {
        amount = claimableFees[msg.sender];
        claimableFees[msg.sender] = 0;
        if (amount != 0) {
            uint256 balanceBefore = quoteToken.balanceOf(address(this));
            feeReserve -= amount;
            quoteToken.safeTransfer(msg.sender, amount);
            if (
                balanceBefore < amount
                    || quoteToken.balanceOf(address(this)) != balanceBefore - amount
            ) revert BadBalanceDelta();
            _assertQuoteBacking();
        }
        emit FeesClaimed(msg.sender, address(quoteToken), amount);
    }

    function _executeBuy(
        address buyer,
        address beneficiary,
        uint256 grossQuoteIn,
        uint256 minTokenAmountOut
    ) private returns (uint256 tokenAmountOut) {
        BuyQuote memory quoted = _quoteBuy(grossQuoteIn);
        if (quoted.tokenAmountOut == 0) revert InsufficientOutput();

        quoteReserve = quoted.quoteReserveAfter;
        tokenReserve = quoted.tokenReserveAfter;
        _accrueFees(grossQuoteIn, quoted.feeAmount);

        uint256 beneficiaryBalanceBefore = launchedToken.balanceOf(beneficiary);
        launchedToken.safeTransfer(beneficiary, quoted.tokenAmountOut);
        uint256 beneficiaryBalanceAfter = launchedToken.balanceOf(beneficiary);
        if (beneficiaryBalanceAfter < beneficiaryBalanceBefore) revert BadBalanceDelta();

        tokenAmountOut = beneficiaryBalanceAfter - beneficiaryBalanceBefore;
        if (tokenAmountOut != quoted.tokenAmountOut) revert BadBalanceDelta();
        if (tokenAmountOut < minTokenAmountOut) revert Slippage(tokenAmountOut, minTokenAmountOut);
        if (launchedToken.balanceOf(address(this)) < tokenReserve) revert BadBalanceDelta();
        _assertQuoteBacking();

        if (quoted.reachesGraduation) {
            state = MarketState.GraduationReady;
            emit GraduationReady(quoted.quoteReserveAfter, quoted.tokenReserveAfter);
        }

        emit Bought(
            buyer,
            beneficiary,
            grossQuoteIn,
            quoted.feeAmount,
            quoted.netQuoteIn,
            tokenAmountOut,
            quoted.quoteReserveAfter,
            quoted.tokenReserveAfter
        );
    }

    function _quoteBuy(uint256 grossQuoteIn) private view returns (BuyQuote memory quoted) {
        _ensureTrading();
        if (grossQuoteIn == 0) revert BadAmount();

        uint256 feeAmount = _feeAmount(grossQuoteIn);
        uint256 netQuoteIn = grossQuoteIn - feeAmount;
        if (netQuoteIn == 0) revert InsufficientOutput();

        uint256 x = virtualQuoteReserve + quoteReserve;
        uint256 y = tokenReserve;
        uint256 xAfter = x + netQuoteIn;
        uint256 yAfter = Math.mulDiv(x, y, xAfter, Math.Rounding.Ceil);
        if (yAfter >= y) revert InsufficientOutput();

        quoted = BuyQuote({
            grossQuoteIn: grossQuoteIn,
            feeAmount: feeAmount,
            netQuoteIn: netQuoteIn,
            tokenAmountOut: y - yAfter,
            quoteReserveAfter: quoteReserve + netQuoteIn,
            tokenReserveAfter: yAfter,
            reachesGraduation: quoteReserve + netQuoteIn >= graduationQuoteThreshold
        });
    }

    function _quoteSell(uint256 tokenAmountIn) private view returns (SellQuote memory quoted) {
        _ensureTrading();
        if (tokenAmountIn == 0) revert BadAmount();

        uint256 x = virtualQuoteReserve + quoteReserve;
        uint256 y = tokenReserve;
        uint256 yAfter = y + tokenAmountIn;
        uint256 xAfter = Math.mulDiv(x, y, yAfter, Math.Rounding.Ceil);
        if (xAfter >= x) revert InsufficientOutput();

        uint256 grossQuoteOut = x - xAfter;
        if (grossQuoteOut == 0) revert InsufficientOutput();
        if (grossQuoteOut > quoteReserve) revert InsufficientLiquidity();

        uint256 feeAmount = _feeAmount(grossQuoteOut);
        quoted = SellQuote({
            tokenAmountIn: tokenAmountIn,
            grossQuoteOut: grossQuoteOut,
            feeAmount: feeAmount,
            netQuoteOut: grossQuoteOut - feeAmount,
            quoteReserveAfter: quoteReserve - grossQuoteOut,
            tokenReserveAfter: yAfter
        });
    }

    function _accrueFees(uint256 grossQuoteAmount, uint256 feeAmount) private {
        if (feeAmount == 0) return;

        uint256 creatorAmount =
            Math.mulDiv(grossQuoteAmount, creatorSwapFeeBps, QuoteV2FeePolicy.BPS);
        uint256 rewardAmount = Math.mulDiv(grossQuoteAmount, rewardFeeBps, QuoteV2FeePolicy.BPS);
        uint256 platformAmount = feeAmount - creatorAmount - rewardAmount;

        claimableFees[platformRecipient] += platformAmount;
        if (creatorAmount != 0) claimableFees[creatorRecipient] += creatorAmount;
        if (rewardAmount != 0) claimableFees[rewardRecipient] += rewardAmount;
        feeReserve += feeAmount;
    }

    function _feeAmount(uint256 grossQuoteAmount) private view returns (uint256) {
        return
            Math.mulDiv(grossQuoteAmount, totalSwapFeeBps, QuoteV2FeePolicy.BPS, Math.Rounding.Ceil);
    }

    function _validateTrade(address beneficiary, uint256 deadline) private view {
        _ensureTrading();
        if (beneficiary == address(0) || beneficiary == address(this)) revert BadBeneficiary();
        if (deadline < block.timestamp) revert DeadlineExpired();
    }

    function _validatePool(bytes32 requestedPoolId, address launchedToken_, address quoteToken_)
        private
        view
    {
        if (
            requestedPoolId != poolId || launchedToken_ != address(launchedToken)
                || quoteToken_ != address(quoteToken)
        ) revert BadAsset();
    }

    function _ensureTrading() private view {
        if (state != MarketState.Trading) revert NotTrading();
    }

    function _accountedQuoteBalance() private view returns (uint256) {
        return quoteReserve + feeReserve;
    }

    function _assertQuoteBacking() private view {
        if (quoteToken.balanceOf(address(this)) < _accountedQuoteBalance()) {
            revert BadBalanceDelta();
        }
    }
}
