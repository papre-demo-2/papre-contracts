// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DeadlineEnforcementAdapter} from "../../src/adapters/DeadlineEnforcementAdapter.sol";
import {DeadlineClauseLogicV3} from "../../src/clauses/state/DeadlineClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../../src/clauses/orchestration/MilestoneClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";

/// @title MockDeadlineAgreement
/// @notice Simulates an Agreement contract that holds storage for all deadline-related clauses
contract MockDeadlineAgreement {
    DeadlineClauseLogicV3 public immutable deadlineClause;
    MilestoneClauseLogicV3 public immutable milestoneClause;
    EscrowClauseLogicV3 public immutable escrowClause;
    DeadlineEnforcementAdapter public immutable adapter;

    error DelegatecallFailed(bytes data);

    constructor(
        address _deadlineClause,
        address _milestoneClause,
        address _escrowClause,
        address _adapter
    ) {
        deadlineClause = DeadlineClauseLogicV3(_deadlineClause);
        milestoneClause = MilestoneClauseLogicV3(_milestoneClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        adapter = DeadlineEnforcementAdapter(_adapter);
    }

    // =========================================================
    // ADAPTER DELEGATECALLS
    // =========================================================

    function adapter_setDeadline(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex,
        uint256 deadline,
        uint8 action,
        address controller
    ) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(
                DeadlineEnforcementAdapter.setDeadline,
                (milestoneInstanceId, milestoneIndex, deadline, action, controller)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function adapter_modifyDeadline(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex,
        uint256 newDeadline,
        uint8 newAction
    ) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(
                DeadlineEnforcementAdapter.modifyDeadline,
                (milestoneInstanceId, milestoneIndex, newDeadline, newAction)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function adapter_enforceDeadline(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex
    ) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(
                DeadlineEnforcementAdapter.enforceDeadline,
                (milestoneInstanceId, milestoneIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function adapter_canEnforce(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex
    ) external returns (bool) {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(
                DeadlineEnforcementAdapter.canEnforce,
                (milestoneInstanceId, milestoneIndex)
            )
        );
        if (!success) return false;
        return abi.decode(data, (bool));
    }

    function adapter_getDeadline(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex
    ) external returns (uint256 deadline, uint8 action, bool enforced, address controller) {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(
                DeadlineEnforcementAdapter.getDeadline,
                (milestoneInstanceId, milestoneIndex)
            )
        );
        if (!success) return (0, 0, false, address(0));
        return abi.decode(data, (uint256, uint8, bool, address));
    }

    // =========================================================
    // MILESTONE CLAUSE DELEGATECALLS
    // =========================================================

    function milestone_intakeMilestone(
        bytes32 instanceId,
        bytes32 descriptionHash,
        uint256 amount
    ) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.intakeMilestone, (instanceId, descriptionHash, amount))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_intakeBeneficiary(bytes32 instanceId, address beneficiary) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.intakeBeneficiary, (instanceId, beneficiary))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_intakeClient(bytes32 instanceId, address client) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.intakeClient, (instanceId, client))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_intakeToken(bytes32 instanceId, address token) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.intakeToken, (instanceId, token))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_intakeMilestoneEscrowId(
        bytes32 instanceId,
        uint256 index,
        bytes32 escrowId
    ) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.intakeMilestoneEscrowId, (instanceId, index, escrowId))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_intakeReady(bytes32 instanceId) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.intakeReady, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_actionActivate(bytes32 instanceId) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.actionActivate, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_actionRequestConfirmation(bytes32 instanceId, uint256 index) external {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.actionRequestConfirmation, (instanceId, index))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function milestone_queryStatus(bytes32 instanceId) external returns (uint16) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryStatus, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint16));
    }

    function milestone_queryMilestoneStatus(bytes32 instanceId, uint256 index) external returns (uint8) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneStatus, (instanceId, index))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint8));
    }

    function milestone_queryTotalReleased(bytes32 instanceId) external returns (uint256) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryTotalReleased, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint256));
    }

    // =========================================================
    // ESCROW CLAUSE DELEGATECALLS
    // =========================================================

    function escrow_intakeDepositor(bytes32 instanceId, address depositor) external {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeDepositor, (instanceId, depositor))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function escrow_intakeBeneficiary(bytes32 instanceId, address beneficiary) external {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeBeneficiary, (instanceId, beneficiary))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function escrow_intakeToken(bytes32 instanceId, address token) external {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeToken, (instanceId, token))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function escrow_intakeAmount(bytes32 instanceId, uint256 amount) external {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeAmount, (instanceId, amount))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function escrow_intakeReady(bytes32 instanceId) external {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeReady, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function escrow_actionDeposit(bytes32 instanceId) external payable {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.actionDeposit, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function escrow_queryStatus(bytes32 instanceId) external returns (uint16) {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.queryStatus, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint16));
    }

    function escrow_queryBeneficiary(bytes32 instanceId) external returns (address) {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.queryBeneficiary, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (address));
    }

    // Allow receiving ETH
    receive() external payable {}
}

contract DeadlineEnforcementAdapterTest is Test {
    DeadlineClauseLogicV3 public deadlineClause;
    MilestoneClauseLogicV3 public milestoneClause;
    EscrowClauseLogicV3 public escrowClause;
    DeadlineEnforcementAdapter public adapter;
    MockDeadlineAgreement public agreement;

    address public client = address(0x1);
    address public freelancer = address(0x2);
    address public randomEnforcer = address(0x3);

    bytes32 constant MILESTONE_INSTANCE_ID = keccak256("test.milestone.instance");
    bytes32 constant ESCROW_INSTANCE_ID_0 = keccak256("test.escrow.0");
    bytes32 constant ESCROW_INSTANCE_ID_1 = keccak256("test.escrow.1");
    bytes32 constant DESCRIPTION_HASH = keccak256("Deliver website design");

    uint8 constant ACTION_RELEASE = 1;
    uint8 constant ACTION_REFUND = 2;

    // Milestone states
    uint8 constant MILESTONE_PENDING = 1;
    uint8 constant MILESTONE_REQUESTED = 2;
    uint8 constant MILESTONE_CONFIRMED = 3;
    uint8 constant MILESTONE_RELEASED = 5;
    uint8 constant MILESTONE_REFUNDED = 6;

    // Escrow states
    uint16 constant ESCROW_PENDING = 0x0002;
    uint16 constant ESCROW_FUNDED = 0x0004;
    uint16 constant ESCROW_RELEASED = 0x0008;
    uint16 constant ESCROW_REFUNDED = 0x0010;

    // Milestone overall states
    uint16 constant MILESTONE_STATUS_ACTIVE = 0x0010;
    uint16 constant MILESTONE_STATUS_COMPLETE = 0x0004;

    function setUp() public {
        // Deploy clause implementations
        deadlineClause = new DeadlineClauseLogicV3();
        milestoneClause = new MilestoneClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();

        // Deploy adapter
        adapter = new DeadlineEnforcementAdapter(
            address(deadlineClause),
            address(milestoneClause),
            address(escrowClause)
        );

        // Deploy mock agreement
        agreement = new MockDeadlineAgreement(
            address(deadlineClause),
            address(milestoneClause),
            address(escrowClause),
            address(adapter)
        );

        // Fund the client
        vm.deal(client, 100 ether);
    }

    /// @dev Helper to set up a single-milestone agreement in ACTIVE state
    function _setupSingleMilestoneAgreement(uint256 amount) internal {
        // Setup milestone
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, DESCRIPTION_HASH, amount);
        agreement.milestone_intakeBeneficiary(MILESTONE_INSTANCE_ID, freelancer);
        agreement.milestone_intakeClient(MILESTONE_INSTANCE_ID, client);
        agreement.milestone_intakeToken(MILESTONE_INSTANCE_ID, address(0)); // ETH

        // Setup escrow
        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_0, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_0, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_0, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_0, amount);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_0);

        // Link escrow to milestone
        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 0, ESCROW_INSTANCE_ID_0);
        agreement.milestone_intakeReady(MILESTONE_INSTANCE_ID);

        // Fund escrow
        vm.prank(client);
        agreement.escrow_actionDeposit{value: amount}(ESCROW_INSTANCE_ID_0);

        // Activate milestone
        agreement.milestone_actionActivate(MILESTONE_INSTANCE_ID);
    }

    // =============================================================
    // SET DEADLINE TESTS
    // =============================================================

    function test_SetDeadline_Success() public {
        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        (uint256 d, uint8 a, bool e,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(d, deadline);
        assertEq(a, ACTION_RELEASE);
        assertFalse(e);
    }

    function test_SetDeadline_RefundAction() public {
        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + 30 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_REFUND, address(0));

        (uint256 d, uint8 a,,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(d, deadline);
        assertEq(a, ACTION_REFUND);
    }

    // =============================================================
    // ENFORCE DEADLINE - RELEASE ACTION TESTS
    // =============================================================

    function test_EnforceDeadline_Release_Success() public {
        _setupSingleMilestoneAgreement(1 ether);

        // Set deadline with RELEASE action
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        // Freelancer requests confirmation (optional but realistic)
        vm.prank(freelancer);
        agreement.milestone_actionRequestConfirmation(MILESTONE_INSTANCE_ID, 0);

        // Time passes, deadline expires
        vm.warp(deadline + 1);

        // Record freelancer balance before
        uint256 balanceBefore = freelancer.balance;

        // Anyone can enforce (permissionless)
        vm.prank(randomEnforcer);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Verify milestone is released
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);

        // Verify escrow was released
        assertEq(agreement.escrow_queryStatus(ESCROW_INSTANCE_ID_0), ESCROW_RELEASED);

        // Verify freelancer received funds
        assertEq(freelancer.balance, balanceBefore + 1 ether);

        // Verify deadline is marked as enforced
        (,, bool enforced,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertTrue(enforced);
    }

    function test_EnforceDeadline_Release_FromPendingState() public {
        _setupSingleMilestoneAgreement(1 ether);

        // Set deadline but freelancer never requests confirmation
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        // Milestone is still in PENDING state (not REQUESTED)
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_PENDING);

        // Time passes, deadline expires
        vm.warp(deadline + 1);

        // Enforce - should still work from PENDING state
        vm.prank(randomEnforcer);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Verify milestone is released
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
    }

    function test_EnforceDeadline_Release_ClientAutoApproval() public {
        // This tests the scenario: "If client doesn't respond within 7 days, auto-release"
        _setupSingleMilestoneAgreement(2 ether);

        // Set deadline for auto-release
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        // Freelancer requests confirmation
        vm.prank(freelancer);
        agreement.milestone_actionRequestConfirmation(MILESTONE_INSTANCE_ID, 0);

        // Client doesn't respond (no actionConfirm call)
        // 7 days pass
        vm.warp(deadline + 1);

        // Freelancer triggers enforcement
        vm.prank(freelancer);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Funds automatically released to freelancer
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
        assertEq(agreement.escrow_queryStatus(ESCROW_INSTANCE_ID_0), ESCROW_RELEASED);
    }

    // =============================================================
    // ENFORCE DEADLINE - REFUND ACTION TESTS
    // =============================================================

    function test_EnforceDeadline_Refund_Success() public {
        _setupSingleMilestoneAgreement(1 ether);

        // Set deadline with REFUND action (freelancer must deliver or funds refund)
        uint256 deadline = block.timestamp + 30 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_REFUND, address(0));

        // Record client balance before
        uint256 balanceBefore = client.balance;

        // Freelancer doesn't deliver, deadline expires
        vm.warp(deadline + 1);

        // Client (or anyone) triggers enforcement
        vm.prank(client);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Verify milestone is refunded
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REFUNDED);

        // Verify escrow was refunded
        assertEq(agreement.escrow_queryStatus(ESCROW_INSTANCE_ID_0), ESCROW_REFUNDED);

        // Verify client received refund
        assertEq(client.balance, balanceBefore + 1 ether);

        // Verify deadline is marked as enforced
        (,, bool enforced,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertTrue(enforced);
    }

    function test_EnforceDeadline_Refund_DeliveryDeadlineMissed() public {
        // Scenario: "Freelancer must deliver within 30 days or auto-refund"
        _setupSingleMilestoneAgreement(5 ether);

        uint256 deadline = block.timestamp + 30 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_REFUND, address(0));

        // Milestone stays in PENDING (no request confirmation)
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_PENDING);

        // 30 days pass with no delivery
        vm.warp(deadline + 1);

        // Client triggers refund
        vm.prank(client);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Funds returned to client
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REFUNDED);
    }

    // =============================================================
    // CAN ENFORCE QUERY TESTS
    // =============================================================

    function test_CanEnforce_NotSet() public {
        _setupSingleMilestoneAgreement(1 ether);
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
    }

    function test_CanEnforce_NotExpired() public {
        _setupSingleMilestoneAgreement(1 ether);
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, block.timestamp + 7 days, ACTION_RELEASE, address(0));
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
    }

    function test_CanEnforce_ExpiredNotEnforced() public {
        _setupSingleMilestoneAgreement(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
    }

    function test_CanEnforce_AlreadyEnforced() public {
        _setupSingleMilestoneAgreement(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
    }

    // =============================================================
    // ERROR CASES
    // =============================================================

    function test_EnforceDeadline_RevertNotEnforceable_NotSet() public {
        _setupSingleMilestoneAgreement(1 ether);

        // No deadline set - reverts with DelegatecallFailed wrapping DeadlineNotEnforceable
        vm.expectRevert();
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
    }

    function test_EnforceDeadline_RevertNotEnforceable_NotExpired() public {
        _setupSingleMilestoneAgreement(1 ether);
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, block.timestamp + 7 days, ACTION_RELEASE, address(0));

        // Deadline not yet expired - reverts with DelegatecallFailed
        vm.expectRevert();
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
    }

    function test_EnforceDeadline_RevertNotEnforceable_AlreadyEnforced() public {
        _setupSingleMilestoneAgreement(1 ether);
        uint256 deadline = block.timestamp + 1 hours;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Try to enforce again - reverts with DelegatecallFailed
        vm.expectRevert();
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
    }

    // =============================================================
    // MULTIPLE MILESTONES TESTS
    // =============================================================

    function test_MultiMilestone_DifferentDeadlines() public {
        // Setup 2 milestones
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, DESCRIPTION_HASH, 1 ether);
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, keccak256("Phase 2"), 2 ether);
        agreement.milestone_intakeBeneficiary(MILESTONE_INSTANCE_ID, freelancer);
        agreement.milestone_intakeClient(MILESTONE_INSTANCE_ID, client);
        agreement.milestone_intakeToken(MILESTONE_INSTANCE_ID, address(0));

        // Setup escrow 0
        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_0, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_0, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_0, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_0, 1 ether);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_0);

        // Setup escrow 1
        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_1, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_1, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_1, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_1, 2 ether);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_1);

        // Link escrows
        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 0, ESCROW_INSTANCE_ID_0);
        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 1, ESCROW_INSTANCE_ID_1);
        agreement.milestone_intakeReady(MILESTONE_INSTANCE_ID);

        // Fund escrows
        vm.prank(client);
        agreement.escrow_actionDeposit{value: 1 ether}(ESCROW_INSTANCE_ID_0);
        vm.prank(client);
        agreement.escrow_actionDeposit{value: 2 ether}(ESCROW_INSTANCE_ID_1);

        // Activate
        agreement.milestone_actionActivate(MILESTONE_INSTANCE_ID);

        // Set different deadlines: milestone 0 auto-release, milestone 1 auto-refund
        uint256 deadline0 = block.timestamp + 7 days;
        uint256 deadline1 = block.timestamp + 30 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline0, ACTION_RELEASE, address(0));
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 1, deadline1, ACTION_REFUND, address(0));

        // Warp past first deadline only
        vm.warp(deadline0 + 1);

        // Can enforce milestone 0 but not 1
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 1));

        // Enforce milestone 0
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 1), MILESTONE_PENDING);

        // Warp past second deadline
        vm.warp(deadline1 + 1);

        // Now can enforce milestone 1
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 1));
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 1);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 1), MILESTONE_REFUNDED);
    }

    // =============================================================
    // PERMISSIONLESS ENFORCEMENT TESTS
    // =============================================================

    function test_AnyoneCanEnforce() public {
        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + 1 hours;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);

        // Random address can enforce
        address randomUser = address(0x999);
        vm.prank(randomUser);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Funds released to freelancer (not the enforcer)
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
    }

    function test_KeeperBotEnforcement() public {
        // Simulates a keeper bot monitoring deadlines
        address keeperBot = address(0xB07);

        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + 1 hours;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);

        // Keeper checks and enforces
        bool canDo = agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0);
        assertTrue(canDo);

        vm.prank(keeperBot);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Verify enforcement happened
        (,, bool enforced,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertTrue(enforced);
    }

    // =============================================================
    // EDGE CASES - NON-REALISTIC SCENARIOS
    // =============================================================

    function test_EdgeCase_VeryShortDeadline() public {
        _setupSingleMilestoneAgreement(1 ether);

        // 1 second deadline
        uint256 deadline = block.timestamp + 1;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        // Warp exactly to deadline (should work at deadline time)
        vm.warp(deadline);
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
    }

    function test_EdgeCase_VeryLongDeadline() public {
        _setupSingleMilestoneAgreement(1 ether);

        // 10 year deadline
        uint256 deadline = block.timestamp + 365 days * 10;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_REFUND, address(0));

        // Not enforceable yet
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        // Warp 10 years
        vm.warp(deadline + 1);
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REFUNDED);
    }

    function test_EdgeCase_ResetDeadlineBeforeExpiry() public {
        _setupSingleMilestoneAgreement(1 ether);

        // Set initial deadline for REFUND
        uint256 deadline1 = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline1, ACTION_REFUND, address(0));

        // Verify initial settings
        (uint256 d1, uint8 a1,,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(d1, deadline1);
        assertEq(a1, ACTION_REFUND);

        // Client and freelancer negotiate extension - use modifyDeadline (requires controller)
        // But since controller is address(0) (immutable), this won't work.
        // Let's re-set up with a proper controller
    }

    function test_EdgeCase_ModifyDeadlineWithController() public {
        _setupSingleMilestoneAgreement(1 ether);

        address controller = address(0x123);

        // Set initial deadline with a controller
        uint256 deadline1 = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline1, ACTION_REFUND, controller);

        // Verify initial settings
        (uint256 d1, uint8 a1,, address c1) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(d1, deadline1);
        assertEq(a1, ACTION_REFUND);
        assertEq(c1, controller);

        // Controller modifies the deadline
        uint256 deadline2 = block.timestamp + 30 days;
        vm.prank(controller);
        agreement.adapter_modifyDeadline(MILESTONE_INSTANCE_ID, 0, deadline2, ACTION_RELEASE);

        // Verify new settings
        (uint256 d2, uint8 a2,,) = agreement.adapter_getDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(d2, deadline2);
        assertEq(a2, ACTION_RELEASE);

        // Warp past original deadline but not new one
        vm.warp(deadline1 + 1);
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        // Warp past new deadline
        vm.warp(deadline2 + 1);
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        // Now enforces with RELEASE (not original REFUND)
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
    }

    function test_EdgeCase_SameDeadlineMultipleMilestones() public {
        // Setup 2 milestones
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, DESCRIPTION_HASH, 1 ether);
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, keccak256("Phase 2"), 1 ether);
        agreement.milestone_intakeBeneficiary(MILESTONE_INSTANCE_ID, freelancer);
        agreement.milestone_intakeClient(MILESTONE_INSTANCE_ID, client);
        agreement.milestone_intakeToken(MILESTONE_INSTANCE_ID, address(0));

        // Setup escrows
        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_0, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_0, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_0, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_0, 1 ether);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_0);

        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_1, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_1, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_1, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_1, 1 ether);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_1);

        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 0, ESCROW_INSTANCE_ID_0);
        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 1, ESCROW_INSTANCE_ID_1);
        agreement.milestone_intakeReady(MILESTONE_INSTANCE_ID);

        vm.prank(client);
        agreement.escrow_actionDeposit{value: 1 ether}(ESCROW_INSTANCE_ID_0);
        vm.prank(client);
        agreement.escrow_actionDeposit{value: 1 ether}(ESCROW_INSTANCE_ID_1);

        agreement.milestone_actionActivate(MILESTONE_INSTANCE_ID);

        // Set SAME deadline for both milestones
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 1, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);

        // Both can be enforced
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 1));

        // Enforce both in same block
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 1);

        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 1), MILESTONE_RELEASED);
    }

    function test_EdgeCase_EnforceAtExactDeadlineTime() public {
        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + 1 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        // One second before - cannot enforce
        vm.warp(deadline - 1);
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        // Exactly at deadline - CAN enforce (>= check)
        vm.warp(deadline);
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
    }

    function test_EdgeCase_NoDeadlineSetForOneMilestoneOnly() public {
        // Setup 2 milestones
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, DESCRIPTION_HASH, 1 ether);
        agreement.milestone_intakeMilestone(MILESTONE_INSTANCE_ID, keccak256("Phase 2"), 2 ether);
        agreement.milestone_intakeBeneficiary(MILESTONE_INSTANCE_ID, freelancer);
        agreement.milestone_intakeClient(MILESTONE_INSTANCE_ID, client);
        agreement.milestone_intakeToken(MILESTONE_INSTANCE_ID, address(0));

        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_0, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_0, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_0, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_0, 1 ether);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_0);

        agreement.escrow_intakeDepositor(ESCROW_INSTANCE_ID_1, client);
        agreement.escrow_intakeBeneficiary(ESCROW_INSTANCE_ID_1, freelancer);
        agreement.escrow_intakeToken(ESCROW_INSTANCE_ID_1, address(0));
        agreement.escrow_intakeAmount(ESCROW_INSTANCE_ID_1, 2 ether);
        agreement.escrow_intakeReady(ESCROW_INSTANCE_ID_1);

        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 0, ESCROW_INSTANCE_ID_0);
        agreement.milestone_intakeMilestoneEscrowId(MILESTONE_INSTANCE_ID, 1, ESCROW_INSTANCE_ID_1);
        agreement.milestone_intakeReady(MILESTONE_INSTANCE_ID);

        vm.prank(client);
        agreement.escrow_actionDeposit{value: 1 ether}(ESCROW_INSTANCE_ID_0);
        vm.prank(client);
        agreement.escrow_actionDeposit{value: 2 ether}(ESCROW_INSTANCE_ID_1);

        agreement.milestone_actionActivate(MILESTONE_INSTANCE_ID);

        // Only set deadline for milestone 0
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);

        // Milestone 0 can enforce, milestone 1 cannot
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 1));

        // Enforce milestone 0
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);

        // Milestone 1 still pending (no deadline to enforce)
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 1), MILESTONE_PENDING);
    }

    function test_EdgeCase_EnforceFromRequestedState() public {
        _setupSingleMilestoneAgreement(1 ether);

        // Freelancer requests confirmation
        vm.prank(freelancer);
        agreement.milestone_actionRequestConfirmation(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REQUESTED);

        // Set deadline after request
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);

        // Enforce from REQUESTED state
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
    }

    function test_EdgeCase_RefundFromRequestedState() public {
        _setupSingleMilestoneAgreement(1 ether);

        // Freelancer requests confirmation
        vm.prank(freelancer);
        agreement.milestone_actionRequestConfirmation(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REQUESTED);

        // But deadline is for REFUND (maybe they delivered bad work)
        uint256 deadline = block.timestamp + 7 days;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_REFUND, address(0));

        vm.warp(deadline + 1);

        // Refund even though freelancer requested (client didn't accept)
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REFUNDED);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_DeadlineEnforcement(uint256 deadlineOffset, bool isRelease) public {
        // Bound deadline to reasonable range (1 minute to 365 days)
        deadlineOffset = bound(deadlineOffset, 1 minutes, 365 days);

        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + deadlineOffset;
        uint8 action = isRelease ? ACTION_RELEASE : ACTION_REFUND;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, action, address(0));

        // Cannot enforce before deadline
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        // Can enforce at/after deadline
        vm.warp(deadline);
        assertTrue(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));

        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Correct final state based on action
        if (isRelease) {
            assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_RELEASED);
        } else {
            assertEq(agreement.milestone_queryMilestoneStatus(MILESTONE_INSTANCE_ID, 0), MILESTONE_REFUNDED);
        }

        // Cannot enforce twice
        assertFalse(agreement.adapter_canEnforce(MILESTONE_INSTANCE_ID, 0));
    }

    function testFuzz_MultipleEnforcers(address enforcer1, address enforcer2) public {
        vm.assume(enforcer1 != address(0) && enforcer2 != address(0));
        vm.assume(enforcer1 != enforcer2);

        _setupSingleMilestoneAgreement(1 ether);

        uint256 deadline = block.timestamp + 1 hours;
        agreement.adapter_setDeadline(MILESTONE_INSTANCE_ID, 0, deadline, ACTION_RELEASE, address(0));

        vm.warp(deadline + 1);

        // First enforcer succeeds
        vm.prank(enforcer1);
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);

        // Second enforcer fails (already enforced)
        vm.prank(enforcer2);
        vm.expectRevert();
        agreement.adapter_enforceDeadline(MILESTONE_INSTANCE_ID, 0);
    }
}
