// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DeadlineClauseLogicV3} from "../../../src/clauses/state/DeadlineClauseLogicV3.sol";

/// @title MockDeadlineAgreement
/// @notice Simulates an Agreement contract that holds storage for DeadlineClauseLogicV3
contract MockDeadlineAgreement {
    DeadlineClauseLogicV3 public immutable deadlineClause;

    error DelegatecallFailed(bytes data);

    constructor(address _deadlineClause) {
        deadlineClause = DeadlineClauseLogicV3(_deadlineClause);
    }

    // Intake functions
    function deadline_intakeSetDeadline(
        bytes32 targetInstanceId,
        uint256 targetIndex,
        uint256 deadline,
        uint8 action,
        address controller
    ) external {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.intakeSetDeadline,
                (targetInstanceId, targetIndex, deadline, action, controller)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function deadline_intakeModifyDeadline(
        bytes32 targetInstanceId,
        uint256 targetIndex,
        uint256 newDeadline,
        uint8 newAction
    ) external {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.intakeModifyDeadline,
                (targetInstanceId, targetIndex, newDeadline, newAction)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function deadline_intakeClearDeadline(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.intakeClearDeadline,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    // Action functions
    function deadline_actionMarkEnforced(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.actionMarkEnforced,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    // Query functions
    function deadline_queryDeadline(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (uint256 deadline, uint8 action, bool enforced, address controller) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryDeadline,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint256, uint8, bool, address));
    }

    function deadline_queryController(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (address) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryController,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (address));
    }

    function deadline_queryIsImmutable(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (bool) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryIsImmutable,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function deadline_queryIsSet(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (bool) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryIsSet,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function deadline_queryIsExpired(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (bool) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryIsExpired,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function deadline_queryIsEnforced(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (bool) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryIsEnforced,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function deadline_queryCanEnforce(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (bool) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryCanEnforce,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function deadline_queryAction(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (uint8) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryAction,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint8));
    }

    function deadline_queryTimeRemaining(
        bytes32 targetInstanceId,
        uint256 targetIndex
    ) external returns (uint256) {
        (bool success, bytes memory data) = address(deadlineClause).delegatecall(
            abi.encodeCall(
                DeadlineClauseLogicV3.queryTimeRemaining,
                (targetInstanceId, targetIndex)
            )
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint256));
    }
}

contract DeadlineClauseLogicV3Test is Test {
    DeadlineClauseLogicV3 public deadlineClause;
    MockDeadlineAgreement public agreement;

    bytes32 constant INSTANCE_ID = keccak256("test.milestone.instance");
    uint256 constant INDEX_0 = 0;
    uint256 constant INDEX_1 = 1;

    uint8 constant ACTION_NONE = 0;
    uint8 constant ACTION_RELEASE = 1;
    uint8 constant ACTION_REFUND = 2;

    function setUp() public {
        // Deploy the clause implementation
        deadlineClause = new DeadlineClauseLogicV3();
        // Deploy mock agreement that holds storage
        agreement = new MockDeadlineAgreement(address(deadlineClause));
    }

    // =============================================================
    // INTAKE TESTS
    // =============================================================

    function test_IntakeSetDeadline_Success() public {
        uint256 deadline = block.timestamp + 7 days;

        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        (uint256 d, uint8 a, bool e,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        assertEq(d, deadline);
        assertEq(a, ACTION_RELEASE);
        assertFalse(e);
    }

    function test_IntakeSetDeadline_RefundAction() public {
        uint256 deadline = block.timestamp + 30 days;

        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_REFUND, address(0));

        (uint256 d, uint8 a, bool e,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        assertEq(d, deadline);
        assertEq(a, ACTION_REFUND);
        assertFalse(e);
    }

    function test_IntakeSetDeadline_MultipleMilestones() public {
        uint256 deadline1 = block.timestamp + 7 days;
        uint256 deadline2 = block.timestamp + 14 days;

        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline1, ACTION_RELEASE, address(0));
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_1, deadline2, ACTION_REFUND, address(0));

        (uint256 d1, uint8 a1,,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        (uint256 d2, uint8 a2,,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_1);

        assertEq(d1, deadline1);
        assertEq(a1, ACTION_RELEASE);
        assertEq(d2, deadline2);
        assertEq(a2, ACTION_REFUND);
    }

    function test_IntakeSetDeadline_RevertInvalidDeadline() public {
        vm.expectRevert(); // DelegatecallFailed wraps InvalidDeadline
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, 0, ACTION_RELEASE, address(0));
    }

    function test_IntakeSetDeadline_RevertDeadlineInPast() public {
        uint256 pastDeadline = block.timestamp - 1;
        vm.expectRevert(); // DelegatecallFailed wraps DeadlineInPast
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, pastDeadline, ACTION_RELEASE, address(0));
    }

    function test_IntakeSetDeadline_RevertInvalidAction() public {
        uint256 deadline = block.timestamp + 7 days;
        vm.expectRevert(); // DelegatecallFailed wraps InvalidAction
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, 3, address(0));
    }

    function test_IntakeSetDeadline_RevertAlreadySet() public {
        // With new authorization model, cannot call setDeadline twice
        uint256 deadline1 = block.timestamp + 7 days;
        uint256 deadline2 = block.timestamp + 14 days;

        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline1, ACTION_RELEASE, address(0));

        // Second setDeadline should revert with DeadlineAlreadySet
        vm.expectRevert();
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline2, ACTION_REFUND, address(0));
    }

    function test_IntakeModifyDeadline_WithController() public {
        // Set deadline with controller (msg.sender is agreement in delegatecall context)
        // But since we're calling through the MockAgreement, msg.sender is this test contract
        // For this test we need to set controller to the address that will call modifyDeadline
        address controller = address(this);
        uint256 deadline1 = block.timestamp + 7 days;
        uint256 deadline2 = block.timestamp + 14 days;

        // Set with non-zero controller so it can be modified
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline1, ACTION_RELEASE, controller);

        // Modify the deadline (will be called by test contract which is the controller)
        agreement.deadline_intakeModifyDeadline(INSTANCE_ID, INDEX_0, deadline2, ACTION_REFUND);

        (uint256 d, uint8 a,,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        assertEq(d, deadline2);
        assertEq(a, ACTION_REFUND);
    }

    function test_IntakeClearDeadline_Success() public {
        // Need a controller to clear - immutable deadlines cannot be cleared
        address controller = address(this);
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, controller);

        agreement.deadline_intakeClearDeadline(INSTANCE_ID, INDEX_0);

        (uint256 d, uint8 a,,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        assertEq(d, 0);
        assertEq(a, ACTION_NONE);
    }

    function test_IntakeClearDeadline_RevertImmutable() public {
        // Deadline with address(0) controller is immutable
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        vm.expectRevert(); // DelegatecallFailed wraps DeadlineImmutable
        agreement.deadline_intakeClearDeadline(INSTANCE_ID, INDEX_0);
    }

    function test_IntakeClearDeadline_RevertNotSet() public {
        vm.expectRevert(); // DelegatecallFailed wraps DeadlineNotSet
        agreement.deadline_intakeClearDeadline(INSTANCE_ID, INDEX_0);
    }

    // =============================================================
    // ACTION TESTS
    // =============================================================

    function test_ActionMarkEnforced_Success() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        // Advance time past deadline
        vm.warp(deadline + 1);

        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);

        (,, bool enforced,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        assertTrue(enforced);
    }

    function test_ActionMarkEnforced_RevertNotSet() public {
        vm.expectRevert(); // DelegatecallFailed wraps DeadlineNotSet
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);
    }

    function test_ActionMarkEnforced_RevertNotExpired() public {
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        vm.expectRevert(); // DelegatecallFailed wraps DeadlineNotExpired
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);
    }

    function test_ActionMarkEnforced_RevertAlreadyEnforced() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 1);
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);

        vm.expectRevert(); // DelegatecallFailed wraps DeadlineAlreadyEnforced
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);
    }

    function test_IntakeSetDeadline_RevertAfterEnforced() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 1);
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);

        // Try to set a new deadline after enforcement
        vm.expectRevert(); // DelegatecallFailed wraps DeadlineAlreadyEnforced
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, block.timestamp + 7 days, ACTION_REFUND, address(0));
    }

    function test_IntakeClearDeadline_RevertAfterEnforced() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 1);
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);

        vm.expectRevert(); // DelegatecallFailed wraps DeadlineAlreadyEnforced
        agreement.deadline_intakeClearDeadline(INSTANCE_ID, INDEX_0);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryIsSet_NotSet() public {
        assertFalse(agreement.deadline_queryIsSet(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsSet_Set() public {
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, block.timestamp + 1 hours, ACTION_RELEASE, address(0));
        assertTrue(agreement.deadline_queryIsSet(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsExpired_NotSet() public {
        assertFalse(agreement.deadline_queryIsExpired(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsExpired_NotYetExpired() public {
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, block.timestamp + 1 hours, ACTION_RELEASE, address(0));
        assertFalse(agreement.deadline_queryIsExpired(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsExpired_JustExpired() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline);
        assertTrue(agreement.deadline_queryIsExpired(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsExpired_WellPastDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 100 days);
        assertTrue(agreement.deadline_queryIsExpired(INSTANCE_ID, INDEX_0));
    }

    function test_QueryCanEnforce_NotSet() public {
        assertFalse(agreement.deadline_queryCanEnforce(INSTANCE_ID, INDEX_0));
    }

    function test_QueryCanEnforce_NotExpired() public {
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, block.timestamp + 7 days, ACTION_RELEASE, address(0));
        assertFalse(agreement.deadline_queryCanEnforce(INSTANCE_ID, INDEX_0));
    }

    function test_QueryCanEnforce_ExpiredNotEnforced() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 1);
        assertTrue(agreement.deadline_queryCanEnforce(INSTANCE_ID, INDEX_0));
    }

    function test_QueryCanEnforce_AlreadyEnforced() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 1);
        agreement.deadline_actionMarkEnforced(INSTANCE_ID, INDEX_0);
        assertFalse(agreement.deadline_queryCanEnforce(INSTANCE_ID, INDEX_0));
    }

    function test_QueryTimeRemaining_NotSet() public {
        assertEq(agreement.deadline_queryTimeRemaining(INSTANCE_ID, INDEX_0), 0);
    }

    function test_QueryTimeRemaining_HasTime() public {
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        assertEq(agreement.deadline_queryTimeRemaining(INSTANCE_ID, INDEX_0), 7 days);
    }

    function test_QueryTimeRemaining_PartialTime() public {
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(block.timestamp + 3 days);
        assertEq(agreement.deadline_queryTimeRemaining(INSTANCE_ID, INDEX_0), 4 days);
    }

    function test_QueryTimeRemaining_Expired() public {
        uint256 deadline = block.timestamp + 1 hours;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));
        vm.warp(deadline + 1);
        assertEq(agreement.deadline_queryTimeRemaining(INSTANCE_ID, INDEX_0), 0);
    }

    // =============================================================
    // AUTHORIZATION TESTS
    // =============================================================

    function test_ModifyDeadline_RevertWrongController() public {
        address controller = address(0x1234);
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, controller);

        // Try to modify as non-controller (msg.sender is this test contract, not controller)
        vm.expectRevert(); // DelegatecallFailed wraps OnlyController
        agreement.deadline_intakeModifyDeadline(INSTANCE_ID, INDEX_0, block.timestamp + 14 days, ACTION_REFUND);
    }

    function test_ModifyDeadline_RevertImmutable() public {
        // Immutable deadline (controller = address(0))
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        vm.expectRevert(); // DelegatecallFailed wraps DeadlineImmutable
        agreement.deadline_intakeModifyDeadline(INSTANCE_ID, INDEX_0, block.timestamp + 14 days, ACTION_REFUND);
    }

    function test_QueryController_ReturnsCorrect() public {
        address controller = address(0x5678);
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, controller);

        assertEq(agreement.deadline_queryController(INSTANCE_ID, INDEX_0), controller);
    }

    function test_QueryController_ReturnsZeroForImmutable() public {
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        assertEq(agreement.deadline_queryController(INSTANCE_ID, INDEX_0), address(0));
    }

    function test_QueryIsImmutable_TrueForZeroController() public {
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        assertTrue(agreement.deadline_queryIsImmutable(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsImmutable_FalseForNonZeroController() public {
        address controller = address(0x9ABC);
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, controller);

        assertFalse(agreement.deadline_queryIsImmutable(INSTANCE_ID, INDEX_0));
    }

    function test_QueryIsImmutable_FalseForNotSet() public {
        // Not set deadlines return false (not immutable, just doesn't exist)
        assertFalse(agreement.deadline_queryIsImmutable(INSTANCE_ID, INDEX_0));
    }

    function test_ClearDeadline_RevertWrongController() public {
        address controller = address(0xDEAD);
        uint256 deadline = block.timestamp + 7 days;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, controller);

        // Try to clear as non-controller
        vm.expectRevert(); // DelegatecallFailed wraps OnlyController
        agreement.deadline_intakeClearDeadline(INSTANCE_ID, INDEX_0);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_IntakeSetDeadline(uint256 offset, uint8 actionType) public {
        vm.assume(offset > 0 && offset < 365 days);
        actionType = uint8(bound(actionType, 1, 2)); // ACTION_RELEASE or ACTION_REFUND

        uint256 deadline = block.timestamp + offset;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, actionType, address(0));

        (uint256 d, uint8 a, bool e,) = agreement.deadline_queryDeadline(INSTANCE_ID, INDEX_0);
        assertEq(d, deadline);
        assertEq(a, actionType);
        assertFalse(e);
    }

    function testFuzz_TimeRemaining(uint256 offset, uint256 elapsed) public {
        vm.assume(offset > 0 && offset < 365 days);
        vm.assume(elapsed <= offset);

        uint256 deadline = block.timestamp + offset;
        agreement.deadline_intakeSetDeadline(INSTANCE_ID, INDEX_0, deadline, ACTION_RELEASE, address(0));

        vm.warp(block.timestamp + elapsed);

        uint256 remaining = agreement.deadline_queryTimeRemaining(INSTANCE_ID, INDEX_0);
        assertEq(remaining, offset - elapsed);
    }
}
