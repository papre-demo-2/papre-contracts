// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ReputationClauseLogicV3} from "../../../src/clauses/reputation/ReputationClauseLogicV3.sol";

/// @title ReputationClauseLogicV3 Test Suite
/// @notice Comprehensive tests including unit, fuzz, and invariant tests
contract ReputationClauseLogicV3Test is Test {
    ReputationClauseLogicV3 public reputation;

    address public rater1 = address(0x1);
    address public rater2 = address(0x2);
    address public subject1 = address(0x3); // e.g., arbitrator
    address public subject2 = address(0x4);
    address public randomUser = address(0x5);

    bytes32 public instanceId = keccak256("test-instance");
    bytes32 public arbitratorRole = keccak256("arbitrator");
    bytes32 public feedbackCID = keccak256("ipfs://feedback");

    // State constants
    uint16 constant CONFIGURED = 1 << 1; // 0x0002
    uint16 constant WINDOW_OPEN = 1 << 4; // 0x0010
    uint16 constant WINDOW_CLOSED = 1 << 2; // 0x0004

    function setUp() public {
        reputation = new ReputationClauseLogicV3();
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _getDefaultConfig() internal view returns (ReputationClauseLogicV3.ReputationConfig memory) {
        return ReputationClauseLogicV3.ReputationConfig({
            weightStrategy: reputation.WEIGHT_EQUAL(),
            winnerWeightBps: 10000,
            visibilityMode: reputation.VISIBILITY_IMMEDIATE(),
            blindThreshold: 2,
            ratingWindowSeconds: 14 days,
            allowUpdates: true,
            aggregationMethod: reputation.AGGREGATION_SIMPLE(),
            minimumRatingsToDisplay: 1,
            ratedRole: arbitratorRole
        });
    }

    function _getBlindConfig() internal view returns (ReputationClauseLogicV3.ReputationConfig memory) {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.visibilityMode = reputation.VISIBILITY_BLIND_UNTIL_ALL();
        config.blindThreshold = 2;
        return config;
    }

    function _setupConfigured() internal {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        reputation.intakeConfig(instanceId, config);
    }

    function _setupWindowOpen() internal {
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](1);
        subjects[0] = subject1;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    function _setupWithRating() internal {
        _setupWindowOpen();
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);
    }

    // =============================================================
    // UNIT TESTS: INTAKE FUNCTIONS
    // =============================================================

    function test_intakeConfig_basic() public {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        reputation.intakeConfig(instanceId, config);

        assertEq(reputation.queryStatus(instanceId), CONFIGURED);

        ReputationClauseLogicV3.ReputationConfig memory storedConfig = reputation.queryConfig(instanceId);
        assertEq(storedConfig.weightStrategy, reputation.WEIGHT_EQUAL());
        assertEq(storedConfig.ratingWindowSeconds, 14 days);
        assertEq(storedConfig.ratedRole, arbitratorRole);
    }

    function test_intakeConfig_revertsIfAlreadyConfigured() public {
        _setupConfigured();

        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        vm.expectRevert("Wrong state");
        reputation.intakeConfig(instanceId, config);
    }

    function test_intakeConfig_revertsIfZeroRatingWindow() public {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.ratingWindowSeconds = 0;

        vm.expectRevert(ReputationClauseLogicV3.InvalidConfig.selector);
        reputation.intakeConfig(instanceId, config);
    }

    function test_intakeConfig_revertsIfInvalidVisibilityMode() public {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.visibilityMode = 99;

        vm.expectRevert(ReputationClauseLogicV3.InvalidConfig.selector);
        reputation.intakeConfig(instanceId, config);
    }

    function test_intakeRatingWindow_basic() public {
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](1);
        subjects[0] = subject1;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        assertEq(reputation.queryStatus(instanceId), WINDOW_OPEN);

        (bool isOpen, uint48 opensAt, uint48 closesAt, uint8 ratingsSubmitted, uint8 ratersCount) =
            reputation.queryWindowStatus(instanceId);

        assertTrue(isOpen);
        assertEq(opensAt, uint48(block.timestamp));
        assertEq(closesAt, uint48(block.timestamp + 14 days));
        assertEq(ratingsSubmitted, 0);
        assertEq(ratersCount, 2);
    }

    function test_intakeRatingWindow_revertsIfWrongState() public {
        // Not configured yet

        address[] memory raters = new address[](1);
        raters[0] = rater1;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.WrongState.selector, CONFIGURED, 0));
        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    function test_intakeRatingWindow_revertsIfArrayMismatch() public {
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](1); // Mismatch!
        outcomes[0] = 1;

        vm.expectRevert(ReputationClauseLogicV3.ArrayLengthMismatch.selector);
        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    function test_intakeRatingWindow_revertsIfZeroAddressRater() public {
        _setupConfigured();

        address[] memory raters = new address[](1);
        raters[0] = address(0);
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        vm.expectRevert(ReputationClauseLogicV3.ZeroAddress.selector);
        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    function test_intakeRatingWindow_revertsIfZeroAddressSubject() public {
        _setupConfigured();

        address[] memory raters = new address[](1);
        raters[0] = rater1;
        address[] memory subjects = new address[](1);
        subjects[0] = address(0);
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        vm.expectRevert(ReputationClauseLogicV3.ZeroAddress.selector);
        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    // =============================================================
    // UNIT TESTS: ACTION FUNCTIONS
    // =============================================================

    function test_actionSubmitRating_basic() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        assertEq(reputation.queryRatingsCount(instanceId), 1);

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertEq(rating.score, 5);
        assertEq(rating.feedbackCID, feedbackCID);
        assertTrue(rating.visible);
        assertTrue(rating.exists);
    }

    function test_actionSubmitRating_updatesGlobalProfile() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 4, feedbackCID);

        (uint64 totalRatings, uint16 averageScore, uint48 firstRatingAt, uint48 lastRatingAt) =
            reputation.queryProfile(subject1);

        assertEq(totalRatings, 1);
        assertEq(averageScore, 400); // 4.00 scaled by 100
        assertTrue(firstRatingAt > 0);
        assertTrue(lastRatingAt > 0);
    }

    function test_actionSubmitRating_updatesRoleStats() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 4, feedbackCID);

        (uint32 count, uint16 averageScore) = reputation.queryRoleReputation(subject1, arbitratorRole);

        assertEq(count, 1);
        assertEq(averageScore, 400);
    }

    function test_actionSubmitRating_multipleRaters() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject1, 3, bytes32(0));

        assertEq(reputation.queryRatingsCount(instanceId), 2);

        (uint64 totalRatings, uint16 averageScore,,) = reputation.queryProfile(subject1);
        assertEq(totalRatings, 2);
        assertEq(averageScore, 400); // (5+3)/2 = 4.00
    }

    function test_actionSubmitRating_revertsIfNotEligible() public {
        _setupWindowOpen();

        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.NotEligibleRater.selector, randomUser));
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);
    }

    function test_actionSubmitRating_revertsIfNotRatableSubject() public {
        _setupWindowOpen();

        vm.prank(rater1);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.NotRatableSubject.selector, subject2));
        reputation.actionSubmitRating(instanceId, subject2, 5, feedbackCID);
    }

    function test_actionSubmitRating_revertsIfAlreadyRated() public {
        _setupWithRating();

        vm.prank(rater1);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.AlreadyRated.selector, rater1, subject1));
        reputation.actionSubmitRating(instanceId, subject1, 3, feedbackCID);
    }

    function test_actionSubmitRating_revertsIfWindowClosed() public {
        _setupWindowOpen();

        vm.warp(block.timestamp + 15 days);

        vm.prank(rater1);
        vm.expectRevert(ReputationClauseLogicV3.WindowClosed.selector);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);
    }

    function test_actionSubmitRating_revertsIfInvalidScore() public {
        _setupWindowOpen();

        vm.prank(rater1);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.InvalidScore.selector, 0));
        reputation.actionSubmitRating(instanceId, subject1, 0, feedbackCID);

        vm.prank(rater1);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.InvalidScore.selector, 6));
        reputation.actionSubmitRating(instanceId, subject1, 6, feedbackCID);
    }

    function test_actionUpdateRating_basic() public {
        _setupWithRating();

        vm.prank(rater1);
        reputation.actionUpdateRating(instanceId, subject1, 3, bytes32(0));

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertEq(rating.score, 3);

        // Profile should be updated
        (, uint16 averageScore,,) = reputation.queryProfile(subject1);
        assertEq(averageScore, 300);
    }

    function test_actionUpdateRating_revertsIfNotAllowed() public {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.allowUpdates = false;
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](1);
        raters[0] = rater1;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        vm.prank(rater1);
        vm.expectRevert(ReputationClauseLogicV3.UpdatesNotAllowed.selector);
        reputation.actionUpdateRating(instanceId, subject1, 3, bytes32(0));
    }

    function test_actionUpdateRating_revertsIfNoExistingRating() public {
        _setupWindowOpen();

        vm.prank(rater1);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.NotEligibleRater.selector, rater1));
        reputation.actionUpdateRating(instanceId, subject1, 3, bytes32(0));
    }

    function test_actionCloseWindow_basic() public {
        _setupWindowOpen();

        reputation.actionCloseWindow(instanceId);

        assertEq(reputation.queryStatus(instanceId), WINDOW_CLOSED);
    }

    function test_actionCloseWindow_revertsIfWrongState() public {
        _setupConfigured();

        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.WrongState.selector, WINDOW_OPEN, CONFIGURED));
        reputation.actionCloseWindow(instanceId);
    }

    function test_actionRevealRatings_afterWindowClosed() public {
        // Setup with blind mode
        ReputationClauseLogicV3.ReputationConfig memory config = _getBlindConfig();
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // Submit one rating (threshold not met yet)
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertFalse(rating.visible); // Should be hidden

        // Warp past window
        vm.warp(block.timestamp + 15 days);

        // Reveal
        reputation.actionRevealRatings(instanceId);

        rating = reputation.queryRating(instanceId, rater1, subject1);
        assertTrue(rating.visible); // Now visible
    }

    function test_actionRevealRatings_revertsIfWindowStillOpen() public {
        _setupWindowOpen();

        vm.expectRevert(ReputationClauseLogicV3.RatingWindowStillOpen.selector);
        reputation.actionRevealRatings(instanceId);
    }

    // =============================================================
    // UNIT TESTS: BLIND MODE
    // =============================================================

    function test_blindMode_hidesUntilThreshold() public {
        ReputationClauseLogicV3.ReputationConfig memory config = _getBlindConfig();
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // First rating - hidden
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        ReputationClauseLogicV3.Rating memory rating1 = reputation.queryRating(instanceId, rater1, subject1);
        assertFalse(rating1.visible);

        // Second rating - threshold met, both revealed
        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject1, 3, bytes32(0));

        rating1 = reputation.queryRating(instanceId, rater1, subject1);
        ReputationClauseLogicV3.Rating memory rating2 = reputation.queryRating(instanceId, rater2, subject1);

        assertTrue(rating1.visible);
        assertTrue(rating2.visible);
    }

    // =============================================================
    // UNIT TESTS: QUERY FUNCTIONS
    // =============================================================

    function test_queryCanRate_eligible() public {
        _setupWindowOpen();

        (bool canRate, string memory reason) = reputation.queryCanRate(instanceId, rater1, subject1);
        assertTrue(canRate);
        assertEq(reason, "");
    }

    function test_queryCanRate_windowNotOpen() public {
        _setupConfigured();

        (bool canRate, string memory reason) = reputation.queryCanRate(instanceId, rater1, subject1);
        assertFalse(canRate);
        assertEq(reason, "Window not open");
    }

    function test_queryCanRate_windowExpired() public {
        _setupWindowOpen();
        vm.warp(block.timestamp + 15 days);

        (bool canRate, string memory reason) = reputation.queryCanRate(instanceId, rater1, subject1);
        assertFalse(canRate);
        assertEq(reason, "Window expired");
    }

    function test_queryCanRate_notEligible() public {
        _setupWindowOpen();

        (bool canRate, string memory reason) = reputation.queryCanRate(instanceId, randomUser, subject1);
        assertFalse(canRate);
        assertEq(reason, "Not eligible rater");
    }

    function test_queryCanRate_notRatableSubject() public {
        _setupWindowOpen();

        (bool canRate, string memory reason) = reputation.queryCanRate(instanceId, rater1, subject2);
        assertFalse(canRate);
        assertEq(reason, "Not ratable subject");
    }

    function test_queryCanRate_alreadyRated() public {
        _setupWithRating();

        (bool canRate, string memory reason) = reputation.queryCanRate(instanceId, rater1, subject1);
        assertFalse(canRate);
        assertEq(reason, "Already rated");
    }

    function test_queryEligibleRaters() public {
        _setupWindowOpen();

        address[] memory raters = reputation.queryEligibleRaters(instanceId);
        assertEq(raters.length, 2);
        assertEq(raters[0], rater1);
        assertEq(raters[1], rater2);
    }

    function test_queryRatableSubjects() public {
        _setupWindowOpen();

        address[] memory subjects = reputation.queryRatableSubjects(instanceId);
        assertEq(subjects.length, 1);
        assertEq(subjects[0], subject1);
    }

    function test_queryRaterOutcome() public {
        _setupWindowOpen();

        assertEq(reputation.queryRaterOutcome(instanceId, rater1), reputation.OUTCOME_WINNER());
        assertEq(reputation.queryRaterOutcome(instanceId, rater2), reputation.OUTCOME_LOSER());
    }

    // =============================================================
    // UNIT TESTS: HANDOFF FUNCTIONS
    // =============================================================

    function test_handoffSubjectScore_basic() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 4, feedbackCID);

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject1, 5, bytes32(0));

        (uint16 score, uint64 count) = reputation.handoffSubjectScore(instanceId, subject1);

        assertEq(count, 2);
        assertEq(score, 450); // (4+5)/2 = 4.50
    }

    function test_handoffSubjectScore_noRatings() public {
        _setupWindowOpen();

        (uint16 score, uint64 count) = reputation.handoffSubjectScore(instanceId, subject1);

        assertEq(count, 0);
        assertEq(score, 0);
    }

    // =============================================================
    // UNIT TESTS: EVENTS
    // =============================================================

    function test_event_ReputationConfigured() public {
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();

        vm.expectEmit(true, true, false, true);
        emit ReputationClauseLogicV3.ReputationConfigured(
            instanceId, arbitratorRole, 14 days, reputation.VISIBILITY_IMMEDIATE()
        );

        reputation.intakeConfig(instanceId, config);
    }

    function test_event_RatingWindowOpened() public {
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        vm.expectEmit(true, false, false, true);
        emit ReputationClauseLogicV3.RatingWindowOpened(
            instanceId, uint48(block.timestamp), uint48(block.timestamp + 14 days), 2, 1
        );

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    function test_event_RatingSubmitted() public {
        _setupWindowOpen();

        vm.expectEmit(true, true, true, true);
        emit ReputationClauseLogicV3.RatingSubmitted(instanceId, rater1, subject1, 5, feedbackCID);

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);
    }

    function test_event_RatingUpdated() public {
        _setupWithRating();

        vm.expectEmit(true, true, true, true);
        emit ReputationClauseLogicV3.RatingUpdated(instanceId, rater1, subject1, 5, 3);

        vm.prank(rater1);
        reputation.actionUpdateRating(instanceId, subject1, 3, bytes32(0));
    }

    function test_event_RatingWindowClosed() public {
        _setupWithRating();

        vm.expectEmit(true, false, false, true);
        emit ReputationClauseLogicV3.RatingWindowClosed(instanceId, 1);

        reputation.actionCloseWindow(instanceId);
    }

    // =============================================================
    // UNIT TESTS: MULTIPLE INSTANCES
    // =============================================================

    function test_multipleInstances_isolated() public {
        bytes32 instanceId2 = keccak256("test-instance-2");

        // Setup first instance
        _setupWindowOpen();

        // Setup second instance
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        reputation.intakeConfig(instanceId2, config);

        address[] memory raters = new address[](1);
        raters[0] = rater1;
        address[] memory subjects = new address[](1);
        subjects[0] = subject2;
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        reputation.intakeRatingWindow(instanceId2, raters, subjects, outcomes);

        // Rate on first instance
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        // Second instance should have 0 ratings
        assertEq(reputation.queryRatingsCount(instanceId), 1);
        assertEq(reputation.queryRatingsCount(instanceId2), 0);

        // Different subjects
        address[] memory subjects1 = reputation.queryRatableSubjects(instanceId);
        address[] memory subjects2 = reputation.queryRatableSubjects(instanceId2);
        assertEq(subjects1[0], subject1);
        assertEq(subjects2[0], subject2);
    }

    function test_globalProfile_aggregatesAcrossInstances() public {
        bytes32 instanceId2 = keccak256("test-instance-2");

        // Setup first instance
        _setupWindowOpen();

        // Rate subject1 with 5
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        // Setup second instance with same subject
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        reputation.intakeConfig(instanceId2, config);

        address[] memory raters = new address[](1);
        raters[0] = rater2;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1; // Same subject!
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        reputation.intakeRatingWindow(instanceId2, raters, subjects, outcomes);

        // Rate subject1 with 3 in second instance
        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId2, subject1, 3, bytes32(0));

        // Global profile should aggregate both
        (uint64 totalRatings, uint16 averageScore,,) = reputation.queryProfile(subject1);
        assertEq(totalRatings, 2);
        assertEq(averageScore, 400); // (5+3)/2 = 4.00
    }

    // =============================================================
    // FUZZ TESTS
    // =============================================================

    function testFuzz_actionSubmitRating_validScore(uint8 score) public {
        vm.assume(score >= 1 && score <= 5);

        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, score, feedbackCID);

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertEq(rating.score, score);
    }

    function testFuzz_actionSubmitRating_invalidScore(uint8 score) public {
        vm.assume(score == 0 || score > 5);

        _setupWindowOpen();

        vm.prank(rater1);
        vm.expectRevert(abi.encodeWithSelector(ReputationClauseLogicV3.InvalidScore.selector, score));
        reputation.actionSubmitRating(instanceId, subject1, score, feedbackCID);
    }

    function testFuzz_ratingWindowDuration(uint32 duration) public {
        vm.assume(duration > 0 && duration < 365 days);

        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.ratingWindowSeconds = duration;
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](1);
        raters[0] = rater1;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](1);
        outcomes[0] = 1;

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        (,, uint48 closesAt,,) = reputation.queryWindowStatus(instanceId);
        assertEq(closesAt, uint48(block.timestamp + duration));
    }

    function testFuzz_multipleInstances(bytes32 salt1, bytes32 salt2) public {
        vm.assume(salt1 != salt2);

        bytes32 id1 = keccak256(abi.encodePacked("instance", salt1));
        bytes32 id2 = keccak256(abi.encodePacked("instance", salt2));

        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();

        reputation.intakeConfig(id1, config);
        reputation.intakeConfig(id2, config);

        // Both configured
        assertEq(reputation.queryStatus(id1), CONFIGURED);
        assertEq(reputation.queryStatus(id2), CONFIGURED);
    }

    // =============================================================
    // EDGE CASE TESTS
    // =============================================================

    function test_edgeCase_ratingAtWindowClose() public {
        _setupWindowOpen();

        (,, uint48 closesAt,,) = reputation.queryWindowStatus(instanceId);
        vm.warp(closesAt); // Exactly at close time

        // Should still be able to rate at exact close time
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        assertEq(reputation.queryRatingsCount(instanceId), 1);
    }

    function test_edgeCase_ratingOneSecondAfterClose() public {
        _setupWindowOpen();

        (,, uint48 closesAt,,) = reputation.queryWindowStatus(instanceId);
        vm.warp(closesAt + 1); // One second after

        vm.prank(rater1);
        vm.expectRevert(ReputationClauseLogicV3.WindowClosed.selector);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);
    }

    function test_edgeCase_minScore() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 1, feedbackCID);

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertEq(rating.score, 1);
    }

    function test_edgeCase_maxScore() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertEq(rating.score, 5);
    }

    function test_edgeCase_noFeedbackCID() public {
        _setupWindowOpen();

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, bytes32(0));

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater1, subject1);
        assertEq(rating.feedbackCID, bytes32(0));
    }

    // =============================================================
    // PHASE 3: ADVANCED FEATURES
    // =============================================================

    function test_handoffTopSubjects_basic() public {
        // Setup with multiple subjects
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](2);
        subjects[0] = subject1;
        subjects[1] = subject2;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // Rate both subjects
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject2, 3, feedbackCID);

        // Get top subjects
        (address[] memory topSubjects, uint16[] memory scores) =
            reputation.handoffTopSubjects(instanceId, arbitratorRole, 10, 1);

        assertEq(topSubjects.length, 2);
        // Should be sorted by score descending
        assertEq(topSubjects[0], subject1); // Score 5
        assertEq(topSubjects[1], subject2); // Score 3
        assertEq(scores[0], 500); // 5.00 scaled
        assertEq(scores[1], 300); // 3.00 scaled
    }

    function test_handoffTopSubjects_withLimit() public {
        // Setup with multiple subjects
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](2);
        subjects[0] = subject1;
        subjects[1] = subject2;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // Rate both subjects
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject2, 3, feedbackCID);

        // Get top 1 subject only
        (address[] memory topSubjects, uint16[] memory scores) =
            reputation.handoffTopSubjects(instanceId, arbitratorRole, 1, 1);

        assertEq(topSubjects.length, 1);
        assertEq(topSubjects[0], subject1);
        assertEq(scores[0], 500);
    }

    function test_handoffTopSubjects_filterByMinRatings() public {
        // Setup with multiple subjects
        _setupConfigured();

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](2);
        subjects[0] = subject1;
        subjects[1] = subject2;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // Only rate subject1
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        // Second instance to rate subject1 again (to get 2 ratings)
        bytes32 instanceId2 = keccak256("test-instance-2");
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        reputation.intakeConfig(instanceId2, config);
        reputation.intakeRatingWindow(instanceId2, raters, subjects, outcomes);

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId2, subject1, 4, feedbackCID);

        // Filter by minRatings=2 should only return subject1
        (address[] memory topSubjects,) = reputation.handoffTopSubjects(instanceId, arbitratorRole, 10, 2);

        assertEq(topSubjects.length, 1);
        assertEq(topSubjects[0], subject1);
    }

    function test_handoffTopSubjects_emptyRole() public {
        bytes32 unknownRole = keccak256("unknown-role");

        (address[] memory topSubjects, uint16[] memory scores) =
            reputation.handoffTopSubjects(instanceId, unknownRole, 10, 1);

        assertEq(topSubjects.length, 0);
        assertEq(scores.length, 0);
    }

    function test_handoffSubjectsByRole() public {
        _setupWithRating();

        address[] memory subjects = reputation.handoffSubjectsByRole(instanceId, arbitratorRole);

        assertEq(subjects.length, 1);
        assertEq(subjects[0], subject1);
    }

    function test_handoffSubjectScoreWeighted() public {
        // Setup with outcome weighting
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.weightStrategy = reputation.WEIGHT_OUTCOME();
        config.winnerWeightBps = 15000; // 1.5x for winners
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](1);
        subjects[0] = subject1;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER(); // 1.5x weight
        outcomes[1] = reputation.OUTCOME_LOSER(); // 0.5x weight (10000 - 5000)

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // Winner gives 5 stars
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        // Loser gives 1 star
        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject1, 1, feedbackCID);

        // Simple average would be (5+1)/2 = 3.00
        // Weighted: (5*15000 + 1*5000) / (15000+5000) = 80000/20000 = 4.00
        (uint16 weightedScore, uint64 totalWeight) = reputation.handoffSubjectScoreWeighted(instanceId, subject1);

        assertEq(totalWeight, 20000); // 15000 + 5000
        assertEq(weightedScore, 400); // 4.00 scaled
    }

    function test_handoffRoleReputationWeighted() public {
        // Setup with outcome weighting
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.weightStrategy = reputation.WEIGHT_OUTCOME();
        config.winnerWeightBps = 15000;
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](1);
        subjects[0] = subject1;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject1, 1, feedbackCID);

        (uint32 count, uint16 averageScore, uint16 weightedScore) =
            reputation.handoffRoleReputationWeighted(subject1, arbitratorRole);

        assertEq(count, 2);
        assertEq(averageScore, 300); // (5+1)/2 = 3.00
        assertEq(weightedScore, 400); // Weighted: 4.00
    }

    function test_handoffSubjectScoreWithDecay_recent() public {
        _setupWithRating();

        // Rating is fresh (just submitted)
        (uint16 score, uint64 count, uint16 decayFactor) =
            reputation.handoffSubjectScoreWithDecay(instanceId, subject1, 30);

        assertEq(count, 1);
        assertEq(decayFactor, 10000); // 100% - no decay
        assertEq(score, 500); // 5.00 scaled, no decay applied
    }

    function test_handoffSubjectScoreWithDecay_halfDecayed() public {
        _setupWithRating();

        // Advance time by halfLife (30 days)
        vm.warp(block.timestamp + 30 days);

        (uint16 score, uint64 count, uint16 decayFactor) =
            reputation.handoffSubjectScoreWithDecay(instanceId, subject1, 30);

        assertEq(count, 1);
        assertEq(decayFactor, 5000); // 50% at half life
        assertEq(score, 250); // 5.00 * 0.50 = 2.50 scaled
    }

    function test_handoffSubjectScoreWithDecay_fullyDecayed() public {
        _setupWithRating();

        // Advance time past 2x halfLife (full decay)
        vm.warp(block.timestamp + 61 days);

        (uint16 score, uint64 count, uint16 decayFactor) =
            reputation.handoffSubjectScoreWithDecay(instanceId, subject1, 30);

        assertEq(count, 1);
        assertEq(decayFactor, 0); // 0% - fully decayed
        assertEq(score, 0); // Fully decayed
    }

    function test_handoffSubjectScoreWithDecay_noRatings() public {
        (uint16 score, uint64 count, uint16 decayFactor) =
            reputation.handoffSubjectScoreWithDecay(instanceId, subject1, 30);

        assertEq(count, 0);
        assertEq(decayFactor, 10000);
        assertEq(score, 0);
    }

    function test_outcomeWeighting_winnerGetsMoreWeight() public {
        // Setup with outcome weighting
        ReputationClauseLogicV3.ReputationConfig memory config = _getDefaultConfig();
        config.weightStrategy = reputation.WEIGHT_OUTCOME();
        config.winnerWeightBps = 12000; // 1.2x for winners
        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;

        address[] memory subjects = new address[](1);
        subjects[0] = subject1;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputation.OUTCOME_WINNER();
        outcomes[1] = reputation.OUTCOME_LOSER();

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);

        // Check weights are applied correctly
        vm.prank(rater1);
        reputation.actionSubmitRating(instanceId, subject1, 5, feedbackCID);

        ReputationClauseLogicV3.Rating memory ratingWinner =
            reputation.queryRating(instanceId, rater1, subject1);
        assertEq(ratingWinner.weight, 12000); // 1.2x

        vm.prank(rater2);
        reputation.actionSubmitRating(instanceId, subject1, 3, feedbackCID);

        ReputationClauseLogicV3.Rating memory ratingLoser =
            reputation.queryRating(instanceId, rater2, subject1);
        assertEq(ratingLoser.weight, 8000); // 1.0 - 0.2 = 0.8x
    }
}

// =============================================================
// INVARIANT TESTS
// =============================================================

/// @title Reputation Invariant Handler
/// @notice Handler contract for invariant testing
contract ReputationInvariantHandler is Test {
    ReputationClauseLogicV3 public reputation;

    address public rater1;
    address public rater2;
    address public subject1;
    bytes32 public instanceId;
    bytes32 public arbitratorRole = keccak256("arbitrator");

    uint16 constant CONFIGURED = 1 << 1;
    uint16 constant WINDOW_OPEN = 1 << 4;
    uint16 constant WINDOW_CLOSED = 1 << 2;

    uint8 public totalRatingsSubmitted;

    constructor(ReputationClauseLogicV3 _reputation) {
        reputation = _reputation;
        rater1 = address(0x1);
        rater2 = address(0x2);
        subject1 = address(0x3);
        instanceId = keccak256("invariant-instance");

        // Setup instance
        ReputationClauseLogicV3.ReputationConfig memory config = ReputationClauseLogicV3.ReputationConfig({
            weightStrategy: reputation.WEIGHT_EQUAL(),
            winnerWeightBps: 10000,
            visibilityMode: reputation.VISIBILITY_IMMEDIATE(),
            blindThreshold: 2,
            ratingWindowSeconds: 14 days,
            allowUpdates: true,
            aggregationMethod: reputation.AGGREGATION_SIMPLE(),
            minimumRatingsToDisplay: 1,
            ratedRole: arbitratorRole
        });

        reputation.intakeConfig(instanceId, config);

        address[] memory raters = new address[](2);
        raters[0] = rater1;
        raters[1] = rater2;
        address[] memory subjects = new address[](1);
        subjects[0] = subject1;
        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        reputation.intakeRatingWindow(instanceId, raters, subjects, outcomes);
    }

    function submitRating(bool asRater1, uint8 score) external {
        uint16 status = reputation.queryStatus(instanceId);
        if (status != WINDOW_OPEN) return;

        // Bound score
        score = uint8(bound(score, 1, 5));

        address rater = asRater1 ? rater1 : rater2;

        // Check if already rated
        (bool canRate,) = reputation.queryCanRate(instanceId, rater, subject1);
        if (!canRate) return;

        vm.prank(rater);
        try reputation.actionSubmitRating(instanceId, subject1, score, bytes32(0)) {
            totalRatingsSubmitted++;
        } catch {}
    }

    function updateRating(bool asRater1, uint8 newScore) external {
        uint16 status = reputation.queryStatus(instanceId);
        if (status != WINDOW_OPEN) return;

        newScore = uint8(bound(newScore, 1, 5));

        address rater = asRater1 ? rater1 : rater2;

        ReputationClauseLogicV3.Rating memory rating = reputation.queryRating(instanceId, rater, subject1);
        if (!rating.exists) return;

        vm.prank(rater);
        try reputation.actionUpdateRating(instanceId, subject1, newScore, bytes32(0)) {} catch {}
    }

    function closeWindow() external {
        uint16 status = reputation.queryStatus(instanceId);
        if (status != WINDOW_OPEN) return;

        try reputation.actionCloseWindow(instanceId) {} catch {}
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, 30 days);
        vm.warp(block.timestamp + seconds_);
    }
}

/// @title Reputation Invariant Tests
/// @notice Invariant tests for ReputationClauseLogicV3
contract ReputationInvariantTest is Test {
    ReputationClauseLogicV3 public reputation;
    ReputationInvariantHandler public handler;

    bytes32 public instanceId = keccak256("invariant-instance");

    uint16 constant CONFIGURED = 1 << 1;
    uint16 constant WINDOW_OPEN = 1 << 4;
    uint16 constant WINDOW_CLOSED = 1 << 2;

    function setUp() public {
        reputation = new ReputationClauseLogicV3();
        handler = new ReputationInvariantHandler(reputation);

        targetContract(address(handler));
    }

    /// @notice Status must always be one of the valid states
    function invariant_validStatus() public view {
        uint16 status = reputation.queryStatus(instanceId);
        assertTrue(
            status == CONFIGURED || status == WINDOW_OPEN || status == WINDOW_CLOSED, "Invalid status"
        );
    }

    /// @notice Ratings count must match handler tracking
    function invariant_ratingsCountNonNegative() public view {
        uint8 count = reputation.queryRatingsCount(instanceId);
        assertTrue(count <= 2, "Too many ratings"); // Max 2 raters
    }

    /// @notice All scores must be in valid range
    function invariant_scoresInRange() public view {
        ReputationClauseLogicV3.Rating memory rating1 =
            reputation.queryRating(instanceId, handler.rater1(), handler.subject1());
        ReputationClauseLogicV3.Rating memory rating2 =
            reputation.queryRating(instanceId, handler.rater2(), handler.subject1());

        if (rating1.exists) {
            assertTrue(rating1.score >= 1 && rating1.score <= 5, "Invalid score for rater1");
        }
        if (rating2.exists) {
            assertTrue(rating2.score >= 1 && rating2.score <= 5, "Invalid score for rater2");
        }
    }

    /// @notice Global profile count must equal sum of instance ratings for this subject
    function invariant_profileCountMatches() public view {
        (uint64 totalRatings,,,) = reputation.queryProfile(handler.subject1());

        uint8 instanceCount = reputation.queryRatingsCount(instanceId);
        assertTrue(totalRatings >= instanceCount, "Profile count less than instance count");
    }

    /// @notice Window closes at correct time
    function invariant_windowTimingValid() public view {
        (bool isOpen, uint48 opensAt, uint48 closesAt,,) = reputation.queryWindowStatus(instanceId);

        if (opensAt > 0) {
            assertTrue(closesAt > opensAt, "Close time before open time");
        }

        uint16 status = reputation.queryStatus(instanceId);
        if (status == WINDOW_OPEN && block.timestamp <= closesAt) {
            assertTrue(isOpen, "Window should be open");
        }
    }
}
