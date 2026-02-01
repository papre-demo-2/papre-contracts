// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MilestoneClauseLogicV3} from "../clauses/orchestration/MilestoneClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";

/// @title MilestoneEscrowAdapter
/// @notice Adapter that bridges MilestoneClauseLogicV3 and EscrowClauseLogicV3
/// @dev This adapter provides atomic operations that orchestrate milestone confirmation
///      and escrow release in a single transaction. It is designed to be called via
///      delegatecall from Agreement contracts, preserving msg.sender as the original caller.
///
///      The adapter is the "authorized releaser" - when a client confirms a milestone
///      through this adapter, the corresponding escrow is automatically released.
///
///      Architecture:
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │                         AGREEMENT CONTRACT                               │
///      │  (holds storage for all clauses via ERC-7201 namespaced storage)        │
///      └─────────────────────────────────────────────────────────────────────────┘
///                                      │
///                             delegatecall to adapter
///                                      │
///                                      ▼
///      ┌─────────────────────────────────────────────────────────────────────────┐
///      │                      MilestoneEscrowAdapter                              │
///      │  confirmAndRelease() ──► MilestoneClause.actionConfirm()                │
///      │                     ──► EscrowClause.actionRelease()                    │
///      │                     ──► MilestoneClause.actionMarkReleased()            │
///      └─────────────────────────────────────────────────────────────────────────┘
///
///      Usage:
///      1. Frontend auto-includes this adapter when Milestone + Escrow are used
///      2. Client calls Agreement.confirmAndRelease() which delegatecalls here
///      3. One transaction: milestone confirmed + escrow released + state updated
///
///      For dispute flows, use disputeAndInitiateArbitration() to atomically
///      file a dispute and start the arbitration process.
contract MilestoneEscrowAdapter {
    // =============================================================
    // IMMUTABLES
    // =============================================================

    /// @notice Address of the MilestoneClauseLogicV3 implementation
    MilestoneClauseLogicV3 public immutable milestoneClause;

    /// @notice Address of the EscrowClauseLogicV3 implementation
    EscrowClauseLogicV3 public immutable escrowClause;

    // =============================================================
    // ERRORS
    // =============================================================

    error ConfirmFailed(bytes reason);
    error ReleaseFailed(bytes reason);
    error MarkReleasedFailed(bytes reason);
    error DisputeFailed(bytes reason);
    error RefundFailed(bytes reason);
    error MarkRefundedFailed(bytes reason);
    error ResolveDisputeFailed(bytes reason);

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a milestone is confirmed and escrow released atomically
    event MilestoneReleasedViaAdapter(
        bytes32 indexed milestoneInstanceId,
        uint256 indexed milestoneIndex,
        bytes32 escrowInstanceId,
        address indexed client
    );

    /// @notice Emitted when a dispute is filed for a milestone
    event MilestoneDisputedViaAdapter(
        bytes32 indexed milestoneInstanceId,
        uint256 indexed milestoneIndex,
        bytes32 reasonHash,
        address indexed disputer
    );

    /// @notice Emitted when a disputed milestone is resolved and funds moved
    event DisputeResolvedViaAdapter(
        bytes32 indexed milestoneInstanceId, uint256 indexed milestoneIndex, bool releasedToBeneficiary
    );

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /// @notice Create a new MilestoneEscrowAdapter
    /// @param _milestoneClause Address of MilestoneClauseLogicV3 implementation
    /// @param _escrowClause Address of EscrowClauseLogicV3 implementation
    constructor(address _milestoneClause, address _escrowClause) {
        milestoneClause = MilestoneClauseLogicV3(_milestoneClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
    }

    // =============================================================
    // ADAPTER FUNCTIONS (called via delegatecall from Agreement)
    // =============================================================

    /// @notice Confirm a milestone and automatically release the linked escrow
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone to confirm
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      msg.sender must be the client for the milestone instance.
    ///      Atomically: confirms milestone → releases escrow → marks released
    function confirmAndRelease(bytes32 milestoneInstanceId, uint256 milestoneIndex) external {
        // Step 1: Confirm the milestone (validates msg.sender is client)
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.actionConfirm, (milestoneInstanceId, milestoneIndex))
        );
        if (!success) revert ConfirmFailed(data);

        // Step 2: Get the linked escrow instance ID
        // Use delegatecall to read from Agreement's storage using clause's code
        (success, data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneEscrowId, (milestoneInstanceId, milestoneIndex))
        );
        require(success, "Query escrow ID failed");
        bytes32 escrowInstanceId = abi.decode(data, (bytes32));

        // Step 3: Release the escrow
        (success, data) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionRelease, (escrowInstanceId)));
        if (!success) revert ReleaseFailed(data);

        // Step 4: Mark the milestone as released
        (success, data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.actionMarkReleased, (milestoneInstanceId, milestoneIndex))
        );
        if (!success) revert MarkReleasedFailed(data);

        emit MilestoneReleasedViaAdapter(milestoneInstanceId, milestoneIndex, escrowInstanceId, msg.sender);
    }

    /// @notice File a dispute for a milestone
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone to dispute
    /// @param reasonHash Hash of the dispute reason (off-chain content)
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Either party (client or beneficiary) can file a dispute.
    function dispute(bytes32 milestoneInstanceId, uint256 milestoneIndex, bytes32 reasonHash) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.actionDispute, (milestoneInstanceId, milestoneIndex, reasonHash))
        );
        if (!success) revert DisputeFailed(data);

        emit MilestoneDisputedViaAdapter(milestoneInstanceId, milestoneIndex, reasonHash, msg.sender);
    }

    /// @notice Resolve a disputed milestone and execute the appropriate escrow action
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the disputed milestone
    /// @param releaseToBeneficiary True to release to beneficiary, false to refund
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Typically called after arbitration ruling is received.
    ///      Atomically: resolves dispute → releases or refunds escrow → updates milestone
    function resolveDisputeAndExecute(bytes32 milestoneInstanceId, uint256 milestoneIndex, bool releaseToBeneficiary)
        external
    {
        // Step 1: Resolve the dispute in MilestoneClause
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(
                MilestoneClauseLogicV3.actionResolveDispute, (milestoneInstanceId, milestoneIndex, releaseToBeneficiary)
            )
        );
        if (!success) revert ResolveDisputeFailed(data);

        // Step 2: Get the linked escrow instance ID
        (success, data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneEscrowId, (milestoneInstanceId, milestoneIndex))
        );
        require(success, "Query escrow ID failed");
        bytes32 escrowInstanceId = abi.decode(data, (bytes32));

        // Step 3: Execute the escrow action based on resolution
        if (releaseToBeneficiary) {
            // Release to beneficiary (freelancer wins)
            (success, data) = address(escrowClause).delegatecall(
                abi.encodeCall(EscrowClauseLogicV3.actionRelease, (escrowInstanceId))
            );
            if (!success) revert ReleaseFailed(data);

            // Mark milestone as released
            (success, data) = address(milestoneClause).delegatecall(
                abi.encodeCall(MilestoneClauseLogicV3.actionMarkReleased, (milestoneInstanceId, milestoneIndex))
            );
            if (!success) revert MarkReleasedFailed(data);
        } else {
            // Refund to depositor (client wins)
            (success, data) =
                address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionRefund, (escrowInstanceId)));
            if (!success) revert RefundFailed(data);

            // Note: actionResolveDispute(false) already sets milestone to MILESTONE_REFUNDED,
            // so we do NOT call actionMarkRefunded here
        }

        emit DisputeResolvedViaAdapter(milestoneInstanceId, milestoneIndex, releaseToBeneficiary);
    }

    /// @notice Cancel all milestones and refund all escrows
    /// @param milestoneInstanceId The milestone instance ID
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Can only be called in PENDING state (before activation).
    ///      Refunds all funded escrows and cancels the milestone instance.
    function cancelAndRefundAll(bytes32 milestoneInstanceId) external {
        // Get milestone count
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneCount, (milestoneInstanceId))
        );
        require(success, "Query count failed");
        uint256 count = abi.decode(data, (uint256));

        // Refund each funded escrow
        for (uint256 i = 0; i < count; i++) {
            // Get escrow ID
            (success, data) = address(milestoneClause).delegatecall(
                abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneEscrowId, (milestoneInstanceId, i))
            );
            require(success, "Query escrow ID failed");
            bytes32 escrowId = abi.decode(data, (bytes32));

            if (escrowId != bytes32(0)) {
                // Check if escrow is funded
                (success, data) =
                    address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (escrowId)));
                if (success && abi.decode(data, (bool))) {
                    // Refund this escrow
                    (success,) =
                        address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionRefund, (escrowId)));
                    // Continue even if refund fails (escrow might be in wrong state)
                }
            }
        }

        // Cancel the milestone instance
        (success, data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.actionCancel, (milestoneInstanceId))
        );
        // Don't revert if cancel fails - escrows are already refunded
    }
}
