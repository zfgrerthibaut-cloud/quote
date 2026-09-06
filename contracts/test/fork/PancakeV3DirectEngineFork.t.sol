// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

import {
    INonfungiblePositionManager,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "../../src/interfaces/IPancakeV3.sol";
import { TokenMode, V2FeeConfig } from "../../src/v2/QuoteV2Types.sol";
import {
    QuoteLaunchArtifacts,
    QuoteLaunchContext,
    QuoteLaunchEngineKind
} from "../../src/v2/core/IQuoteLaunchEngine.sol";
import { PancakeV3DirectEngine } from "../../src/v2/direct/PancakeV3DirectEngine.sol";
import { QuoteDirectToken } from "../../src/v2/direct/QuoteDirectToken.sol";
import { PermanentPancakeV3Locker } from "../../src/v2/locker/PermanentPancakeV3Locker.sol";
import { IWBNB } from "../../src/v2/native/INativeDevBuyAdapters.sol";
import { V2QuoteUsdPriceVerifier } from "../../src/v2/oracle/V2QuoteUsdPriceVerifier.sol";
import {
    IPancakeV3SwapRouterLike
} from "../../src/v2/adapters/interfaces/IPancakeV3AdapterTypes.sol";

contract DirectForkLaunchpad {
    function launch(
        PancakeV3DirectEngine engine,
        QuoteLaunchContext calldata context,
        bytes calldata payload
    ) external returns (QuoteLaunchArtifacts memory) {
        return engine.launch(context, payload);
    }
}

contract PancakeV3DirectEngineForkTest is Test {
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant POSITION_MANAGER = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant WBNB_USDT_POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant SUPPLY = 100_000_000 ether;
    bytes32 internal constant ENGINE_VERSION = keccak256("QUOTE:DIRECT:V3:1");

    function setUp() external {
        vm.createSelectFork(vm.envString("BSC_RPC_URL"));
    }

    function testDirectEngineCreatesPriceDerivedCanonicalLockedPosition() external {
        DirectForkLaunchpad launchpad = new DirectForkLaunchpad();
        address[] memory references = new address[](1);
        references[0] = WBNB;
        V2QuoteUsdPriceVerifier verifier = new V2QuoteUsdPriceVerifier(
            address(this), vm.addr(SIGNER_KEY), 10_000e18, 15 minutes, references
        );
        PancakeV3DirectEngine engine = new PancakeV3DirectEngine(
            address(launchpad),
            ENGINE_VERSION,
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(POSITION_MANAGER),
            IPancakeV3SwapRouterLike(SWAP_ROUTER),
            IWBNB(WBNB),
            verifier,
            makeAddr("treasury")
        );

        PancakeV3DirectEngine.LaunchPayload memory payload;
        payload.name = "Fork Direct V3";
        payload.symbol = "FDV3";
        payload.referenceToken = WBNB;
        payload.referencePool = WBNB_USDT_POOL;

        payload.userSalt = bytes32("fork-direct-v3-token");
        QuoteLaunchContext memory context = QuoteLaunchContext({
            launchId: 0,
            creator: address(this),
            quoteToken: WBNB,
            supply: SUPPLY,
            nativeAmount: 0,
            deadline: block.timestamp + 30 minutes,
            tokenMode: TokenMode.STANDARD,
            feeConfig: V2FeeConfig({
                creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 7_000
            }),
            creatorFeeRecipient: address(this),
            rewardFeeRecipient: address(0),
            engineKind: QuoteLaunchEngineKind.DIRECT,
            engineVersion: ENGINE_VERSION
        });
        payload.quoteAttestation = V2QuoteUsdPriceVerifier.QuotePriceAttestation({
            consumer: address(engine),
            creator: address(this),
            launchRequestHash: engine.launchRequestHash(context, payload),
            quoteToken: WBNB,
            referenceToken: WBNB,
            referencePool: WBNB_USDT_POOL,
            priceUsdWad: 600e18,
            liquidityUsdWad: 10_000e18,
            observationTimestamp: uint64(block.timestamp),
            deadline: uint64(block.timestamp + 10 minutes),
            nonce: bytes32("fork-direct-v3")
        });
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SIGNER_KEY, verifier.hashAttestation(payload.quoteAttestation));
        payload.quoteAttestationSignature = abi.encodePacked(r, s, v);

        QuoteLaunchArtifacts memory artifacts =
            launchpad.launch(engine, context, abi.encode(payload));
        PancakeV3DirectEngine.DirectLaunchRecord memory record = engine.recordAt(0);
        (, int24 currentTick,,,,,) = IPancakeV3Pool(record.pool).slot0();

        assertEq(artifacts.token, record.token);
        assertTrue(artifacts.token != WBNB);
        assertEq(
            IPancakeV3Factory(PANCAKE_V3_FACTORY).getPool(record.token, WBNB, 10_000), record.pool
        );
        assertEq(record.feeTier, 10_000);
        assertEq(IERC721(POSITION_MANAGER).ownerOf(record.positionTokenId), record.locker);
        assertTrue(PermanentPancakeV3Locker(record.locker).finalized());
        assertEq(record.tickLower % 200, 0);
        assertEq(record.tickUpper % 200, 0);
        if (record.token < WBNB) {
            assertGt(record.tickLower, currentTick);
            assertEq(record.tickUpper, 887_200);
        } else {
            assertLe(record.tickUpper, currentTick);
            assertEq(record.tickLower, -887_200);
        }
        assertLe(SUPPLY - record.depositedSupply, SUPPLY / engine.MAX_DUST_DIVISOR());
        assertEq(QuoteDirectToken(record.token).totalSupply(), record.depositedSupply);
        assertEq(IERC20(record.token).balanceOf(record.pool), record.depositedSupply);
        assertEq(IERC20(record.token).balanceOf(address(engine)), 0);
    }
}
