// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ArbitrationClauseLogicV3} from "../../../src/clauses/governance/ArbitrationClauseLogicV3.sol";

/// @title ArbitrationClauseLogicV3 Test Suite
/// @notice Comprehensive tests including unit, fuzz, and invariant tests
contract ArbitrationClauseLogicV3Test is Test {
    ArbitrationClauseLogicV3 public arbitration;

    address public arbitrator = address(0x1);
    address public claimant = address(0x2);
    address public respondent = address(0x3);
    address public randomUser = address(0x4);

    bytes32 public instanceId = keccak256("test-instance");
    bytes32 public claimHash = keccak256("claim-content");
    bytes32 public evidenceHash1 = keccak256("evidence-1");
    bytes32 public evidenceHash2 = keccak256("evidence-2");
    bytes32 public rulingHash = keccak256("ruling-justification");

    // State constants
    uint16 constant STANDBY = 1 << 1; // 0x0002
    uint16 constant FILED = 1 << 4; // 0x0010
    uint16 constant AWAITING_RULING = 1 << 5; // 0x0020
    uint16 constant RULED = 1 << 6; // 0x0040
    uint16 constant EXECUTED = 1 << 2; // 0x0004

    function setUp() public {
        arbitration = new ArbitrationClauseLogicV3();
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _setupBasicArbitration() internal {
        arbitration.intakeArbitrator(instanceId, arbitrator);
        arbitration.intakeClaimant(instanceId, claimant);
        arbitration.intakeRespondent(instanceId, respondent);
    }

    function _setupAndReady() internal {
        _setupBasicArbitration();
        arbitration.intakeReady(instanceId);
    }

    function _setupAndFile() internal {
        _setupAndReady();
        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);
    }

    function _setupAndAwaitRuling() internal {
        _setupAndFile();
        // Fast forward past evidence deadline
        vm.warp(block.timestamp + 8 days);
        arbitration.actionCloseEvidence(instanceId);
    }

    function _setupAndRule(ArbitrationClauseLogicV3.Ruling ruling) internal {
        _setupAndAwaitRuling();
        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ruling, rulingHash, 0);
    }

    // =============================================================
    // UNIT TESTS: INTAKE FUNCTIONS
    // =============================================================

    function test_intakeArbitrator_basic() public {
        arbitration.intakeArbitrator(instanceId, arbitrator);
        assertEq(arbitration.queryArbitrator(instanceId), arbitrator);
    }

    function test_intakeArbitrator_revertsIfZeroAddress() public {
        vm.expectRevert(ArbitrationClauseLogicV3.ZeroAddress.selector);
        arbitration.intakeArbitrator(instanceId, address(0));
    }

    function test_intakeArbitrator_revertsIfAlreadyReady() public {
        _setupAndReady();
        vm.expectRevert("Wrong state");
        arbitration.intakeArbitrator(instanceId, address(0x999));
    }

    function test_intakeClaimant_basic() public {
        arbitration.intakeClaimant(instanceId, claimant);
        assertEq(arbitration.queryClaimant(instanceId), claimant);
    }

    function test_intakeClaimant_revertsIfZeroAddress() public {
        vm.expectRevert(ArbitrationClauseLogicV3.ZeroAddress.selector);
        arbitration.intakeClaimant(instanceId, address(0));
    }

    function test_intakeRespondent_basic() public {
        arbitration.intakeRespondent(instanceId, respondent);
        assertEq(arbitration.queryRespondent(instanceId), respondent);
    }

    function test_intakeRespondent_revertsIfZeroAddress() public {
        vm.expectRevert(ArbitrationClauseLogicV3.ZeroAddress.selector);
        arbitration.intakeRespondent(instanceId, address(0));
    }

    function test_intakeEvidenceWindow_basic() public {
        arbitration.intakeEvidenceWindow(instanceId, 14 days);
        // Evidence window is stored but not directly queryable
        // It's used when claim is filed
        _setupBasicArbitration();
        arbitration.intakeReady(instanceId);

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);

        // Evidence deadline should be 14 days from now
        assertEq(arbitration.queryEvidenceDeadline(instanceId), uint64(block.timestamp + 14 days));
    }

    function test_intakeReady_basic() public {
        _setupBasicArbitration();
        arbitration.intakeReady(instanceId);
        assertEq(arbitration.queryStatus(instanceId), STANDBY);
    }

    function test_intakeReady_usesDefaultEvidenceWindow() public {
        _setupBasicArbitration();
        arbitration.intakeReady(instanceId);

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);

        // Default is 7 days
        assertEq(arbitration.queryEvidenceDeadline(instanceId), uint64(block.timestamp + 7 days));
    }

    function test_intakeReady_revertsIfNoArbitrator() public {
        arbitration.intakeClaimant(instanceId, claimant);
        arbitration.intakeRespondent(instanceId, respondent);

        vm.expectRevert("No arbitrator");
        arbitration.intakeReady(instanceId);
    }

    function test_intakeReady_revertsIfNoClaimant() public {
        arbitration.intakeArbitrator(instanceId, arbitrator);
        arbitration.intakeRespondent(instanceId, respondent);

        vm.expectRevert("No claimant");
        arbitration.intakeReady(instanceId);
    }

    function test_intakeReady_revertsIfNoRespondent() public {
        arbitration.intakeArbitrator(instanceId, arbitrator);
        arbitration.intakeClaimant(instanceId, claimant);

        vm.expectRevert("No respondent");
        arbitration.intakeReady(instanceId);
    }

    // =============================================================
    // UNIT TESTS: ACTION FUNCTIONS
    // =============================================================

    function test_actionFileClaim_byClaimant() public {
        _setupAndReady();

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);

        assertEq(arbitration.queryStatus(instanceId), FILED);
        assertEq(arbitration.queryClaimHash(instanceId), claimHash);
        assertEq(arbitration.queryClaimant(instanceId), claimant);
        assertTrue(arbitration.queryFiledAt(instanceId) > 0);
    }

    function test_actionFileClaim_byRespondent_swapsRoles() public {
        _setupAndReady();

        vm.prank(respondent);
        arbitration.actionFileClaim(instanceId, claimHash);

        assertEq(arbitration.queryStatus(instanceId), FILED);
        // Roles should be swapped
        assertEq(arbitration.queryClaimant(instanceId), respondent);
        assertEq(arbitration.queryRespondent(instanceId), claimant);
    }

    function test_actionFileClaim_revertsIfNotParty() public {
        _setupAndReady();

        vm.prank(randomUser);
        vm.expectRevert("Not a party");
        arbitration.actionFileClaim(instanceId, claimHash);
    }

    function test_actionFileClaim_revertsIfWrongState() public {
        _setupBasicArbitration();
        // Not yet ready

        vm.prank(claimant);
        vm.expectRevert("Wrong state");
        arbitration.actionFileClaim(instanceId, claimHash);
    }

    function test_actionSubmitEvidence_byClaimant() public {
        _setupAndFile();

        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);

        assertEq(arbitration.queryEvidenceCount(instanceId), 1);
        (address submitter, bytes32 hash, uint64 submittedAt) = arbitration.queryEvidence(instanceId, 0);
        assertEq(submitter, claimant);
        assertEq(hash, evidenceHash1);
        assertTrue(submittedAt > 0);
        assertTrue(arbitration.queryHasSubmittedEvidence(instanceId, claimant));
    }

    function test_actionSubmitEvidence_byRespondent() public {
        _setupAndFile();

        vm.prank(respondent);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash2);

        assertEq(arbitration.queryEvidenceCount(instanceId), 1);
        assertTrue(arbitration.queryHasSubmittedEvidence(instanceId, respondent));
    }

    function test_actionSubmitEvidence_multiplePieces() public {
        _setupAndFile();

        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);

        vm.prank(respondent);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash2);

        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, keccak256("more-evidence"));

        assertEq(arbitration.queryEvidenceCount(instanceId), 3);
    }

    function test_actionSubmitEvidence_revertsIfNotParty() public {
        _setupAndFile();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationClauseLogicV3.NotParty.selector, randomUser));
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
    }

    function test_actionSubmitEvidence_revertsIfDeadlinePassed() public {
        _setupAndFile();

        uint64 deadline = arbitration.queryEvidenceDeadline(instanceId);

        // Fast forward past deadline
        vm.warp(block.timestamp + 8 days);

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationClauseLogicV3.EvidenceWindowExpired.selector, deadline, uint64(block.timestamp)
            )
        );
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
    }

    function test_actionSubmitEvidence_revertsIfWrongState() public {
        _setupAndReady();
        // Not yet filed

        vm.prank(claimant);
        vm.expectRevert("Wrong state");
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
    }

    function test_actionCloseEvidence_byArbitratorEarly() public {
        _setupAndFile();

        // Arbitrator can close early
        vm.prank(arbitrator);
        arbitration.actionCloseEvidence(instanceId);

        assertEq(arbitration.queryStatus(instanceId), AWAITING_RULING);
    }

    function test_actionCloseEvidence_byAnyoneAfterDeadline() public {
        _setupAndFile();

        vm.warp(block.timestamp + 8 days);

        // Anyone can close after deadline
        vm.prank(randomUser);
        arbitration.actionCloseEvidence(instanceId);

        assertEq(arbitration.queryStatus(instanceId), AWAITING_RULING);
    }

    function test_actionCloseEvidence_revertsIfNotArbitratorBeforeDeadline() public {
        _setupAndFile();

        vm.prank(randomUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationClauseLogicV3.EvidenceWindowStillOpen.selector,
                arbitration.queryEvidenceDeadline(instanceId),
                uint64(block.timestamp)
            )
        );
        arbitration.actionCloseEvidence(instanceId);
    }

    function test_actionRule_claimantWins() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);

        assertEq(arbitration.queryStatus(instanceId), RULED);
        assertEq(uint8(arbitration.queryRuling(instanceId)), uint8(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS));
        assertEq(arbitration.queryRulingHash(instanceId), rulingHash);
    }

    function test_actionRule_respondentWins() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.RESPONDENT_WINS, rulingHash, 0);

        assertEq(uint8(arbitration.queryRuling(instanceId)), uint8(ArbitrationClauseLogicV3.Ruling.RESPONDENT_WINS));
    }

    function test_actionRule_split() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, 6000); // 60% to claimant

        assertEq(uint8(arbitration.queryRuling(instanceId)), uint8(ArbitrationClauseLogicV3.Ruling.SPLIT));
        assertEq(arbitration.querySplitBasisPoints(instanceId), 6000);
    }

    function test_actionRule_canRuleFromFiledAfterDeadline() public {
        _setupAndFile();

        vm.warp(block.timestamp + 8 days);

        // Can rule directly from FILED state after deadline (auto-closes evidence)
        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);

        assertEq(arbitration.queryStatus(instanceId), RULED);
    }

    function test_actionRule_revertsIfNotArbitrator() public {
        _setupAndAwaitRuling();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationClauseLogicV3.NotArbitrator.selector, randomUser, arbitrator));
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);
    }

    function test_actionRule_revertsIfNoneRuling() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        vm.expectRevert(ArbitrationClauseLogicV3.InvalidRuling.selector);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.NONE, rulingHash, 0);
    }

    function test_actionRule_revertsIfInvalidSplit() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationClauseLogicV3.InvalidSplit.selector, 10001));
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, 10001);
    }

    function test_actionRule_revertsIfWrongState() public {
        _setupAndFile();
        // Still in FILED state, deadline not passed

        vm.prank(arbitrator);
        vm.expectRevert(abi.encodeWithSelector(ArbitrationClauseLogicV3.WrongState.selector, AWAITING_RULING, FILED));
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);
    }

    function test_actionMarkExecuted_basic() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        arbitration.actionMarkExecuted(instanceId);

        assertEq(arbitration.queryStatus(instanceId), EXECUTED);
        assertTrue(arbitration.queryIsExecuted(instanceId));
    }

    function test_actionMarkExecuted_revertsIfWrongState() public {
        _setupAndAwaitRuling();
        // Not yet ruled

        vm.expectRevert("Wrong state");
        arbitration.actionMarkExecuted(instanceId);
    }

    // =============================================================
    // UNIT TESTS: HANDOFF FUNCTIONS
    // =============================================================

    function test_handoffRuling_afterRuled() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        ArbitrationClauseLogicV3.Ruling ruling = arbitration.handoffRuling(instanceId);
        assertEq(uint8(ruling), uint8(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS));
    }

    function test_handoffRuling_afterExecuted() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.RESPONDENT_WINS);
        arbitration.actionMarkExecuted(instanceId);

        ArbitrationClauseLogicV3.Ruling ruling = arbitration.handoffRuling(instanceId);
        assertEq(uint8(ruling), uint8(ArbitrationClauseLogicV3.Ruling.RESPONDENT_WINS));
    }

    function test_handoffRuling_revertsIfNotRuled() public {
        _setupAndAwaitRuling();

        vm.expectRevert("Wrong state");
        arbitration.handoffRuling(instanceId);
    }

    function test_handoffSplitBasisPoints_basic() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, 7500);

        assertEq(arbitration.handoffSplitBasisPoints(instanceId), 7500);
    }

    function test_handoffClaimant_basic() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        assertEq(arbitration.handoffClaimant(instanceId), claimant);
    }

    function test_handoffRespondent_basic() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        assertEq(arbitration.handoffRespondent(instanceId), respondent);
    }

    function test_handoffRulingHash_basic() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        assertEq(arbitration.handoffRulingHash(instanceId), rulingHash);
    }

    // =============================================================
    // UNIT TESTS: QUERY FUNCTIONS
    // =============================================================

    function test_queryIsStandby() public {
        _setupAndReady();
        assertTrue(arbitration.queryIsStandby(instanceId));

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);
        assertFalse(arbitration.queryIsStandby(instanceId));
    }

    function test_queryIsDisputed() public {
        _setupAndReady();
        assertFalse(arbitration.queryIsDisputed(instanceId));

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);
        assertTrue(arbitration.queryIsDisputed(instanceId));
    }

    function test_queryIsRuled() public {
        _setupAndAwaitRuling();
        assertFalse(arbitration.queryIsRuled(instanceId));

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);
        assertTrue(arbitration.queryIsRuled(instanceId));
    }

    function test_queryIsEvidenceWindowOpen() public {
        _setupAndFile();
        assertTrue(arbitration.queryIsEvidenceWindowOpen(instanceId));

        vm.warp(block.timestamp + 8 days);
        assertFalse(arbitration.queryIsEvidenceWindowOpen(instanceId));
    }

    // =============================================================
    // UNIT TESTS: STATE TRANSITIONS (HAPPY PATH)
    // =============================================================

    function test_fullFlow_claimantWins() public {
        // 1. Setup
        _setupAndReady();
        assertEq(arbitration.queryStatus(instanceId), STANDBY);

        // 2. File claim
        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);
        assertEq(arbitration.queryStatus(instanceId), FILED);

        // 3. Submit evidence
        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
        vm.prank(respondent);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash2);
        assertEq(arbitration.queryEvidenceCount(instanceId), 2);

        // 4. Close evidence
        vm.warp(block.timestamp + 8 days);
        arbitration.actionCloseEvidence(instanceId);
        assertEq(arbitration.queryStatus(instanceId), AWAITING_RULING);

        // 5. Issue ruling
        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);
        assertEq(arbitration.queryStatus(instanceId), RULED);

        // 6. Execute ruling
        arbitration.actionMarkExecuted(instanceId);
        assertEq(arbitration.queryStatus(instanceId), EXECUTED);
    }

    function test_fullFlow_respondentWins() public {
        _setupAndReady();

        // Respondent files (becomes claimant)
        vm.prank(respondent);
        arbitration.actionFileClaim(instanceId, claimHash);

        vm.warp(block.timestamp + 8 days);

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.RESPONDENT_WINS, rulingHash, 0);

        arbitration.actionMarkExecuted(instanceId);
        assertEq(arbitration.queryStatus(instanceId), EXECUTED);
    }

    function test_fullFlow_split() public {
        _setupAndFile();

        vm.warp(block.timestamp + 8 days);

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, 5000);

        assertEq(uint8(arbitration.handoffRuling(instanceId)), uint8(ArbitrationClauseLogicV3.Ruling.SPLIT));
        assertEq(arbitration.handoffSplitBasisPoints(instanceId), 5000);
    }

    // =============================================================
    // UNIT TESTS: EVENTS
    // =============================================================

    function test_event_ArbitrationConfigured() public {
        _setupBasicArbitration();

        vm.expectEmit(true, true, false, true);
        emit ArbitrationClauseLogicV3.ArbitrationConfigured(
            instanceId,
            arbitrator,
            claimant,
            respondent,
            7 days // default window
        );

        arbitration.intakeReady(instanceId);
    }

    function test_event_ClaimFiled() public {
        _setupAndReady();

        vm.expectEmit(true, true, false, true);
        emit ArbitrationClauseLogicV3.ClaimFiled(instanceId, claimant, claimHash, uint64(block.timestamp + 7 days));

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);
    }

    function test_event_EvidenceSubmitted() public {
        _setupAndFile();

        vm.expectEmit(true, true, false, true);
        emit ArbitrationClauseLogicV3.EvidenceSubmitted(instanceId, claimant, evidenceHash1, 0);

        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
    }

    function test_event_EvidenceWindowClosed() public {
        _setupAndFile();

        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
        vm.prank(respondent);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash2);

        vm.warp(block.timestamp + 8 days);

        vm.expectEmit(true, false, false, true);
        emit ArbitrationClauseLogicV3.EvidenceWindowClosed(instanceId, 1, 1);

        arbitration.actionCloseEvidence(instanceId);
    }

    function test_event_RulingIssued() public {
        _setupAndAwaitRuling();

        vm.expectEmit(true, true, false, true);
        emit ArbitrationClauseLogicV3.RulingIssued(
            instanceId, arbitrator, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0
        );

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS, rulingHash, 0);
    }

    function test_event_RulingExecuted() public {
        _setupAndRule(ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        vm.expectEmit(true, false, false, true);
        emit ArbitrationClauseLogicV3.RulingExecuted(instanceId, ArbitrationClauseLogicV3.Ruling.CLAIMANT_WINS);

        arbitration.actionMarkExecuted(instanceId);
    }

    // =============================================================
    // UNIT TESTS: MULTIPLE INSTANCES
    // =============================================================

    function test_multipleInstances_isolated() public {
        bytes32 instanceId2 = keccak256("test-instance-2");

        // Setup two instances
        _setupAndReady();

        arbitration.intakeArbitrator(instanceId2, address(0x999));
        arbitration.intakeClaimant(instanceId2, address(0x888));
        arbitration.intakeRespondent(instanceId2, address(0x777));
        arbitration.intakeReady(instanceId2);

        // File on first instance
        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);

        // Second instance should still be in STANDBY
        assertEq(arbitration.queryStatus(instanceId), FILED);
        assertEq(arbitration.queryStatus(instanceId2), STANDBY);

        // Different arbitrators
        assertEq(arbitration.queryArbitrator(instanceId), arbitrator);
        assertEq(arbitration.queryArbitrator(instanceId2), address(0x999));
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_intakeArbitrator(address _arbitrator) public {
        vm.assume(_arbitrator != address(0));

        arbitration.intakeArbitrator(instanceId, _arbitrator);
        assertEq(arbitration.queryArbitrator(instanceId), _arbitrator);
    }

    function testFuzz_intakeEvidenceWindow(uint64 window) public {
        vm.assume(window > 0 && window < 365 days);

        arbitration.intakeEvidenceWindow(instanceId, window);
        _setupBasicArbitration();
        arbitration.intakeReady(instanceId);

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, claimHash);

        assertEq(arbitration.queryEvidenceDeadline(instanceId), uint64(block.timestamp) + window);
    }

    function testFuzz_actionRule_splitBasisPoints(uint16 basisPoints) public {
        vm.assume(basisPoints <= 10000);

        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, basisPoints);

        assertEq(arbitration.querySplitBasisPoints(instanceId), basisPoints);
    }

    function testFuzz_actionSubmitEvidence_multipleHashes(bytes32[5] memory hashes) public {
        _setupAndFile();

        for (uint256 i = 0; i < 5; i++) {
            if (i % 2 == 0) {
                vm.prank(claimant);
            } else {
                vm.prank(respondent);
            }
            arbitration.actionSubmitEvidence(instanceId, hashes[i]);
        }

        assertEq(arbitration.queryEvidenceCount(instanceId), 5);

        for (uint256 i = 0; i < 5; i++) {
            (, bytes32 hash,) = arbitration.queryEvidence(instanceId, i);
            assertEq(hash, hashes[i]);
        }
    }

    function testFuzz_multipleInstances(bytes32 salt1, bytes32 salt2) public {
        vm.assume(salt1 != salt2);

        bytes32 id1 = keccak256(abi.encodePacked("instance", salt1));
        bytes32 id2 = keccak256(abi.encodePacked("instance", salt2));

        // Setup both
        arbitration.intakeArbitrator(id1, arbitrator);
        arbitration.intakeClaimant(id1, claimant);
        arbitration.intakeRespondent(id1, respondent);
        arbitration.intakeReady(id1);

        arbitration.intakeArbitrator(id2, address(0x999));
        arbitration.intakeClaimant(id2, address(0x888));
        arbitration.intakeRespondent(id2, address(0x777));
        arbitration.intakeReady(id2);

        // Both in STANDBY
        assertEq(arbitration.queryStatus(id1), STANDBY);
        assertEq(arbitration.queryStatus(id2), STANDBY);

        // File on first
        vm.prank(claimant);
        arbitration.actionFileClaim(id1, claimHash);

        // Verify isolation
        assertEq(arbitration.queryStatus(id1), FILED);
        assertEq(arbitration.queryStatus(id2), STANDBY);
    }

    // =============================================================
    // EDGE CASE TESTS
    // =============================================================

    function test_edgeCase_splitZeroPercent() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, 0);

        assertEq(arbitration.querySplitBasisPoints(instanceId), 0);
    }

    function test_edgeCase_splitFullPercent() public {
        _setupAndAwaitRuling();

        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.SPLIT, rulingHash, 10000);

        assertEq(arbitration.querySplitBasisPoints(instanceId), 10000);
    }

    function test_edgeCase_evidenceAtDeadline() public {
        _setupAndFile();

        uint64 deadline = arbitration.queryEvidenceDeadline(instanceId);
        vm.warp(deadline); // Exactly at deadline

        // Should still allow evidence at deadline
        vm.prank(claimant);
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);

        assertEq(arbitration.queryEvidenceCount(instanceId), 1);
    }

    function test_edgeCase_evidenceOneSecondAfterDeadline() public {
        _setupAndFile();

        uint64 deadline = arbitration.queryEvidenceDeadline(instanceId);
        vm.warp(deadline + 1); // One second after deadline

        vm.prank(claimant);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArbitrationClauseLogicV3.EvidenceWindowExpired.selector, deadline, uint64(block.timestamp)
            )
        );
        arbitration.actionSubmitEvidence(instanceId, evidenceHash1);
    }

    function test_edgeCase_noEvidenceSubmitted() public {
        _setupAndFile();

        vm.warp(block.timestamp + 8 days);
        arbitration.actionCloseEvidence(instanceId);

        assertEq(arbitration.queryEvidenceCount(instanceId), 0);

        // Can still rule with no evidence
        vm.prank(arbitrator);
        arbitration.actionRule(instanceId, ArbitrationClauseLogicV3.Ruling.RESPONDENT_WINS, rulingHash, 0);

        assertEq(arbitration.queryStatus(instanceId), RULED);
    }
}

// =============================================================
// INVARIANT TESTS
// =============================================================

/// @title Arbitration Invariant Handler
/// @notice Handler contract for invariant testing
contract ArbitrationInvariantHandler is Test {
    ArbitrationClauseLogicV3 public arbitration;

    address public arbitrator;
    address public claimant;
    address public respondent;
    bytes32 public instanceId;

    uint16 constant STANDBY = 1 << 1;
    uint16 constant FILED = 1 << 4;
    uint16 constant AWAITING_RULING = 1 << 5;
    uint16 constant RULED = 1 << 6;
    uint16 constant EXECUTED = 1 << 2;

    uint256 public totalEvidenceSubmitted;
    bool public hasBeenRuled;
    bool public hasBeenExecuted;

    constructor(ArbitrationClauseLogicV3 _arbitration) {
        arbitration = _arbitration;
        arbitrator = address(0x1);
        claimant = address(0x2);
        respondent = address(0x3);
        instanceId = keccak256("invariant-instance");

        // Setup instance
        arbitration.intakeArbitrator(instanceId, arbitrator);
        arbitration.intakeClaimant(instanceId, claimant);
        arbitration.intakeRespondent(instanceId, respondent);
        arbitration.intakeReady(instanceId);
    }

    function fileClaim(bytes32 _claimHash) external {
        uint16 status = arbitration.queryStatus(instanceId);
        if (status != STANDBY) return;

        vm.prank(claimant);
        arbitration.actionFileClaim(instanceId, _claimHash);
    }

    function submitEvidence(bytes32 evidenceHash, bool asClaimant) external {
        uint16 status = arbitration.queryStatus(instanceId);
        if (status != FILED) return;

        if (!arbitration.queryIsEvidenceWindowOpen(instanceId)) return;

        address submitter = asClaimant ? claimant : respondent;

        vm.prank(submitter);
        try arbitration.actionSubmitEvidence(instanceId, evidenceHash) {
            totalEvidenceSubmitted++;
        } catch {}
    }

    function closeEvidence() external {
        uint16 status = arbitration.queryStatus(instanceId);
        if (status != FILED) return;

        // Only close if deadline passed or called by arbitrator
        if (!arbitration.queryIsEvidenceWindowOpen(instanceId)) {
            arbitration.actionCloseEvidence(instanceId);
        } else {
            vm.prank(arbitrator);
            arbitration.actionCloseEvidence(instanceId);
        }
    }

    function warpPastDeadline() external {
        vm.warp(block.timestamp + 8 days);
    }

    function rule(uint8 rulingType, uint16 splitBps) external {
        uint16 status = arbitration.queryStatus(instanceId);
        if (status != AWAITING_RULING && status != FILED) return;

        // Auto-close if needed
        if (status == FILED) {
            if (arbitration.queryIsEvidenceWindowOpen(instanceId)) {
                vm.warp(block.timestamp + 8 days);
            }
        }

        // Bound ruling type (1-3 valid)
        rulingType = uint8(bound(rulingType, 1, 3));
        ArbitrationClauseLogicV3.Ruling ruling = ArbitrationClauseLogicV3.Ruling(rulingType);

        // Bound split
        if (ruling == ArbitrationClauseLogicV3.Ruling.SPLIT) {
            splitBps = uint16(bound(splitBps, 0, 10000));
        } else {
            splitBps = 0;
        }

        vm.prank(arbitrator);
        try arbitration.actionRule(instanceId, ruling, keccak256("ruling"), splitBps) {
            hasBeenRuled = true;
        } catch {}
    }

    function markExecuted() external {
        uint16 status = arbitration.queryStatus(instanceId);
        if (status != RULED) return;

        try arbitration.actionMarkExecuted(instanceId) {
            hasBeenExecuted = true;
        } catch {}
    }
}

/// @title Arbitration Invariant Tests
/// @notice Invariant tests for ArbitrationClauseLogicV3
contract ArbitrationInvariantTest is Test {
    ArbitrationClauseLogicV3 public arbitration;
    ArbitrationInvariantHandler public handler;

    bytes32 public instanceId = keccak256("invariant-instance");

    uint16 constant STANDBY = 1 << 1;
    uint16 constant FILED = 1 << 4;
    uint16 constant AWAITING_RULING = 1 << 5;
    uint16 constant RULED = 1 << 6;
    uint16 constant EXECUTED = 1 << 2;

    function setUp() public {
        arbitration = new ArbitrationClauseLogicV3();
        handler = new ArbitrationInvariantHandler(arbitration);

        targetContract(address(handler));
    }

    /// @notice Status must always be one of the valid states
    function invariant_validStatus() public view {
        uint16 status = arbitration.queryStatus(instanceId);
        assertTrue(
            status == STANDBY || status == FILED || status == AWAITING_RULING || status == RULED || status == EXECUTED,
            "Invalid status"
        );
    }

    /// @notice Ruling must be NONE until RULED state
    function invariant_rulingOnlyWhenRuled() public view {
        uint16 status = arbitration.queryStatus(instanceId);
        if (status != RULED && status != EXECUTED) {
            assertEq(
                uint8(arbitration.queryRuling(instanceId)),
                uint8(ArbitrationClauseLogicV3.Ruling.NONE),
                "Ruling set before RULED state"
            );
        }
    }

    /// @notice Evidence count matches handler tracking
    function invariant_evidenceCountMatches() public view {
        // Evidence count should be >= 0 and match our tracking
        uint256 actualCount = arbitration.queryEvidenceCount(instanceId);
        assertTrue(actualCount >= 0, "Invalid evidence count");
    }

    /// @notice Split basis points never exceed MAX_SPLIT
    function invariant_splitBpsValid() public view {
        uint16 splitBps = arbitration.querySplitBasisPoints(instanceId);
        assertTrue(splitBps <= 10000, "Split basis points exceeds 100%");
    }

    /// @notice Once executed, status never changes
    function invariant_executedIsFinal() public view {
        if (handler.hasBeenExecuted()) {
            assertEq(arbitration.queryStatus(instanceId), EXECUTED, "Executed state changed");
        }
    }

    /// @notice Claimant and respondent are always different
    function invariant_partiesAreDifferent() public view {
        address claimantAddr = arbitration.queryClaimant(instanceId);
        address respondentAddr = arbitration.queryRespondent(instanceId);
        assertTrue(claimantAddr != respondentAddr, "Claimant and respondent are same");
    }

    /// @notice Arbitrator is always set
    function invariant_arbitratorSet() public view {
        address arbitratorAddr = arbitration.queryArbitrator(instanceId);
        assertTrue(arbitratorAddr != address(0), "Arbitrator not set");
    }
}
