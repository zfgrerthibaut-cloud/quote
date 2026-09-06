// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { DeployQuoteV2 } from "../../script/DeployQuoteV2.s.sol";
import { QuoteLaunchEngineKind } from "../../src/v2/core/IQuoteLaunchEngine.sol";
import { QuoteLaunchpad } from "../../src/v2/core/QuoteLaunchpad.sol";

contract DeployQuoteV2Test is Test {
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant PANCAKE_V3_POSITION_MANAGER =
        0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal signer = makeAddr("signer");
    bytes32 internal constant DIRECT_ENGINE_VERSION = keccak256("QUOTE:DIRECT:V3:1");

    function setUp() external {
        vm.chainId(56);
        _etchCode(PANCAKE_V3_FACTORY);
        _etchCode(PANCAKE_V3_POSITION_MANAGER);
        _etchCode(PANCAKE_V3_SWAP_ROUTER);
        _etchCode(WBNB);

        vm.mockCall(
            PANCAKE_V3_POSITION_MANAGER,
            abi.encodeWithSignature("factory()"),
            abi.encode(PANCAKE_V3_FACTORY)
        );
        vm.mockCall(
            PANCAKE_V3_POSITION_MANAGER, abi.encodeWithSignature("WETH9()"), abi.encode(WBNB)
        );
        vm.mockCall(
            PANCAKE_V3_SWAP_ROUTER,
            abi.encodeWithSignature("factory()"),
            abi.encode(PANCAKE_V3_FACTORY)
        );
        vm.mockCall(PANCAKE_V3_SWAP_ROUTER, abi.encodeWithSignature("WETH9()"), abi.encode(WBNB));
        vm.mockCall(
            PANCAKE_V3_FACTORY,
            abi.encodeWithSignature("feeAmountTickSpacing(uint24)", uint24(10_000)),
            abi.encode(int24(200))
        );

        vm.setEnv("QUOTE_V2_UPGRADE_ADMIN", vm.toString(admin));
        vm.setEnv("QUOTE_V2_PAUSE_GUARDIAN", vm.toString(guardian));
        vm.setEnv("QUOTE_V2_TREASURY", vm.toString(treasury));
        vm.setEnv("QUOTE_V2_PRICE_SIGNER", vm.toString(signer));
        vm.setEnv("QUOTE_V2_MIN_LIQUIDITY_USD_WAD", vm.toString(uint256(10_000e18)));
        vm.setEnv("QUOTE_V2_MAX_OBSERVATION_AGE", vm.toString(uint256(900)));
        vm.setEnv("QUOTE_V2_REFERENCE_TOKENS", vm.toString(WBNB));
    }

    function testRunDeploysProxyVerifierAndDirectEngineWithoutBroadcast() external {
        DeployQuoteV2 script = new DeployQuoteV2();

        DeployQuoteV2.Deployment memory deployment = script.run();

        assertEq(deployment.launchpad.upgradeAdmin(), admin);
        assertEq(deployment.launchpad.pauseGuardian(), guardian);
        assertEq(deployment.verifier.owner(), admin);
        assertEq(deployment.verifier.signer(), signer);
        assertEq(deployment.verifier.minLiquidityUsdWad(), 10_000e18);
        assertEq(deployment.verifier.maxObservationAge(), 900);
        assertTrue(deployment.verifier.isReferenceTokenAllowed(WBNB));
        assertEq(deployment.directEngine.launchpad(), address(deployment.launchpad));
        assertEq(deployment.directEngine.engineVersion(), DIRECT_ENGINE_VERSION);
        assertEq(uint8(deployment.directEngine.engineKind()), uint8(QuoteLaunchEngineKind.DIRECT));
        assertEq(address(deployment.directEngine.pancakeFactory()), PANCAKE_V3_FACTORY);
        assertEq(address(deployment.directEngine.positionManager()), PANCAKE_V3_POSITION_MANAGER);
        assertEq(address(deployment.directEngine.swapRouter()), PANCAKE_V3_SWAP_ROUTER);
        assertEq(address(deployment.directEngine.quoteVerifier()), address(deployment.verifier));
        assertEq(deployment.directEngine.protocolTreasury(), treasury);
        assertGt(address(deployment.directEngine.tokenDeployer()).code.length, 0);
        assertGt(address(deployment.directEngine.lockerDeployer()).code.length, 0);
        assertGt(address(deployment.directEngine.nativeBuy()).code.length, 0);

        assertEq(
            deployment.launchpad.defaultEngineVersion(QuoteLaunchEngineKind.DIRECT),
            DIRECT_ENGINE_VERSION
        );
        assertEq(deployment.launchpad.launchCount(), 0);
        assertFalse(deployment.launchpad.newLaunchesPaused());
        assertEq(deployment.launchpad.upgradeAdmin(), admin);

        QuoteLaunchpad.EngineConfig memory engineConfig =
            deployment.launchpad.engineConfig(DIRECT_ENGINE_VERSION);
        assertEq(engineConfig.engine, address(deployment.directEngine));
        assertEq(engineConfig.codehash, address(deployment.directEngine).codehash);
        assertEq(uint8(engineConfig.kind), uint8(QuoteLaunchEngineKind.DIRECT));
        assertTrue(engineConfig.enabled);
    }

    function testRunRejectsWrongChain() external {
        vm.chainId(97);
        DeployQuoteV2 script = new DeployQuoteV2();

        vm.expectRevert(abi.encodeWithSelector(DeployQuoteV2.WrongChain.selector, uint256(97)));
        script.run();
    }

    function testRunRejectsBrokenPancakeDependency() external {
        vm.mockCall(
            PANCAKE_V3_SWAP_ROUTER,
            abi.encodeWithSignature("factory()"),
            abi.encode(makeAddr("wrongFactory"))
        );
        DeployQuoteV2 script = new DeployQuoteV2();

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployQuoteV2.BadCanonicalDependency.selector,
                bytes32("ROUTER_FACTORY"),
                PANCAKE_V3_FACTORY,
                makeAddr("wrongFactory")
            )
        );
        script.run();
    }

    function _etchCode(address account) private {
        vm.etch(account, hex"00");
    }
}
