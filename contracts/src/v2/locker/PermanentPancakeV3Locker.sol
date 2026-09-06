// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721Receiver } from "openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import { INonfungiblePositionManager } from "../../interfaces/IPancakeV3.sol";

/// @notice Holds one expected Pancake V3 position NFT forever and splits collected fees.
/// @dev No NFT approval, NFT transfer, liquidity decrease, burn, or arbitrary-call function exists.
contract PermanentPancakeV3Locker is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_CREATOR_FEE_BPS = BPS;

    INonfungiblePositionManager public immutable positionManager;
    address public immutable factory;
    address public immutable creator;
    address public immutable protocolTreasury;
    uint16 public immutable creatorFeeBps;
    uint256 public immutable expectedTokenId;

    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickLower;
    int24 public tickUpper;
    bool public received;
    bool public finalized;

    mapping(address beneficiary => mapping(address token => uint256 amount)) public claimable;
    mapping(address token => uint256 remainder) public creatorFeeRemainder;

    error AlreadyFinalized();
    error AlreadyReceived();
    error InvalidConfiguration();
    error InvalidPosition();
    error NotBeneficiary();
    error NotFactory();
    error NotPositionManager();
    error NotReceived();
    error UnexpectedNft();
    error BadClaimDebit(uint256 expectedDebit, uint256 actualDebit);

    event PositionReceived(uint256 indexed tokenId);
    event PositionFinalized(
        uint256 indexed tokenId,
        address indexed token0,
        address indexed token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    );
    event FeesCollected(
        uint256 amount0,
        uint256 amount1,
        uint256 creatorAmount0,
        uint256 creatorAmount1,
        uint256 protocolAmount0,
        uint256 protocolAmount1
    );
    event FeesClaimed(address indexed beneficiary, address indexed token, uint256 amount);

    constructor(
        INonfungiblePositionManager positionManager_,
        address factory_,
        address creator_,
        address protocolTreasury_,
        uint16 creatorFeeBps_,
        uint256 expectedTokenId_
    ) {
        if (
            address(positionManager_) == address(0) || address(positionManager_).code.length == 0
                || factory_ == address(0) || creator_ == address(0)
                || protocolTreasury_ == address(0) || creatorFeeBps_ > MAX_CREATOR_FEE_BPS
                || expectedTokenId_ == 0
        ) revert InvalidConfiguration();

        positionManager = positionManager_;
        factory = factory_;
        creator = creator_;
        protocolTreasury = protocolTreasury_;
        creatorFeeBps = creatorFeeBps_;
        expectedTokenId = expectedTokenId_;
    }

    function finalize(
        address token0_,
        address token1_,
        uint24 fee_,
        int24 tickLower_,
        int24 tickUpper_
    ) external {
        if (msg.sender != factory) revert NotFactory();
        if (!received) revert NotReceived();
        if (finalized) revert AlreadyFinalized();
        if (token0_ == address(0) || token1_ == address(0) || token0_ == token1_) {
            revert InvalidPosition();
        }

        (
            ,,
            address positionToken0,
            address positionToken1,
            uint24 positionFee,
            int24 positionTickLower,
            int24 positionTickUpper,
            uint128 positionLiquidity,,,,
        ) = positionManager.positions(expectedTokenId);

        if (
            positionManager.ownerOf(expectedTokenId) != address(this) || positionToken0 != token0_
                || positionToken1 != token1_ || positionFee != fee_
                || positionTickLower != tickLower_ || positionTickUpper != tickUpper_
                || positionLiquidity == 0
        ) revert InvalidPosition();

        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        finalized = true;

        emit PositionFinalized(expectedTokenId, token0_, token1_, fee_, tickLower_, tickUpper_);
    }

    function collect() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!finalized) revert InvalidPosition();

        address token0_ = token0;
        address token1_ = token1;
        uint256 balance0Before = IERC20(token0_).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1_).balanceOf(address(this));

        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: expectedTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        amount0 = IERC20(token0_).balanceOf(address(this)) - balance0Before;
        amount1 = IERC20(token1_).balanceOf(address(this)) - balance1Before;

        (uint256 creatorAmount0, uint256 protocolAmount0) = _splitCollectedFee(token0_, amount0);
        (uint256 creatorAmount1, uint256 protocolAmount1) = _splitCollectedFee(token1_, amount1);

        claimable[creator][token0_] += creatorAmount0;
        claimable[protocolTreasury][token0_] += protocolAmount0;
        claimable[creator][token1_] += creatorAmount1;
        claimable[protocolTreasury][token1_] += protocolAmount1;

        emit FeesCollected(
            amount0, amount1, creatorAmount0, creatorAmount1, protocolAmount0, protocolAmount1
        );
    }

    function claim(address token) external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator && msg.sender != protocolTreasury) revert NotBeneficiary();
        if (!finalized || (token != token0 && token != token1)) revert InvalidPosition();

        amount = claimable[msg.sender][token];
        claimable[msg.sender][token] = 0;
        if (amount != 0) {
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(msg.sender, amount);
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            if (balanceAfter > balanceBefore) revert BadClaimDebit(amount, 0);
            uint256 debit = balanceBefore - balanceAfter;
            if (debit != amount) revert BadClaimDebit(amount, debit);
        }

        emit FeesClaimed(msg.sender, token, amount);
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        if (received) revert AlreadyReceived();
        // Engines cannot know Pancake's next position id before minting. They may therefore mint
        // to themselves and immediately forward the exact returned id here in the same launch.
        if ((from != address(0) && from != factory) || tokenId != expectedTokenId) {
            revert UnexpectedNft();
        }

        received = true;
        emit PositionReceived(tokenId);

        return IERC721Receiver.onERC721Received.selector;
    }

    function _splitCollectedFee(address token, uint256 amount)
        private
        returns (uint256 creatorAmount, uint256 protocolAmount)
    {
        uint256 creatorNumerator = amount * creatorFeeBps + creatorFeeRemainder[token];
        creatorAmount = creatorNumerator / BPS;
        creatorFeeRemainder[token] = creatorNumerator % BPS;
        protocolAmount = amount - creatorAmount;
    }
}
