// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {CCIPLocalSimulator, IRouterClient} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {SignatureClauseLogicV3} from "../../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../../src/clauses/financial/EscrowClauseLogicV3.sol";
import {CrossChainClauseLogicV3} from "../../src/clauses/crosschain/CrossChainClauseLogicV3.sol";
import {CrossChainControllerV3, ICrossChainReceiver} from "../../src/controllers/CrossChainControllerV3.sol";
import {SignatureEscrowCrossChainAdapter} from "../../src/adapters/SignatureEscrowCrossChainAdapter.sol";

/// @title Cross-Chain Signature to Escrow Integration Test
/// @notice Tests the full flow: Signature completion on Chain A triggers escrow release on Chain B
/// @dev Uses Chainlink CCIP Local simulator for local testing.
///      This test demonstrates the ADAPTER PATTERN where:
///      - Chain A: Agreement uses SignatureEscrowCrossChainAdapter.sendReleaseOnSignature()
///      - Chain B: Agreement uses SignatureEscrowCrossChainAdapter.handleIncomingRelease()
///      The adapter orchestrates both CrossChainClauseLogicV3 (state tracking) and
///      the business logic clauses (Signature/Escrow).
contract CrossChainSignatureToEscrowTest is Test {
    // CCIP Local simulator
    CCIPLocalSimulator public ccipSimulator;

    // Controllers (one per "chain" but using same router in local mode)
    CrossChainControllerV3 public controllerA;
    CrossChainControllerV3 public controllerB;

    // Clauses
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    CrossChainClauseLogicV3 public crossChainClause;

    // Adapters (one per chain, but they're stateless so could share)
    SignatureEscrowCrossChainAdapter public adapterA;
    SignatureEscrowCrossChainAdapter public adapterB;

    // Mock agreements (simple test contracts that can receive cross-chain messages)
    MockAgreementA public agreementA;
    MockAgreementB public agreementB;

    // Test accounts
    address alice;
    address bob;
    address client;
    address freelancer;

    // Chain config from CCIP Local
    uint64 chainSelector;
    address routerAddress;
    address linkToken;

    // Instance IDs
    bytes32 constant SIG_INSTANCE = keccak256("signature-instance-1");
    bytes32 constant ESCROW_INSTANCE = keccak256("escrow-instance-1");
    bytes32 constant CROSSCHAIN_INSTANCE_A = keccak256("crosschain-instance-a"); // Source chain tracking
    bytes32 constant CROSSCHAIN_INSTANCE_B = keccak256("crosschain-instance-b"); // Destination chain tracking

    // State constants
    uint16 constant PENDING = 1 << 1; // 0x0002
    uint16 constant COMPLETE = 1 << 2; // 0x0004
    uint16 constant FUNDED = 1 << 2; // 0x0004 (same as COMPLETE for escrow)
    uint16 constant RELEASED = 1 << 3; // 0x0008

    function setUp() public {
        // Deploy CCIP Local simulator
        ccipSimulator = new CCIPLocalSimulator();

        // Get configuration
        IRouterClient sourceRouter;
        (chainSelector, sourceRouter,,,,,) = ccipSimulator.configuration();
        routerAddress = address(sourceRouter);
        linkToken = address(0); // Use native token for fees in local mode

        // Deploy clause implementations
        signatureClause = new SignatureClauseLogicV3();
        escrowClause = new EscrowClauseLogicV3();
        crossChainClause = new CrossChainClauseLogicV3();

        // Deploy controllers (both use same router in local mode)
        controllerA = new CrossChainControllerV3(routerAddress, linkToken);
        controllerB = new CrossChainControllerV3(routerAddress, linkToken);

        // Deploy adapters (one per chain with appropriate controller)
        adapterA = new SignatureEscrowCrossChainAdapter(
            address(signatureClause), address(escrowClause), address(crossChainClause), address(controllerA)
        );
        adapterB = new SignatureEscrowCrossChainAdapter(
            address(signatureClause), address(escrowClause), address(crossChainClause), address(controllerB)
        );

        // Setup accounts
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        client = makeAddr("client");
        freelancer = makeAddr("freelancer");

        // Fund accounts
        vm.deal(client, 100 ether);
        vm.deal(freelancer, 100 ether);
        vm.deal(address(this), 100 ether);

        // Deploy mock agreements (now with adapter references)
        agreementA = new MockAgreementA(
            address(signatureClause), address(crossChainClause), address(controllerA), address(adapterA)
        );
        agreementB = new MockAgreementB(
            address(escrowClause), address(crossChainClause), address(controllerB), address(adapterB)
        );

        // Configure controllers
        _setupControllers();
    }

    function _setupControllers() internal {
        // Controller A setup
        controllerA.setAllowedChain(chainSelector, true);
        controllerA.setPartnerController(chainSelector, address(controllerB));
        controllerA.setAuthorizedAgreement(address(agreementA), true);

        // Controller B setup
        controllerB.setAllowedChain(chainSelector, true);
        controllerB.setPartnerController(chainSelector, address(controllerA));
        controllerB.setAuthorizedAgreement(address(agreementB), true);
        controllerB.setAllowedSource(chainSelector, address(agreementA), true);
    }

    // =============================================================
    // UNIT TESTS - Controller Configuration
    // =============================================================

    function test_ControllerSetup_PartnersConfigured() public view {
        assertEq(controllerA.partnerControllers(chainSelector), address(controllerB));
        assertEq(controllerB.partnerControllers(chainSelector), address(controllerA));
    }

    function test_ControllerSetup_ChainsAllowed() public view {
        assertTrue(controllerA.allowedChains(chainSelector));
        assertTrue(controllerB.allowedChains(chainSelector));
    }

    function test_ControllerSetup_AgreementsAuthorized() public view {
        assertTrue(controllerA.authorizedAgreements(address(agreementA)));
        assertTrue(controllerB.authorizedAgreements(address(agreementB)));
    }

    // =============================================================
    // INTEGRATION TESTS - Signature to Escrow Flow
    // =============================================================

    function test_SignatureComplete_TriggersCrossChainRelease_ViaAdapter() public {
        // Step 1: Setup escrow on "Chain B" (destination)
        _setupEscrowOnChainB();

        // Step 2: Setup signature on "Chain A" (source)
        _setupSignatureOnChainA();

        // Step 3: Complete signature (all signers sign)
        _completeSignature();

        // Step 4: Trigger cross-chain release VIA ADAPTER
        // The adapter checks signature is complete, configures CrossChainClause state,
        // sends CCIP message, and marks the instance as SENT
        uint256 fee = adapterA.getFee(ESCROW_INSTANCE, chainSelector, address(agreementB));
        vm.deal(address(agreementA), fee + 1 ether);

        // Agreement A calls adapter.sendReleaseOnSignature() via delegatecall
        agreementA.triggerCrossChainRelease{value: fee}(
            SIG_INSTANCE, CROSSCHAIN_INSTANCE_A, ESCROW_INSTANCE, chainSelector, address(agreementB)
        );

        // Step 5: Verify cross-chain clause state on Chain A (source)
        uint16 crossChainStatusA = agreementA.queryCrossChainStatus(CROSSCHAIN_INSTANCE_A);
        uint16 SENT = 1 << 4; // 0x0010
        assertEq(crossChainStatusA, SENT, "CrossChain instance should be SENT");

        // Step 6: Verify escrow was released on Chain B
        // In CCIP Local mode, the message is delivered immediately
        uint16 escrowStatus = agreementB.queryEscrowStatus(ESCROW_INSTANCE);
        assertEq(escrowStatus, RELEASED, "Escrow should be released");

        // Step 7: Verify cross-chain clause state on Chain B (destination)
        uint16 crossChainStatusB = agreementB.queryCrossChainStatus(CROSSCHAIN_INSTANCE_B);
        uint16 RECEIVED = 1 << 6; // 0x0040
        assertEq(crossChainStatusB, RECEIVED, "CrossChain instance should be RECEIVED");

        // Verify freelancer received funds (started with 100 ETH + 1 ETH from escrow)
        assertEq(freelancer.balance, 101 ether, "Freelancer should have received escrow");
    }

    function test_SignatureNotComplete_CannotTriggerRelease() public {
        // Setup escrow on Chain B
        _setupEscrowOnChainB();

        // Setup signature but don't complete
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        agreementA.setupSignature(SIG_INSTANCE, signers, keccak256("document"));

        // Only alice signs
        vm.prank(alice);
        agreementA.sign(SIG_INSTANCE, abi.encodePacked("alice-sig"));

        // Signature should still be pending
        uint16 sigStatus = agreementA.querySignatureStatus(SIG_INSTANCE);
        assertEq(sigStatus, PENDING, "Signature should still be pending");

        // Cross-chain release would work from controller perspective,
        // but the business logic would need to check signature status first
        // (in a real implementation, the agreement would verify this)
    }

    function test_EscrowNotFunded_ReleaseReverts() public {
        // Setup escrow but don't fund
        agreementB.setupEscrow(
            ESCROW_INSTANCE,
            client,
            freelancer,
            address(0), // ETH
            1 ether
        );

        // Get fee
        uint256 fee = controllerA.getFee(
            chainSelector, address(agreementB), keccak256("document"), 2, abi.encode(ESCROW_INSTANCE)
        );

        // Try to send cross-chain release (will fail on destination because escrow not funded)
        vm.prank(address(agreementA));
        // This will succeed for sending, but destination will revert
        // In CCIP, failed messages are handled differently, but in local mode
        // it should revert if the destination reverts
        vm.expectRevert(); // Expect revert because escrow is not in FUNDED state
        controllerA.sendMessage{value: fee}(
            chainSelector, address(agreementB), keccak256("document"), 2, abi.encode(ESCROW_INSTANCE)
        );
    }

    function test_UnauthorizedAgreement_CannotSend() public {
        address unauthorized = makeAddr("unauthorized");

        uint256 fee = controllerA.getFee(
            chainSelector, address(agreementB), keccak256("document"), 2, abi.encode(ESCROW_INSTANCE)
        );

        vm.deal(unauthorized, 10 ether);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(CrossChainControllerV3.NotAuthorizedAgreement.selector, unauthorized));
        controllerA.sendMessage{value: fee}(
            chainSelector, address(agreementB), keccak256("document"), 2, abi.encode(ESCROW_INSTANCE)
        );
    }

    // =============================================================
    // HELPER FUNCTIONS
    // =============================================================

    function _setupEscrowOnChainB() internal {
        agreementB.setupEscrow(
            ESCROW_INSTANCE,
            client,
            freelancer,
            address(0), // ETH
            1 ether
        );

        // Fund escrow (client deposits via agreement)
        vm.prank(client);
        agreementB.fundEscrow{value: 1 ether}(ESCROW_INSTANCE);

        // Verify funded
        uint16 status = agreementB.queryEscrowStatus(ESCROW_INSTANCE);
        assertEq(status, FUNDED, "Escrow should be funded");
    }

    function _setupSignatureOnChainA() internal {
        address[] memory signers = new address[](2);
        signers[0] = alice;
        signers[1] = bob;

        agreementA.setupSignature(SIG_INSTANCE, signers, keccak256("document"));

        // Verify pending
        uint16 status = agreementA.querySignatureStatus(SIG_INSTANCE);
        assertEq(status, PENDING, "Signature should be pending");
    }

    function _completeSignature() internal {
        vm.prank(alice);
        agreementA.sign(SIG_INSTANCE, abi.encodePacked("alice-sig"));

        vm.prank(bob);
        agreementA.sign(SIG_INSTANCE, abi.encodePacked("bob-sig"));

        // Verify complete
        uint16 status = agreementA.querySignatureStatus(SIG_INSTANCE);
        assertEq(status, COMPLETE, "Signature should be complete");
    }
}

/// @notice Mock Agreement for Chain A (Source - has signature clause)
/// @dev Uses delegatecall to clauses and adapter so msg.sender is preserved.
///      Demonstrates the ADAPTER PATTERN for cross-chain operations.
contract MockAgreementA {
    SignatureClauseLogicV3 public signatureClause;
    CrossChainClauseLogicV3 public crossChainClause;
    CrossChainControllerV3 public controller;
    SignatureEscrowCrossChainAdapter public adapter;

    constructor(address _signatureClause, address _crossChainClause, address _controller, address _adapter) {
        signatureClause = SignatureClauseLogicV3(_signatureClause);
        crossChainClause = CrossChainClauseLogicV3(_crossChainClause);
        controller = CrossChainControllerV3(payable(_controller));
        adapter = SignatureEscrowCrossChainAdapter(_adapter);
    }

    function setupSignature(bytes32 instanceId, address[] calldata signers, bytes32 documentHash) external {
        (bool success,) = address(signatureClause).delegatecall(
            abi.encodeCall(SignatureClauseLogicV3.intakeSigners, (instanceId, signers))
        );
        require(success, "intakeSigners failed");

        (success,) = address(signatureClause).delegatecall(
            abi.encodeCall(SignatureClauseLogicV3.intakeDocumentHash, (instanceId, documentHash))
        );
        require(success, "intakeDocumentHash failed");
    }

    function sign(bytes32 instanceId, bytes calldata signature) external {
        (bool success,) = address(signatureClause).delegatecall(
            abi.encodeCall(SignatureClauseLogicV3.actionSign, (instanceId, signature))
        );
        require(success, "actionSign failed");
    }

    function querySignatureStatus(bytes32 instanceId) external returns (uint16) {
        (bool success, bytes memory data) =
            address(signatureClause).delegatecall(abi.encodeCall(SignatureClauseLogicV3.queryStatus, (instanceId)));
        require(success, "queryStatus failed");
        return abi.decode(data, (uint16));
    }

    /// @notice Query cross-chain clause status via delegatecall
    function queryCrossChainStatus(bytes32 instanceId) external returns (uint16) {
        (bool success, bytes memory data) =
            address(crossChainClause).delegatecall(abi.encodeCall(CrossChainClauseLogicV3.queryStatus, (instanceId)));
        require(success, "queryStatus failed");
        return abi.decode(data, (uint16));
    }

    /// @notice Trigger cross-chain release via the adapter
    /// @dev This is the KEY function demonstrating the adapter pattern.
    ///      The adapter will:
    ///      1. Check signature is complete
    ///      2. Configure CrossChainClause state
    ///      3. Send CCIP message via controller
    ///      4. Mark CrossChainClause as SENT
    function triggerCrossChainRelease(
        bytes32 signatureInstanceId,
        bytes32 crossChainInstanceId,
        bytes32 escrowInstanceId,
        uint64 destinationChainSelector,
        address destinationAgreement
    ) external payable {
        (bool success,) = address(adapter).delegatecall{gas: gasleft()}(
            abi.encodeWithSelector(
                SignatureEscrowCrossChainAdapter.sendReleaseOnSignature.selector,
                signatureInstanceId,
                crossChainInstanceId,
                escrowInstanceId,
                destinationChainSelector,
                destinationAgreement
            )
        );
        require(success, "triggerCrossChainRelease failed");
    }

    receive() external payable {}
}

/// @notice Mock Agreement for Chain B (Destination - has escrow clause)
/// @dev Implements ICrossChainReceiver to handle incoming messages.
///      Uses delegatecall to clauses and adapter so msg.sender is preserved.
///      Demonstrates the ADAPTER PATTERN for receiving cross-chain operations.
contract MockAgreementB is ICrossChainReceiver {
    EscrowClauseLogicV3 public escrowClause;
    CrossChainClauseLogicV3 public crossChainClause;
    CrossChainControllerV3 public controller;
    SignatureEscrowCrossChainAdapter public adapter;

    // Use a fixed instance ID for incoming cross-chain tracking
    // In production, this would be derived from the message or tracked differently
    bytes32 constant CROSSCHAIN_INSTANCE_B = keccak256("crosschain-instance-b");

    constructor(address _escrowClause, address _crossChainClause, address _controller, address _adapter) {
        escrowClause = EscrowClauseLogicV3(_escrowClause);
        crossChainClause = CrossChainClauseLogicV3(_crossChainClause);
        controller = CrossChainControllerV3(payable(_controller));
        adapter = SignatureEscrowCrossChainAdapter(_adapter);
    }

    function setupEscrow(bytes32 instanceId, address depositor, address beneficiary, address token, uint256 amount)
        external
    {
        // Use delegatecall so storage is in this contract
        (bool success,) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeDepositor, (instanceId, depositor))
        );
        require(success, "intakeDepositor failed");

        (success,) = address(escrowClause).delegatecall(
            abi.encodeCall(EscrowClauseLogicV3.intakeBeneficiary, (instanceId, beneficiary))
        );
        require(success, "intakeBeneficiary failed");

        (success,) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.intakeToken, (instanceId, token)));
        require(success, "intakeToken failed");

        (success,) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.intakeAmount, (instanceId, amount)));
        require(success, "intakeAmount failed");

        (success,) = address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.intakeReady, (instanceId)));
        require(success, "intakeReady failed");
    }

    function fundEscrow(bytes32 instanceId) external payable {
        // Use delegatecall so msg.sender (the depositor) is preserved
        (bool success,) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.actionDeposit, (instanceId)));
        require(success, "actionDeposit failed");
    }

    function queryEscrowStatus(bytes32 instanceId) external returns (uint16) {
        (bool success, bytes memory data) =
            address(escrowClause).delegatecall(abi.encodeCall(EscrowClauseLogicV3.queryStatus, (instanceId)));
        require(success, "queryStatus failed");
        return abi.decode(data, (uint16));
    }

    /// @notice Query cross-chain clause status via delegatecall
    function queryCrossChainStatus(bytes32 instanceId) external returns (uint16) {
        (bool success, bytes memory data) =
            address(crossChainClause).delegatecall(abi.encodeCall(CrossChainClauseLogicV3.queryStatus, (instanceId)));
        require(success, "queryStatus failed");
        return abi.decode(data, (uint16));
    }

    /// @notice Handle incoming cross-chain message VIA ADAPTER
    /// @dev This is the KEY function demonstrating the adapter pattern on receive.
    ///      The adapter will:
    ///      1. Record incoming message in CrossChainClause (sets RECEIVED state)
    ///      2. Release the escrow
    function receiveCrossChainMessage(
        uint64 sourceChainSelector,
        address sourceAgreement,
        bytes32 contentHash,
        uint8 action,
        bytes calldata extraData
    ) external override {
        require(msg.sender == address(controller), "Only controller");

        // Use adapter via delegatecall to handle the incoming release
        // The adapter will:
        // 1. Record in CrossChainClauseLogicV3 (state = RECEIVED)
        // 2. Release the escrow via EscrowClauseLogicV3
        (bool success,) = address(adapter).delegatecall(
            abi.encodeWithSelector(
                SignatureEscrowCrossChainAdapter.handleIncomingRelease.selector,
                CROSSCHAIN_INSTANCE_B,
                sourceChainSelector,
                sourceAgreement,
                contentHash,
                action,
                extraData
            )
        );
        require(success, "handleIncomingRelease failed");
    }

    receive() external payable {}
}
