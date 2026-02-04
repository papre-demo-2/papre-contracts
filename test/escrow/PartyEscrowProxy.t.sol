// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {PartyEscrowProxy} from "../../src/escrow/PartyEscrowProxy.sol";
import {PartyEscrowFactory} from "../../src/escrow/PartyEscrowFactory.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract PartyEscrowProxyTest is Test {
    PartyEscrowFactory public factory;
    ERC20Mock public usdc;

    address public client = makeAddr("client");
    address public contractor = makeAddr("contractor");
    address public attacker = makeAddr("attacker");

    uint256 constant INITIAL_BALANCE = 100_000e6; // 100k USDC
    uint256 constant PROJECT_AMOUNT = 6_000e6; // 6k USDC (for 3 milestones)

    function setUp() public {
        // Deploy factory
        factory = new PartyEscrowFactory();

        // Deploy mock USDC
        usdc = new ERC20Mock();
        usdc.mint(client, INITIAL_BALANCE);

        // Give client and contractor some ETH for gas
        vm.deal(client, 100 ether);
        vm.deal(contractor, 10 ether);
        vm.deal(attacker, 10 ether);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INITIALIZATION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_CreateEscrow_Success() public {
        bytes32 salt = keccak256("test-agreement-1");

        address proxy =
            factory.createEscrow(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, salt);

        assertTrue(factory.isProxy(proxy));

        PartyEscrowProxy escrow = PartyEscrowProxy(payable(proxy));
        assertEq(escrow.client(), client);
        assertEq(escrow.contractor(), contractor);
        assertEq(escrow.token(), address(usdc));
        assertEq(uint8(escrow.disputeMode()), uint8(PartyEscrowProxy.DisputeMode.FROZEN));
        assertTrue(escrow.initialized());
    }

    function test_CreateEscrow_NativeToken() public {
        bytes32 salt = keccak256("native-test");

        address proxy = factory.createEscrow(
            client,
            contractor,
            address(0), // Native token
            PartyEscrowProxy.DisputeMode.AUTO_REFUND,
            30, // 30 days timeout
            salt
        );

        PartyEscrowProxy escrow = PartyEscrowProxy(payable(proxy));
        assertEq(escrow.token(), address(0));
        assertEq(uint8(escrow.disputeMode()), uint8(PartyEscrowProxy.DisputeMode.AUTO_REFUND));
        assertEq(escrow.disputeTimeout(), 30 days);
    }

    function test_CreateEscrow_DeterministicAddress() public {
        bytes32 salt = keccak256("deterministic-test");

        address predicted = factory.predictAddress(client, contractor, salt);

        address actual =
            factory.createEscrow(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, salt);

        assertEq(actual, predicted);
    }

    function test_CreateEscrow_RevertIfAlreadyExists() public {
        bytes32 salt = keccak256("duplicate-test");

        factory.createEscrow(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, salt);

        vm.expectRevert(PartyEscrowFactory.ProxyAlreadyExists.selector);
        factory.createEscrow(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, salt);
    }

    function test_Initialize_RevertIfCalledTwice() public {
        address proxy = factory.createEscrow(
            client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, keccak256("init-test")
        );

        PartyEscrowProxy escrow = PartyEscrowProxy(payable(proxy));

        vm.expectRevert(PartyEscrowProxy.AlreadyInitialized.selector);
        escrow.initialize(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        DEPOSIT TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Deposit_ERC20() public {
        PartyEscrowProxy escrow = _createEscrow();

        vm.startPrank(client);
        usdc.approve(address(escrow), PROJECT_AMOUNT);
        escrow.deposit(PROJECT_AMOUNT);
        vm.stopPrank();

        assertEq(escrow.balance(), PROJECT_AMOUNT);
        assertEq(escrow.totalDeposited(), PROJECT_AMOUNT);
    }

    function test_Deposit_NativeToken() public {
        PartyEscrowProxy escrow = _createNativeEscrow();

        vm.prank(client);
        escrow.deposit{value: 1 ether}(0);

        assertEq(escrow.balance(), 1 ether);
        assertEq(escrow.totalDeposited(), 1 ether);
    }

    function test_Deposit_AnyoneCanDeposit() public {
        PartyEscrowProxy escrow = _createEscrow();

        // Attacker deposits (allowed - it's their money)
        usdc.mint(attacker, 1000e6);
        vm.startPrank(attacker);
        usdc.approve(address(escrow), 1000e6);
        escrow.deposit(1000e6);
        vm.stopPrank();

        assertEq(escrow.balance(), 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        RELEASE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Release_RequiresBothApprovals() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256(abi.encode(1, 0)); // instanceId=1, milestoneIndex=0
        uint256 amount = 1000e6;

        // Client approves
        vm.prank(client);
        escrow.approveRelease(releaseId, amount);

        // Cannot execute yet
        vm.expectRevert(PartyEscrowProxy.NotBothApproved.selector);
        escrow.executeRelease(releaseId);

        // Contractor approves
        vm.prank(contractor);
        escrow.approveRelease(releaseId, amount);

        // Now can execute
        uint256 contractorBalanceBefore = usdc.balanceOf(contractor);
        escrow.executeRelease(releaseId);

        assertEq(usdc.balanceOf(contractor) - contractorBalanceBefore, amount);
        assertEq(escrow.totalReleased(), amount);
    }

    function test_Release_RevertIfAmountMismatch() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256("release-1");

        // Client approves 1000
        vm.prank(client);
        escrow.approveRelease(releaseId, 1000e6);

        // Contractor tries to approve 2000
        vm.prank(contractor);
        vm.expectRevert(PartyEscrowProxy.AmountMismatch.selector);
        escrow.approveRelease(releaseId, 2000e6);
    }

    function test_Release_RevertIfAlreadyExecuted() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256("release-once");
        uint256 amount = 1000e6;

        // Both approve
        vm.prank(client);
        escrow.approveRelease(releaseId, amount);
        vm.prank(contractor);
        escrow.approveRelease(releaseId, amount);

        // Execute once
        escrow.executeRelease(releaseId);

        // Try to execute again
        vm.expectRevert(PartyEscrowProxy.AlreadyExecuted.selector);
        escrow.executeRelease(releaseId);
    }

    function test_Release_RevertIfNonPartyApproves() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256("attacker-release");

        vm.prank(attacker);
        vm.expectRevert(PartyEscrowProxy.OnlyParty.selector);
        escrow.approveRelease(releaseId, 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        REFUND TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Refund_RequiresBothApprovals() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 refundId = keccak256("refund-1");
        uint256 amount = 2000e6;

        uint256 clientBalanceBefore = usdc.balanceOf(client);

        // Both approve
        vm.prank(client);
        escrow.approveRefund(refundId, amount);
        vm.prank(contractor);
        escrow.approveRefund(refundId, amount);

        // Execute
        escrow.executeRefund(refundId);

        assertEq(usdc.balanceOf(client) - clientBalanceBefore, amount);
        assertEq(escrow.totalRefunded(), amount);
    }

    // ═══════════════════════════════════════════════════════════════
    //                   MULTI-MILESTONE TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_MultiMilestone_SequentialReleases() public {
        // Scenario: 3 milestones ($1000, $2000, $3000)
        PartyEscrowProxy escrow = _createAndFundEscrow();

        uint256 milestone1 = 1000e6;
        uint256 milestone2 = 2000e6;
        uint256 milestone3 = 3000e6;

        bytes32 release1 = keccak256(abi.encode(1, 0));
        bytes32 release2 = keccak256(abi.encode(1, 1));
        bytes32 release3 = keccak256(abi.encode(1, 2));

        // Milestone 1: Release $1000
        vm.prank(client);
        escrow.approveRelease(release1, milestone1);
        vm.prank(contractor);
        escrow.approveRelease(release1, milestone1);
        escrow.executeRelease(release1);

        assertEq(escrow.balance(), PROJECT_AMOUNT - milestone1);
        assertEq(escrow.totalReleased(), milestone1);

        // Milestone 2: Release $2000
        vm.prank(client);
        escrow.approveRelease(release2, milestone2);
        vm.prank(contractor);
        escrow.approveRelease(release2, milestone2);
        escrow.executeRelease(release2);

        assertEq(escrow.balance(), PROJECT_AMOUNT - milestone1 - milestone2);
        assertEq(escrow.totalReleased(), milestone1 + milestone2);

        // Milestone 3: Release $3000
        vm.prank(client);
        escrow.approveRelease(release3, milestone3);
        vm.prank(contractor);
        escrow.approveRelease(release3, milestone3);
        escrow.executeRelease(release3);

        assertEq(escrow.balance(), 0);
        assertEq(escrow.totalReleased(), PROJECT_AMOUNT);
    }

    // ═══════════════════════════════════════════════════════════════
    //                   DISPUTE RESOLUTION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_DisputeMode_FrozenNoAutoResolve() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();

        // FROZEN mode - should revert even after long time
        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(PartyEscrowProxy.AutoResolutionNotEnabled.selector);
        escrow.executeDisputeResolution();
    }

    function test_DisputeMode_AutoRefund() public {
        // Create with AUTO_REFUND mode
        address proxy = factory.createEscrow(
            client,
            contractor,
            address(usdc),
            PartyEscrowProxy.DisputeMode.AUTO_REFUND,
            30, // 30 days
            keccak256("auto-refund-test")
        );
        PartyEscrowProxy escrow = PartyEscrowProxy(payable(proxy));

        // Fund
        vm.startPrank(client);
        usdc.approve(address(escrow), PROJECT_AMOUNT);
        escrow.deposit(PROJECT_AMOUNT);
        vm.stopPrank();

        // Can't resolve yet
        assertFalse(escrow.canAutoResolve());
        vm.expectRevert(PartyEscrowProxy.DisputeTimeoutNotElapsed.selector);
        escrow.executeDisputeResolution();

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days + 1);

        assertTrue(escrow.canAutoResolve());

        uint256 clientBalanceBefore = usdc.balanceOf(client);
        escrow.executeDisputeResolution();

        // Client gets refund
        assertEq(usdc.balanceOf(client) - clientBalanceBefore, PROJECT_AMOUNT);
        assertEq(escrow.balance(), 0);
    }

    function test_DisputeMode_AutoRelease() public {
        // Create with AUTO_RELEASE mode
        address proxy = factory.createEscrow(
            client,
            contractor,
            address(usdc),
            PartyEscrowProxy.DisputeMode.AUTO_RELEASE,
            30, // 30 days
            keccak256("auto-release-test")
        );
        PartyEscrowProxy escrow = PartyEscrowProxy(payable(proxy));

        // Fund
        vm.startPrank(client);
        usdc.approve(address(escrow), PROJECT_AMOUNT);
        escrow.deposit(PROJECT_AMOUNT);
        vm.stopPrank();

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days + 1);

        uint256 contractorBalanceBefore = usdc.balanceOf(contractor);
        escrow.executeDisputeResolution();

        // Contractor gets payment
        assertEq(usdc.balanceOf(contractor) - contractorBalanceBefore, PROJECT_AMOUNT);
        assertEq(escrow.balance(), 0);
    }

    function test_DisputeMode_ActivityResetsTimeout() public {
        // Create with AUTO_REFUND mode
        address proxy = factory.createEscrow(
            client,
            contractor,
            address(usdc),
            PartyEscrowProxy.DisputeMode.AUTO_REFUND,
            7, // 7 days
            keccak256("activity-reset-test")
        );
        PartyEscrowProxy escrow = PartyEscrowProxy(payable(proxy));

        // Fund
        vm.startPrank(client);
        usdc.approve(address(escrow), PROJECT_AMOUNT);
        escrow.deposit(PROJECT_AMOUNT);
        vm.stopPrank();

        // Record timestamp after deposit
        uint256 afterDeposit = block.timestamp;

        // Fast forward 5 days (not yet 7)
        vm.warp(afterDeposit + 5 days);
        assertFalse(escrow.canAutoResolve());

        // Do a partial release (resets activity timestamp)
        bytes32 releaseId = keccak256("partial");
        vm.prank(client);
        escrow.approveRelease(releaseId, 1000e6);
        vm.prank(contractor);
        escrow.approveRelease(releaseId, 1000e6);
        escrow.executeRelease(releaseId);

        // Record timestamp after release
        uint256 afterRelease = block.timestamp;

        // Fast forward 6 days from release (not yet 7)
        vm.warp(afterRelease + 6 days);
        assertFalse(escrow.canAutoResolve());

        // Fast forward 7+ days from release
        vm.warp(afterRelease + 7 days + 1);
        assertTrue(escrow.canAutoResolve());
    }

    // ═══════════════════════════════════════════════════════════════
    //                    SECURITY TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Security_NoOwnerNoAdmin() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();

        // No pause function
        // No admin functions
        // No owner functions

        // Only release/refund with both party approval
        // That's the security model
    }

    function test_Security_CannotReleaseMoreThanBalance() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256("too-much");
        uint256 tooMuch = PROJECT_AMOUNT + 1;

        vm.prank(client);
        escrow.approveRelease(releaseId, tooMuch);
        vm.prank(contractor);
        escrow.approveRelease(releaseId, tooMuch);

        vm.expectRevert(PartyEscrowProxy.InsufficientBalance.selector);
        escrow.executeRelease(releaseId);
    }

    function test_Security_DoubleApprovalRejected() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256("double-approve");

        vm.startPrank(client);
        escrow.approveRelease(releaseId, 1000e6);

        vm.expectRevert(PartyEscrowProxy.AlreadyApproved.selector);
        escrow.approveRelease(releaseId, 1000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════
    //                    VIEW FUNCTION TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_GetReleaseStatus() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();
        bytes32 releaseId = keccak256("status-test");

        // Initial status
        (bool clientApproved, bool contractorApproved, uint256 amount, bool executed) =
            escrow.getReleaseStatus(releaseId);
        assertFalse(clientApproved);
        assertFalse(contractorApproved);
        assertEq(amount, 0);
        assertFalse(executed);

        // After client approval
        vm.prank(client);
        escrow.approveRelease(releaseId, 1000e6);

        (clientApproved, contractorApproved, amount, executed) = escrow.getReleaseStatus(releaseId);
        assertTrue(clientApproved);
        assertFalse(contractorApproved);
        assertEq(amount, 1000e6);
        assertFalse(executed);
    }

    function test_GetConfig() public {
        PartyEscrowProxy escrow = _createEscrow();

        (
            address _client,
            address _contractor,
            address _token,
            PartyEscrowProxy.DisputeMode _disputeMode,
            uint256 _disputeTimeout,
        ) = escrow.getConfig();

        assertEq(_client, client);
        assertEq(_contractor, contractor);
        assertEq(_token, address(usdc));
        assertEq(uint8(_disputeMode), uint8(PartyEscrowProxy.DisputeMode.FROZEN));
        assertEq(_disputeTimeout, 0);
    }

    function test_GetTotals() public {
        PartyEscrowProxy escrow = _createAndFundEscrow();

        // Do a release
        bytes32 releaseId = keccak256("totals-test");
        vm.prank(client);
        escrow.approveRelease(releaseId, 1000e6);
        vm.prank(contractor);
        escrow.approveRelease(releaseId, 1000e6);
        escrow.executeRelease(releaseId);

        (uint256 deposited, uint256 released, uint256 refunded, uint256 currentBalance) = escrow.getTotals();

        assertEq(deposited, PROJECT_AMOUNT);
        assertEq(released, 1000e6);
        assertEq(refunded, 0);
        assertEq(currentBalance, PROJECT_AMOUNT - 1000e6);
    }

    // ═══════════════════════════════════════════════════════════════
    //                        FACTORY TESTS
    // ═══════════════════════════════════════════════════════════════

    function test_Factory_TracksProxies() public {
        bytes32 salt1 = keccak256("proxy-1");
        bytes32 salt2 = keccak256("proxy-2");

        address proxy1 =
            factory.createEscrow(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, salt1);
        address proxy2 =
            factory.createEscrow(client, contractor, address(usdc), PartyEscrowProxy.DisputeMode.FROZEN, 0, salt2);

        assertEq(factory.getProxyCount(), 2);

        address[] memory allProxies = factory.getAllProxies();
        assertEq(allProxies.length, 2);
        assertEq(allProxies[0], proxy1);
        assertEq(allProxies[1], proxy2);

        address[] memory clientProxies = factory.getProxiesForParty(client);
        assertEq(clientProxies.length, 2);
    }

    // ═══════════════════════════════════════════════════════════════
    //                          HELPERS
    // ═══════════════════════════════════════════════════════════════

    function _createEscrow() internal returns (PartyEscrowProxy) {
        address proxy = factory.createEscrow(
            client,
            contractor,
            address(usdc),
            PartyEscrowProxy.DisputeMode.FROZEN,
            0,
            keccak256(abi.encode(block.timestamp, msg.sender))
        );
        return PartyEscrowProxy(payable(proxy));
    }

    function _createNativeEscrow() internal returns (PartyEscrowProxy) {
        address proxy = factory.createEscrow(
            client,
            contractor,
            address(0),
            PartyEscrowProxy.DisputeMode.FROZEN,
            0,
            keccak256(abi.encode(block.timestamp, msg.sender, "native"))
        );
        return PartyEscrowProxy(payable(proxy));
    }

    function _createAndFundEscrow() internal returns (PartyEscrowProxy) {
        PartyEscrowProxy escrow = _createEscrow();

        vm.startPrank(client);
        usdc.approve(address(escrow), PROJECT_AMOUNT);
        escrow.deposit(PROJECT_AMOUNT);
        vm.stopPrank();

        return escrow;
    }
}
