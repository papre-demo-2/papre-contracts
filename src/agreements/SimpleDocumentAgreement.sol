// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../clauses/content/DeclarativeClauseLogicV3.sol";

/**
 * @title SimpleDocumentAgreement
 * @author Papre Protocol
 * @notice Multi-party document signing agreement with N variable signers
 * @dev Uses V3 pattern: delegatecall to clause logic contracts with ERC-7201 storage.
 *
 * Flow:
 * 1. Creator uploads documents to IPFS, creates bundler JSON, uploads bundler
 * 2. Creator calls createInstance(signers, bundlerCid) with bundler CID
 * 3. Each signer calls sign(instanceId, signature) to sign
 * 4. When all sign, agreement is complete
 *
 * Pending Signers:
 * - Pass address(0) for signers who will claim their slot later
 * - Backend issues attestation after verifying email ownership
 * - Claimer calls claimSignerSlot() with attestation to fill the slot
 */
contract SimpleDocumentAgreement {
    // =============================================================
    // ERRORS
    // =============================================================

    error InvalidBundlerCid();
    error NoSignersProvided();
    error InstanceDoesNotExist();
    error NotASigner();
    error AlreadySigned();
    error DelegatecallFailed(string reason);

    // =============================================================
    // EVENTS
    // =============================================================

    event InstanceCreated(uint256 indexed instanceId, address indexed creator, string bundlerCid, address[] signers);

    event Signed(uint256 indexed instanceId, address indexed signer, uint256 timestamp);

    event Completed(uint256 indexed instanceId);

    event SignerSlotClaimed(uint256 indexed instanceId, uint256 indexed slotIndex, address indexed claimer);

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

    /// @custom:storage-location erc7201:papre.agreement.simpledocument.storage
    struct SimpleDocumentStorage {
        /// @notice Instance counter (starts at 1)
        uint256 instanceCount;
        /// @notice instanceId => creator address
        mapping(uint256 => address) creators;
        /// @notice instanceId => bundler CID string (IPFS)
        mapping(uint256 => string) bundlerCids;
        /// @notice instanceId => bundler hash (keccak256 of CID for on-chain refs)
        mapping(uint256 => bytes32) bundlerHashes;
        /// @notice instanceId => signers array (cached for quick access)
        mapping(uint256 => address[]) signers;
        /// @notice instanceId => creation timestamp
        mapping(uint256 => uint256) createdAt;
        /// @notice instanceId => clause instance ID for DeclarativeClause
        mapping(uint256 => bytes32) declarativeInstanceIds;
        /// @notice instanceId => clause instance ID for SignatureClause
        mapping(uint256 => bytes32) signatureInstanceIds;
    }

    // keccak256(abi.encode(uint256(keccak256("papre.agreement.simpledocument.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x8a35acfbc15ff81a39ae7d344fd709f28e8600b4aa8c65c6b64bfe7fe36bd100;

    function _getStorage() internal pure returns (SimpleDocumentStorage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /**
     * @notice Deploy SimpleDocumentAgreement
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
     * @notice Create a new document signing instance
     * @param signers Array of signer addresses (address(0) for pending slots)
     * @param bundlerCid IPFS CID of the bundler JSON
     * @return instanceId The new instance ID
     */
    function createInstance(address[] calldata signers, string calldata bundlerCid)
        external
        returns (uint256 instanceId)
    {
        if (bytes(bundlerCid).length == 0) revert InvalidBundlerCid();
        if (signers.length == 0) revert NoSignersProvided();

        SimpleDocumentStorage storage $ = _getStorage();

        // Increment and get new instance ID
        instanceId = ++$.instanceCount;

        // Store instance data
        $.creators[instanceId] = msg.sender;
        $.bundlerCids[instanceId] = bundlerCid;
        $.bundlerHashes[instanceId] = keccak256(bytes(bundlerCid));
        $.signers[instanceId] = signers;
        $.createdAt[instanceId] = block.timestamp;

        // Generate unique clause instance IDs
        bytes32 declarativeId = keccak256(abi.encode(address(this), instanceId, "declarative"));
        bytes32 signatureId = keccak256(abi.encode(address(this), instanceId, "signature"));

        $.declarativeInstanceIds[instanceId] = declarativeId;
        $.signatureInstanceIds[instanceId] = signatureId;

        // 1. Register bundler with DeclarativeClause
        _delegateToDeclarative(
            abi.encodeCall(
                DeclarativeClauseLogicV3.intakeContent, (declarativeId, $.bundlerHashes[instanceId], bundlerCid)
            )
        );

        // 2. Initialize SignatureClause with signers
        _delegateToSignature(abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (signatureId, signers)));

        // 3. Set document hash to transition SignatureClause to PENDING
        _delegateToSignature(
            abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (signatureId, $.bundlerHashes[instanceId]))
        );

        emit InstanceCreated(instanceId, msg.sender, bundlerCid, signers);
    }

    /**
     * @notice Sign the document
     * @param instanceId The instance to sign
     * @param signature The cryptographic signature (EIP-191 or EIP-712)
     */
    function sign(uint256 instanceId, bytes calldata signature) external {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();

        bytes32 signatureId = $.signatureInstanceIds[instanceId];

        // Check if caller is a signer
        bool isSigner = false;
        address[] storage signerList = $.signers[instanceId];
        for (uint256 i = 0; i < signerList.length; i++) {
            if (signerList[i] == msg.sender) {
                isSigner = true;
                break;
            }
        }
        if (!isSigner) revert NotASigner();

        // Check if already signed (query the signature clause)
        bytes memory hasSignedResult =
            _delegateToSignatureView(abi.encodeCall(SignatureClauseLogicV3.queryHasSigned, (signatureId, msg.sender)));
        bool alreadySigned = abi.decode(hasSignedResult, (bool));
        if (alreadySigned) revert AlreadySigned();

        // Submit signature to SignatureClause
        _delegateToSignature(abi.encodeCall(SignatureClauseLogicV3.actionSign, (signatureId, signature)));

        emit Signed(instanceId, msg.sender, block.timestamp);

        // Check if complete
        bytes memory statusResult =
            _delegateToSignatureView(abi.encodeCall(SignatureClauseLogicV3.queryStatus, (signatureId)));
        uint16 status = abi.decode(statusResult, (uint16));

        // COMPLETE = 1 << 2 = 4
        if (status == 4) {
            emit Completed(instanceId);
        }
    }

    /**
     * @notice Claim a pending signer slot
     * @param instanceId The instance
     * @param slotIndex Index in the signers array to claim
     * @param attestation Backend-signed attestation proving email ownership
     */
    function claimSignerSlot(uint256 instanceId, uint256 slotIndex, bytes calldata attestation) external {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();

        bytes32 signatureId = $.signatureInstanceIds[instanceId];

        // Delegate to SignatureClause's claim function
        _delegateToSignature(
            abi.encodeCall(
                SignatureClauseLogicV3.actionClaimSignerSlot, (signatureId, slotIndex, msg.sender, attestation)
            )
        );

        // Update our cached signers array
        $.signers[instanceId][slotIndex] = msg.sender;

        emit SignerSlotClaimed(instanceId, slotIndex, msg.sender);
    }

    /**
     * @notice Set trusted attestor for signer slot claims
     * @param attestor Address of the trusted attestor (backend wallet)
     * @param trusted Whether to trust or revoke trust
     */
    function setTrustedAttestor(address attestor, bool trusted) external {
        // For now, anyone can set attestors. In production, add access control.
        _delegateToSignature(abi.encodeCall(SignatureClauseLogicV3.setTrustedAttestor, (attestor, trusted)));
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================

    /**
     * @notice Get instance status
     * @param instanceId The instance to query
     * @return creator Address that created the instance
     * @return signerList Array of signer addresses
     * @return bundlerCid The IPFS CID of the bundler
     * @return signedCount Number of signatures collected
     * @return isComplete Whether all signatures are collected
     * @dev Uses delegatecall for queries to read storage written via delegatecall
     */
    function getStatus(uint256 instanceId)
        external
        returns (
            address creator,
            address[] memory signerList,
            string memory bundlerCid,
            uint256 signedCount,
            bool isComplete
        )
    {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();

        creator = $.creators[instanceId];
        signerList = $.signers[instanceId];
        bundlerCid = $.bundlerCids[instanceId];

        // Count signatures by checking each signer
        bytes32 signatureId = $.signatureInstanceIds[instanceId];
        signedCount = 0;

        for (uint256 i = 0; i < signerList.length; i++) {
            address signer = signerList[i];
            // Skip pending slots
            if (signer == address(0)) continue;

            // Use delegatecall to query signature status (reads our storage)
            bytes memory result =
                _delegateToSignatureView(abi.encodeCall(SignatureClauseLogicV3.queryHasSigned, (signatureId, signer)));

            if (abi.decode(result, (bool))) {
                signedCount++;
            }
        }

        // Count non-pending signers
        uint256 requiredCount = 0;
        for (uint256 i = 0; i < signerList.length; i++) {
            if (signerList[i] != address(0)) {
                requiredCount++;
            }
        }

        isComplete = signedCount == requiredCount && requiredCount > 0;
    }

    /**
     * @notice Check if an address has signed
     * @param instanceId The instance to query
     * @param signer Address to check
     * @return True if the address has signed
     * @dev Uses delegatecall for queries to read storage written via delegatecall
     */
    function hasSigned(uint256 instanceId, address signer) external returns (bool) {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();

        bytes32 signatureId = $.signatureInstanceIds[instanceId];

        bytes memory result =
            _delegateToSignatureView(abi.encodeCall(SignatureClauseLogicV3.queryHasSigned, (signatureId, signer)));

        return abi.decode(result, (bool));
    }

    /**
     * @notice Get the timestamp when a signer signed
     * @param instanceId The instance to query
     * @param signer Address to check
     * @return Unix timestamp when the signer signed (0 if not signed)
     * @dev Uses delegatecall for queries to read storage written via delegatecall
     */
    function getSignatureTimestamp(uint256 instanceId, address signer) external returns (uint256) {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();

        bytes32 signatureId = $.signatureInstanceIds[instanceId];

        bytes memory result =
            _delegateToSignatureView(abi.encodeCall(SignatureClauseLogicV3.querySignatureTime, (signatureId, signer)));

        return abi.decode(result, (uint256));
    }

    /**
     * @notice Get the bundler CID for an instance
     * @param instanceId The instance to query
     * @return The IPFS CID string
     */
    function getBundlerCid(uint256 instanceId) external view returns (string memory) {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();
        return $.bundlerCids[instanceId];
    }

    /**
     * @notice Get the signers array for an instance
     * @param instanceId The instance to query
     * @return Array of signer addresses
     */
    function getSigners(uint256 instanceId) external view returns (address[] memory) {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();
        return $.signers[instanceId];
    }

    /**
     * @notice Get the creator of an instance
     * @param instanceId The instance to query
     * @return Creator address
     */
    function getCreator(uint256 instanceId) external view returns (address) {
        SimpleDocumentStorage storage $ = _getStorage();
        if ($.creators[instanceId] == address(0)) revert InstanceDoesNotExist();
        return $.creators[instanceId];
    }

    /**
     * @notice Get total instance count
     * @return Number of instances created
     */
    function instanceCount() external view returns (uint256) {
        return _getStorage().instanceCount;
    }

    /**
     * @notice Check if an attestor is trusted
     * @param attestor Address to check
     * @return True if the attestor is trusted
     * @dev Uses delegatecall for queries to read storage written via delegatecall
     */
    function isTrustedAttestor(address attestor) external returns (bool) {
        bytes memory result =
            _delegateToSignatureView(abi.encodeCall(SignatureClauseLogicV3.queryIsTrustedAttestor, (attestor)));

        return abi.decode(result, (bool));
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

    /**
     * @dev Execute delegatecall for view function on SignatureClauseLogicV3
     * @notice Uses delegatecall for view to access storage written via delegatecall
     */
    function _delegateToSignatureView(bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory result) = SIGNATURE_LOGIC.delegatecall(data);
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert DelegatecallFailed("SignatureView");
        }
        return result;
    }
}
