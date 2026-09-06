// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { TokenMode, V2FeeConfig } from "../QuoteV2Types.sol";

enum QuoteLaunchEngineKind {
    UNKNOWN,
    DIRECT,
    CURVE
}

struct QuoteLaunchRequest {
    address creator;
    address quoteToken;
    uint256 supply;
    uint256 nativeAmount;
    uint256 deadline;
    TokenMode tokenMode;
    V2FeeConfig feeConfig;
    address creatorFeeRecipient;
    address rewardFeeRecipient;
    QuoteLaunchEngineKind engineKind;
    bytes32 engineVersion;
    bytes enginePayload;
}

struct QuoteLaunchContext {
    uint256 launchId;
    address creator;
    address quoteToken;
    uint256 supply;
    uint256 nativeAmount;
    uint256 deadline;
    TokenMode tokenMode;
    V2FeeConfig feeConfig;
    address creatorFeeRecipient;
    address rewardFeeRecipient;
    QuoteLaunchEngineKind engineKind;
    bytes32 engineVersion;
}

struct QuoteLaunchArtifacts {
    address creator;
    address token;
    address market;
    address hook;
    address vault;
    address locker;
    bytes32 poolId;
    bytes32 engineRecordId;
}

struct QuoteLaunchRecord {
    uint256 launchId;
    address creator;
    address quoteToken;
    uint256 supply;
    TokenMode tokenMode;
    V2FeeConfig feeConfig;
    address creatorFeeRecipient;
    address rewardFeeRecipient;
    QuoteLaunchEngineKind engineKind;
    bytes32 engineVersion;
    address engine;
    QuoteLaunchArtifacts artifacts;
    uint64 launchedAt;
}

interface IQuoteLaunchEngine {
    function launchpad() external view returns (address);

    function engineKind() external view returns (QuoteLaunchEngineKind);

    function engineVersion() external view returns (bytes32);

    function launch(QuoteLaunchContext calldata context, bytes calldata enginePayload)
        external
        payable
        returns (QuoteLaunchArtifacts memory artifacts);
}

interface IQuoteLaunchpad {
    function launch(QuoteLaunchRequest calldata request)
        external
        payable
        returns (QuoteLaunchRecord memory record);
}
