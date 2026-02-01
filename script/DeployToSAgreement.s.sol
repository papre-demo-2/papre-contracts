// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TermsOfServiceAgreement} from "../src/agreements/TermsOfServiceAgreement.sol";

/**
 * @title DeployToSAgreement
 * @notice Deploy TermsOfServiceAgreement using EXISTING clause addresses
 * @dev This script deploys the dedicated ToS acceptance contract
 *
 * Prerequisites:
 *   - DEPLOYER_PRIVATE_KEY environment variable set
 *   - SIGNATURE_CLAUSE_ADDRESS environment variable set (existing deployed clause)
 *   - DECLARATIVE_CLAUSE_ADDRESS environment variable set (existing deployed clause)
 *
 * Usage:
 *   forge script script/DeployToSAgreement.s.sol:DeployToSAgreement \
 *     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
 *     --broadcast \
 *     -vvvv
 *
 * Example with all env vars:
 *   DEPLOYER_PRIVATE_KEY=0x... \
 *   SIGNATURE_CLAUSE_ADDRESS=0x9A6d4412bf93530aFC96eCC3D8F998D72E977D6E \
 *   DECLARATIVE_CLAUSE_ADDRESS=0xDfBEc9772904b74436DFDf79ee5701BCB2135dF7 \
 *   forge script script/DeployToSAgreement.s.sol:DeployToSAgreement \
 *     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
 *     --broadcast
 */
contract DeployToSAgreement is Script {
    function run() external {
        // Get deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Get EXISTING clause addresses (required)
        address signatureClause = vm.envAddress("SIGNATURE_CLAUSE_ADDRESS");
        address declarativeClause = vm.envAddress("DECLARATIVE_CLAUSE_ADDRESS");

        console2.log("=== Deploying TermsOfServiceAgreement ===");
        console2.log("Using existing SignatureClauseLogicV3:", signatureClause);
        console2.log("Using existing DeclarativeClauseLogicV3:", declarativeClause);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy TermsOfServiceAgreement with existing clause addresses
        TermsOfServiceAgreement agreement = new TermsOfServiceAgreement(declarativeClause, signatureClause);
        console2.log("TermsOfServiceAgreement deployed at:", address(agreement));

        vm.stopBroadcast();

        // Output deployment info
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("Network: Avalanche Fuji Testnet");
        console2.log("TermsOfServiceAgreement:", address(agreement));
        console2.log("");
        console2.log("Add to papre-app/.env.local:");
        console2.log("VITE_TOS_AGREEMENT_ADDRESS=", address(agreement));
    }
}
