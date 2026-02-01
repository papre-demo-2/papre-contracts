// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CrossChainClauseLogicV3} from "../../../src/clauses/crosschain/CrossChainClauseLogicV3.sol";

/// @title CrossChainClauseLogicV3 Unit Tests
/// @notice Tests for the v3 cross-chain messaging clause with ERC-7201 storage
contract CrossChainClauseLogicV3Test is Test {
    CrossChainClauseLogicV3 public clause;

    // Test accounts
    address controller;
    address remoteAgreement;

    // Instance IDs for testing
    bytes32 constant INSTANCE_1 = bytes32(uint256(1));
    bytes32 constant INSTANCE_2 = bytes32(uint256(2));

    // Chain selectors (using CCIP Local's selector)
    uint64 constant CHAIN_SELECTOR = 16015286601757825753;

    // State constants (matching the contract)
    uint16 constant PENDING = 1 << 1; // 0x0002
    uint16 constant SENT = 1 << 4; // 0x0010
    uint16 constant CONFIRMED = 1 << 5; // 0x0020
    uint16 constant RECEIVED = 1 << 6; // 0x0040
    uint16 constant CANCELLED = 1 << 3; // 0x0008

    // Action constants
    uint8 constant ACTION_RELEASE_ESCROW = 2;

    function setUp() public {
        clause = new CrossChainClauseLogicV3();

        controller = makeAddr("controller");
        remoteAgreement = makeAddr("remoteAgreement");
    }

    // =============================================================
    // INITIAL STATE TESTS
    // =============================================================

    function test_InitialState_IsUninitialized() public view {
        assertEq(clause.queryStatus(INSTANCE_1), 0);
    }

    function test_QueryDestinationChain_InitiallyZero() public view {
        assertEq(clause.queryDestinationChain(INSTANCE_1), 0);
    }

    // =============================================================
    // INTAKE TESTS
    // =============================================================

    function test_IntakeDestinationChain_Success() public {
        clause.intakeDestinationChain(INSTANCE_1, CHAIN_SELECTOR);
        assertEq(clause.queryDestinationChain(INSTANCE_1), CHAIN_SELECTOR);
    }

    function test_IntakeDestinationChain_RevertsOnZero() public {
        vm.expectRevert(CrossChainClauseLogicV3.ZeroChainSelector.selector);
        clause.intakeDestinationChain(INSTANCE_1, 0);
    }

    function test_IntakeRemoteAgreement_Success() public {
        clause.intakeRemoteAgreement(INSTANCE_1, remoteAgreement);
        assertEq(clause.queryRemoteAgreement(INSTANCE_1), remoteAgreement);
    }

    function test_IntakeRemoteAgreement_RevertsOnZeroAddress() public {
        vm.expectRevert(CrossChainClauseLogicV3.ZeroAddress.selector);
        clause.intakeRemoteAgreement(INSTANCE_1, address(0));
    }

    function test_IntakeAction_Success() public {
        clause.intakeAction(INSTANCE_1, ACTION_RELEASE_ESCROW);
        assertEq(clause.queryAction(INSTANCE_1), ACTION_RELEASE_ESCROW);
    }

    function test_IntakeContentHash_Success() public {
        bytes32 contentHash = keccak256("document");
        clause.intakeContentHash(INSTANCE_1, contentHash);
        assertEq(clause.queryContentHash(INSTANCE_1), contentHash);
    }

    function test_IntakeExtraData_Success() public {
        bytes memory extraData = abi.encode(bytes32(uint256(123)));
        clause.intakeExtraData(INSTANCE_1, extraData);
        assertEq(clause.queryExtraData(INSTANCE_1), extraData);
    }

    function test_IntakeController_Success() public {
        clause.intakeController(INSTANCE_1, controller);
        assertEq(clause.queryController(INSTANCE_1), controller);
    }

    function test_IntakeController_RevertsOnZeroAddress() public {
        vm.expectRevert(CrossChainClauseLogicV3.ZeroAddress.selector);
        clause.intakeController(INSTANCE_1, address(0));
    }

    function test_IntakeReady_TransitionsToPending() public {
        // Setup all required fields
        clause.intakeDestinationChain(INSTANCE_1, CHAIN_SELECTOR);
        clause.intakeRemoteAgreement(INSTANCE_1, remoteAgreement);
        clause.intakeController(INSTANCE_1, controller);

        // Verify still uninitialized
        assertEq(clause.queryStatus(INSTANCE_1), 0);

        // Finalize
        clause.intakeReady(INSTANCE_1);

        // Now PENDING
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);
    }

    function test_IntakeReady_RevertsWithoutDestinationChain() public {
        clause.intakeRemoteAgreement(INSTANCE_1, remoteAgreement);
        clause.intakeController(INSTANCE_1, controller);

        vm.expectRevert(CrossChainClauseLogicV3.MissingConfiguration.selector);
        clause.intakeReady(INSTANCE_1);
    }

    function test_IntakeReady_RevertsWithoutRemoteAgreement() public {
        clause.intakeDestinationChain(INSTANCE_1, CHAIN_SELECTOR);
        clause.intakeController(INSTANCE_1, controller);

        vm.expectRevert(CrossChainClauseLogicV3.MissingConfiguration.selector);
        clause.intakeReady(INSTANCE_1);
    }

    function test_IntakeReady_RevertsWithoutController() public {
        clause.intakeDestinationChain(INSTANCE_1, CHAIN_SELECTOR);
        clause.intakeRemoteAgreement(INSTANCE_1, remoteAgreement);

        vm.expectRevert(CrossChainClauseLogicV3.MissingConfiguration.selector);
        clause.intakeReady(INSTANCE_1);
    }

    function test_Intake_OnlyInUninitialized() public {
        // Setup and transition to PENDING
        _setupPendingInstance(INSTANCE_1);

        // All intakes should fail now
        vm.expectRevert("Wrong state");
        clause.intakeDestinationChain(INSTANCE_1, CHAIN_SELECTOR);

        vm.expectRevert("Wrong state");
        clause.intakeRemoteAgreement(INSTANCE_1, remoteAgreement);

        vm.expectRevert("Wrong state");
        clause.intakeAction(INSTANCE_1, ACTION_RELEASE_ESCROW);
    }

    // =============================================================
    // ACTION TESTS - MARK SENT
    // =============================================================

    function test_ActionMarkSent_Success() public {
        _setupPendingInstance(INSTANCE_1);
        bytes32 messageId = keccak256("messageId");

        // In v3 delegatecall pattern, actionMarkSent can be called by anyone
        // since authorization is handled at the Agreement level
        clause.actionMarkSent(INSTANCE_1, messageId);

        assertEq(clause.queryStatus(INSTANCE_1), SENT);
        assertEq(clause.queryMessageId(INSTANCE_1), messageId);
        assertGt(clause.querySentAt(INSTANCE_1), 0);
    }

    // Note: In v3 delegatecall pattern, authorization is handled at Agreement level
    // The clause trusts that if it's being executed, the Agreement has authorized it
    // Therefore we don't test caller authorization at the clause level

    function test_ActionMarkSent_OnlyInPending() public {
        _setupPendingInstance(INSTANCE_1);
        bytes32 messageId = keccak256("messageId");

        // Mark as sent
        clause.actionMarkSent(INSTANCE_1, messageId);

        // Can't mark sent again
        vm.expectRevert("Wrong state");
        clause.actionMarkSent(INSTANCE_1, keccak256("newMessageId"));
    }

    // =============================================================
    // ACTION TESTS - MARK CONFIRMED
    // =============================================================

    function test_ActionMarkConfirmed_Success() public {
        _setupPendingInstance(INSTANCE_1);
        bytes32 messageId = keccak256("messageId");

        // Mark as sent
        clause.actionMarkSent(INSTANCE_1, messageId);

        // Mark as confirmed
        clause.actionMarkConfirmed(INSTANCE_1);

        assertEq(clause.queryStatus(INSTANCE_1), CONFIRMED);
    }

    function test_ActionMarkConfirmed_OnlyInSent() public {
        _setupPendingInstance(INSTANCE_1);

        // Can't confirm from PENDING
        vm.expectRevert("Wrong state");
        clause.actionMarkConfirmed(INSTANCE_1);
    }

    // =============================================================
    // ACTION TESTS - PROCESS INCOMING
    // =============================================================

    function test_ActionProcessIncoming_Success() public {
        bytes32 contentHash = keccak256("document");
        bytes memory extraData = abi.encode(bytes32(uint256(123)));

        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, contentHash, extraData
        );

        assertEq(clause.queryStatus(INSTANCE_1), RECEIVED);
        assertEq(clause.querySourceChain(INSTANCE_1), CHAIN_SELECTOR);
        assertEq(clause.queryRemoteAgreement(INSTANCE_1), remoteAgreement);
        assertEq(clause.queryAction(INSTANCE_1), ACTION_RELEASE_ESCROW);
        assertEq(clause.queryContentHash(INSTANCE_1), contentHash);
        assertEq(clause.queryExtraData(INSTANCE_1), extraData);
        assertGt(clause.queryReceivedAt(INSTANCE_1), 0);
    }

    function test_ActionProcessIncoming_OnlyOncePerInstance() public {
        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc"), ""
        );

        // Can't process same instance again
        vm.expectRevert("Already processed");
        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc2"), ""
        );
    }

    // =============================================================
    // ACTION TESTS - CANCEL
    // =============================================================

    function test_ActionCancel_Success() public {
        _setupPendingInstance(INSTANCE_1);

        clause.actionCancel(INSTANCE_1);

        assertEq(clause.queryStatus(INSTANCE_1), CANCELLED);
    }

    function test_ActionCancel_OnlyInPending() public {
        // Can't cancel uninitialized
        vm.expectRevert("Wrong state");
        clause.actionCancel(INSTANCE_1);
    }

    // =============================================================
    // HANDOFF TESTS
    // =============================================================

    function test_HandoffAction_OnlyInReceived() public {
        // Not received yet
        vm.expectRevert("Wrong state");
        clause.handoffAction(INSTANCE_1);
    }

    function test_HandoffAction_Success() public {
        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc"), ""
        );

        assertEq(clause.handoffAction(INSTANCE_1), ACTION_RELEASE_ESCROW);
    }

    function test_HandoffExtraData_Success() public {
        bytes memory extraData = abi.encode(bytes32(uint256(123)));

        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc"), extraData
        );

        assertEq(clause.handoffExtraData(INSTANCE_1), extraData);
    }

    function test_HandoffContentHash_Success() public {
        bytes32 contentHash = keccak256("document");

        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, contentHash, ""
        );

        assertEq(clause.handoffContentHash(INSTANCE_1), contentHash);
    }

    function test_HandoffSourceAgreement_Success() public {
        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc"), ""
        );

        assertEq(clause.handoffSourceAgreement(INSTANCE_1), remoteAgreement);
    }

    function test_HandoffMessageId_Success() public {
        _setupPendingInstance(INSTANCE_1);
        bytes32 messageId = keccak256("messageId");

        clause.actionMarkSent(INSTANCE_1, messageId);

        assertEq(clause.handoffMessageId(INSTANCE_1), messageId);
    }

    function test_HandoffMessageId_WorksInConfirmed() public {
        _setupPendingInstance(INSTANCE_1);
        bytes32 messageId = keccak256("messageId");

        clause.actionMarkSent(INSTANCE_1, messageId);
        clause.actionMarkConfirmed(INSTANCE_1);

        assertEq(clause.handoffMessageId(INSTANCE_1), messageId);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryIsPending_True() public {
        _setupPendingInstance(INSTANCE_1);
        assertTrue(clause.queryIsPending(INSTANCE_1));
    }

    function test_QueryIsPending_False() public view {
        assertFalse(clause.queryIsPending(INSTANCE_1));
    }

    function test_QueryIsSent_True() public {
        _setupPendingInstance(INSTANCE_1);
        clause.actionMarkSent(INSTANCE_1, keccak256("msg"));
        assertTrue(clause.queryIsSent(INSTANCE_1));
    }

    function test_QueryIsSent_TrueAfterConfirmed() public {
        _setupPendingInstance(INSTANCE_1);
        clause.actionMarkSent(INSTANCE_1, keccak256("msg"));
        clause.actionMarkConfirmed(INSTANCE_1);
        assertTrue(clause.queryIsSent(INSTANCE_1));
    }

    function test_QueryIsReceived_True() public {
        clause.actionProcessIncoming(
            INSTANCE_1, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc"), ""
        );
        assertTrue(clause.queryIsReceived(INSTANCE_1));
    }

    function test_QueryConfig_Success() public {
        bytes32 contentHash = keccak256("document");

        clause.intakeDestinationChain(INSTANCE_1, CHAIN_SELECTOR);
        clause.intakeRemoteAgreement(INSTANCE_1, remoteAgreement);
        clause.intakeAction(INSTANCE_1, ACTION_RELEASE_ESCROW);
        clause.intakeContentHash(INSTANCE_1, contentHash);
        clause.intakeController(INSTANCE_1, controller);
        clause.intakeReady(INSTANCE_1);

        (uint16 status, uint64 destChain, address remote, uint8 action, bytes32 hash) = clause.queryConfig(INSTANCE_1);

        assertEq(status, PENDING);
        assertEq(destChain, CHAIN_SELECTOR);
        assertEq(remote, remoteAgreement);
        assertEq(action, ACTION_RELEASE_ESCROW);
        assertEq(hash, contentHash);
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_MultipleInstances_Independent() public {
        // Setup instance 1
        _setupPendingInstance(INSTANCE_1);

        // Instance 2 should be unaffected
        assertEq(clause.queryStatus(INSTANCE_2), 0);
        assertEq(clause.queryDestinationChain(INSTANCE_2), 0);
        assertEq(clause.queryRemoteAgreement(INSTANCE_2), address(0));
    }

    function test_MultipleInstances_DifferentStates() public {
        // Setup instance 1 as pending
        _setupPendingInstance(INSTANCE_1);

        // Setup instance 2 as received
        clause.actionProcessIncoming(
            INSTANCE_2, CHAIN_SELECTOR, remoteAgreement, ACTION_RELEASE_ESCROW, keccak256("doc"), ""
        );

        // Verify different states
        assertEq(clause.queryStatus(INSTANCE_1), PENDING);
        assertEq(clause.queryStatus(INSTANCE_2), RECEIVED);
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _setupPendingInstance(bytes32 instanceId) internal {
        clause.intakeDestinationChain(instanceId, CHAIN_SELECTOR);
        clause.intakeRemoteAgreement(instanceId, remoteAgreement);
        clause.intakeController(instanceId, controller);
        clause.intakeReady(instanceId);
    }
}
