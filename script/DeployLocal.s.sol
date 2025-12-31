// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

// Clauses
import {SignatureClauseLogicV3} from "../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../src/clauses/financial/EscrowClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../src/clauses/content/DeclarativeClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../src/clauses/orchestration/MilestoneClauseLogicV3.sol";
import {MilestoneEscrowAdapter} from "../src/adapters/MilestoneEscrowAdapter.sol";

// Agreements
import {FreelanceServiceAgreement} from "../src/agreements/FreelanceServiceAgreement.sol";
import {MilestonePaymentAgreement} from "../src/agreements/MilestonePaymentAgreement.sol";

// Factory
import {AgreementFactoryV3} from "../src/factories/AgreementFactoryV3.sol";

/// @title DeployLocal
/// @notice Deploy all MVP contracts to Anvil for local testing
/// @dev Run with: forge script script/DeployLocal.s.sol --rpc-url http://localhost:8545 --broadcast
contract DeployLocal is Script {

    // Deployed addresses
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    DeclarativeClauseLogicV3 public declarativeClause;
    MilestoneClauseLogicV3 public milestoneClause;
    MilestoneEscrowAdapter public milestoneAdapter;
    FreelanceServiceAgreement public freelanceServiceImpl;
    MilestonePaymentAgreement public milestonePaymentImpl;
    AgreementFactoryV3 public factory;

    // Template type IDs
    bytes32 constant FREELANCE_TYPE = keccak256("freelance");
    bytes32 constant MILESTONE_TYPE = keccak256("milestone");
    bytes32 constant RETAINER_TYPE = keccak256("retainer");
    bytes32 constant SAFETY_NET_TYPE = keccak256("safety-net");

    function run() external {
        // Use Anvil's first default private key if not set
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deploying from:", deployer);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // =============================================================
        // 1. Deploy Clause Logic Contracts (shared singletons)
        // =============================================================

        console2.log("=== Deploying Clause Logic Contracts ===");

        signatureClause = new SignatureClauseLogicV3();
        console2.log("SignatureClauseLogicV3:", address(signatureClause));

        escrowClause = new EscrowClauseLogicV3();
        console2.log("EscrowClauseLogicV3:", address(escrowClause));

        declarativeClause = new DeclarativeClauseLogicV3();
        console2.log("DeclarativeClauseLogicV3:", address(declarativeClause));

        milestoneClause = new MilestoneClauseLogicV3();
        console2.log("MilestoneClauseLogicV3:", address(milestoneClause));

        milestoneAdapter = new MilestoneEscrowAdapter(
            address(milestoneClause),
            address(escrowClause)
        );
        console2.log("MilestoneEscrowAdapter:", address(milestoneAdapter));

        console2.log("");

        // =============================================================
        // 2. Deploy Agreement Implementation
        // =============================================================

        console2.log("=== Deploying Agreement Implementations ===");

        freelanceServiceImpl = new FreelanceServiceAgreement(
            address(signatureClause),
            address(escrowClause),
            address(declarativeClause)
        );
        console2.log("FreelanceServiceAgreement:", address(freelanceServiceImpl));

        milestonePaymentImpl = new MilestonePaymentAgreement(
            address(signatureClause),
            address(escrowClause),
            address(milestoneClause),
            address(milestoneAdapter)
        );
        console2.log("MilestonePaymentAgreement:", address(milestonePaymentImpl));

        console2.log("");

        // =============================================================
        // 3. Deploy Factory
        // =============================================================

        console2.log("=== Deploying Factory ===");

        factory = new AgreementFactoryV3(deployer);
        console2.log("AgreementFactoryV3:", address(factory));

        console2.log("");

        // =============================================================
        // 4. Register Templates
        // =============================================================

        console2.log("=== Registering Templates ===");

        factory.registerTemplate(FREELANCE_TYPE, "Freelance Service Agreement", address(freelanceServiceImpl));
        console2.log("Registered: freelance -> ", address(freelanceServiceImpl));

        factory.registerTemplate(MILESTONE_TYPE, "Milestone Payment Agreement", address(milestonePaymentImpl));
        console2.log("Registered: milestone -> ", address(milestonePaymentImpl));

        // For MVP, register placeholder for other template types
        // (They'll use the same implementation for now, just to show factory works)
        // In production, each would have its own implementation
        factory.registerTemplate(RETAINER_TYPE, "Retainer Agreement", address(freelanceServiceImpl));
        console2.log("Registered: retainer (placeholder)");

        factory.registerTemplate(SAFETY_NET_TYPE, "Subcontractor Safety Net", address(freelanceServiceImpl));
        console2.log("Registered: safety-net (placeholder)");

        vm.stopBroadcast();

        // =============================================================
        // Summary
        // =============================================================

        console2.log("");
        console2.log("=== DEPLOYMENT SUMMARY ===");
        console2.log("");
        console2.log("Update packages/demo-v3/src/lib/contracts.ts with:");
        console2.log("");
        console2.log("export const DEPLOYED_ADDRESSES: DeployedAddresses = {");
        console2.log("  factory: '%s',", address(factory));
        console2.log("  clauses: {");
        console2.log("    signature: '%s',", address(signatureClause));
        console2.log("    escrow: '%s',", address(escrowClause));
        console2.log("    declarative: '%s',", address(declarativeClause));
        console2.log("    milestone: '%s',", address(milestoneClause));
        console2.log("    milestoneAdapter: '%s',", address(milestoneAdapter));
        console2.log("  },");
        console2.log("  templates: {");
        console2.log("    freelanceService: '%s',", address(freelanceServiceImpl));
        console2.log("    milestonePayment: '%s',", address(milestonePaymentImpl));
        console2.log("  },");
        console2.log("};");
        console2.log("");
        console2.log("Type IDs for frontend templates.ts:");
        console2.log("  freelance: 0x%s", vm.toString(FREELANCE_TYPE));
        console2.log("  milestone: 0x%s", vm.toString(MILESTONE_TYPE));
        console2.log("  retainer: 0x%s", vm.toString(RETAINER_TYPE));
        console2.log("  safety-net: 0x%s", vm.toString(SAFETY_NET_TYPE));
    }
}
