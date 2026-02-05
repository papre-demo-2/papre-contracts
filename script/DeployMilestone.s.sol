// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MilestonePaymentAgreement} from "../src/agreements/MilestonePaymentAgreement.sol";

/**
 * Deploy updated MilestonePaymentAgreement to Fuji Testnet
 *
 * Usage:
 *   forge script script/DeployMilestone.s.sol:DeployMilestone \
 *     --rpc-url $FUJI_RPC_URL \
 *     --private-key $DEPLOYER_PRIVATE_KEY \
 *     --broadcast \
 *     -vvvv
 *
 * This script uses existing clause deployments from previous DeployFuji run.
 */
contract DeployMilestone is Script {
    // Existing clause addresses on Fuji (from 2024-12-30 deployment)
    address constant SIGNATURE_CLAUSE = 0x9A6d4412bf93530aFC96eCC3D8F998D72E977D6E;
    address constant ESCROW_CLAUSE = 0xA9923F79997Ca47A21eD21C95A848fFF3F1490fE;
    address constant MILESTONE_CLAUSE = 0x3D83a056D2a3F6f962c910158A193C93ae872504;
    address constant MILESTONE_ESCROW_ADAPTER = 0xD74F58Ec5AFb9a99c878967a0cf2b851AeD462f1;

    function run() external {
        console2.log("");
        console2.log(
            unicode"╔═══════════════════════════════════════════════════════════════╗"
        );
        console2.log(unicode"║          DEPLOY MILESTONE AGREEMENT TO FUJI                   ║");
        console2.log(
            unicode"╚═══════════════════════════════════════════════════════════════╝"
        );
        console2.log("");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("Deployer:", deployer);
        console2.log("Chain ID: 43113 (Avalanche Fuji)");
        console2.log("");

        console2.log("Using existing clause deployments:");
        console2.log("  SignatureClause:", SIGNATURE_CLAUSE);
        console2.log("  EscrowClause:", ESCROW_CLAUSE);
        console2.log("  MilestoneClause:", MILESTONE_CLAUSE);
        console2.log("  MilestoneEscrowAdapter:", MILESTONE_ESCROW_ADAPTER);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MilestonePaymentAgreement with existing clauses
        console2.log("Deploying MilestonePaymentAgreement...");
        MilestonePaymentAgreement milestoneImpl = new MilestonePaymentAgreement(
            SIGNATURE_CLAUSE,
            ESCROW_CLAUSE,
            MILESTONE_CLAUSE,
            MILESTONE_ESCROW_ADAPTER,
            address(0) // reputationAdapter - optional
        );
        console2.log("MilestonePaymentAgreement:", address(milestoneImpl));

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log(
            unicode"╔═══════════════════════════════════════════════════════════════╗"
        );
        console2.log(unicode"║                    DEPLOYMENT COMPLETE!                       ║");
        console2.log(
            unicode"╚═══════════════════════════════════════════════════════════════╝"
        );
        console2.log("");
        console2.log("Update your .env.local file:");
        console2.log("");
        console2.log("VITE_MILESTONE_PAYMENT_TEMPLATE=%s", address(milestoneImpl));
        console2.log("");
        console2.log("View on Snowtrace:");
        console2.log("  https://testnet.snowtrace.io/address/%s", address(milestoneImpl));
    }
}
