// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { ForkPareToken } from "./ForkPareToken.sol";
import { PermanentV3Locker } from "./PermanentV3Locker.sol";
import {
    INonfungiblePositionManager,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "./interfaces/IPancakeV3.sol";

/// @notice Versioned, non-upgradeable factory for fixed-supply, one-sided Pancake V3 launches.
contract ForkPareFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant CREATOR_FEE_SHARE_BPS = 7_000;
    uint256 public constant MIN_SUPPLY = 1_000_000_000_000;
    uint256 public constant MAX_SUPPLY = type(uint128).max;
    uint256 public constant MAX_DUST_DIVISOR = 1_000_000_000_000;
    uint256 public constant MAX_SALT_CANDIDATES = 32;

    IPancakeV3Factory public immutable pancakeFactory;
    INonfungiblePositionManager public immutable positionManager;
    address public immutable protocolTreasury;
    uint256 public immutable creationFee;

    struct LaunchParams {
        string name;
        string symbol;
        uint256 supply;
        address quoteToken;
        uint24 feeTier;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint256 deadline;
        bytes32 userSalt;
    }

    struct LaunchRecord {
        address creator;
        address token;
        address quoteToken;
        address pool;
        address locker;
        uint256 positionTokenId;
        uint256 supply;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint24 feeTier;
    }

    LaunchRecord[] private _launches;
    mapping(address token => uint256 idPlusOne) public launchIdByToken;

    error BadCreationFee();
    error BadDependencies();
    error BadMetadata();
    error BadSupply();
    error BadQuoteToken();
    error BadFeeTier();
    error BadTicks();
    error BadOrientation();
    error DeadlineExpired();
    error PoolAlreadyInitialized();
    error PoolPriceConflict();
    error InvalidPool();
    error InvalidPosition();
    error IncompleteLiquidityDeposit();
    error ExcessiveLiquidityDust();
    error NoLaunchableSalt();
    error NotTreasury();
    error NativeTransferFailed();

    event MarketLaunched(
        uint256 indexed launchId,
        address indexed creator,
        address indexed token,
        address quoteToken,
        address pool,
        address locker,
        uint256 positionTokenId,
        uint256 supply,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint24 feeTier
    );
    event LiquidityDustBurned(
        address indexed token, uint256 requestedSupply, uint256 depositedSupply, uint256 burnedDust
    );

    constructor(
        IPancakeV3Factory pancakeFactory_,
        INonfungiblePositionManager positionManager_,
        address protocolTreasury_,
        uint256 creationFee_
    ) {
        if (
            address(pancakeFactory_) == address(0) || address(positionManager_) == address(0)
                || protocolTreasury_ == address(0) || address(pancakeFactory_).code.length == 0
                || address(positionManager_).code.length == 0
                || positionManager_.factory() != address(pancakeFactory_)
        ) revert BadDependencies();

        pancakeFactory = pancakeFactory_;
        positionManager = positionManager_;
        protocolTreasury = protocolTreasury_;
        creationFee = creationFee_;
    }

    function launch(LaunchParams calldata params)
        external
        payable
        nonReentrant
        returns (LaunchRecord memory record)
    {
        if (msg.value != creationFee) revert BadCreationFee();
        if (bytes(params.name).length == 0 || bytes(params.name).length > 64) revert BadMetadata();
        if (bytes(params.symbol).length == 0 || bytes(params.symbol).length > 12) {
            revert BadMetadata();
        }
        if (params.supply < MIN_SUPPLY || params.supply > MAX_SUPPLY) revert BadSupply();
        if (params.quoteToken.code.length == 0) revert BadQuoteToken();
        if (params.deadline < block.timestamp) revert DeadlineExpired();

        int24 tickSpacing = pancakeFactory.feeAmountTickSpacing(params.feeTier);
        if (tickSpacing <= 0) revert BadFeeTier();
        if (
            params.tickLower >= params.tickUpper || params.tickLower % tickSpacing != 0
                || params.tickUpper % tickSpacing != 0
        ) revert BadTicks();

        (bytes32 salt,) = _selectLaunchCandidate(msg.sender, params);

        PermanentV3Locker locker = new PermanentV3Locker(
            positionManager, address(this), msg.sender, protocolTreasury, CREATOR_FEE_SHARE_BPS
        );
        ForkPareToken token = new ForkPareToken{ salt: salt }(
            params.name, params.symbol, params.supply, address(this)
        );

        (address token0, address token1) = address(token) < params.quoteToken
            ? (address(token), params.quoteToken)
            : (params.quoteToken, address(token));

        address pool = positionManager.createAndInitializePoolIfNecessary(
            token0, token1, params.feeTier, params.sqrtPriceX96
        );
        if (pool.code.length == 0 || pancakeFactory.getPool(token0, token1, params.feeTier) != pool)
        {
            revert InvalidPool();
        }
        (uint160 currentPrice, int24 currentTick,,,,,) = IPancakeV3Pool(pool).slot0();
        if (currentPrice != params.sqrtPriceX96) revert PoolPriceConflict();

        if (address(token) == token0) {
            if (currentTick > params.tickLower || params.tickLower - currentTick > tickSpacing) {
                revert BadOrientation();
            }
        } else {
            if (currentTick < params.tickUpper || currentTick - params.tickUpper > tickSpacing) {
                revert BadOrientation();
            }
        }

        uint256 maxDust = params.supply / MAX_DUST_DIVISOR;

        IERC20(address(token)).forceApprove(address(positionManager), params.supply);
        (uint256 positionTokenId,, uint256 amount0, uint256 amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: params.feeTier,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: address(token) == token0 ? params.supply : 0,
                amount1Desired: address(token) == token1 ? params.supply : 0,
                amount0Min: address(token) == token0 ? params.supply - maxDust : 0,
                amount1Min: address(token) == token1 ? params.supply - maxDust : 0,
                recipient: address(locker),
                deadline: params.deadline
            })
        );
        IERC20(address(token)).forceApprove(address(positionManager), 0);

        uint256 depositedSupply = address(token) == token0 ? amount0 : amount1;
        uint256 unexpectedQuoteAmount = address(token) == token0 ? amount1 : amount0;
        if (depositedSupply == 0 || depositedSupply > params.supply || unexpectedQuoteAmount != 0) {
            revert IncompleteLiquidityDeposit();
        }

        uint256 burnedDust = params.supply - depositedSupply;
        if (burnedDust > maxDust) revert ExcessiveLiquidityDust();
        if (burnedDust != 0) {
            token.burnUnspent(burnedDust);
            emit LiquidityDustBurned(address(token), params.supply, depositedSupply, burnedDust);
        }
        if (
            token.balanceOf(address(this)) != 0 || token.totalSupply() != depositedSupply
                || IERC20(address(token)).balanceOf(pool) != depositedSupply
        ) revert IncompleteLiquidityDeposit();

        _validatePosition(positionTokenId, address(locker), token0, token1, params);

        locker.initialize(positionTokenId, token0, token1);

        record = LaunchRecord({
            creator: msg.sender,
            token: address(token),
            quoteToken: params.quoteToken,
            pool: pool,
            locker: address(locker),
            positionTokenId: positionTokenId,
            supply: depositedSupply,
            sqrtPriceX96: params.sqrtPriceX96,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            feeTier: params.feeTier
        });
        _launches.push(record);
        launchIdByToken[address(token)] = _launches.length;

        emit MarketLaunched(
            _launches.length - 1,
            msg.sender,
            address(token),
            params.quoteToken,
            pool,
            address(locker),
            positionTokenId,
            depositedSupply,
            params.sqrtPriceX96,
            params.tickLower,
            params.tickUpper,
            params.feeTier
        );
    }

    function _validatePosition(
        uint256 positionTokenId,
        address locker,
        address token0,
        address token1,
        LaunchParams calldata params
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
                || positionToken1 != token1 || positionFee != params.feeTier
                || positionTickLower != params.tickLower || positionTickUpper != params.tickUpper
                || positionLiquidity == 0
        ) revert InvalidPosition();
    }

    /// @notice Returns the salt for the first currently launchable candidate.
    /// @dev Candidate zero preserves the historical address when it is not squatted. If that
    ///      token/quote/fee pool is already initialized, launch and prediction skip to the next
    ///      bounded candidate, so this value is state-dependent.
    function launchSalt(address creator, LaunchParams calldata params)
        public
        view
        returns (bytes32)
    {
        (bytes32 salt,) = _selectLaunchCandidate(creator, params);
        return salt;
    }

    function _launchSaltCandidate(address creator, LaunchParams calldata params, uint256 candidate)
        private
        view
        returns (bytes32)
    {
        bytes32 baseSalt = keccak256(
            abi.encode(
                block.chainid,
                address(this),
                creator,
                params.name,
                params.symbol,
                params.supply,
                params.quoteToken,
                params.feeTier,
                params.sqrtPriceX96,
                params.tickLower,
                params.tickUpper,
                params.userSalt
            )
        );
        if (candidate == 0) return baseSalt;
        return keccak256(abi.encode(baseSalt, candidate));
    }

    function _tokenInitCodeHash(LaunchParams calldata params) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(ForkPareToken).creationCode,
                abi.encode(params.name, params.symbol, params.supply, address(this))
            )
        );
    }

    function _predictToken(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))
                )
            )
        );
    }

    function _selectLaunchCandidate(address creator, LaunchParams calldata params)
        private
        view
        returns (bytes32 salt, address token)
    {
        bytes32 initCodeHash = _tokenInitCodeHash(params);
        bool expectedTokenIsToken0 = _predictToken(
            _launchSaltCandidate(creator, params, 0), initCodeHash
        ) < params.quoteToken;

        for (uint256 i; i < MAX_SALT_CANDIDATES; ++i) {
            salt = _launchSaltCandidate(creator, params, i);
            token = _predictToken(salt, initCodeHash);
            if (token == params.quoteToken) continue;
            if ((token < params.quoteToken) != expectedTokenIsToken0) continue;

            address existingPool = pancakeFactory.getPool(token, params.quoteToken, params.feeTier);
            if (existingPool == address(0)) return (salt, token);
            if (existingPool.code.length == 0) revert InvalidPool();

            (uint160 existingPrice,,,,,,) = IPancakeV3Pool(existingPool).slot0();
            if (existingPrice == 0) return (salt, token);
        }

        revert NoLaunchableSalt();
    }

    /// @notice Predicts the first token address that launch would use under current pool state.
    /// @dev Historically this was a fixed address for `userSalt`. It now skips bounded candidates
    ///      whose Pancake V3 pool already exists and is initialized, preventing pool-squatting DoS.
    function predictToken(address creator, LaunchParams calldata params)
        public
        view
        returns (address)
    {
        (, address token) = _selectLaunchCandidate(creator, params);
        return token;
    }

    function launchCount() external view returns (uint256) {
        return _launches.length;
    }

    function launchAt(uint256 launchId) external view returns (LaunchRecord memory) {
        return _launches[launchId];
    }

    function withdrawCreationFees(address payable receiver) external nonReentrant {
        if (msg.sender != protocolTreasury) revert NotTreasury();
        if (receiver == address(0)) revert BadQuoteToken();
        (bool ok,) = receiver.call{ value: address(this).balance }("");
        if (!ok) revert NativeTransferFailed();
    }
}
