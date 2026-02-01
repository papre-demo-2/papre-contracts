// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DeadlineClauseLogicV3} from "../clauses/state/DeadlineClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../clauses/orchestration/MilestoneClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../clauses/financial/EscrowClauseLogicV3.sol";

/// @title DeadlineEnforcementAdapter
/// @notice Adapter that enforces deadline-based automatic actions on milestones
/// @dev This adapter provides permissionless deadline enforcement - anyone can trigger
///      enforcement after a deadline has passed. It orchestrates three clauses:
///
///      1. DeadlineClauseLogicV3 - owns deadline configuration (when, what action)
///      2. MilestoneClauseLogicV3 - owns milestone state
///      3. EscrowClauseLogicV3 - owns fund custody
///
///      The adapter is designed to be called via delegatecall from Agreement contracts.
///      Unlike MilestoneEscrowAdapter (which requires client to call), this adapter
///      is permissionless - the deadline expiry IS the authorization.
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
///      │                    DeadlineEnforcementAdapter                            │
///      │                                                                          │
///      │  enforceDeadline():                                                      │
///      │    1. DeadlineClause.queryCanEnforce()  ← check expiry                  │
///      │    2. DeadlineClause.queryAction()      ← get action type               │
///      │    3. If RELEASE:                                                        │
///      │       - MilestoneClause.actionDeadlineConfirm()  ← permissionless       │
///      │       - EscrowClause.actionRelease()                                     │
///      │       - MilestoneClause.actionMarkReleased()                             │
///      │    4. If REFUND:                                                         │
///      │       - EscrowClause.actionRefund()                                      │
///      │       - MilestoneClause.actionMarkRefunded()                             │
///      │    5. DeadlineClause.actionMarkEnforced()                                │
///      └─────────────────────────────────────────────────────────────────────────┘
///
///      Use Cases:
///      - RELEASE: "If client doesn't respond within 7 days, auto-release to freelancer"
///      - REFUND: "If freelancer doesn't deliver within 30 days, auto-refund to client"
///
///      Anyone can call enforceDeadline() after the deadline passes - this could be:
///      - The beneficiary (freelancer) wanting to trigger release
///      - The client wanting to trigger refund
///      - A keeper bot monitoring deadlines
///      - The Agreement itself via scheduled execution
contract DeadlineEnforcementAdapter {
    // =============================================================
    // IMMUTABLES
    // =============================================================

    /// @notice Address of the DeadlineClauseLogicV3 implementation
    DeadlineClauseLogicV3 public immutable deadlineClause;

    /// @notice Address of the MilestoneClauseLogicV3 implementation
    MilestoneClauseLogicV3 public immutable milestoneClause;

    /// @notice Address of the EscrowClauseLogicV3 implementation
    EscrowClauseLogicV3 public immutable escrowClause;

    // =============================================================
    // ERRORS
    // =============================================================

    error DeadlineNotEnforceable();
    error QueryCanEnforceFailed(bytes reason);
    error QueryActionFailed(bytes reason);
    error QueryEscrowIdFailed(bytes reason);
    error DeadlineConfirmFailed(bytes reason);
    error ReleaseFailed(bytes reason);
    error MarkReleasedFailed(bytes reason);
    error RefundFailed(bytes reason);
    error MarkRefundedFailed(bytes reason);
    error MarkEnforcedFailed(bytes reason);
    error SetDeadlineFailed(bytes reason);
    error InvalidAction(uint8 action);

    // =============================================================
    // EVENTS
    // =============================================================

    /// @notice Emitted when a deadline is enforced via this adapter
    event DeadlineEnforcedViaAdapter(
        bytes32 indexed milestoneInstanceId, uint256 indexed milestoneIndex, uint8 action, address indexed enforcer
    );

    /// @notice Emitted when a deadline is set via this adapter
    event DeadlineSetViaAdapter(
        bytes32 indexed milestoneInstanceId, uint256 indexed milestoneIndex, uint256 deadline, uint8 action
    );

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    /// @notice Create a new DeadlineEnforcementAdapter
    /// @param _deadlineClause Address of DeadlineClauseLogicV3 implementation
    /// @param _milestoneClause Address of MilestoneClauseLogicV3 implementation
    /// @param _escrowClause Address of EscrowClauseLogicV3 implementation
    constructor(address _deadlineClause, address _milestoneClause, address _escrowClause) {
        deadlineClause = DeadlineClauseLogicV3(_deadlineClause);
        milestoneClause = MilestoneClauseLogicV3(_milestoneClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
    }

    // =============================================================
    // ADAPTER FUNCTIONS (called via delegatecall from Agreement)
    // =============================================================

    /// @notice Set a deadline for a milestone (FIRST TIME ONLY)
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone
    /// @param deadline Unix timestamp when deadline expires
    /// @param action What to do when deadline expires (1=RELEASE, 2=REFUND)
    /// @param controller Who can modify this deadline (address(0) = immutable)
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Typically called during agreement setup or after milestone activation.
    ///      Controller options:
    ///      - address(0): Immutable deadline, cannot be changed
    ///      - Single address: Only that address can modify
    ///      - Multisig address: Requires multi-party approval to modify
    function setDeadline(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex,
        uint256 deadline,
        uint8 action,
        address controller
    ) external {
        (bool success, bytes memory data) = address(deadlineClause)
            .delegatecall(
                abi.encodeCall(
                    DeadlineClauseLogicV3.intakeSetDeadline,
                    (milestoneInstanceId, milestoneIndex, deadline, action, controller)
                )
            );
        if (!success) revert SetDeadlineFailed(data);

        emit DeadlineSetViaAdapter(milestoneInstanceId, milestoneIndex, deadline, action);
    }

    /// @notice Modify an existing deadline
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone
    /// @param newDeadline New unix timestamp (must be in future)
    /// @param newAction New action (1=RELEASE, 2=REFUND)
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      Only callable by the controller set during setDeadline.
    ///      If controller is address(0), deadline is immutable and cannot be modified.
    function modifyDeadline(bytes32 milestoneInstanceId, uint256 milestoneIndex, uint256 newDeadline, uint8 newAction)
        external
    {
        (bool success, bytes memory data) = address(deadlineClause)
            .delegatecall(
                abi.encodeCall(
                    DeadlineClauseLogicV3.intakeModifyDeadline,
                    (milestoneInstanceId, milestoneIndex, newDeadline, newAction)
                )
            );
        if (!success) revert SetDeadlineFailed(data);

        emit DeadlineSetViaAdapter(milestoneInstanceId, milestoneIndex, newDeadline, newAction);
    }

    /// @notice Enforce a deadline that has passed
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone
    /// @dev MUST be called via delegatecall from an Agreement contract.
    ///      This function is PERMISSIONLESS - anyone can call it after deadline expires.
    ///      The deadline expiry IS the authorization.
    ///
    ///      Flow for RELEASE action:
    ///      1. Verify deadline can be enforced
    ///      2. Confirm milestone (permissionless via actionDeadlineConfirm)
    ///      3. Release escrow to beneficiary
    ///      4. Mark milestone as released
    ///      5. Mark deadline as enforced
    ///
    ///      Flow for REFUND action:
    ///      1. Verify deadline can be enforced
    ///      2. Refund escrow to depositor
    ///      3. Mark milestone as refunded
    ///      4. Mark deadline as enforced
    function enforceDeadline(bytes32 milestoneInstanceId, uint256 milestoneIndex) external {
        // Step 1: Check if deadline can be enforced
        (bool success, bytes memory data) = address(deadlineClause)
            .delegatecall(abi.encodeCall(DeadlineClauseLogicV3.queryCanEnforce, (milestoneInstanceId, milestoneIndex)));
        if (!success) revert QueryCanEnforceFailed(data);
        bool isEnforceable = abi.decode(data, (bool));
        if (!isEnforceable) revert DeadlineNotEnforceable();

        // Step 2: Get the action type
        (success, data) = address(deadlineClause)
            .delegatecall(abi.encodeCall(DeadlineClauseLogicV3.queryAction, (milestoneInstanceId, milestoneIndex)));
        if (!success) revert QueryActionFailed(data);
        uint8 action = abi.decode(data, (uint8));

        // Step 3: Get the linked escrow instance ID
        (success, data) = address(milestoneClause)
            .delegatecall(
                abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneEscrowId, (milestoneInstanceId, milestoneIndex))
            );
        if (!success) revert QueryEscrowIdFailed(data);
        bytes32 escrowInstanceId = abi.decode(data, (bytes32));

        // Step 4: Execute based on action type
        if (action == DeadlineClauseLogicV3(address(deadlineClause)).ACTION_RELEASE()) {
            // RELEASE: Auto-confirm and release to beneficiary
            _executeRelease(milestoneInstanceId, milestoneIndex, escrowInstanceId);
        } else if (action == DeadlineClauseLogicV3(address(deadlineClause)).ACTION_REFUND()) {
            // REFUND: Auto-refund to depositor
            _executeRefund(milestoneInstanceId, milestoneIndex, escrowInstanceId);
        } else {
            revert InvalidAction(action);
        }

        // Step 5: Mark deadline as enforced
        (success, data) = address(deadlineClause)
            .delegatecall(
                abi.encodeCall(DeadlineClauseLogicV3.actionMarkEnforced, (milestoneInstanceId, milestoneIndex))
            );
        if (!success) revert MarkEnforcedFailed(data);

        emit DeadlineEnforcedViaAdapter(milestoneInstanceId, milestoneIndex, action, msg.sender);
    }

    /// @notice Check if a deadline can currently be enforced
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone
    /// @return True if deadline is set, expired, and not yet enforced
    /// @dev This is a convenience function that can be called to check before enforcing.
    ///      Uses delegatecall to read from Agreement's storage using clause's code.
    function canEnforce(bytes32 milestoneInstanceId, uint256 milestoneIndex) external returns (bool) {
        (bool success, bytes memory data) = address(deadlineClause)
            .delegatecall(abi.encodeCall(DeadlineClauseLogicV3.queryCanEnforce, (milestoneInstanceId, milestoneIndex)));
        if (!success) return false;
        return abi.decode(data, (bool));
    }

    /// @notice Get deadline info for a milestone
    /// @param milestoneInstanceId The milestone instance ID
    /// @param milestoneIndex The index of the milestone
    /// @return deadline Unix timestamp (0 if not set)
    /// @return action ACTION_RELEASE (1), ACTION_REFUND (2), or ACTION_NONE (0)
    /// @return enforced Whether the deadline has been enforced
    /// @return controller Who can modify (address(0) = immutable)
    function getDeadline(bytes32 milestoneInstanceId, uint256 milestoneIndex)
        external
        returns (uint256 deadline, uint8 action, bool enforced, address controller)
    {
        (bool success, bytes memory data) = address(deadlineClause)
            .delegatecall(abi.encodeCall(DeadlineClauseLogicV3.queryDeadline, (milestoneInstanceId, milestoneIndex)));
        if (!success) return (0, 0, false, address(0));
        return abi.decode(data, (uint256, uint8, bool, address));
    }

    // =============================================================
    // INTERNAL FUNCTIONS
    // =============================================================

    /// @notice Execute RELEASE action: confirm milestone, release escrow, mark released
    function _executeRelease(bytes32 milestoneInstanceId, uint256 milestoneIndex, bytes32 escrowInstanceId) internal {
        // Step 1: Confirm milestone via deadline (permissionless)
        (bool success, bytes memory data) = address(milestoneClause)
            .delegatecall(
                abi.encodeCall(MilestoneClauseLogicV3.actionDeadlineConfirm, (milestoneInstanceId, milestoneIndex))
            );
        if (!success) revert DeadlineConfirmFailed(data);

        // Step 2: Release escrow
        (success, data) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionRelease, (escrowInstanceId)));
        if (!success) revert ReleaseFailed(data);

        // Step 3: Mark milestone as released
        (success, data) = address(milestoneClause)
            .delegatecall(
                abi.encodeCall(MilestoneClauseLogicV3.actionMarkReleased, (milestoneInstanceId, milestoneIndex))
            );
        if (!success) revert MarkReleasedFailed(data);
    }

    /// @notice Execute REFUND action: refund escrow, mark milestone refunded
    function _executeRefund(bytes32 milestoneInstanceId, uint256 milestoneIndex, bytes32 escrowInstanceId) internal {
        // Step 1: Refund escrow
        (bool success, bytes memory data) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionRefund, (escrowInstanceId)));
        if (!success) revert RefundFailed(data);

        // Step 2: Mark milestone as refunded
        (success, data) = address(milestoneClause)
            .delegatecall(
                abi.encodeCall(MilestoneClauseLogicV3.actionMarkRefunded, (milestoneInstanceId, milestoneIndex))
            );
        if (!success) revert MarkRefundedFailed(data);
    }
}
