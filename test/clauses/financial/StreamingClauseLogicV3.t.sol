// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StreamingClauseLogicV3} from "../../../src/clauses/financial/StreamingClauseLogicV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title StreamingClauseLogicV3Test
 * @notice Comprehensive tests for StreamingClauseLogicV3
 */
contract StreamingClauseLogicV3Test is Test {
    StreamingClauseLogicV3 public streaming;
    MockERC20 public token;

    address alice;
    address bob;
    address charlie;

    // State constants (matching the contract)
    uint16 constant PENDING = 1 << 1; // 0x0002
    uint16 constant STREAMING_STATE = 1 << 2; // 0x0004
    uint16 constant COMPLETED = 1 << 3; // 0x0008
    uint16 constant STREAM_CANCELLED = 1 << 4; // 0x0010

    function setUp() public {
        streaming = new StreamingClauseLogicV3();
        token = new MockERC20();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fund accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);

        // Give alice some tokens
        token.mint(alice, 1000 * 10 ** 18);
    }

    // Allow test contract to receive ETH
    receive() external payable {}

    // =============================================================
    // CONFIGURATION TESTS
    // =============================================================

    function test_IntakeSender_Success() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeSender(instanceId, alice);

        assertEq(streaming.querySender(instanceId), alice);
        assertEq(streaming.queryStatus(instanceId), 0);
    }

    function test_IntakeRecipient_Success() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeRecipient(instanceId, bob);

        assertEq(streaming.queryRecipient(instanceId), bob);
    }

    function test_IntakeToken_Success() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeToken(instanceId, address(token));

        assertEq(streaming.queryToken(instanceId), address(token));
    }

    function test_IntakeDeposit_Success() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeDeposit(instanceId, 10 ether);

        assertEq(streaming.queryDeposit(instanceId), 10 ether);
    }

    function test_IntakeRatePerSecond_Success() public {
        bytes32 instanceId = keccak256("test-1");
        uint256 ratePerSecond = 1 ether / 30 days; // ~1 ETH per 30 days

        streaming.intakeRatePerSecond(instanceId, ratePerSecond);

        assertEq(streaming.queryRatePerSecond(instanceId), ratePerSecond);
    }

    function test_IntakeStartTime_Success() public {
        bytes32 instanceId = keccak256("test-1");
        uint48 startTime = uint48(block.timestamp + 1 days);

        streaming.intakeStartTime(instanceId, startTime);

        assertEq(streaming.queryStartTime(instanceId), startTime);
    }

    function test_IntakeReady_Success() public {
        bytes32 instanceId = keccak256("test-1");

        _configureStream(instanceId, alice, bob, address(0), 10 ether, 1 ether / 10);

        assertEq(streaming.queryStatus(instanceId), PENDING);
    }

    function test_IntakeSender_RevertsOnZeroAddress() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(StreamingClauseLogicV3.ZeroAddress.selector);
        streaming.intakeSender(instanceId, address(0));
    }

    function test_IntakeRecipient_RevertsOnZeroAddress() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(StreamingClauseLogicV3.ZeroAddress.selector);
        streaming.intakeRecipient(instanceId, address(0));
    }

    function test_IntakeDeposit_RevertsOnZero() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(StreamingClauseLogicV3.ZeroAmount.selector);
        streaming.intakeDeposit(instanceId, 0);
    }

    function test_IntakeRatePerSecond_RevertsOnZero() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(StreamingClauseLogicV3.InvalidRate.selector);
        streaming.intakeRatePerSecond(instanceId, 0);
    }

    function test_IntakeStartTime_RevertsOnZero() public {
        bytes32 instanceId = keccak256("test-1");

        vm.expectRevert(StreamingClauseLogicV3.InvalidStartTime.selector);
        streaming.intakeStartTime(instanceId, 0);
    }

    function test_IntakeReady_RevertsIfMissingSender() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeRecipient(instanceId, bob);
        streaming.intakeDeposit(instanceId, 10 ether);
        streaming.intakeRatePerSecond(instanceId, 1 ether);

        vm.expectRevert("No sender");
        streaming.intakeReady(instanceId);
    }

    function test_IntakeReady_RevertsIfMissingRecipient() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeSender(instanceId, alice);
        streaming.intakeDeposit(instanceId, 10 ether);
        streaming.intakeRatePerSecond(instanceId, 1 ether);

        vm.expectRevert("No recipient");
        streaming.intakeReady(instanceId);
    }

    function test_IntakeReady_RevertsIfMissingDeposit() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeSender(instanceId, alice);
        streaming.intakeRecipient(instanceId, bob);
        streaming.intakeRatePerSecond(instanceId, 1 ether);

        vm.expectRevert("No deposit");
        streaming.intakeReady(instanceId);
    }

    function test_IntakeReady_RevertsIfMissingRate() public {
        bytes32 instanceId = keccak256("test-1");

        streaming.intakeSender(instanceId, alice);
        streaming.intakeRecipient(instanceId, bob);
        streaming.intakeDeposit(instanceId, 10 ether);

        vm.expectRevert("No rate");
        streaming.intakeReady(instanceId);
    }

    function test_IntakeReady_CalculatesStopTime() public {
        bytes32 instanceId = keccak256("test-1");
        uint256 deposit = 10 ether;
        uint256 ratePerSecond = 1 ether; // 1 ETH per second

        _configureStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        // Duration should be deposit / rate = 10 seconds
        uint48 expectedStopTime = uint48(block.timestamp) + 10;
        assertEq(streaming.queryStopTime(instanceId), expectedStopTime);
    }

    function test_Intake_RevertsIfAlreadyPending() public {
        bytes32 instanceId = keccak256("test-1");

        _configureStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.expectRevert("Wrong state");
        streaming.intakeSender(instanceId, charlie);
    }

    // =============================================================
    // ETH DEPOSIT TESTS
    // =============================================================

    function test_ActionDeposit_ETH_Success() public {
        bytes32 instanceId = keccak256("eth-deposit-1");
        uint256 deposit = 10 ether;

        _configureStream(instanceId, alice, bob, address(0), deposit, 1 ether);

        uint256 balanceBefore = address(streaming).balance;

        vm.prank(alice);
        streaming.actionDeposit{value: deposit}(instanceId);

        assertEq(streaming.queryStatus(instanceId), STREAMING_STATE);
        assertEq(address(streaming).balance, balanceBefore + deposit);
        assertTrue(streaming.queryIsStreaming(instanceId));
    }

    function test_ActionDeposit_ETH_RefundsExcess() public {
        bytes32 instanceId = keccak256("eth-deposit-2");
        uint256 requiredDeposit = 10 ether;
        uint256 sentAmount = 15 ether;

        _configureStream(instanceId, alice, bob, address(0), requiredDeposit, 1 ether);

        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        streaming.actionDeposit{value: sentAmount}(instanceId);

        // Alice should have received the excess back
        assertEq(alice.balance, aliceBalanceBefore - requiredDeposit);
        assertEq(address(streaming).balance, requiredDeposit);
    }

    function test_ActionDeposit_ETH_RevertsOnInsufficientAmount() public {
        bytes32 instanceId = keccak256("eth-deposit-3");
        uint256 requiredDeposit = 10 ether;
        uint256 sentAmount = 5 ether;

        _configureStream(instanceId, alice, bob, address(0), requiredDeposit, 1 ether);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(StreamingClauseLogicV3.InsufficientDeposit.selector, requiredDeposit, sentAmount)
        );
        streaming.actionDeposit{value: sentAmount}(instanceId);
    }

    function test_ActionDeposit_ETH_RevertsIfNotSender() public {
        bytes32 instanceId = keccak256("eth-deposit-4");

        _configureStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(StreamingClauseLogicV3.NotSender.selector, charlie, alice));
        streaming.actionDeposit{value: 10 ether}(instanceId);
    }

    // =============================================================
    // ERC20 DEPOSIT TESTS
    // =============================================================

    function test_ActionDeposit_ERC20_Success() public {
        bytes32 instanceId = keccak256("erc20-deposit-1");
        uint256 deposit = 100 * 10 ** 18;

        _configureStream(instanceId, alice, bob, address(token), deposit, 1 * 10 ** 18);

        vm.prank(alice);
        token.approve(address(streaming), deposit);

        uint256 streamingBalanceBefore = token.balanceOf(address(streaming));
        uint256 aliceBalanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        streaming.actionDeposit(instanceId);

        assertEq(streaming.queryStatus(instanceId), STREAMING_STATE);
        assertEq(token.balanceOf(address(streaming)), streamingBalanceBefore + deposit);
        assertEq(token.balanceOf(alice), aliceBalanceBefore - deposit);
    }

    function test_ActionDeposit_ERC20_RevertsIfNotApproved() public {
        bytes32 instanceId = keccak256("erc20-deposit-2");
        uint256 deposit = 100 * 10 ** 18;

        _configureStream(instanceId, alice, bob, address(token), deposit, 1 * 10 ** 18);

        vm.prank(alice);
        vm.expectRevert();
        streaming.actionDeposit(instanceId);
    }

    // =============================================================
    // CLAIM TESTS
    // =============================================================

    function test_ActionClaim_Success() public {
        bytes32 instanceId = keccak256("claim-1");
        uint256 deposit = 10 ether;
        uint256 ratePerSecond = 1 ether; // 1 ETH per second

        _configureAndDepositStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        // Fast forward 5 seconds = 5 ETH streamed
        vm.warp(block.timestamp + 5);

        uint256 bobBalanceBefore = bob.balance;

        vm.prank(bob);
        uint256 claimed = streaming.actionClaim(instanceId, 0); // Claim all available

        assertEq(claimed, 5 ether);
        assertEq(bob.balance, bobBalanceBefore + 5 ether);
        assertEq(streaming.queryWithdrawn(instanceId), 5 ether);
    }

    function test_ActionClaim_PartialClaim() public {
        bytes32 instanceId = keccak256("claim-2");
        uint256 deposit = 10 ether;
        uint256 ratePerSecond = 1 ether;

        _configureAndDepositStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        // Fast forward 5 seconds = 5 ETH streamed
        vm.warp(block.timestamp + 5);

        vm.prank(bob);
        uint256 claimed = streaming.actionClaim(instanceId, 2 ether); // Only claim 2 ETH

        assertEq(claimed, 2 ether);
        assertEq(streaming.queryWithdrawn(instanceId), 2 ether);
        assertEq(streaming.queryAvailable(instanceId), 3 ether); // 5 - 2 = 3 remaining
    }

    function test_ActionClaim_CompletesStreamWhenFullyClaimed() public {
        bytes32 instanceId = keccak256("claim-3");
        uint256 deposit = 10 ether;
        uint256 ratePerSecond = 1 ether;

        _configureAndDepositStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        // Fast forward past stop time
        vm.warp(block.timestamp + 20); // Well past the 10-second duration

        vm.prank(bob);
        streaming.actionClaim(instanceId, 0);

        assertEq(streaming.queryStatus(instanceId), COMPLETED);
        assertTrue(streaming.queryIsComplete(instanceId));
    }

    function test_ActionClaim_RevertsIfNotRecipient() public {
        bytes32 instanceId = keccak256("claim-4");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(StreamingClauseLogicV3.NotRecipient.selector, charlie, bob));
        streaming.actionClaim(instanceId, 0);
    }

    function test_ActionClaim_RevertsIfNothingToClaim() public {
        bytes32 instanceId = keccak256("claim-5");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        // No time has passed, nothing streamed yet (assuming same block)

        vm.prank(bob);
        vm.expectRevert(StreamingClauseLogicV3.NothingToClaim.selector);
        streaming.actionClaim(instanceId, 0);
    }

    function test_ActionClaim_RevertsIfRequestedMoreThanAvailable() public {
        bytes32 instanceId = keccak256("claim-6");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5); // 5 ETH available

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StreamingClauseLogicV3.InsufficientAvailable.selector, 8 ether, 5 ether));
        streaming.actionClaim(instanceId, 8 ether);
    }

    // =============================================================
    // CANCEL TESTS
    // =============================================================

    function test_ActionCancel_Success() public {
        bytes32 instanceId = keccak256("cancel-1");
        uint256 deposit = 10 ether;
        uint256 ratePerSecond = 1 ether;

        _configureAndDepositStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        // Fast forward 5 seconds
        vm.warp(block.timestamp + 5);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alice);
        (uint256 toRecipient, uint256 toSender) = streaming.actionCancel(instanceId);

        assertEq(toRecipient, 5 ether); // Streamed amount
        assertEq(toSender, 5 ether); // Remaining amount
        assertEq(bob.balance, bobBalanceBefore + 5 ether);
        assertEq(alice.balance, aliceBalanceBefore + 5 ether);
        assertTrue(streaming.queryIsCancelled(instanceId));
    }

    function test_ActionCancel_RecipientCanCancel() public {
        bytes32 instanceId = keccak256("cancel-2");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);

        vm.prank(bob); // Recipient cancels
        streaming.actionCancel(instanceId);

        assertTrue(streaming.queryIsCancelled(instanceId));
    }

    function test_ActionCancel_AccountsForPriorWithdrawals() public {
        bytes32 instanceId = keccak256("cancel-3");
        uint256 deposit = 10 ether;
        uint256 ratePerSecond = 1 ether;

        _configureAndDepositStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        // Fast forward 5 seconds and claim 3 ETH
        vm.warp(block.timestamp + 5);
        vm.prank(bob);
        streaming.actionClaim(instanceId, 3 ether);

        // Fast forward 3 more seconds (8 total) and cancel
        vm.warp(block.timestamp + 3);

        uint256 bobBalanceBefore = bob.balance;
        uint256 aliceBalanceBefore = alice.balance;

        vm.prank(alice);
        (uint256 toRecipient, uint256 toSender) = streaming.actionCancel(instanceId);

        // 8 ETH streamed, 3 ETH already withdrawn
        // toRecipient = 8 - 3 = 5 ETH
        // toSender = 10 - 8 = 2 ETH
        assertEq(toRecipient, 5 ether);
        assertEq(toSender, 2 ether);
    }

    function test_ActionCancel_RevertsIfNotSenderOrRecipient() public {
        bytes32 instanceId = keccak256("cancel-4");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSelector(StreamingClauseLogicV3.NotSenderOrRecipient.selector, charlie));
        streaming.actionCancel(instanceId);
    }

    function test_ActionCancel_RevertsIfStreamFinished() public {
        bytes32 instanceId = keccak256("cancel-5");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        // Fast forward past stop time
        vm.warp(block.timestamp + 20);

        vm.prank(alice);
        vm.expectRevert(StreamingClauseLogicV3.StreamAlreadyFinished.selector);
        streaming.actionCancel(instanceId);
    }

    // =============================================================
    // HANDOFF TESTS
    // =============================================================

    function test_HandoffAmount_Success() public {
        bytes32 instanceId = keccak256("handoff-1");
        uint256 deposit = 10 ether;

        _configureAndDepositStream(instanceId, alice, bob, address(0), deposit, 1 ether);

        // Complete the stream
        vm.warp(block.timestamp + 20);
        vm.prank(bob);
        streaming.actionClaim(instanceId, 0);

        assertEq(streaming.handoffAmount(instanceId), deposit);
    }

    function test_HandoffRecipient_Success() public {
        bytes32 instanceId = keccak256("handoff-2");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        // Complete the stream
        vm.warp(block.timestamp + 20);
        vm.prank(bob);
        streaming.actionClaim(instanceId, 0);

        assertEq(streaming.handoffRecipient(instanceId), bob);
    }

    function test_HandoffCancellationSplit_Success() public {
        bytes32 instanceId = keccak256("handoff-3");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);
        vm.prank(alice);
        streaming.actionCancel(instanceId);

        (uint256 toRecipient, uint256 toSender) = streaming.handoffCancellationSplit(instanceId);
        assertEq(toRecipient, 5 ether);
        assertEq(toSender, 5 ether);
    }

    function test_Handoff_RevertsIfNotTerminalState() public {
        bytes32 instanceId = keccak256("handoff-fail-1");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);
        // Still in STREAMING state

        vm.expectRevert("Wrong state");
        streaming.handoffAmount(instanceId);
    }

    // =============================================================
    // QUERY TESTS
    // =============================================================

    function test_QueryStreamed_BeforeStart() public {
        bytes32 instanceId = keccak256("query-1");
        uint48 futureStart = uint48(block.timestamp + 1 days);

        streaming.intakeSender(instanceId, alice);
        streaming.intakeRecipient(instanceId, bob);
        streaming.intakeDeposit(instanceId, 10 ether);
        streaming.intakeRatePerSecond(instanceId, 1 ether);
        streaming.intakeStartTime(instanceId, futureStart);
        streaming.intakeReady(instanceId);

        vm.prank(alice);
        streaming.actionDeposit{value: 10 ether}(instanceId);

        assertEq(streaming.queryStreamed(instanceId), 0);
    }

    function test_QueryStreamed_DuringStream() public {
        bytes32 instanceId = keccak256("query-2");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);

        assertEq(streaming.queryStreamed(instanceId), 5 ether);
    }

    function test_QueryStreamed_AfterStop() public {
        bytes32 instanceId = keccak256("query-3");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 100); // Well past 10 seconds

        assertEq(streaming.queryStreamed(instanceId), 10 ether); // Capped at deposit
    }

    function test_QueryAvailable() public {
        bytes32 instanceId = keccak256("query-4");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);

        assertEq(streaming.queryAvailable(instanceId), 5 ether);

        // Claim some
        vm.prank(bob);
        streaming.actionClaim(instanceId, 2 ether);

        assertEq(streaming.queryAvailable(instanceId), 3 ether);
    }

    function test_QueryRemainingTime() public {
        bytes32 instanceId = keccak256("query-5");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        assertEq(streaming.queryRemainingTime(instanceId), 10);

        vm.warp(block.timestamp + 3);
        assertEq(streaming.queryRemainingTime(instanceId), 7);

        vm.warp(block.timestamp + 20);
        assertEq(streaming.queryRemainingTime(instanceId), 0);
    }

    function test_QueryRemainingAmount() public {
        bytes32 instanceId = keccak256("query-6");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        assertEq(streaming.queryRemainingAmount(instanceId), 10 ether);

        vm.warp(block.timestamp + 5);
        assertEq(streaming.queryRemainingAmount(instanceId), 5 ether);

        vm.warp(block.timestamp + 20);
        assertEq(streaming.queryRemainingAmount(instanceId), 0);
    }

    function test_QueryStreamState() public {
        bytes32 instanceId = keccak256("query-7");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);

        (uint16 status, uint256 streamed, uint256 available, uint256 withdrawn, uint256 remaining) =
            streaming.queryStreamState(instanceId);

        assertEq(status, STREAMING_STATE);
        assertEq(streamed, 5 ether);
        assertEq(available, 5 ether);
        assertEq(withdrawn, 0);
        assertEq(remaining, 5 ether);
    }

    function test_QueryCancellation() public {
        bytes32 instanceId = keccak256("query-8");

        _configureAndDepositStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.warp(block.timestamp + 5);
        vm.prank(alice);
        streaming.actionCancel(instanceId);

        (uint48 cancelledAt, address cancelledBy) = streaming.queryCancellation(instanceId);

        assertEq(cancelledAt, uint48(block.timestamp));
        assertEq(cancelledBy, alice);
    }

    // =============================================================
    // INSTANCE ISOLATION TESTS
    // =============================================================

    function test_MultipleInstances_Independent() public {
        bytes32 instance1 = keccak256("multi-1");
        bytes32 instance2 = keccak256("multi-2");

        _configureStream(instance1, alice, bob, address(0), 10 ether, 1 ether);
        _configureStream(instance2, bob, charlie, address(0), 20 ether, 2 ether);

        // Both should be PENDING
        assertEq(streaming.queryStatus(instance1), PENDING);
        assertEq(streaming.queryStatus(instance2), PENDING);

        // Fund only instance1
        vm.prank(alice);
        streaming.actionDeposit{value: 10 ether}(instance1);

        // Instance1 streaming, instance2 still pending
        assertEq(streaming.queryStatus(instance1), STREAMING_STATE);
        assertEq(streaming.queryStatus(instance2), PENDING);

        // Check different configurations
        assertEq(streaming.querySender(instance1), alice);
        assertEq(streaming.querySender(instance2), bob);
        assertEq(streaming.queryRecipient(instance1), bob);
        assertEq(streaming.queryRecipient(instance2), charlie);
    }

    // =============================================================
    // STATE MACHINE TESTS
    // =============================================================

    function test_StateMachine_FullFlow_Complete() public {
        bytes32 instanceId = keccak256("flow-complete");

        // 0 -> PENDING
        assertEq(streaming.queryStatus(instanceId), 0);
        _configureStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);
        assertEq(streaming.queryStatus(instanceId), PENDING);

        // PENDING -> STREAMING
        vm.prank(alice);
        streaming.actionDeposit{value: 10 ether}(instanceId);
        assertEq(streaming.queryStatus(instanceId), STREAMING_STATE);

        // STREAMING -> COMPLETED
        vm.warp(block.timestamp + 20);
        vm.prank(bob);
        streaming.actionClaim(instanceId, 0);
        assertEq(streaming.queryStatus(instanceId), COMPLETED);
    }

    function test_StateMachine_FullFlow_Cancel() public {
        bytes32 instanceId = keccak256("flow-cancel");

        _configureStream(instanceId, alice, bob, address(0), 10 ether, 1 ether);

        vm.prank(alice);
        streaming.actionDeposit{value: 10 ether}(instanceId);

        vm.warp(block.timestamp + 5);
        vm.prank(alice);
        streaming.actionCancel(instanceId);

        assertEq(streaming.queryStatus(instanceId), STREAM_CANCELLED);
    }

    // =============================================================
    // ERC20 STREAMING TESTS
    // =============================================================

    function test_ERC20_FullFlow() public {
        bytes32 instanceId = keccak256("erc20-flow");
        uint256 deposit = 100 * 10 ** 18;
        uint256 ratePerSecond = 10 * 10 ** 18; // 10 tokens per second

        _configureStream(instanceId, alice, bob, address(token), deposit, ratePerSecond);

        vm.prank(alice);
        token.approve(address(streaming), deposit);

        vm.prank(alice);
        streaming.actionDeposit(instanceId);

        // Fast forward 5 seconds = 50 tokens
        vm.warp(block.timestamp + 5);

        uint256 bobBalanceBefore = token.balanceOf(bob);

        vm.prank(bob);
        streaming.actionClaim(instanceId, 0);

        assertEq(token.balanceOf(bob), bobBalanceBefore + 50 * 10 ** 18);
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_StreamCalculation(uint256 deposit, uint256 ratePerSecond, uint256 elapsed) public {
        deposit = bound(deposit, 1 ether, 100 ether);
        ratePerSecond = bound(ratePerSecond, 0.01 ether, deposit); // Ensure rate doesn't exceed deposit
        elapsed = bound(elapsed, 0, 365 days);

        bytes32 instanceId = keccak256(abi.encode("fuzz-calc", deposit, ratePerSecond, elapsed));

        vm.deal(alice, deposit + 1 ether);

        _configureStream(instanceId, alice, bob, address(0), deposit, ratePerSecond);

        vm.prank(alice);
        streaming.actionDeposit{value: deposit}(instanceId);

        vm.warp(block.timestamp + elapsed);

        uint256 streamed = streaming.queryStreamed(instanceId);
        uint256 available = streaming.queryAvailable(instanceId);
        uint256 remaining = streaming.queryRemainingAmount(instanceId);

        // Invariants
        assertTrue(streamed <= deposit, "Streamed should not exceed deposit");
        assertTrue(available <= streamed, "Available should not exceed streamed");
        assertEq(streamed + remaining, deposit, "Streamed + remaining should equal deposit");
    }

    function testFuzz_ClaimConservesTotal(uint256 deposit, uint256 claimAmount, uint256 elapsed) public {
        deposit = bound(deposit, 1 ether, 100 ether);
        elapsed = bound(elapsed, 1, deposit); // At least 1 second, max deposit seconds

        bytes32 instanceId = keccak256(abi.encode("fuzz-claim", deposit, claimAmount, elapsed));

        vm.deal(alice, deposit + 1 ether);

        _configureStream(instanceId, alice, bob, address(0), deposit, 1 ether);

        vm.prank(alice);
        streaming.actionDeposit{value: deposit}(instanceId);

        vm.warp(block.timestamp + elapsed);

        uint256 available = streaming.queryAvailable(instanceId);

        if (available > 0) {
            claimAmount = bound(claimAmount, 1, available);

            uint256 bobBalanceBefore = bob.balance;

            vm.prank(bob);
            streaming.actionClaim(instanceId, claimAmount);

            assertEq(bob.balance, bobBalanceBefore + claimAmount);
            assertEq(streaming.queryWithdrawn(instanceId), claimAmount);
        }
    }

    function testFuzz_CancelConservesTotal(uint256 deposit, uint256 elapsed) public {
        deposit = bound(deposit, 1 ether, 100 ether);
        elapsed = bound(elapsed, 0, deposit - 1); // Must cancel before stream finishes

        bytes32 instanceId = keccak256(abi.encode("fuzz-cancel", deposit, elapsed));

        vm.deal(alice, deposit + 1 ether);

        _configureStream(instanceId, alice, bob, address(0), deposit, 1 ether);

        vm.prank(alice);
        streaming.actionDeposit{value: deposit}(instanceId);

        vm.warp(block.timestamp + elapsed);

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alice);
        (uint256 toRecipient, uint256 toSender) = streaming.actionCancel(instanceId);

        // Total conserved
        assertEq(toRecipient + toSender, deposit);
        assertEq(alice.balance, aliceBalanceBefore + toSender);
        assertEq(bob.balance, bobBalanceBefore + toRecipient);
    }

    // =============================================================
    // HELPERS
    // =============================================================

    function _configureStream(
        bytes32 instanceId,
        address sender,
        address recipient,
        address tokenAddr,
        uint256 deposit,
        uint256 ratePerSecond
    ) internal {
        streaming.intakeSender(instanceId, sender);
        streaming.intakeRecipient(instanceId, recipient);
        streaming.intakeToken(instanceId, tokenAddr);
        streaming.intakeDeposit(instanceId, deposit);
        streaming.intakeRatePerSecond(instanceId, ratePerSecond);
        streaming.intakeReady(instanceId);
    }

    function _configureAndDepositStream(
        bytes32 instanceId,
        address sender,
        address recipient,
        address tokenAddr,
        uint256 deposit,
        uint256 ratePerSecond
    ) internal {
        _configureStream(instanceId, sender, recipient, tokenAddr, deposit, ratePerSecond);

        if (tokenAddr == address(0)) {
            vm.prank(sender);
            streaming.actionDeposit{value: deposit}(instanceId);
        } else {
            vm.prank(sender);
            IERC20(tokenAddr).approve(address(streaming), deposit);
            vm.prank(sender);
            streaming.actionDeposit(instanceId);
        }
    }
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
