// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Initializable } from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

import { QuoteV2FeePolicy, TokenMode, V2FeeConfig } from "../../../src/v2/QuoteV2Types.sol";
import {
    IQuoteLaunchEngine,
    IQuoteLaunchpad,
    QuoteLaunchArtifacts,
    QuoteLaunchContext,
    QuoteLaunchEngineKind,
    QuoteLaunchRecord,
    QuoteLaunchRequest
} from "../../../src/v2/core/IQuoteLaunchEngine.sol";
import { QuoteLaunchpad } from "../../../src/v2/core/QuoteLaunchpad.sol";

contract QuoteCoreMockERC20 is ERC20 {
    constructor() ERC20("Quote Mock", "QUOTE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract QuoteCoreLaunchedToken is ERC20 {
    constructor(uint256 supply) ERC20("Quote Launch", "QLAUNCH") {
        _mint(msg.sender, supply);
    }
}

contract QuoteCoreArtifact { }

contract QuoteCoreMockEngine is IQuoteLaunchEngine {
    QuoteLaunchArtifacts private _nextArtifacts;

    address public immutable override launchpad;
    QuoteLaunchEngineKind public immutable override engineKind;
    bytes32 public immutable override engineVersion;
    bool public hasNextArtifacts;
    bool public forceWrongCreator;
    address public lastSender;
    address public lastCreator;
    address public lastQuoteToken;
    uint256 public lastSupply;
    uint256 public lastNativeAmount;
    uint256 public lastValue;
    TokenMode public lastTokenMode;
    QuoteLaunchEngineKind public lastEngineKind;
    bytes32 public lastEngineVersion;
    bytes public lastEnginePayload;

    constructor(address launchpad_, QuoteLaunchEngineKind engineKind_, bytes32 engineVersion_) {
        launchpad = launchpad_;
        engineKind = engineKind_;
        engineVersion = engineVersion_;
    }

    function setNextArtifacts(QuoteLaunchArtifacts calldata artifacts) external {
        _nextArtifacts = artifacts;
        hasNextArtifacts = true;
    }

    function setForceWrongCreator(bool forceWrongCreator_) external {
        forceWrongCreator = forceWrongCreator_;
    }

    function launch(QuoteLaunchContext calldata context, bytes calldata enginePayload)
        external
        payable
        returns (QuoteLaunchArtifacts memory artifacts)
    {
        lastSender = msg.sender;
        lastCreator = context.creator;
        lastQuoteToken = context.quoteToken;
        lastSupply = context.supply;
        lastNativeAmount = context.nativeAmount;
        lastValue = msg.value;
        lastTokenMode = context.tokenMode;
        lastEngineKind = context.engineKind;
        lastEngineVersion = context.engineVersion;
        lastEnginePayload = enginePayload;

        if (hasNextArtifacts) {
            artifacts = _nextArtifacts;
            delete _nextArtifacts;
            hasNextArtifacts = false;
        } else {
            artifacts = _artifacts(
                context.creator, context.engineVersion, context.launchId, context.supply
            );
        }

        if (forceWrongCreator) {
            artifacts.creator = address(0xBEEF);
        }
    }

    function _artifacts(address creator, bytes32 version, uint256 launchId, uint256 supply)
        private
        returns (QuoteLaunchArtifacts memory artifacts)
    {
        artifacts = QuoteLaunchArtifacts({
            creator: creator,
            token: address(new QuoteCoreLaunchedToken(supply)),
            market: address(new QuoteCoreArtifact()),
            hook: address(0),
            vault: address(0),
            locker: address(0),
            poolId: keccak256(abi.encode(version, launchId, "pool")),
            engineRecordId: keccak256(abi.encode(version, launchId, "record"))
        });
    }
}

    contract QuoteCoreMutableEngine is IQuoteLaunchEngine {
        address public override launchpad;
        QuoteLaunchEngineKind public override engineKind;
        bytes32 public override engineVersion;

        constructor(address launchpad_, QuoteLaunchEngineKind engineKind_, bytes32 engineVersion_) {
            launchpad = launchpad_;
            engineKind = engineKind_;
            engineVersion = engineVersion_;
        }

        function setLaunchpad(address launchpad_) external {
            launchpad = launchpad_;
        }

        function setEngineKind(QuoteLaunchEngineKind engineKind_) external {
            engineKind = engineKind_;
        }

        function setEngineVersion(bytes32 engineVersion_) external {
            engineVersion = engineVersion_;
        }

        function launch(QuoteLaunchContext calldata context, bytes calldata)
            external
            payable
            returns (QuoteLaunchArtifacts memory artifacts)
        {
            artifacts = QuoteLaunchArtifacts({
                creator: context.creator,
                token: address(new QuoteCoreLaunchedToken(context.supply)),
                market: address(new QuoteCoreArtifact()),
                hook: address(0),
                vault: address(0),
                locker: address(0),
                poolId: keccak256(abi.encode(context.engineVersion, context.launchId, "pool")),
                engineRecordId: keccak256(
                    abi.encode(context.engineVersion, context.launchId, "record")
                )
            });
        }
    }

        contract QuoteCoreAlternateEngine is IQuoteLaunchEngine {
            address public immutable override launchpad;
            QuoteLaunchEngineKind public immutable override engineKind;
            bytes32 public immutable override engineVersion;

            constructor(
                address launchpad_,
                QuoteLaunchEngineKind engineKind_,
                bytes32 engineVersion_
            ) {
                launchpad = launchpad_;
                engineKind = engineKind_;
                engineVersion = engineVersion_;
            }

            function launch(QuoteLaunchContext calldata context, bytes calldata)
                external
                payable
                returns (QuoteLaunchArtifacts memory artifacts)
            {
                artifacts = QuoteLaunchArtifacts({
                    creator: context.creator,
                    token: address(new QuoteCoreLaunchedToken(context.supply)),
                    market: address(new QuoteCoreArtifact()),
                    hook: address(0),
                    vault: address(0),
                    locker: address(0),
                    poolId: keccak256("alternate-pool"),
                    engineRecordId: keccak256("alternate-record")
                });
            }
        }

            contract QuoteCoreReentrantEngine is IQuoteLaunchEngine {
                address public immutable override launchpad;
                QuoteLaunchEngineKind public immutable override engineKind;
                bytes32 public immutable override engineVersion;
                bool public reentrantRejected;
                bytes4 public reentrantSelector;

                constructor(
                    address launchpad_,
                    QuoteLaunchEngineKind engineKind_,
                    bytes32 engineVersion_
                ) {
                    launchpad = launchpad_;
                    engineKind = engineKind_;
                    engineVersion = engineVersion_;
                }

                function launch(QuoteLaunchContext calldata context, bytes calldata)
                    external
                    payable
                    returns (QuoteLaunchArtifacts memory artifacts)
                {
                    QuoteLaunchRequest memory request = QuoteLaunchRequest({
                        creator: address(this),
                        quoteToken: context.quoteToken,
                        supply: 1,
                        nativeAmount: 0,
                        deadline: context.deadline,
                        tokenMode: TokenMode.STANDARD,
                        feeConfig: V2FeeConfig({
                            creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 0
                        }),
                        creatorFeeRecipient: address(0),
                        rewardFeeRecipient: address(0),
                        engineKind: context.engineKind,
                        engineVersion: context.engineVersion,
                        enginePayload: ""
                    });

                    try IQuoteLaunchpad(msg.sender).launch(request) returns (
                        QuoteLaunchRecord memory
                    ) {
                        revert("QUOTE_REENTRANCY_ALLOWED");
                    } catch (bytes memory revertData) {
                        reentrantRejected = true;
                        if (revertData.length >= 4) {
                            bytes4 selector;
                            assembly ("memory-safe") {
                                selector := mload(add(revertData, 0x20))
                            }
                            reentrantSelector = selector;
                        }
                    }

                    artifacts = QuoteLaunchArtifacts({
                        creator: context.creator,
                        token: address(new QuoteCoreLaunchedToken(context.supply)),
                        market: address(new QuoteCoreArtifact()),
                        hook: address(0),
                        vault: address(0),
                        locker: address(0),
                        poolId: keccak256("reentrant-pool"),
                        engineRecordId: keccak256("reentrant-record")
                    });
                }
            }

                contract QuoteLaunchpadV2Harness is QuoteLaunchpad {
                    function quoteCoreVersion() external pure returns (uint256) {
                        return 2;
                    }
                }

                contract QuoteLaunchpadTest is Test {
                    uint256 internal constant SUPPLY = 1_000_000 ether;
                    bytes32 internal constant DIRECT_V1 = keccak256("QUOTE:DIRECT:1");
                    bytes32 internal constant DIRECT_V2 = keccak256("QUOTE:DIRECT:2");
                    bytes32 internal constant CURVE_V1 = keccak256("QUOTE:CURVE:1");

                    address internal admin = makeAddr("admin");
                    address internal newAdmin = makeAddr("newAdmin");
                    address internal guardian = makeAddr("guardian");
                    address internal attacker = makeAddr("attacker");
                    address internal creator = makeAddr("creator");
                    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");

                    QuoteCoreMockERC20 internal quote;
                    QuoteLaunchpad internal implementation;
                    QuoteLaunchpad internal launchpad;
                    QuoteCoreMockEngine internal directEngine;

                    event QUOTEMarketLaunched(
                        uint256 indexed launchId,
                        address indexed creator,
                        bytes32 indexed engineVersion,
                        QuoteLaunchEngineKind engineKind,
                        address engine,
                        address token,
                        address quoteToken,
                        address market,
                        address hook,
                        address vault,
                        address locker,
                        uint256 supply,
                        uint16 creatorSwapFeeBps,
                        uint16 rewardFeeBps,
                        uint16 creatorLpShareBps,
                        bytes32 poolId,
                        bytes32 engineRecordId
                    );

                    function setUp() external {
                        vm.warp(1_800_000_000);
                        quote = new QuoteCoreMockERC20();
                        implementation = new QuoteLaunchpad();
                        launchpad = _deployProxy(implementation, admin, guardian);
                        directEngine =
                            new QuoteCoreMockEngine(
                            address(launchpad), QuoteLaunchEngineKind.DIRECT, DIRECT_V1
                        );
                    }

                    function testAtomicProxyInitializationAndImplementationLock() external {
                        QuoteLaunchpad lockedImplementation = new QuoteLaunchpad();

                        vm.expectRevert(Initializable.InvalidInitialization.selector);
                        lockedImplementation.initialize(
                            QuoteLaunchpad.InitParams({
                                upgradeAdmin: admin, pauseGuardian: guardian
                            })
                        );

                        assertEq(launchpad.upgradeAdmin(), admin);
                        assertEq(launchpad.pauseGuardian(), guardian);

                        vm.prank(attacker);
                        vm.expectRevert(Initializable.InvalidInitialization.selector);
                        launchpad.initialize(
                            QuoteLaunchpad.InitParams({
                                upgradeAdmin: attacker, pauseGuardian: attacker
                            })
                        );

                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        assertEq(
                            launchpad.defaultEngineVersion(QuoteLaunchEngineKind.DIRECT), DIRECT_V1
                        );
                    }

                    function testInitializerRejectsInvalidAdminAndGuardian() external {
                        QuoteLaunchpad freshImplementation = new QuoteLaunchpad();

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidAdmin.selector, address(0)
                            )
                        );
                        new ERC1967Proxy(
                            address(freshImplementation),
                            abi.encodeCall(
                                QuoteLaunchpad.initialize,
                                (QuoteLaunchpad.InitParams({
                                        upgradeAdmin: address(0), pauseGuardian: guardian
                                    }))
                            )
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidGuardian.selector, address(0)
                            )
                        );
                        new ERC1967Proxy(
                            address(freshImplementation),
                            abi.encodeCall(
                                QuoteLaunchpad.initialize,
                                (QuoteLaunchpad.InitParams({
                                        upgradeAdmin: admin, pauseGuardian: address(0)
                                    }))
                            )
                        );
                    }

                    function testUnauthorizedAdminAndPauseActionsFail() external {
                        QuoteLaunchpadV2Harness nextImplementation = new QuoteLaunchpadV2Harness();

                        vm.prank(attacker);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEUnauthorizedAdmin.selector, attacker
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, address(directEngine), QuoteLaunchEngineKind.DIRECT, true
                        );

                        vm.prank(attacker);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEUnauthorizedPause.selector, attacker
                            )
                        );
                        launchpad.pauseNewLaunches();

                        vm.prank(attacker);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEUnauthorizedAdmin.selector, attacker
                            )
                        );
                        launchpad.upgradeToAndCall(address(nextImplementation), "");
                    }

                    function testUpgradeAdminTransferIsTwoStepWithoutDelay() external {
                        vm.prank(admin);
                        launchpad.proposeUpgradeAdmin(newAdmin);
                        assertEq(launchpad.pendingUpgradeAdmin(), newAdmin);

                        vm.prank(attacker);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEAdminTransferNotPending.selector, attacker
                            )
                        );
                        launchpad.acceptUpgradeAdmin();

                        vm.prank(newAdmin);
                        launchpad.acceptUpgradeAdmin();

                        assertEq(launchpad.upgradeAdmin(), newAdmin);
                        assertEq(launchpad.pendingUpgradeAdmin(), address(0));

                        vm.prank(admin);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEUnauthorizedAdmin.selector, admin
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, address(directEngine), QuoteLaunchEngineKind.DIRECT, true
                        );

                        vm.prank(newAdmin);
                        launchpad.registerEngine(
                            DIRECT_V1, address(directEngine), QuoteLaunchEngineKind.DIRECT, true
                        );
                    }

                    function testUpgradeIsImmediateOnlyAdminRejectsValueAndPreservesState()
                        external
                    {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        _launch(_standardRequest(bytes32(0), 0));

                        QuoteLaunchpadV2Harness nextImplementation = new QuoteLaunchpadV2Harness();

                        vm.deal(admin, 1 wei);
                        vm.prank(admin);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidUpgradeValue.selector, 1
                            )
                        );
                        launchpad.upgradeToAndCall{ value: 1 }(address(nextImplementation), "");

                        vm.prank(admin);
                        launchpad.upgradeToAndCall(address(nextImplementation), "");

                        QuoteLaunchpadV2Harness upgraded = QuoteLaunchpadV2Harness(
                            address(launchpad)
                        );
                        assertEq(upgraded.quoteCoreVersion(), 2);
                        assertEq(upgraded.upgradeAdmin(), admin);
                        assertEq(upgraded.pauseGuardian(), guardian);
                        assertEq(upgraded.launchCount(), 1);
                        assertEq(
                            upgraded.defaultEngineVersion(QuoteLaunchEngineKind.DIRECT), DIRECT_V1
                        );

                        QuoteLaunchRecord memory record = upgraded.getLaunch(0);
                        assertEq(record.engineVersion, DIRECT_V1);
                        assertEq(record.creator, creator);
                    }

                    function testLaunchRecordsExactDefaultEngineVersionNativeValueAndCodehash()
                        external
                    {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);

                        QuoteCoreLaunchedToken token = new QuoteCoreLaunchedToken(SUPPLY);
                        QuoteCoreArtifact market = new QuoteCoreArtifact();
                        QuoteCoreArtifact locker = new QuoteCoreArtifact();
                        QuoteLaunchArtifacts memory artifacts = QuoteLaunchArtifacts({
                            creator: creator,
                            token: address(token),
                            market: address(market),
                            hook: address(0),
                            vault: address(0),
                            locker: address(locker),
                            poolId: keccak256("pool"),
                            engineRecordId: keccak256("engine-record")
                        });
                        directEngine.setNextArtifacts(artifacts);

                        QuoteLaunchRequest memory request = _standardRequest(bytes32(0), 0.25 ether);
                        request.feeConfig.creatorSwapFeeBps = 100;
                        request.creatorFeeRecipient = creatorFeeRecipient;

                        vm.expectEmit(true, true, true, true, address(launchpad));
                        emit QUOTEMarketLaunched(
                            0,
                            creator,
                            DIRECT_V1,
                            QuoteLaunchEngineKind.DIRECT,
                            address(directEngine),
                            address(token),
                            address(quote),
                            address(market),
                            address(0),
                            address(0),
                            address(locker),
                            request.supply,
                            100,
                            0,
                            request.feeConfig.creatorLpShareBps,
                            artifacts.poolId,
                            artifacts.engineRecordId
                        );

                        QuoteLaunchRecord memory record = _launch(request);
                        QuoteLaunchpad.EngineConfig memory config = launchpad.engineConfig(
                            DIRECT_V1
                        );

                        assertEq(config.codehash, address(directEngine).codehash);
                        assertEq(directEngine.lastSender(), address(launchpad));
                        assertEq(directEngine.lastValue(), request.nativeAmount);
                        assertEq(directEngine.lastNativeAmount(), request.nativeAmount);
                        assertEq(directEngine.lastCreator(), creator);
                        assertEq(directEngine.lastQuoteToken(), address(quote));
                        assertEq(directEngine.lastSupply(), SUPPLY);
                        assertEq(directEngine.lastEngineVersion(), DIRECT_V1);
                        assertEq(
                            uint256(directEngine.lastEngineKind()),
                            uint256(QuoteLaunchEngineKind.DIRECT)
                        );
                        assertEq(directEngine.lastEnginePayload(), request.enginePayload);

                        assertEq(record.launchId, 0);
                        assertEq(record.creator, creator);
                        assertEq(record.quoteToken, address(quote));
                        assertEq(record.supply, SUPPLY);
                        assertEq(record.engineVersion, DIRECT_V1);
                        assertEq(record.engine, address(directEngine));
                        assertEq(record.artifacts.token, address(token));
                        assertEq(record.artifacts.market, address(market));
                        assertEq(record.artifacts.locker, address(locker));
                        assertEq(record.feeConfig.creatorSwapFeeBps, 100);
                        assertEq(launchpad.artifactLaunchId(address(token)), 0);
                        assertEq(
                            launchpad.getLaunchByToken(address(token)).engineVersion, DIRECT_V1
                        );
                        assertEq(
                            launchpad.getLaunchByMarket(address(market)).engineVersion, DIRECT_V1
                        );
                        assertEq(
                            launchpad.getLaunchByEngineRecordId(artifacts.engineRecordId).launchId,
                            0
                        );
                    }

                    function testLaunchRecordsActualTokenSupplyAfterEngineDustBurn() external {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);

                        uint256 actualSupply = SUPPLY - 1;
                        QuoteCoreLaunchedToken token = new QuoteCoreLaunchedToken(actualSupply);
                        QuoteCoreArtifact market = new QuoteCoreArtifact();
                        QuoteLaunchArtifacts memory artifacts = QuoteLaunchArtifacts({
                            creator: creator,
                            token: address(token),
                            market: address(market),
                            hook: address(0),
                            vault: address(0),
                            locker: address(0),
                            poolId: keccak256("dust-pool"),
                            engineRecordId: keccak256("dust-record")
                        });
                        directEngine.setNextArtifacts(artifacts);

                        QuoteLaunchRequest memory request = _standardRequest(bytes32(0), 0);

                        vm.expectEmit(true, true, true, true, address(launchpad));
                        emit QUOTEMarketLaunched(
                            0,
                            creator,
                            DIRECT_V1,
                            QuoteLaunchEngineKind.DIRECT,
                            address(directEngine),
                            address(token),
                            address(quote),
                            address(market),
                            address(0),
                            address(0),
                            address(0),
                            actualSupply,
                            0,
                            0,
                            request.feeConfig.creatorLpShareBps,
                            artifacts.poolId,
                            artifacts.engineRecordId
                        );

                        QuoteLaunchRecord memory record = _launch(request);

                        assertEq(directEngine.lastSupply(), SUPPLY);
                        assertEq(record.supply, actualSupply);
                        assertEq(launchpad.getLaunch(0).supply, actualSupply);
                        assertEq(launchpad.getLaunchByToken(address(token)).supply, actualSupply);
                    }

                    function testFutureDefaultEngineSelectionKeepsHistoricRecordsImmutable()
                        external
                    {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        QuoteLaunchRecord memory first = _launch(_standardRequest(bytes32(0), 0));

                        QuoteCoreMockEngine secondEngine =
                            new QuoteCoreMockEngine(
                            address(launchpad), QuoteLaunchEngineKind.DIRECT, DIRECT_V2
                        );
                        vm.startPrank(admin);
                        launchpad.registerEngine(
                            DIRECT_V2, address(secondEngine), QuoteLaunchEngineKind.DIRECT, false
                        );
                        launchpad.setDefaultEngineVersion(QuoteLaunchEngineKind.DIRECT, DIRECT_V2);
                        vm.stopPrank();

                        QuoteLaunchRecord memory second = _launch(_standardRequest(bytes32(0), 0));

                        assertEq(first.engineVersion, DIRECT_V1);
                        assertEq(launchpad.getLaunch(0).engineVersion, DIRECT_V1);
                        assertEq(second.engineVersion, DIRECT_V2);
                        assertEq(launchpad.getLaunch(1).engineVersion, DIRECT_V2);
                        assertEq(
                            launchpad.defaultEngineVersion(QuoteLaunchEngineKind.DIRECT), DIRECT_V2
                        );
                    }

                    function testDisableAndReenableEngineAreImmediateButOldRecordsRemain()
                        external
                    {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        QuoteLaunchRecord memory existing = _launch(_standardRequest(DIRECT_V1, 0));

                        vm.prank(admin);
                        launchpad.setEngineEnabled(DIRECT_V1, false);

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineDisabled.selector, DIRECT_V1
                            )
                        );
                        _launch(_standardRequest(DIRECT_V1, 0));

                        QuoteLaunchRecord memory stillRecorded = launchpad.getLaunch(0);
                        assertEq(stillRecorded.engineVersion, DIRECT_V1);
                        assertEq(stillRecorded.artifacts.token, existing.artifacts.token);

                        vm.prank(admin);
                        launchpad.setEngineEnabled(DIRECT_V1, true);
                        _launch(_standardRequest(DIRECT_V1, 0));
                        assertEq(launchpad.launchCount(), 2);
                    }

                    function testPauseBlocksNewLaunchesButLeavesRecordsReadable() external {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        QuoteLaunchRecord memory existing = _launch(_standardRequest(bytes32(0), 0));

                        vm.prank(guardian);
                        launchpad.pauseNewLaunches();
                        assertTrue(launchpad.newLaunchesPaused());

                        vm.expectRevert(QuoteLaunchpad.QUOTENewLaunchesCurrentlyPaused.selector);
                        _launch(_standardRequest(bytes32(0), 0));

                        assertEq(launchpad.getLaunch(0).artifacts.token, existing.artifacts.token);

                        vm.prank(guardian);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEUnauthorizedAdmin.selector, guardian
                            )
                        );
                        launchpad.unpauseNewLaunches();

                        vm.prank(admin);
                        launchpad.unpauseNewLaunches();
                        _launch(_standardRequest(bytes32(0), 0));
                        assertEq(launchpad.launchCount(), 2);
                    }

                    function testEngineCannotSpoofDuplicateOrReservedArtifacts() external {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        QuoteLaunchRecord memory existing = _launch(_standardRequest(bytes32(0), 0));

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(new QuoteCoreLaunchedToken(SUPPLY)),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("record-duplicate-pool"),
                                engineRecordId: existing.artifacts.engineRecordId
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEDuplicateEngineRecordId.selector,
                                existing.artifacts.engineRecordId,
                                0
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: existing.artifacts.token,
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("duplicate-pool"),
                                engineRecordId: keccak256("duplicate-record")
                            })
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEDuplicateLaunchArtifact.selector,
                                existing.artifacts.token,
                                0
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(new QuoteCoreLaunchedToken(SUPPLY)),
                                market: address(launchpad),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("proxy-pool"),
                                engineRecordId: keccak256("proxy-record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchArtifact.selector,
                                bytes32("QUOTE_MARKET"),
                                address(launchpad)
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(directEngine),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("engine-pool"),
                                engineRecordId: keccak256("engine-record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchArtifact.selector,
                                bytes32("QUOTE_TOKEN"),
                                address(directEngine)
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));
                    }

                    function testEngineReentrancyIsRejected() external {
                        QuoteCoreReentrantEngine reentrantEngine = new QuoteCoreReentrantEngine(
                            address(launchpad), QuoteLaunchEngineKind.DIRECT, DIRECT_V1
                        );
                        _registerDirectEngine(
                            DIRECT_V1, IQuoteLaunchEngine(address(reentrantEngine)), true
                        );

                        QuoteLaunchRecord memory record = _launch(_standardRequest(bytes32(0), 0));

                        assertTrue(reentrantEngine.reentrantRejected());
                        assertEq(
                            reentrantEngine.reentrantSelector(),
                            QuoteLaunchpad.QUOTEReentrantCall.selector
                        );
                        assertEq(record.engineVersion, DIRECT_V1);
                        assertEq(launchpad.launchCount(), 1);
                    }

                    function testEngineRegistryValidatesVersionCodeKindAndDefaultCompatibility()
                        external
                    {
                        vm.startPrank(admin);

                        vm.expectRevert(QuoteLaunchpad.QUOTEEngineVersionZero.selector);
                        launchpad.registerEngine(
                            bytes32(0), address(directEngine), QuoteLaunchEngineKind.DIRECT, false
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidEngine.selector, address(0)
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, address(0), QuoteLaunchEngineKind.DIRECT, false
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidEngine.selector, attacker
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, attacker, QuoteLaunchEngineKind.DIRECT, false
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidEngineKind.selector,
                                QuoteLaunchEngineKind.UNKNOWN
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, address(directEngine), QuoteLaunchEngineKind.UNKNOWN, false
                        );

                        QuoteCoreMockEngine wrongLaunchpadEngine =
                            new QuoteCoreMockEngine(
                            attacker, QuoteLaunchEngineKind.DIRECT, DIRECT_V1
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineLaunchpadMismatch.selector,
                                address(wrongLaunchpadEngine),
                                address(launchpad),
                                attacker
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1,
                            address(wrongLaunchpadEngine),
                            QuoteLaunchEngineKind.DIRECT,
                            false
                        );

                        QuoteCoreMockEngine wrongKindEngine =
                            new QuoteCoreMockEngine(
                            address(launchpad), QuoteLaunchEngineKind.CURVE, DIRECT_V1
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineKindMismatch.selector,
                                DIRECT_V1,
                                QuoteLaunchEngineKind.DIRECT,
                                QuoteLaunchEngineKind.CURVE
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, address(wrongKindEngine), QuoteLaunchEngineKind.DIRECT, false
                        );

                        QuoteCoreMockEngine wrongVersionEngine =
                            new QuoteCoreMockEngine(
                            address(launchpad), QuoteLaunchEngineKind.DIRECT, DIRECT_V2
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineVersionMismatch.selector,
                                address(wrongVersionEngine),
                                DIRECT_V1,
                                DIRECT_V2
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1,
                            address(wrongVersionEngine),
                            QuoteLaunchEngineKind.DIRECT,
                            false
                        );

                        launchpad.registerEngine(
                            DIRECT_V1, address(directEngine), QuoteLaunchEngineKind.DIRECT, false
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineVersionAlreadyRegistered.selector,
                                DIRECT_V1
                            )
                        );
                        launchpad.registerEngine(
                            DIRECT_V1, address(directEngine), QuoteLaunchEngineKind.DIRECT, false
                        );

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineKindMismatch.selector,
                                DIRECT_V1,
                                QuoteLaunchEngineKind.CURVE,
                                QuoteLaunchEngineKind.DIRECT
                            )
                        );
                        launchpad.setDefaultEngineVersion(QuoteLaunchEngineKind.CURVE, DIRECT_V1);

                        vm.stopPrank();
                    }

                    function testLaunchValidationRejectsBadInputs() external {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);

                        QuoteLaunchRequest memory request = _standardRequest(bytes32(0), 0);
                        request.creator = attacker;
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidCreator.selector, attacker, creator
                            )
                        );
                        _launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.quoteToken = attacker;
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidQuoteToken.selector, attacker
                            )
                        );
                        _launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.supply = 0;
                        vm.expectRevert(QuoteLaunchpad.QUOTEInvalidSupply.selector);
                        _launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.deadline = block.timestamp - 1;
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEDeadlineExpired.selector, request.deadline
                            )
                        );
                        _launch(request);

                        request = _standardRequest(bytes32(0), 1 ether);
                        vm.prank(creator);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidNativeValue.selector, 0, 1 ether
                            )
                        );
                        launchpad.launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.feeConfig.creatorSwapFeeBps = QuoteV2FeePolicy.MAX_CREATOR_SWAP_FEE_BPS
                            + 1;
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteV2FeePolicy.CreatorSwapFeeTooHigh.selector,
                                QuoteV2FeePolicy.MAX_CREATOR_SWAP_FEE_BPS + 1
                            )
                        );
                        _launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.feeConfig.creatorSwapFeeBps = 1;
                        request.feeConfig.creatorLpShareBps = 0;
                        request.creatorFeeRecipient = address(0);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidFeeRecipient.selector,
                                bytes32("QUOTE_CREATOR_FEE_RECIPIENT")
                            )
                        );
                        _launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.feeConfig.creatorLpShareBps = 1;
                        request.creatorFeeRecipient = address(0);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidFeeRecipient.selector,
                                bytes32("QUOTE_CREATOR_FEE_RECIPIENT")
                            )
                        );
                        _launch(request);
                    }

                    function testLaunchValidationRejectsEngineAndArtifactMismatches() external {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);
                        QuoteCoreMockEngine curveEngine =
                            new QuoteCoreMockEngine(
                            address(launchpad), QuoteLaunchEngineKind.CURVE, CURVE_V1
                        );

                        vm.prank(admin);
                        launchpad.registerEngine(
                            CURVE_V1, address(curveEngine), QuoteLaunchEngineKind.CURVE, false
                        );

                        QuoteLaunchRequest memory request = _standardRequest(CURVE_V1, 0);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineKindMismatch.selector,
                                CURVE_V1,
                                QuoteLaunchEngineKind.DIRECT,
                                QuoteLaunchEngineKind.CURVE
                            )
                        );
                        _launch(request);

                        request = _standardRequest(bytes32(0), 0);
                        request.engineKind = QuoteLaunchEngineKind.UNKNOWN;
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidEngineKind.selector,
                                QuoteLaunchEngineKind.UNKNOWN
                            )
                        );
                        _launch(request);

                        directEngine.setForceWrongCreator(true);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidArtifactCreator.selector,
                                address(0xBEEF),
                                creator
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));
                        directEngine.setForceWrongCreator(false);

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(quote),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("quote-pool"),
                                engineRecordId: keccak256("quote-record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchArtifact.selector,
                                bytes32("QUOTE_TOKEN"),
                                address(quote)
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        QuoteCoreArtifact nonErc20Token = new QuoteCoreArtifact();
                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(nonErc20Token),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("non-erc20-pool"),
                                engineRecordId: keccak256("non-erc20-record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchArtifact.selector,
                                bytes32("QUOTE_TOKEN"),
                                address(nonErc20Token)
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        QuoteCoreLaunchedToken zeroSupplyToken = new QuoteCoreLaunchedToken(0);
                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(zeroSupplyToken),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("zero-supply-pool"),
                                engineRecordId: keccak256("zero-supply-record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchedSupply.selector,
                                address(zeroSupplyToken),
                                0,
                                SUPPLY
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        QuoteCoreLaunchedToken oversizedSupplyToken = new QuoteCoreLaunchedToken(
                            SUPPLY + 1
                        );
                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(oversizedSupplyToken),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("oversized-supply-pool"),
                                engineRecordId: keccak256("oversized-supply-record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchedSupply.selector,
                                address(oversizedSupplyToken),
                                SUPPLY + 1,
                                SUPPLY
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));
                    }

                    function testCurveEngineMayRemainRegisteredButCannotServeNewLaunches()
                        external
                    {
                        QuoteCoreMockEngine curveEngine = new QuoteCoreMockEngine(
                            address(launchpad), QuoteLaunchEngineKind.CURVE, CURVE_V1
                        );
                        vm.prank(admin);
                        launchpad.registerEngine(
                            CURVE_V1, address(curveEngine), QuoteLaunchEngineKind.CURVE, true
                        );
                        assertEq(
                            launchpad.defaultEngineVersion(QuoteLaunchEngineKind.CURVE), CURVE_V1
                        );

                        QuoteLaunchRequest memory request = _standardRequest(bytes32(0), 0);
                        request.engineKind = QuoteLaunchEngineKind.CURVE;
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineKindDisabledForNewLaunches.selector,
                                QuoteLaunchEngineKind.CURVE
                            )
                        );
                        _launch(request);
                    }

                    function testLaunchRejectsZeroPoolAndEngineRecordIds() external {
                        _registerDirectEngine(DIRECT_V1, directEngine, true);

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(new QuoteCoreLaunchedToken(SUPPLY)),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: bytes32(0),
                                engineRecordId: keccak256("record")
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchArtifactId.selector,
                                bytes32("QUOTE_POOL_ID")
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        directEngine.setNextArtifacts(
                            QuoteLaunchArtifacts({
                                creator: creator,
                                token: address(new QuoteCoreLaunchedToken(SUPPLY)),
                                market: address(new QuoteCoreArtifact()),
                                hook: address(0),
                                vault: address(0),
                                locker: address(0),
                                poolId: keccak256("pool"),
                                engineRecordId: bytes32(0)
                            })
                        );
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEInvalidLaunchArtifactId.selector,
                                bytes32("QUOTE_ENGINE_RECORD_ID")
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));
                    }

                    function testLaunchRevalidatesMutableEngineHandshakeAndCodehash() external {
                        QuoteCoreMutableEngine mutableEngine = new QuoteCoreMutableEngine(
                            address(launchpad), QuoteLaunchEngineKind.DIRECT, DIRECT_V1
                        );
                        _registerDirectEngine(
                            DIRECT_V1, IQuoteLaunchEngine(address(mutableEngine)), true
                        );

                        mutableEngine.setEngineVersion(DIRECT_V2);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineVersionMismatch.selector,
                                address(mutableEngine),
                                DIRECT_V1,
                                DIRECT_V2
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        mutableEngine.setEngineVersion(DIRECT_V1);
                        mutableEngine.setEngineKind(QuoteLaunchEngineKind.CURVE);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineKindMismatch.selector,
                                DIRECT_V1,
                                QuoteLaunchEngineKind.DIRECT,
                                QuoteLaunchEngineKind.CURVE
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        mutableEngine.setEngineKind(QuoteLaunchEngineKind.DIRECT);
                        mutableEngine.setLaunchpad(attacker);
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineLaunchpadMismatch.selector,
                                address(mutableEngine),
                                address(launchpad),
                                attacker
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));

                        mutableEngine.setLaunchpad(address(launchpad));
                        QuoteCoreAlternateEngine alternate = new QuoteCoreAlternateEngine(
                            address(launchpad), QuoteLaunchEngineKind.DIRECT, DIRECT_V1
                        );
                        bytes32 expectedCodehash = address(mutableEngine).codehash;
                        bytes32 actualCodehash = address(alternate).codehash;
                        vm.etch(address(mutableEngine), address(alternate).code);

                        vm.expectRevert(
                            abi.encodeWithSelector(
                                QuoteLaunchpad.QUOTEEngineCodehashMismatch.selector,
                                DIRECT_V1,
                                expectedCodehash,
                                actualCodehash
                            )
                        );
                        _launch(_standardRequest(bytes32(0), 0));
                    }

                    function _deployProxy(
                        QuoteLaunchpad implementation_,
                        address upgradeAdmin,
                        address pauseGuardian
                    ) internal returns (QuoteLaunchpad proxy) {
                        bytes memory initData = abi.encodeCall(
                            QuoteLaunchpad.initialize,
                            (QuoteLaunchpad.InitParams({
                                    upgradeAdmin: upgradeAdmin, pauseGuardian: pauseGuardian
                                }))
                        );
                        proxy = QuoteLaunchpad(
                            address(new ERC1967Proxy(address(implementation_), initData))
                        );
                    }

                    function _registerDirectEngine(
                        bytes32 version,
                        IQuoteLaunchEngine engine,
                        bool setAsDefault
                    ) internal {
                        vm.prank(admin);
                        launchpad.registerEngine(
                            version, address(engine), QuoteLaunchEngineKind.DIRECT, setAsDefault
                        );
                    }

                    function _standardRequest(bytes32 engineVersion, uint256 nativeAmount)
                        internal
                        view
                        returns (QuoteLaunchRequest memory request)
                    {
                        request = QuoteLaunchRequest({
                            creator: creator,
                            quoteToken: address(quote),
                            supply: SUPPLY,
                            nativeAmount: nativeAmount,
                            deadline: block.timestamp + 1 hours,
                            tokenMode: TokenMode.STANDARD,
                            feeConfig: V2FeeConfig({
                                creatorSwapFeeBps: 0, rewardFeeBps: 0, creatorLpShareBps: 10_000
                            }),
                            creatorFeeRecipient: creatorFeeRecipient,
                            rewardFeeRecipient: address(0),
                            engineKind: QuoteLaunchEngineKind.DIRECT,
                            engineVersion: engineVersion,
                            enginePayload: hex"51554f5445"
                        });
                    }

                    function _launch(QuoteLaunchRequest memory request)
                        internal
                        returns (QuoteLaunchRecord memory record)
                    {
                        vm.deal(creator, request.nativeAmount);
                        vm.prank(creator);
                        record = launchpad.launch{ value: request.nativeAmount }(request);
                    }
                }
