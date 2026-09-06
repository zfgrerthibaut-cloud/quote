// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { INonfungiblePositionManager, IPancakeV3Factory } from "../src/interfaces/IPancakeV3.sol";
import { IPancakeV3SwapRouterLike } from "../src/v2/adapters/interfaces/IPancakeV3AdapterTypes.sol";
import { QuoteLaunchEngineKind } from "../src/v2/core/IQuoteLaunchEngine.sol";
import { QuoteLaunchpad } from "../src/v2/core/QuoteLaunchpad.sol";
import { PancakeV3DirectEngine } from "../src/v2/direct/PancakeV3DirectEngine.sol";
import { IWBNB } from "../src/v2/native/INativeDevBuyAdapters.sol";
import { V2QuoteUsdPriceVerifier } from "../src/v2/oracle/V2QuoteUsdPriceVerifier.sol";

interface IWethAware {
    function WETH9() external view returns (address);
}

interface IFactoryAware {
    function factory() external view returns (address);
}

/// @notice Broadcast-free QUOTE V2 mainnet deployment rehearsal.
/// @dev This script intentionally never calls vm.startBroadcast/vm.broadcast and never reads a key.
///      It deploys against the selected fork/local EVM, simulates admin registry calls with prank,
///      and fails unless BSC mainnet Pancake dependencies and QUOTE bootstrap assertions hold.
contract DeployQuoteV2 is Script {
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant PANCAKE_V3_POSITION_MANAGER =
        0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    address internal constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint256 internal constant BSC_CHAIN_ID = 56;
    uint24 internal constant DIRECT_POOL_FEE = 10_000;
    int24 internal constant DIRECT_POOL_TICK_SPACING = 200;
    bytes32 internal constant DIRECT_ENGINE_VERSION = keccak256("QUOTE:DIRECT:V3:1");

    bytes32 private constant CHECK_FACTORY_CODE = "PANCAKE_FACTORY_CODE";
    bytes32 private constant CHECK_POSITION_MANAGER_CODE = "PANCAKE_NPM_CODE";
    bytes32 private constant CHECK_SWAP_ROUTER_CODE = "PANCAKE_ROUTER_CODE";
    bytes32 private constant CHECK_WBNB_CODE = "WBNB_CODE";
    bytes32 private constant CHECK_POSITION_MANAGER_FACTORY = "NPM_FACTORY";
    bytes32 private constant CHECK_POSITION_MANAGER_WBNB = "NPM_WBNB";
    bytes32 private constant CHECK_SWAP_ROUTER_FACTORY = "ROUTER_FACTORY";
    bytes32 private constant CHECK_SWAP_ROUTER_WBNB = "ROUTER_WBNB";
    bytes32 private constant CHECK_DIRECT_TICK_SPACING = "DIRECT_TICK_SPACING";
    bytes32 private constant CHECK_PROXY_ADMIN = "PROXY_ADMIN";
    bytes32 private constant CHECK_PROXY_GUARDIAN = "PROXY_GUARDIAN";
    bytes32 private constant CHECK_VERIFIER_OWNER = "VERIFIER_OWNER";
    bytes32 private constant CHECK_VERIFIER_SIGNER = "VERIFIER_SIGNER";
    bytes32 private constant CHECK_VERIFIER_MIN_LIQUIDITY = "VERIFIER_MIN_LIQUIDITY";
    bytes32 private constant CHECK_VERIFIER_MAX_AGE = "VERIFIER_MAX_AGE";
    bytes32 private constant CHECK_REFERENCE_ALLOWED = "REFERENCE_ALLOWED";
    bytes32 private constant CHECK_ENGINE_LAUNCHPAD = "ENGINE_LAUNCHPAD";
    bytes32 private constant CHECK_ENGINE_VERSION = "ENGINE_VERSION";
    bytes32 private constant CHECK_ENGINE_KIND = "ENGINE_KIND";
    bytes32 private constant CHECK_ENGINE_FACTORY = "ENGINE_FACTORY";
    bytes32 private constant CHECK_ENGINE_POSITION_MANAGER = "ENGINE_NPM";
    bytes32 private constant CHECK_ENGINE_ROUTER = "ENGINE_ROUTER";
    bytes32 private constant CHECK_ENGINE_VERIFIER = "ENGINE_VERIFIER";
    bytes32 private constant CHECK_ENGINE_TREASURY = "ENGINE_TREASURY";
    bytes32 private constant CHECK_ENGINE_DEPLOYERS = "ENGINE_DEPLOYERS";
    bytes32 private constant CHECK_REGISTRY_ENGINE = "REGISTRY_ENGINE";
    bytes32 private constant CHECK_REGISTRY_CODEHASH = "REGISTRY_CODEHASH";
    bytes32 private constant CHECK_REGISTRY_KIND = "REGISTRY_KIND";
    bytes32 private constant CHECK_REGISTRY_ENABLED = "REGISTRY_ENABLED";
    bytes32 private constant CHECK_DEFAULT_DIRECT = "DEFAULT_DIRECT";

    struct DeployConfig {
        address upgradeAdmin;
        address pauseGuardian;
        address treasury;
        address signer;
        uint256 minLiquidityUsdWad;
        uint256 maxObservationAge;
        address[] referenceTokens;
    }

    struct Deployment {
        QuoteLaunchpad implementation;
        QuoteLaunchpad launchpad;
        ERC1967Proxy proxy;
        V2QuoteUsdPriceVerifier verifier;
        PancakeV3DirectEngine directEngine;
    }

    error WrongChain(uint256 chainId);
    error InvalidAddress(bytes32 field);
    error EmptyReferenceTokens();
    error MissingCanonicalContract(bytes32 check, address account);
    error BadCanonicalDependency(bytes32 check, address expected, address actual);
    error BadCanonicalValue(bytes32 check, int256 expected, int256 actual);
    error DeploymentAssertionFailed(bytes32 check);

    function run() external returns (Deployment memory deployment) {
        DeployConfig memory config = _loadConfig();
        _preflight(config);
        deployment = _deploy(config);
        _postDeploy(config, deployment);
        _printDeployment(deployment);
    }

    function _loadConfig() internal view returns (DeployConfig memory config) {
        config = DeployConfig({
            upgradeAdmin: vm.envAddress("QUOTE_V2_UPGRADE_ADMIN"),
            pauseGuardian: vm.envAddress("QUOTE_V2_PAUSE_GUARDIAN"),
            treasury: vm.envAddress("QUOTE_V2_TREASURY"),
            signer: vm.envAddress("QUOTE_V2_PRICE_SIGNER"),
            minLiquidityUsdWad: vm.envUint("QUOTE_V2_MIN_LIQUIDITY_USD_WAD"),
            maxObservationAge: vm.envUint("QUOTE_V2_MAX_OBSERVATION_AGE"),
            referenceTokens: vm.envAddress("QUOTE_V2_REFERENCE_TOKENS", ",")
        });
    }

    function _preflight(DeployConfig memory config) internal view {
        if (block.chainid != BSC_CHAIN_ID) revert WrongChain(block.chainid);
        _requireNonZero(config.upgradeAdmin, "QUOTE_V2_UPGRADE_ADMIN");
        _requireNonZero(config.pauseGuardian, "QUOTE_V2_PAUSE_GUARDIAN");
        _requireNonZero(config.treasury, "QUOTE_V2_TREASURY");
        _requireNonZero(config.signer, "QUOTE_V2_PRICE_SIGNER");
        if (config.referenceTokens.length == 0) revert EmptyReferenceTokens();

        _requireCode(CHECK_FACTORY_CODE, PANCAKE_V3_FACTORY);
        _requireCode(CHECK_POSITION_MANAGER_CODE, PANCAKE_V3_POSITION_MANAGER);
        _requireCode(CHECK_SWAP_ROUTER_CODE, PANCAKE_V3_SWAP_ROUTER);
        _requireCode(CHECK_WBNB_CODE, WBNB);

        _requireEqual(
            CHECK_POSITION_MANAGER_FACTORY,
            PANCAKE_V3_FACTORY,
            INonfungiblePositionManager(PANCAKE_V3_POSITION_MANAGER).factory()
        );
        _requireEqual(
            CHECK_POSITION_MANAGER_WBNB, WBNB, IWethAware(PANCAKE_V3_POSITION_MANAGER).WETH9()
        );
        _requireEqual(
            CHECK_SWAP_ROUTER_FACTORY,
            PANCAKE_V3_FACTORY,
            IFactoryAware(PANCAKE_V3_SWAP_ROUTER).factory()
        );
        _requireEqual(CHECK_SWAP_ROUTER_WBNB, WBNB, IWethAware(PANCAKE_V3_SWAP_ROUTER).WETH9());
        _requireEqual(
            CHECK_DIRECT_TICK_SPACING,
            int256(DIRECT_POOL_TICK_SPACING),
            int256(IPancakeV3Factory(PANCAKE_V3_FACTORY).feeAmountTickSpacing(DIRECT_POOL_FEE))
        );

        for (uint256 i; i < config.referenceTokens.length; ++i) {
            _requireNonZero(config.referenceTokens[i], "QUOTE_V2_REFERENCE_TOKENS");
            _requireCode(CHECK_REFERENCE_ALLOWED, config.referenceTokens[i]);
        }

        console2.log("QUOTE V2 dry-run preflight");
        console2.log("chainId", block.chainid);
        console2.log("directPoolFee", DIRECT_POOL_FEE);
        console2.logInt(int256(DIRECT_POOL_TICK_SPACING));
        console2.logAddress(PANCAKE_V3_FACTORY);
        console2.logAddress(PANCAKE_V3_POSITION_MANAGER);
        console2.logAddress(PANCAKE_V3_SWAP_ROUTER);
        console2.logAddress(WBNB);
        console2.logAddress(config.upgradeAdmin);
        console2.logAddress(config.pauseGuardian);
        console2.logAddress(config.treasury);
        console2.logAddress(config.signer);
        console2.log("minLiquidityUsdWad", config.minLiquidityUsdWad);
        console2.log("maxObservationAge", config.maxObservationAge);
        console2.log("referenceTokenCount", config.referenceTokens.length);
        console2.logBytes32(DIRECT_ENGINE_VERSION);
    }

    function _deploy(DeployConfig memory config) internal returns (Deployment memory deployment) {
        deployment.implementation = new QuoteLaunchpad();
        bytes memory initData = abi.encodeCall(
            QuoteLaunchpad.initialize,
            (QuoteLaunchpad.InitParams({
                    upgradeAdmin: config.upgradeAdmin, pauseGuardian: config.pauseGuardian
                }))
        );
        deployment.proxy = new ERC1967Proxy(address(deployment.implementation), initData);
        deployment.launchpad = QuoteLaunchpad(address(deployment.proxy));
        deployment.verifier = new V2QuoteUsdPriceVerifier(
            config.upgradeAdmin,
            config.signer,
            config.minLiquidityUsdWad,
            config.maxObservationAge,
            config.referenceTokens
        );
        deployment.directEngine = new PancakeV3DirectEngine(
            address(deployment.launchpad),
            DIRECT_ENGINE_VERSION,
            IPancakeV3Factory(PANCAKE_V3_FACTORY),
            INonfungiblePositionManager(PANCAKE_V3_POSITION_MANAGER),
            IPancakeV3SwapRouterLike(PANCAKE_V3_SWAP_ROUTER),
            IWBNB(WBNB),
            deployment.verifier,
            config.treasury
        );

        vm.startPrank(config.upgradeAdmin);
        deployment.launchpad
            .registerEngine(
                DIRECT_ENGINE_VERSION,
                address(deployment.directEngine),
                QuoteLaunchEngineKind.DIRECT,
                false
            );
        deployment.launchpad.setEngineEnabled(DIRECT_ENGINE_VERSION, true);
        deployment.launchpad
            .setDefaultEngineVersion(QuoteLaunchEngineKind.DIRECT, DIRECT_ENGINE_VERSION);
        vm.stopPrank();
    }

    function _postDeploy(DeployConfig memory config, Deployment memory deployment) internal view {
        _requireCode("IMPLEMENTATION_CODE", address(deployment.implementation));
        _requireCode("PROXY_CODE", address(deployment.proxy));
        _requireCode("VERIFIER_CODE", address(deployment.verifier));
        _requireCode("DIRECT_ENGINE_CODE", address(deployment.directEngine));

        _assertEq(CHECK_PROXY_ADMIN, deployment.launchpad.upgradeAdmin(), config.upgradeAdmin);
        _assertEq(CHECK_PROXY_GUARDIAN, deployment.launchpad.pauseGuardian(), config.pauseGuardian);
        _assertTrue("PROXY_UNPAUSED", !deployment.launchpad.newLaunchesPaused());
        _assertEq(CHECK_VERIFIER_OWNER, deployment.verifier.owner(), config.upgradeAdmin);
        _assertEq(CHECK_VERIFIER_SIGNER, deployment.verifier.signer(), config.signer);
        _assertEq(
            CHECK_VERIFIER_MIN_LIQUIDITY,
            deployment.verifier.minLiquidityUsdWad(),
            config.minLiquidityUsdWad
        );
        _assertEq(
            CHECK_VERIFIER_MAX_AGE,
            deployment.verifier.maxObservationAge(),
            config.maxObservationAge
        );
        for (uint256 i; i < config.referenceTokens.length; ++i) {
            _assertTrue(
                CHECK_REFERENCE_ALLOWED,
                deployment.verifier.isReferenceTokenAllowed(config.referenceTokens[i])
            );
        }

        _assertEq(
            CHECK_ENGINE_LAUNCHPAD,
            deployment.directEngine.launchpad(),
            address(deployment.launchpad)
        );
        _assertEq(
            CHECK_ENGINE_VERSION, deployment.directEngine.engineVersion(), DIRECT_ENGINE_VERSION
        );
        _assertTrue(
            CHECK_ENGINE_KIND, deployment.directEngine.engineKind() == QuoteLaunchEngineKind.DIRECT
        );
        _assertEq(
            CHECK_ENGINE_FACTORY,
            address(deployment.directEngine.pancakeFactory()),
            PANCAKE_V3_FACTORY
        );
        _assertEq(
            CHECK_ENGINE_POSITION_MANAGER,
            address(deployment.directEngine.positionManager()),
            PANCAKE_V3_POSITION_MANAGER
        );
        _assertEq(
            CHECK_ENGINE_ROUTER,
            address(deployment.directEngine.swapRouter()),
            PANCAKE_V3_SWAP_ROUTER
        );
        _assertEq(
            CHECK_ENGINE_VERIFIER,
            address(deployment.directEngine.quoteVerifier()),
            address(deployment.verifier)
        );
        _assertEq(
            CHECK_ENGINE_TREASURY, deployment.directEngine.protocolTreasury(), config.treasury
        );
        _assertTrue(
            CHECK_ENGINE_DEPLOYERS,
            address(deployment.directEngine.tokenDeployer()).code.length != 0
        );
        _assertTrue(
            CHECK_ENGINE_DEPLOYERS,
            address(deployment.directEngine.lockerDeployer()).code.length != 0
        );
        _assertTrue(
            CHECK_ENGINE_DEPLOYERS, address(deployment.directEngine.nativeBuy()).code.length != 0
        );

        QuoteLaunchpad.EngineConfig memory engineConfig =
            deployment.launchpad.engineConfig(DIRECT_ENGINE_VERSION);
        _assertEq(CHECK_REGISTRY_ENGINE, engineConfig.engine, address(deployment.directEngine));
        _assertEq(
            CHECK_REGISTRY_CODEHASH,
            engineConfig.codehash,
            address(deployment.directEngine).codehash
        );
        _assertTrue(CHECK_REGISTRY_KIND, engineConfig.kind == QuoteLaunchEngineKind.DIRECT);
        _assertTrue(CHECK_REGISTRY_ENABLED, engineConfig.enabled);
        _assertEq(
            CHECK_DEFAULT_DIRECT,
            deployment.launchpad.defaultEngineVersion(QuoteLaunchEngineKind.DIRECT),
            DIRECT_ENGINE_VERSION
        );
    }

    function _printDeployment(Deployment memory deployment) internal view {
        console2.log("QUOTE V2 dry-run deployment");
        console2.logAddress(address(deployment.implementation));
        console2.logBytes32(address(deployment.implementation).codehash);
        console2.logAddress(address(deployment.proxy));
        console2.logAddress(address(deployment.verifier));
        console2.logBytes32(address(deployment.verifier).codehash);
        console2.logAddress(address(deployment.directEngine));
        console2.logBytes32(address(deployment.directEngine).codehash);
        console2.logAddress(address(deployment.directEngine.tokenDeployer()));
        console2.logAddress(address(deployment.directEngine.lockerDeployer()));
        console2.logAddress(address(deployment.directEngine.nativeBuy()));
    }

    function _requireCode(bytes32 check, address account) private view {
        if (account.code.length == 0) revert MissingCanonicalContract(check, account);
    }

    function _requireNonZero(address account, bytes32 field) private pure {
        if (account == address(0)) revert InvalidAddress(field);
    }

    function _requireEqual(bytes32 check, address expected, address actual) private pure {
        if (actual != expected) revert BadCanonicalDependency(check, expected, actual);
    }

    function _requireEqual(bytes32 check, int256 expected, int256 actual) private pure {
        if (actual != expected) revert BadCanonicalValue(check, expected, actual);
    }

    function _assertTrue(bytes32 check, bool condition) private pure {
        if (!condition) revert DeploymentAssertionFailed(check);
    }

    function _assertEq(bytes32 check, address actual, address expected) private pure {
        if (actual != expected) revert DeploymentAssertionFailed(check);
    }

    function _assertEq(bytes32 check, bytes32 actual, bytes32 expected) private pure {
        if (actual != expected) revert DeploymentAssertionFailed(check);
    }

    function _assertEq(bytes32 check, uint256 actual, uint256 expected) private pure {
        if (actual != expected) revert DeploymentAssertionFailed(check);
    }
}
