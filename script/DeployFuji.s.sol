// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";

// Clauses
import {SignatureClauseLogicV3} from "../src/clauses/attestation/SignatureClauseLogicV3.sol";
import {EscrowClauseLogicV3} from "../src/clauses/financial/EscrowClauseLogicV3.sol";
import {DeclarativeClauseLogicV3} from "../src/clauses/content/DeclarativeClauseLogicV3.sol";
import {ArbitrationClauseLogicV3} from "../src/clauses/governance/ArbitrationClauseLogicV3.sol";
import {MilestoneClauseLogicV3} from "../src/clauses/orchestration/MilestoneClauseLogicV3.sol";
import {DeadlineClauseLogicV3} from "../src/clauses/state/DeadlineClauseLogicV3.sol";
import {PartyRegistryClauseLogicV3} from "../src/clauses/access/PartyRegistryClauseLogicV3.sol";
import {CrossChainClauseLogicV3} from "../src/clauses/crosschain/CrossChainClauseLogicV3.sol";

// Adapters
import {MilestoneEscrowAdapter} from "../src/adapters/MilestoneEscrowAdapter.sol";
import {DeadlineEnforcementAdapter} from "../src/adapters/DeadlineEnforcementAdapter.sol";

// Agreements
import {FreelanceServiceAgreement} from "../src/agreements/FreelanceServiceAgreement.sol";
import {RetainerAgreement} from "../src/agreements/RetainerAgreement.sol";
import {SubcontractorSafetyNetAgreement} from "../src/agreements/SubcontractorSafetyNetAgreement.sol";
import {MilestonePaymentAgreement} from "../src/agreements/MilestonePaymentAgreement.sol";

// Factory
import {AgreementFactoryV3} from "../src/factories/AgreementFactoryV3.sol";

/**
 * ═══════════════════════════════════════════════════════════════════════════════
 *
 *   Deploy all MVP contracts to Avalanche Fuji Testnet
 *
 *   Prerequisites:
 *     - DEPLOYER_PRIVATE_KEY environment variable set
 *     - FUJI_RPC_URL environment variable set (or use default)
 *
 *   Usage:
 *     forge script script/DeployFuji.s.sol:DeployFuji \
 *       --rpc-url $FUJI_RPC_URL \
 *       --broadcast \
 *       --verify \
 *       -vvvv
 *
 *   Or with private key:
 *     forge script script/DeployFuji.s.sol:DeployFuji \
 *       --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
 *       --private-key $DEPLOYER_PRIVATE_KEY \
 *       --broadcast \
 *       -vvvv
 *
 * ═══════════════════════════════════════════════════════════════════════════════
 */
contract DeployFuji is Script {
    // Deployed clause addresses
    SignatureClauseLogicV3 public signatureClause;
    EscrowClauseLogicV3 public escrowClause;
    DeclarativeClauseLogicV3 public declarativeClause;
    ArbitrationClauseLogicV3 public arbitrationClause;
    MilestoneClauseLogicV3 public milestoneClause;
    DeadlineClauseLogicV3 public deadlineClause;
    PartyRegistryClauseLogicV3 public partyRegistryClause;
    CrossChainClauseLogicV3 public crossChainClause;

    // Deployed adapter addresses
    MilestoneEscrowAdapter public milestoneAdapter;
    DeadlineEnforcementAdapter public deadlineAdapter;

    // Deployed agreement implementations
    FreelanceServiceAgreement public freelanceServiceImpl;
    RetainerAgreement public retainerImpl;
    SubcontractorSafetyNetAgreement public safetyNetImpl;
    MilestonePaymentAgreement public milestonePaymentImpl;

    // Factory
    AgreementFactoryV3 public factory;

    // Template type IDs
    bytes32 constant FREELANCE_TYPE = keccak256("freelance");
    bytes32 constant MILESTONE_TYPE = keccak256("milestone");
    bytes32 constant RETAINER_TYPE = keccak256("retainer");
    bytes32 constant SAFETY_NET_TYPE = keccak256("safety-net");

    function run() external {
        console2.log("");
        console2.log(unicode"╔═══════════════════════════════════════════════════════════════╗");
        console2.log(unicode"║          DEPLOY PAPRE MVP CONTRACTS TO FUJI TESTNET           ║");
        console2.log(unicode"╚═══════════════════════════════════════════════════════════════╝");
        console2.log("");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deployer:", deployer);
        console2.log("Chain ID: 43113 (Avalanche Fuji)");
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // =============================================================
        // 1. Deploy Clause Logic Contracts (shared singletons)
        // =============================================================

        console2.log(unicode"┌─────────────────────────────────────────────────────────────────┐");
        console2.log(unicode"│              1. DEPLOYING CLAUSE LOGIC CONTRACTS                │");
        console2.log(unicode"└─────────────────────────────────────────────────────────────────┘");

        signatureClause = new SignatureClauseLogicV3();
        console2.log("SignatureClauseLogicV3:", address(signatureClause));

        escrowClause = new EscrowClauseLogicV3();
        console2.log("EscrowClauseLogicV3:", address(escrowClause));

        declarativeClause = new DeclarativeClauseLogicV3();
        console2.log("DeclarativeClauseLogicV3:", address(declarativeClause));

        arbitrationClause = new ArbitrationClauseLogicV3();
        console2.log("ArbitrationClauseLogicV3:", address(arbitrationClause));

        milestoneClause = new MilestoneClauseLogicV3();
        console2.log("MilestoneClauseLogicV3:", address(milestoneClause));

        deadlineClause = new DeadlineClauseLogicV3();
        console2.log("DeadlineClauseLogicV3:", address(deadlineClause));

        partyRegistryClause = new PartyRegistryClauseLogicV3();
        console2.log("PartyRegistryClauseLogicV3:", address(partyRegistryClause));

        crossChainClause = new CrossChainClauseLogicV3();
        console2.log("CrossChainClauseLogicV3:", address(crossChainClause));

        console2.log("");

        // =============================================================
        // 2. Deploy Adapters
        // =============================================================

        console2.log(unicode"┌─────────────────────────────────────────────────────────────────┐");
        console2.log(unicode"│                      2. DEPLOYING ADAPTERS                      │");
        console2.log(unicode"└─────────────────────────────────────────────────────────────────┘");

        milestoneAdapter = new MilestoneEscrowAdapter(address(milestoneClause), address(escrowClause));
        console2.log("MilestoneEscrowAdapter:", address(milestoneAdapter));

        deadlineAdapter =
            new DeadlineEnforcementAdapter(address(deadlineClause), address(milestoneClause), address(escrowClause));
        console2.log("DeadlineEnforcementAdapter:", address(deadlineAdapter));

        console2.log("");

        // =============================================================
        // 3. Deploy Agreement Implementations
        // =============================================================

        console2.log(unicode"┌─────────────────────────────────────────────────────────────────┐");
        console2.log(unicode"│               3. DEPLOYING AGREEMENT IMPLEMENTATIONS            │");
        console2.log(unicode"└─────────────────────────────────────────────────────────────────┘");

        freelanceServiceImpl =
            new FreelanceServiceAgreement(address(signatureClause), address(escrowClause), address(declarativeClause));
        console2.log("FreelanceServiceAgreement:", address(freelanceServiceImpl));

        retainerImpl = new RetainerAgreement(address(signatureClause), address(escrowClause));
        console2.log("RetainerAgreement:", address(retainerImpl));

        safetyNetImpl = new SubcontractorSafetyNetAgreement(
            address(signatureClause), address(escrowClause), address(arbitrationClause)
        );
        console2.log("SubcontractorSafetyNetAgreement:", address(safetyNetImpl));

        milestonePaymentImpl = new MilestonePaymentAgreement(
            address(signatureClause), address(escrowClause), address(milestoneClause), address(milestoneAdapter)
        );
        console2.log("MilestonePaymentAgreement:", address(milestonePaymentImpl));

        console2.log("");

        // =============================================================
        // 4. Deploy Factory
        // =============================================================

        console2.log(unicode"┌─────────────────────────────────────────────────────────────────┐");
        console2.log(unicode"│                       4. DEPLOYING FACTORY                      │");
        console2.log(unicode"└─────────────────────────────────────────────────────────────────┘");

        factory = new AgreementFactoryV3(deployer);
        console2.log("AgreementFactoryV3:", address(factory));

        console2.log("");

        // =============================================================
        // 5. Register Templates
        // =============================================================

        console2.log(unicode"┌─────────────────────────────────────────────────────────────────┐");
        console2.log(unicode"│                    5. REGISTERING TEMPLATES                     │");
        console2.log(unicode"└─────────────────────────────────────────────────────────────────┘");

        factory.registerTemplate(FREELANCE_TYPE, "Freelance Service Agreement", address(freelanceServiceImpl));
        console2.log("Registered: freelance ->", address(freelanceServiceImpl));

        factory.registerTemplate(RETAINER_TYPE, "Retainer Agreement", address(retainerImpl));
        console2.log("Registered: retainer ->", address(retainerImpl));

        factory.registerTemplate(SAFETY_NET_TYPE, "Subcontractor Safety Net", address(safetyNetImpl));
        console2.log("Registered: safety-net ->", address(safetyNetImpl));

        factory.registerTemplate(MILESTONE_TYPE, "Milestone Payment Agreement", address(milestonePaymentImpl));
        console2.log("Registered: milestone ->", address(milestonePaymentImpl));

        vm.stopBroadcast();

        // =============================================================
        // Summary
        // =============================================================

        console2.log("");
        console2.log(unicode"╔═══════════════════════════════════════════════════════════════╗");
        console2.log(unicode"║                    DEPLOYMENT COMPLETE!                       ║");
        console2.log(unicode"╚═══════════════════════════════════════════════════════════════╝");
        console2.log("");

        console2.log("Add to your .env.local file:");
        console2.log("");
        console2.log("# Clauses");
        console2.log("VITE_SIGNATURE_CLAUSE=%s", address(signatureClause));
        console2.log("VITE_ESCROW_CLAUSE=%s", address(escrowClause));
        console2.log("VITE_DECLARATIVE_CLAUSE=%s", address(declarativeClause));
        console2.log("VITE_ARBITRATION_CLAUSE=%s", address(arbitrationClause));
        console2.log("VITE_MILESTONE_CLAUSE=%s", address(milestoneClause));
        console2.log("VITE_DEADLINE_CLAUSE=%s", address(deadlineClause));
        console2.log("VITE_PARTY_REGISTRY_CLAUSE=%s", address(partyRegistryClause));
        console2.log("VITE_CROSS_CHAIN_CLAUSE=%s", address(crossChainClause));
        console2.log("");
        console2.log("# Adapters");
        console2.log("VITE_MILESTONE_ESCROW_ADAPTER=%s", address(milestoneAdapter));
        console2.log("VITE_DEADLINE_ENFORCEMENT_ADAPTER=%s", address(deadlineAdapter));
        console2.log("");
        console2.log("# Templates (Agreement Implementations)");
        console2.log("VITE_FREELANCE_SERVICE_TEMPLATE=%s", address(freelanceServiceImpl));
        console2.log("VITE_RETAINER_TEMPLATE=%s", address(retainerImpl));
        console2.log("VITE_SAFETY_NET_TEMPLATE=%s", address(safetyNetImpl));
        console2.log("VITE_MILESTONE_PAYMENT_TEMPLATE=%s", address(milestonePaymentImpl));
        console2.log("");
        console2.log("# Factory");
        console2.log("VITE_FACTORY_ADDRESS=%s", address(factory));
        console2.log("");
        console2.log("View on Snowtrace:");
        console2.log("  https://testnet.snowtrace.io/address/%s", address(factory));
        console2.log("");
        console2.log("Template Type IDs:");
        console2.log("  freelance:  0x%s", vm.toString(FREELANCE_TYPE));
        console2.log("  retainer:   0x%s", vm.toString(RETAINER_TYPE));
        console2.log("  safety-net: 0x%s", vm.toString(SAFETY_NET_TYPE));
        console2.log("  milestone:  0x%s", vm.toString(MILESTONE_TYPE));
    }
}
