// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MilestoneEscrowAdapter} from "../../src/adapters/MilestoneEscrowAdapter.sol";
import {MilestoneClauseLogicV3} from "../../src/clauses/orchestration/MilestoneClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";

/// @title MockAgreement
/// @notice A minimal Agreement contract that holds storage for all clauses
/// @dev This contract simulates how a real Agreement would work:
///      - It holds storage for both MilestoneClauseLogicV3 and EscrowClauseLogicV3
///      - Clause functions are called via delegatecall, so storage lives here
///      - Adapter functions are also called via delegatecall
contract MockAgreement {
    // These are the clause implementations (code only, no storage)
    MilestoneClauseLogicV3 public immutable milestoneClause;
    EscrowClauseLogicV3 public immutable escrowClause;
    MilestoneEscrowAdapter public immutable adapter;

    error DelegatecallFailed(bytes data);

    constructor(
        address _milestoneClause,
        address _escrowClause,
        address _adapter
    ) {
        milestoneClause = MilestoneClauseLogicV3(_milestoneClause);
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        adapter = MilestoneEscrowAdapter(_adapter);
    }

    // =========================================================
    // MILESTONE CLAUSE DELEGATECALLS (for setup)
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

    function milestone_queryMilestoneCount(bytes32 instanceId) external returns (uint256) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryMilestoneCount, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint256));
    }

    function milestone_queryTotalReleased(bytes32 instanceId) external returns (uint256) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryTotalReleased, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint256));
    }

    function milestone_queryReleasedCount(bytes32 instanceId) external returns (uint256) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryReleasedCount, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (uint256));
    }

    function milestone_queryIsComplete(bytes32 instanceId) external returns (bool) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryIsComplete, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function milestone_queryIsDisputed(bytes32 instanceId) external returns (bool) {
        (bool success, bytes memory data) = address(milestoneClause).delegatecall(
            abi.encodeCall(MilestoneClauseLogicV3.queryIsDisputed, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    // =========================================================
    // ESCROW CLAUSE DELEGATECALLS (for setup and queries)
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

    function escrow_queryIsFunded(bytes32 instanceId) external returns (bool) {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.queryIsFunded, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function escrow_queryIsReleased(bytes32 instanceId) external returns (bool) {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.queryIsReleased, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    function escrow_queryIsRefunded(bytes32 instanceId) external returns (bool) {
        (bool success, bytes memory data) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.queryIsRefunded, (instanceId))
        );
        if (!success) revert DelegatecallFailed(data);
        return abi.decode(data, (bool));
    }

    // =========================================================
    // ADAPTER DELEGATECALLS (the main orchestration functions)
    // =========================================================

    function adapter_confirmAndRelease(bytes32 milestoneInstanceId, uint256 milestoneIndex) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(MilestoneEscrowAdapter.confirmAndRelease, (milestoneInstanceId, milestoneIndex))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function adapter_dispute(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex,
        bytes32 reasonHash
    ) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(MilestoneEscrowAdapter.dispute, (milestoneInstanceId, milestoneIndex, reasonHash))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function adapter_resolveDisputeAndExecute(
        bytes32 milestoneInstanceId,
        uint256 milestoneIndex,
        bool releaseToBeneficiary
    ) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(
                MilestoneEscrowAdapter.resolveDisputeAndExecute,
                (milestoneInstanceId, milestoneIndex, releaseToBeneficiary)
            )
        );
        if (!success) revert DelegatecallFailed(data);
    }

    function adapter_cancelAndRefundAll(bytes32 milestoneInstanceId) external {
        (bool success, bytes memory data) = address(adapter).delegatecall(
            abi.encodeCall(MilestoneEscrowAdapter.cancelAndRefundAll, (milestoneInstanceId))
        );
        if (!success) revert DelegatecallFailed(data);
    }

    // Receive ETH for escrow operations
    receive() external payable {}
}

/// @title MilestoneEscrowAdapterTest
/// @notice Comprehensive integration tests for MilestoneEscrowAdapter
/// @dev Tests the adapter in the context of a real delegatecall chain:
///      Agreement -> Adapter -> Clauses (all operating on Agreement's storage)
contract MilestoneEscrowAdapterTest is Test {
    // Contracts
    MilestoneClauseLogicV3 public milestoneClause;
    EscrowClauseLogicV3 public escrowClause;
    MilestoneEscrowAdapter public adapter;
    MockAgreement public agreement;

    // Actors
    address public beneficiary;
    address public client;
    address public arbitrator;

    // Test data
    bytes32 public milestoneInstanceId = keccak256("test-milestone-instance");

    // Milestone state constants
    uint8 constant MILESTONE_NONE = 0;
    uint8 constant MILESTONE_PENDING = 1;
    uint8 constant MILESTONE_REQUESTED = 2;
    uint8 constant MILESTONE_CONFIRMED = 3;
    uint8 constant MILESTONE_DISPUTED = 4;
    uint8 constant MILESTONE_RELEASED = 5;
    uint8 constant MILESTONE_REFUNDED = 6;

    // Instance state constants
    uint16 constant STATE_PENDING = 1 << 1;   // 0x0002
    uint16 constant STATE_COMPLETE = 1 << 2;  // 0x0004
    uint16 constant STATE_CANCELLED = 1 << 3; // 0x0008
    uint16 constant STATE_ACTIVE = 1 << 4;    // 0x0010
    uint16 constant STATE_DISPUTED = 1 << 5;  // 0x0020

    // Escrow state constants
    uint16 constant ESCROW_PENDING = 1 << 1;  // 0x0002
    uint16 constant ESCROW_FUNDED = 1 << 2;   // 0x0004
    uint16 constant ESCROW_RELEASED = 1 << 3; // 0x0008
    uint16 constant ESCROW_REFUNDED = 1 << 4; // 0x0010

    function setUp() public {
        // Create actors
        beneficiary = makeAddr("beneficiary");
        client = makeAddr("client");
        arbitrator = makeAddr("arbitrator");

        // Fund actors
        vm.deal(client, 100 ether);
        vm.deal(beneficiary, 1 ether);

        // Deploy clause logic contracts (stateless, code only)
        milestoneClause = new MilestoneClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();

        // Deploy adapter with clause addresses
        adapter = new MilestoneEscrowAdapter(
            address(milestoneClause),
            address(escrowClause)
        );

        // Deploy mock agreement that will hold all storage
        agreement = new MockAgreement(
            address(milestoneClause),
            address(escrowClause),
            address(adapter)
        );

        // Fund the agreement for ETH escrows
        vm.deal(address(agreement), 100 ether);
    }

    // =========================================================
    // HELPER FUNCTIONS
    // =========================================================

    /// @notice Helper to generate escrow instance IDs linked to milestones
    function _escrowId(uint256 milestoneIndex) internal view returns (bytes32) {
        return keccak256(abi.encode(milestoneInstanceId, "escrow", milestoneIndex));
    }

    /// @notice Setup a milestone instance with N milestones and linked escrows
    function _setupMilestones(uint256 count, uint256[] memory amounts) internal {
        require(count == amounts.length, "count must match amounts length");

        // Setup milestones
        for (uint256 i = 0; i < count; i++) {
            agreement.milestone_intakeMilestone(
                milestoneInstanceId,
                keccak256(abi.encode("milestone", i)),
                amounts[i]
            );
        }

        agreement.milestone_intakeBeneficiary(milestoneInstanceId, beneficiary);
        agreement.milestone_intakeClient(milestoneInstanceId, client);
        agreement.milestone_intakeToken(milestoneInstanceId, address(0)); // ETH
        agreement.milestone_intakeReady(milestoneInstanceId);

        // Setup escrows and link them
        for (uint256 i = 0; i < count; i++) {
            bytes32 escrowId = _escrowId(i);

            agreement.escrow_intakeDepositor(escrowId, client);
            agreement.escrow_intakeBeneficiary(escrowId, beneficiary);
            agreement.escrow_intakeToken(escrowId, address(0)); // ETH
            agreement.escrow_intakeAmount(escrowId, amounts[i]);
            agreement.escrow_intakeReady(escrowId);

            // Link escrow to milestone
            agreement.milestone_intakeMilestoneEscrowId(milestoneInstanceId, i, escrowId);
        }
    }

    /// @notice Setup milestones, fund escrows, and activate
    function _setupAndActivate(uint256 count, uint256[] memory amounts) internal {
        _setupMilestones(count, amounts);

        // Fund each escrow (client deposits)
        for (uint256 i = 0; i < count; i++) {
            bytes32 escrowId = _escrowId(i);
            vm.prank(client);
            agreement.escrow_actionDeposit{value: amounts[i]}(escrowId);
        }

        // Activate milestone tracking
        agreement.milestone_actionActivate(milestoneInstanceId);
    }

    // =========================================================
    // UNIT TESTS: confirmAndRelease
    // =========================================================

    function test_confirmAndRelease_singleMilestone() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // Client confirms and releases via adapter
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        // Check milestone state
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 1 ether);

        // Check escrow state
        assertTrue(agreement.escrow_queryIsReleased(_escrowId(0)));

        // Check beneficiary received funds
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + 1 ether);
    }

    function test_confirmAndRelease_threeMilestones_inOrder() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupAndActivate(3, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // Confirm all milestones in order
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            agreement.adapter_confirmAndRelease(milestoneInstanceId, i);

            assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, i), MILESTONE_RELEASED);
            assertEq(agreement.milestone_queryReleasedCount(milestoneInstanceId), i + 1);
        }

        // Final state checks
        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 6 ether);
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + 6 ether);

        // All escrows released
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(agreement.escrow_queryIsReleased(_escrowId(i)));
        }
    }

    function test_confirmAndRelease_outOfOrder() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupAndActivate(3, amounts);

        // Confirm out of order: 2, 0, 1
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 2);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 2), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 3 ether);

        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 4 ether);

        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 1);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 1), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 6 ether);

        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
    }

    function test_confirmAndRelease_withPriorRequest() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        // Beneficiary requests confirmation first
        vm.prank(beneficiary);
        agreement.milestone_actionRequestConfirmation(milestoneInstanceId, 0);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_REQUESTED);

        // Client confirms and releases
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
    }

    function test_confirmAndRelease_revertsIfNotClient() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        // Try to confirm as beneficiary (should fail)
        vm.prank(beneficiary);
        vm.expectRevert(); // Will revert with NotClient
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);
    }

    function test_confirmAndRelease_revertsIfAlreadyReleased() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        // First confirm succeeds
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        // Second confirm fails
        vm.prank(client);
        vm.expectRevert(); // Already confirmed/released
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);
    }

    // =========================================================
    // UNIT TESTS: dispute
    // =========================================================

    function test_dispute_byClient() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        bytes32 reasonHash = keccak256("Work not delivered");

        vm.prank(client);
        agreement.adapter_dispute(milestoneInstanceId, 0, reasonHash);

        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_DISPUTED);
        assertTrue(agreement.milestone_queryIsDisputed(milestoneInstanceId));
    }

    function test_dispute_byBeneficiary() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        bytes32 reasonHash = keccak256("Client unresponsive");

        vm.prank(beneficiary);
        agreement.adapter_dispute(milestoneInstanceId, 0, reasonHash);

        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_DISPUTED);
        assertTrue(agreement.milestone_queryIsDisputed(milestoneInstanceId));
    }

    // =========================================================
    // UNIT TESTS: resolveDisputeAndExecute
    // =========================================================

    function test_resolveDisputeAndExecute_releaseToBeneficiary() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // File dispute
        vm.prank(client);
        agreement.adapter_dispute(milestoneInstanceId, 0, keccak256("dispute"));

        // Resolve in favor of beneficiary
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 0, true);

        // Milestone should be released
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        assertTrue(agreement.escrow_queryIsReleased(_escrowId(0)));
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + 1 ether);
    }

    function test_resolveDisputeAndExecute_refundToDepositor() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        _setupAndActivate(1, amounts);

        uint256 clientBalanceBefore = client.balance;

        // File dispute
        vm.prank(beneficiary);
        agreement.adapter_dispute(milestoneInstanceId, 0, keccak256("dispute"));

        // Resolve in favor of depositor (client)
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 0, false);

        // Milestone should be refunded
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_REFUNDED);
        assertTrue(agreement.escrow_queryIsRefunded(_escrowId(0)));
        assertEq(client.balance, clientBalanceBefore + 1 ether);
    }

    // =========================================================
    // INTEGRATION TESTS: Complex Multi-Step Scenarios
    // =========================================================

    function test_mixedState_releaseAndDispute() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupAndActivate(3, amounts);

        // Release milestone 0
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        // Dispute milestone 1
        vm.prank(client);
        agreement.adapter_dispute(milestoneInstanceId, 1, keccak256("bad work"));

        // Check mixed state
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 1), MILESTONE_DISPUTED);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 2), MILESTONE_PENDING);
        assertTrue(agreement.milestone_queryIsDisputed(milestoneInstanceId));
        assertFalse(agreement.milestone_queryIsComplete(milestoneInstanceId));

        // Resolve dispute in favor of beneficiary
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 1, true);

        // Now release milestone 2
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 2);

        // All milestones resolved
        assertEq(agreement.milestone_queryReleasedCount(milestoneInstanceId), 3);
        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 6 ether);
    }

    function test_mixedState_multipleDisputes() public {
        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;
        amounts[3] = 4 ether;

        _setupAndActivate(4, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 clientBalanceBefore = client.balance;

        // Release milestone 0
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        // Dispute milestones 1 and 2
        vm.prank(client);
        agreement.adapter_dispute(milestoneInstanceId, 1, keccak256("dispute-1"));
        vm.prank(beneficiary);
        agreement.adapter_dispute(milestoneInstanceId, 2, keccak256("dispute-2"));

        assertTrue(agreement.milestone_queryIsDisputed(milestoneInstanceId));

        // Resolve disputes with different outcomes
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 1, true);  // to beneficiary
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 2, false); // to depositor (refund)

        // Release milestone 3
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 3);

        // Verify final state
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 1), MILESTONE_RELEASED);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 2), MILESTONE_REFUNDED);
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 3), MILESTONE_RELEASED);

        // Verify payments:
        // Beneficiary gets: 1 + 2 + 4 = 7 ether
        // Client gets refunded: 3 ether
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + 7 ether);
        assertEq(client.balance, clientBalanceBefore + 3 ether);
    }

    function test_partialCompletion_disputeThenComplete() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupAndActivate(3, amounts);

        // Complete milestone 0
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        // Dispute milestone 1
        vm.prank(client);
        agreement.adapter_dispute(milestoneInstanceId, 1, keccak256("dispute"));

        // We're now in DISPUTED state globally
        assertTrue(agreement.milestone_queryIsDisputed(milestoneInstanceId));

        // Can't confirm new milestones while disputed? Let's check milestone 2
        // Actually, in MilestoneClauseLogicV3, dispute only affects the specific milestone
        // The instance-level status is DISPUTED but we should still be able to release other milestones

        // Complete milestone 2 (should work even with milestone 1 disputed)
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 2);

        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 2), MILESTONE_RELEASED);

        // Now resolve the dispute
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 1, true);

        // Should be complete now
        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 6 ether);
    }

    // =========================================================
    // UNIT TESTS: cancelAndRefundAll
    // =========================================================

    function test_cancelAndRefundAll_beforeActivation() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupMilestones(3, amounts);

        // Fund escrows but don't activate
        for (uint256 i = 0; i < 3; i++) {
            bytes32 escrowId = _escrowId(i);
            vm.prank(client);
            agreement.escrow_actionDeposit{value: amounts[i]}(escrowId);
        }

        uint256 clientBalanceBefore = client.balance;

        // Cancel all
        vm.prank(client);
        agreement.adapter_cancelAndRefundAll(milestoneInstanceId);

        // All escrows should be refunded
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(agreement.escrow_queryIsRefunded(_escrowId(i)));
        }

        // Client should get all funds back
        assertEq(client.balance, clientBalanceBefore + 6 ether);
    }

    function test_cancelAndRefundAll_partiallyFunded() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupMilestones(3, amounts);

        // Fund only first 2 escrows
        for (uint256 i = 0; i < 2; i++) {
            bytes32 escrowId = _escrowId(i);
            vm.prank(client);
            agreement.escrow_actionDeposit{value: amounts[i]}(escrowId);
        }

        uint256 clientBalanceBefore = client.balance;

        // Cancel all
        vm.prank(client);
        agreement.adapter_cancelAndRefundAll(milestoneInstanceId);

        // First 2 escrows refunded, 3rd still pending
        assertTrue(agreement.escrow_queryIsRefunded(_escrowId(0)));
        assertTrue(agreement.escrow_queryIsRefunded(_escrowId(1)));
        assertEq(agreement.escrow_queryStatus(_escrowId(2)), ESCROW_PENDING);

        // Client gets back 3 ether
        assertEq(client.balance, clientBalanceBefore + 3 ether);
    }

    // =========================================================
    // FUZZ TESTS
    // =========================================================

    function testFuzz_confirmAndRelease_variableAmounts(
        uint128 amount1,
        uint128 amount2,
        uint128 amount3
    ) public {
        vm.assume(amount1 > 0 && amount1 <= 10 ether);
        vm.assume(amount2 > 0 && amount2 <= 10 ether);
        vm.assume(amount3 > 0 && amount3 <= 10 ether);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amount1;
        amounts[1] = amount2;
        amounts[2] = amount3;

        // Use fresh instance ID for each fuzz run
        milestoneInstanceId = keccak256(abi.encode("fuzz", amount1, amount2, amount3));

        _setupAndActivate(3, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // Confirm all
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            agreement.adapter_confirmAndRelease(milestoneInstanceId, i);
        }

        uint256 expectedTotal = uint256(amount1) + uint256(amount2) + uint256(amount3);

        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), expectedTotal);
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + expectedTotal);
    }

    function testFuzz_confirmAndRelease_randomOrder(
        uint256 seed
    ) public {
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;
        amounts[3] = 4 ether;
        amounts[4] = 5 ether;

        // Use fresh instance ID for each fuzz run
        milestoneInstanceId = keccak256(abi.encode("fuzz-order", seed));

        _setupAndActivate(5, amounts);

        // Generate a random order based on seed
        uint256[] memory order = new uint256[](5);
        order[0] = seed % 5;
        order[1] = (seed / 5) % 5;
        order[2] = (seed / 25) % 5;
        order[3] = (seed / 125) % 5;
        order[4] = (seed / 625) % 5;

        // Track which milestones we've released
        bool[5] memory released;
        uint256 releasedCount = 0;

        for (uint256 i = 0; i < 5; i++) {
            uint256 idx = order[i];
            if (!released[idx]) {
                vm.prank(client);
                agreement.adapter_confirmAndRelease(milestoneInstanceId, idx);
                released[idx] = true;
                releasedCount++;
            }
        }

        // Release any remaining
        for (uint256 i = 0; i < 5; i++) {
            if (!released[i]) {
                vm.prank(client);
                agreement.adapter_confirmAndRelease(milestoneInstanceId, i);
            }
        }

        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), 15 ether);
    }

    function testFuzz_disputeAndResolve_randomOutcomes(
        bool outcome1,
        bool outcome2,
        bool outcome3
    ) public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        milestoneInstanceId = keccak256(abi.encode("fuzz-dispute", outcome1, outcome2, outcome3));

        _setupAndActivate(3, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;
        uint256 clientBalanceBefore = client.balance;

        // Dispute all milestones
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(client);
            agreement.adapter_dispute(milestoneInstanceId, i, keccak256(abi.encode("dispute", i)));
        }

        // Resolve with random outcomes
        bool[] memory outcomes = new bool[](3);
        outcomes[0] = outcome1;
        outcomes[1] = outcome2;
        outcomes[2] = outcome3;

        uint256 expectedBeneficiaryGain = 0;
        uint256 expectedClientGain = 0;

        for (uint256 i = 0; i < 3; i++) {
            agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, i, outcomes[i]);

            if (outcomes[i]) {
                expectedBeneficiaryGain += amounts[i];
            } else {
                expectedClientGain += amounts[i];
            }
        }

        assertEq(beneficiary.balance, beneficiaryBalanceBefore + expectedBeneficiaryGain);
        assertEq(client.balance, clientBalanceBefore + expectedClientGain);
    }

    // =========================================================
    // EDGE CASE TESTS
    // =========================================================

    function test_singleMilestone_fullDisputeFlow() public {
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5 ether;

        _setupAndActivate(1, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // Dispute
        vm.prank(beneficiary);
        agreement.adapter_dispute(milestoneInstanceId, 0, keccak256("not paid yet"));

        // Resolve in favor of beneficiary
        agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, 0, true);

        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + 5 ether);
    }

    function test_twentyMilestones_fullFlow() public {
        uint256 count = 20;
        uint256[] memory amounts = new uint256[](count);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < count; i++) {
            amounts[i] = (i + 1) * 0.1 ether; // 0.1, 0.2, 0.3, ... 2.0 ether
            totalAmount += amounts[i];
        }

        milestoneInstanceId = keccak256("twenty-milestones");

        _setupAndActivate(count, amounts);

        uint256 beneficiaryBalanceBefore = beneficiary.balance;

        // Confirm all
        for (uint256 i = 0; i < count; i++) {
            vm.prank(client);
            agreement.adapter_confirmAndRelease(milestoneInstanceId, i);
        }

        assertTrue(agreement.milestone_queryIsComplete(milestoneInstanceId));
        assertEq(agreement.milestone_queryTotalReleased(milestoneInstanceId), totalAmount);
        assertEq(beneficiary.balance, beneficiaryBalanceBefore + totalAmount);
    }

    function test_disputeAfterSomeReleased() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 3 ether;

        _setupAndActivate(3, amounts);

        // Release milestone 0
        vm.prank(client);
        agreement.adapter_confirmAndRelease(milestoneInstanceId, 0);

        // Now dispute milestone 1
        vm.prank(client);
        agreement.adapter_dispute(milestoneInstanceId, 1, keccak256("issue"));

        // Milestone 0 should still be RELEASED
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 0), MILESTONE_RELEASED);
        // Milestone 1 should be DISPUTED
        assertEq(agreement.milestone_queryMilestoneStatus(milestoneInstanceId, 1), MILESTONE_DISPUTED);

        // The escrow for milestone 0 should still be released
        assertTrue(agreement.escrow_queryIsReleased(_escrowId(0)));
        // The escrow for milestone 1 should still be funded (not released or refunded yet)
        assertTrue(agreement.escrow_queryIsFunded(_escrowId(1)));
    }
}

/// @title Invariant handler for MilestoneEscrowAdapter
contract AdapterInvariantHandler is Test {
    MockAgreement public agreement;

    bytes32 public milestoneInstanceId;
    uint256 public milestoneCount;
    uint256[] public amounts;

    address public beneficiary;
    address public client;

    bool public isSetup;
    bool public isActive;

    constructor(
        MockAgreement _agreement,
        address _beneficiary,
        address _client
    ) {
        agreement = _agreement;
        beneficiary = _beneficiary;
        client = _client;
    }

    function setup(uint256 count, uint256 amountSeed) external {
        if (isSetup) return;

        count = bound(count, 1, 5);
        milestoneInstanceId = keccak256(abi.encode("invariant", count, amountSeed));
        milestoneCount = count;

        amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            amounts[i] = bound(uint256(keccak256(abi.encode(amountSeed, i))), 0.1 ether, 5 ether);
        }

        // Setup milestones
        for (uint256 i = 0; i < count; i++) {
            agreement.milestone_intakeMilestone(
                milestoneInstanceId,
                keccak256(abi.encode("ms", i)),
                amounts[i]
            );
        }

        agreement.milestone_intakeBeneficiary(milestoneInstanceId, beneficiary);
        agreement.milestone_intakeClient(milestoneInstanceId, client);
        agreement.milestone_intakeToken(milestoneInstanceId, address(0));
        agreement.milestone_intakeReady(milestoneInstanceId);

        // Setup and fund escrows
        for (uint256 i = 0; i < count; i++) {
            bytes32 escrowId = _escrowId(i);

            agreement.escrow_intakeDepositor(escrowId, client);
            agreement.escrow_intakeBeneficiary(escrowId, beneficiary);
            agreement.escrow_intakeToken(escrowId, address(0));
            agreement.escrow_intakeAmount(escrowId, amounts[i]);
            agreement.escrow_intakeReady(escrowId);

            agreement.milestone_intakeMilestoneEscrowId(milestoneInstanceId, i, escrowId);

            vm.prank(client);
            agreement.escrow_actionDeposit{value: amounts[i]}(escrowId);
        }

        agreement.milestone_actionActivate(milestoneInstanceId);

        isSetup = true;
        isActive = true;
    }

    function confirmAndRelease(uint256 indexSeed) external {
        if (!isActive || !isSetup) return;

        uint256 index = indexSeed % milestoneCount;
        uint8 status = agreement.milestone_queryMilestoneStatus(milestoneInstanceId, index);

        // Can only confirm pending or requested milestones
        if (status == 1 || status == 2) {
            vm.prank(client);
            try agreement.adapter_confirmAndRelease(milestoneInstanceId, index) {
                // Success
            } catch {
                // Ignore failures
            }
        }
    }

    function dispute(uint256 indexSeed) external {
        if (!isActive || !isSetup) return;

        uint256 index = indexSeed % milestoneCount;
        uint8 status = agreement.milestone_queryMilestoneStatus(milestoneInstanceId, index);

        // Can only dispute pending or requested milestones
        if (status == 1 || status == 2) {
            vm.prank(client);
            try agreement.adapter_dispute(milestoneInstanceId, index, keccak256(abi.encode("d", index))) {
                // Success
            } catch {
                // Ignore failures
            }
        }
    }

    function resolveDispute(uint256 indexSeed, bool outcome) external {
        if (!isActive || !isSetup) return;

        uint256 index = indexSeed % milestoneCount;
        uint8 status = agreement.milestone_queryMilestoneStatus(milestoneInstanceId, index);

        // Can only resolve disputed milestones
        if (status == 4) {
            try agreement.adapter_resolveDisputeAndExecute(milestoneInstanceId, index, outcome) {
                // Success
            } catch {
                // Ignore failures
            }
        }
    }

    function _escrowId(uint256 index) internal view returns (bytes32) {
        return keccak256(abi.encode(milestoneInstanceId, "escrow", index));
    }

    function getMilestoneInstanceId() external view returns (bytes32) {
        return milestoneInstanceId;
    }

    function getMilestoneCount() external view returns (uint256) {
        return milestoneCount;
    }

    function getAmount(uint256 index) external view returns (uint256) {
        return amounts[index];
    }

    function getEscrowId(uint256 index) external view returns (bytes32) {
        return _escrowId(index);
    }
}

/// @title Invariant tests for MilestoneEscrowAdapter
contract MilestoneEscrowAdapterInvariantTest is Test {
    MilestoneClauseLogicV3 public milestoneClause;
    EscrowClauseLogicV3 public escrowClause;
    MilestoneEscrowAdapter public adapter;
    MockAgreement public agreement;
    AdapterInvariantHandler public handler;

    address public beneficiary;
    address public client;

    // Milestone state constants
    uint8 constant MILESTONE_RELEASED = 5;
    uint8 constant MILESTONE_REFUNDED = 6;

    function setUp() public {
        beneficiary = makeAddr("beneficiary");
        client = makeAddr("client");

        vm.deal(client, 1000 ether);
        vm.deal(beneficiary, 1 ether);

        milestoneClause = new MilestoneClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        adapter = new MilestoneEscrowAdapter(
            address(milestoneClause),
            address(escrowClause)
        );
        agreement = new MockAgreement(
            address(milestoneClause),
            address(escrowClause),
            address(adapter)
        );

        vm.deal(address(agreement), 1000 ether);

        handler = new AdapterInvariantHandler(agreement, beneficiary, client);

        targetContract(address(handler));
    }

    /// @notice Invariant: Released count never exceeds milestone count
    function invariant_releasedCountNeverExceedsMilestoneCount() public {
        if (!handler.isSetup()) return;

        bytes32 instanceId = handler.getMilestoneInstanceId();
        uint256 count = handler.getMilestoneCount();

        uint256 releasedCount = 0;
        for (uint256 i = 0; i < count; i++) {
            uint8 status = agreement.milestone_queryMilestoneStatus(instanceId, i);
            if (status == MILESTONE_RELEASED) {
                releasedCount++;
            }
        }

        assertTrue(releasedCount <= count, "Released count exceeds milestone count");
    }

    /// @notice Invariant: Milestone and Escrow states are consistent
    /// - If milestone is RELEASED, escrow must be RELEASED
    /// - If milestone is REFUNDED, escrow must be REFUNDED
    function invariant_milestoneEscrowStateConsistency() public {
        if (!handler.isSetup()) return;

        bytes32 instanceId = handler.getMilestoneInstanceId();
        uint256 count = handler.getMilestoneCount();

        for (uint256 i = 0; i < count; i++) {
            uint8 milestoneStatus = agreement.milestone_queryMilestoneStatus(instanceId, i);
            bytes32 escrowId = handler.getEscrowId(i);

            if (milestoneStatus == MILESTONE_RELEASED) {
                assertTrue(
                    agreement.escrow_queryIsReleased(escrowId),
                    "Milestone RELEASED but escrow not RELEASED"
                );
            }

            if (milestoneStatus == MILESTONE_REFUNDED) {
                assertTrue(
                    agreement.escrow_queryIsRefunded(escrowId),
                    "Milestone REFUNDED but escrow not REFUNDED"
                );
            }
        }
    }

    /// @notice Invariant: Total released matches sum of released milestone amounts
    function invariant_totalReleasedMatchesSum() public {
        if (!handler.isSetup()) return;

        bytes32 instanceId = handler.getMilestoneInstanceId();
        uint256 count = handler.getMilestoneCount();

        uint256 sumReleased = 0;
        for (uint256 i = 0; i < count; i++) {
            uint8 status = agreement.milestone_queryMilestoneStatus(instanceId, i);
            if (status == MILESTONE_RELEASED) {
                sumReleased += handler.getAmount(i);
            }
        }

        assertEq(
            agreement.milestone_queryTotalReleased(instanceId),
            sumReleased,
            "Total released doesn't match sum"
        );
    }

    /// @notice Invariant: Cannot have both RELEASED and REFUNDED for same milestone
    function invariant_mutuallyExclusiveTerminalStates() public {
        if (!handler.isSetup()) return;

        uint256 count = handler.getMilestoneCount();

        for (uint256 i = 0; i < count; i++) {
            bytes32 escrowId = handler.getEscrowId(i);

            bool isReleased = agreement.escrow_queryIsReleased(escrowId);
            bool isRefunded = agreement.escrow_queryIsRefunded(escrowId);

            assertFalse(
                isReleased && isRefunded,
                "Escrow cannot be both released and refunded"
            );
        }
    }
}
