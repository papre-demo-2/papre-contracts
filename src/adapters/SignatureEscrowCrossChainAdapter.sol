// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureClauseLogicV3} from "../clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";
import {CrossChainClauseLogicV3} from "../clauses/crosschain/CrossChainClauseLogicV3.sol";
import {CrossChainControllerV3} from "../controllers/CrossChainControllerV3.sol";

/// @title SignatureEscrowCrossChainAdapter
/// @notice Bridges signature completion on one chain to escrow release on another chain
/// @dev This adapter orchestrates the cross-chain flow:
///
///      Chain A (Source - Signature Chain)           Chain B (Destination - Escrow Chain)
///      ┌────────────────────────────────────┐      ┌────────────────────────────────────┐
///      │  Agreement Proxy                   │      │  Agreement Proxy                   │
///      │  ┌──────────────────────────────┐  │      │  ┌──────────────────────────────┐  │
///      │  │ SignatureClauseLogicV3       │  │      │  │ EscrowClauseLogicV3          │  │
///      │  │ (COMPLETE state) ────────┐   │  │      │  │          │                   │  │
///      │  └──────────────────────────│───┘  │      │  └──────────│───────────────────┘  │
///      │                             │      │      │             │                      │
///      │  ┌──────────────────────────│───┐  │      │  ┌──────────│───────────────────┐  │
///      │  │ This Adapter             ▼   │  │      │  │ This Adapter                 │  │
///      │  │ sendReleaseOnSignature() ────│──│──────│──│─► handleIncomingRelease()   │  │
///      │  └──────────────────────────────┘  │      │  └──────────────────────────────┘  │
///      └────────────────────────────────────┘      └────────────────────────────────────┘
///                        │                                          ▲
///                        │                                          │
///                        ▼                                          │
///               CrossChainControllerV3  ───── CCIP ─────  CrossChainControllerV3
///
///      Usage:
///      1. Deploy SignatureClauseLogicV3 on Chain A, EscrowClauseLogicV3 on Chain B
///      2. Configure both chains with CrossChainControllerV3
///      3. On Chain A: After all signatures collected, call sendReleaseOnSignature()
///      4. CCIP delivers message to Chain B
///      5. On Chain B: Agreement receives message and calls handleIncomingRelease()
///      6. Escrow is automatically released to beneficiary
contract SignatureEscrowCrossChainAdapter {
    // =============================================================
    // CONSTANTS
    // =============================================================

    /// @notice Action type for releasing escrow (matches CrossChainClauseLogicV3.ACTION_RELEASE_ESCROW)
    uint8 public constant ACTION_RELEASE_ESCROW = 2;

    // =============================================================
    // IMMUTABLES
    // =============================================================

    /// @notice Address of the SignatureClauseLogicV3 implementation
    SignatureClauseLogicV3 public immutable signatureClause;

    /// @notice Address of the EscrowClauseLogicV3 implementation
    EscrowClauseLogicV3 public immutable escrowClause;

    /// @notice Address of the CrossChainClauseLogicV3 implementation
    CrossChainClauseLogicV3 public immutable crossChainClause;

    /// @notice Address of the CrossChainControllerV3 on this chain
    CrossChainControllerV3 public immutable controller;

    // =============================================================
    // ERRORS
    // =============================================================

    error SignatureNotComplete(bytes32 instanceId, uint16 status);
    error SendFailed(bytes reason);
    error ReleaseFailed(bytes reason);
    error NotController(address caller, address expected);
    error InvalidAction(uint8 action, uint8 expected);

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a cross-chain release is initiated after signature completion
    event CrossChainReleaseInitiated(
        bytes32 indexed signatureInstanceId,
        bytes32 indexed escrowInstanceId,
        bytes32 messageId,
        uint64 destinationChainSelector
    );

    /// @notice Emitted when an incoming cross-chain release is processed
    event CrossChainReleaseExecuted(
        bytes32 indexed escrowInstanceId, uint64 sourceChainSelector, address sourceAgreement
    );

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /// @notice Create a new SignatureEscrowCrossChainAdapter
    /// @param _signatureClause Address of SignatureClauseLogicV3 implementation
    /// @param _escrowClause Address of EscrowClauseLogicV3 implementation
    /// @param _crossChainClause Address of CrossChainClauseLogicV3 implementation
    /// @param _controller Address of CrossChainControllerV3 on this chain
    constructor(address _signatureClause, address _escrowClause, address _crossChainClause, address _controller) {
        signatureClause = SignatureClauseLogicV3(_signatureClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        crossChainClause = CrossChainClauseLogicV3(_crossChainClause);
        controller = CrossChainControllerV3(payable(_controller));
    }

    // =============================================================
    // SOURCE CHAIN FUNCTIONS (called via delegatecall from Agreement)
    // =============================================================

    /// @notice Check if signature is complete and send cross-chain release message
    /// @param signatureInstanceId The signature instance ID on this chain
    /// @param crossChainInstanceId The cross-chain clause instance ID (tracks message state)
    /// @param escrowInstanceId The escrow instance ID on the destination chain
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      The Agreement MUST be authorized by the controller to send messages.
    ///      msg.value must cover CCIP fees.
    function sendReleaseOnSignature(
        bytes32 signatureInstanceId,
        bytes32 crossChainInstanceId,
        bytes32 escrowInstanceId,
        uint64 destinationChainSelector,
        address destinationAgreement
    ) external payable {
        // Step 1: Verify signature is complete
        (bool success, bytes memory data) = address(signatureClause).delegatecall(
            abi.encodeCall(SignatureClauseLogicV3.queryStatus, (signatureInstanceId))
        );
        require(success, "Query status failed");
        uint16 status = abi.decode(data, (uint16));

        // COMPLETE = 0x0004 from ClauseBase
        if (status != 0x0004) {
            revert SignatureNotComplete(signatureInstanceId, status);
        }

        // Step 2: Get the document hash from signature clause
        (success, data) = address(signatureClause).delegatecall(
            abi.encodeCall(SignatureClauseLogicV3.handoffDocumentHash, (signatureInstanceId))
        );
        require(success, "Handoff document hash failed");
        bytes32 documentHash = abi.decode(data, (bytes32));

        // Step 3: Configure cross-chain clause state (for tracking)
        _configureCrossChainState(
            crossChainInstanceId, destinationChainSelector, destinationAgreement, documentHash, escrowInstanceId
        );

        // Step 4: Send cross-chain message via controller
        // Note: In delegatecall context, address(this) is the Agreement
        bytes32 messageId = controller.sendMessage{value: msg.value}(
            destinationChainSelector,
            destinationAgreement,
            documentHash,
            ACTION_RELEASE_ESCROW,
            abi.encode(escrowInstanceId)
        );

        // Step 5: Mark as sent in cross-chain clause
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.actionMarkSent, (crossChainInstanceId, messageId))
        );
        if (!success) revert SendFailed(data);

        emit CrossChainReleaseInitiated(signatureInstanceId, escrowInstanceId, messageId, destinationChainSelector);
    }

    /// @notice Send cross-chain release without checking signature (for manual triggers)
    /// @param crossChainInstanceId The cross-chain clause instance ID
    /// @param escrowInstanceId The escrow instance ID on the destination chain
    /// @param documentHash The document hash being referenced
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Use this when you want to trigger release without signature check.
    function sendRelease(
        bytes32 crossChainInstanceId,
        bytes32 escrowInstanceId,
        bytes32 documentHash,
        uint64 destinationChainSelector,
        address destinationAgreement
    ) external payable {
        // Configure cross-chain clause state
        _configureCrossChainState(
            crossChainInstanceId, destinationChainSelector, destinationAgreement, documentHash, escrowInstanceId
        );

        // Send cross-chain message via controller
        bytes32 messageId = controller.sendMessage{value: msg.value}(
            destinationChainSelector,
            destinationAgreement,
            documentHash,
            ACTION_RELEASE_ESCROW,
            abi.encode(escrowInstanceId)
        );

        // Mark as sent
        (bool success, bytes memory data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.actionMarkSent, (crossChainInstanceId, messageId))
        );
        if (!success) revert SendFailed(data);

        emit CrossChainReleaseInitiated(
            bytes32(0), // No signature instance
            escrowInstanceId,
            messageId,
            destinationChainSelector
        );
    }

    // =============================================================
    // DESTINATION CHAIN FUNCTIONS (called via delegatecall from Agreement)
    // =============================================================

    /// @notice Handle incoming cross-chain release message
    /// @param crossChainInstanceId Instance ID for tracking the incoming message
    /// @param sourceChainSelector The source chain's CCIP selector
    /// @param sourceAgreement The source agreement address
    /// @param contentHash The content hash from the source
    /// @param action The action being triggered (should be ACTION_RELEASE_ESCROW)
    /// @param extraData Contains the escrow instance ID to release
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Typically called by Agreement's receiveCrossChainMessage() function.
    function handleIncomingRelease(
        bytes32 crossChainInstanceId,
        uint64 sourceChainSelector,
        address sourceAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData
    ) external {
        // Verify action type
        if (action != ACTION_RELEASE_ESCROW) {
            revert InvalidAction(action, ACTION_RELEASE_ESCROW);
        }

        // Decode escrow instance ID from extra data
        bytes32 escrowInstanceId = abi.decode(extraData, (bytes32));

        // Record incoming message in cross-chain clause
        (bool success, bytes memory data) = address(crossChainClause).delegatecall(
            abi.encodeCall(
                CrossChainClauseLogicV3.actionProcessIncoming,
                (crossChainInstanceId, sourceChainSelector, sourceAgreement, action, contentHash, extraData)
            )
        );
        require(success, "Process incoming failed");

        // Release the escrow
        (success, data) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionRelease, (escrowInstanceId)));
        if (!success) revert ReleaseFailed(data);

        emit CrossChainReleaseExecuted(escrowInstanceId, sourceChainSelector, sourceAgreement);
    }

    // =============================================================
    // INTERNAL FUNCTIONS
    // =============================================================

    /// @notice Configure cross-chain clause state before sending
    function _configureCrossChainState(
        bytes32 crossChainInstanceId,
        uint64 destinationChainSelector,
        address destinationAgreement,
        bytes32 contentHash,
        bytes32 escrowInstanceId
    ) internal {
        bool success;
        bytes memory data;

        // Set destination chain
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(
                CrossChainClauseLogicV3.intakeDestinationChain, (crossChainInstanceId, destinationChainSelector)
            )
        );
        require(success, "Set destination chain failed");

        // Set remote agreement
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.intakeRemoteAgreement, (crossChainInstanceId, destinationAgreement))
        );
        require(success, "Set remote agreement failed");

        // Set action
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.intakeAction, (crossChainInstanceId, ACTION_RELEASE_ESCROW))
        );
        require(success, "Set action failed");

        // Set content hash
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.intakeContentHash, (crossChainInstanceId, contentHash))
        );
        require(success, "Set content hash failed");

        // Set extra data (escrow instance ID)
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(
                CrossChainClauseLogicV3.intakeExtraData, (crossChainInstanceId, abi.encode(escrowInstanceId))
            )
        );
        require(success, "Set extra data failed");

        // Set controller
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.intakeController, (crossChainInstanceId, address(controller)))
        );
        require(success, "Set controller failed");

        // Finalize configuration
        (success, data) = address(crossChainClause).delegatecall(
            abi.encodeCall(CrossChainClauseLogicV3.intakeReady, (crossChainInstanceId))
        );
        require(success, "Finalize config failed");
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================

    /// @notice Get the fee required to send a cross-chain release message
    /// @param escrowInstanceId The escrow instance ID on the destination chain
    /// @param destinationChainSelector The destination chain's CCIP selector
    /// @param destinationAgreement The agreement address on the destination chain
    /// @return fee The fee in native token
    function getFee(bytes32 escrowInstanceId, uint64 destinationChainSelector, address destinationAgreement)
        external
        view
        returns (uint256 fee)
    {
        return controller.getFee(
            destinationChainSelector,
            destinationAgreement,
            bytes32(0), // contentHash - not known until send
            ACTION_RELEASE_ESCROW,
            abi.encode(escrowInstanceId)
        );
    }
}
