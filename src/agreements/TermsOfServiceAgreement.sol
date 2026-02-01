// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../clauses/content/DeclarativeClauseLogicV3.sol";

/**
 * @title TermsOfServiceAgreement
 * @author Papre Protocol
 * @notice Dedicated contract for recording Terms of Service acceptance on-chain
 * @dev Optimized for single-signer ToS acceptance. Uses V3 clause pattern.
 *
 * This contract is purpose-built for ToS acceptance:
 * - Each acceptance creates a new instance
 * - Single signer per instance (the user accepting ToS)
 * - Bundler CID points to ToS document version
 * - Events specifically named for ToS tracking
 *
 * Flow:
 * 1. Platform creates ToS bundler on IPFS (done once per ToS version)
 * 2. User calls acceptToS(bundlerCid) to create and sign in one transaction
 * 3. ToSAccepted event emitted with all relevant data
 *
 * Alternative two-step flow (for compatibility with existing frontend):
 * 1. Frontend calls createInstance([userAddress], bundlerCid)
 * 2. Frontend calls sign(instanceId, signature)
 */
contract TermsOfServiceAgreement {
    // =============================================================
    // ERRORS
    // =============================================================

    error InvalidBundlerCid();
    error InstanceDoesNotExist();
    error NotTheSigner();
    error AlreadyAccepted();
    error DelegatecallFailed(string reason);

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a user accepts the Terms of Service
    event ToSAccepted(uint256 indexed instanceId, address indexed user, string bundlerCid, uint256 timestamp);

    /// @notice Emitted when a new ToS acceptance instance is created (two-step flow)
    event ToSInstanceCreated(uint256 indexed instanceId, address indexed user, string bundlerCid);

    /// @notice Emitted when signature is recorded (two-step flow)
    event ToSSigned(uint256 indexed instanceId, address indexed user, uint256 timestamp);

    // =============================================================
    // IMMUTABLES
    // =============================================================

    /// @notice DeclarativeClauseLogicV3 contract for content anchoring
    address public immutable DECLARATIVE_LOGIC;

    /// @notice SignatureClauseLogicV3 contract for signature collection
    address public immutable SIGNATURE_LOGIC;

    // =============================================================
    // ERC-7201 NAMESPACED STORAGE
    // =============================================================

    /// @custom:storage-location erc7201:papre.agreement.termsofservice.storage
    struct ToSStorage {
        /// @notice Instance counter (starts at 1)
        uint256 instanceCount;
        /// @notice instanceId => user address who accepted
        mapping(uint256 => address) users;
        /// @notice instanceId => bundler CID string (IPFS)
        mapping(uint256 => string) bundlerCids;
        /// @notice instanceId => bundler hash (keccak256 of CID)
        mapping(uint256 => bytes32) bundlerHashes;
        /// @notice instanceId => creation timestamp
        mapping(uint256 => uint256) createdAt;
        /// @notice instanceId => acceptance timestamp (0 if not yet accepted)
        mapping(uint256 => uint256) acceptedAt;
        /// @notice instanceId => clause instance ID for DeclarativeClause
        mapping(uint256 => bytes32) declarativeInstanceIds;
        /// @notice instanceId => clause instance ID for SignatureClause
        mapping(uint256 => bytes32) signatureInstanceIds;
        /// @notice user => bundlerCid hash => instanceId (for lookup)
        mapping(address => mapping(bytes32 => uint256)) userAcceptances;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.termsofservice.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x3d8b5c3c2a1e4f5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c00;

    function _getStorage() internal pure returns (ToSStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /**
     * @notice Deploy TermsOfServiceAgreement
     * @param declarativeLogic Address of DeclarativeClauseLogicV3
     * @param signatureLogic Address of SignatureClauseLogicV3
     */
    constructor(address declarativeLogic, address signatureLogic) {
        DECLARATIVE_LOGIC = declarativeLogic;
        SIGNATURE_LOGIC = signatureLogic;
    }

    // =============================================================
    // MAIN FUNCTIONS
    // =============================================================

    /**
     * @notice Create a ToS acceptance instance (two-step flow, step 1)
     * @param signers Array containing single user address
     * @param bundlerCid IPFS CID of the ToS bundler
     * @return instanceId The new instance ID
     * @dev Compatible with SimpleDocumentAgreement interface for frontend reuse
     */
    function createInstance(address[] calldata signers, string calldata bundlerCid)
        external
        returns (uint256 instanceId)
    {
        if (bytes(bundlerCid).length == 0) revert InvalidBundlerCid();
        // ToS acceptance is single-signer, take first address
        address user = signers.length > 0 ? signers[0] : msg.sender;

        ToSStorage storage $ = _getStorage();

        // Increment and get new instance ID
        instanceId = ++$.instanceCount;

        // Store instance data
        bytes32 bundlerHash = keccak256(bytes(bundlerCid));
        $.users[instanceId] = user;
        $.bundlerCids[instanceId] = bundlerCid;
        $.bundlerHashes[instanceId] = bundlerHash;
        $.createdAt[instanceId] = block.timestamp;

        // Generate unique clause instance IDs
        bytes32 declarativeId = keccak256(abi.encode(address(this), instanceId, "tos-declarative"));
        bytes32 signatureId = keccak256(abi.encode(address(this), instanceId, "tos-signature"));

        $.declarativeInstanceIds[instanceId] = declarativeId;
        $.signatureInstanceIds[instanceId] = signatureId;

        // 1. Register bundler with DeclarativeClause
        _delegateToDeclarative(
            abi.encodeCall(DeclarativeClauseLogicV3.intakeContent, (declarativeId, bundlerHash, bundlerCid))
        );

        // 2. Initialize SignatureClause with single signer
        address[] memory signerArray = new address[](1);
        signerArray[0] = user;
        _delegateToSignature(abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (signatureId, signerArray)));

        // 3. Set document hash to transition SignatureClause to PENDING
        _delegateToSignature(abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (signatureId, bundlerHash)));

        emit ToSInstanceCreated(instanceId, user, bundlerCid);
    }

    /**
     * @notice Sign the ToS (two-step flow, step 2)
     * @param instanceId The instance to sign
     * @param signature The cryptographic signature (EIP-191)
     */
    function sign(uint256 instanceId, bytes calldata signature) external {
        ToSStorage storage $ = _getStorage();
        if ($.users[instanceId] == address(0)) revert InstanceDoesNotExist();
        if ($.users[instanceId] != msg.sender) revert NotTheSigner();
        if ($.acceptedAt[instanceId] != 0) revert AlreadyAccepted();

        bytes32 signatureId = $.signatureInstanceIds[instanceId];

        // Submit signature to SignatureClause
        _delegateToSignature(abi.encodeCall(SignatureClauseLogicV3.actionSign, (signatureId, signature)));

        // Record acceptance
        $.acceptedAt[instanceId] = block.timestamp;

        // Track user's acceptance of this ToS version
        $.userAcceptances[msg.sender][$.bundlerHashes[instanceId]] = instanceId;

        emit ToSSigned(instanceId, msg.sender, block.timestamp);
        emit ToSAccepted(instanceId, msg.sender, $.bundlerCids[instanceId], block.timestamp);
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Check if a user has accepted a specific ToS version
     * @param user Address to check
     * @param bundlerCid The ToS bundler CID
     * @return True if the user has accepted this ToS version
     */
    function hasAccepted(address user, string calldata bundlerCid) external view returns (bool) {
        ToSStorage storage $ = _getStorage();
        bytes32 bundlerHash = keccak256(bytes(bundlerCid));
        uint256 instanceId = $.userAcceptances[user][bundlerHash];
        return instanceId != 0 && $.acceptedAt[instanceId] != 0;
    }

    /**
     * @notice Get acceptance instance ID for a user and ToS version
     * @param user Address to check
     * @param bundlerCid The ToS bundler CID
     * @return instanceId The instance ID (0 if not found)
     */
    function getAcceptanceInstance(address user, string calldata bundlerCid) external view returns (uint256) {
        ToSStorage storage $ = _getStorage();
        bytes32 bundlerHash = keccak256(bytes(bundlerCid));
        return $.userAcceptances[user][bundlerHash];
    }

    /**
     * @notice Get instance status
     * @param instanceId The instance to query
     * @return user Address that accepted
     * @return bundlerCid The IPFS CID of the ToS bundler
     * @return createdAt Timestamp when instance was created
     * @return acceptedAt Timestamp when ToS was accepted (0 if pending)
     * @return isAccepted Whether the ToS has been accepted
     */
    function getStatus(uint256 instanceId)
        external
        view
        returns (address user, string memory bundlerCid, uint256 createdAt, uint256 acceptedAt, bool isAccepted)
    {
        ToSStorage storage $ = _getStorage();
        if ($.users[instanceId] == address(0)) revert InstanceDoesNotExist();

        user = $.users[instanceId];
        bundlerCid = $.bundlerCids[instanceId];
        createdAt = $.createdAt[instanceId];
        acceptedAt = $.acceptedAt[instanceId];
        isAccepted = acceptedAt != 0;
    }

    /**
     * @notice Get the bundler CID for an instance
     * @param instanceId The instance to query
     * @return The IPFS CID string
     */
    function getBundlerCid(uint256 instanceId) external view returns (string memory) {
        ToSStorage storage $ = _getStorage();
        if ($.users[instanceId] == address(0)) revert InstanceDoesNotExist();
        return $.bundlerCids[instanceId];
    }

    /**
     * @notice Get the user for an instance
     * @param instanceId The instance to query
     * @return User address
     */
    function getUser(uint256 instanceId) external view returns (address) {
        ToSStorage storage $ = _getStorage();
        if ($.users[instanceId] == address(0)) revert InstanceDoesNotExist();
        return $.users[instanceId];
    }

    /**
     * @notice Get total instance count
     * @return Number of ToS acceptances
     */
    function instanceCount() external view returns (uint256) {
        return _getStorage().instanceCount;
    }

    /**
     * @notice Check if an instance has been signed (compatibility with SimpleDocumentAgreement)
     * @param instanceId The instance to query
     * @param signer Address to check
     * @return True if signed
     */
    function hasSigned(uint256 instanceId, address signer) external view returns (bool) {
        ToSStorage storage $ = _getStorage();
        if ($.users[instanceId] == address(0)) revert InstanceDoesNotExist();
        // Only the user can sign, and only once
        return $.users[instanceId] == signer && $.acceptedAt[instanceId] != 0;
    }

    /**
     * @notice Get signers for an instance (compatibility with SimpleDocumentAgreement)
     * @param instanceId The instance to query
     * @return Array with single signer
     */
    function getSigners(uint256 instanceId) external view returns (address[] memory) {
        ToSStorage storage $ = _getStorage();
        if ($.users[instanceId] == address(0)) revert InstanceDoesNotExist();
        address[] memory signers = new address[](1);
        signers[0] = $.users[instanceId];
        return signers;
    }

    // =============================================================
    // INTERNAL HELPERS
    // =============================================================

    /**
     * @dev Execute delegatecall to DeclarativeClauseLogicV3
     */
    function _delegateToDeclarative(bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory result) = DECLARATIVE_LOGIC.delegatecall(data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert DelegatecallFailed("Declarative");
        }
        return result;
    }

    /**
     * @dev Execute delegatecall to SignatureClauseLogicV3
     */
    function _delegateToSignature(bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory result) = SIGNATURE_LOGIC.delegatecall(data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert DelegatecallFailed("Signature");
        }
        return result;
    }
}
