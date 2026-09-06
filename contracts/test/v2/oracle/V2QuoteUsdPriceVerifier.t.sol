// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

import { V2QuoteUsdPriceVerifier } from "../../../src/v2/oracle/V2QuoteUsdPriceVerifier.sol";

contract V2QuoteUsdPriceVerifierTest is Test {
    uint256 internal constant SIGNER_KEY = 0xA11CE;
    uint256 internal constant OTHER_SIGNER_KEY = 0xB0B;
    uint256 internal constant MIN_LIQUIDITY = 10_000e18;
    uint256 internal constant MAX_OBSERVATION_AGE = 15 minutes;

    address internal admin = makeAddr("admin");
    address internal launchFactory = makeAddr("launchFactory");
    address internal quoteToken = makeAddr("quoteToken");
    address internal referenceToken = makeAddr("referenceToken");
    address internal referencePool = makeAddr("referencePool");
    address internal creator = makeAddr("creator");
    bytes32 internal launchRequestHash = keccak256("launch-request");
    address internal signer = vm.addr(SIGNER_KEY);

    V2QuoteUsdPriceVerifier internal verifier;

    function setUp() external {
        vm.warp(1_700_000_000);
        vm.etch(quoteToken, hex"00");
        vm.etch(referenceToken, hex"00");
        vm.etch(referencePool, hex"00");

        address[] memory referenceTokens = new address[](1);
        referenceTokens[0] = referenceToken;
        verifier = new V2QuoteUsdPriceVerifier(
            admin, signer, MIN_LIQUIDITY, MAX_OBSERVATION_AGE, referenceTokens
        );
    }

    function testVerifyAndConsumeAcceptsFreshSignedAttestation() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("valid"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);
        bytes32 expectedDigest = verifier.hashAttestation(attestation);

        vm.prank(launchFactory);
        (
            uint256 priceUsdWad,
            uint256 liquidityUsdWad,
            uint64 observationTimestamp,
            bytes32 digest
        ) = verifier.verifyAndConsume(
            quoteToken, referenceToken, referencePool, attestation, signature
        );

        assertEq(priceUsdWad, attestation.priceUsdWad);
        assertEq(liquidityUsdWad, attestation.liquidityUsdWad);
        assertEq(observationTimestamp, attestation.observationTimestamp);
        assertEq(digest, expectedDigest);
        assertTrue(verifier.consumedDigests(expectedDigest));
    }

    function testVerifyReturnsFalseAfterConsumption() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("view-check"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        assertTrue(
            verifier.verify(quoteToken, referenceToken, referencePool, attestation, signature)
        );

        vm.prank(launchFactory);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);

        vm.prank(launchFactory);
        assertFalse(
            verifier.verify(quoteToken, referenceToken, referencePool, attestation, signature)
        );
    }

    function testRejectsReplay() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("replay"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);
        bytes32 digest = verifier.hashAttestation(attestation);

        vm.prank(launchFactory);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);

        vm.prank(launchFactory);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.AttestationAlreadyConsumed.selector, digest
            )
        );
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsExpiredAttestation() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("expired"));
        attestation.deadline = uint64(block.timestamp - 1);
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.AttestationExpired.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsZeroQuoteTokenAndZeroPrice() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("zero-quote"));
        attestation.quoteToken = address(0);
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.ZeroQuoteToken.selector);
        verifier.verifyAndConsume(address(0), referenceToken, referencePool, attestation, signature);

        attestation = _attestation(bytes32("zero-price"));
        attestation.priceUsdWad = 0;
        signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.ZeroPrice.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsAttestedAddressesWithoutRuntimeCode() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("no-code-quote"));
        address noCodeQuote = makeAddr("noCodeQuote");
        attestation.quoteToken = noCodeQuote;
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(
            abi.encodeWithSelector(V2QuoteUsdPriceVerifier.AddressHasNoCode.selector, noCodeQuote)
        );
        verifier.verifyAndConsume(
            noCodeQuote, referenceToken, referencePool, attestation, signature
        );

        attestation = _attestation(bytes32("no-code-pool"));
        address noCodePool = makeAddr("noCodePool");
        attestation.referencePool = noCodePool;
        signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(
            abi.encodeWithSelector(V2QuoteUsdPriceVerifier.AddressHasNoCode.selector, noCodePool)
        );
        verifier.verifyAndConsume(quoteToken, referenceToken, noCodePool, attestation, signature);
    }

    function testRejectsReferenceTokenAndPoolBindingMismatches() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("pool-binding"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        address otherReference = makeAddr("otherReference");
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.ReferenceTokenMismatch.selector,
                referenceToken,
                otherReference
            )
        );
        verifier.verifyAndConsume(quoteToken, otherReference, referencePool, attestation, signature);

        vm.prank(launchFactory);
        address otherPool = makeAddr("otherPool");
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.ReferencePoolMismatch.selector, referencePool, otherPool
            )
        );
        verifier.verifyAndConsume(quoteToken, referenceToken, otherPool, attestation, signature);
    }

    function testRejectsTamperedQuoteAndReferencePool() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("tamper"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        attestation.quoteToken = makeAddr("tamperedQuote");
        vm.etch(attestation.quoteToken, hex"00");
        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(
            attestation.quoteToken, referenceToken, referencePool, attestation, signature
        );

        attestation = _attestation(bytes32("tamper-pool"));
        signature = _sign(attestation, SIGNER_KEY);
        attestation.referencePool = makeAddr("tamperedPool");
        vm.etch(attestation.referencePool, hex"00");

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(
            quoteToken, referenceToken, attestation.referencePool, attestation, signature
        );
    }

    function testSignatureBindsCreatorAndLaunchRequestHash() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("request-binding"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        attestation.creator = makeAddr("tamperedCreator");
        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);

        attestation = _attestation(bytes32("hash-binding"));
        signature = _sign(attestation, SIGNER_KEY);
        attestation.launchRequestHash = keccak256("tampered-request");
        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsZeroCreatorAndLaunchRequestHash() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("zero-creator"));
        attestation.creator = address(0);
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.ZeroCreator.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);

        attestation = _attestation(bytes32("zero-request-hash"));
        attestation.launchRequestHash = bytes32(0);
        signature = _sign(attestation, SIGNER_KEY);
        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.ZeroLaunchRequestHash.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsWrongConsumer() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("consumer"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.ConsumerMismatch.selector, launchFactory, attacker
            )
        );
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsWrongSigner() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("wrong-signer"));
        bytes memory signature = _sign(attestation, OTHER_SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsWrongVerifyingContractDomain() external {
        address[] memory referenceTokens = new address[](1);
        referenceTokens[0] = referenceToken;
        V2QuoteUsdPriceVerifier otherVerifier = new V2QuoteUsdPriceVerifier(
            admin, signer, MIN_LIQUIDITY, MAX_OBSERVATION_AGE, referenceTokens
        );

        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("wrong-contract"));
        bytes32 wrongDigest = otherVerifier.hashAttestation(attestation);
        bytes memory signature = _signDigest(wrongDigest, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsWrongChainDomain() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("wrong-chain"));
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.chainId(56);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testEnforcesLiquidityThresholdAndAllowedReferenceToken() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("low-liquidity"));
        attestation.liquidityUsdWad = MIN_LIQUIDITY - 1;
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.LiquidityBelowMinimum.selector,
                MIN_LIQUIDITY - 1,
                MIN_LIQUIDITY
            )
        );
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);

        address unallowedReferenceToken = makeAddr("unallowedReferenceToken");
        vm.etch(unallowedReferenceToken, hex"00");
        attestation = _attestation(bytes32("unallowed-reference"));
        attestation.referenceToken = unallowedReferenceToken;
        signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.ReferenceTokenNotAllowed.selector, unallowedReferenceToken
            )
        );
        verifier.verifyAndConsume(
            quoteToken, unallowedReferenceToken, referencePool, attestation, signature
        );

        vm.prank(admin);
        verifier.setReferenceTokenAllowed(unallowedReferenceToken, true);

        signature = _sign(attestation, SIGNER_KEY);
        vm.prank(launchFactory);
        verifier.verifyAndConsume(
            quoteToken, unallowedReferenceToken, referencePool, attestation, signature
        );
    }

    function testRejectsInvalidObservationWindow() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("future-observation"));
        attestation.observationTimestamp = uint64(block.timestamp + 1);
        attestation.deadline = uint64(block.timestamp + 1 hours);
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.ObservationInFuture.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);

        attestation = _attestation(bytes32("bad-window"));
        attestation.deadline = attestation.observationTimestamp - 1;
        signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidObservationWindow.selector);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsHardMinLiquidityBelowTenThousandUsd() external {
        address[] memory referenceTokens = new address[](1);
        referenceTokens[0] = referenceToken;

        vm.expectRevert(V2QuoteUsdPriceVerifier.MinLiquidityBelowHardFloor.selector);
        new V2QuoteUsdPriceVerifier(
            admin, signer, MIN_LIQUIDITY - 1, MAX_OBSERVATION_AGE, referenceTokens
        );
    }

    function testRejectsInvalidMaxObservationAge() external {
        address[] memory referenceTokens = new address[](1);
        referenceTokens[0] = referenceToken;

        vm.expectRevert(
            abi.encodeWithSelector(V2QuoteUsdPriceVerifier.InvalidMaxObservationAge.selector, 0)
        );
        new V2QuoteUsdPriceVerifier(admin, signer, MIN_LIQUIDITY, 0, referenceTokens);

        uint256 tooLong = verifier.MAX_OBSERVATION_AGE_UPPER_BOUND() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.InvalidMaxObservationAge.selector, tooLong
            )
        );
        new V2QuoteUsdPriceVerifier(admin, signer, MIN_LIQUIDITY, tooLong, referenceTokens);
    }

    function testAcceptsObservationExactlyAtMaxAgeBoundary() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("max-age-boundary"));
        attestation.observationTimestamp = uint64(block.timestamp - MAX_OBSERVATION_AGE);
        attestation.deadline = uint64(block.timestamp + 5 minutes);
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testRejectsObservationOneSecondTooOldEvenWithFutureDeadline() external {
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation =
            _attestation(bytes32("one-second-too-old"));
        attestation.observationTimestamp = uint64(block.timestamp - MAX_OBSERVATION_AGE - 1);
        attestation.deadline = uint64(block.timestamp + 5 minutes);
        bytes memory signature = _sign(attestation, SIGNER_KEY);

        vm.prank(launchFactory);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2QuoteUsdPriceVerifier.ObservationTooOld.selector,
                attestation.observationTimestamp,
                MAX_OBSERVATION_AGE
            )
        );
        verifier.verifyAndConsume(quoteToken, referenceToken, referencePool, attestation, signature);
    }

    function testSignerRotationIsTwoStepAndOwnershipIsTwoStep() external {
        address nextSigner = vm.addr(0xCAFE);
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory oldSignerAttestation =
            _attestation(bytes32("old-signer"));
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory newSignerAttestation =
            _attestation(bytes32("new-signer"));
        bytes memory oldSignerSignature = _sign(oldSignerAttestation, SIGNER_KEY);
        bytes memory newSignerSignature = _sign(newSignerAttestation, 0xCAFE);

        vm.prank(admin);
        verifier.startSignerRotation(nextSigner);
        assertEq(verifier.pendingSigner(), nextSigner);
        assertEq(verifier.signer(), signer);

        vm.prank(makeAddr("not-pending"));
        vm.expectRevert(V2QuoteUsdPriceVerifier.NotPendingSigner.selector);
        verifier.acceptSigner();

        vm.prank(nextSigner);
        verifier.acceptSigner();
        assertEq(verifier.pendingSigner(), address(0));
        assertEq(verifier.signer(), nextSigner);

        vm.prank(launchFactory);
        vm.expectRevert(V2QuoteUsdPriceVerifier.InvalidSignature.selector);
        verifier.verifyAndConsume(
            quoteToken, referenceToken, referencePool, oldSignerAttestation, oldSignerSignature
        );

        vm.prank(launchFactory);
        verifier.verifyAndConsume(
            quoteToken, referenceToken, referencePool, newSignerAttestation, newSignerSignature
        );

        address nextAdmin = makeAddr("nextAdmin");
        vm.prank(admin);
        verifier.transferOwnership(nextAdmin);
        assertEq(verifier.owner(), admin);
        assertEq(verifier.pendingOwner(), nextAdmin);

        vm.prank(nextAdmin);
        verifier.acceptOwnership();
        assertEq(verifier.owner(), nextAdmin);
    }

    function testOwnershipTransferClearsPendingSignerRotation() external {
        address nextSigner = vm.addr(0xCAFE);
        address nextAdmin = makeAddr("nextAdmin");

        vm.startPrank(admin);
        verifier.startSignerRotation(nextSigner);
        assertEq(verifier.pendingSigner(), nextSigner);

        verifier.transferOwnership(nextAdmin);
        vm.stopPrank();

        assertEq(verifier.pendingSigner(), address(0));
        assertEq(verifier.pendingOwner(), nextAdmin);

        vm.prank(nextSigner);
        vm.expectRevert(V2QuoteUsdPriceVerifier.NotPendingSigner.selector);
        verifier.acceptSigner();

        vm.prank(nextAdmin);
        verifier.acceptOwnership();

        assertEq(verifier.owner(), nextAdmin);
        assertEq(verifier.pendingSigner(), address(0));
    }

    function testOnlyOwnerCanManageSignerAndReferenceTokens() external {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        verifier.startSignerRotation(vm.addr(0xCAFE));

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
        );
        verifier.setReferenceTokenAllowed(makeAddr("newReference"), true);

        vm.prank(admin);
        vm.expectRevert(V2QuoteUsdPriceVerifier.OwnershipRenounceDisabled.selector);
        verifier.renounceOwnership();
    }

    function _attestation(bytes32 nonce)
        internal
        view
        returns (V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation)
    {
        attestation = V2QuoteUsdPriceVerifier.QuotePriceAttestation({
            consumer: launchFactory,
            creator: creator,
            launchRequestHash: launchRequestHash,
            quoteToken: quoteToken,
            referenceToken: referenceToken,
            referencePool: referencePool,
            priceUsdWad: 1.25e18,
            liquidityUsdWad: MIN_LIQUIDITY,
            observationTimestamp: uint64(block.timestamp - 5 minutes),
            deadline: uint64(block.timestamp + 5 minutes),
            nonce: nonce
        });
    }

    function _sign(
        V2QuoteUsdPriceVerifier.QuotePriceAttestation memory attestation,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        return _signDigest(verifier.hashAttestation(attestation), privateKey);
    }

    function _signDigest(bytes32 digest, uint256 privateKey) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
