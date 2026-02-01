// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MilestoneClauseLogicV3} from "../../../src/clauses/orchestration/MilestoneClauseLogicV3.sol";

/// @title MilestoneClauseLogicV3 Test Suite
/// @notice Comprehensive tests including unit, fuzz, and invariant tests
contract MilestoneClauseLogicV3Test is Test {
    MilestoneClauseLogicV3 public milestone;

    address public beneficiary = address(0x1);
    address public client = address(0x2);
    address public arbitrator = address(0x3);
    address public randomUser = address(0x4);

    bytes32 public instanceId = keccak256("test-instance");
    bytes32 public descriptionHash1 = keccak256("milestone-1");
    bytes32 public descriptionHash2 = keccak256("milestone-2");
    bytes32 public descriptionHash3 = keccak256("milestone-3");

    bytes32 public escrowId1 = keccak256("escrow-1");
    bytes32 public escrowId2 = keccak256("escrow-2");
    bytes32 public escrowId3 = keccak256("escrow-3");

    // State constants
    uint16 constant PENDING = 1 << 1; // 0x0002
    uint16 constant COMPLETE = 1 << 2; // 0x0004
    uint16 constant CANCELLED = 1 << 3; // 0x0008
    uint16 constant ACTIVE = 1 << 4; // 0x0010
    uint16 constant DISPUTED = 1 << 5; // 0x0020

    // Milestone state constants
    uint8 constant MILESTONE_NONE = 0;
    uint8 constant MILESTONE_PENDING = 1;
    uint8 constant MILESTONE_REQUESTED = 2;
    uint8 constant MILESTONE_CONFIRMED = 3;
    uint8 constant MILESTONE_DISPUTED = 4;
    uint8 constant MILESTONE_RELEASED = 5;
    uint8 constant MILESTONE_REFUNDED = 6;

    function setUp() public {
        milestone = new MilestoneClauseLogicV3();
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _setupBasicMilestones() internal {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);
        milestone.intakeMilestone(instanceId, descriptionHash2, 2000);
        milestone.intakeMilestone(instanceId, descriptionHash3, 3000);
        milestone.intakeBeneficiary(instanceId, beneficiary);
        milestone.intakeClient(instanceId, client);
    }

    function _setupAndReady() internal {
        _setupBasicMilestones();
        milestone.intakeReady(instanceId);
    }

    function _setupAndActivate() internal {
        _setupAndReady();
        milestone.intakeMilestoneEscrowId(instanceId, 0, escrowId1);
        milestone.intakeMilestoneEscrowId(instanceId, 1, escrowId2);
        milestone.intakeMilestoneEscrowId(instanceId, 2, escrowId3);
        milestone.actionActivate(instanceId);
    }

    // =============================================================
    // UNIT TESTS: INTAKE FUNCTIONS
    // =============================================================

    function test_intakeMilestone_basic() public {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);

        assertEq(milestone.queryMilestoneCount(instanceId), 1);
        (bytes32 desc, uint256 amount,,,,) = milestone.queryMilestone(instanceId, 0);
        assertEq(desc, descriptionHash1);
        assertEq(amount, 1000);
    }

    function test_intakeMilestone_multiple() public {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);
        milestone.intakeMilestone(instanceId, descriptionHash2, 2000);
        milestone.intakeMilestone(instanceId, descriptionHash3, 3000);

        assertEq(milestone.queryMilestoneCount(instanceId), 3);
        assertEq(milestone.queryTotalAmount(instanceId), 6000);
    }

    function test_intakeMilestone_revertsIfZeroAmount() public {
        vm.expectRevert(MilestoneClauseLogicV3.ZeroAmount.selector);
        milestone.intakeMilestone(instanceId, descriptionHash1, 0);
    }

    function test_intakeMilestone_revertsIfTooMany() public {
        for (uint256 i = 0; i < 20; i++) {
            milestone.intakeMilestone(instanceId, bytes32(i), 100);
        }

        vm.expectRevert(abi.encodeWithSelector(MilestoneClauseLogicV3.TooManyMilestones.selector, 21, 20));
        milestone.intakeMilestone(instanceId, bytes32(uint256(20)), 100);
    }

    function test_intakeMilestone_revertsIfAlreadyReady() public {
        _setupAndReady();

        vm.expectRevert("Wrong state");
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);
    }

    function test_intakeBeneficiary_basic() public {
        milestone.intakeBeneficiary(instanceId, beneficiary);
        assertEq(milestone.queryBeneficiary(instanceId), beneficiary);
    }

    function test_intakeBeneficiary_revertsIfZeroAddress() public {
        vm.expectRevert(MilestoneClauseLogicV3.ZeroAddress.selector);
        milestone.intakeBeneficiary(instanceId, address(0));
    }

    function test_intakeClient_basic() public {
        milestone.intakeClient(instanceId, client);
        assertEq(milestone.queryClient(instanceId), client);
    }

    function test_intakeClient_revertsIfZeroAddress() public {
        vm.expectRevert(MilestoneClauseLogicV3.ZeroAddress.selector);
        milestone.intakeClient(instanceId, address(0));
    }

    function test_intakeToken_basic() public {
        address token = address(0x123);
        milestone.intakeToken(instanceId, token);
        assertEq(milestone.queryToken(instanceId), token);
    }

    function test_intakeToken_ethAsZeroAddress() public {
        milestone.intakeToken(instanceId, address(0));
        assertEq(milestone.queryToken(instanceId), address(0));
    }

    function test_intakeMilestoneEscrowId_inUninitialized() public {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);
        milestone.intakeMilestoneEscrowId(instanceId, 0, escrowId1);

        assertEq(milestone.queryMilestoneEscrowId(instanceId, 0), escrowId1);
    }

    function test_intakeMilestoneEscrowId_inPending() public {
        _setupAndReady();
        milestone.intakeMilestoneEscrowId(instanceId, 0, escrowId1);

        assertEq(milestone.queryMilestoneEscrowId(instanceId, 0), escrowId1);
    }

    function test_intakeMilestoneEscrowId_revertsIfInvalidIndex() public {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);

        vm.expectRevert(abi.encodeWithSelector(MilestoneClauseLogicV3.InvalidMilestoneIndex.selector, 5, 1));
        milestone.intakeMilestoneEscrowId(instanceId, 5, escrowId1);
    }

    function test_intakeReady_basic() public {
        _setupBasicMilestones();
        milestone.intakeReady(instanceId);

        assertEq(milestone.queryStatus(instanceId), PENDING);
        // All milestones should be in PENDING state
        for (uint256 i = 0; i < 3; i++) {
            assertEq(milestone.queryMilestoneStatus(instanceId, i), MILESTONE_PENDING);
        }
    }

    function test_intakeReady_revertsIfNoBeneficiary() public {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);
        milestone.intakeClient(instanceId, client);

        vm.expectRevert("No beneficiary");
        milestone.intakeReady(instanceId);
    }

    function test_intakeReady_revertsIfNoClient() public {
        milestone.intakeMilestone(instanceId, descriptionHash1, 1000);
        milestone.intakeBeneficiary(instanceId, beneficiary);

        vm.expectRevert("No client");
        milestone.intakeReady(instanceId);
    }

    function test_intakeReady_revertsIfNoMilestones() public {
        milestone.intakeBeneficiary(instanceId, beneficiary);
        milestone.intakeClient(instanceId, client);

        vm.expectRevert("No milestones");
        milestone.intakeReady(instanceId);
    }

    // =============================================================
    // UNIT TESTS: ACTION FUNCTIONS
    // =============================================================

    function test_actionActivate_basic() public {
        _setupAndReady();
        milestone.intakeMilestoneEscrowId(instanceId, 0, escrowId1);
        milestone.intakeMilestoneEscrowId(instanceId, 1, escrowId2);
        milestone.intakeMilestoneEscrowId(instanceId, 2, escrowId3);

        milestone.actionActivate(instanceId);

        assertEq(milestone.queryStatus(instanceId), ACTIVE);
        assertTrue(milestone.queryIsActive(instanceId));
    }

    function test_actionActivate_revertsIfNotPending() public {
        _setupBasicMilestones();

        vm.expectRevert("Wrong state");
        milestone.actionActivate(instanceId);
    }

    function test_actionActivate_revertsIfEscrowNotLinked() public {
        _setupAndReady();
        milestone.intakeMilestoneEscrowId(instanceId, 0, escrowId1);
        // Missing escrow for milestone 1 and 2

        vm.expectRevert(abi.encodeWithSelector(MilestoneClauseLogicV3.EscrowNotLinked.selector, 1));
        milestone.actionActivate(instanceId);
    }

    function test_actionRequestConfirmation_basic() public {
        _setupAndActivate();

        vm.prank(beneficiary);
        milestone.actionRequestConfirmation(instanceId, 0);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_REQUESTED);
    }

    function test_actionRequestConfirmation_revertsIfNotBeneficiary() public {
        _setupAndActivate();

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(MilestoneClauseLogicV3.NotBeneficiary.selector, client, beneficiary));
        milestone.actionRequestConfirmation(instanceId, 0);
    }

    function test_actionRequestConfirmation_revertsIfInvalidIndex() public {
        _setupAndActivate();

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(MilestoneClauseLogicV3.InvalidMilestoneIndex.selector, 10, 3));
        milestone.actionRequestConfirmation(instanceId, 10);
    }

    function test_actionRequestConfirmation_revertsIfNotPending() public {
        _setupAndActivate();

        vm.prank(beneficiary);
        milestone.actionRequestConfirmation(instanceId, 0);

        // Already requested, can't request again
        vm.prank(beneficiary);
        vm.expectRevert(
            abi.encodeWithSelector(
                MilestoneClauseLogicV3.WrongMilestoneState.selector, MILESTONE_PENDING, MILESTONE_REQUESTED
            )
        );
        milestone.actionRequestConfirmation(instanceId, 0);
    }

    function test_actionConfirm_fromPending() public {
        _setupAndActivate();

        // Client can confirm directly without freelancer requesting
        vm.prank(client);
        milestone.actionConfirm(instanceId, 0);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_CONFIRMED);
        assertTrue(milestone.queryIsMilestoneReadyForRelease(instanceId, 0));
    }

    function test_actionConfirm_fromRequested() public {
        _setupAndActivate();

        vm.prank(beneficiary);
        milestone.actionRequestConfirmation(instanceId, 0);

        vm.prank(client);
        milestone.actionConfirm(instanceId, 0);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_CONFIRMED);
    }

    function test_actionConfirm_revertsIfNotClient() public {
        _setupAndActivate();

        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(MilestoneClauseLogicV3.NotClient.selector, beneficiary, client));
        milestone.actionConfirm(instanceId, 0);
    }

    function test_actionMarkReleased_basic() public {
        _setupAndActivate();

        vm.prank(client);
        milestone.actionConfirm(instanceId, 0);

        milestone.actionMarkReleased(instanceId, 0);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_RELEASED);
        assertEq(milestone.queryReleasedCount(instanceId), 1);
        assertEq(milestone.queryTotalReleased(instanceId), 1000);
    }

    function test_actionMarkReleased_completesWhenAllReleased() public {
        _setupAndActivate();

        // Confirm and release all milestones
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            milestone.actionConfirm(instanceId, i);
            milestone.actionMarkReleased(instanceId, i);
        }

        assertEq(milestone.queryStatus(instanceId), COMPLETE);
        assertTrue(milestone.queryIsComplete(instanceId));
        assertEq(milestone.queryTotalReleased(instanceId), 6000);
    }

    function test_actionMarkRefunded_basic() public {
        _setupAndActivate();

        milestone.actionMarkRefunded(instanceId, 0);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_REFUNDED);
    }

    function test_actionDispute_byClient() public {
        _setupAndActivate();

        bytes32 reason = keccak256("Work not delivered");

        vm.prank(client);
        milestone.actionDispute(instanceId, 0, reason);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_DISPUTED);
        assertEq(milestone.queryStatus(instanceId), DISPUTED);
        assertTrue(milestone.queryIsDisputed(instanceId));
    }

    function test_actionDispute_byBeneficiary() public {
        _setupAndActivate();

        bytes32 reason = keccak256("Client unresponsive");

        vm.prank(beneficiary);
        milestone.actionDispute(instanceId, 0, reason);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_DISPUTED);
        assertEq(milestone.queryStatus(instanceId), DISPUTED);
    }

    function test_actionDispute_revertsIfNotParty() public {
        _setupAndActivate();

        vm.prank(randomUser);
        vm.expectRevert("Not a party");
        milestone.actionDispute(instanceId, 0, keccak256("reason"));
    }

    function test_actionResolveDispute_releaseTobeneficiary() public {
        _setupAndActivate();

        vm.prank(client);
        milestone.actionDispute(instanceId, 0, keccak256("reason"));

        milestone.actionResolveDispute(instanceId, 0, true);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_CONFIRMED);
        // No more disputed milestones, should return to ACTIVE
        assertEq(milestone.queryStatus(instanceId), ACTIVE);
    }

    function test_actionResolveDispute_refund() public {
        _setupAndActivate();

        vm.prank(client);
        milestone.actionDispute(instanceId, 0, keccak256("reason"));

        milestone.actionResolveDispute(instanceId, 0, false);

        assertEq(milestone.queryMilestoneStatus(instanceId, 0), MILESTONE_REFUNDED);
        assertEq(milestone.queryStatus(instanceId), ACTIVE);
    }

    function test_actionResolveDispute_multipleDisputes() public {
        _setupAndActivate();

        // Dispute two milestones
        vm.prank(client);
        milestone.actionDispute(instanceId, 0, keccak256("reason1"));
        vm.prank(client);
        milestone.actionDispute(instanceId, 1, keccak256("reason2"));

        assertEq(milestone.queryStatus(instanceId), DISPUTED);

        // Resolve first dispute
        milestone.actionResolveDispute(instanceId, 0, true);
        // Still disputed because milestone 1 is still disputed
        assertEq(milestone.queryStatus(instanceId), DISPUTED);

        // Resolve second dispute
        milestone.actionResolveDispute(instanceId, 1, true);
        // Now should be ACTIVE
        assertEq(milestone.queryStatus(instanceId), ACTIVE);
    }

    function test_actionCancel_byClient() public {
        _setupAndReady();

        vm.prank(client);
        milestone.actionCancel(instanceId);

        assertEq(milestone.queryStatus(instanceId), CANCELLED);
    }

    function test_actionCancel_byBeneficiary() public {
        _setupAndReady();

        vm.prank(beneficiary);
        milestone.actionCancel(instanceId);

        assertEq(milestone.queryStatus(instanceId), CANCELLED);
    }

    function test_actionCancel_revertsIfActive() public {
        _setupAndActivate();

        vm.prank(client);
        vm.expectRevert("Wrong state");
        milestone.actionCancel(instanceId);
    }

    function test_actionCancel_revertsIfNotParty() public {
        _setupAndReady();

        vm.prank(randomUser);
        vm.expectRevert("Not a party");
        milestone.actionCancel(instanceId);
    }

    // =============================================================
    // UNIT TESTS: HANDOFF FUNCTIONS
    // =============================================================

    function test_handoffTotalReleased_afterComplete() public {
        _setupAndActivate();

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            milestone.actionConfirm(instanceId, i);
            milestone.actionMarkReleased(instanceId, i);
        }

        assertEq(milestone.handoffTotalReleased(instanceId), 6000);
    }

    function test_handoffTotalReleased_revertsIfNotComplete() public {
        _setupAndActivate();

        vm.expectRevert("Wrong state");
        milestone.handoffTotalReleased(instanceId);
    }

    function test_handoffBeneficiary_afterComplete() public {
        _setupAndActivate();

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            milestone.actionConfirm(instanceId, i);
            milestone.actionMarkReleased(instanceId, i);
        }

        assertEq(milestone.handoffBeneficiary(instanceId), beneficiary);
    }

    function test_handoffMilestoneEscrowId_afterConfirm() public {
        _setupAndActivate();

        vm.prank(client);
        milestone.actionConfirm(instanceId, 0);

        assertEq(milestone.handoffMilestoneEscrowId(instanceId, 0), escrowId1);
    }

    function test_handoffMilestoneEscrowId_revertsIfNotConfirmed() public {
        _setupAndActivate();

        vm.expectRevert("Wrong milestone state");
        milestone.handoffMilestoneEscrowId(instanceId, 0);
    }

    // =============================================================
    // UNIT TESTS: QUERY FUNCTIONS
    // =============================================================

    function test_queryMilestone_returnsAllFields() public {
        _setupAndActivate();

        vm.prank(client);
        milestone.actionConfirm(instanceId, 0);

        (bytes32 desc, uint256 amount, bytes32 escrowId, uint8 status, uint256 confirmedAt, uint256 releasedAt) =
            milestone.queryMilestone(instanceId, 0);

        assertEq(desc, descriptionHash1);
        assertEq(amount, 1000);
        assertEq(escrowId, escrowId1);
        assertEq(status, MILESTONE_CONFIRMED);
        assertGt(confirmedAt, 0);
        assertEq(releasedAt, 0);
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_instanceIsolation() public {
        bytes32 instance1 = keccak256("instance-1");
        bytes32 instance2 = keccak256("instance-2");

        // Setup instance 1
        milestone.intakeMilestone(instance1, descriptionHash1, 1000);
        milestone.intakeBeneficiary(instance1, beneficiary);
        milestone.intakeClient(instance1, client);
        milestone.intakeReady(instance1);

        // Setup instance 2 with different values
        milestone.intakeMilestone(instance2, descriptionHash2, 5000);
        milestone.intakeMilestone(instance2, descriptionHash3, 7000);
        milestone.intakeBeneficiary(instance2, address(0x5));
        milestone.intakeClient(instance2, address(0x6));
        milestone.intakeReady(instance2);

        // Verify isolation
        assertEq(milestone.queryMilestoneCount(instance1), 1);
        assertEq(milestone.queryMilestoneCount(instance2), 2);
        assertEq(milestone.queryTotalAmount(instance1), 1000);
        assertEq(milestone.queryTotalAmount(instance2), 12000);
        assertEq(milestone.queryBeneficiary(instance1), beneficiary);
        assertEq(milestone.queryBeneficiary(instance2), address(0x5));
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_intakeMilestone_anyAmount(uint256 amount) public {
        vm.assume(amount > 0);

        milestone.intakeMilestone(instanceId, descriptionHash1, amount);

        (, uint256 storedAmount,,,,) = milestone.queryMilestone(instanceId, 0);
        assertEq(storedAmount, amount);
    }

    function testFuzz_intakeMilestone_anyDescription(bytes32 desc) public {
        milestone.intakeMilestone(instanceId, desc, 1000);

        (bytes32 storedDesc,,,,,) = milestone.queryMilestone(instanceId, 0);
        assertEq(storedDesc, desc);
    }

    function testFuzz_intakeBeneficiary_anyAddress(address _beneficiary) public {
        vm.assume(_beneficiary != address(0));

        milestone.intakeBeneficiary(instanceId, _beneficiary);
        assertEq(milestone.queryBeneficiary(instanceId), _beneficiary);
    }

    function testFuzz_intakeClient_anyAddress(address _client) public {
        vm.assume(_client != address(0));

        milestone.intakeClient(instanceId, _client);
        assertEq(milestone.queryClient(instanceId), _client);
    }

    function testFuzz_queryTotalAmount_multiMilestones(uint128 amount1, uint128 amount2, uint128 amount3) public {
        vm.assume(amount1 > 0 && amount2 > 0 && amount3 > 0);

        milestone.intakeMilestone(instanceId, descriptionHash1, amount1);
        milestone.intakeMilestone(instanceId, descriptionHash2, amount2);
        milestone.intakeMilestone(instanceId, descriptionHash3, amount3);

        uint256 expectedTotal = uint256(amount1) + uint256(amount2) + uint256(amount3);
        assertEq(milestone.queryTotalAmount(instanceId), expectedTotal);
    }

    function testFuzz_instanceId_isolation(bytes32 id1, bytes32 id2) public {
        vm.assume(id1 != id2);

        milestone.intakeMilestone(id1, descriptionHash1, 1000);
        milestone.intakeMilestone(id2, descriptionHash2, 5000);

        assertEq(milestone.queryMilestoneCount(id1), 1);
        assertEq(milestone.queryMilestoneCount(id2), 1);
        assertEq(milestone.queryTotalAmount(id1), 1000);
        assertEq(milestone.queryTotalAmount(id2), 5000);
    }

    function testFuzz_fullWorkflow(address _beneficiary, address _client, uint128 amount) public {
        vm.assume(_beneficiary != address(0));
        vm.assume(_client != address(0));
        vm.assume(_beneficiary != _client);
        vm.assume(amount > 0);

        bytes32 id = keccak256(abi.encode(_beneficiary, _client, amount));

        // Setup
        milestone.intakeMilestone(id, descriptionHash1, amount);
        milestone.intakeBeneficiary(id, _beneficiary);
        milestone.intakeClient(id, _client);
        milestone.intakeReady(id);

        assertEq(milestone.queryStatus(id), PENDING);

        // Link escrow and activate
        milestone.intakeMilestoneEscrowId(id, 0, escrowId1);
        milestone.actionActivate(id);

        assertEq(milestone.queryStatus(id), ACTIVE);

        // Request and confirm
        vm.prank(_beneficiary);
        milestone.actionRequestConfirmation(id, 0);

        vm.prank(_client);
        milestone.actionConfirm(id, 0);

        // Mark released
        milestone.actionMarkReleased(id, 0);

        assertEq(milestone.queryStatus(id), COMPLETE);
        assertEq(milestone.queryTotalReleased(id), amount);
    }

    // =============================================================
    // INVARIANT TESTS
    // =============================================================

    /// @notice Handler contract for invariant testing
    MilestoneInvariantHandler public handler;

    function setUp_invariants() internal {
        handler = new MilestoneInvariantHandler(milestone);
        targetContract(address(handler));
    }

    function invariant_releasedCountNeverExceedsMilestoneCount() public view {
        uint256 count = milestone.queryMilestoneCount(instanceId);
        uint256 released = milestone.queryReleasedCount(instanceId);
        assertTrue(released <= count);
    }

    function invariant_totalReleasedMatchesSumOfReleased() public view {
        uint256 count = milestone.queryMilestoneCount(instanceId);
        uint256 sumReleased = 0;

        for (uint256 i = 0; i < count; i++) {
            uint8 status = milestone.queryMilestoneStatus(instanceId, i);
            if (status == MILESTONE_RELEASED) {
                (, uint256 amount,,,,) = milestone.queryMilestone(instanceId, i);
                sumReleased += amount;
            }
        }

        assertEq(milestone.queryTotalReleased(instanceId), sumReleased);
    }

    // =============================================================
    // EDGE CASE TESTS
    // =============================================================

    function test_singleMilestone_workflow() public {
        bytes32 id = keccak256("single");

        milestone.intakeMilestone(id, descriptionHash1, 1 ether);
        milestone.intakeBeneficiary(id, beneficiary);
        milestone.intakeClient(id, client);
        milestone.intakeReady(id);

        milestone.intakeMilestoneEscrowId(id, 0, escrowId1);
        milestone.actionActivate(id);

        vm.prank(client);
        milestone.actionConfirm(id, 0);

        milestone.actionMarkReleased(id, 0);

        assertTrue(milestone.queryIsComplete(id));
        assertEq(milestone.queryTotalReleased(id), 1 ether);
    }

    function test_maxMilestones_workflow() public {
        bytes32 id = keccak256("max-milestones");

        // Add maximum number of milestones
        for (uint256 i = 0; i < 20; i++) {
            milestone.intakeMilestone(id, bytes32(i), 100 * (i + 1));
        }

        milestone.intakeBeneficiary(id, beneficiary);
        milestone.intakeClient(id, client);
        milestone.intakeReady(id);

        // Link all escrows
        for (uint256 i = 0; i < 20; i++) {
            milestone.intakeMilestoneEscrowId(id, i, bytes32(uint256(100 + i)));
        }

        milestone.actionActivate(id);

        // Confirm and release all
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < 20; i++) {
            vm.prank(client);
            milestone.actionConfirm(id, i);
            milestone.actionMarkReleased(id, i);
            expectedTotal += 100 * (i + 1);
        }

        assertTrue(milestone.queryIsComplete(id));
        assertEq(milestone.queryTotalReleased(id), expectedTotal);
    }

    function test_partialCompletion_withDispute() public {
        _setupAndActivate();

        // Confirm and release first milestone
        vm.prank(client);
        milestone.actionConfirm(instanceId, 0);
        milestone.actionMarkReleased(instanceId, 0);

        // Dispute second milestone
        vm.prank(beneficiary);
        milestone.actionDispute(instanceId, 1, keccak256("dispute reason"));

        assertEq(milestone.queryStatus(instanceId), DISPUTED);
        assertEq(milestone.queryReleasedCount(instanceId), 1);
        assertEq(milestone.queryTotalReleased(instanceId), 1000);

        // Resolve dispute with refund
        milestone.actionResolveDispute(instanceId, 1, false);

        // Should be back to ACTIVE
        assertEq(milestone.queryStatus(instanceId), ACTIVE);

        // Complete remaining milestone
        vm.prank(client);
        milestone.actionConfirm(instanceId, 2);
        milestone.actionMarkReleased(instanceId, 2);

        // Not complete because milestone 1 was refunded, not released
        assertEq(milestone.queryStatus(instanceId), ACTIVE);
        assertEq(milestone.queryReleasedCount(instanceId), 2);
        assertEq(milestone.queryTotalReleased(instanceId), 4000); // 1000 + 3000
    }
}

/// @title Handler contract for invariant testing
contract MilestoneInvariantHandler is Test {
    MilestoneClauseLogicV3 public milestone;
    bytes32 public instanceId = keccak256("invariant-test");

    address public beneficiary = address(0x1);
    address public client = address(0x2);

    bool public isSetup;
    bool public isActive;
    uint256 public milestoneCount;

    constructor(MilestoneClauseLogicV3 _milestone) {
        milestone = _milestone;
    }

    function setup() external {
        if (isSetup) return;

        milestone.intakeMilestone(instanceId, bytes32(uint256(1)), 1000);
        milestone.intakeMilestone(instanceId, bytes32(uint256(2)), 2000);
        milestone.intakeMilestone(instanceId, bytes32(uint256(3)), 3000);
        milestone.intakeBeneficiary(instanceId, beneficiary);
        milestone.intakeClient(instanceId, client);
        milestone.intakeReady(instanceId);

        milestone.intakeMilestoneEscrowId(instanceId, 0, bytes32(uint256(100)));
        milestone.intakeMilestoneEscrowId(instanceId, 1, bytes32(uint256(101)));
        milestone.intakeMilestoneEscrowId(instanceId, 2, bytes32(uint256(102)));
        milestone.actionActivate(instanceId);

        isSetup = true;
        isActive = true;
        milestoneCount = 3;
    }

    function requestConfirmation(uint256 indexSeed) external {
        if (!isActive) return;

        uint256 index = indexSeed % milestoneCount;
        uint8 status = milestone.queryMilestoneStatus(instanceId, index);

        if (status == 1) {
            // MILESTONE_PENDING
            vm.prank(beneficiary);
            milestone.actionRequestConfirmation(instanceId, index);
        }
    }

    function confirm(uint256 indexSeed) external {
        if (!isActive) return;

        uint256 index = indexSeed % milestoneCount;
        uint8 status = milestone.queryMilestoneStatus(instanceId, index);

        if (status == 1 || status == 2) {
            // PENDING or REQUESTED
            vm.prank(client);
            milestone.actionConfirm(instanceId, index);
        }
    }

    function markReleased(uint256 indexSeed) external {
        if (!isActive) return;

        uint256 index = indexSeed % milestoneCount;
        uint8 status = milestone.queryMilestoneStatus(instanceId, index);

        if (status == 3) {
            // CONFIRMED
            milestone.actionMarkReleased(instanceId, index);

            if (milestone.queryStatus(instanceId) == (1 << 2)) {
                // COMPLETE
                isActive = false;
            }
        }
    }
}
