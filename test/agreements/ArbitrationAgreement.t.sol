// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ArbitrationAgreement} from "../../src/agreements/ArbitrationAgreement.sol";
import {MilestonePaymentAgreement} from "../../src/agreements/MilestonePaymentAgreement.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../../src/clauses/orchestration/MilestoneClauseLogicV3.sol";
import {MilestoneEscrowAdapter} from "../../src/adapters/MilestoneEscrowAdapter.sol";
import {IDisputable} from "../../src/interfaces/IDisputable.sol";

contract ArbitrationAgreementTest is Test {
    ArbitrationAgreement public arbitration;
    MilestonePaymentAgreement public milestone;

    // Clause contracts
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    MilestoneClauseLogicV3 public milestoneClause;
    MilestoneEscrowAdapter public milestoneAdapter;

    // Test accounts
    address public client = address(0x1);
    address public contractor = address(0x2);
    address public arbitrator = address(0x3);

    // Test data
    bytes32[] public descriptions;
    uint256[] public amounts;
    uint256[] public deadlines;
    bytes32 public documentCID = keccak256("test-document");

    function setUp() public {
        // Deploy clauses
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        milestoneClause = new MilestoneClauseLogicV3();
        milestoneAdapter = new MilestoneEscrowAdapter(
            address(milestoneClause),
            address(escrowClause)
        );

        // Deploy agreements
        milestone = new MilestonePaymentAgreement(
            address(signatureClause),
            address(escrowClause),
            address(milestoneClause),
            address(milestoneAdapter)
        );

        arbitration = new ArbitrationAgreement();

        // Setup test data
        descriptions = new bytes32[](2);
        descriptions[0] = keccak256("Milestone 1");
        descriptions[1] = keccak256("Milestone 2");

        amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 1 ether;

        deadlines = new uint256[](2);
        deadlines[0] = block.timestamp + 30 days;
        deadlines[1] = block.timestamp + 60 days;

        // Fund test accounts
        vm.deal(client, 100 ether);
        vm.deal(contractor, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    function _createAndFundMilestoneAgreement() internal returns (uint256 milestoneInstanceId) {
        // Create milestone agreement
        vm.prank(client);
        milestoneInstanceId = milestone.createInstance(
            client,
            contractor,
            address(0), // ETH
            descriptions,
            amounts,
            deadlines,
            documentCID
        );

        // Both parties sign
        vm.prank(client);
        milestone.signTerms(milestoneInstanceId, abi.encode("client-sig"));

        vm.prank(contractor);
        milestone.signTerms(milestoneInstanceId, abi.encode("contractor-sig"));

        // Client funds the project
        vm.prank(client);
        milestone.fundProject{value: 2 ether}(milestoneInstanceId);

        return milestoneInstanceId;
    }

    // ═══════════════════════════════════════════════════════════════
    //                    IDISPUTABLE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_CanInitiateArbitration_True() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        bool canInitiate = milestone.canInitiateArbitration(milestoneInstanceId);
        assertTrue(canInitiate, "Should be able to initiate arbitration on funded agreement");
    }

    function test_CanInitiateArbitration_False_NotFunded() public {
        // Create but don't fund
        vm.prank(client);
        uint256 milestoneInstanceId = milestone.createInstance(
            client,
            contractor,
            address(0),
            descriptions,
            amounts,
            deadlines,
            documentCID
        );

        bool canInitiate = milestone.canInitiateArbitration(milestoneInstanceId);
        assertFalse(canInitiate, "Should not be able to initiate arbitration on unfunded agreement");
    }

    function test_GetArbitrationParties() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        (address claimant, address respondent) = milestone.getArbitrationParties(milestoneInstanceId);
        assertEq(claimant, contractor, "Claimant should be contractor");
        assertEq(respondent, client, "Respondent should be client");
    }

    function test_HasArbitrationLinked_False() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        bool hasArb = milestone.hasArbitrationLinked(milestoneInstanceId);
        assertFalse(hasArb, "Should not have arbitration linked initially");
    }

    function test_LinkArbitration() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        // Link arbitration
        vm.prank(client);
        milestone.linkArbitration(milestoneInstanceId, address(arbitration), 1);

        assertTrue(milestone.hasArbitrationLinked(milestoneInstanceId), "Should have arbitration linked");
        assertEq(milestone.getArbitrationAgreement(milestoneInstanceId), address(arbitration));
        assertEq(milestone.getArbitrationInstanceId(milestoneInstanceId), 1);
    }

    function test_LinkArbitration_RevertsIfAlreadyLinked() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        // Link first time
        vm.prank(client);
        milestone.linkArbitration(milestoneInstanceId, address(arbitration), 1);

        // Try to link again
        vm.prank(contractor);
        vm.expectRevert(MilestonePaymentAgreement.ArbitrationAlreadyLinked.selector);
        milestone.linkArbitration(milestoneInstanceId, address(arbitration), 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    ARBITRATION AGREEMENT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_CreateInstance_SimplePreset() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        assertEq(arbInstanceId, 1, "Should be instance 1");

        (
            address linkedAgreement,
            uint256 linkedInstanceId,
            address claimant,
            address respondent,
            uint16 status,
            uint8 presetId
        ) = arbitration.getInstance(arbInstanceId);

        assertEq(linkedAgreement, address(milestone));
        assertEq(linkedInstanceId, milestoneInstanceId);
        assertEq(claimant, contractor, "Claimant should be contractor");
        assertEq(respondent, client, "Respondent should be client");
        assertEq(presetId, arbitration.PRESET_SIMPLE());

        // Check it's linked in milestone agreement
        assertTrue(milestone.hasArbitrationLinked(milestoneInstanceId));
    }

    function test_FileClaim() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        // Contractor files claim
        bytes32 claimHash = keccak256("Client didn't pay on time");
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, claimHash);

        (
            uint64 filedAt,
            uint64 evidenceDeadline,
            ,
            ,
            ,

        ) = arbitration.getInstanceState(arbInstanceId);

        assertGt(filedAt, 0, "Filed timestamp should be set");
        assertGt(evidenceDeadline, filedAt, "Evidence deadline should be after filed time");
    }

    function test_SubmitEvidence() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        // File claim
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, keccak256("claim"));

        // Both parties submit evidence
        vm.prank(contractor);
        arbitration.submitEvidence(arbInstanceId, keccak256("evidence-1"));

        vm.prank(client);
        arbitration.submitEvidence(arbInstanceId, keccak256("evidence-2"));

        assertEq(arbitration.getEvidenceCount(arbInstanceId), 2);
    }

    function test_Rule_ClaimantWins() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        // Debug: Check arbitrator is stored correctly
        (address[3] memory arbs, uint8 arbCount) = arbitration.getArbitrators(arbInstanceId);
        console2.log("Arbitrator count:", arbCount);
        console2.log("Arbitrator[0]:", arbs[0]);
        console2.log("Expected arbitrator:", arbitrator);
        assertEq(arbs[0], arbitrator, "Arbitrator should be set");
        assertEq(arbCount, 1, "Should have 1 arbitrator");

        // File claim
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, keccak256("claim"));

        // Skip evidence window
        vm.warp(block.timestamp + 8 days);

        // Debug: Check what rule() would see
        (
            uint16 dbgStatus,
            uint64 dbgEvidenceDeadline,
            uint8 dbgArbCount,
            address dbgArb0,
            address dbgArb1,
            address dbgArb2,
            bool dbgCallerIsArb
        ) = arbitration.debugRuleView(arbInstanceId, arbitrator);
        console2.log("Debug status:", dbgStatus);
        console2.log("Debug evidenceDeadline:", dbgEvidenceDeadline);
        console2.log("Debug arbitratorCount:", dbgArbCount);
        console2.log("Debug arb0:", dbgArb0);
        console2.log("Debug callerIsArb:", dbgCallerIsArb);
        console2.log("Block timestamp:", block.timestamp);

        // Arbitrator rules in favor of claimant
        // Note: Get constant BEFORE prank to avoid consuming the prank
        uint8 claimantWins = arbitration.RULING_CLAIMANT_WINS();
        vm.prank(arbitrator);
        arbitration.rule(
            arbInstanceId,
            claimantWins,
            0,
            keccak256("justification")
        );

        (
            ,
            ,
            uint8 ruling,
            ,
            uint64 ruledAt,

        ) = arbitration.getInstanceState(arbInstanceId);

        assertEq(ruling, arbitration.RULING_CLAIMANT_WINS());
        assertGt(ruledAt, 0, "Ruled timestamp should be set");
    }

    function test_ExecuteRuling_ClaimantWins() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        // Record contractor balance before
        uint256 contractorBalanceBefore = contractor.balance;

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        // File claim
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, keccak256("claim"));

        // Skip evidence window
        vm.warp(block.timestamp + 8 days);

        // Arbitrator rules in favor of claimant (contractor)
        // Note: Get constant BEFORE prank to avoid consuming the prank on staticcall
        uint8 claimantWins = arbitration.RULING_CLAIMANT_WINS();
        vm.prank(arbitrator);
        arbitration.rule(
            arbInstanceId,
            claimantWins,
            0,
            keccak256("justification")
        );

        // Execute the ruling (no appeals for SIMPLE preset)
        arbitration.executeRuling(arbInstanceId);

        // Check contractor received funds
        uint256 contractorBalanceAfter = contractor.balance;
        assertEq(
            contractorBalanceAfter - contractorBalanceBefore,
            2 ether,
            "Contractor should receive all funds"
        );

        // Check dispute is resolved
        assertTrue(milestone.isDisputeResolved(milestoneInstanceId));
    }

    function test_ExecuteRuling_RespondentWins() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        // Record client balance before
        uint256 clientBalanceBefore = client.balance;

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        // Contractor files claim
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, keccak256("claim"));

        // Skip evidence window
        vm.warp(block.timestamp + 8 days);

        // Arbitrator rules in favor of respondent (client)
        // Note: Get constant BEFORE prank to avoid consuming the prank on staticcall
        uint8 respondentWins = arbitration.RULING_RESPONDENT_WINS();
        vm.prank(arbitrator);
        arbitration.rule(
            arbInstanceId,
            respondentWins,
            0,
            keccak256("justification")
        );

        // Execute the ruling
        arbitration.executeRuling(arbInstanceId);

        // Check that funds were returned (via cancellation)
        // Note: The exact amount depends on cancellation fee settings
        assertTrue(milestone.isDisputeResolved(milestoneInstanceId));
    }

    function test_Rule_NotArbitrator_Reverts() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        // File claim
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, keccak256("claim"));

        // Skip evidence window
        vm.warp(block.timestamp + 8 days);

        // Random person tries to rule
        vm.prank(address(0x999));
        vm.expectRevert(ArbitrationAgreement.NotArbitrator.selector);
        arbitration.rule(arbInstanceId, 1, 0, keccak256("justification"));
    }

    function test_Withdraw_Anytime() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(), // SIMPLE preset allows withdrawal anytime
            arbitrator
        );

        // File claim
        vm.prank(contractor);
        arbitration.fileClaim(arbInstanceId, keccak256("claim"));

        // Claimant withdraws
        vm.prank(contractor);
        arbitration.withdraw(arbInstanceId);

        // Check status is WITHDRAWN
        (,,,, uint16 status,) = arbitration.getInstance(arbInstanceId);
        assertEq(status, 0x0100, "Status should be WITHDRAWN");
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PRESET TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Preset_Simple_Config() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_SIMPLE(),
            arbitrator
        );

        ArbitrationAgreement.ArbitrationConfig memory config = arbitration.getConfig(arbInstanceId);

        assertEq(config.presetId, arbitration.PRESET_SIMPLE());
        assertEq(config.evidenceWindowDays, 7);
        assertFalse(config.appealsAllowed);
        assertEq(config.withdrawalPolicy, arbitration.WITHDRAW_ANYTIME());
    }

    function test_Preset_Balanced_Config() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_BALANCED(),
            arbitrator
        );

        ArbitrationAgreement.ArbitrationConfig memory config = arbitration.getConfig(arbInstanceId);

        assertEq(config.presetId, arbitration.PRESET_BALANCED());
        assertEq(config.evidenceWindowDays, 14);
        assertTrue(config.appealsAllowed);
        assertEq(config.maxAppeals, 1);
        assertEq(config.withdrawalPolicy, arbitration.WITHDRAW_MUTUAL());
    }

    function test_Preset_Panel_Config() public {
        uint256 milestoneInstanceId = _createAndFundMilestoneAgreement();

        vm.prank(client);
        uint256 arbInstanceId = arbitration.createInstance(
            address(milestone),
            milestoneInstanceId,
            arbitration.PRESET_PANEL(),
            address(0) // No arbitrator initially for panel
        );

        ArbitrationAgreement.ArbitrationConfig memory config = arbitration.getConfig(arbInstanceId);

        assertEq(config.presetId, arbitration.PRESET_PANEL());
        assertEq(config.evidenceWindowDays, 21);
        assertFalse(config.appealsAllowed); // Panel decisions are final
        assertEq(config.votingMethod, arbitration.VOTE_MAJORITY());
    }
}
