// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CrossChainCodec} from "../../src/libraries/CrossChainCodec.sol";

/// @title CrossChainCodecWrapper
/// @notice Helper contract to test library reverts via external calls
contract CrossChainCodecWrapper {
    function getSchemaId(bytes memory payload) external pure returns (bytes32) {
        return CrossChainCodec.getSchemaId(payload);
    }

    function decodeSignaturesComplete(bytes memory payload) external pure returns (bytes32, address[] memory) {
        return CrossChainCodec.decodeSignaturesComplete(payload);
    }
}

/// @title CrossChainCodec Unit Tests
/// @notice Tests for the cross-chain message encoding/decoding library
contract CrossChainCodecTest is Test {
    // Test accounts
    address alice;
    address bob;
    address charlie;

    // Wrapper for testing library reverts
    CrossChainCodecWrapper wrapper;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        wrapper = new CrossChainCodecWrapper();
    }

    // =============================================================
    // INTROSPECTION TESTS
    // =============================================================

    function test_GetSchemaId_ExtractsCorrectly() public pure {
        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(keccak256("doc"), new address[](0));

        bytes32 schemaId = CrossChainCodec.getSchemaId(payload);
        assertEq(schemaId, CrossChainCodec.SIGNATURES_COMPLETE_V1);
    }

    function test_GetSchemaId_RevertsOnShortPayload() public {
        bytes memory shortPayload = new bytes(31);

        vm.expectRevert(CrossChainCodec.InvalidPayload.selector);
        wrapper.getSchemaId(shortPayload);
    }

    function test_IsSchema_ReturnsTrue() public pure {
        bytes memory payload = CrossChainCodec.encodeContentSealed(keccak256("content"), "ipfs://test", address(0x123));

        assertTrue(CrossChainCodec.isSchema(payload, CrossChainCodec.CONTENT_SEALED_V1));
    }

    function test_IsSchema_ReturnsFalse_WrongSchema() public pure {
        bytes memory payload = CrossChainCodec.encodeContentSealed(keccak256("content"), "ipfs://test", address(0x123));

        assertFalse(CrossChainCodec.isSchema(payload, CrossChainCodec.SIGNATURES_COMPLETE_V1));
    }

    function test_IsSchema_ReturnsFalse_ShortPayload() public pure {
        bytes memory shortPayload = new bytes(31);
        assertFalse(CrossChainCodec.isSchema(shortPayload, CrossChainCodec.SIGNATURES_COMPLETE_V1));
    }

    // =============================================================
    // ATTESTATION EVENTS
    // =============================================================

    function test_SignaturesComplete_RoundTrip() public {
        bytes32 contentHash = keccak256("document-to-sign");
        address[] memory signers = new address[](3);
        signers[0] = alice;
        signers[1] = bob;
        signers[2] = charlie;

        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(contentHash, signers);

        (bytes32 decodedHash, address[] memory decodedSigners) = CrossChainCodec.decodeSignaturesComplete(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedSigners.length, 3);
        assertEq(decodedSigners[0], alice);
        assertEq(decodedSigners[1], bob);
        assertEq(decodedSigners[2], charlie);
    }

    function test_SignaturesComplete_EmptySigners() public pure {
        bytes32 contentHash = keccak256("doc");
        address[] memory signers = new address[](0);

        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(contentHash, signers);

        (bytes32 decodedHash, address[] memory decodedSigners) = CrossChainCodec.decodeSignaturesComplete(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedSigners.length, 0);
    }

    function test_SignaturesComplete_WrongSchema_Reverts() public {
        // Create a payload with the correct structure but wrong schema
        // (same types: bytes32, bytes32, address[])
        bytes memory wrongPayload = abi.encode(
            CrossChainCodec.CONTENT_SEALED_V1, // wrong schema
            keccak256("content"),
            new address[](0)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CrossChainCodec.SchemaMismatch.selector,
                CrossChainCodec.SIGNATURES_COMPLETE_V1,
                CrossChainCodec.CONTENT_SEALED_V1
            )
        );
        wrapper.decodeSignaturesComplete(wrongPayload);
    }

    function test_WitnessConfirmed_RoundTrip() public {
        bytes32 contentHash = keccak256("witnessed-content");

        bytes memory payload = CrossChainCodec.encodeWitnessConfirmed(contentHash, alice);

        (bytes32 decodedHash, address decodedWitness) = CrossChainCodec.decodeWitnessConfirmed(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedWitness, alice);
    }

    // =============================================================
    // CONTENT EVENTS
    // =============================================================

    function test_ContentSealed_RoundTrip() public {
        bytes32 contentHash = keccak256("sealed-content");
        string memory uri = "ipfs://QmSealedDocument123";

        bytes memory payload = CrossChainCodec.encodeContentSealed(contentHash, uri, alice);

        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentSealed(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, uri);
        assertEq(decodedRegistrant, alice);
    }

    function test_ContentSealed_EmptyUri() public {
        bytes32 contentHash = keccak256("sealed-content");

        bytes memory payload = CrossChainCodec.encodeContentSealed(contentHash, "", alice);

        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentSealed(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, "");
        assertEq(decodedRegistrant, alice);
    }

    function test_ContentRevoked_RoundTrip() public pure {
        bytes32 contentHash = keccak256("revoked-content");

        bytes memory payload = CrossChainCodec.encodeContentRevoked(contentHash);

        bytes32 decodedHash = CrossChainCodec.decodeContentRevoked(payload);

        assertEq(decodedHash, contentHash);
    }

    function test_ContentRegistered_RoundTrip() public {
        bytes32 contentHash = keccak256("registered-content");
        string memory uri = "ar://ArweaveHash123";

        bytes memory payload = CrossChainCodec.encodeContentRegistered(contentHash, uri, bob);

        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentRegistered(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, uri);
        assertEq(decodedRegistrant, bob);
    }

    // =============================================================
    // FINANCIAL EVENTS
    // =============================================================

    function test_EscrowFunded_RoundTrip() public {
        uint256 amount = 1.5 ether;
        address token = address(0); // Native

        bytes memory payload = CrossChainCodec.encodeEscrowFunded(amount, token, alice);

        (uint256 decodedAmount, address decodedToken, address decodedDepositor) =
            CrossChainCodec.decodeEscrowFunded(payload);

        assertEq(decodedAmount, amount);
        assertEq(decodedToken, token);
        assertEq(decodedDepositor, alice);
    }

    function test_ReleaseAuthorized_RoundTrip() public {
        uint256 amount = 100 ether;
        bytes32 contentHash = keccak256("completed-agreement");

        bytes memory payload = CrossChainCodec.encodeReleaseAuthorized(amount, bob, contentHash);

        (uint256 decodedAmount, address decodedRecipient, bytes32 decodedHash) =
            CrossChainCodec.decodeReleaseAuthorized(payload);

        assertEq(decodedAmount, amount);
        assertEq(decodedRecipient, bob);
        assertEq(decodedHash, contentHash);
    }

    function test_RefundAuthorized_RoundTrip() public {
        uint256 amount = 50 ether;
        bytes32 reason = keccak256("deadline-missed");

        bytes memory payload = CrossChainCodec.encodeRefundAuthorized(amount, charlie, reason);

        (uint256 decodedAmount, address decodedRecipient, bytes32 decodedReason) =
            CrossChainCodec.decodeRefundAuthorized(payload);

        assertEq(decodedAmount, amount);
        assertEq(decodedRecipient, charlie);
        assertEq(decodedReason, reason);
    }

    // =============================================================
    // STATE EVENTS
    // =============================================================

    function test_ConditionMet_RoundTrip() public pure {
        bytes32 conditionId = keccak256("price-threshold");
        bytes32 value = bytes32(uint256(1000 * 10 ** 18)); // Price value

        bytes memory payload = CrossChainCodec.encodeConditionMet(conditionId, value);

        (bytes32 decodedId, bytes32 decodedValue) = CrossChainCodec.decodeConditionMet(payload);

        assertEq(decodedId, conditionId);
        assertEq(decodedValue, value);
    }

    function test_DeadlineReached_RoundTrip() public pure {
        bytes32 deadlineId = keccak256("payment-deadline");
        uint256 timestamp = 1700000000;

        bytes memory payload = CrossChainCodec.encodeDeadlineReached(deadlineId, timestamp);

        (bytes32 decodedId, uint256 decodedTimestamp) = CrossChainCodec.decodeDeadlineReached(payload);

        assertEq(decodedId, deadlineId);
        assertEq(decodedTimestamp, timestamp);
    }

    function test_TimelockUnlocked_RoundTrip() public pure {
        bytes32 lockId = keccak256("vesting-lock");
        uint256 unlockedAt = 1700000000;

        bytes memory payload = CrossChainCodec.encodeTimelockUnlocked(lockId, unlockedAt);

        (bytes32 decodedId, uint256 decodedUnlockedAt) = CrossChainCodec.decodeTimelockUnlocked(payload);

        assertEq(decodedId, lockId);
        assertEq(decodedUnlockedAt, unlockedAt);
    }

    // =============================================================
    // ACCESS EVENTS
    // =============================================================

    function test_PartiesRegistered_RoundTrip() public {
        bytes32 role = keccak256("SIGNER");
        address[] memory parties = new address[](2);
        parties[0] = alice;
        parties[1] = bob;

        bytes memory payload = CrossChainCodec.encodePartiesRegistered(role, parties);

        (bytes32 decodedRole, address[] memory decodedParties) = CrossChainCodec.decodePartiesRegistered(payload);

        assertEq(decodedRole, role);
        assertEq(decodedParties.length, 2);
        assertEq(decodedParties[0], alice);
        assertEq(decodedParties[1], bob);
    }

    function test_PermissionGranted_RoundTrip() public {
        bytes32 permission = keccak256("EXECUTE");

        bytes memory payload = CrossChainCodec.encodePermissionGranted(bob, permission, alice);

        (address decodedGrantee, bytes32 decodedPermission, address decodedGranter) =
            CrossChainCodec.decodePermissionGranted(payload);

        assertEq(decodedGrantee, bob);
        assertEq(decodedPermission, permission);
        assertEq(decodedGranter, alice);
    }

    // =============================================================
    // GOVERNANCE EVENTS
    // =============================================================

    function test_VoteRecorded_RoundTrip() public {
        bytes32 proposalId = keccak256("proposal-1");
        uint256 weight = 1000;
        bool support = true;

        bytes memory payload = CrossChainCodec.encodeVoteRecorded(proposalId, alice, weight, support);

        (bytes32 decodedProposal, address decodedVoter, uint256 decodedWeight, bool decodedSupport) =
            CrossChainCodec.decodeVoteRecorded(payload);

        assertEq(decodedProposal, proposalId);
        assertEq(decodedVoter, alice);
        assertEq(decodedWeight, weight);
        assertEq(decodedSupport, support);
    }

    function test_QuorumReached_RoundTrip() public pure {
        bytes32 proposalId = keccak256("proposal-2");
        uint256 totalWeight = 10000;
        uint256 threshold = 5000;

        bytes memory payload = CrossChainCodec.encodeQuorumReached(proposalId, totalWeight, threshold);

        (bytes32 decodedProposal, uint256 decodedTotal, uint256 decodedThreshold) =
            CrossChainCodec.decodeQuorumReached(payload);

        assertEq(decodedProposal, proposalId);
        assertEq(decodedTotal, totalWeight);
        assertEq(decodedThreshold, threshold);
    }

    function test_RulingIssued_RoundTrip() public {
        bytes32 disputeId = keccak256("dispute-1");
        uint8 ruling = 2; // Party 2 wins

        bytes memory payload = CrossChainCodec.encodeRulingIssued(disputeId, ruling, charlie);

        (bytes32 decodedDispute, uint8 decodedRuling, address decodedArbiter) =
            CrossChainCodec.decodeRulingIssued(payload);

        assertEq(decodedDispute, disputeId);
        assertEq(decodedRuling, ruling);
        assertEq(decodedArbiter, charlie);
    }

    // =============================================================
    // GENERIC (ESCAPE HATCH)
    // =============================================================

    function test_Generic_RoundTrip() public pure {
        bytes32 customSchemaId = keccak256("custom.MyCustomMessage.v1");
        bytes memory innerData = abi.encode(uint256(42), "hello", true);

        bytes memory payload = CrossChainCodec.encodeGeneric(customSchemaId, innerData);

        (bytes32 decodedSchemaId, bytes memory decodedData) = CrossChainCodec.decodeGeneric(payload);

        assertEq(decodedSchemaId, customSchemaId);
        assertEq(keccak256(decodedData), keccak256(innerData));
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_SignaturesComplete_RoundTrip(bytes32 contentHash, uint8 signerCount) public {
        vm.assume(signerCount <= 20);

        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(i + 1));
        }

        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(contentHash, signers);

        (bytes32 decodedHash, address[] memory decodedSigners) = CrossChainCodec.decodeSignaturesComplete(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedSigners.length, signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            assertEq(decodedSigners[i], signers[i]);
        }
    }

    function testFuzz_ContentSealed_RoundTrip(bytes32 contentHash, address registrant) public pure {
        string memory uri = "ipfs://fuzz-test-uri";

        bytes memory payload = CrossChainCodec.encodeContentSealed(contentHash, uri, registrant);

        (bytes32 decodedHash, string memory decodedUri, address decodedRegistrant) =
            CrossChainCodec.decodeContentSealed(payload);

        assertEq(decodedHash, contentHash);
        assertEq(decodedUri, uri);
        assertEq(decodedRegistrant, registrant);
    }

    function testFuzz_EscrowFunded_RoundTrip(uint256 amount, address token, address depositor) public pure {
        bytes memory payload = CrossChainCodec.encodeEscrowFunded(amount, token, depositor);

        (uint256 decodedAmount, address decodedToken, address decodedDepositor) =
            CrossChainCodec.decodeEscrowFunded(payload);

        assertEq(decodedAmount, amount);
        assertEq(decodedToken, token);
        assertEq(decodedDepositor, depositor);
    }

    function testFuzz_ReleaseAuthorized_RoundTrip(uint256 amount, address recipient, bytes32 contentHash) public pure {
        bytes memory payload = CrossChainCodec.encodeReleaseAuthorized(amount, recipient, contentHash);

        (uint256 decodedAmount, address decodedRecipient, bytes32 decodedHash) =
            CrossChainCodec.decodeReleaseAuthorized(payload);

        assertEq(decodedAmount, amount);
        assertEq(decodedRecipient, recipient);
        assertEq(decodedHash, contentHash);
    }

    function testFuzz_ConditionMet_RoundTrip(bytes32 conditionId, bytes32 value) public pure {
        bytes memory payload = CrossChainCodec.encodeConditionMet(conditionId, value);

        (bytes32 decodedId, bytes32 decodedValue) = CrossChainCodec.decodeConditionMet(payload);

        assertEq(decodedId, conditionId);
        assertEq(decodedValue, value);
    }

    function testFuzz_PartiesRegistered_RoundTrip(bytes32 role, uint8 partyCount) public {
        vm.assume(partyCount <= 20);

        address[] memory parties = new address[](partyCount);
        for (uint256 i = 0; i < partyCount; i++) {
            parties[i] = address(uint160(i + 100));
        }

        bytes memory payload = CrossChainCodec.encodePartiesRegistered(role, parties);

        (bytes32 decodedRole, address[] memory decodedParties) = CrossChainCodec.decodePartiesRegistered(payload);

        assertEq(decodedRole, role);
        assertEq(decodedParties.length, partyCount);
        for (uint256 i = 0; i < partyCount; i++) {
            assertEq(decodedParties[i], parties[i]);
        }
    }

    function testFuzz_VoteRecorded_RoundTrip(bytes32 proposalId, address voter, uint256 weight, bool support)
        public
        pure
    {
        bytes memory payload = CrossChainCodec.encodeVoteRecorded(proposalId, voter, weight, support);

        (bytes32 decodedProposal, address decodedVoter, uint256 decodedWeight, bool decodedSupport) =
            CrossChainCodec.decodeVoteRecorded(payload);

        assertEq(decodedProposal, proposalId);
        assertEq(decodedVoter, voter);
        assertEq(decodedWeight, weight);
        assertEq(decodedSupport, support);
    }

    function testFuzz_Generic_RoundTrip(bytes32 customSchemaId, bytes memory innerData) public pure {
        bytes memory payload = CrossChainCodec.encodeGeneric(customSchemaId, innerData);

        (bytes32 decodedSchemaId, bytes memory decodedData) = CrossChainCodec.decodeGeneric(payload);

        assertEq(decodedSchemaId, customSchemaId);
        assertEq(keccak256(decodedData), keccak256(innerData));
    }

    function testFuzz_SchemaIdExtraction(bytes32 anySchemaId, bytes memory anyData) public pure {
        // Manually create payload with schema prefix
        bytes memory payload = abi.encode(anySchemaId, anyData);

        bytes32 extracted = CrossChainCodec.getSchemaId(payload);
        assertEq(extracted, anySchemaId);
    }

    // =============================================================
    // SCHEMA VERSION CONSISTENCY TESTS
    // =============================================================

    function test_SchemaIds_AreUnique() public pure {
        bytes32[] memory schemas = new bytes32[](17);
        schemas[0] = CrossChainCodec.SIGNATURES_COMPLETE_V1;
        schemas[1] = CrossChainCodec.WITNESS_CONFIRMED_V1;
        schemas[2] = CrossChainCodec.CONTENT_SEALED_V1;
        schemas[3] = CrossChainCodec.CONTENT_REVOKED_V1;
        schemas[4] = CrossChainCodec.CONTENT_REGISTERED_V1;
        schemas[5] = CrossChainCodec.ESCROW_FUNDED_V1;
        schemas[6] = CrossChainCodec.RELEASE_AUTHORIZED_V1;
        schemas[7] = CrossChainCodec.REFUND_AUTHORIZED_V1;
        schemas[8] = CrossChainCodec.CONDITION_MET_V1;
        schemas[9] = CrossChainCodec.DEADLINE_REACHED_V1;
        schemas[10] = CrossChainCodec.TIMELOCK_UNLOCKED_V1;
        schemas[11] = CrossChainCodec.PARTIES_REGISTERED_V1;
        schemas[12] = CrossChainCodec.PERMISSION_GRANTED_V1;
        schemas[13] = CrossChainCodec.VOTE_RECORDED_V1;
        schemas[14] = CrossChainCodec.QUORUM_REACHED_V1;
        schemas[15] = CrossChainCodec.RULING_ISSUED_V1;
        schemas[16] = CrossChainCodec.GENERIC_V1;

        // Check all unique
        for (uint256 i = 0; i < schemas.length; i++) {
            for (uint256 j = i + 1; j < schemas.length; j++) {
                assertTrue(schemas[i] != schemas[j], "Schema IDs must be unique");
            }
        }
    }

    function test_SchemaIds_AreNonZero() public pure {
        assertTrue(CrossChainCodec.SIGNATURES_COMPLETE_V1 != bytes32(0));
        assertTrue(CrossChainCodec.WITNESS_CONFIRMED_V1 != bytes32(0));
        assertTrue(CrossChainCodec.CONTENT_SEALED_V1 != bytes32(0));
        assertTrue(CrossChainCodec.CONTENT_REVOKED_V1 != bytes32(0));
        assertTrue(CrossChainCodec.ESCROW_FUNDED_V1 != bytes32(0));
        assertTrue(CrossChainCodec.GENERIC_V1 != bytes32(0));
    }
}

/// @title CrossChainCodec Invariant Tests
/// @notice Invariant tests for codec encode/decode symmetry
contract CrossChainCodecInvariantTest is Test {
    CodecHandler public handler;

    function setUp() public {
        handler = new CodecHandler();
        targetContract(address(handler));
    }

    /// @notice Invariant: All encoded messages can be decoded
    function invariant_AllMessagesDecodable() public view {
        CrossChainCodecInvariantTest.EncodedMessage[] memory messages = handler.getEncodedMessages();

        for (uint256 i = 0; i < messages.length; i++) {
            bytes memory payload = messages[i].payload;
            bytes32 schemaId = CrossChainCodec.getSchemaId(payload);

            // Verify schema matches expected
            assertEq(schemaId, messages[i].expectedSchemaId);

            // Verify isSchema returns true
            assertTrue(CrossChainCodec.isSchema(payload, messages[i].expectedSchemaId));
        }
    }

    /// @notice Invariant: Schema IDs are deterministic
    function invariant_SchemaIdsDeterministic() public pure {
        // These should always be the same
        assertEq(CrossChainCodec.SIGNATURES_COMPLETE_V1, keccak256("papre.SignaturesComplete.v1"));
        assertEq(CrossChainCodec.CONTENT_SEALED_V1, keccak256("papre.ContentSealed.v1"));
        assertEq(CrossChainCodec.ESCROW_FUNDED_V1, keccak256("papre.EscrowFunded.v1"));
    }

    struct EncodedMessage {
        bytes payload;
        bytes32 expectedSchemaId;
    }
}

/// @title Handler for invariant testing
contract CodecHandler is Test {
    CrossChainCodecInvariantTest.EncodedMessage[] public encodedMessages;

    function encodeSignaturesComplete(bytes32 contentHash, uint8 signerCount) public {
        if (signerCount > 10) return;

        address[] memory signers = new address[](signerCount);
        for (uint256 i = 0; i < signerCount; i++) {
            signers[i] = address(uint160(i + 1));
        }

        bytes memory payload = CrossChainCodec.encodeSignaturesComplete(contentHash, signers);

        encodedMessages.push(
            CrossChainCodecInvariantTest.EncodedMessage({
                payload: payload, expectedSchemaId: CrossChainCodec.SIGNATURES_COMPLETE_V1
            })
        );
    }

    function encodeContentSealed(bytes32 contentHash, address registrant) public {
        bytes memory payload = CrossChainCodec.encodeContentSealed(contentHash, "ipfs://test", registrant);

        encodedMessages.push(
            CrossChainCodecInvariantTest.EncodedMessage({
                payload: payload, expectedSchemaId: CrossChainCodec.CONTENT_SEALED_V1
            })
        );
    }

    function encodeEscrowFunded(uint256 amount, address token, address depositor) public {
        bytes memory payload = CrossChainCodec.encodeEscrowFunded(amount, token, depositor);

        encodedMessages.push(
            CrossChainCodecInvariantTest.EncodedMessage({
                payload: payload, expectedSchemaId: CrossChainCodec.ESCROW_FUNDED_V1
            })
        );
    }

    function encodeConditionMet(bytes32 conditionId, bytes32 value) public {
        bytes memory payload = CrossChainCodec.encodeConditionMet(conditionId, value);

        encodedMessages.push(
            CrossChainCodecInvariantTest.EncodedMessage({
                payload: payload, expectedSchemaId: CrossChainCodec.CONDITION_MET_V1
            })
        );
    }

    function getEncodedMessages() external view returns (CrossChainCodecInvariantTest.EncodedMessage[] memory) {
        return encodedMessages;
    }
}
