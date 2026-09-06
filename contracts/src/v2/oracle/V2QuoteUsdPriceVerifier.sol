// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { Ownable2Step } from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { ECDSA } from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

/// @notice Verifies backend-signed USD price and liquidity attestations for V2 launches.
/// @dev This contract does not derive USD value from arbitrary pools onchain. The backend signs
///      the consumer, creator, launch request hash, quote price, reference assets, observed
///      liquidity and freshness window.
contract V2QuoteUsdPriceVerifier is EIP712, Ownable2Step {
    uint256 public constant HARD_MIN_LIQUIDITY_USD_WAD = 10_000e18;
    uint256 public constant MAX_OBSERVATION_AGE_UPPER_BOUND = 1 hours;

    bytes32 public constant QUOTE_PRICE_ATTESTATION_TYPEHASH = keccak256(
        "QuotePriceAttestation(address consumer,address creator,bytes32 launchRequestHash,address quoteToken,address referenceToken,address referencePool,uint256 priceUsdWad,uint256 liquidityUsdWad,uint64 observationTimestamp,uint64 deadline,bytes32 nonce)"
    );

    struct QuotePriceAttestation {
        address consumer;
        address creator;
        bytes32 launchRequestHash;
        address quoteToken;
        address referenceToken;
        address referencePool;
        uint256 priceUsdWad;
        uint256 liquidityUsdWad;
        uint64 observationTimestamp;
        uint64 deadline;
        bytes32 nonce;
    }

    address public signer;
    address public pendingSigner;
    uint256 public immutable minLiquidityUsdWad;
    uint256 public immutable maxObservationAge;

    mapping(address referenceToken => bool allowed) public isReferenceTokenAllowed;
    mapping(bytes32 digest => bool consumed) public consumedDigests;

    error InvalidSigner();
    error NotPendingSigner();
    error OwnershipRenounceDisabled();
    error MinLiquidityBelowHardFloor();
    error InvalidMaxObservationAge(uint256 maxObservationAge);
    error ConsumerMismatch(address attestedConsumer, address caller);
    error QuoteTokenMismatch(address attestedQuoteToken, address expectedQuoteToken);
    error ReferenceTokenMismatch(address attestedReferenceToken, address expectedReferenceToken);
    error ReferencePoolMismatch(address attestedReferencePool, address expectedReferencePool);
    error ZeroConsumer();
    error ZeroCreator();
    error ZeroLaunchRequestHash();
    error ZeroQuoteToken();
    error ZeroReferenceToken();
    error ZeroReferencePool();
    error AddressHasNoCode(address account);
    error ReferenceTokenNotAllowed(address referenceToken);
    error ZeroPrice();
    error LiquidityBelowMinimum(uint256 liquidityUsdWad, uint256 minLiquidityUsdWad);
    error ZeroObservationTimestamp();
    error ObservationInFuture();
    error ObservationTooOld(uint64 observationTimestamp, uint256 maxObservationAge);
    error InvalidObservationWindow();
    error AttestationExpired();
    error ZeroNonce();
    error AttestationAlreadyConsumed(bytes32 digest);
    error InvalidSignature();

    event SignerRotationStarted(address indexed currentSigner, address indexed pendingSigner);
    event SignerRotated(address indexed previousSigner, address indexed newSigner);
    event ReferenceTokenAllowedSet(address indexed referenceToken, bool allowed);
    event QuotePriceAttestationConsumed(
        bytes32 indexed digest,
        address indexed consumer,
        address indexed creator,
        bytes32 launchRequestHash,
        address quoteToken,
        address referenceToken,
        address referencePool,
        uint256 priceUsdWad,
        uint256 liquidityUsdWad,
        uint64 observationTimestamp,
        uint64 deadline,
        bytes32 nonce
    );

    constructor(
        address initialOwner,
        address initialSigner,
        uint256 minLiquidityUsdWad_,
        uint256 maxObservationAge_,
        address[] memory initialReferenceTokens
    ) EIP712("QUOTE V2 Asset Eligibility", "1") Ownable(initialOwner) {
        if (initialSigner == address(0)) revert InvalidSigner();
        if (minLiquidityUsdWad_ < HARD_MIN_LIQUIDITY_USD_WAD) {
            revert MinLiquidityBelowHardFloor();
        }
        if (maxObservationAge_ == 0 || maxObservationAge_ > MAX_OBSERVATION_AGE_UPPER_BOUND) {
            revert InvalidMaxObservationAge(maxObservationAge_);
        }

        signer = initialSigner;
        minLiquidityUsdWad = minLiquidityUsdWad_;
        maxObservationAge = maxObservationAge_;

        uint256 length = initialReferenceTokens.length;
        for (uint256 i; i < length; ++i) {
            _setReferenceTokenAllowed(initialReferenceTokens[i], true);
        }
    }

    function startSignerRotation(address newSigner) external onlyOwner {
        if (newSigner == address(0) || newSigner == signer) revert InvalidSigner();
        pendingSigner = newSigner;
        emit SignerRotationStarted(signer, newSigner);
    }

    function cancelSignerRotation() external onlyOwner {
        pendingSigner = address(0);
        emit SignerRotationStarted(signer, address(0));
    }

    function acceptSigner() external {
        if (msg.sender != pendingSigner) revert NotPendingSigner();

        address previousSigner = signer;
        signer = msg.sender;
        pendingSigner = address(0);

        emit SignerRotated(previousSigner, msg.sender);
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        if (pendingSigner != address(0)) {
            pendingSigner = address(0);
            emit SignerRotationStarted(signer, address(0));
        }

        super.transferOwnership(newOwner);
    }

    function setReferenceTokenAllowed(address referenceToken, bool allowed) external onlyOwner {
        _setReferenceTokenAllowed(referenceToken, allowed);
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnershipRenounceDisabled();
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashStruct(QuotePriceAttestation calldata attestation) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_PRICE_ATTESTATION_TYPEHASH,
                attestation.consumer,
                attestation.creator,
                attestation.launchRequestHash,
                attestation.quoteToken,
                attestation.referenceToken,
                attestation.referencePool,
                attestation.priceUsdWad,
                attestation.liquidityUsdWad,
                attestation.observationTimestamp,
                attestation.deadline,
                attestation.nonce
            )
        );
    }

    function hashAttestation(QuotePriceAttestation calldata attestation)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(hashStruct(attestation));
    }

    function verify(
        address expectedQuoteToken,
        address expectedReferenceToken,
        address expectedReferencePool,
        QuotePriceAttestation calldata attestation,
        bytes calldata signature
    ) external view returns (bool) {
        bytes32 digest = hashAttestation(attestation);
        if (consumedDigests[digest]) return false;
        if (!_fieldsAreValid(
                expectedQuoteToken, expectedReferenceToken, expectedReferencePool, attestation
            )) {
            return false;
        }

        (address recovered, ECDSA.RecoverError recoverError,) = ECDSA.tryRecover(digest, signature);
        return recoverError == ECDSA.RecoverError.NoError && recovered == signer;
    }

    function verifyAndConsume(
        address expectedQuoteToken,
        address expectedReferenceToken,
        address expectedReferencePool,
        QuotePriceAttestation calldata attestation,
        bytes calldata signature
    )
        external
        returns (
            uint256 priceUsdWad,
            uint256 liquidityUsdWad,
            uint64 observationTimestamp,
            bytes32 digest
        )
    {
        _validateFields(
            expectedQuoteToken, expectedReferenceToken, expectedReferencePool, attestation
        );

        digest = hashAttestation(attestation);
        if (consumedDigests[digest]) revert AttestationAlreadyConsumed(digest);

        (address recovered, ECDSA.RecoverError recoverError,) = ECDSA.tryRecover(digest, signature);
        if (recoverError != ECDSA.RecoverError.NoError || recovered != signer) {
            revert InvalidSignature();
        }

        consumedDigests[digest] = true;

        emit QuotePriceAttestationConsumed(
            digest,
            attestation.consumer,
            attestation.creator,
            attestation.launchRequestHash,
            attestation.quoteToken,
            attestation.referenceToken,
            attestation.referencePool,
            attestation.priceUsdWad,
            attestation.liquidityUsdWad,
            attestation.observationTimestamp,
            attestation.deadline,
            attestation.nonce
        );

        return (
            attestation.priceUsdWad,
            attestation.liquidityUsdWad,
            attestation.observationTimestamp,
            digest
        );
    }

    function _setReferenceTokenAllowed(address referenceToken, bool allowed) private {
        if (referenceToken == address(0)) revert ZeroReferenceToken();
        isReferenceTokenAllowed[referenceToken] = allowed;
        emit ReferenceTokenAllowedSet(referenceToken, allowed);
    }

    function _validateFields(
        address expectedQuoteToken,
        address expectedReferenceToken,
        address expectedReferencePool,
        QuotePriceAttestation calldata attestation
    ) private view {
        if (!_fieldsAreValid(
                expectedQuoteToken, expectedReferenceToken, expectedReferencePool, attestation
            )) {
            _revertInvalidFields(
                expectedQuoteToken, expectedReferenceToken, expectedReferencePool, attestation
            );
        }
    }

    function _fieldsAreValid(
        address expectedQuoteToken,
        address expectedReferenceToken,
        address expectedReferencePool,
        QuotePriceAttestation calldata attestation
    ) private view returns (bool) {
        if (attestation.consumer != msg.sender) {
            return false;
        }
        if (attestation.quoteToken != expectedQuoteToken) return false;
        if (attestation.referenceToken != expectedReferenceToken) return false;
        if (attestation.referencePool != expectedReferencePool) return false;
        if (attestation.consumer == address(0)) return false;
        if (attestation.creator == address(0)) return false;
        if (attestation.launchRequestHash == bytes32(0)) return false;
        if (attestation.quoteToken == address(0)) return false;
        if (attestation.referenceToken == address(0)) return false;
        if (attestation.referencePool == address(0)) return false;
        if (attestation.quoteToken.code.length == 0) return false;
        if (attestation.referenceToken.code.length == 0) return false;
        if (attestation.referencePool.code.length == 0) return false;
        if (!isReferenceTokenAllowed[attestation.referenceToken]) return false;
        if (attestation.priceUsdWad == 0) return false;
        if (attestation.liquidityUsdWad < minLiquidityUsdWad) return false;
        if (attestation.observationTimestamp == 0) return false;
        if (attestation.observationTimestamp > block.timestamp) return false;
        if (block.timestamp - attestation.observationTimestamp > maxObservationAge) return false;
        if (attestation.deadline < attestation.observationTimestamp) return false;
        if (attestation.deadline < block.timestamp) return false;
        if (attestation.nonce == bytes32(0)) return false;
        return true;
    }

    function _revertInvalidFields(
        address expectedQuoteToken,
        address expectedReferenceToken,
        address expectedReferencePool,
        QuotePriceAttestation calldata attestation
    ) private view {
        if (attestation.consumer != msg.sender) {
            revert ConsumerMismatch(attestation.consumer, msg.sender);
        }
        if (attestation.quoteToken != expectedQuoteToken) {
            revert QuoteTokenMismatch(attestation.quoteToken, expectedQuoteToken);
        }
        if (attestation.referenceToken != expectedReferenceToken) {
            revert ReferenceTokenMismatch(attestation.referenceToken, expectedReferenceToken);
        }
        if (attestation.referencePool != expectedReferencePool) {
            revert ReferencePoolMismatch(attestation.referencePool, expectedReferencePool);
        }
        if (attestation.consumer == address(0)) revert ZeroConsumer();
        if (attestation.creator == address(0)) revert ZeroCreator();
        if (attestation.launchRequestHash == bytes32(0)) revert ZeroLaunchRequestHash();
        if (attestation.quoteToken == address(0)) revert ZeroQuoteToken();
        if (attestation.referenceToken == address(0)) revert ZeroReferenceToken();
        if (attestation.referencePool == address(0)) revert ZeroReferencePool();
        if (attestation.quoteToken.code.length == 0) {
            revert AddressHasNoCode(attestation.quoteToken);
        }
        if (attestation.referenceToken.code.length == 0) {
            revert AddressHasNoCode(attestation.referenceToken);
        }
        if (attestation.referencePool.code.length == 0) {
            revert AddressHasNoCode(attestation.referencePool);
        }
        if (!isReferenceTokenAllowed[attestation.referenceToken]) {
            revert ReferenceTokenNotAllowed(attestation.referenceToken);
        }
        if (attestation.priceUsdWad == 0) revert ZeroPrice();
        if (attestation.liquidityUsdWad < minLiquidityUsdWad) {
            revert LiquidityBelowMinimum(attestation.liquidityUsdWad, minLiquidityUsdWad);
        }
        if (attestation.observationTimestamp == 0) revert ZeroObservationTimestamp();
        if (attestation.observationTimestamp > block.timestamp) revert ObservationInFuture();
        if (block.timestamp - attestation.observationTimestamp > maxObservationAge) {
            revert ObservationTooOld(attestation.observationTimestamp, maxObservationAge);
        }
        if (attestation.deadline < attestation.observationTimestamp) {
            revert InvalidObservationWindow();
        }
        if (attestation.deadline < block.timestamp) revert AttestationExpired();
        if (attestation.nonce == bytes32(0)) revert ZeroNonce();
    }
}
