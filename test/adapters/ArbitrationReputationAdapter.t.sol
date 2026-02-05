// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ArbitrationReputationAdapter} from "../../src/adapters/ArbitrationReputationAdapter.sol";
import {ReputationClauseLogicV3} from "../../src/clauses/reputation/ReputationClauseLogicV3.sol";

/// @title Mock Agreement for testing the adapter
/// @notice Simulates how a real agreement would use the adapter via delegatecall
contract MockAgreementWithReputation {
    ArbitrationReputationAdapter public immutable reputationAdapter;

    constructor(address _adapter) {
        reputationAdapter = ArbitrationReputationAdapter(_adapter);
    }

    function openReputationWindow(
        bytes32 agreementInstanceId,
        address arbitrator,
        address[] calldata raters,
        uint8[] calldata outcomes,
        uint32 windowDuration
    ) external {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(
                ArbitrationReputationAdapter.openReputationWindow,
                (agreementInstanceId, arbitrator, raters, outcomes, windowDuration)
            )
        );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function rateArbitrator(bytes32 agreementInstanceId, uint8 score, bytes32 feedbackCID) external {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.rateArbitrator, (agreementInstanceId, score, feedbackCID))
        );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function updateArbitratorRating(bytes32 agreementInstanceId, uint8 score, bytes32 feedbackCID) external {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(
                ArbitrationReputationAdapter.updateArbitratorRating, (agreementInstanceId, score, feedbackCID)
            )
        );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    function closeReputationWindow(bytes32 agreementInstanceId) external {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.closeReputationWindow, (agreementInstanceId))
        );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
    }

    // Query functions also need delegatecall since they read from this contract's storage
    function getReputationInstanceId(bytes32 agreementInstanceId) external returns (bytes32) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getReputationInstanceId, (agreementInstanceId))
        );
        require(success, "Query failed");
        return abi.decode(data, (bytes32));
    }

    function getRatedArbitrator(bytes32 agreementInstanceId) external returns (address) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getRatedArbitrator, (agreementInstanceId))
        );
        require(success, "Query failed");
        return abi.decode(data, (address));
    }

    function isReputationConfigured(bytes32 agreementInstanceId) external returns (bool) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.isReputationConfigured, (agreementInstanceId))
        );
        require(success, "Query failed");
        return abi.decode(data, (bool));
    }

    function canRateArbitrator(bytes32 agreementInstanceId) external returns (bool, string memory) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.canRateArbitrator, (agreementInstanceId))
        );
        require(success, "Query failed");
        return abi.decode(data, (bool, string));
    }

    function getWindowStatus(bytes32 agreementInstanceId)
        external
        returns (bool, uint48, uint48, uint8, uint8)
    {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getWindowStatus, (agreementInstanceId))
        );
        require(success, "Query failed");
        return abi.decode(data, (bool, uint48, uint48, uint8, uint8));
    }

    function getArbitratorProfile(address arbitrator)
        external
        returns (uint64, uint16, uint48, uint48)
    {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getArbitratorProfile, (arbitrator))
        );
        require(success, "Query failed");
        return abi.decode(data, (uint64, uint16, uint48, uint48));
    }

    function getArbitratorRoleReputation(address arbitrator) external returns (uint32, uint16) {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getArbitratorRoleReputation, (arbitrator))
        );
        require(success, "Query failed");
        return abi.decode(data, (uint32, uint16));
    }

    function getTopArbitrators(uint8 limit, uint8 minRatings)
        external
        returns (address[] memory, uint16[] memory)
    {
        (bool success, bytes memory data) = address(reputationAdapter).delegatecall(
            abi.encodeCall(ArbitrationReputationAdapter.getTopArbitrators, (limit, minRatings))
        );
        require(success, "Query failed");
        return abi.decode(data, (address[], uint16[]));
    }
}

/// @title ArbitrationReputationAdapter Test Suite
/// @notice Tests the adapter for arbitrator reputation tracking
contract ArbitrationReputationAdapterTest is Test {
    ArbitrationReputationAdapter public adapter;
    ReputationClauseLogicV3 public reputationClause;
    MockAgreementWithReputation public agreement;

    address public claimant = address(0x1);
    address public respondent = address(0x2);
    address public arbitrator = address(0x3);
    address public randomUser = address(0x4);

    bytes32 public agreementInstanceId = bytes32(uint256(1));
    bytes32 public feedbackCID = keccak256("Good arbitration");

    function setUp() public {
        // Deploy clause and adapter
        reputationClause = new ReputationClauseLogicV3();
        adapter = new ArbitrationReputationAdapter(address(reputationClause));
        agreement = new MockAgreementWithReputation(address(adapter));
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _openWindow() internal {
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputationClause.OUTCOME_WINNER(); // claimant won
        outcomes[1] = reputationClause.OUTCOME_LOSER(); // respondent lost

        agreement.openReputationWindow(agreementInstanceId, arbitrator, raters, outcomes, 0);
    }

    // =============================================================
    // UNIT TESTS: DEPLOYMENT
    // =============================================================

    function test_deployment() public view {
        assertEq(address(adapter.reputationClause()), address(reputationClause));
        assertEq(adapter.ARBITRATOR_ROLE(), keccak256("arbitrator"));
        assertEq(adapter.DEFAULT_RATING_WINDOW(), 14 days);
    }

    // =============================================================
    // UNIT TESTS: OPEN REPUTATION WINDOW
    // =============================================================

    function test_openReputationWindow_basic() public {
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = reputationClause.OUTCOME_WINNER();
        outcomes[1] = reputationClause.OUTCOME_LOSER();

        agreement.openReputationWindow(agreementInstanceId, arbitrator, raters, outcomes, 0);

        // Check storage was updated
        bytes32 reputationInstanceId = agreement.getReputationInstanceId(agreementInstanceId);
        assertTrue(reputationInstanceId != bytes32(0));

        address ratedArbitrator = agreement.getRatedArbitrator(agreementInstanceId);
        assertEq(ratedArbitrator, arbitrator);

        bool configured = agreement.isReputationConfigured(agreementInstanceId);
        assertTrue(configured);
    }

    function test_openReputationWindow_withCustomDuration() public {
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        uint32 customDuration = 7 days;

        agreement.openReputationWindow(agreementInstanceId, arbitrator, raters, outcomes, customDuration);

        // Verify window closes at expected time
        (bool isOpen,, uint48 closesAt,,) = agreement.getWindowStatus(agreementInstanceId);
        assertTrue(isOpen);
        assertEq(closesAt, uint48(block.timestamp + customDuration));
    }

    function test_openReputationWindow_revertsIfNoArbitrator() public {
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        vm.expectRevert(ArbitrationReputationAdapter.NoArbitratorToRate.selector);
        agreement.openReputationWindow(agreementInstanceId, address(0), raters, outcomes, 0);
    }

    function test_openReputationWindow_revertsIfArrayMismatch() public {
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](1); // Wrong length
        outcomes[0] = 1;

        vm.expectRevert(ArbitrationReputationAdapter.ArrayLengthMismatch.selector);
        agreement.openReputationWindow(agreementInstanceId, arbitrator, raters, outcomes, 0);
    }

    function test_openReputationWindow_revertsIfAlreadyConfigured() public {
        _openWindow();

        // Try to open again
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        vm.expectRevert(ArbitrationReputationAdapter.ReputationAlreadyConfigured.selector);
        agreement.openReputationWindow(agreementInstanceId, arbitrator, raters, outcomes, 0);
    }

    // =============================================================
    // UNIT TESTS: RATE ARBITRATOR
    // =============================================================

    function test_rateArbitrator_byClaimant() public {
        _openWindow();

        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 5, feedbackCID);

        // Check profile was updated
        (uint64 totalRatings, uint16 averageScore,,) = agreement.getArbitratorProfile(arbitrator);
        assertEq(totalRatings, 1);
        assertEq(averageScore, 500); // 5.00 scaled
    }

    function test_rateArbitrator_byRespondent() public {
        _openWindow();

        vm.prank(respondent);
        agreement.rateArbitrator(agreementInstanceId, 3, feedbackCID);

        (uint64 totalRatings, uint16 averageScore,,) = agreement.getArbitratorProfile(arbitrator);
        assertEq(totalRatings, 1);
        assertEq(averageScore, 300);
    }

    function test_rateArbitrator_bothParties() public {
        _openWindow();

        // Claimant rates
        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 5, feedbackCID);

        // Respondent rates
        vm.prank(respondent);
        agreement.rateArbitrator(agreementInstanceId, 3, bytes32(0));

        // Check aggregated profile
        (uint64 totalRatings, uint16 averageScore,,) = agreement.getArbitratorProfile(arbitrator);
        assertEq(totalRatings, 2);
        assertEq(averageScore, 400); // (5+3)/2 = 4.00
    }

    function test_rateArbitrator_revertsIfWindowNotOpen() public {
        vm.prank(claimant);
        vm.expectRevert(ArbitrationReputationAdapter.ReputationWindowNotOpen.selector);
        agreement.rateArbitrator(agreementInstanceId, 5, feedbackCID);
    }

    // =============================================================
    // UNIT TESTS: UPDATE RATING
    // =============================================================

    function test_updateArbitratorRating() public {
        _openWindow();

        // Initial rating
        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 3, feedbackCID);

        // Update rating
        vm.prank(claimant);
        agreement.updateArbitratorRating(agreementInstanceId, 5, keccak256("Updated"));

        // Check updated profile
        (uint64 totalRatings, uint16 averageScore,,) = agreement.getArbitratorProfile(arbitrator);
        assertEq(totalRatings, 1); // Still 1 rating
        assertEq(averageScore, 500); // Updated to 5.00
    }

    // =============================================================
    // UNIT TESTS: CLOSE WINDOW
    // =============================================================

    function test_closeReputationWindow() public {
        _openWindow();

        agreement.closeReputationWindow(agreementInstanceId);

        // Window should be closed
        (bool isOpen,,,,) = agreement.getWindowStatus(agreementInstanceId);
        assertFalse(isOpen);
    }

    function test_closeReputationWindow_revertsIfNotOpen() public {
        vm.expectRevert(ArbitrationReputationAdapter.ReputationWindowNotOpen.selector);
        agreement.closeReputationWindow(agreementInstanceId);
    }

    // =============================================================
    // UNIT TESTS: QUERY FUNCTIONS
    // =============================================================

    function test_canRateArbitrator_beforeWindow() public {
        (bool canRate, string memory reason) = agreement.canRateArbitrator(agreementInstanceId);
        assertFalse(canRate);
        assertEq(reason, "Reputation window not open");
    }

    function test_canRateArbitrator_eligible() public {
        _openWindow();

        vm.prank(claimant);
        (bool canRate, string memory reason) = agreement.canRateArbitrator(agreementInstanceId);
        assertTrue(canRate);
        assertEq(reason, "");
    }

    function test_getWindowStatus() public {
        _openWindow();

        (bool isOpen, uint48 opensAt, uint48 closesAt, uint8 ratingsSubmitted, uint8 ratersCount) =
            agreement.getWindowStatus(agreementInstanceId);

        assertTrue(isOpen);
        assertEq(opensAt, uint48(block.timestamp));
        assertEq(closesAt, uint48(block.timestamp + 14 days));
        assertEq(ratingsSubmitted, 0);
        assertEq(ratersCount, 2);
    }

    function test_getWindowStatus_afterRating() public {
        _openWindow();

        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 5, feedbackCID);

        (,,, uint8 ratingsSubmitted,) = agreement.getWindowStatus(agreementInstanceId);
        assertEq(ratingsSubmitted, 1);
    }

    // =============================================================
    // UNIT TESTS: GLOBAL PROFILE QUERIES
    // =============================================================

    function test_getArbitratorProfile_noRatings() public {
        (uint64 totalRatings, uint16 averageScore, uint48 firstRatingAt, uint48 lastRatingAt) =
            agreement.getArbitratorProfile(arbitrator);

        assertEq(totalRatings, 0);
        assertEq(averageScore, 0);
        assertEq(firstRatingAt, 0);
        assertEq(lastRatingAt, 0);
    }

    function test_getArbitratorRoleReputation() public {
        _openWindow();

        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 4, feedbackCID);

        (uint32 count, uint16 averageScore) = agreement.getArbitratorRoleReputation(arbitrator);
        assertEq(count, 1);
        assertEq(averageScore, 400);
    }

    function test_getTopArbitrators() public {
        _openWindow();

        // Rate arbitrator
        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 5, feedbackCID);

        (address[] memory arbitrators, uint16[] memory scores) = agreement.getTopArbitrators(10, 1);
        assertEq(arbitrators.length, 1);
        assertEq(arbitrators[0], arbitrator);
        assertEq(scores[0], 500);
    }

    // =============================================================
    // UNIT TESTS: MULTIPLE INSTANCES
    // =============================================================

    function test_multipleInstances_isolated() public {
        bytes32 agreementInstanceId2 = bytes32(uint256(2));
        address arbitrator2 = address(0x5);

        // Open window for first instance
        _openWindow();

        // Open window for second instance
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 1;
        outcomes[1] = 2;

        agreement.openReputationWindow(agreementInstanceId2, arbitrator2, raters, outcomes, 0);

        // Verify isolation
        assertEq(agreement.getRatedArbitrator(agreementInstanceId), arbitrator);
        assertEq(agreement.getRatedArbitrator(agreementInstanceId2), arbitrator2);
    }

    function test_multipleInstances_aggregateGlobalProfile() public {
        bytes32 agreementInstanceId2 = bytes32(uint256(2));

        // First instance - rate arbitrator 5 stars
        _openWindow();
        vm.prank(claimant);
        agreement.rateArbitrator(agreementInstanceId, 5, feedbackCID);

        // Second instance - rate SAME arbitrator 3 stars
        address[] memory raters = new address[](2);
        raters[0] = claimant;
        raters[1] = respondent;

        uint8[] memory outcomes = new uint8[](2);
        outcomes[0] = 2; // claimant lost this time
        outcomes[1] = 1; // respondent won

        agreement.openReputationWindow(agreementInstanceId2, arbitrator, raters, outcomes, 0);

        vm.prank(respondent);
        agreement.rateArbitrator(agreementInstanceId2, 3, bytes32(0));

        // Check aggregated global profile
        (uint64 totalRatings, uint16 averageScore,,) = agreement.getArbitratorProfile(arbitrator);
        assertEq(totalRatings, 2);
        assertEq(averageScore, 400); // (5+3)/2 = 4.00
    }
}
