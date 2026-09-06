// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    INonfungiblePositionManager,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "../../interfaces/IPancakeV3.sol";
import { TokenMode } from "../QuoteV2Types.sol";
import {
    IQuoteLaunchEngine,
    QuoteLaunchArtifacts,
    QuoteLaunchContext,
    QuoteLaunchEngineKind
} from "../core/IQuoteLaunchEngine.sol";
import { DirectV3LockerDeployer, DirectV3TokenDeployer } from "./DirectV3ArtifactDeployers.sol";
import { DirectV3NativeBuy } from "./DirectV3NativeBuy.sol";
import { DirectV3PriceMath } from "./DirectV3PriceMath.sol";
import { QuoteDirectToken } from "./QuoteDirectToken.sol";
import { PermanentPancakeV3Locker } from "../locker/PermanentPancakeV3Locker.sol";
import { V2QuoteUsdPriceVerifier } from "../oracle/V2QuoteUsdPriceVerifier.sol";
import { IPancakeV3SwapRouterLike } from "../adapters/interfaces/IPancakeV3AdapterTypes.sol";
import { IWBNB } from "../native/INativeDevBuyAdapters.sol";

/// @notice Minimal direct Pancake V3 launch engine. Pancake's one-sided range is the only curve.
/// @dev Price and ticks are protocol-derived from a fresh quote/USD attestation and a fixed $7k
///      target FDV. Existing initialized pools are categorically rejected, even at zero liquidity.
contract PancakeV3DirectEngine is IQuoteLaunchEngine {
    using SafeERC20 for IERC20;

    uint256 public constant TARGET_FDV_USD_WAD = 7_000e18;
    uint256 public constant MIN_SUPPLY = 1_000_000_000_000;
    uint256 public constant MAX_SUPPLY = type(uint128).max;
    uint256 public constant MAX_DUST_DIVISOR = 1_000_000_000_000;
    uint24 public constant POOL_FEE = 10_000;
    uint256 public constant MAX_TOKEN_CANDIDATES = 32;
    bytes32 public constant TOKEN_SALT_DOMAIN = keccak256("QUOTE.PancakeV3DirectToken.v2");
    bytes32 public constant POOL_ID_DOMAIN = keccak256("QUOTE.PancakeV3DirectPool.v1");
    bytes32 public constant RECORD_ID_DOMAIN = keccak256("QUOTE.PancakeV3DirectRecord.v1");
    bytes32 public constant REQUEST_HASH_DOMAIN = keccak256("QUOTE.PancakeV3DirectRequest.v1");
    bytes32 public constant DEV_BUY_HASH_DOMAIN = keccak256("QUOTE.PancakeV3DirectDevBuy.v1");

    address public immutable override launchpad;
    bytes32 public immutable override engineVersion;
    IPancakeV3Factory public immutable pancakeFactory;
    INonfungiblePositionManager public immutable positionManager;
    IPancakeV3SwapRouterLike public immutable swapRouter;
    V2QuoteUsdPriceVerifier public immutable quoteVerifier;
    address public immutable protocolTreasury;
    DirectV3TokenDeployer public immutable tokenDeployer;
    DirectV3LockerDeployer public immutable lockerDeployer;
    DirectV3NativeBuy public immutable nativeBuy;

    struct LaunchPayload {
        string name;
        string symbol;
        bytes32 userSalt;
        address referenceToken;
        address referencePool;
        V2QuoteUsdPriceVerifier.QuotePriceAttestation quoteAttestation;
        bytes quoteAttestationSignature;
        DirectV3NativeBuy.DevBuyParams devBuy;
    }

    struct DirectLaunchRecord {
        address creator;
        address token;
        address quoteToken;
        address referenceToken;
        address referencePool;
        address pool;
        address locker;
        uint256 positionTokenId;
        uint256 requestedSupply;
        uint256 depositedSupply;
        uint256 quotePriceUsdWad;
        uint256 observedLiquidityUsdWad;
        bytes32 attestationDigest;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint24 feeTier;
        uint8 quoteDecimals;
        uint256 devBuyNativeIn;
        uint256 devBuyQuoteOut;
        uint256 devBuyTokenOut;
        uint256 devBuyNativeRefund;
        uint256 devBuyQuoteRefund;
    }

    mapping(uint256 launchId => DirectLaunchRecord record) private _records;

    error BadDependencies();
    error NotLaunchpad();
    error InvalidContext();
    error UnsupportedTokenMode();
    error UnsupportedFeeConfiguration();
    error BadMetadata();
    error BadSupply();
    error BadQuoteToken();
    error QuoteDecimalsUnavailable();
    error DeadlineExpired();
    error NativeValueMismatch(uint256 actual, uint256 expected);
    error AttestedCreatorMismatch(address attested, address expected);
    error AttestedRequestHashMismatch(bytes32 attested, bytes32 expected);
    error PoolAlreadyInitialized(address pool);
    error InvalidPool();
    error InvalidPoolState();
    error InvalidPosition();
    error IncompleteLiquidityDeposit();
    error ExcessiveLiquidityDust(uint256 dust, uint256 maxDust);
    error NoUnsquattedPoolCandidate();

    event DirectMarketLaunched(
        uint256 indexed launchId,
        address indexed creator,
        address indexed token,
        address quoteToken,
        address pool,
        address locker,
        uint256 positionTokenId,
        uint256 depositedSupply,
        uint256 targetFdvUsdWad,
        uint256 quotePriceUsdWad,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint24 feeTier,
        uint8 quoteDecimals,
        bytes32 attestationDigest
    );
    event DirectLiquidityDustBurned(
        address indexed token, uint256 requestedSupply, uint256 depositedSupply, uint256 burnedDust
    );

    constructor(
        address launchpad_,
        bytes32 engineVersion_,
        IPancakeV3Factory pancakeFactory_,
        INonfungiblePositionManager positionManager_,
        IPancakeV3SwapRouterLike swapRouter_,
        IWBNB wbnb_,
        V2QuoteUsdPriceVerifier quoteVerifier_,
        address protocolTreasury_
    ) {
        if (
            launchpad_ == address(0) || launchpad_.code.length == 0 || engineVersion_ == bytes32(0)
                || address(pancakeFactory_) == address(0)
                || address(pancakeFactory_).code.length == 0
                || address(positionManager_) == address(0)
                || address(positionManager_).code.length == 0 || address(swapRouter_) == address(0)
                || address(swapRouter_).code.length == 0 || address(quoteVerifier_) == address(0)
                || address(wbnb_) == address(0) || address(wbnb_).code.length == 0
                || address(quoteVerifier_).code.length == 0 || protocolTreasury_ == address(0)
                || positionManager_.factory() != address(pancakeFactory_)
                || pancakeFactory_.feeAmountTickSpacing(POOL_FEE) <= 0
        ) revert BadDependencies();

        launchpad = launchpad_;
        engineVersion = engineVersion_;
        pancakeFactory = pancakeFactory_;
        positionManager = positionManager_;
        swapRouter = swapRouter_;
        quoteVerifier = quoteVerifier_;
        protocolTreasury = protocolTreasury_;
        tokenDeployer = new DirectV3TokenDeployer(address(this));
        lockerDeployer = new DirectV3LockerDeployer(address(this));
        nativeBuy = new DirectV3NativeBuy(address(this), wbnb_, swapRouter_, pancakeFactory_);
    }

    function engineKind() external pure override returns (QuoteLaunchEngineKind) {
        return QuoteLaunchEngineKind.DIRECT;
    }

    function launch(QuoteLaunchContext calldata context, bytes calldata enginePayload)
        external
        payable
        override
        returns (QuoteLaunchArtifacts memory artifacts)
    {
        if (msg.sender != launchpad) revert NotLaunchpad();
        LaunchPayload memory payload = abi.decode(enginePayload, (LaunchPayload));
        _validateRequest(context, payload);
        uint8 quoteDecimals = _quoteDecimals(context.quoteToken);
        bytes32 requestHash = _launchRequestHash(context, payload, quoteDecimals);
        if (payload.quoteAttestation.creator != context.creator) {
            revert AttestedCreatorMismatch(payload.quoteAttestation.creator, context.creator);
        }
        if (payload.quoteAttestation.launchRequestHash != requestHash) {
            revert AttestedRequestHashMismatch(
                payload.quoteAttestation.launchRequestHash, requestHash
            );
        }

        (uint256 quotePriceUsdWad, uint256 observedLiquidityUsdWad,, bytes32 attestationDigest) = quoteVerifier.verifyAndConsume(
            context.quoteToken,
            payload.referenceToken,
            payload.referencePool,
            payload.quoteAttestation,
            payload.quoteAttestationSignature
        );

        (bytes32 salt, address predictedToken, bool launchTokenIsToken0) =
            _selectTokenCandidate(context, payload, quoteDecimals);
        uint160 sqrtPriceX96 = DirectV3PriceMath.initialSqrtPriceX96(
            TARGET_FDV_USD_WAD, context.supply, quotePriceUsdWad, quoteDecimals, launchTokenIsToken0
        );

        QuoteDirectToken token =
            tokenDeployer.deploy(salt, payload.name, payload.symbol, context.supply);
        if (address(token) != predictedToken) revert InvalidContext();
        _requirePoolUninitialized(
            pancakeFactory.getPool(address(token), context.quoteToken, POOL_FEE)
        );

        (address token0, address token1) = launchTokenIsToken0
            ? (address(token), context.quoteToken)
            : (context.quoteToken, address(token));
        address pool = positionManager.createAndInitializePoolIfNecessary(
            token0, token1, POOL_FEE, sqrtPriceX96
        );
        if (
            pool == address(0) || pool.code.length == 0
                || pancakeFactory.getPool(token0, token1, POOL_FEE) != pool
        ) revert InvalidPool();

        (uint160 actualSqrtPriceX96, int24 currentTick,,,,,) = IPancakeV3Pool(pool).slot0();
        if (actualSqrtPriceX96 != sqrtPriceX96) revert InvalidPoolState();
        int24 tickSpacing = pancakeFactory.feeAmountTickSpacing(POOL_FEE);
        (int24 tickLower, int24 tickUpper) =
            DirectV3PriceMath.oneSidedTicks(currentTick, tickSpacing, launchTokenIsToken0);

        (uint256 positionTokenId, uint256 depositedSupply) = _mintPosition(
            token,
            pool,
            token0,
            token1,
            POOL_FEE,
            tickLower,
            tickUpper,
            context.supply,
            context.deadline,
            launchTokenIsToken0
        );

        PermanentPancakeV3Locker locker = lockerDeployer.deploy(
            positionManager,
            _lockerBeneficiary(context),
            protocolTreasury,
            context.feeConfig.creatorLpShareBps,
            positionTokenId
        );
        positionManager.safeTransferFrom(address(this), address(locker), positionTokenId);
        locker.finalize(token0, token1, POOL_FEE, tickLower, tickUpper);

        _validatePostconditions(
            token,
            pool,
            address(locker),
            positionTokenId,
            token0,
            token1,
            POOL_FEE,
            tickLower,
            tickUpper,
            depositedSupply
        );

        DirectV3NativeBuy.DevBuyResult memory devBuyResult;
        if (payload.devBuy.nativeAmountIn != 0) {
            devBuyResult = nativeBuy.buy{ value: context.nativeAmount }(
                address(token), context.quoteToken, POOL_FEE, context.deadline, payload.devBuy
            );
        }

        bytes32 poolId = keccak256(
            abi.encode(
                POOL_ID_DOMAIN,
                block.chainid,
                address(pancakeFactory),
                token0,
                token1,
                POOL_FEE,
                pool
            )
        );
        bytes32 engineRecordId = keccak256(
            abi.encode(
                RECORD_ID_DOMAIN, block.chainid, address(this), context.launchId, address(token)
            )
        );

        _records[context.launchId] = DirectLaunchRecord({
            creator: context.creator,
            token: address(token),
            quoteToken: context.quoteToken,
            referenceToken: payload.referenceToken,
            referencePool: payload.referencePool,
            pool: pool,
            locker: address(locker),
            positionTokenId: positionTokenId,
            requestedSupply: context.supply,
            depositedSupply: depositedSupply,
            quotePriceUsdWad: quotePriceUsdWad,
            observedLiquidityUsdWad: observedLiquidityUsdWad,
            attestationDigest: attestationDigest,
            sqrtPriceX96: sqrtPriceX96,
            tickLower: tickLower,
            tickUpper: tickUpper,
            feeTier: POOL_FEE,
            quoteDecimals: quoteDecimals,
            devBuyNativeIn: devBuyResult.nativeAmountIn,
            devBuyQuoteOut: devBuyResult.quoteAmountOut,
            devBuyTokenOut: devBuyResult.tokenAmountOut,
            devBuyNativeRefund: devBuyResult.wbnbRefundedAsNative,
            devBuyQuoteRefund: devBuyResult.quoteRefunded
        });

        artifacts = QuoteLaunchArtifacts({
            creator: context.creator,
            token: address(token),
            market: pool,
            hook: address(0),
            vault: address(0),
            locker: address(locker),
            poolId: poolId,
            engineRecordId: engineRecordId
        });

        emit DirectMarketLaunched(
            context.launchId,
            context.creator,
            address(token),
            context.quoteToken,
            pool,
            address(locker),
            positionTokenId,
            depositedSupply,
            TARGET_FDV_USD_WAD,
            quotePriceUsdWad,
            sqrtPriceX96,
            tickLower,
            tickUpper,
            POOL_FEE,
            quoteDecimals,
            attestationDigest
        );
    }

    function recordAt(uint256 launchId) external view returns (DirectLaunchRecord memory) {
        return _records[launchId];
    }

    /// @notice Deterministic helper for offline tooling; live launches add execution entropy.
    function tokenSalt(
        uint256 launchId,
        address creator,
        address quoteToken,
        uint256 supply,
        string memory name,
        string memory symbol,
        bytes32 userSalt
    ) public view returns (bytes32) {
        return _tokenSalt(
            launchId, creator, quoteToken, supply, 0, name, symbol, userSalt, bytes32(0), 0
        );
    }

    /// @notice Deterministic helper for offline tooling; live launches add execution entropy.
    function predictToken(
        uint256 launchId,
        address creator,
        address quoteToken,
        uint256 supply,
        string memory name,
        string memory symbol,
        bytes32 userSalt
    ) public view returns (address) {
        bytes32 salt = tokenSalt(launchId, creator, quoteToken, supply, name, symbol, userSalt);
        return tokenDeployer.predict(salt, name, symbol, supply);
    }

    function launchRequestHash(QuoteLaunchContext calldata context, LaunchPayload calldata payload)
        external
        view
        returns (bytes32)
    {
        LaunchPayload memory payloadCopy = payload;
        return _launchRequestHash(context, payloadCopy, _quoteDecimals(context.quoteToken));
    }

    function previewInitialPrice(
        address launchToken,
        address quoteToken,
        uint256 supply,
        uint256 quotePriceUsdWad,
        uint8 quoteDecimals
    ) external pure returns (uint160 sqrtPriceX96) {
        if (launchToken == address(0) || quoteToken == address(0) || launchToken == quoteToken) {
            revert BadQuoteToken();
        }
        return DirectV3PriceMath.initialSqrtPriceX96(
            TARGET_FDV_USD_WAD, supply, quotePriceUsdWad, quoteDecimals, launchToken < quoteToken
        );
    }

    function _launchRequestHash(
        QuoteLaunchContext calldata context,
        LaunchPayload memory payload,
        uint8 quoteDecimals
    ) private view returns (bytes32) {
        bytes32 metadataHash = keccak256(
            abi.encode(
                keccak256(bytes(payload.name)), keccak256(bytes(payload.symbol)), payload.userSalt
            )
        );
        DirectV3NativeBuy.DevBuyParams memory devBuy = payload.devBuy;
        bytes32 devBuyHash = keccak256(
            abi.encode(
                DEV_BUY_HASH_DOMAIN,
                devBuy.nativeAmountIn,
                devBuy.minQuoteOut,
                devBuy.minTokenOut,
                devBuy.deadline,
                devBuy.quoteFeeTier,
                devBuy.expectedQuotePool,
                devBuy.quoteSqrtPriceLimitX96,
                devBuy.launchSqrtPriceLimitX96,
                devBuy.beneficiary
            )
        );
        return keccak256(
            abi.encode(
                REQUEST_HASH_DOMAIN,
                block.chainid,
                address(this),
                uint8(context.engineKind),
                context.engineVersion,
                context.creator,
                context.quoteToken,
                context.supply,
                context.nativeAmount,
                context.deadline,
                uint8(context.tokenMode),
                context.feeConfig.creatorSwapFeeBps,
                context.feeConfig.rewardFeeBps,
                context.feeConfig.creatorLpShareBps,
                context.creatorFeeRecipient,
                context.rewardFeeRecipient,
                protocolTreasury,
                POOL_FEE,
                quoteDecimals,
                payload.referenceToken,
                payload.referencePool,
                metadataHash,
                devBuyHash
            )
        );
    }

    function previewOneSidedTicks(int24 currentTick, int24 tickSpacing, bool launchTokenIsToken0)
        external
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        return DirectV3PriceMath.oneSidedTicks(currentTick, tickSpacing, launchTokenIsToken0);
    }

    function _validateRequest(QuoteLaunchContext calldata context, LaunchPayload memory payload)
        private
        view
    {
        if (
            context.creator == address(0) || context.quoteToken == address(0)
                || context.quoteToken.code.length == 0
                || context.engineKind != QuoteLaunchEngineKind.DIRECT
                || context.engineVersion != engineVersion
        ) revert InvalidContext();
        if (context.tokenMode != TokenMode.STANDARD) revert UnsupportedTokenMode();
        if (context.feeConfig.creatorSwapFeeBps != 0 || context.feeConfig.rewardFeeBps != 0) {
            revert UnsupportedFeeConfiguration();
        }
        if (context.feeConfig.creatorLpShareBps != 0 && context.creatorFeeRecipient == address(0)) {
            revert InvalidContext();
        }
        if (bytes(payload.name).length == 0 || bytes(payload.name).length > 64) {
            revert BadMetadata();
        }
        if (bytes(payload.symbol).length == 0 || bytes(payload.symbol).length > 16) {
            revert BadMetadata();
        }
        if (context.supply < MIN_SUPPLY || context.supply > MAX_SUPPLY) revert BadSupply();
        if (context.deadline < block.timestamp) revert DeadlineExpired();
        if (
            msg.value != context.nativeAmount
                || context.nativeAmount != payload.devBuy.nativeAmountIn
        ) revert NativeValueMismatch(msg.value, payload.devBuy.nativeAmountIn);
        if (payload.devBuy.nativeAmountIn == 0) {
            DirectV3NativeBuy.DevBuyParams memory devBuy = payload.devBuy;
            if (
                devBuy.minQuoteOut != 0 || devBuy.minTokenOut != 0 || devBuy.deadline != 0
                    || devBuy.quoteFeeTier != 0 || devBuy.expectedQuotePool != address(0)
                    || devBuy.quoteSqrtPriceLimitX96 != 0 || devBuy.launchSqrtPriceLimitX96 != 0
                    || devBuy.beneficiary != address(0)
            ) revert InvalidContext();
        }
    }

    /// @dev Keeps the live CREATE2 salt out of ordinary mempool observers' reach by mixing data
    ///      only fixed at execution. Current block proposers can still know or influence this
    ///      entropy within consensus limits, so this is not proposer-censorship resistance.
    function _selectTokenCandidate(
        QuoteLaunchContext calldata context,
        LaunchPayload memory payload,
        uint8 quoteDecimals
    ) private view returns (bytes32 salt, address predictedToken, bool launchTokenIsToken0) {
        bytes32 executionEntropy = _executionTokenEntropy();
        for (uint256 i; i < MAX_TOKEN_CANDIDATES; ++i) {
            salt = _tokenSalt(
                context.launchId,
                context.creator,
                context.quoteToken,
                context.supply,
                quoteDecimals,
                payload.name,
                payload.symbol,
                payload.userSalt,
                executionEntropy,
                i
            );
            predictedToken =
                tokenDeployer.predict(salt, payload.name, payload.symbol, context.supply);
            if (predictedToken == context.quoteToken) continue;
            if (_poolCandidateAvailable(predictedToken, context.quoteToken)) {
                launchTokenIsToken0 = predictedToken < context.quoteToken;
                return (salt, predictedToken, launchTokenIsToken0);
            }
        }
        revert NoUnsquattedPoolCandidate();
    }

    function _tokenSalt(
        uint256 launchId,
        address creator,
        address quoteToken,
        uint256 supply,
        uint8 quoteDecimals,
        string memory name,
        string memory symbol,
        bytes32 userSalt,
        bytes32 executionEntropy,
        uint256 candidate
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                TOKEN_SALT_DOMAIN,
                block.chainid,
                address(this),
                address(tokenDeployer),
                launchId,
                creator,
                quoteToken,
                supply,
                quoteDecimals,
                keccak256(bytes(name)),
                keccak256(bytes(symbol)),
                userSalt,
                executionEntropy,
                candidate
            )
        );
    }

    function _executionTokenEntropy() private view returns (bytes32) {
        bytes32 parentHash = block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
        return keccak256(abi.encode(parentHash, block.prevrandao, block.timestamp, block.coinbase));
    }

    function _poolCandidateAvailable(address token, address quoteToken)
        private
        view
        returns (bool)
    {
        address pool = pancakeFactory.getPool(token, quoteToken, POOL_FEE);
        if (pool == address(0)) return true;
        if (pool.code.length == 0) revert InvalidPool();
        (uint160 existingSqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        return existingSqrtPriceX96 == 0;
    }

    function _lockerBeneficiary(QuoteLaunchContext calldata context)
        private
        pure
        returns (address)
    {
        if (context.feeConfig.creatorLpShareBps == 0) return context.creator;
        return context.creatorFeeRecipient;
    }

    function _quoteDecimals(address quoteToken) private view returns (uint8 quoteDecimals) {
        try IERC20Metadata(quoteToken).decimals() returns (uint8 decimals_) {
            quoteDecimals = decimals_;
        } catch {
            revert QuoteDecimalsUnavailable();
        }
    }

    function _requirePoolUninitialized(address pool) private view {
        if (pool == address(0)) return;
        if (pool.code.length == 0) revert InvalidPool();
        (uint160 existingSqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        if (existingSqrtPriceX96 != 0) revert PoolAlreadyInitialized(pool);
    }

    function _mintPosition(
        QuoteDirectToken token,
        address pool,
        address token0,
        address token1,
        uint24 feeTier,
        int24 tickLower,
        int24 tickUpper,
        uint256 supply,
        uint256 deadline,
        bool launchTokenIsToken0
    ) private returns (uint256 positionTokenId, uint256 depositedSupply) {
        uint256 maxDust = supply / MAX_DUST_DIVISOR;
        IERC20(address(token)).forceApprove(address(positionManager), supply);

        uint256 amount0;
        uint256 amount1;
        (positionTokenId,, amount0, amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: feeTier,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: launchTokenIsToken0 ? supply : 0,
                amount1Desired: launchTokenIsToken0 ? 0 : supply,
                amount0Min: launchTokenIsToken0 ? supply - maxDust : 0,
                amount1Min: launchTokenIsToken0 ? 0 : supply - maxDust,
                recipient: address(this),
                deadline: deadline
            })
        );
        IERC20(address(token)).forceApprove(address(positionManager), 0);
        if (positionManager.ownerOf(positionTokenId) != address(this)) revert InvalidPosition();

        depositedSupply = launchTokenIsToken0 ? amount0 : amount1;
        uint256 unexpectedQuoteAmount = launchTokenIsToken0 ? amount1 : amount0;
        if (depositedSupply == 0 || depositedSupply > supply || unexpectedQuoteAmount != 0) {
            revert IncompleteLiquidityDeposit();
        }

        uint256 dust = supply - depositedSupply;
        if (dust > maxDust) revert ExcessiveLiquidityDust(dust, maxDust);
        if (dust != 0) {
            token.burnLaunchDust(dust);
            emit DirectLiquidityDustBurned(address(token), supply, depositedSupply, dust);
        }

        if (
            token.balanceOf(address(this)) != 0 || token.totalSupply() != depositedSupply
                || token.balanceOf(pool) != depositedSupply
        ) revert IncompleteLiquidityDeposit();
    }

    function _validatePostconditions(
        QuoteDirectToken token,
        address pool,
        address locker,
        uint256 positionTokenId,
        address token0,
        address token1,
        uint24 feeTier,
        int24 tickLower,
        int24 tickUpper,
        uint256 depositedSupply
    ) private view {
        (
            ,,
            address positionToken0,
            address positionToken1,
            uint24 positionFee,
            int24 positionTickLower,
            int24 positionTickUpper,
            uint128 positionLiquidity,,,,
        ) = positionManager.positions(positionTokenId);
        if (
            positionManager.ownerOf(positionTokenId) != locker || positionToken0 != token0
                || positionToken1 != token1 || positionFee != feeTier
                || positionTickLower != tickLower || positionTickUpper != tickUpper
                || positionLiquidity == 0 || token.balanceOf(address(this)) != 0
                || token.totalSupply() != depositedSupply
                || token.balanceOf(pool) != depositedSupply
                || token.allowance(address(this), address(positionManager)) != 0
        ) revert InvalidPosition();
    }
}
