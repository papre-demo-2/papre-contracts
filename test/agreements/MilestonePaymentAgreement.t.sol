// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MilestonePaymentAgreement} from "../../src/agreements/MilestonePaymentAgreement.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../../src/clauses/orchestration/MilestoneClauseLogicV3.sol";
import {MilestoneEscrowAdapter} from "../../src/adapters/MilestoneEscrowAdapter.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title MilestonePaymentAgreementTest
 * @notice Comprehensive tests for MilestonePaymentAgreement
 *         Covers multi-milestone flows, concurrent projects, edge cases
 */
contract MilestonePaymentAgreementTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Clause contracts
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    MilestoneClauseLogicV3 public milestoneClause;
    MilestoneEscrowAdapter public milestoneAdapter;

    // Agreement implementation
    MilestonePaymentAgreement public implementation;

    // Test accounts
    uint256 clientPk;
    uint256 contractorPk;
    address client;
    address contractor;

    // Events (must match contract)
    event InstanceCreated(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event ProjectConfigured(
        uint256 indexed instanceId,
        address indexed client,
        address indexed contractor,
        uint8 milestoneCount,
        uint256 totalAmount,
        bytes32 documentCID
    );
    event TermsAccepted(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event ProjectFunded(uint256 indexed instanceId, address indexed client, uint256 totalAmount);
    event MilestoneSubmitted(uint256 indexed instanceId, uint8 milestoneIndex, bytes32 deliverableHash, string message);
    event MilestoneApproved(uint256 indexed instanceId, uint8 milestoneIndex, uint256 amount);
    event MilestoneRejected(uint256 indexed instanceId, uint8 milestoneIndex, string reason);
    event ProjectCompleted(uint256 indexed instanceId, address indexed contractor, uint256 totalPaid);
    event ProjectCancelled(uint256 indexed instanceId, address indexed cancelledBy);

    function setUp() public {
        // Deploy clauses
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        milestoneClause = new MilestoneClauseLogicV3();
        milestoneAdapter = new MilestoneEscrowAdapter(address(milestoneClause), address(escrowClause));

        // Deploy implementation
        implementation = new MilestonePaymentAgreement(
            address(signatureClause), address(escrowClause), address(milestoneClause), address(milestoneAdapter)
        );

        // Create accounts
        clientPk = 0x1;
        contractorPk = 0x2;
        client = vm.addr(clientPk);
        contractor = vm.addr(contractorPk);

        vm.deal(client, 100 ether);
        vm.deal(contractor, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function _createThreeMilestoneProject() internal returns (MilestonePaymentAgreement) {
        bytes32[] memory descriptions = new bytes32[](3);
        descriptions[0] = keccak256("Design Phase");
        descriptions[1] = keccak256("Development Phase");
        descriptions[2] = keccak256("Testing Phase");

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5 ether;
        amounts[1] = 15 ether;
        amounts[2] = 5 ether;

        uint256[] memory deadlines = new uint256[](3);
        deadlines[0] = block.timestamp + 2 weeks;
        deadlines[1] = block.timestamp + 6 weeks;
        deadlines[2] = block.timestamp + 8 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        bytes32 documentCID = keccak256("test-document-cid");

        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, documentCID);

        return agreement;
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signTerms(MilestonePaymentAgreement agreement, uint256 pk) internal {
        // Get terms hash from the milestone configs
        bytes32[] memory descriptions = new bytes32[](3);
        descriptions[0] = keccak256("Design Phase");
        descriptions[1] = keccak256("Development Phase");
        descriptions[2] = keccak256("Testing Phase");

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 5 ether;
        amounts[1] = 15 ether;
        amounts[2] = 5 ether;

        uint256[] memory deadlines = new uint256[](3);
        deadlines[0] = block.timestamp + 2 weeks;
        deadlines[1] = block.timestamp + 6 weeks;
        deadlines[2] = block.timestamp + 8 weeks;

        bytes32 termsHash = keccak256(abi.encode(descriptions, amounts, deadlines));
        bytes memory signature = _signMessage(pk, termsHash);

        vm.prank(vm.addr(pk));
        agreement.signTerms(0, signature); // instanceId = 0 for proxy mode
    }

    function _signAndFundProject(MilestonePaymentAgreement agreement) internal {
        _signTerms(agreement, clientPk);
        _signTerms(agreement, contractorPk);

        vm.prank(client);
        agreement.fundProject{value: 25 ether}(0); // instanceId = 0 for proxy mode
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Initialize_ThreeMilestones() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        assertEq(agreement.getClient(), client);
        assertEq(agreement.getContractor(), contractor);
        assertEq(agreement.getMilestoneCount(), 3);
        assertEq(agreement.getTotalAmount(), 25 ether);
    }

    function test_Initialize_MilestoneDetails() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        (bytes32 desc0, uint256 amt0, uint256 deadline0,,,,,) = agreement.getMilestone(0);
        (bytes32 desc1, uint256 amt1,,,,,,) = agreement.getMilestone(1);
        (bytes32 desc2, uint256 amt2,,,,,,) = agreement.getMilestone(2);

        assertEq(desc0, keccak256("Design Phase"));
        assertEq(amt0, 5 ether);
        assertEq(desc1, keccak256("Development Phase"));
        assertEq(amt1, 15 ether);
        assertEq(desc2, keccak256("Testing Phase"));
        assertEq(amt2, 5 ether);
    }

    function test_GetDocumentCID() public {
        bytes32 testCID = keccak256("my-specific-document-cid");

        bytes32[] memory descriptions = new bytes32[](1);
        descriptions[0] = keccak256("Test Milestone");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 1 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, testCID);

        assertEq(agreement.getDocumentCID(0), testCID);
    }

    function test_SetDocumentCID_Success() public {
        // Create agreement with zero CID
        bytes32[] memory descriptions = new bytes32[](1);
        descriptions[0] = keccak256("Test Milestone");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 1 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        // Initialize with zero CID - in proxy mode, creator is set to client
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, bytes32(0));

        // Verify CID is zero initially
        assertEq(agreement.getDocumentCID(0), bytes32(0));

        // Set CID as client (who is the creator in proxy mode)
        bytes32 newCID = keccak256("uploaded-document-cid");
        vm.prank(client);
        agreement.setDocumentCID(0, newCID);

        // Verify CID is now set
        assertEq(agreement.getDocumentCID(0), newCID);
    }

    function test_SetDocumentCID_RevertsIfNotCreator() public {
        bytes32[] memory descriptions = new bytes32[](1);
        descriptions[0] = keccak256("Test Milestone");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 1 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        // In proxy mode, creator is client
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, bytes32(0));

        // Try to set CID as contractor (not the creator)
        bytes32 newCID = keccak256("uploaded-document-cid");
        vm.prank(contractor);
        vm.expectRevert(MilestonePaymentAgreement.OnlyCreator.selector);
        agreement.setDocumentCID(0, newCID);
    }

    function test_SetDocumentCID_RevertsIfAlreadySet() public {
        bytes32 initialCID = keccak256("initial-document-cid");

        bytes32[] memory descriptions = new bytes32[](1);
        descriptions[0] = keccak256("Test Milestone");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 1 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        // Initialize with non-zero CID - creator is client in proxy mode
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, initialCID);

        // Try to set CID again as client (the creator)
        bytes32 newCID = keccak256("new-document-cid");
        vm.prank(client);
        vm.expectRevert(MilestonePaymentAgreement.DocumentCIDAlreadySet.selector);
        agreement.setDocumentCID(0, newCID);
    }

    function test_SetDocumentCID_RevertsIfZeroCID() public {
        bytes32[] memory descriptions = new bytes32[](1);
        descriptions[0] = keccak256("Test Milestone");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 1 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        // In proxy mode, creator is client
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, bytes32(0));

        // Try to set zero CID as client (the creator)
        vm.prank(client);
        vm.expectRevert(MilestonePaymentAgreement.InvalidDocumentCID.selector);
        agreement.setDocumentCID(0, bytes32(0));
    }

    function test_Initialize_RevertsOnZeroMilestones() public {
        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        bytes32[] memory descriptions = new bytes32[](0);
        uint256[] memory amounts = new uint256[](0);
        uint256[] memory deadlines = new uint256[](0);

        vm.expectRevert(MilestonePaymentAgreement.TooManyMilestones.selector);
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, bytes32(0));
    }

    function test_Initialize_RevertsOnTooManyMilestones() public {
        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        bytes32[] memory descriptions = new bytes32[](11);
        uint256[] memory amounts = new uint256[](11);
        uint256[] memory deadlines = new uint256[](11);

        for (uint8 i = 0; i < 11; i++) {
            descriptions[i] = keccak256(abi.encode(i));
            amounts[i] = 1 ether;
            deadlines[i] = block.timestamp + 1 days;
        }

        vm.expectRevert(MilestonePaymentAgreement.TooManyMilestones.selector);
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, bytes32(0));
    }

    function test_Initialize_RevertsOnMismatchedArrays() public {
        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        bytes32[] memory descriptions = new bytes32[](3);
        uint256[] memory amounts = new uint256[](2); // Mismatched
        uint256[] memory deadlines = new uint256[](3);

        vm.expectRevert(MilestonePaymentAgreement.InvalidMilestoneConfig.selector);
        agreement.initialize(client, contractor, address(0), descriptions, amounts, deadlines, bytes32(0));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FUNDING TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_FundProject_Success() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        _signTerms(agreement, clientPk);
        _signTerms(agreement, contractorPk);

        vm.expectEmit(true, true, false, true);
        emit ProjectFunded(0, client, 25 ether);

        vm.prank(client);
        agreement.fundProject{value: 25 ether}(0);

        (, bool funded,,) = agreement.getProjectState();
        assertTrue(funded);
    }

    function test_FundProject_RevertsIfTermsNotAccepted() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        vm.prank(client);
        vm.expectRevert(MilestonePaymentAgreement.TermsNotAccepted.selector);
        agreement.fundProject{value: 25 ether}(0);
    }

    function test_FundProject_RevertsIfNotClient() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        _signTerms(agreement, clientPk);
        _signTerms(agreement, contractorPk);

        // Give contractor enough ETH for the attempt
        vm.deal(contractor, 30 ether);

        vm.prank(contractor);
        vm.expectRevert(MilestonePaymentAgreement.OnlyClient.selector);
        agreement.fundProject{value: 25 ether}(0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    MILESTONE COMPLETION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_RequestMilestoneConfirmation_Success() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        vm.expectEmit(true, false, false, true);
        emit MilestoneSubmitted(0, 0, keccak256("Design Phase"), "Design work completed");

        vm.prank(contractor);
        agreement.requestMilestoneConfirmation(0, 0, "Design work completed");
    }

    function test_RequestMilestoneConfirmation_RevertsIfNotFunded() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        _signTerms(agreement, clientPk);
        _signTerms(agreement, contractorPk);

        vm.prank(contractor);
        vm.expectRevert(MilestonePaymentAgreement.NotFunded.selector);
        agreement.requestMilestoneConfirmation(0, 0, "");
    }

    function test_RequestMilestoneConfirmation_RevertsIfNotContractor() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        vm.prank(client);
        vm.expectRevert(MilestonePaymentAgreement.OnlyContractor.selector);
        agreement.requestMilestoneConfirmation(0, 0, "");
    }

    function test_ApproveMilestone_Success() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        vm.prank(contractor);
        agreement.requestMilestoneConfirmation(0, 0, "Work complete");

        uint256 contractorBefore = contractor.balance;

        vm.expectEmit(true, false, false, true);
        emit MilestoneApproved(0, 0, 5 ether);

        vm.prank(client);
        agreement.approveMilestone(0, 0);

        assertEq(contractor.balance, contractorBefore + 5 ether);
        assertEq(agreement.getCompletedMilestones(), 1);
    }

    function test_ApproveMilestone_RevertsIfNotClient() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        vm.prank(contractor);
        agreement.requestMilestoneConfirmation(0, 0, "");

        vm.prank(contractor);
        vm.expectRevert(MilestonePaymentAgreement.OnlyClient.selector);
        agreement.approveMilestone(0, 0);
    }

    function test_RejectMilestone_Success() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        vm.prank(contractor);
        agreement.requestMilestoneConfirmation(0, 0, "");

        vm.expectEmit(true, false, false, true);
        emit MilestoneRejected(0, 0, "Poor quality");

        vm.prank(client);
        agreement.rejectMilestone(0, 0, "Poor quality");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FULL PROJECT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════

    function test_FullProject_AllMilestonesComplete() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        uint256 contractorBefore = contractor.balance;

        // Complete all three milestones
        for (uint8 i = 0; i < 3; i++) {
            vm.prank(contractor);
            agreement.requestMilestoneConfirmation(0, i, "");

            vm.prank(client);
            agreement.approveMilestone(0, i);
        }

        assertEq(agreement.getCompletedMilestones(), 3);
        assertEq(contractor.balance, contractorBefore + 25 ether);

        (,, uint8 completed, uint8 total) = agreement.getProjectState();
        assertEq(completed, total);
    }

    function test_FullProject_OutOfOrderApprovals() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        // Request all milestones
        for (uint8 i = 0; i < 3; i++) {
            vm.prank(contractor);
            agreement.requestMilestoneConfirmation(0, i, "");
        }

        // Approve in reverse order
        vm.prank(client);
        agreement.approveMilestone(0, 2);
        vm.prank(client);
        agreement.approveMilestone(0, 0);
        vm.prank(client);
        agreement.approveMilestone(0, 1);

        assertEq(agreement.getCompletedMilestones(), 3);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCELLATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_CancelRemainingMilestones_PartialComplete() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        // Complete first milestone
        vm.prank(contractor);
        agreement.requestMilestoneConfirmation(0, 0, "");
        vm.prank(client);
        agreement.approveMilestone(0, 0);

        uint256 contractorBefore = contractor.balance;
        uint256 clientBefore = client.balance;

        // Cancel remaining
        vm.prank(client);
        agreement.cancelRemainingMilestones(0);

        // Contractor should have 5 ether from milestone 0
        // Plus 50% of remaining 20 ether = 10 ether (kill fee)
        assertEq(contractor.balance, contractorBefore + 10 ether);
        assertEq(client.balance, clientBefore + 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    MULTIPLE PROJECTS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_MultipleProjects_Independent() public {
        // Create two projects
        MilestonePaymentAgreement project1 = _createThreeMilestoneProject();
        MilestonePaymentAgreement project2 = _createThreeMilestoneProject();

        // Fund and work on project1
        _signAndFundProject(project1);
        vm.prank(contractor);
        project1.requestMilestoneConfirmation(0, 0, "");
        vm.prank(client);
        project1.approveMilestone(0, 0);

        // Project2 should be unaffected
        (bool termsAccepted,,,) = project2.getProjectState();
        assertFalse(termsAccepted);
        assertEq(project2.getCompletedMilestones(), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    EDGE CASES
    // ═══════════════════════════════════════════════════════════════

    function test_InvalidMilestoneIndex_Reverts() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();
        _signAndFundProject(agreement);

        vm.prank(contractor);
        vm.expectRevert(MilestonePaymentAgreement.InvalidMilestoneIndex.selector);
        agreement.requestMilestoneConfirmation(0, 5, "");
    }

    function test_SingleMilestone_Success() public {
        bytes32[] memory descriptions = new bytes32[](1);
        descriptions[0] = keccak256("Full Project");

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;

        uint256[] memory deadlines = new uint256[](1);
        deadlines[0] = block.timestamp + 4 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        agreement.initialize(
            client, contractor, address(0), descriptions, amounts, deadlines, keccak256("single-milestone-doc")
        );

        // Sign and fund
        bytes32 termsHash = keccak256(abi.encode(descriptions, amounts, deadlines));

        vm.prank(client);
        agreement.signTerms(0, _signMessage(clientPk, termsHash));

        vm.prank(contractor);
        agreement.signTerms(0, _signMessage(contractorPk, termsHash));

        vm.prank(client);
        agreement.fundProject{value: 10 ether}(0);

        // Complete
        vm.prank(contractor);
        agreement.requestMilestoneConfirmation(0, 0, "");

        uint256 contractorBefore = contractor.balance;

        vm.prank(client);
        agreement.approveMilestone(0, 0);

        assertEq(contractor.balance, contractorBefore + 10 ether);
    }

    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════
    //                    PENDING COUNTERPARTY TESTS
    // ═══════════════════════════════════════════════════════════════

    uint256 constant ATTESTOR_PK = 0xA77E5702;

    function _createProjectWithPendingContractor() internal returns (MilestonePaymentAgreement, uint256) {
        bytes32[] memory descriptions = new bytes32[](2);
        descriptions[0] = keccak256("Phase 1");
        descriptions[1] = keccak256("Phase 2");

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5 ether;
        amounts[1] = 10 ether;

        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = block.timestamp + 2 weeks;
        deadlines[1] = block.timestamp + 4 weeks;

        // Create instance on singleton with pending contractor (address(0))
        uint256 instanceId = implementation.createInstance(
            client,
            address(0), // Pending contractor
            address(0), // ETH payment
            descriptions,
            amounts,
            deadlines,
            keccak256("pending-contractor-doc")
        );

        return (implementation, instanceId);
    }

    function _createClaimAttestation(address agreement, bytes32 termsSignatureId, uint256 slotIndex, address claimer)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 messageHash =
            keccak256(abi.encode(agreement, termsSignatureId, slotIndex, claimer, "CLAIM_SIGNER_SLOT"));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTOR_PK, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function test_CreateInstance_WithPendingContractor() public {
        (MilestonePaymentAgreement agreement, uint256 instanceId) = _createProjectWithPendingContractor();

        (,,, address instanceClient, address instanceContractor,, uint256 totalAmount, uint8 milestoneCount) =
            agreement.getInstance(instanceId);

        assertEq(instanceClient, client);
        assertEq(instanceContractor, address(0)); // Pending
        assertEq(totalAmount, 15 ether);
        assertEq(milestoneCount, 2);
    }

    function test_HasPendingContractor_True() public {
        (MilestonePaymentAgreement agreement, uint256 instanceId) = _createProjectWithPendingContractor();

        assertTrue(agreement.hasPendingContractor(instanceId));
    }

    function test_HasPendingContractor_False() public {
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        // Proxy mode uses instanceId = 0, contractor is set
        assertFalse(agreement.hasPendingContractor(0));
    }

    function test_SetTrustedAttestor_FromAgreement() public {
        address attestor = vm.addr(ATTESTOR_PK);

        // Set trusted attestor on implementation (singleton)
        implementation.setTrustedAttestor(attestor, true);

        // Note: We can't directly query the signature clause's trustedAttestors
        // because it uses delegatecall. The test passes if no revert.
    }

    function test_ClaimContractorSlot_Success() public {
        // Setup attestor
        address attestor = vm.addr(ATTESTOR_PK);
        implementation.setTrustedAttestor(attestor, true);

        // Create instance with pending contractor
        (MilestonePaymentAgreement agreement, uint256 instanceId) = _createProjectWithPendingContractor();

        // Generate the termsSignatureId (matches how agreement generates it)
        bytes32 termsSignatureId = keccak256(abi.encode(address(agreement), instanceId, "terms"));

        // Create attestation for contractor to claim slot 1
        bytes memory attestation = _createClaimAttestation(
            address(agreement),
            termsSignatureId,
            1, // Contractor is slot 1
            contractor
        );

        // Contractor claims the slot
        vm.prank(contractor);
        agreement.claimContractorSlot(instanceId, attestation);

        // Verify contractor is now set
        (,,,, address instanceContractor,,,) = agreement.getInstance(instanceId);
        assertEq(instanceContractor, contractor);

        // Verify no longer pending
        assertFalse(agreement.hasPendingContractor(instanceId));
    }

    function test_ClaimContractorSlot_AlreadySet_Reverts() public {
        // Use regular project where contractor is already set
        MilestonePaymentAgreement agreement = _createThreeMilestoneProject();

        // Try to claim contractor slot on proxy mode (instanceId = 0)
        // This should fail because contractor is already set
        vm.expectRevert(MilestonePaymentAgreement.ContractorAlreadySet.selector);
        vm.prank(contractor);
        agreement.claimContractorSlot(0, "");
    }

    function test_FullFlow_PendingContractor_Claim_Sign_Fund() public {
        // Setup attestor
        address attestor = vm.addr(ATTESTOR_PK);
        implementation.setTrustedAttestor(attestor, true);

        // Create instance with pending contractor
        bytes32[] memory descriptions = new bytes32[](2);
        descriptions[0] = keccak256("Phase 1");
        descriptions[1] = keccak256("Phase 2");

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5 ether;
        amounts[1] = 10 ether;

        uint256[] memory deadlines = new uint256[](2);
        deadlines[0] = block.timestamp + 2 weeks;
        deadlines[1] = block.timestamp + 4 weeks;

        uint256 instanceId = implementation.createInstance(
            client,
            address(0), // Pending contractor
            address(0), // ETH
            descriptions,
            amounts,
            deadlines,
            keccak256("full-flow-pending-doc")
        );

        // Generate termsSignatureId
        bytes32 termsSignatureId = keccak256(abi.encode(address(implementation), instanceId, "terms"));

        // Contractor claims slot
        bytes memory attestation = _createClaimAttestation(address(implementation), termsSignatureId, 1, contractor);

        vm.prank(contractor);
        implementation.claimContractorSlot(instanceId, attestation);

        // Verify contractor is set
        assertEq(implementation.hasPendingContractor(instanceId), false);

        // Both parties sign
        bytes32 termsHash = keccak256(abi.encode(descriptions, amounts, deadlines));

        vm.prank(client);
        implementation.signTerms(instanceId, _signMessage(clientPk, termsHash));

        vm.prank(contractor);
        implementation.signTerms(instanceId, _signMessage(contractorPk, termsHash));

        // Verify terms accepted
        (bool termsAccepted,,,, bool cancelled) = implementation.getInstanceState(instanceId);
        assertTrue(termsAccepted);
        assertFalse(cancelled);

        // Client funds
        vm.prank(client);
        implementation.fundProject{value: 15 ether}(instanceId);

        // Verify funded
        assertTrue(implementation.isFunded(instanceId));

        // Complete first milestone
        vm.prank(contractor);
        implementation.requestMilestoneConfirmation(instanceId, 0, "");

        uint256 contractorBalanceBefore = contractor.balance;

        vm.prank(client);
        implementation.approveMilestone(instanceId, 0);

        // Verify payment received
        assertEq(contractor.balance, contractorBalanceBefore + 5 ether);
    }
}

/**
 * @title MilestonePaymentAgreementFuzzTest
 * @notice Fuzz tests for variable milestone configurations
 */
contract MilestonePaymentAgreementFuzzTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    MilestoneClauseLogicV3 public milestoneClause;
    MilestoneEscrowAdapter public milestoneAdapter;
    MilestonePaymentAgreement public implementation;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        milestoneClause = new MilestoneClauseLogicV3();
        milestoneAdapter = new MilestoneEscrowAdapter(address(milestoneClause), address(escrowClause));
        implementation = new MilestonePaymentAgreement(
            address(signatureClause), address(escrowClause), address(milestoneClause), address(milestoneAdapter)
        );
    }

    function testFuzz_VariableMilestoneCount(uint8 count) public {
        count = uint8(bound(uint256(count), 1, 10));

        uint256 clientPk = 0x1;
        uint256 contractorPk = 0x2;
        address client = vm.addr(clientPk);
        address contractor = vm.addr(contractorPk);

        bytes32[] memory descriptions = new bytes32[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256[] memory deadlines = new uint256[](count);

        uint256 totalAmount = 0;
        for (uint8 i = 0; i < count; i++) {
            descriptions[i] = keccak256(abi.encode("milestone", i));
            amounts[i] = (uint256(i) + 1) * 1 ether;
            deadlines[i] = block.timestamp + (uint256(i) + 1) * 1 weeks;
            totalAmount += amounts[i];
        }

        vm.deal(client, totalAmount + 10 ether);
        vm.deal(contractor, 1 ether);

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        agreement.initialize(
            client, contractor, address(0), descriptions, amounts, deadlines, keccak256(abi.encode("fuzz-doc", count))
        );

        assertEq(agreement.getMilestoneCount(), count);
        assertEq(agreement.getTotalAmount(), totalAmount);
    }

    function testFuzz_VariableAmounts(uint128 amt1, uint128 amt2, uint128 amt3) public {
        amt1 = uint128(bound(uint256(amt1), 0.01 ether, 100 ether));
        amt2 = uint128(bound(uint256(amt2), 0.01 ether, 100 ether));
        amt3 = uint128(bound(uint256(amt3), 0.01 ether, 100 ether));

        uint256 clientPk = 0x1;
        uint256 contractorPk = 0x2;
        address client = vm.addr(clientPk);
        address contractor = vm.addr(contractorPk);

        uint256 totalAmount = uint256(amt1) + uint256(amt2) + uint256(amt3);
        vm.deal(client, totalAmount + 10 ether);
        vm.deal(contractor, 1 ether);

        bytes32[] memory descriptions = new bytes32[](3);
        descriptions[0] = keccak256("m1");
        descriptions[1] = keccak256("m2");
        descriptions[2] = keccak256("m3");

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = amt1;
        amounts[1] = amt2;
        amounts[2] = amt3;

        uint256[] memory deadlines = new uint256[](3);
        deadlines[0] = block.timestamp + 1 weeks;
        deadlines[1] = block.timestamp + 2 weeks;
        deadlines[2] = block.timestamp + 3 weeks;

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        agreement.initialize(
            client,
            contractor,
            address(0),
            descriptions,
            amounts,
            deadlines,
            keccak256(abi.encode("fuzz-amounts-doc", amt1, amt2, amt3))
        );

        assertEq(agreement.getTotalAmount(), totalAmount);

        // Verify each milestone
        for (uint8 i = 0; i < 3; i++) {
            (, uint256 storedAmt,,,,,,) = agreement.getMilestone(i);
            assertEq(storedAmt, amounts[i]);
        }
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}

/**
 * @title MilestonePaymentAgreementInvariantTest
 * @notice Invariant tests for milestone payment consistency
 */
contract MilestonePaymentAgreementInvariantTest is Test {
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    MilestoneClauseLogicV3 public milestoneClause;
    MilestoneEscrowAdapter public milestoneAdapter;
    MilestonePaymentAgreement public implementation;

    MilestonePaymentHandler public handler;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        milestoneClause = new MilestoneClauseLogicV3();
        milestoneAdapter = new MilestoneEscrowAdapter(address(milestoneClause), address(escrowClause));
        implementation = new MilestonePaymentAgreement(
            address(signatureClause), address(escrowClause), address(milestoneClause), address(milestoneAdapter)
        );

        handler = new MilestonePaymentHandler(implementation);
        targetContract(address(handler));
    }

    function invariant_CompletedNeverExceedsTotal() public view {
        MilestonePaymentAgreement[] memory agreements = handler.getAgreements();
        for (uint256 i = 0; i < agreements.length; i++) {
            (,, uint8 completed, uint8 total) = agreements[i].getProjectState();
            assertLe(completed, total);
        }
    }

    function invariant_TotalAmountConsistent() public view {
        MilestonePaymentAgreement[] memory agreements = handler.getAgreements();
        for (uint256 i = 0; i < agreements.length; i++) {
            uint256 total = agreements[i].getTotalAmount();
            uint256 summedAmounts = 0;

            uint8 count = agreements[i].getMilestoneCount();
            for (uint8 j = 0; j < count; j++) {
                (, uint256 amt,,,,,,) = agreements[i].getMilestone(j);
                summedAmounts += amt;
            }

            assertEq(total, summedAmounts);
        }
    }

    receive() external payable {}
}

/**
 * @title MilestonePaymentHandler
 * @notice Handler for invariant testing
 */
contract MilestonePaymentHandler is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    MilestonePaymentAgreement public implementation;
    MilestonePaymentAgreement[] public agreements;

    uint256 public constant MAX_AGREEMENTS = 3;

    constructor(MilestonePaymentAgreement _implementation) {
        implementation = _implementation;
    }

    function createAgreement(uint256 seed) external {
        if (agreements.length >= MAX_AGREEMENTS) return;

        uint256 milestoneCount = (seed % 5) + 1;

        uint256 clientPk = seed % 1000 + 1;
        address client = vm.addr(clientPk);

        uint256 contractorPk = seed % 1000 + 1001;
        address contractor = vm.addr(contractorPk);

        bytes32[] memory descriptions = new bytes32[](milestoneCount);
        uint256[] memory amounts = new uint256[](milestoneCount);
        uint256[] memory deadlines = new uint256[](milestoneCount);

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < milestoneCount; i++) {
            descriptions[i] = keccak256(abi.encode(seed, i));
            amounts[i] = ((seed % 10) + 1) * 0.1 ether;
            deadlines[i] = block.timestamp + (i + 1) * 1 weeks;
            totalAmount += amounts[i];
        }

        vm.deal(client, totalAmount + 10 ether);
        vm.deal(contractor, 1 ether);

        MilestonePaymentAgreement agreement = MilestonePaymentAgreement(payable(Clones.clone(address(implementation))));

        agreement.initialize(
            client, contractor, address(0), descriptions, amounts, deadlines, keccak256(abi.encode("handler-doc", seed))
        );

        agreements.push(agreement);
    }

    function getAgreements() external view returns (MilestonePaymentAgreement[] memory) {
        return agreements;
    }

    receive() external payable {}
}
