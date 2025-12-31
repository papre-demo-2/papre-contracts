// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title CrossChainCodec
/// @notice Library for encoding/decoding typed cross-chain messages between Papre clauses
/// @dev All messages are prefixed with a schema ID for versioning and validation.
///      Schema IDs are keccak256 hashes of schema names, enabling explicit versioning.
///
///      Message Format:
///      [schemaId: bytes32][encodedData: bytes...]
///
///      Usage:
///      - Sender: bytes memory payload = CrossChainCodec.encodeSignaturesComplete(hash, signers);
///      - Receiver: (hash, signers) = CrossChainCodec.decodeSignaturesComplete(payload);
library CrossChainCodec {

    // =============================================================
    // ERRORS
    // =============================================================

    error SchemaMismatch(bytes32 expected, bytes32 actual);
    error InvalidPayload();

    // =============================================================
    // SCHEMA IDs (versioned)
    // =============================================================

    // Attestation Events
    bytes32 public constant SIGNATURES_COMPLETE_V1 = keccak256("papre.SignaturesComplete.v1");
    bytes32 public constant WITNESS_CONFIRMED_V1 = keccak256("papre.WitnessConfirmed.v1");

    // Content Events
    bytes32 public constant CONTENT_SEALED_V1 = keccak256("papre.ContentSealed.v1");
    bytes32 public constant CONTENT_REVOKED_V1 = keccak256("papre.ContentRevoked.v1");
    bytes32 public constant CONTENT_REGISTERED_V1 = keccak256("papre.ContentRegistered.v1");

    // Financial Events
    bytes32 public constant ESCROW_FUNDED_V1 = keccak256("papre.EscrowFunded.v1");
    bytes32 public constant RELEASE_AUTHORIZED_V1 = keccak256("papre.ReleaseAuthorized.v1");
    bytes32 public constant REFUND_AUTHORIZED_V1 = keccak256("papre.RefundAuthorized.v1");

    // State Events
    bytes32 public constant CONDITION_MET_V1 = keccak256("papre.ConditionMet.v1");
    bytes32 public constant DEADLINE_REACHED_V1 = keccak256("papre.DeadlineReached.v1");
    bytes32 public constant TIMELOCK_UNLOCKED_V1 = keccak256("papre.TimelockUnlocked.v1");

    // Access Events
    bytes32 public constant PARTIES_REGISTERED_V1 = keccak256("papre.PartiesRegistered.v1");
    bytes32 public constant PERMISSION_GRANTED_V1 = keccak256("papre.PermissionGranted.v1");

    // Governance Events
    bytes32 public constant VOTE_RECORDED_V1 = keccak256("papre.VoteRecorded.v1");
    bytes32 public constant QUORUM_REACHED_V1 = keccak256("papre.QuorumReached.v1");
    bytes32 public constant RULING_ISSUED_V1 = keccak256("papre.RulingIssued.v1");

    // Generic (escape hatch)
    bytes32 public constant GENERIC_V1 = keccak256("papre.Generic.v1");

    // =============================================================
    // INTROSPECTION
    // =============================================================

    /// @notice Extract the schema ID from an encoded payload
    /// @param payload The encoded payload
    /// @return schemaId The schema ID (first 32 bytes)
    function getSchemaId(bytes memory payload) internal pure returns (bytes32 schemaId) {
        if (payload.length < 32) revert InvalidPayload();
        assembly {
            schemaId := mload(add(payload, 32))
        }
    }

    /// @notice Check if a payload matches an expected schema
    /// @param payload The encoded payload
    /// @param expectedSchema The expected schema ID
    /// @return True if the schema matches
    function isSchema(bytes memory payload, bytes32 expectedSchema) internal pure returns (bool) {
        if (payload.length < 32) return false;
        return getSchemaId(payload) == expectedSchema;
    }

    // =============================================================
    // ATTESTATION EVENTS
    // =============================================================

    /// @notice Encode a "signatures complete" message
    /// @param contentHash The content/document hash that was signed
    /// @param signers Array of addresses that signed
    /// @return Encoded payload
    function encodeSignaturesComplete(
        bytes32 contentHash,
        address[] memory signers
    ) internal pure returns (bytes memory) {
        return abi.encode(SIGNATURES_COMPLETE_V1, contentHash, signers);
    }

    /// @notice Decode a "signatures complete" message
    /// @param payload The encoded payload
    /// @return contentHash The content/document hash
    /// @return signers Array of signer addresses
    function decodeSignaturesComplete(bytes memory payload)
        internal
        pure
        returns (bytes32 contentHash, address[] memory signers)
    {
        bytes32 schemaId;
        (schemaId, contentHash, signers) = abi.decode(payload, (bytes32, bytes32, address[]));
        if (schemaId != SIGNATURES_COMPLETE_V1) {
            revert SchemaMismatch(SIGNATURES_COMPLETE_V1, schemaId);
        }
    }

    /// @notice Encode a "witness confirmed" message
    /// @param contentHash The content hash being witnessed
    /// @param witness The witness address
    /// @return Encoded payload
    function encodeWitnessConfirmed(
        bytes32 contentHash,
        address witness
    ) internal pure returns (bytes memory) {
        return abi.encode(WITNESS_CONFIRMED_V1, contentHash, witness);
    }

    /// @notice Decode a "witness confirmed" message
    function decodeWitnessConfirmed(bytes memory payload)
        internal
        pure
        returns (bytes32 contentHash, address witness)
    {
        bytes32 schemaId;
        (schemaId, contentHash, witness) = abi.decode(payload, (bytes32, bytes32, address));
        if (schemaId != WITNESS_CONFIRMED_V1) {
            revert SchemaMismatch(WITNESS_CONFIRMED_V1, schemaId);
        }
    }

    // =============================================================
    // CONTENT EVENTS
    // =============================================================

    /// @notice Encode a "content sealed" message
    /// @param contentHash The content hash
    /// @param uri The content URI (ipfs://, ar://, https://)
    /// @param registrant Who registered the content
    /// @return Encoded payload
    function encodeContentSealed(
        bytes32 contentHash,
        string memory uri,
        address registrant
    ) internal pure returns (bytes memory) {
        return abi.encode(CONTENT_SEALED_V1, contentHash, uri, registrant);
    }

    /// @notice Decode a "content sealed" message
    function decodeContentSealed(bytes memory payload)
        internal
        pure
        returns (bytes32 contentHash, string memory uri, address registrant)
    {
        bytes32 schemaId;
        (schemaId, contentHash, uri, registrant) = abi.decode(
            payload, (bytes32, bytes32, string, address)
        );
        if (schemaId != CONTENT_SEALED_V1) {
            revert SchemaMismatch(CONTENT_SEALED_V1, schemaId);
        }
    }

    /// @notice Encode a "content revoked" message
    /// @param contentHash The content hash that was revoked
    /// @return Encoded payload
    function encodeContentRevoked(bytes32 contentHash) internal pure returns (bytes memory) {
        return abi.encode(CONTENT_REVOKED_V1, contentHash);
    }

    /// @notice Decode a "content revoked" message
    function decodeContentRevoked(bytes memory payload)
        internal
        pure
        returns (bytes32 contentHash)
    {
        bytes32 schemaId;
        (schemaId, contentHash) = abi.decode(payload, (bytes32, bytes32));
        if (schemaId != CONTENT_REVOKED_V1) {
            revert SchemaMismatch(CONTENT_REVOKED_V1, schemaId);
        }
    }

    /// @notice Encode a "content registered" message (not yet sealed)
    /// @param contentHash The content hash
    /// @param uri The content URI
    /// @param registrant Who registered the content
    /// @return Encoded payload
    function encodeContentRegistered(
        bytes32 contentHash,
        string memory uri,
        address registrant
    ) internal pure returns (bytes memory) {
        return abi.encode(CONTENT_REGISTERED_V1, contentHash, uri, registrant);
    }

    /// @notice Decode a "content registered" message
    function decodeContentRegistered(bytes memory payload)
        internal
        pure
        returns (bytes32 contentHash, string memory uri, address registrant)
    {
        bytes32 schemaId;
        (schemaId, contentHash, uri, registrant) = abi.decode(
            payload, (bytes32, bytes32, string, address)
        );
        if (schemaId != CONTENT_REGISTERED_V1) {
            revert SchemaMismatch(CONTENT_REGISTERED_V1, schemaId);
        }
    }

    // =============================================================
    // FINANCIAL EVENTS
    // =============================================================

    /// @notice Encode an "escrow funded" message
    /// @param amount The amount funded
    /// @param token The token address (address(0) for native)
    /// @param depositor Who funded the escrow
    /// @return Encoded payload
    function encodeEscrowFunded(
        uint256 amount,
        address token,
        address depositor
    ) internal pure returns (bytes memory) {
        return abi.encode(ESCROW_FUNDED_V1, amount, token, depositor);
    }

    /// @notice Decode an "escrow funded" message
    function decodeEscrowFunded(bytes memory payload)
        internal
        pure
        returns (uint256 amount, address token, address depositor)
    {
        bytes32 schemaId;
        (schemaId, amount, token, depositor) = abi.decode(
            payload, (bytes32, uint256, address, address)
        );
        if (schemaId != ESCROW_FUNDED_V1) {
            revert SchemaMismatch(ESCROW_FUNDED_V1, schemaId);
        }
    }

    /// @notice Encode a "release authorized" message
    /// @param amount The amount to release
    /// @param recipient Who should receive the funds
    /// @param contentHash Reference to what was signed/completed
    /// @return Encoded payload
    function encodeReleaseAuthorized(
        uint256 amount,
        address recipient,
        bytes32 contentHash
    ) internal pure returns (bytes memory) {
        return abi.encode(RELEASE_AUTHORIZED_V1, amount, recipient, contentHash);
    }

    /// @notice Decode a "release authorized" message
    function decodeReleaseAuthorized(bytes memory payload)
        internal
        pure
        returns (uint256 amount, address recipient, bytes32 contentHash)
    {
        bytes32 schemaId;
        (schemaId, amount, recipient, contentHash) = abi.decode(
            payload, (bytes32, uint256, address, bytes32)
        );
        if (schemaId != RELEASE_AUTHORIZED_V1) {
            revert SchemaMismatch(RELEASE_AUTHORIZED_V1, schemaId);
        }
    }

    /// @notice Encode a "refund authorized" message
    /// @param amount The amount to refund
    /// @param recipient Who should receive the refund
    /// @param reason Hash of reason for refund
    /// @return Encoded payload
    function encodeRefundAuthorized(
        uint256 amount,
        address recipient,
        bytes32 reason
    ) internal pure returns (bytes memory) {
        return abi.encode(REFUND_AUTHORIZED_V1, amount, recipient, reason);
    }

    /// @notice Decode a "refund authorized" message
    function decodeRefundAuthorized(bytes memory payload)
        internal
        pure
        returns (uint256 amount, address recipient, bytes32 reason)
    {
        bytes32 schemaId;
        (schemaId, amount, recipient, reason) = abi.decode(
            payload, (bytes32, uint256, address, bytes32)
        );
        if (schemaId != REFUND_AUTHORIZED_V1) {
            revert SchemaMismatch(REFUND_AUTHORIZED_V1, schemaId);
        }
    }

    // =============================================================
    // STATE EVENTS
    // =============================================================

    /// @notice Encode a "condition met" message
    /// @param conditionId Identifier for the condition
    /// @param value The value that triggered the condition (encoded as bytes32)
    /// @return Encoded payload
    function encodeConditionMet(
        bytes32 conditionId,
        bytes32 value
    ) internal pure returns (bytes memory) {
        return abi.encode(CONDITION_MET_V1, conditionId, value);
    }

    /// @notice Decode a "condition met" message
    function decodeConditionMet(bytes memory payload)
        internal
        pure
        returns (bytes32 conditionId, bytes32 value)
    {
        bytes32 schemaId;
        (schemaId, conditionId, value) = abi.decode(payload, (bytes32, bytes32, bytes32));
        if (schemaId != CONDITION_MET_V1) {
            revert SchemaMismatch(CONDITION_MET_V1, schemaId);
        }
    }

    /// @notice Encode a "deadline reached" message
    /// @param deadlineId Identifier for the deadline
    /// @param timestamp When the deadline was reached
    /// @return Encoded payload
    function encodeDeadlineReached(
        bytes32 deadlineId,
        uint256 timestamp
    ) internal pure returns (bytes memory) {
        return abi.encode(DEADLINE_REACHED_V1, deadlineId, timestamp);
    }

    /// @notice Decode a "deadline reached" message
    function decodeDeadlineReached(bytes memory payload)
        internal
        pure
        returns (bytes32 deadlineId, uint256 timestamp)
    {
        bytes32 schemaId;
        (schemaId, deadlineId, timestamp) = abi.decode(payload, (bytes32, bytes32, uint256));
        if (schemaId != DEADLINE_REACHED_V1) {
            revert SchemaMismatch(DEADLINE_REACHED_V1, schemaId);
        }
    }

    /// @notice Encode a "timelock unlocked" message
    /// @param lockId Identifier for the timelock
    /// @param unlockedAt When it was unlocked
    /// @return Encoded payload
    function encodeTimelockUnlocked(
        bytes32 lockId,
        uint256 unlockedAt
    ) internal pure returns (bytes memory) {
        return abi.encode(TIMELOCK_UNLOCKED_V1, lockId, unlockedAt);
    }

    /// @notice Decode a "timelock unlocked" message
    function decodeTimelockUnlocked(bytes memory payload)
        internal
        pure
        returns (bytes32 lockId, uint256 unlockedAt)
    {
        bytes32 schemaId;
        (schemaId, lockId, unlockedAt) = abi.decode(payload, (bytes32, bytes32, uint256));
        if (schemaId != TIMELOCK_UNLOCKED_V1) {
            revert SchemaMismatch(TIMELOCK_UNLOCKED_V1, schemaId);
        }
    }

    // =============================================================
    // ACCESS EVENTS
    // =============================================================

    /// @notice Encode a "parties registered" message
    /// @param role The role these parties have
    /// @param parties Array of party addresses
    /// @return Encoded payload
    function encodePartiesRegistered(
        bytes32 role,
        address[] memory parties
    ) internal pure returns (bytes memory) {
        return abi.encode(PARTIES_REGISTERED_V1, role, parties);
    }

    /// @notice Decode a "parties registered" message
    function decodePartiesRegistered(bytes memory payload)
        internal
        pure
        returns (bytes32 role, address[] memory parties)
    {
        bytes32 schemaId;
        (schemaId, role, parties) = abi.decode(payload, (bytes32, bytes32, address[]));
        if (schemaId != PARTIES_REGISTERED_V1) {
            revert SchemaMismatch(PARTIES_REGISTERED_V1, schemaId);
        }
    }

    /// @notice Encode a "permission granted" message
    /// @param grantee Who received the permission
    /// @param permission The permission identifier
    /// @param granter Who granted it
    /// @return Encoded payload
    function encodePermissionGranted(
        address grantee,
        bytes32 permission,
        address granter
    ) internal pure returns (bytes memory) {
        return abi.encode(PERMISSION_GRANTED_V1, grantee, permission, granter);
    }

    /// @notice Decode a "permission granted" message
    function decodePermissionGranted(bytes memory payload)
        internal
        pure
        returns (address grantee, bytes32 permission, address granter)
    {
        bytes32 schemaId;
        (schemaId, grantee, permission, granter) = abi.decode(
            payload, (bytes32, address, bytes32, address)
        );
        if (schemaId != PERMISSION_GRANTED_V1) {
            revert SchemaMismatch(PERMISSION_GRANTED_V1, schemaId);
        }
    }

    // =============================================================
    // GOVERNANCE EVENTS
    // =============================================================

    /// @notice Encode a "vote recorded" message
    /// @param proposalId The proposal being voted on
    /// @param voter Who voted
    /// @param weight The vote weight
    /// @param support True for yes, false for no
    /// @return Encoded payload
    function encodeVoteRecorded(
        bytes32 proposalId,
        address voter,
        uint256 weight,
        bool support
    ) internal pure returns (bytes memory) {
        return abi.encode(VOTE_RECORDED_V1, proposalId, voter, weight, support);
    }

    /// @notice Decode a "vote recorded" message
    function decodeVoteRecorded(bytes memory payload)
        internal
        pure
        returns (bytes32 proposalId, address voter, uint256 weight, bool support)
    {
        bytes32 schemaId;
        (schemaId, proposalId, voter, weight, support) = abi.decode(
            payload, (bytes32, bytes32, address, uint256, bool)
        );
        if (schemaId != VOTE_RECORDED_V1) {
            revert SchemaMismatch(VOTE_RECORDED_V1, schemaId);
        }
    }

    /// @notice Encode a "quorum reached" message
    /// @param proposalId The proposal that reached quorum
    /// @param totalWeight Total weight of votes
    /// @param threshold The quorum threshold
    /// @return Encoded payload
    function encodeQuorumReached(
        bytes32 proposalId,
        uint256 totalWeight,
        uint256 threshold
    ) internal pure returns (bytes memory) {
        return abi.encode(QUORUM_REACHED_V1, proposalId, totalWeight, threshold);
    }

    /// @notice Decode a "quorum reached" message
    function decodeQuorumReached(bytes memory payload)
        internal
        pure
        returns (bytes32 proposalId, uint256 totalWeight, uint256 threshold)
    {
        bytes32 schemaId;
        (schemaId, proposalId, totalWeight, threshold) = abi.decode(
            payload, (bytes32, bytes32, uint256, uint256)
        );
        if (schemaId != QUORUM_REACHED_V1) {
            revert SchemaMismatch(QUORUM_REACHED_V1, schemaId);
        }
    }

    /// @notice Encode a "ruling issued" message
    /// @param disputeId The dispute identifier
    /// @param ruling The ruling value (0=none, 1=party1, 2=party2, etc.)
    /// @param arbiter Who issued the ruling
    /// @return Encoded payload
    function encodeRulingIssued(
        bytes32 disputeId,
        uint8 ruling,
        address arbiter
    ) internal pure returns (bytes memory) {
        return abi.encode(RULING_ISSUED_V1, disputeId, ruling, arbiter);
    }

    /// @notice Decode a "ruling issued" message
    function decodeRulingIssued(bytes memory payload)
        internal
        pure
        returns (bytes32 disputeId, uint8 ruling, address arbiter)
    {
        bytes32 schemaId;
        (schemaId, disputeId, ruling, arbiter) = abi.decode(
            payload, (bytes32, bytes32, uint8, address)
        );
        if (schemaId != RULING_ISSUED_V1) {
            revert SchemaMismatch(RULING_ISSUED_V1, schemaId);
        }
    }

    // =============================================================
    // GENERIC (ESCAPE HATCH)
    // =============================================================

    /// @notice Encode a generic message with custom schema
    /// @param customSchemaId A custom schema identifier
    /// @param data The raw encoded data
    /// @return Encoded payload
    /// @dev Use this for custom message types not covered by standard schemas.
    ///      Receiver must know how to decode based on customSchemaId.
    function encodeGeneric(
        bytes32 customSchemaId,
        bytes memory data
    ) internal pure returns (bytes memory) {
        return abi.encode(GENERIC_V1, customSchemaId, data);
    }

    /// @notice Decode a generic message
    /// @param payload The encoded payload
    /// @return customSchemaId The custom schema identifier
    /// @return data The raw data (still encoded)
    function decodeGeneric(bytes memory payload)
        internal
        pure
        returns (bytes32 customSchemaId, bytes memory data)
    {
        bytes32 schemaId;
        (schemaId, customSchemaId, data) = abi.decode(payload, (bytes32, bytes32, bytes));
        if (schemaId != GENERIC_V1) {
            revert SchemaMismatch(GENERIC_V1, schemaId);
        }
    }
}
