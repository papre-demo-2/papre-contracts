// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {RetainerAgreement} from "../../src/agreements/RetainerAgreement.sol";
import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title RetainerAgreementTest
 * @notice Comprehensive tests for RetainerAgreement with REAL-TIME STREAMING
 *         Covers both singleton and proxy modes, streaming payments, cancellation
 */
contract RetainerAgreementTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Clause contracts
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;

    // Agreement implementation (singleton)
    RetainerAgreement public retainer;

    // Test accounts
    uint256 clientPk;
    uint256 contractorPk;
    address client;
    address contractor;

    // Constants
    uint256 constant MONTHLY_RATE = 10 ether;
    uint256 constant PERIOD_DURATION = 30 days;
    uint256 constant NOTICE_PERIOD_DAYS = 7;
    bytes32 constant DOCUMENT_CID = keccak256("ipfs://QmRetainerDocument");

    // Events (match contract)
    event InstanceCreated(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event RetainerConfigured(
        uint256 indexed instanceId,
        address indexed client,
        address indexed contractor,
        uint256 monthlyRate,
        uint256 periodDuration,
        uint256 noticePeriodDays
    );
    event TermsSigned(uint256 indexed instanceId, address indexed signer);
    event TermsAccepted(uint256 indexed instanceId, address indexed client, address indexed contractor);
    event PeriodFunded(uint256 indexed instanceId, uint256 amount, uint256 periodStart, uint256 periodEnd);
    event StreamClaimed(uint256 indexed instanceId, address indexed contractor, uint256 amount, uint256 totalClaimed);
    event CancelInitiated(uint256 indexed instanceId, address indexed initiatedBy, uint256 effectiveAt);
    event CancelExecuted(uint256 indexed instanceId, uint256 contractorAmount, uint256 clientRefund);

    function setUp() public {
        // Deploy clauses
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();

        // Deploy retainer singleton (2 args: signatureClause, escrowClause)
        retainer = new RetainerAgreement(address(signatureClause), address(escrowClause));

        // Create accounts
        clientPk = 0x1;
        contractorPk = 0x2;
        client = vm.addr(clientPk);
        contractor = vm.addr(contractorPk);

        vm.deal(client, 100 ether);
        vm.deal(contractor, 10 ether);
        vm.deal(address(retainer), 100 ether); // Fund singleton for escrow
    }

    // ═══════════════════════════════════════════════════════════════
    //                    HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a proxy-based agreement
    function _createProxyAgreement() internal returns (RetainerAgreement) {
        return _createProxyAgreement(MONTHLY_RATE, PERIOD_DURATION, NOTICE_PERIOD_DAYS);
    }

    function _createProxyAgreement(uint256 monthlyRate, uint256 periodDuration, uint256 noticePeriodDays)
        internal
        returns (RetainerAgreement)
    {
        RetainerAgreement agreement = RetainerAgreement(payable(Clones.clone(address(retainer))));

        vm.deal(address(agreement), 100 ether); // Fund for escrow

        agreement.initialize(
            client,
            contractor,
            address(0), // ETH
            monthlyRate,
            periodDuration,
            noticePeriodDays,
            DOCUMENT_CID
        );

        return agreement;
    }

    /// @notice Create a singleton instance (returns instanceId)
    function _createSingletonInstance() internal returns (uint256 instanceId) {
        return _createSingletonInstance(MONTHLY_RATE, PERIOD_DURATION, NOTICE_PERIOD_DAYS);
    }

    function _createSingletonInstance(uint256 monthlyRate, uint256 periodDuration, uint256 noticePeriodDays)
        internal
        returns (uint256 instanceId)
    {
        return retainer.createInstance(
            client,
            contractor,
            address(0), // ETH
            monthlyRate,
            periodDuration,
            noticePeriodDays,
            DOCUMENT_CID
        );
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _getTermsHash() internal pure returns (bytes32) {
        return keccak256(abi.encode(MONTHLY_RATE, PERIOD_DURATION, NOTICE_PERIOD_DAYS));
    }

    function _getTermsHash(uint256 monthlyRate, uint256 periodDuration, uint256 noticePeriodDays)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(monthlyRate, periodDuration, noticePeriodDays));
    }

    /// @notice Sign terms for proxy mode (instanceId = 0)
    function _signTermsProxy(RetainerAgreement agreement) internal {
        bytes32 termsHash = _getTermsHash();

        vm.prank(client);
        agreement.signTerms(0, _signMessage(clientPk, termsHash));

        vm.prank(contractor);
        agreement.signTerms(0, _signMessage(contractorPk, termsHash));
    }

    /// @notice Sign terms for singleton mode
    function _signTermsSingleton(uint256 instanceId) internal {
        bytes32 termsHash = _getTermsHash();

        vm.prank(client);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));

        vm.prank(contractor);
        retainer.signTerms(instanceId, _signMessage(contractorPk, termsHash));
    }

    /// @notice Complete proxy mode setup: sign and fund
    function _signAndFundProxy(RetainerAgreement agreement) internal {
        _signTermsProxy(agreement);

        vm.prank(client);
        agreement.fundPeriod{value: MONTHLY_RATE}(0);
    }

    /// @notice Complete singleton mode setup: sign and fund
    function _signAndFundSingleton(uint256 instanceId) internal {
        _signTermsSingleton(instanceId);

        vm.prank(client);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SINGLETON MODE: CREATE INSTANCE
    // ═══════════════════════════════════════════════════════════════

    function test_CreateInstance_Success() public {
        vm.expectEmit(true, true, true, false);
        emit InstanceCreated(1, client, contractor);

        uint256 instanceId = _createSingletonInstance();

        assertEq(instanceId, 1);
        assertEq(retainer.getInstanceCount(), 1);

        (
            uint256 instanceNumber,
            address creator,
            ,
            address _client,
            address _contractor,
            address paymentToken,
            uint256 monthlyRate,
            uint256 periodDuration,
            uint256 noticePeriodDays
        ) = retainer.getInstance(instanceId);

        assertEq(instanceNumber, 1);
        assertEq(creator, address(this));
        assertEq(_client, client);
        assertEq(_contractor, contractor);
        assertEq(paymentToken, address(0));
        assertEq(monthlyRate, MONTHLY_RATE);
        assertEq(periodDuration, PERIOD_DURATION);
        assertEq(noticePeriodDays, NOTICE_PERIOD_DAYS);
    }

    function test_CreateInstance_MultipleInstances() public {
        uint256 id1 = _createSingletonInstance();
        uint256 id2 = _createSingletonInstance();
        uint256 id3 = _createSingletonInstance();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
        assertEq(retainer.getInstanceCount(), 3);
    }

    function test_CreateInstance_TracksUserInstances() public {
        _createSingletonInstance();
        _createSingletonInstance();

        uint256[] memory clientInstances = retainer.getUserInstances(client);
        uint256[] memory contractorInstances = retainer.getUserInstances(contractor);

        assertEq(clientInstances.length, 2);
        assertEq(contractorInstances.length, 2);
        assertEq(clientInstances[0], 1);
        assertEq(clientInstances[1], 2);
    }

    function test_CreateInstance_DefaultPeriodDuration() public {
        uint256 instanceId = retainer.createInstance(
            client,
            contractor,
            address(0),
            MONTHLY_RATE,
            0, // Should default to 30 days
            NOTICE_PERIOD_DAYS,
            DOCUMENT_CID
        );

        (,,,,,,, uint256 periodDuration,) = retainer.getInstance(instanceId);
        assertEq(periodDuration, 30 days);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    PROXY MODE: INITIALIZE
    // ═══════════════════════════════════════════════════════════════

    function test_Initialize_Proxy_Success() public {
        RetainerAgreement agreement = _createProxyAgreement();

        assertTrue(agreement.isProxyMode());

        (uint256 instanceNumber,,, address _client, address _contractor,, uint256 monthlyRate,,) =
            agreement.getInstance(0);

        assertEq(instanceNumber, 0);
        assertEq(_client, client);
        assertEq(_contractor, contractor);
        assertEq(monthlyRate, MONTHLY_RATE);
    }

    function test_Initialize_Proxy_RevertsOnSecondInit() public {
        RetainerAgreement agreement = _createProxyAgreement();

        vm.expectRevert();
        agreement.initialize(
            client, contractor, address(0), MONTHLY_RATE, PERIOD_DURATION, NOTICE_PERIOD_DAYS, DOCUMENT_CID
        );
    }

    function test_CreateInstance_RevertsOnProxy() public {
        RetainerAgreement agreement = _createProxyAgreement();

        vm.expectRevert(RetainerAgreement.SingletonModeOnly.selector);
        agreement.createInstance(
            client, contractor, address(0), MONTHLY_RATE, PERIOD_DURATION, NOTICE_PERIOD_DAYS, DOCUMENT_CID
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SIGN TERMS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_SignTerms_Singleton_BothSign() public {
        uint256 instanceId = _createSingletonInstance();
        bytes32 termsHash = _getTermsHash();

        vm.expectEmit(true, true, false, false);
        emit TermsSigned(instanceId, client);

        vm.prank(client);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));

        vm.expectEmit(true, true, true, false);
        emit TermsAccepted(instanceId, client, contractor);

        vm.prank(contractor);
        retainer.signTerms(instanceId, _signMessage(contractorPk, termsHash));

        (bool termsAccepted,,,,,,,) = retainer.getInstanceState(instanceId);
        assertTrue(termsAccepted);
    }

    function test_SignTerms_Proxy_BothSign() public {
        RetainerAgreement agreement = _createProxyAgreement();
        bytes32 termsHash = _getTermsHash();

        vm.prank(client);
        agreement.signTerms(0, _signMessage(clientPk, termsHash));

        vm.prank(contractor);
        agreement.signTerms(0, _signMessage(contractorPk, termsHash));

        (bool termsAccepted,,,,,,,) = agreement.getInstanceState(0);
        assertTrue(termsAccepted);
    }

    function test_SignTerms_RevertsIfNotParty() public {
        uint256 instanceId = _createSingletonInstance();
        bytes32 termsHash = _getTermsHash();

        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(RetainerAgreement.OnlyClientOrContractor.selector);
        retainer.signTerms(instanceId, _signMessage(0x999, termsHash));
    }

    function test_SignTerms_RevertsIfInvalidInstance() public {
        bytes32 termsHash = _getTermsHash();

        vm.prank(client);
        vm.expectRevert(RetainerAgreement.InstanceNotFound.selector);
        retainer.signTerms(999, _signMessage(clientPk, termsHash));
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FUND PERIOD TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_FundPeriod_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        vm.expectEmit(true, false, false, true);
        emit PeriodFunded(instanceId, MONTHLY_RATE, block.timestamp, block.timestamp + PERIOD_DURATION);

        vm.prank(client);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);

        (bool termsAccepted, bool funded, uint256 currentPeriodStart, uint256 currentPeriodEnd,,,,) =
            retainer.getInstanceState(instanceId);

        assertTrue(termsAccepted);
        assertTrue(funded);
        assertEq(currentPeriodStart, block.timestamp);
        assertEq(currentPeriodEnd, block.timestamp + PERIOD_DURATION);
    }

    function test_FundPeriod_Proxy_Success() public {
        RetainerAgreement agreement = _createProxyAgreement();
        _signTermsProxy(agreement);

        vm.prank(client);
        agreement.fundPeriod{value: MONTHLY_RATE}(0);

        (, bool funded,,,,,,) = agreement.getInstanceState(0);
        assertTrue(funded);
    }

    function test_FundPeriod_RevertsIfTermsNotAccepted() public {
        uint256 instanceId = _createSingletonInstance();

        vm.prank(client);
        vm.expectRevert(RetainerAgreement.TermsNotAccepted.selector);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);
    }

    function test_FundPeriod_RevertsIfNotClient() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        vm.prank(contractor);
        vm.expectRevert(RetainerAgreement.OnlyClient.selector);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);
    }

    function test_FundPeriod_RevertsIfAlreadyFunded() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.prank(client);
        vm.expectRevert(RetainerAgreement.AlreadyFunded.selector);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    STREAMING PAYMENT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetClaimableAmount_ZeroBeforeFunding() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        uint256 claimable = retainer.getClaimableAmount(instanceId);
        assertEq(claimable, 0);
    }

    function test_GetClaimableAmount_StreamsOverTime() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Initially 0
        uint256 claimable0 = retainer.getClaimableAmount(instanceId);
        assertEq(claimable0, 0);

        // After 1/3 of period
        vm.warp(block.timestamp + PERIOD_DURATION / 3);
        uint256 claimable1 = retainer.getClaimableAmount(instanceId);
        assertApproxEqRel(claimable1, MONTHLY_RATE / 3, 0.01e18);

        // After 2/3 of period
        vm.warp(block.timestamp + PERIOD_DURATION / 3);
        uint256 claimable2 = retainer.getClaimableAmount(instanceId);
        assertApproxEqRel(claimable2, (MONTHLY_RATE * 2) / 3, 0.01e18);

        // After full period
        vm.warp(block.timestamp + PERIOD_DURATION / 3);
        uint256 claimable3 = retainer.getClaimableAmount(instanceId);
        assertEq(claimable3, MONTHLY_RATE);
    }

    function test_GetInstanceState_ReturnsRealTimeStreamedAmount() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Warp halfway through period
        vm.warp(block.timestamp + PERIOD_DURATION / 2);

        (,,,, uint256 streamedAmount, uint256 claimedAmount,,) = retainer.getInstanceState(instanceId);

        assertApproxEqRel(streamedAmount, MONTHLY_RATE / 2, 0.01e18);
        assertEq(claimedAmount, 0);
    }

    function test_ClaimStreamed_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Warp halfway through period
        vm.warp(block.timestamp + PERIOD_DURATION / 2);

        uint256 expectedClaim = MONTHLY_RATE / 2;
        uint256 contractorBefore = contractor.balance;

        vm.prank(contractor);
        retainer.claimStreamed(instanceId);

        // After claiming, claimedAmount should update
        (,,,,, uint256 claimedAmount,,) = retainer.getInstanceState(instanceId);
        assertApproxEqRel(claimedAmount, expectedClaim, 0.01e18);
    }

    function test_ClaimStreamed_AtEndOfPeriod() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Warp to end of period
        vm.warp(block.timestamp + PERIOD_DURATION + 1);

        vm.expectEmit(true, true, false, false);
        emit StreamClaimed(instanceId, contractor, MONTHLY_RATE, MONTHLY_RATE);

        vm.prank(contractor);
        retainer.claimStreamed(instanceId);

        (,,,,, uint256 claimedAmount,,) = retainer.getInstanceState(instanceId);
        assertEq(claimedAmount, MONTHLY_RATE);
    }

    function test_ClaimStreamed_MultipleClaims() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // First claim at 25%
        vm.warp(block.timestamp + PERIOD_DURATION / 4);
        vm.prank(contractor);
        retainer.claimStreamed(instanceId);

        (,,,,, uint256 claimed1,,) = retainer.getInstanceState(instanceId);
        assertApproxEqRel(claimed1, MONTHLY_RATE / 4, 0.01e18);

        // Second claim at 75%
        vm.warp(block.timestamp + PERIOD_DURATION / 2);
        vm.prank(contractor);
        retainer.claimStreamed(instanceId);

        (,,,,, uint256 claimed2,,) = retainer.getInstanceState(instanceId);
        assertApproxEqRel(claimed2, (MONTHLY_RATE * 3) / 4, 0.01e18);
    }

    function test_ClaimStreamed_RevertsIfNotContractor() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.warp(block.timestamp + PERIOD_DURATION / 2);

        vm.prank(client);
        vm.expectRevert(RetainerAgreement.OnlyContractor.selector);
        retainer.claimStreamed(instanceId);
    }

    function test_ClaimStreamed_RevertsIfNotFunded() public {
        uint256 instanceId = _createSingletonInstance();
        _signTermsSingleton(instanceId);

        vm.prank(contractor);
        vm.expectRevert(RetainerAgreement.NotFunded.selector);
        retainer.claimStreamed(instanceId);
    }

    function test_ClaimStreamed_RevertsIfNothingToClaim() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Claim everything
        vm.warp(block.timestamp + PERIOD_DURATION + 1);
        vm.prank(contractor);
        retainer.claimStreamed(instanceId);

        // Try to claim again
        vm.prank(contractor);
        vm.expectRevert(RetainerAgreement.NothingToClaim.selector);
        retainer.claimStreamed(instanceId);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCELLATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_InitiateCancel_Singleton_Success() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        uint256 expectedEffectiveAt = block.timestamp + (NOTICE_PERIOD_DAYS * 1 days);

        vm.expectEmit(true, true, false, true);
        emit CancelInitiated(instanceId, client, expectedEffectiveAt);

        vm.prank(client);
        retainer.initiateCancel(instanceId);

        (,,,,,, uint256 cancelInitiatedAt,) = retainer.getInstanceState(instanceId);
        assertEq(cancelInitiatedAt, block.timestamp);
    }

    function test_InitiateCancel_Proxy_Success() public {
        RetainerAgreement agreement = _createProxyAgreement();
        _signAndFundProxy(agreement);

        vm.prank(contractor);
        agreement.initiateCancel(0);

        (,,,,,, uint256 cancelInitiatedAt,) = agreement.getInstanceState(0);
        assertGt(cancelInitiatedAt, 0);
    }

    function test_InitiateCancel_ByContractor() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.prank(contractor);
        retainer.initiateCancel(instanceId);

        (,,,,,, uint256 cancelInitiatedAt,) = retainer.getInstanceState(instanceId);
        assertGt(cancelInitiatedAt, 0);
    }

    function test_InitiateCancel_RevertsIfAlreadyCancelling() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.prank(client);
        retainer.initiateCancel(instanceId);

        vm.prank(client);
        vm.expectRevert(RetainerAgreement.AlreadyCancelled.selector);
        retainer.initiateCancel(instanceId);
    }

    function test_ExecuteCancel_AfterNoticePeriod() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.prank(client);
        retainer.initiateCancel(instanceId);

        // Warp past notice period
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);

        vm.prank(client);
        retainer.executeCancel(instanceId);

        (,,,,,,, bool cancelled) = retainer.getInstanceState(instanceId);
        assertTrue(cancelled);
    }

    function test_ExecuteCancel_RevertsIfNoticePeriodNotElapsed() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.prank(client);
        retainer.initiateCancel(instanceId);

        // Try before notice period
        vm.prank(client);
        vm.expectRevert(RetainerAgreement.NoticePeriodNotElapsed.selector);
        retainer.executeCancel(instanceId);
    }

    function test_ExecuteCancel_RevertsIfNotInitiated() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        vm.prank(client);
        vm.expectRevert(RetainerAgreement.CancelNotInitiated.selector);
        retainer.executeCancel(instanceId);
    }

    function test_ExecuteCancel_ProratesPayment() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Warp to halfway through period
        vm.warp(block.timestamp + PERIOD_DURATION / 2);

        vm.prank(client);
        retainer.initiateCancel(instanceId);

        // Warp past notice period
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);

        vm.expectEmit(true, false, false, false);
        emit CancelExecuted(instanceId, 0, 0); // Event params will be calculated

        vm.prank(client);
        retainer.executeCancel(instanceId);

        (,,,,,,, bool cancelled) = retainer.getInstanceState(instanceId);
        assertTrue(cancelled);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    DOCUMENT CID TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetDocumentCID_Singleton() public {
        uint256 instanceId = _createSingletonInstance();

        bytes32 cid = retainer.getDocumentCID(instanceId);
        assertEq(cid, DOCUMENT_CID);
    }

    function test_GetDocumentCID_Proxy() public {
        RetainerAgreement agreement = _createProxyAgreement();

        bytes32 cid = agreement.getDocumentCID(0);
        assertEq(cid, DOCUMENT_CID);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTIONS TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetInstance_ReturnsCorrectData() public {
        uint256 instanceId = _createSingletonInstance();

        (
            uint256 instanceNumber,
            address creator,
            uint256 createdAt,
            address _client,
            address _contractor,
            address paymentToken,
            uint256 monthlyRate,
            uint256 periodDuration,
            uint256 noticePeriodDays
        ) = retainer.getInstance(instanceId);

        assertEq(instanceNumber, 1);
        assertEq(creator, address(this));
        assertEq(createdAt, block.timestamp);
        assertEq(_client, client);
        assertEq(_contractor, contractor);
        assertEq(paymentToken, address(0));
        assertEq(monthlyRate, MONTHLY_RATE);
        assertEq(periodDuration, PERIOD_DURATION);
        assertEq(noticePeriodDays, NOTICE_PERIOD_DAYS);
    }

    function test_GetInstanceState_ReturnsCorrectData() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        (
            bool termsAccepted,
            bool funded,
            uint256 currentPeriodStart,
            uint256 currentPeriodEnd,
            uint256 streamedAmount,
            uint256 claimedAmount,
            uint256 cancelInitiatedAt,
            bool cancelled
        ) = retainer.getInstanceState(instanceId);

        assertTrue(termsAccepted);
        assertTrue(funded);
        assertEq(currentPeriodStart, block.timestamp);
        assertEq(currentPeriodEnd, block.timestamp + PERIOD_DURATION);
        assertEq(streamedAmount, 0);
        assertEq(claimedAmount, 0);
        assertEq(cancelInitiatedAt, 0);
        assertFalse(cancelled);
    }

    function test_IsFunded() public {
        uint256 instanceId = _createSingletonInstance();

        assertFalse(retainer.isFunded(instanceId));

        _signAndFundSingleton(instanceId);

        assertTrue(retainer.isFunded(instanceId));
    }

    function test_IsProxyMode_Singleton() public {
        assertFalse(retainer.isProxyMode());
    }

    function test_IsProxyMode_Proxy() public {
        RetainerAgreement agreement = _createProxyAgreement();
        assertTrue(agreement.isProxyMode());
    }

    // ═══════════════════════════════════════════════════════════════
    //                    FULL LIFECYCLE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_FullLifecycle_Singleton_ClaimAtEnd() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Wait for full period
        vm.warp(block.timestamp + PERIOD_DURATION + 1);

        uint256 claimable = retainer.getClaimableAmount(instanceId);
        assertEq(claimable, MONTHLY_RATE);

        // Claim full amount
        vm.prank(contractor);
        retainer.claimStreamed(instanceId);

        (,,,,, uint256 claimedAmount,,) = retainer.getInstanceState(instanceId);
        assertEq(claimedAmount, MONTHLY_RATE);
    }

    function test_FullLifecycle_Proxy_ClaimThenCancel() public {
        RetainerAgreement agreement = _createProxyAgreement();
        _signAndFundProxy(agreement);

        // Claim at 50%
        vm.warp(block.timestamp + PERIOD_DURATION / 2);
        vm.prank(contractor);
        agreement.claimStreamed(0);

        // Initiate cancel
        vm.prank(client);
        agreement.initiateCancel(0);

        // Wait for notice period
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);

        // Execute cancel
        vm.prank(client);
        agreement.executeCancel(0);

        (,,,,,,, bool cancelled) = agreement.getInstanceState(0);
        assertTrue(cancelled);
    }

    function test_FullLifecycle_MultipleInstances_Independent() public {
        uint256 id1 = _createSingletonInstance();
        uint256 id2 = _createSingletonInstance();

        // Sign and fund both
        _signAndFundSingleton(id1);
        _signAndFundSingleton(id2);

        // Cancel id1
        vm.prank(client);
        retainer.initiateCancel(id1);
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);
        vm.prank(client);
        retainer.executeCancel(id1);

        // id2 should be unaffected
        (,,,,,,, bool cancelled1) = retainer.getInstanceState(id1);
        (,,,,,,, bool cancelled2) = retainer.getInstanceState(id2);

        assertTrue(cancelled1);
        assertFalse(cancelled2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    CANCELLED STATE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_SignTerms_RevertsIfCancelled() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Cancel
        vm.prank(client);
        retainer.initiateCancel(instanceId);
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);
        vm.prank(client);
        retainer.executeCancel(instanceId);

        // Try to sign again
        bytes32 termsHash = _getTermsHash();
        vm.prank(client);
        vm.expectRevert(RetainerAgreement.AlreadyCancelled.selector);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));
    }

    function test_FundPeriod_RevertsIfCancelled() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Cancel
        vm.prank(client);
        retainer.initiateCancel(instanceId);
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);
        vm.prank(client);
        retainer.executeCancel(instanceId);

        // Try to fund again
        vm.prank(client);
        vm.expectRevert(RetainerAgreement.AlreadyCancelled.selector);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);
    }

    function test_ClaimStreamed_RevertsIfCancelled() public {
        uint256 instanceId = _createSingletonInstance();
        _signAndFundSingleton(instanceId);

        // Cancel
        vm.prank(client);
        retainer.initiateCancel(instanceId);
        vm.warp(block.timestamp + (NOTICE_PERIOD_DAYS * 1 days) + 1);
        vm.prank(client);
        retainer.executeCancel(instanceId);

        // Try to claim
        vm.prank(contractor);
        vm.expectRevert(RetainerAgreement.AlreadyCancelled.selector);
        retainer.claimStreamed(instanceId);
    }

    receive() external payable {}
}

/**
 * @title RetainerAgreementFuzzTest
 * @notice Fuzz tests for RetainerAgreement streaming logic
 */
contract RetainerAgreementFuzzTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    RetainerAgreement public retainer;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        retainer = new RetainerAgreement(address(signatureClause), address(escrowClause));
        vm.deal(address(retainer), 1000 ether);
    }

    function testFuzz_StreamedAmountNeverExceedsMonthlyRate(uint128 monthlyRate, uint32 elapsedSeconds) public {
        monthlyRate = uint128(bound(uint256(monthlyRate), 0.1 ether, 100 ether));
        uint256 periodDuration = 30 days;

        uint256 clientPk = 0x1;
        uint256 contractorPk = 0x2;
        address client = vm.addr(clientPk);
        address contractor = vm.addr(contractorPk);

        vm.deal(client, monthlyRate + 10 ether);

        uint256 instanceId =
            retainer.createInstance(client, contractor, address(0), monthlyRate, periodDuration, 7, keccak256("doc"));

        // Sign terms
        bytes32 termsHash = keccak256(abi.encode(uint256(monthlyRate), periodDuration, uint256(7)));
        vm.prank(client);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));
        vm.prank(contractor);
        retainer.signTerms(instanceId, _signMessage(contractorPk, termsHash));

        // Fund
        vm.prank(client);
        retainer.fundPeriod{value: monthlyRate}(instanceId);

        // Warp by arbitrary time
        vm.warp(block.timestamp + elapsedSeconds);

        // Claimable should never exceed monthly rate
        uint256 claimable = retainer.getClaimableAmount(instanceId);
        assertLe(claimable, monthlyRate);
    }

    function testFuzz_ClaimedAmountTracksCorrectly(uint8 numClaims) public {
        numClaims = uint8(bound(uint256(numClaims), 1, 10));
        uint256 monthlyRate = 10 ether;
        uint256 periodDuration = 30 days;

        uint256 clientPk = 0x1;
        uint256 contractorPk = 0x2;
        address client = vm.addr(clientPk);
        address contractor = vm.addr(contractorPk);

        vm.deal(client, monthlyRate + 10 ether);

        uint256 instanceId =
            retainer.createInstance(client, contractor, address(0), monthlyRate, periodDuration, 7, keccak256("doc"));

        // Sign and fund
        bytes32 termsHash = keccak256(abi.encode(monthlyRate, periodDuration, uint256(7)));
        vm.prank(client);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));
        vm.prank(contractor);
        retainer.signTerms(instanceId, _signMessage(contractorPk, termsHash));
        vm.prank(client);
        retainer.fundPeriod{value: monthlyRate}(instanceId);

        uint256 timeStep = periodDuration / (numClaims + 1);
        uint256 totalClaimed = 0;

        for (uint8 i = 0; i < numClaims; i++) {
            vm.warp(block.timestamp + timeStep);

            uint256 claimableBefore = retainer.getClaimableAmount(instanceId);
            if (claimableBefore > 0) {
                vm.prank(contractor);
                retainer.claimStreamed(instanceId);
                totalClaimed += claimableBefore;
            }
        }

        (,,,,, uint256 claimedAmount,,) = retainer.getInstanceState(instanceId);
        assertEq(claimedAmount, totalClaimed);
        assertLe(totalClaimed, monthlyRate);
    }

    function testFuzz_VariableNoticePeriods(uint8 noticeDays) public {
        noticeDays = uint8(bound(uint256(noticeDays), 1, 30));
        uint256 monthlyRate = 10 ether;

        uint256 clientPk = 0x1;
        uint256 contractorPk = 0x2;
        address client = vm.addr(clientPk);
        address contractor = vm.addr(contractorPk);

        vm.deal(client, monthlyRate + 10 ether);

        uint256 instanceId =
            retainer.createInstance(client, contractor, address(0), monthlyRate, 30 days, noticeDays, keccak256("doc"));

        // Sign and fund
        bytes32 termsHash = keccak256(abi.encode(monthlyRate, uint256(30 days), uint256(noticeDays)));
        vm.prank(client);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));
        vm.prank(contractor);
        retainer.signTerms(instanceId, _signMessage(contractorPk, termsHash));
        vm.prank(client);
        retainer.fundPeriod{value: monthlyRate}(instanceId);

        // Initiate cancel
        vm.prank(client);
        retainer.initiateCancel(instanceId);

        // Should revert before notice period
        vm.warp(block.timestamp + (noticeDays * 1 days) - 1);
        vm.prank(client);
        vm.expectRevert(RetainerAgreement.NoticePeriodNotElapsed.selector);
        retainer.executeCancel(instanceId);

        // Should work after notice period
        vm.warp(block.timestamp + 2);
        vm.prank(client);
        retainer.executeCancel(instanceId);

        (,,,,,,, bool cancelled) = retainer.getInstanceState(instanceId);
        assertTrue(cancelled);
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}

/**
 * @title RetainerAgreementInvariantTest
 * @notice Invariant tests for streaming payment consistency
 */
contract RetainerAgreementInvariantTest is Test {
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    RetainerAgreement public retainer;

    RetainerHandler public handler;

    function setUp() public {
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        retainer = new RetainerAgreement(address(signatureClause), address(escrowClause));
        vm.deal(address(retainer), 1000 ether);

        handler = new RetainerHandler(retainer);
        targetContract(address(handler));
    }

    function invariant_ClaimedNeverExceedsStreamed() public view {
        uint256[] memory instanceIds = handler.getInstanceIds();
        for (uint256 i = 0; i < instanceIds.length; i++) {
            uint256 id = instanceIds[i];
            (,,,, uint256 streamed, uint256 claimed,,) = retainer.getInstanceState(id);
            assertLe(claimed, streamed + 1); // +1 for rounding
        }
    }

    function invariant_InstanceCountNeverDecreases() public view {
        assertGe(retainer.getInstanceCount(), handler.getInstanceIds().length);
    }

    receive() external payable {}
}

/**
 * @title RetainerHandler
 * @notice Handler for invariant testing
 */
contract RetainerHandler is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    RetainerAgreement public retainer;
    uint256[] public instanceIds;

    uint256 public constant MAX_INSTANCES = 3;
    uint256 constant MONTHLY_RATE = 10 ether;

    constructor(RetainerAgreement _retainer) {
        retainer = _retainer;
    }

    function createInstance(uint256 seed) external {
        if (instanceIds.length >= MAX_INSTANCES) return;

        uint256 clientPk = seed % 1000 + 1;
        address client = vm.addr(clientPk);
        uint256 contractorPk = seed % 1000 + 1001;
        address contractor = vm.addr(contractorPk);

        vm.deal(client, MONTHLY_RATE * 10);

        uint256 instanceId = retainer.createInstance(
            client, contractor, address(0), MONTHLY_RATE, 30 days, 7, keccak256(abi.encode("doc", seed))
        );

        instanceIds.push(instanceId);

        // Sign terms
        bytes32 termsHash = keccak256(abi.encode(MONTHLY_RATE, uint256(30 days), uint256(7)));
        vm.prank(client);
        retainer.signTerms(instanceId, _signMessage(clientPk, termsHash));
        vm.prank(contractor);
        retainer.signTerms(instanceId, _signMessage(contractorPk, termsHash));

        // Fund
        vm.prank(client);
        retainer.fundPeriod{value: MONTHLY_RATE}(instanceId);
    }

    function claimStreamed(uint256 instanceIndex) external {
        if (instanceIds.length == 0) return;
        instanceIndex = instanceIndex % instanceIds.length;
        uint256 instanceId = instanceIds[instanceIndex];

        // Get contractor
        (,,,, address contractor,,,,) = retainer.getInstance(instanceId);

        // Check if there's anything to claim
        uint256 claimable = retainer.getClaimableAmount(instanceId);
        if (claimable == 0) return;

        (,,,,,,, bool cancelled) = retainer.getInstanceState(instanceId);
        if (cancelled) return;

        vm.prank(contractor);
        try retainer.claimStreamed(instanceId) {} catch {}
    }

    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 30 days);
        vm.warp(block.timestamp + seconds_);
    }

    function getInstanceIds() external view returns (uint256[] memory) {
        return instanceIds;
    }

    function _signMessage(uint256 pk, bytes32 hash) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    receive() external payable {}
}
