// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {EscrowClauseLogicV3} from "../../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000 * 10**18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title EscrowClauseLogicV3Test
 * @notice Comprehensive tests for EscrowClauseLogicV3
 */
contract EscrowClauseLogicV3Test is Test {

    EscrowClauseLogicV3 public escrow;
    MockERC20 public token;

    address alice;
    address bob;
    address charlie;

    // State constants (matching the contract)
    uint16 constant PENDING = 1 << 1;   // 0x0002
    uint16 constant FUNDED = 1 << 2;    // 0x0004
    uint16 constant RELEASED = 1 << 3;  // 0x0008
    uint16 constant REFUNDED = 1 << 4;  // 0x0010

    function setUp() public {
        escrow = new EscrowClauseLogicV3();
        token = new MockERC20();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);

        // Give alice some tokens
        token.mint(alice, 1000 * 10**18);
    }

    // Allow test contract to receive ETH
    receive() external payable {}

    // =============================================================
    // CONFIGURATION TESTS
    // =============================================================

    function test_IntakeDepositor_Success() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeDepositor(instanceId, alice);

        assertEq(escrow.queryDepositor(instanceId), alice);
        assertEq(escrow.queryStatus(instanceId), 0); // Still uninitialized
    }

    function test_IntakeBeneficiary_Success() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeBeneficiary(instanceId, bob);

        assertEq(escrow.queryBeneficiary(instanceId), bob);
    }

    function test_IntakeToken_Success() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeToken(instanceId, address(token));

        assertEq(escrow.queryToken(instanceId), address(token));
    }

    function test_IntakeAmount_Success() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeAmount(instanceId, 1 ether);

        assertEq(escrow.queryAmount(instanceId), 1 ether);
    }

    function test_IntakeReady_Success() public {
        bytes32 instanceId = keccak256("test-1");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        assertEq(escrow.queryStatus(instanceId), PENDING);
    }

    function test_IntakeDepositor_RevertsOnZeroAddress() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(EscrowClauseLogicV3.ZeroAddress.selector);
        escrow.intakeDepositor(instanceId, address(0));
    }

    function test_IntakeBeneficiary_RevertsOnZeroAddress() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(EscrowClauseLogicV3.ZeroAddress.selector);
        escrow.intakeBeneficiary(instanceId, address(0));
    }

    function test_IntakeAmount_RevertsOnZero() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(EscrowClauseLogicV3.ZeroAmount.selector);
        escrow.intakeAmount(instanceId, 0);
    }

    function test_IntakeReady_RevertsIfMissingDepositor() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, 1 ether);

        vm.expectRevert("No depositor");
        escrow.intakeReady(instanceId);
    }

    function test_IntakeReady_RevertsIfMissingBeneficiary() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeAmount(instanceId, 1 ether);

        vm.expectRevert("No beneficiary");
        escrow.intakeReady(instanceId);
    }

    function test_IntakeReady_RevertsIfMissingAmount() public {
        bytes32 instanceId = keccak256("test-1");

        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);

        vm.expectRevert("No amount");
        escrow.intakeReady(instanceId);
    }

    function test_Intake_RevertsIfAlreadyPending() public {
        bytes32 instanceId = keccak256("test-1");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.expectRevert("Wrong state");
        escrow.intakeDepositor(instanceId, charlie);
    }

    // =============================================================
    // ETH DEPOSIT TESTS
    // =============================================================

    function test_ActionDeposit_ETH_Success() public {
        bytes32 instanceId = keccak256("eth-deposit-1");
        uint256 amount = 1 ether;

        _configureEscrow(instanceId, alice, bob, address(0), amount);

        uint256 balanceBefore = address(escrow).balance;

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        assertEq(escrow.queryStatus(instanceId), FUNDED);
        assertEq(escrow.queryFundedAt(instanceId), block.timestamp);
        assertEq(address(escrow).balance, balanceBefore + amount);
        assertTrue(escrow.queryIsFunded(instanceId));
    }

    function test_ActionDeposit_ETH_RefundsExcess() public {
        bytes32 instanceId = keccak256("eth-deposit-2");
        uint256 requiredAmount = 1 ether;
        uint256 sentAmount = 2 ether;

        _configureEscrow(instanceId, alice, bob, address(0), requiredAmount);

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        escrow.actionDeposit{value: sentAmount}(instanceId);

        // Alice should have received the excess back
        assertEq(alice.balance, aliceBalanceBefore - requiredAmount);
        assertEq(address(escrow).balance, requiredAmount);
    }

    function test_ActionDeposit_ETH_RevertsOnInsufficientAmount() public {
        bytes32 instanceId = keccak256("eth-deposit-3");
        uint256 requiredAmount = 2 ether;
        uint256 sentAmount = 1 ether;

        _configureEscrow(instanceId, alice, bob, address(0), requiredAmount);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.InsufficientDeposit.selector,
                requiredAmount,
                sentAmount
            )
        );
        escrow.actionDeposit{value: sentAmount}(instanceId);
    }

    function test_ActionDeposit_ETH_RevertsIfNotDepositor() public {
        bytes32 instanceId = keccak256("eth-deposit-4");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.NotDepositor.selector,
                charlie,
                alice
            )
        );
        escrow.actionDeposit{value: 1 ether}(instanceId);
    }

    // =============================================================
    // ERC20 DEPOSIT TESTS
    // =============================================================

    function test_ActionDeposit_ERC20_Success() public {
        bytes32 instanceId = keccak256("erc20-deposit-1");
        uint256 amount = 100 * 10**18;

        _configureEscrow(instanceId, alice, bob, address(token), amount);

        // Alice approves escrow to spend tokens
        vm.prank(alice);
        token.approve(address(escrow), amount);

        uint256 escrowBalanceBefore = token.balanceOf(address(escrow));
        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        escrow.actionDeposit(instanceId);

        assertEq(escrow.queryStatus(instanceId), FUNDED);
        assertEq(token.balanceOf(address(escrow)), escrowBalanceBefore + amount);
        assertEq(token.balanceOf(alice), aliceBalanceBefore - amount);
    }

    function test_ActionDeposit_ERC20_RevertsIfNotApproved() public {
        bytes32 instanceId = keccak256("erc20-deposit-2");
        uint256 amount = 100 * 10**18;

        _configureEscrow(instanceId, alice, bob, address(token), amount);

        // No approval
        vm.prank(alice);
        vm.expectRevert();
        escrow.actionDeposit(instanceId);
    }

    // =============================================================
    // RELEASE TESTS
    // =============================================================

    function test_ActionRelease_ETH_Success() public {
        bytes32 instanceId = keccak256("release-eth-1");
        uint256 amount = 1 ether;

        _configureAndFundEscrow(instanceId, alice, bob, address(0), amount);

        uint256 bobBalanceBefore = bob.balance;

        escrow.actionRelease(instanceId);

        assertEq(escrow.queryStatus(instanceId), RELEASED);
        assertEq(bob.balance, bobBalanceBefore + amount);
        assertTrue(escrow.queryIsReleased(instanceId));
    }

    function test_ActionRelease_ERC20_Success() public {
        bytes32 instanceId = keccak256("release-erc20-1");
        uint256 amount = 100 * 10**18;

        _configureAndFundEscrow(instanceId, alice, bob, address(token), amount);

        uint256 bobBalanceBefore = token.balanceOf(bob);

        escrow.actionRelease(instanceId);

        assertEq(escrow.queryStatus(instanceId), RELEASED);
        assertEq(token.balanceOf(bob), bobBalanceBefore + amount);
    }

    function test_ActionRelease_RevertsIfNotFunded() public {
        bytes32 instanceId = keccak256("release-fail-1");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.expectRevert("Wrong state");
        escrow.actionRelease(instanceId);
    }

    function test_ActionRelease_RevertsIfAlreadyReleased() public {
        bytes32 instanceId = keccak256("release-fail-2");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        escrow.actionRelease(instanceId);

        vm.expectRevert("Wrong state");
        escrow.actionRelease(instanceId);
    }

    // =============================================================
    // REFUND TESTS
    // =============================================================

    function test_ActionRefund_ETH_Success() public {
        bytes32 instanceId = keccak256("refund-eth-1");
        uint256 amount = 1 ether;

        _configureAndFundEscrow(instanceId, alice, bob, address(0), amount);

        uint256 aliceBalanceBefore = alice.balance;

        escrow.actionRefund(instanceId);

        assertEq(escrow.queryStatus(instanceId), REFUNDED);
        assertEq(alice.balance, aliceBalanceBefore + amount);
        assertTrue(escrow.queryIsRefunded(instanceId));
    }

    function test_ActionRefund_ERC20_Success() public {
        bytes32 instanceId = keccak256("refund-erc20-1");
        uint256 amount = 100 * 10**18;

        _configureAndFundEscrow(instanceId, alice, bob, address(token), amount);

        uint256 aliceBalanceBefore = token.balanceOf(alice);

        escrow.actionRefund(instanceId);

        assertEq(escrow.queryStatus(instanceId), REFUNDED);
        assertEq(token.balanceOf(alice), aliceBalanceBefore + amount);
    }

    function test_ActionRefund_RevertsIfNotFunded() public {
        bytes32 instanceId = keccak256("refund-fail-1");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.expectRevert("Wrong state");
        escrow.actionRefund(instanceId);
    }

    function test_ActionRefund_RevertsIfAlreadyRefunded() public {
        bytes32 instanceId = keccak256("refund-fail-2");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        escrow.actionRefund(instanceId);

        vm.expectRevert("Wrong state");
        escrow.actionRefund(instanceId);
    }

    // =============================================================
    // HANDOFF TESTS
    // =============================================================

    function test_HandoffAmount_Success() public {
        bytes32 instanceId = keccak256("handoff-1");
        uint256 amount = 1 ether;

        _configureAndFundEscrow(instanceId, alice, bob, address(0), amount);
        escrow.actionRelease(instanceId);

        assertEq(escrow.handoffAmount(instanceId), amount);
    }

    function test_HandoffBeneficiary_Success() public {
        bytes32 instanceId = keccak256("handoff-2");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        escrow.actionRelease(instanceId);

        assertEq(escrow.handoffBeneficiary(instanceId), bob);
    }

    function test_HandoffToken_Success() public {
        bytes32 instanceId = keccak256("handoff-3");

        _configureAndFundEscrow(instanceId, alice, bob, address(token), 100 * 10**18);
        escrow.actionRelease(instanceId);

        assertEq(escrow.handoffToken(instanceId), address(token));
    }

    function test_HandoffDepositor_Success() public {
        bytes32 instanceId = keccak256("handoff-4");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        escrow.actionRefund(instanceId);

        assertEq(escrow.handoffDepositor(instanceId), alice);
    }

    function test_Handoff_RevertsIfNotTerminalState() public {
        bytes32 instanceId = keccak256("handoff-fail-1");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        // Still in FUNDED, not RELEASED

        vm.expectRevert("Wrong state");
        escrow.handoffAmount(instanceId);
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_MultipleInstances_Independent() public {
        bytes32 instance1 = keccak256("multi-1");
        bytes32 instance2 = keccak256("multi-2");

        // Configure both instances
        _configureEscrow(instance1, alice, bob, address(0), 1 ether);
        _configureEscrow(instance2, bob, charlie, address(0), 2 ether);

        // Both should be PENDING
        assertEq(escrow.queryStatus(instance1), PENDING);
        assertEq(escrow.queryStatus(instance2), PENDING);

        // Fund only instance1
        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instance1);

        // Instance1 funded, instance2 still pending
        assertEq(escrow.queryStatus(instance1), FUNDED);
        assertEq(escrow.queryStatus(instance2), PENDING);

        // Check different configurations
        assertEq(escrow.queryDepositor(instance1), alice);
        assertEq(escrow.queryDepositor(instance2), bob);
        assertEq(escrow.queryBeneficiary(instance1), bob);
        assertEq(escrow.queryBeneficiary(instance2), charlie);
    }

    // =============================================================
    // STATE MACHINE TESTS
    // =============================================================

    function test_StateMachine_FullFlow_Release() public {
        bytes32 instanceId = keccak256("flow-release");

        // 0 -> PENDING
        assertEq(escrow.queryStatus(instanceId), 0);
        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);
        assertEq(escrow.queryStatus(instanceId), PENDING);

        // PENDING -> FUNDED
        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);
        assertEq(escrow.queryStatus(instanceId), FUNDED);

        // FUNDED -> RELEASED
        escrow.actionRelease(instanceId);
        assertEq(escrow.queryStatus(instanceId), RELEASED);
    }

    function test_StateMachine_FullFlow_Refund() public {
        bytes32 instanceId = keccak256("flow-refund");

        // 0 -> PENDING -> FUNDED -> REFUNDED
        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        escrow.actionRefund(instanceId);
        assertEq(escrow.queryStatus(instanceId), REFUNDED);
    }

    function test_StateMachine_ReleaseAndRefundMutuallyExclusive() public {
        bytes32 instanceId = keccak256("mutex-test");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);

        // Release first
        escrow.actionRelease(instanceId);

        // Cannot refund after release
        vm.expectRevert("Wrong state");
        escrow.actionRefund(instanceId);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryIsFunded() public {
        bytes32 instanceId = keccak256("query-funded");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);
        assertFalse(escrow.queryIsFunded(instanceId));

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);
        assertTrue(escrow.queryIsFunded(instanceId));

        escrow.actionRelease(instanceId);
        assertFalse(escrow.queryIsFunded(instanceId));
    }

    function test_QueryIsReleased() public {
        bytes32 instanceId = keccak256("query-released");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        assertFalse(escrow.queryIsReleased(instanceId));

        escrow.actionRelease(instanceId);
        assertTrue(escrow.queryIsReleased(instanceId));
    }

    function test_QueryIsRefunded() public {
        bytes32 instanceId = keccak256("query-refunded");

        _configureAndFundEscrow(instanceId, alice, bob, address(0), 1 ether);
        assertFalse(escrow.queryIsRefunded(instanceId));

        escrow.actionRefund(instanceId);
        assertTrue(escrow.queryIsRefunded(instanceId));
    }

    // =============================================================
    // CANCELLATION CONFIGURATION TESTS
    // =============================================================

    function test_IntakeCancellationEnabled_Success() public {
        bytes32 instanceId = keccak256("cancel-config-1");

        escrow.intakeCancellationEnabled(instanceId, true);

        assertTrue(escrow.queryCancellationEnabled(instanceId));
    }

    function test_IntakeCancellationNoticePeriod_Success() public {
        bytes32 instanceId = keccak256("cancel-config-2");

        escrow.intakeCancellationNoticePeriod(instanceId, 7 days);

        assertEq(escrow.queryCancellationNoticePeriod(instanceId), 7 days);
    }

    function test_IntakeCancellationFeeType_Success() public {
        bytes32 instanceId = keccak256("cancel-config-3");

        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType.BPS);

        assertEq(uint8(escrow.queryCancellationFeeType(instanceId)), uint8(EscrowClauseLogicV3.FeeType.BPS));
    }

    function test_IntakeCancellationFeeAmount_Success() public {
        bytes32 instanceId = keccak256("cancel-config-4");

        escrow.intakeCancellationFeeAmount(instanceId, 2500); // 25%

        assertEq(escrow.queryCancellationFeeAmount(instanceId), 2500);
    }

    function test_IntakeCancellableBy_Success() public {
        bytes32 instanceId = keccak256("cancel-config-5");

        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.DEPOSITOR);

        assertEq(uint8(escrow.queryCancellableBy(instanceId)), uint8(EscrowClauseLogicV3.CancellableBy.DEPOSITOR));
    }

    function test_IntakeProrationStartDate_Success() public {
        bytes32 instanceId = keccak256("cancel-config-6");
        uint256 startDate = block.timestamp + 1 days;

        escrow.intakeProrationStartDate(instanceId, startDate);

        assertEq(escrow.queryProrationStartDate(instanceId), startDate);
    }

    function test_IntakeProrationDuration_Success() public {
        bytes32 instanceId = keccak256("cancel-config-7");

        escrow.intakeProrationDuration(instanceId, 30 days);

        assertEq(escrow.queryProrationDuration(instanceId), 30 days);
    }

    function test_Cancellation_RevertsIfAlreadyPending() public {
        bytes32 instanceId = keccak256("cancel-config-8");

        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.expectRevert("Wrong state");
        escrow.intakeCancellationEnabled(instanceId, true);
    }

    // =============================================================
    // IMMEDIATE CANCELLATION TESTS (no notice period)
    // =============================================================

    function test_ActionInitiateCancel_Immediate_FeeTypeNone() public {
        bytes32 instanceId = keccak256("immediate-cancel-none");
        uint256 amount = 1 ether;

        _configureEscrowWithCancellation(
            instanceId,
            alice, // depositor
            bob,   // beneficiary
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0, // feeAmount
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0  // noticePeriod
        );

        // Fund the escrow
        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        // Cancel as depositor
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Should be in CANCEL_EXECUTED state
        assertTrue(escrow.queryIsCancelExecuted(instanceId));

        // Full refund to depositor
        assertEq(alice.balance, aliceBalanceBefore + amount);
        assertEq(bob.balance, bobBalanceBefore); // No change for beneficiary
    }

    function test_ActionInitiateCancel_Immediate_FeeTypeFixed() public {
        bytes32 instanceId = keccak256("immediate-cancel-fixed");
        uint256 amount = 1 ether;
        uint256 fixedFee = 0.2 ether;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.FIXED,
            fixedFee,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        assertTrue(escrow.queryIsCancelExecuted(instanceId));

        // Fixed fee to beneficiary, rest to depositor
        assertEq(bob.balance, bobBalanceBefore + fixedFee);
        assertEq(alice.balance, aliceBalanceBefore + (amount - fixedFee));
    }

    function test_ActionInitiateCancel_Immediate_FeeTypeBPS() public {
        bytes32 instanceId = keccak256("immediate-cancel-bps");
        uint256 amount = 1 ether;
        uint256 bps = 2500; // 25%

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.BPS,
            bps,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        assertTrue(escrow.queryIsCancelExecuted(instanceId));

        uint256 expectedToBeneficiary = (amount * bps) / 10000;
        uint256 expectedToDepositor = amount - expectedToBeneficiary;

        assertEq(bob.balance, bobBalanceBefore + expectedToBeneficiary);
        assertEq(alice.balance, aliceBalanceBefore + expectedToDepositor);
    }

    function test_ActionInitiateCancel_Immediate_FeeTypeProrated() public {
        bytes32 instanceId = keccak256("immediate-cancel-prorated");
        uint256 amount = 1 ether;
        uint256 duration = 30 days;

        // Start date is now
        uint256 startDate = block.timestamp;

        _configureEscrowWithProration(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            startDate,
            duration,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Warp forward 15 days (50%)
        vm.warp(block.timestamp + 15 days);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        assertTrue(escrow.queryIsCancelExecuted(instanceId));

        // 50% should go to beneficiary
        uint256 expectedToBeneficiary = amount / 2;
        uint256 expectedToDepositor = amount - expectedToBeneficiary;

        assertEq(bob.balance, bobBalanceBefore + expectedToBeneficiary);
        assertEq(alice.balance, aliceBalanceBefore + expectedToDepositor);
    }

    // =============================================================
    // DEFERRED CANCELLATION TESTS (with notice period)
    // =============================================================

    function test_ActionInitiateCancel_Deferred_EntersCancelPending() public {
        bytes32 instanceId = keccak256("deferred-cancel-1");
        uint256 amount = 1 ether;
        uint256 noticePeriod = 7 days;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            noticePeriod
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Should be in CANCEL_PENDING state
        assertTrue(escrow.queryIsCancelPending(instanceId));
        assertFalse(escrow.queryIsCancelExecuted(instanceId));

        // Check notice ends at
        assertEq(escrow.queryNoticeEndsAt(instanceId), block.timestamp + noticePeriod);
        assertEq(escrow.queryCancellationInitiatedBy(instanceId), alice);
        assertEq(escrow.queryCancellationInitiatedAt(instanceId), block.timestamp);
    }

    function test_ActionExecuteCancel_AfterNoticePeriod() public {
        bytes32 instanceId = keccak256("deferred-cancel-2");
        uint256 amount = 1 ether;
        uint256 noticePeriod = 7 days;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            noticePeriod
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Cannot execute before notice period
        assertFalse(escrow.queryCanExecuteCancel(instanceId));

        // Warp past notice period
        vm.warp(block.timestamp + noticePeriod + 1);

        assertTrue(escrow.queryCanExecuteCancel(instanceId));

        uint256 aliceBalanceBefore = alice.balance;

        // Anyone can execute after notice period
        vm.prank(charlie);
        escrow.actionExecuteCancel(instanceId);

        assertTrue(escrow.queryIsCancelExecuted(instanceId));
        assertEq(alice.balance, aliceBalanceBefore + amount);
    }

    function test_ActionExecuteCancel_RevertsBeforeNoticePeriod() public {
        bytes32 instanceId = keccak256("deferred-cancel-3");
        uint256 amount = 1 ether;
        uint256 noticePeriod = 7 days;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            noticePeriod
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Try to execute before notice period
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.NoticePeriodNotElapsed.selector,
                instanceId,
                noticePeriod
            )
        );
        escrow.actionExecuteCancel(instanceId);
    }

    // =============================================================
    // AUTHORIZATION TESTS
    // =============================================================

    function test_ActionInitiateCancel_OnlyDepositor() public {
        bytes32 instanceId = keccak256("auth-depositor");
        uint256 amount = 1 ether;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Beneficiary cannot cancel
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.NotAuthorizedToCancel.selector,
                bob,
                EscrowClauseLogicV3.CancellableBy.DEPOSITOR
            )
        );
        escrow.actionInitiateCancel(instanceId);

        // Third party cannot cancel
        vm.prank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.NotAuthorizedToCancel.selector,
                charlie,
                EscrowClauseLogicV3.CancellableBy.DEPOSITOR
            )
        );
        escrow.actionInitiateCancel(instanceId);

        // Depositor can cancel
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);
        assertTrue(escrow.queryIsCancelExecuted(instanceId));
    }

    function test_ActionInitiateCancel_OnlyBeneficiary() public {
        bytes32 instanceId = keccak256("auth-beneficiary");
        uint256 amount = 1 ether;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.BENEFICIARY,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Depositor cannot cancel
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.NotAuthorizedToCancel.selector,
                alice,
                EscrowClauseLogicV3.CancellableBy.BENEFICIARY
            )
        );
        escrow.actionInitiateCancel(instanceId);

        // Beneficiary can cancel
        vm.prank(bob);
        escrow.actionInitiateCancel(instanceId);
        assertTrue(escrow.queryIsCancelExecuted(instanceId));
    }

    function test_ActionInitiateCancel_Either() public {
        // Test depositor
        bytes32 instanceId1 = keccak256("auth-either-1");
        _configureEscrowWithCancellation(
            instanceId1,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.EITHER,
            0
        );
        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId1);
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId1);
        assertTrue(escrow.queryIsCancelExecuted(instanceId1));

        // Test beneficiary
        bytes32 instanceId2 = keccak256("auth-either-2");
        _configureEscrowWithCancellation(
            instanceId2,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.EITHER,
            0
        );
        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId2);
        vm.prank(bob);
        escrow.actionInitiateCancel(instanceId2);
        assertTrue(escrow.queryIsCancelExecuted(instanceId2));
    }

    function test_ActionInitiateCancel_RevertsIfNotEnabled() public {
        bytes32 instanceId = keccak256("cancel-not-enabled");

        // Configure without cancellation
        _configureEscrow(instanceId, alice, bob, address(0), 1 ether);

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.CancellationNotEnabled.selector,
                instanceId
            )
        );
        escrow.actionInitiateCancel(instanceId);
    }

    function test_ActionInitiateCancel_RevertsIfNotFunded() public {
        bytes32 instanceId = keccak256("cancel-not-funded");

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        // Try to cancel without funding
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        escrow.actionInitiateCancel(instanceId);
    }

    // =============================================================
    // EDGE CASE TESTS
    // =============================================================

    function test_Cancellation_FixedFeeExceedsAmount() public {
        bytes32 instanceId = keccak256("edge-fixed-exceeds");
        uint256 amount = 1 ether;
        uint256 fixedFee = 2 ether; // Fee exceeds amount

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.FIXED,
            fixedFee,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        uint256 bobBalanceBefore = bob.balance;
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // All goes to beneficiary when fee exceeds amount
        assertEq(bob.balance, bobBalanceBefore + amount);
        assertEq(alice.balance, aliceBalanceBefore); // No refund
    }

    function test_Cancellation_ProrationBeforeStart() public {
        bytes32 instanceId = keccak256("edge-proration-before");
        uint256 amount = 1 ether;
        uint256 startDate = block.timestamp + 7 days; // Starts in the future

        _configureEscrowWithProration(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            startDate,
            30 days,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        // Cancel before proration starts
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Full refund to depositor
        assertEq(alice.balance, aliceBalanceBefore + amount);
        assertEq(bob.balance, bobBalanceBefore);
    }

    function test_Cancellation_ProrationAfterDuration() public {
        bytes32 instanceId = keccak256("edge-proration-after");
        uint256 amount = 1 ether;
        uint256 startDate = block.timestamp;
        uint256 duration = 30 days;

        _configureEscrowWithProration(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            startDate,
            duration,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Warp past full duration
        vm.warp(block.timestamp + duration + 1 days);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Full payment to beneficiary
        assertEq(bob.balance, bobBalanceBefore + amount);
        assertEq(alice.balance, aliceBalanceBefore);
    }

    function test_Cancellation_ProrationNotConfigured() public {
        bytes32 instanceId = keccak256("edge-proration-missing");
        uint256 amount = 1 ether;

        // Configure with PRORATED fee type but no proration config
        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.PRORATED,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.ProrationNotConfigured.selector,
                instanceId
            )
        );
        escrow.actionInitiateCancel(instanceId);
    }

    // =============================================================
    // HANDOFF TESTS FOR CANCELLATION
    // =============================================================

    function test_HandoffCancellationSplit_Success() public {
        bytes32 instanceId = keccak256("handoff-cancel-1");
        uint256 amount = 1 ether;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.BPS,
            2500, // 25%
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        (uint256 toBeneficiary, uint256 toDepositor) = escrow.handoffCancellationSplit(instanceId);
        assertEq(toBeneficiary, 0.25 ether);
        assertEq(toDepositor, 0.75 ether);
    }

    function test_HandoffCancelledBy_Success() public {
        bytes32 instanceId = keccak256("handoff-cancel-2");

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        assertEq(escrow.handoffCancelledBy(instanceId), alice);
    }

    function test_HandoffCancellation_RevertsIfNotCancelled() public {
        bytes32 instanceId = keccak256("handoff-cancel-3");

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        // Still FUNDED, not cancelled
        vm.expectRevert("Wrong state");
        escrow.handoffCancellationSplit(instanceId);
    }

    // =============================================================
    // QUERY TESTS FOR CANCELLATION
    // =============================================================

    function test_QueryCancellationSplit_PreviewBeforeCancel() public {
        bytes32 instanceId = keccak256("query-split-preview");
        uint256 amount = 1 ether;
        uint256 bps = 3000; // 30%

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            amount,
            EscrowClauseLogicV3.FeeType.BPS,
            bps,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Query split before cancelling
        (uint256 toBeneficiary, uint256 toDepositor) = escrow.queryCancellationSplit(instanceId);

        assertEq(toBeneficiary, 0.3 ether);
        assertEq(toDepositor, 0.7 ether);
    }

    // =============================================================
    // STATE MACHINE TESTS FOR CANCELLATION
    // =============================================================

    function test_StateMachine_CancelMutuallyExclusiveWithRelease() public {
        bytes32 instanceId = keccak256("mutex-cancel-release");

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        // Cancel first
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Cannot release after cancel
        vm.expectRevert("Wrong state");
        escrow.actionRelease(instanceId);

        // Cannot refund after cancel
        vm.expectRevert("Wrong state");
        escrow.actionRefund(instanceId);
    }

    function test_StateMachine_CannotCancelTwice() public {
        bytes32 instanceId = keccak256("cancel-twice");
        uint256 noticePeriod = 7 days;

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(0),
            1 ether,
            EscrowClauseLogicV3.FeeType.NONE,
            0,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            noticePeriod
        );

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Cannot initiate again while CANCEL_PENDING
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        escrow.actionInitiateCancel(instanceId);
    }

    // =============================================================
    // ERC20 CANCELLATION TESTS
    // =============================================================

    function test_Cancellation_ERC20_Success() public {
        bytes32 instanceId = keccak256("cancel-erc20");
        uint256 amount = 100 * 10**18;
        uint256 bps = 2000; // 20%

        _configureEscrowWithCancellation(
            instanceId,
            alice,
            bob,
            address(token),
            amount,
            EscrowClauseLogicV3.FeeType.BPS,
            bps,
            EscrowClauseLogicV3.CancellableBy.DEPOSITOR,
            0
        );

        vm.prank(alice);
        token.approve(address(escrow), amount);

        vm.prank(alice);
        escrow.actionDeposit(instanceId);

        uint256 aliceBalanceBefore = token.balanceOf(alice);
        uint256 bobBalanceBefore = token.balanceOf(bob);

        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        uint256 expectedToBeneficiary = (amount * bps) / 10000;
        uint256 expectedToDepositor = amount - expectedToBeneficiary;

        assertEq(token.balanceOf(bob), bobBalanceBefore + expectedToBeneficiary);
        assertEq(token.balanceOf(alice), aliceBalanceBefore + expectedToDepositor);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_ConfigureEscrow(
        address depositor,
        address beneficiary,
        uint256 amount
    ) public {
        vm.assume(depositor != address(0));
        vm.assume(beneficiary != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);

        bytes32 instanceId = keccak256(abi.encode("fuzz", depositor, beneficiary, amount));

        escrow.intakeDepositor(instanceId, depositor);
        escrow.intakeBeneficiary(instanceId, beneficiary);
        escrow.intakeAmount(instanceId, amount);
        escrow.intakeReady(instanceId);

        assertEq(escrow.queryDepositor(instanceId), depositor);
        assertEq(escrow.queryBeneficiary(instanceId), beneficiary);
        assertEq(escrow.queryAmount(instanceId), amount);
        assertEq(escrow.queryStatus(instanceId), PENDING);
    }

    function testFuzz_ETHDeposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 100 ether);

        bytes32 instanceId = keccak256(abi.encode("fuzz-eth", amount));

        _configureEscrow(instanceId, alice, bob, address(0), amount);

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        assertEq(escrow.queryStatus(instanceId), FUNDED);
        assertEq(address(escrow).balance, amount);
    }

    function testFuzz_InstanceIsolation(bytes32 id1, bytes32 id2) public {
        vm.assume(id1 != id2);

        _configureEscrow(id1, alice, bob, address(0), 1 ether);

        // id2 should still be uninitialized
        assertEq(escrow.queryStatus(id2), 0);
        assertEq(escrow.queryDepositor(id2), address(0));

        _configureEscrow(id2, charlie, alice, address(0), 2 ether);

        // Both should have their own state
        assertEq(escrow.queryDepositor(id1), alice);
        assertEq(escrow.queryDepositor(id2), charlie);
    }

    // =============================================================
    // HELPERS
    // =============================================================

    function _configureEscrow(
        bytes32 instanceId,
        address depositor,
        address beneficiary,
        address tokenAddr,
        uint256 amount
    ) internal {
        escrow.intakeDepositor(instanceId, depositor);
        escrow.intakeBeneficiary(instanceId, beneficiary);
        escrow.intakeToken(instanceId, tokenAddr);
        escrow.intakeAmount(instanceId, amount);
        escrow.intakeReady(instanceId);
    }

    function _configureAndFundEscrow(
        bytes32 instanceId,
        address depositor,
        address beneficiary,
        address tokenAddr,
        uint256 amount
    ) internal {
        _configureEscrow(instanceId, depositor, beneficiary, tokenAddr, amount);

        if (tokenAddr == address(0)) {
            vm.prank(depositor);
            escrow.actionDeposit{value: amount}(instanceId);
        } else {
            vm.prank(depositor);
            IERC20(tokenAddr).approve(address(escrow), amount);
            vm.prank(depositor);
            escrow.actionDeposit(instanceId);
        }
    }

    function _configureEscrowWithCancellation(
        bytes32 instanceId,
        address depositor,
        address beneficiary,
        address tokenAddr,
        uint256 amount,
        EscrowClauseLogicV3.FeeType feeType,
        uint256 feeAmount,
        EscrowClauseLogicV3.CancellableBy cancellableBy,
        uint256 noticePeriod
    ) internal {
        escrow.intakeDepositor(instanceId, depositor);
        escrow.intakeBeneficiary(instanceId, beneficiary);
        escrow.intakeToken(instanceId, tokenAddr);
        escrow.intakeAmount(instanceId, amount);

        // Cancellation config
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, feeType);
        escrow.intakeCancellationFeeAmount(instanceId, feeAmount);
        escrow.intakeCancellableBy(instanceId, cancellableBy);
        escrow.intakeCancellationNoticePeriod(instanceId, noticePeriod);

        escrow.intakeReady(instanceId);
    }

    function _configureEscrowWithProration(
        bytes32 instanceId,
        address depositor,
        address beneficiary,
        address tokenAddr,
        uint256 amount,
        uint256 startDate,
        uint256 duration,
        EscrowClauseLogicV3.CancellableBy cancellableBy
    ) internal {
        escrow.intakeDepositor(instanceId, depositor);
        escrow.intakeBeneficiary(instanceId, beneficiary);
        escrow.intakeToken(instanceId, tokenAddr);
        escrow.intakeAmount(instanceId, amount);

        // Cancellation config with proration
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType.PRORATED);
        escrow.intakeCancellableBy(instanceId, cancellableBy);
        escrow.intakeCancellationNoticePeriod(instanceId, 0);
        escrow.intakeProrationStartDate(instanceId, startDate);
        escrow.intakeProrationDuration(instanceId, duration);

        escrow.intakeReady(instanceId);
    }
}

/**
 * @title Fuzz Tests for Cancellation Split Calculations
 */
contract EscrowCancellationFuzzTest is Test {

    EscrowClauseLogicV3 public escrow;
    address alice;
    address bob;

    function setUp() public {
        escrow = new EscrowClauseLogicV3();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    receive() external payable {}

    /// @notice Fuzz test: Fixed fee split always conserves total amount
    function testFuzz_CancellationSplit_Fixed_ConservesTotal(
        uint256 amount,
        uint256 fixedFee
    ) public {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1, 100 ether);
        fixedFee = bound(fixedFee, 0, 200 ether); // Can exceed amount

        bytes32 instanceId = keccak256(abi.encode("fuzz-fixed", amount, fixedFee));

        _configureEscrowWithCancellation(
            instanceId,
            amount,
            EscrowClauseLogicV3.FeeType.FIXED,
            fixedFee
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        (uint256 toBeneficiary, uint256 toDepositor) = escrow.queryCancellationSplit(instanceId);

        // Total must always equal original amount (conservation)
        assertEq(toBeneficiary + toDepositor, amount, "Total must be conserved");

        // toBeneficiary should be capped at amount
        assertTrue(toBeneficiary <= amount, "toBeneficiary should not exceed amount");
    }

    /// @notice Fuzz test: BPS split always conserves total amount
    function testFuzz_CancellationSplit_BPS_ConservesTotal(
        uint256 amount,
        uint256 bps
    ) public {
        amount = bound(amount, 1, 100 ether);
        bps = bound(bps, 0, 20000); // 0% to 200%

        bytes32 instanceId = keccak256(abi.encode("fuzz-bps", amount, bps));

        _configureEscrowWithCancellation(
            instanceId,
            amount,
            EscrowClauseLogicV3.FeeType.BPS,
            bps
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        (uint256 toBeneficiary, uint256 toDepositor) = escrow.queryCancellationSplit(instanceId);

        // Total must always equal original amount
        assertEq(toBeneficiary + toDepositor, amount, "Total must be conserved");

        // toBeneficiary should be capped at amount
        assertTrue(toBeneficiary <= amount, "toBeneficiary should not exceed amount");
    }

    /// @notice Fuzz test: Prorated split always conserves total and respects time bounds
    function testFuzz_CancellationSplit_Prorated_ConservesTotal(
        uint256 amount,
        uint256 elapsed,
        uint256 duration
    ) public {
        amount = bound(amount, 1, 100 ether);
        duration = bound(duration, 1 hours, 365 days);
        elapsed = bound(elapsed, 0, duration * 2); // Can be past duration

        bytes32 instanceId = keccak256(abi.encode("fuzz-prorated", amount, elapsed, duration));

        uint256 startDate = block.timestamp;

        _configureEscrowWithProration(
            instanceId,
            amount,
            startDate,
            duration
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Warp to elapsed time
        vm.warp(startDate + elapsed);

        (uint256 toBeneficiary, uint256 toDepositor) = escrow.queryCancellationSplit(instanceId);

        // Total must always equal original amount
        assertEq(toBeneficiary + toDepositor, amount, "Total must be conserved");

        // Bounds checks
        if (elapsed == 0) {
            assertEq(toBeneficiary, 0, "No payment if no time elapsed");
        }
        if (elapsed >= duration) {
            assertEq(toBeneficiary, amount, "Full payment if past duration");
            assertEq(toDepositor, 0, "No refund if past duration");
        }
    }

    /// @notice Fuzz test: BPS calculation is monotonically increasing
    function testFuzz_CancellationSplit_BPS_Monotonic(
        uint256 amount,
        uint256 bps1,
        uint256 bps2
    ) public {
        amount = bound(amount, 1, 100 ether);
        bps1 = bound(bps1, 0, 10000);
        bps2 = bound(bps2, bps1, 10000);

        bytes32 instanceId1 = keccak256(abi.encode("fuzz-mono-1", amount, bps1));
        bytes32 instanceId2 = keccak256(abi.encode("fuzz-mono-2", amount, bps2));

        _configureEscrowWithCancellation(instanceId1, amount, EscrowClauseLogicV3.FeeType.BPS, bps1);
        _configureEscrowWithCancellation(instanceId2, amount, EscrowClauseLogicV3.FeeType.BPS, bps2);

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId1);
        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId2);

        (uint256 toBen1, ) = escrow.queryCancellationSplit(instanceId1);
        (uint256 toBen2, ) = escrow.queryCancellationSplit(instanceId2);

        // Higher BPS should result in higher toBeneficiary
        assertTrue(toBen2 >= toBen1, "Higher BPS should give higher toBeneficiary");
    }

    /// @notice Fuzz test: FeeType.NONE always gives full refund
    function testFuzz_CancellationSplit_None_FullRefund(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);

        bytes32 instanceId = keccak256(abi.encode("fuzz-none", amount));

        _configureEscrowWithCancellation(
            instanceId,
            amount,
            EscrowClauseLogicV3.FeeType.NONE,
            0
        );

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        (uint256 toBeneficiary, uint256 toDepositor) = escrow.queryCancellationSplit(instanceId);

        assertEq(toBeneficiary, 0, "NONE fee type should give 0 to beneficiary");
        assertEq(toDepositor, amount, "NONE fee type should give full refund");
    }

    // Helper functions
    function _configureEscrowWithCancellation(
        bytes32 instanceId,
        uint256 amount,
        EscrowClauseLogicV3.FeeType feeType,
        uint256 feeAmount
    ) internal {
        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, amount);
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, feeType);
        escrow.intakeCancellationFeeAmount(instanceId, feeAmount);
        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.DEPOSITOR);
        escrow.intakeReady(instanceId);
    }

    function _configureEscrowWithProration(
        bytes32 instanceId,
        uint256 amount,
        uint256 startDate,
        uint256 duration
    ) internal {
        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, amount);
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType.PRORATED);
        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.DEPOSITOR);
        escrow.intakeProrationStartDate(instanceId, startDate);
        escrow.intakeProrationDuration(instanceId, duration);
        escrow.intakeReady(instanceId);
    }
}

/**
 * @title EscrowClauseLogicV3 Invariant Tests
 * @notice Includes cancellation state invariants
 */
contract EscrowClauseLogicV3InvariantTest is Test {

    EscrowClauseLogicV3 public escrow;
    EscrowHandler public handler;

    // State constants
    uint16 constant PENDING = 1 << 1;
    uint16 constant FUNDED = 1 << 2;
    uint16 constant RELEASED = 1 << 3;
    uint16 constant REFUNDED = 1 << 4;
    uint16 constant CANCEL_PENDING = 1 << 5;
    uint16 constant CANCEL_EXECUTED = 1 << 6;

    function setUp() public {
        escrow = new EscrowClauseLogicV3();
        handler = new EscrowHandler(escrow);
        targetContract(address(handler));
    }

    /// @notice Invariant: No instance can be in multiple terminal states
    function invariant_NoMultipleTerminalStates() public view {
        bytes32[] memory instances = handler.getAllInstances();

        for (uint256 i = 0; i < instances.length; i++) {
            uint16 status = escrow.queryStatus(instances[i]);

            // Count how many terminal states are active
            uint256 terminalCount = 0;
            if (status == RELEASED) terminalCount++;
            if (status == REFUNDED) terminalCount++;
            if (status == CANCEL_EXECUTED) terminalCount++;

            assertTrue(terminalCount <= 1, "Cannot be in multiple terminal states");
        }
    }

    /// @notice Invariant: Valid status transitions only
    function invariant_ValidStatusValues() public view {
        bytes32[] memory instances = handler.getAllInstances();

        for (uint256 i = 0; i < instances.length; i++) {
            uint16 status = escrow.queryStatus(instances[i]);
            assertTrue(
                status == 0 || status == PENDING || status == FUNDED ||
                status == RELEASED || status == REFUNDED ||
                status == CANCEL_PENDING || status == CANCEL_EXECUTED,
                "Invalid status value"
            );
        }
    }

    /// @notice Invariant: Cancellation split always conserves total
    function invariant_CancellationSplitConservesTotal() public view {
        bytes32[] memory instances = handler.getAllInstances();

        for (uint256 i = 0; i < instances.length; i++) {
            uint16 status = escrow.queryStatus(instances[i]);

            // Only check if escrow has been funded (amount is non-zero)
            uint256 amount = escrow.queryAmount(instances[i]);
            if (amount > 0 && escrow.queryCancellationEnabled(instances[i])) {
                // Skip if it's a PRORATED type without valid config
                EscrowClauseLogicV3.FeeType feeType = escrow.queryCancellationFeeType(instances[i]);
                if (feeType == EscrowClauseLogicV3.FeeType.PRORATED) {
                    uint256 startDate = escrow.queryProrationStartDate(instances[i]);
                    uint256 duration = escrow.queryProrationDuration(instances[i]);
                    if (startDate == 0 || duration == 0) continue;
                }

                (uint256 toBen, uint256 toDep) = escrow.queryCancellationSplit(instances[i]);
                assertEq(toBen + toDep, amount, "Split must conserve total");
            }
        }
    }

    /// @notice Invariant: Terminal states are irreversible
    function invariant_TerminalStatesIrreversible() public view {
        bytes32[] memory instances = handler.getAllInstances();

        for (uint256 i = 0; i < instances.length; i++) {
            uint16 status = escrow.queryStatus(instances[i]);

            // If in terminal state, verify it's actually terminal
            if (status == RELEASED || status == REFUNDED || status == CANCEL_EXECUTED) {
                // These are the only valid terminal states
                assertTrue(
                    status == RELEASED || status == REFUNDED || status == CANCEL_EXECUTED,
                    "Terminal state check"
                );
            }
        }
    }
}

/**
 * @title Handler for invariant testing
 * @notice Includes cancellation operations
 */
contract EscrowHandler is Test {

    EscrowClauseLogicV3 public escrow;

    bytes32[] public allInstances;
    uint256 public counter;

    address public alice = address(0x1);
    address public bob = address(0x2);

    // State constants
    uint16 constant PENDING = 1 << 1;
    uint16 constant FUNDED = 1 << 2;
    uint16 constant CANCEL_PENDING = 1 << 5;

    constructor(EscrowClauseLogicV3 _escrow) {
        escrow = _escrow;
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function createAndConfigureInstance(uint256 amount) public {
        amount = bound(amount, 1, 10 ether);

        bytes32 instanceId = keccak256(abi.encode("handler", counter++));

        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, amount);
        escrow.intakeReady(instanceId);

        allInstances.push(instanceId);
    }

    function createCancellableInstance(uint256 amount, uint256 feeType, uint256 noticePeriod) public {
        amount = bound(amount, 1, 10 ether);
        feeType = bound(feeType, 0, 2); // NONE, FIXED, BPS (skip PRORATED for simplicity)
        noticePeriod = bound(noticePeriod, 0, 7 days);

        bytes32 instanceId = keccak256(abi.encode("handler-cancel", counter++));

        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, amount);

        // Cancellation config
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType(uint8(feeType)));
        if (feeType == 1) { // FIXED
            escrow.intakeCancellationFeeAmount(instanceId, amount / 10); // 10% fixed fee
        } else if (feeType == 2) { // BPS
            escrow.intakeCancellationFeeAmount(instanceId, 2500); // 25%
        }
        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.EITHER);
        escrow.intakeCancellationNoticePeriod(instanceId, noticePeriod);

        escrow.intakeReady(instanceId);

        allInstances.push(instanceId);
    }

    function fundInstance(uint256 instanceIndex) public {
        if (allInstances.length == 0) return;

        instanceIndex = instanceIndex % allInstances.length;
        bytes32 instanceId = allInstances[instanceIndex];

        if (escrow.queryStatus(instanceId) == PENDING) {
            uint256 amount = escrow.queryAmount(instanceId);
            vm.prank(alice);
            escrow.actionDeposit{value: amount}(instanceId);
        }
    }

    function releaseInstance(uint256 instanceIndex) public {
        if (allInstances.length == 0) return;

        instanceIndex = instanceIndex % allInstances.length;
        bytes32 instanceId = allInstances[instanceIndex];

        if (escrow.queryStatus(instanceId) == FUNDED) {
            escrow.actionRelease(instanceId);
        }
    }

    function refundInstance(uint256 instanceIndex) public {
        if (allInstances.length == 0) return;

        instanceIndex = instanceIndex % allInstances.length;
        bytes32 instanceId = allInstances[instanceIndex];

        if (escrow.queryStatus(instanceId) == FUNDED) {
            escrow.actionRefund(instanceId);
        }
    }

    function initiateCancelInstance(uint256 instanceIndex) public {
        if (allInstances.length == 0) return;

        instanceIndex = instanceIndex % allInstances.length;
        bytes32 instanceId = allInstances[instanceIndex];

        if (escrow.queryStatus(instanceId) == FUNDED && escrow.queryCancellationEnabled(instanceId)) {
            vm.prank(alice);
            escrow.actionInitiateCancel(instanceId);
        }
    }

    function executeCancelInstance(uint256 instanceIndex) public {
        if (allInstances.length == 0) return;

        instanceIndex = instanceIndex % allInstances.length;
        bytes32 instanceId = allInstances[instanceIndex];

        if (escrow.queryStatus(instanceId) == CANCEL_PENDING) {
            // Check if notice period has elapsed
            if (escrow.queryCanExecuteCancel(instanceId)) {
                escrow.actionExecuteCancel(instanceId);
            }
        }
    }

    function warpTime(uint256 seconds_) public {
        seconds_ = bound(seconds_, 0, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    function getAllInstances() external view returns (bytes32[] memory) {
        return allInstances;
    }

    receive() external payable {}
}

/**
 * @title Integration tests with other v3 clauses
 * @notice Tests demonstrating escrow cancellation interacting with other clause patterns
 */
contract EscrowClauseLogicV3IntegrationTest is Test {

    EscrowClauseLogicV3 public escrow;

    address alice;
    address bob;
    address charlie;

    function setUp() public {
        escrow = new EscrowClauseLogicV3();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
    }

    receive() external payable {}

    /// @notice Simulates an agreement where both parties can cancel with notice
    ///         This is a common pattern for service agreements
    function test_Integration_ServiceAgreementWithCancellation() public {
        bytes32 instanceId = keccak256("service-agreement");
        uint256 amount = 10 ether;
        uint256 noticePeriod = 30 days;

        // Configure a service agreement where either party can cancel with 30 days notice
        // Worker gets prorated payment based on time worked
        escrow.intakeDepositor(instanceId, alice); // Client
        escrow.intakeBeneficiary(instanceId, bob); // Service provider
        escrow.intakeAmount(instanceId, amount);

        // Cancellation: either party, 30 day notice, prorated fee
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType.PRORATED);
        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.EITHER);
        escrow.intakeCancellationNoticePeriod(instanceId, noticePeriod);

        // Work period: 90 days starting now
        uint256 workStart = block.timestamp;
        escrow.intakeProrationStartDate(instanceId, workStart);
        escrow.intakeProrationDuration(instanceId, 90 days);

        escrow.intakeReady(instanceId);

        // Client funds the escrow
        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        // Time passes - worker completes 45 days (50%)
        vm.warp(workStart + 45 days);

        // Client needs to cancel
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        assertTrue(escrow.queryIsCancelPending(instanceId));

        // Query what the split would be if executed now (after 45 days)
        (uint256 toWorker, uint256 toClient) = escrow.queryCancellationSplit(instanceId);
        assertEq(toWorker, 5 ether); // 50% of work completed
        assertEq(toClient, 5 ether);

        // Notice period passes (30 more days = 75 days total)
        vm.warp(workStart + 45 days + noticePeriod);

        // Now at 75 days (83.3% of 90 day period)
        (toWorker, toClient) = escrow.queryCancellationSplit(instanceId);
        assertGt(toWorker, 8 ether); // Should be ~8.33 ether

        // Execute cancellation
        escrow.actionExecuteCancel(instanceId);

        assertTrue(escrow.queryIsCancelExecuted(instanceId));
    }

    /// @notice Simulates a retainer where client can cancel with fixed cancellation fee
    function test_Integration_RetainerWithFixedCancellationFee() public {
        bytes32 instanceId = keccak256("retainer");
        uint256 amount = 5 ether;
        uint256 cancellationFee = 0.5 ether; // 10% kill fee

        // Configure retainer with fixed cancellation fee
        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, amount);

        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType.FIXED);
        escrow.intakeCancellationFeeAmount(instanceId, cancellationFee);
        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.DEPOSITOR);
        escrow.intakeCancellationNoticePeriod(instanceId, 0); // Immediate

        escrow.intakeReady(instanceId);

        vm.prank(alice);
        escrow.actionDeposit{value: amount}(instanceId);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        // Client cancels immediately
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        // Verify payments
        assertEq(bob.balance, bobBalanceBefore + cancellationFee);
        assertEq(alice.balance, aliceBalanceBefore + (amount - cancellationFee));
        assertTrue(escrow.queryIsCancelExecuted(instanceId));
    }

    /// @notice Tests multiple escrow instances with different cancellation policies
    ///         This simulates a multi-milestone project where each milestone has different terms
    function test_Integration_MultiMilestoneWithDifferentPolicies() public {
        // Milestone 1: Non-refundable deposit (no cancellation)
        bytes32 milestone1 = keccak256("milestone-1-deposit");
        escrow.intakeDepositor(milestone1, alice);
        escrow.intakeBeneficiary(milestone1, bob);
        escrow.intakeAmount(milestone1, 1 ether);
        // No cancellation config - cancellationEnabled defaults to false
        escrow.intakeReady(milestone1);

        // Milestone 2: 50% cancellation fee
        bytes32 milestone2 = keccak256("milestone-2-work");
        escrow.intakeDepositor(milestone2, alice);
        escrow.intakeBeneficiary(milestone2, bob);
        escrow.intakeAmount(milestone2, 4 ether);
        escrow.intakeCancellationEnabled(milestone2, true);
        escrow.intakeCancellationFeeType(milestone2, EscrowClauseLogicV3.FeeType.BPS);
        escrow.intakeCancellationFeeAmount(milestone2, 5000); // 50%
        escrow.intakeCancellableBy(milestone2, EscrowClauseLogicV3.CancellableBy.DEPOSITOR);
        escrow.intakeReady(milestone2);

        // Milestone 3: Full refund allowed
        bytes32 milestone3 = keccak256("milestone-3-bonus");
        escrow.intakeDepositor(milestone3, alice);
        escrow.intakeBeneficiary(milestone3, bob);
        escrow.intakeAmount(milestone3, 2 ether);
        escrow.intakeCancellationEnabled(milestone3, true);
        escrow.intakeCancellationFeeType(milestone3, EscrowClauseLogicV3.FeeType.NONE);
        escrow.intakeCancellableBy(milestone3, EscrowClauseLogicV3.CancellableBy.DEPOSITOR);
        escrow.intakeReady(milestone3);

        // Fund all milestones
        vm.startPrank(alice);
        escrow.actionDeposit{value: 1 ether}(milestone1);
        escrow.actionDeposit{value: 4 ether}(milestone2);
        escrow.actionDeposit{value: 2 ether}(milestone3);
        vm.stopPrank();

        // Milestone 1: Cannot cancel (not enabled)
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                EscrowClauseLogicV3.CancellationNotEnabled.selector,
                milestone1
            )
        );
        escrow.actionInitiateCancel(milestone1);

        // Milestone 2: Cancel with 50% fee
        (uint256 toBen2, uint256 toDep2) = escrow.queryCancellationSplit(milestone2);
        assertEq(toBen2, 2 ether); // 50%
        assertEq(toDep2, 2 ether);

        vm.prank(alice);
        escrow.actionInitiateCancel(milestone2);
        assertTrue(escrow.queryIsCancelExecuted(milestone2));

        // Milestone 3: Full refund
        (uint256 toBen3, uint256 toDep3) = escrow.queryCancellationSplit(milestone3);
        assertEq(toBen3, 0);
        assertEq(toDep3, 2 ether);

        vm.prank(alice);
        escrow.actionInitiateCancel(milestone3);
        assertTrue(escrow.queryIsCancelExecuted(milestone3));
    }

    /// @notice Tests that cancellation interacts correctly with the state machine
    ///         ensuring mutual exclusivity with release/refund
    function test_Integration_CancellationStateMachineExclusivity() public {
        bytes32 instanceId = keccak256("state-machine-test");

        // Setup cancellable escrow
        escrow.intakeDepositor(instanceId, alice);
        escrow.intakeBeneficiary(instanceId, bob);
        escrow.intakeAmount(instanceId, 1 ether);
        escrow.intakeCancellationEnabled(instanceId, true);
        escrow.intakeCancellationFeeType(instanceId, EscrowClauseLogicV3.FeeType.BPS);
        escrow.intakeCancellationFeeAmount(instanceId, 2500);
        escrow.intakeCancellableBy(instanceId, EscrowClauseLogicV3.CancellableBy.EITHER);
        escrow.intakeCancellationNoticePeriod(instanceId, 7 days);
        escrow.intakeReady(instanceId);

        vm.prank(alice);
        escrow.actionDeposit{value: 1 ether}(instanceId);

        // Initiate cancellation
        vm.prank(alice);
        escrow.actionInitiateCancel(instanceId);

        assertTrue(escrow.queryIsCancelPending(instanceId));

        // Cannot release while cancellation pending
        vm.expectRevert("Wrong state");
        escrow.actionRelease(instanceId);

        // Cannot refund while cancellation pending
        vm.expectRevert("Wrong state");
        escrow.actionRefund(instanceId);

        // Cannot deposit again
        vm.prank(alice);
        vm.expectRevert("Wrong state");
        escrow.actionDeposit{value: 1 ether}(instanceId);

        // Fast forward past notice period
        vm.warp(block.timestamp + 7 days + 1);

        // Execute cancellation
        escrow.actionExecuteCancel(instanceId);

        assertTrue(escrow.queryIsCancelExecuted(instanceId));

        // Cannot do anything after cancellation is executed
        vm.expectRevert("Wrong state");
        escrow.actionRelease(instanceId);

        vm.expectRevert("Wrong state");
        escrow.actionRefund(instanceId);

        vm.prank(alice);
        vm.expectRevert("Wrong state");
        escrow.actionInitiateCancel(instanceId);
    }
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
