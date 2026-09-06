// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

import { ForkPareFactory } from "../../src/ForkPareFactory.sol";
import { ForkPareToken } from "../../src/ForkPareToken.sol";
import { PermanentV3Locker } from "../../src/PermanentV3Locker.sol";
import {
    INonfungiblePositionManager,
    IPancakeV3Factory
} from "../../src/interfaces/IPancakeV3.sol";

interface IPancakePoolCreator {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IPancakePoolInitializer {
    function initialize(uint160 sqrtPriceX96) external;
}

interface IWBNB is IERC20 {
    function deposit() external payable;
}

interface IPancakeV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

contract PancakeV3ForkTest is Test {
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant POSITION_MANAGER = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    uint256 internal constant SUPPLY = 100_000_000 ether;

    ForkPareFactory internal launchFactory;
    address internal treasury;

    function setUp() external {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
        treasury = makeAddr("treasury");
        launchFactory = new ForkPareFactory(
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(POSITION_MANAGER),
            treasury,
            0
        );
    }

    function testCanonicalDependenciesAndFeeTiers() external view {
        assertEq(block.chainid, 56);
        assertGt(PANCAKE_V3_FACTORY.code.length, 0);
        assertGt(POSITION_MANAGER.code.length, 0);
        assertGt(SWAP_ROUTER.code.length, 0);

        IPancakeV3Factory factory = IPancakeV3Factory(PANCAKE_V3_FACTORY);
        assertEq(factory.feeAmountTickSpacing(100), 1);
        assertEq(factory.feeAmountTickSpacing(500), 10);
        assertEq(factory.feeAmountTickSpacing(2500), 50);
        assertEq(factory.feeAmountTickSpacing(10_000), 200);
    }

    function testAllEnabledFeeTiersLaunchCanonicalLockedPositions() external {
        uint24[4] memory feeTiers = [uint24(100), uint24(500), uint24(2_500), uint24(10_000)];
        int24[4] memory spacings = [int24(1), int24(10), int24(50), int24(200)];

        for (uint256 i; i < feeTiers.length; ++i) {
            ForkPareFactory.LaunchParams memory params = ForkPareFactory.LaunchParams({
                name: "ForkPare Fee Tier",
                symbol: "FPTIER",
                supply: SUPPLY,
                quoteToken: WBNB,
                feeTier: feeTiers[i],
                sqrtPriceX96: uint160(1 << 96),
                tickLower: spacings[i],
                tickUpper: (int24(887_272) / spacings[i]) * spacings[i],
                deadline: block.timestamp + 1 hours,
                userSalt: bytes32(i)
            });
            _findToken0(params);

            ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

            assertEq(record.feeTier, feeTiers[i]);
            assertEq(IERC721(POSITION_MANAGER).ownerOf(record.positionTokenId), record.locker);
            assertEq(IERC20(record.token).balanceOf(record.pool), record.supply);
            assertEq(ForkPareToken(record.token).totalSupply(), record.supply);
        }
    }

    function testLaunchCreatesRealPancakePoolAndLockedPosition() external {
        ForkPareFactory.LaunchParams memory params = ForkPareFactory.LaunchParams({
            name: "ForkPare Fork Test",
            symbol: "FPFORK",
            supply: SUPPLY,
            quoteToken: WBNB,
            feeTier: 500,
            sqrtPriceX96: uint160(1 << 96),
            tickLower: 10,
            tickUpper: 887_270,
            deadline: block.timestamp + 1 hours,
            userSalt: bytes32(0)
        });

        bool tokenIsToken0;
        for (uint256 i; i < 256; ++i) {
            params.userSalt = bytes32(i);
            if (launchFactory.predictToken(address(this), params) < WBNB) {
                tokenIsToken0 = true;
                break;
            }
        }
        assertTrue(tokenIsToken0, "could not find token0 salt");

        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

        assertEq(
            IPancakeV3Factory(PANCAKE_V3_FACTORY).getPool(record.token, WBNB, 500), record.pool
        );
        assertGt(record.pool.code.length, 0);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(record.positionTokenId), record.locker);
        assertEq(IERC20(record.token).balanceOf(record.pool), SUPPLY);
        assertEq(ForkPareToken(record.token).totalSupply(), SUPPLY);
        assertTrue(PermanentV3Locker(record.locker).initialized());
    }

    function testLaunchWorksWhenNewTokenSortsAsToken1() external {
        ForkPareFactory.LaunchParams memory params = ForkPareFactory.LaunchParams({
            name: "ForkPare Reverse Test",
            symbol: "FPREV",
            supply: SUPPLY,
            quoteToken: WBNB,
            feeTier: 500,
            sqrtPriceX96: uint160(1 << 96),
            tickLower: -887_270,
            tickUpper: -10,
            deadline: block.timestamp + 1 hours,
            userSalt: bytes32(0)
        });

        bool tokenIsToken1;
        for (uint256 i; i < 256; ++i) {
            params.userSalt = bytes32(i);
            if (launchFactory.predictToken(address(this), params) > WBNB) {
                tokenIsToken1 = true;
                break;
            }
        }
        assertTrue(tokenIsToken1, "could not find token1 salt");

        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

        assertEq(
            IPancakeV3Factory(PANCAKE_V3_FACTORY).getPool(record.token, WBNB, 500), record.pool
        );
        assertEq(IERC721(POSITION_MANAGER).ownerOf(record.positionTokenId), record.locker);
        assertEq(IERC20(record.token).balanceOf(record.pool), SUPPLY);
    }

    function testPrecreatedUninitializedCanonicalPoolDoesNotKillSalt() external {
        ForkPareFactory.LaunchParams memory params = _token0Params("ForkPare Precreate", "FPPRE");
        address predicted = _findToken0(params);
        address precreatedPool =
            IPancakePoolCreator(PANCAKE_V3_FACTORY).createPool(predicted, WBNB, params.feeTier);

        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

        assertEq(record.pool, precreatedPool);
        assertEq(record.token, predicted);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(record.positionTokenId), record.locker);
    }

    function testPreinitializedWrongPriceSkipsToLaunchableSalt() external {
        ForkPareFactory.LaunchParams memory params = _token0Params("ForkPare Conflict", "FPCON");
        address squatted = _findToken0(params);
        address precreatedPool =
            IPancakePoolCreator(PANCAKE_V3_FACTORY).createPool(squatted, WBNB, params.feeTier);
        IPancakePoolInitializer(precreatedPool).initialize(uint160(1 << 95));

        address replacement = launchFactory.predictToken(address(this), params);
        assertNotEq(replacement, squatted);
        assertLt(uint160(replacement), uint160(WBNB));

        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);
        assertEq(record.token, replacement);
        assertNotEq(record.pool, precreatedPool);
        assertEq(squatted.code.length, 0);
    }

    function testRealRoundTripAccruesAndSplitsFees() external {
        ForkPareFactory.LaunchParams memory params = _token0Params("ForkPare Fee Test", "FPFEE");
        _findToken0(params);
        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

        vm.deal(address(this), 1 ether);
        IWBNB(WBNB).deposit{ value: 1 ether }();
        IERC20(WBNB).approve(SWAP_ROUTER, type(uint256).max);

        uint256 tokensBought = IPancakeV3SwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: WBNB,
                tokenOut: record.token,
                fee: params.feeTier,
                recipient: address(this),
                deadline: block.timestamp + 1 hours,
                amountIn: 0.1 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
            );
        assertGt(tokensBought, 0, "buy must return launch tokens");

        uint256 tokensSold = tokensBought / 2;
        IERC20(record.token).approve(SWAP_ROUTER, tokensSold);
        uint256 quoteReturned = IPancakeV3SwapRouter(SWAP_ROUTER)
            .exactInputSingle(
                IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: record.token,
                tokenOut: WBNB,
                fee: params.feeTier,
                recipient: address(this),
                deadline: block.timestamp + 1 hours,
                amountIn: tokensSold,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
            );
        assertGt(quoteReturned, 0, "sell must return quote tokens");

        (uint256 tokenFees, uint256 quoteFees) = PermanentV3Locker(record.locker).collect();
        assertGt(tokenFees, 0, "sell must accrue token-side fees");
        assertGt(quoteFees, 0, "buy must accrue quote-side fees");

        uint256 creatorTokenFees =
            PermanentV3Locker(record.locker).claimable(address(this), record.token);
        uint256 treasuryTokenFees =
            PermanentV3Locker(record.locker).claimable(treasury, record.token);
        uint256 creatorQuoteFees = PermanentV3Locker(record.locker).claimable(address(this), WBNB);
        uint256 treasuryQuoteFees = PermanentV3Locker(record.locker).claimable(treasury, WBNB);

        assertEq(creatorTokenFees + treasuryTokenFees, tokenFees);
        assertEq(creatorQuoteFees + treasuryQuoteFees, quoteFees);
        assertEq(creatorTokenFees, (tokenFees * 7_000) / 10_000);
        assertEq(creatorQuoteFees, (quoteFees * 7_000) / 10_000);

        uint256 tokenBalanceBefore = IERC20(record.token).balanceOf(address(this));
        uint256 quoteBalanceBefore = IERC20(WBNB).balanceOf(address(this));
        PermanentV3Locker(record.locker).claim(record.token);
        PermanentV3Locker(record.locker).claim(WBNB);
        assertEq(
            IERC20(record.token).balanceOf(address(this)) - tokenBalanceBefore, creatorTokenFees
        );
        assertEq(IERC20(WBNB).balanceOf(address(this)) - quoteBalanceBefore, creatorQuoteFees);
    }

    function testLaunchAtLowStartPriceBurnsOnlyRoundingDustAndLocksFinalSupply() external {
        ForkPareFactory.LaunchParams memory params = _token0Params("ForkPare Low Price", "FPLOW");
        params.sqrtPriceX96 = 79_228_162_514_264_337_593_543_950;
        params.tickLower = -138_160;
        _findToken0(params);

        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

        assertLe(record.supply, SUPPLY);
        assertLe(SUPPLY - record.supply, SUPPLY / launchFactory.MAX_DUST_DIVISOR());
        assertEq(IERC20(record.token).balanceOf(record.pool), record.supply);
        assertEq(IERC20(record.token).balanceOf(address(launchFactory)), 0);
        assertEq(ForkPareToken(record.token).totalSupply(), record.supply);
    }

    function testLaunchAtHighStartPriceUsesExactFullSupply() external {
        ForkPareFactory.LaunchParams memory params = ForkPareFactory.LaunchParams({
            name: "ForkPare High Price",
            symbol: "FPHIGH",
            supply: SUPPLY,
            quoteToken: WBNB,
            feeTier: 500,
            sqrtPriceX96: 79_228_162_514_264_337_593_543_950,
            tickLower: -887_270,
            tickUpper: -138_170,
            deadline: block.timestamp + 1 hours,
            userSalt: bytes32(0)
        });
        _findToken1(params);

        ForkPareFactory.LaunchRecord memory record = launchFactory.launch(params);

        assertEq(IERC20(record.token).balanceOf(record.pool), SUPPLY);
        assertEq(IERC20(record.token).balanceOf(address(launchFactory)), 0);
        assertEq(ForkPareToken(record.token).totalSupply(), SUPPLY);
    }

    function _token0Params(string memory name, string memory symbol)
        internal
        view
        returns (ForkPareFactory.LaunchParams memory params)
    {
        params = ForkPareFactory.LaunchParams({
            name: name,
            symbol: symbol,
            supply: SUPPLY,
            quoteToken: WBNB,
            feeTier: 500,
            sqrtPriceX96: uint160(1 << 96),
            tickLower: 10,
            tickUpper: 887_270,
            deadline: block.timestamp + 1 hours,
            userSalt: bytes32(0)
        });
    }

    function _findToken0(ForkPareFactory.LaunchParams memory params)
        internal
        view
        returns (address predicted)
    {
        for (uint256 i; i < 256; ++i) {
            params.userSalt = bytes32(i);
            predicted = launchFactory.predictToken(address(this), params);
            if (predicted < WBNB) return predicted;
        }
        revert("could not find token0 salt");
    }

    function _findToken1(ForkPareFactory.LaunchParams memory params)
        internal
        view
        returns (address predicted)
    {
        for (uint256 i; i < 256; ++i) {
            params.userSalt = bytes32(i);
            predicted = launchFactory.predictToken(address(this), params);
            if (predicted > WBNB) return predicted;
        }
        revert("could not find token1 salt");
    }
}
