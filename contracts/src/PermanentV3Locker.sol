// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721Receiver } from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { Math } from "openzeppelin-contracts/contracts/utils/math/Math.sol";

import { INonfungiblePositionManager } from "./interfaces/IPancakeV3.sol";

/// @notice Holds a Pancake V3 position forever while splitting collected trading fees.
/// @dev There is intentionally no NFT transfer, approval or decrease-liquidity function.
contract PermanentV3Locker is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;

    INonfungiblePositionManager public immutable positionManager;
    address public immutable factory;
    address public immutable creator;
    address public immutable protocolTreasury;
    uint16 public immutable creatorFeeBps;

    uint256 public tokenId;
    address public token0;
    address public token1;
    bool public initialized;
    mapping(address beneficiary => mapping(address token => uint256 amount)) public claimable;
    mapping(address token => uint256 amount) private _totalCollected;
    mapping(address token => uint256 amount) private _creatorCollectedShare;

    error AlreadyInitialized();
    error NotFactory();
    error NotPositionManager();
    error InvalidPosition();
    error NotBeneficiary();
    error InvalidConfiguration();
    error BadBalanceDelta();

    event PositionLocked(uint256 indexed tokenId, address indexed token0, address indexed token1);
    event FeesCollected(
        uint256 amount0, uint256 amount1, uint256 creatorAmount0, uint256 creatorAmount1
    );
    event FeesClaimed(address indexed beneficiary, address indexed token, uint256 amount);

    constructor(
        INonfungiblePositionManager positionManager_,
        address factory_,
        address creator_,
        address protocolTreasury_,
        uint16 creatorFeeBps_
    ) {
        if (
            address(positionManager_) == address(0) || factory_ == address(0)
                || creator_ == address(0) || protocolTreasury_ == address(0) || creatorFeeBps_ > BPS
        ) revert InvalidConfiguration();
        positionManager = positionManager_;
        factory = factory_;
        creator = creator_;
        protocolTreasury = protocolTreasury_;
        creatorFeeBps = creatorFeeBps_;
    }

    function initialize(uint256 tokenId_, address token0_, address token1_) external {
        if (msg.sender != factory) revert NotFactory();
        if (initialized) revert AlreadyInitialized();
        if (tokenId_ == 0 || token0_ == address(0) || token1_ == address(0)) {
            revert InvalidPosition();
        }

        tokenId = tokenId_;
        token0 = token0_;
        token1 = token1_;
        initialized = true;

        emit PositionLocked(tokenId_, token0_, token1_);
    }

    function collect() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!initialized) revert InvalidPosition();

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));
        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        amount0 = IERC20(token0).balanceOf(address(this)) - balance0Before;
        amount1 = IERC20(token1).balanceOf(address(this)) - balance1Before;

        (uint256 creatorAmount0, uint256 protocolAmount0) = _splitCollected(token0, amount0);
        (uint256 creatorAmount1, uint256 protocolAmount1) = _splitCollected(token1, amount1);

        claimable[creator][token0] += creatorAmount0;
        claimable[protocolTreasury][token0] += protocolAmount0;
        claimable[creator][token1] += creatorAmount1;
        claimable[protocolTreasury][token1] += protocolAmount1;

        emit FeesCollected(amount0, amount1, creatorAmount0, creatorAmount1);
    }

    function claim(address token) external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator && msg.sender != protocolTreasury) revert NotBeneficiary();
        if (token != token0 && token != token1) revert InvalidPosition();
        amount = claimable[msg.sender][token];
        claimable[msg.sender][token] = 0;
        if (amount != 0) {
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(msg.sender, amount);
            if (
                balanceBefore < amount
                    || IERC20(token).balanceOf(address(this)) != balanceBefore - amount
            ) revert BadBalanceDelta();
        }
        emit FeesClaimed(msg.sender, token, amount);
    }

    function _splitCollected(address token, uint256 amount)
        private
        returns (uint256 creatorAmount, uint256 protocolAmount)
    {
        if (amount == 0) return (0, 0);

        uint256 totalCollectedAfter = _totalCollected[token] + amount;
        uint256 creatorShareAfter =
            Math.mulDiv(totalCollectedAfter, creatorFeeBps, BPS, Math.Rounding.Floor);
        creatorAmount = creatorShareAfter - _creatorCollectedShare[token];
        protocolAmount = amount - creatorAmount;

        _totalCollected[token] = totalCollectedAfter;
        _creatorCollectedShare[token] = creatorShareAfter;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }
}
