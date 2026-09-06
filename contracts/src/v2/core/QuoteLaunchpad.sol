// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Initializable } from "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { QuoteV2FeePolicy } from "../QuoteV2Types.sol";
import {
    IQuoteLaunchEngine,
    QuoteLaunchArtifacts,
    QuoteLaunchContext,
    QuoteLaunchEngineKind,
    QuoteLaunchRecord,
    QuoteLaunchRequest
} from "./IQuoteLaunchEngine.sol";

/// @notice Upgradeable QUOTE V2 launch entry point and external engine registry.
/// @dev Launched token, market, hook, vault and locker artifacts are ordinary engine deployments.
contract QuoteLaunchpad is Initializable, UUPSUpgradeable {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    bytes32 private constant FIELD_TOKEN = "QUOTE_TOKEN";
    bytes32 private constant FIELD_MARKET = "QUOTE_MARKET";
    bytes32 private constant FIELD_HOOK = "QUOTE_HOOK";
    bytes32 private constant FIELD_VAULT = "QUOTE_VAULT";
    bytes32 private constant FIELD_LOCKER = "QUOTE_LOCKER";
    bytes32 private constant FIELD_POOL_ID = "QUOTE_POOL_ID";
    bytes32 private constant FIELD_ENGINE_RECORD_ID = "QUOTE_ENGINE_RECORD_ID";
    bytes32 private constant FIELD_CREATOR_FEE_RECIPIENT = "QUOTE_CREATOR_FEE_RECIPIENT";
    bytes32 private constant FIELD_REWARD_FEE_RECIPIENT = "QUOTE_REWARD_FEE_RECIPIENT";

    // keccak256(abi.encode(uint256(keccak256("quote.storage.QuoteLaunchpad")) - 1))
    // & ~bytes32(uint256(0xff))
    bytes32 private constant QUOTE_LAUNCHPAD_STORAGE =
        0x71ce44f8d746b62861bf222c191674133c1ddf9bb6de8071918b628d9233ca00;

    struct InitParams {
        address upgradeAdmin;
        address pauseGuardian;
    }

    struct EngineConfig {
        address engine;
        bytes32 codehash;
        QuoteLaunchEngineKind kind;
        bool enabled;
        uint64 registeredAt;
        uint64 disabledAt;
    }

    /// @custom:storage-location erc7201:quote.storage.QuoteLaunchpad
    struct QuoteLaunchpadStorage {
        address upgradeAdmin;
        address pendingUpgradeAdmin;
        address pauseGuardian;
        bool newLaunchesPaused;
        uint256 reentrancyStatus;
        uint256 launchCount;
        mapping(bytes32 version => EngineConfig config) engines;
        mapping(uint8 kind => bytes32 version) defaultEngineVersion;
        mapping(uint256 launchId => QuoteLaunchRecord record) launches;
        mapping(address token => uint256 idPlusOne) launchIdPlusOneByToken;
        mapping(address market => uint256 idPlusOne) launchIdPlusOneByMarket;
        mapping(address artifact => uint256 idPlusOne) artifactLaunchIdPlusOne;
        mapping(bytes32 engineRecordId => uint256 idPlusOne) launchIdPlusOneByEngineRecordId;
    }

    error QUOTEUnauthorizedAdmin(address caller);
    error QUOTEUnauthorizedPause(address caller);
    error QUOTEInvalidAdmin(address admin);
    error QUOTEInvalidGuardian(address guardian);
    error QUOTEAdminTransferNotPending(address caller);
    error QUOTEInvalidImplementation(address implementation);
    error QUOTEInvalidUpgradeValue(uint256 value);
    error QUOTEEngineVersionZero();
    error QUOTEEngineVersionAlreadyRegistered(bytes32 version);
    error QUOTEEngineNotRegistered(bytes32 version);
    error QUOTEEngineVersionNotSelected(QuoteLaunchEngineKind kind);
    error QUOTEInvalidEngine(address engine);
    error QUOTEEngineLaunchpadMismatch(address engine, address expected, address actual);
    error QUOTEInvalidEngineKind(QuoteLaunchEngineKind kind);
    error QUOTEEngineKindDisabledForNewLaunches(QuoteLaunchEngineKind kind);
    error QUOTEEngineKindMismatch(
        bytes32 version, QuoteLaunchEngineKind expected, QuoteLaunchEngineKind actual
    );
    error QUOTEEngineVersionMismatch(address engine, bytes32 expected, bytes32 actual);
    error QUOTEEngineCodehashMismatch(bytes32 version, bytes32 expected, bytes32 actual);
    error QUOTEEngineDisabled(bytes32 version);
    error QUOTENewLaunchesCurrentlyPaused();
    error QUOTEInvalidCreator(address creator, address caller);
    error QUOTEInvalidQuoteToken(address quoteToken);
    error QUOTEInvalidSupply();
    error QUOTEInvalidLaunchedSupply(address token, uint256 actualSupply, uint256 requestedSupply);
    error QUOTEDeadlineExpired(uint256 deadline);
    error QUOTEInvalidNativeValue(uint256 actual, uint256 expected);
    error QUOTEInvalidFeeRecipient(bytes32 field);
    error QUOTEInvalidArtifactCreator(address artifactCreator, address expectedCreator);
    error QUOTEInvalidLaunchArtifact(bytes32 field, address artifact);
    error QUOTEInvalidLaunchArtifactId(bytes32 field);
    error QUOTEDuplicateEngineRecordId(bytes32 engineRecordId, uint256 existingLaunchId);
    error QUOTEDuplicateLaunchArtifact(address artifact, uint256 existingLaunchId);
    error QUOTEReentrantCall();
    error QUOTELaunchNotFound(uint256 launchId);
    error QUOTEArtifactNotRecorded(address artifact);
    error QUOTEEngineRecordNotRecorded(bytes32 engineRecordId);

    event QUOTELaunchpadInitialized(address indexed upgradeAdmin, address indexed pauseGuardian);
    event QUOTEUpgradeAdminTransferProposed(
        address indexed currentAdmin, address indexed pendingAdmin
    );
    event QUOTEUpgradeAdminTransferCancelled(
        address indexed currentAdmin, address indexed pendingAdmin
    );
    event QUOTEUpgradeAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event QUOTEPauseGuardianSet(address indexed previousGuardian, address indexed newGuardian);
    event QUOTENewLaunchesPaused(address indexed account);
    event QUOTENewLaunchesUnpaused(address indexed account);
    event QUOTEEngineRegistered(
        bytes32 indexed version,
        address indexed engine,
        QuoteLaunchEngineKind indexed kind,
        bytes32 codehash
    );
    event QUOTEEngineEnabledSet(bytes32 indexed version, bool enabled);
    event QUOTEDefaultEngineVersionSet(QuoteLaunchEngineKind indexed kind, bytes32 indexed version);
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

    modifier onlyQUOTEAdmin() {
        _checkQUOTEAdmin();
        _;
    }

    modifier nonReentrantQUOTE() {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        if ($.reentrancyStatus == ENTERED) revert QUOTEReentrantCall();
        $.reentrancyStatus = ENTERED;
        _;
        $.reentrancyStatus = NOT_ENTERED;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external initializer {
        if (params.upgradeAdmin == address(0)) revert QUOTEInvalidAdmin(params.upgradeAdmin);
        if (params.pauseGuardian == address(0)) revert QUOTEInvalidGuardian(params.pauseGuardian);

        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        $.upgradeAdmin = params.upgradeAdmin;
        $.pauseGuardian = params.pauseGuardian;
        $.reentrancyStatus = NOT_ENTERED;

        emit QUOTELaunchpadInitialized(params.upgradeAdmin, params.pauseGuardian);
    }

    function upgradeAdmin() external view returns (address) {
        return _getQuoteLaunchpadStorage().upgradeAdmin;
    }

    function pendingUpgradeAdmin() external view returns (address) {
        return _getQuoteLaunchpadStorage().pendingUpgradeAdmin;
    }

    function pauseGuardian() external view returns (address) {
        return _getQuoteLaunchpadStorage().pauseGuardian;
    }

    function newLaunchesPaused() external view returns (bool) {
        return _getQuoteLaunchpadStorage().newLaunchesPaused;
    }

    function launchCount() external view returns (uint256) {
        return _getQuoteLaunchpadStorage().launchCount;
    }

    function engineConfig(bytes32 version) external view returns (EngineConfig memory config) {
        config = _getEngineConfig(_getQuoteLaunchpadStorage(), version);
    }

    function defaultEngineVersion(QuoteLaunchEngineKind kind) external view returns (bytes32) {
        return _getQuoteLaunchpadStorage().defaultEngineVersion[uint8(kind)];
    }

    function getLaunch(uint256 launchId) external view returns (QuoteLaunchRecord memory record) {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        if (launchId >= $.launchCount) revert QUOTELaunchNotFound(launchId);
        return $.launches[launchId];
    }

    function getLaunchByToken(address token)
        external
        view
        returns (QuoteLaunchRecord memory record)
    {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        uint256 idPlusOne = $.launchIdPlusOneByToken[token];
        if (idPlusOne == 0) revert QUOTEArtifactNotRecorded(token);
        return $.launches[idPlusOne - 1];
    }

    function getLaunchByMarket(address market)
        external
        view
        returns (QuoteLaunchRecord memory record)
    {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        uint256 idPlusOne = $.launchIdPlusOneByMarket[market];
        if (idPlusOne == 0) revert QUOTEArtifactNotRecorded(market);
        return $.launches[idPlusOne - 1];
    }

    function getLaunchByEngineRecordId(bytes32 engineRecordId)
        external
        view
        returns (QuoteLaunchRecord memory record)
    {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        uint256 idPlusOne = $.launchIdPlusOneByEngineRecordId[engineRecordId];
        if (idPlusOne == 0) revert QUOTEEngineRecordNotRecorded(engineRecordId);
        return $.launches[idPlusOne - 1];
    }

    function artifactLaunchId(address artifact) external view returns (uint256 launchId) {
        uint256 idPlusOne = _getQuoteLaunchpadStorage().artifactLaunchIdPlusOne[artifact];
        if (idPlusOne == 0) revert QUOTEArtifactNotRecorded(artifact);
        return idPlusOne - 1;
    }

    function proposeUpgradeAdmin(address newAdmin) external onlyQUOTEAdmin {
        if (newAdmin == address(0) || newAdmin == _getQuoteLaunchpadStorage().upgradeAdmin) {
            revert QUOTEInvalidAdmin(newAdmin);
        }

        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        $.pendingUpgradeAdmin = newAdmin;

        emit QUOTEUpgradeAdminTransferProposed($.upgradeAdmin, newAdmin);
    }

    function cancelUpgradeAdminTransfer() external onlyQUOTEAdmin {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        address pendingAdmin = $.pendingUpgradeAdmin;
        $.pendingUpgradeAdmin = address(0);

        emit QUOTEUpgradeAdminTransferCancelled($.upgradeAdmin, pendingAdmin);
    }

    function acceptUpgradeAdmin() external {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        if (msg.sender != $.pendingUpgradeAdmin) revert QUOTEAdminTransferNotPending(msg.sender);

        address previousAdmin = $.upgradeAdmin;
        $.upgradeAdmin = msg.sender;
        $.pendingUpgradeAdmin = address(0);

        emit QUOTEUpgradeAdminTransferred(previousAdmin, msg.sender);
    }

    function setPauseGuardian(address newGuardian) external onlyQUOTEAdmin {
        if (newGuardian == address(0)) revert QUOTEInvalidGuardian(newGuardian);

        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        address previousGuardian = $.pauseGuardian;
        $.pauseGuardian = newGuardian;

        emit QUOTEPauseGuardianSet(previousGuardian, newGuardian);
    }

    function pauseNewLaunches() external {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        _checkPauseAuthority($);
        $.newLaunchesPaused = true;
        emit QUOTENewLaunchesPaused(msg.sender);
    }

    function unpauseNewLaunches() external {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        _checkQUOTEAdmin();
        $.newLaunchesPaused = false;
        emit QUOTENewLaunchesUnpaused(msg.sender);
    }

    function upgradeToAndCall(address newImplementation, bytes memory data)
        public
        payable
        override
        onlyProxy
        onlyQUOTEAdmin
    {
        if (msg.value != 0) revert QUOTEInvalidUpgradeValue(msg.value);
        _validateImplementation(newImplementation);
        super.upgradeToAndCall(newImplementation, data);
    }

    function registerEngine(
        bytes32 version,
        address engine,
        QuoteLaunchEngineKind kind,
        bool setAsDefault
    ) external onlyQUOTEAdmin {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        if ($.engines[version].engine != address(0)) {
            revert QUOTEEngineVersionAlreadyRegistered(version);
        }

        bytes32 codehash = _validateEngineRuntime(version, engine, kind, bytes32(0));
        $.engines[version] = EngineConfig({
            engine: engine,
            codehash: codehash,
            kind: kind,
            enabled: true,
            registeredAt: uint64(block.timestamp),
            disabledAt: 0
        });

        emit QUOTEEngineRegistered(version, engine, kind, codehash);
        emit QUOTEEngineEnabledSet(version, true);

        if (setAsDefault) {
            _setDefaultEngineVersion($, kind, version);
        }
    }

    function setEngineEnabled(bytes32 version, bool enabled) external onlyQUOTEAdmin {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        EngineConfig storage config = $.engines[version];
        if (config.engine == address(0)) revert QUOTEEngineNotRegistered(version);

        if (enabled) {
            _validateEngineRuntime(version, config.engine, config.kind, config.codehash);
        }

        config.enabled = enabled;
        config.disabledAt = enabled ? 0 : uint64(block.timestamp);

        emit QUOTEEngineEnabledSet(version, enabled);
    }

    function setDefaultEngineVersion(QuoteLaunchEngineKind kind, bytes32 version)
        external
        onlyQUOTEAdmin
    {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        EngineConfig memory config = _getEngineConfig($, version);
        _validateEngineKind(kind);
        if (config.kind != kind) revert QUOTEEngineKindMismatch(version, kind, config.kind);
        if (!config.enabled) revert QUOTEEngineDisabled(version);
        _validateEngineRuntime(version, config.engine, config.kind, config.codehash);

        _setDefaultEngineVersion($, kind, version);
    }

    function launch(QuoteLaunchRequest calldata request)
        external
        payable
        nonReentrantQUOTE
        returns (QuoteLaunchRecord memory record)
    {
        QuoteLaunchpadStorage storage $ = _getQuoteLaunchpadStorage();
        if ($.newLaunchesPaused) revert QUOTENewLaunchesCurrentlyPaused();

        _validateLaunchRequest(request);

        (bytes32 engineVersion_, EngineConfig memory config) = _resolveEngine($, request);
        _validateEngineRuntime(engineVersion_, config.engine, config.kind, config.codehash);

        uint256 launchId = $.launchCount;
        QuoteLaunchContext memory context = QuoteLaunchContext({
            launchId: launchId,
            creator: request.creator,
            quoteToken: request.quoteToken,
            supply: request.supply,
            nativeAmount: request.nativeAmount,
            deadline: request.deadline,
            tokenMode: request.tokenMode,
            feeConfig: request.feeConfig,
            creatorFeeRecipient: request.creatorFeeRecipient,
            rewardFeeRecipient: request.rewardFeeRecipient,
            engineKind: config.kind,
            engineVersion: engineVersion_
        });

        QuoteLaunchArtifacts memory artifacts = IQuoteLaunchEngine(config.engine)
        .launch{ value: request.nativeAmount }(
            context, request.enginePayload
        );

        _validateLaunchArtifacts($, request, config.engine, artifacts);
        uint256 launchedSupply = _readLaunchedTokenSupply(artifacts.token, request.supply);

        record = QuoteLaunchRecord({
            launchId: launchId,
            creator: request.creator,
            quoteToken: request.quoteToken,
            supply: launchedSupply,
            tokenMode: request.tokenMode,
            feeConfig: request.feeConfig,
            creatorFeeRecipient: request.creatorFeeRecipient,
            rewardFeeRecipient: request.rewardFeeRecipient,
            engineKind: config.kind,
            engineVersion: engineVersion_,
            engine: config.engine,
            artifacts: artifacts,
            launchedAt: uint64(block.timestamp)
        });

        $.launches[launchId] = record;
        _recordArtifacts($, artifacts, launchId);
        $.launchCount = launchId + 1;

        emit QUOTEMarketLaunched(
            launchId,
            request.creator,
            engineVersion_,
            config.kind,
            config.engine,
            artifacts.token,
            request.quoteToken,
            artifacts.market,
            artifacts.hook,
            artifacts.vault,
            artifacts.locker,
            launchedSupply,
            request.feeConfig.creatorSwapFeeBps,
            request.feeConfig.rewardFeeBps,
            request.feeConfig.creatorLpShareBps,
            artifacts.poolId,
            artifacts.engineRecordId
        );
    }

    function _authorizeUpgrade(address) internal view override {
        _checkQUOTEAdmin();
    }

    function _checkQUOTEAdmin() internal view {
        if (msg.sender != _getQuoteLaunchpadStorage().upgradeAdmin) {
            revert QUOTEUnauthorizedAdmin(msg.sender);
        }
    }

    function _checkPauseAuthority(QuoteLaunchpadStorage storage $) private view {
        if (msg.sender != $.upgradeAdmin && msg.sender != $.pauseGuardian) {
            revert QUOTEUnauthorizedPause(msg.sender);
        }
    }

    function _validateImplementation(address implementation) private view {
        if (implementation == address(0) || implementation.code.length == 0) {
            revert QUOTEInvalidImplementation(implementation);
        }
    }

    function _validateEngineKind(QuoteLaunchEngineKind kind) private pure {
        if (kind == QuoteLaunchEngineKind.UNKNOWN) revert QUOTEInvalidEngineKind(kind);
    }

    function _validateEngineRuntime(
        bytes32 version,
        address engine,
        QuoteLaunchEngineKind expectedKind,
        bytes32 expectedCodehash
    ) private view returns (bytes32 actualCodehash) {
        if (version == bytes32(0)) revert QUOTEEngineVersionZero();
        if (engine == address(0) || engine.code.length == 0) revert QUOTEInvalidEngine(engine);
        _validateEngineKind(expectedKind);

        actualCodehash = engine.codehash;
        if (expectedCodehash != bytes32(0) && actualCodehash != expectedCodehash) {
            revert QUOTEEngineCodehashMismatch(version, expectedCodehash, actualCodehash);
        }

        // Codehash binding covers the registered address only. If governance registers a proxy-like
        // engine, that engine's own upgrade controls remain part of the trust boundary.
        _validateEngineHandshake(engine, expectedKind, version);
    }

    function _validateEngineHandshake(
        address engine,
        QuoteLaunchEngineKind expectedKind,
        bytes32 expectedVersion
    ) private view {
        address configuredLaunchpad;
        QuoteLaunchEngineKind configuredKind;
        bytes32 configuredVersion;

        try IQuoteLaunchEngine(engine).launchpad() returns (address launchpad_) {
            configuredLaunchpad = launchpad_;
        } catch {
            revert QUOTEInvalidEngine(engine);
        }
        if (configuredLaunchpad != address(this)) {
            revert QUOTEEngineLaunchpadMismatch(engine, address(this), configuredLaunchpad);
        }

        try IQuoteLaunchEngine(engine).engineKind() returns (QuoteLaunchEngineKind kind_) {
            configuredKind = kind_;
        } catch {
            revert QUOTEInvalidEngine(engine);
        }
        if (configuredKind != expectedKind) {
            revert QUOTEEngineKindMismatch(expectedVersion, expectedKind, configuredKind);
        }

        try IQuoteLaunchEngine(engine).engineVersion() returns (bytes32 version_) {
            configuredVersion = version_;
        } catch {
            revert QUOTEInvalidEngine(engine);
        }
        if (configuredVersion != expectedVersion) {
            revert QUOTEEngineVersionMismatch(engine, expectedVersion, configuredVersion);
        }
    }

    function _setDefaultEngineVersion(
        QuoteLaunchpadStorage storage $,
        QuoteLaunchEngineKind kind,
        bytes32 version
    ) private {
        $.defaultEngineVersion[uint8(kind)] = version;
        emit QUOTEDefaultEngineVersionSet(kind, version);
    }

    function _getEngineConfig(QuoteLaunchpadStorage storage $, bytes32 version)
        private
        view
        returns (EngineConfig memory config)
    {
        config = $.engines[version];
        if (config.engine == address(0)) revert QUOTEEngineNotRegistered(version);
    }

    function _resolveEngine(QuoteLaunchpadStorage storage $, QuoteLaunchRequest calldata request)
        private
        view
        returns (bytes32 engineVersion_, EngineConfig memory config)
    {
        _validateEngineKind(request.engineKind);
        if (request.engineKind != QuoteLaunchEngineKind.DIRECT) {
            revert QUOTEEngineKindDisabledForNewLaunches(request.engineKind);
        }
        engineVersion_ = request.engineVersion;
        if (engineVersion_ == bytes32(0)) {
            engineVersion_ = $.defaultEngineVersion[uint8(request.engineKind)];
            if (engineVersion_ == bytes32(0)) {
                revert QUOTEEngineVersionNotSelected(request.engineKind);
            }
        }

        config = _getEngineConfig($, engineVersion_);
        if (config.kind != request.engineKind) {
            revert QUOTEEngineKindMismatch(engineVersion_, request.engineKind, config.kind);
        }
        if (!config.enabled) revert QUOTEEngineDisabled(engineVersion_);
    }

    function _validateLaunchRequest(QuoteLaunchRequest calldata request) private view {
        if (request.creator == address(0) || request.creator != msg.sender) {
            revert QUOTEInvalidCreator(request.creator, msg.sender);
        }
        if (request.quoteToken == address(0) || request.quoteToken.code.length == 0) {
            revert QUOTEInvalidQuoteToken(request.quoteToken);
        }
        if (request.supply == 0) revert QUOTEInvalidSupply();
        if (request.deadline < block.timestamp) revert QUOTEDeadlineExpired(request.deadline);
        if (msg.value != request.nativeAmount) {
            revert QUOTEInvalidNativeValue(msg.value, request.nativeAmount);
        }

        QuoteV2FeePolicy.validate(request.tokenMode, request.feeConfig);
        if (
            request.creatorFeeRecipient == address(0)
                && (request.feeConfig.creatorSwapFeeBps != 0
                    || request.feeConfig.creatorLpShareBps != 0)
        ) {
            revert QUOTEInvalidFeeRecipient(FIELD_CREATOR_FEE_RECIPIENT);
        }
        if (request.feeConfig.rewardFeeBps != 0 && request.rewardFeeRecipient == address(0)) {
            revert QUOTEInvalidFeeRecipient(FIELD_REWARD_FEE_RECIPIENT);
        }
    }

    function _validateLaunchArtifacts(
        QuoteLaunchpadStorage storage $,
        QuoteLaunchRequest calldata request,
        address engine,
        QuoteLaunchArtifacts memory artifacts
    ) private view {
        if (artifacts.creator != request.creator) {
            revert QUOTEInvalidArtifactCreator(artifacts.creator, request.creator);
        }
        if (artifacts.poolId == bytes32(0)) revert QUOTEInvalidLaunchArtifactId(FIELD_POOL_ID);
        if (artifacts.engineRecordId == bytes32(0)) {
            revert QUOTEInvalidLaunchArtifactId(FIELD_ENGINE_RECORD_ID);
        }
        uint256 existingRecordIdPlusOne =
            $.launchIdPlusOneByEngineRecordId[artifacts.engineRecordId];
        if (existingRecordIdPlusOne != 0) {
            revert QUOTEDuplicateEngineRecordId(
                artifacts.engineRecordId, existingRecordIdPlusOne - 1
            );
        }

        address[5] memory artifactAddresses =
            [artifacts.token, artifacts.market, artifacts.hook, artifacts.vault, artifacts.locker];
        bytes32[5] memory fields =
            [FIELD_TOKEN, FIELD_MARKET, FIELD_HOOK, FIELD_VAULT, FIELD_LOCKER];

        for (uint256 i; i < artifactAddresses.length; ++i) {
            address artifact = artifactAddresses[i];
            bool required = i < 2;
            if (artifact == address(0)) {
                if (required) revert QUOTEInvalidLaunchArtifact(fields[i], artifact);
                continue;
            }

            if (artifact == request.quoteToken || artifact.code.length == 0) {
                revert QUOTEInvalidLaunchArtifact(fields[i], artifact);
            }
            if (artifact == address(this) || artifact == engine) {
                revert QUOTEInvalidLaunchArtifact(fields[i], artifact);
            }

            for (uint256 j; j < i; ++j) {
                if (artifactAddresses[j] == artifact) {
                    revert QUOTEInvalidLaunchArtifact(fields[i], artifact);
                }
            }

            uint256 existingIdPlusOne = $.artifactLaunchIdPlusOne[artifact];
            if (existingIdPlusOne != 0) {
                revert QUOTEDuplicateLaunchArtifact(artifact, existingIdPlusOne - 1);
            }
        }
    }

    function _readLaunchedTokenSupply(address token, uint256 requestedSupply)
        private
        view
        returns (uint256 actualSupply)
    {
        (bool success, bytes memory data) = token.staticcall(abi.encodeCall(IERC20.totalSupply, ()));
        if (!success || data.length != 32) {
            revert QUOTEInvalidLaunchArtifact(FIELD_TOKEN, token);
        }

        actualSupply = abi.decode(data, (uint256));
        if (actualSupply == 0 || actualSupply > requestedSupply) {
            revert QUOTEInvalidLaunchedSupply(token, actualSupply, requestedSupply);
        }
    }

    function _recordArtifacts(
        QuoteLaunchpadStorage storage $,
        QuoteLaunchArtifacts memory artifacts,
        uint256 launchId
    ) private {
        uint256 idPlusOne = launchId + 1;
        $.launchIdPlusOneByToken[artifacts.token] = idPlusOne;
        $.launchIdPlusOneByMarket[artifacts.market] = idPlusOne;
        $.artifactLaunchIdPlusOne[artifacts.token] = idPlusOne;
        $.artifactLaunchIdPlusOne[artifacts.market] = idPlusOne;
        $.launchIdPlusOneByEngineRecordId[artifacts.engineRecordId] = idPlusOne;

        if (artifacts.hook != address(0)) $.artifactLaunchIdPlusOne[artifacts.hook] = idPlusOne;
        if (artifacts.vault != address(0)) $.artifactLaunchIdPlusOne[artifacts.vault] = idPlusOne;
        if (artifacts.locker != address(0)) {
            $.artifactLaunchIdPlusOne[artifacts.locker] = idPlusOne;
        }
    }

    function _getQuoteLaunchpadStorage() private pure returns (QuoteLaunchpadStorage storage $) {
        assembly {
            $.slot := QUOTE_LAUNCHPAD_STORAGE
        }
    }
}
