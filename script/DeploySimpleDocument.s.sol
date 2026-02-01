// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SimpleDocumentAgreement} from "../src/agreements/SimpleDocumentAgreement.sol";

/**
 * @title DeploySimpleDocument
 * @notice Deploy SimpleDocumentAgreement using EXISTING clause addresses
 * @dev This script does NOT deploy new clauses - it reuses existing ones!
 *
 * Prerequisites:
 *   - DEPLOYER_PRIVATE_KEY environment variable set
 *   - SIGNATURE_CLAUSE_ADDRESS environment variable set (existing deployed clause)
 *   - DECLARATIVE_CLAUSE_ADDRESS environment variable set (existing deployed clause)
 *   - Optional: TRUSTED_ATTESTOR environment variable for email-based signing
 *
 * Usage:
 *   forge script script/DeploySimpleDocument.s.sol:DeploySimpleDocument \
 *     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
 *     --broadcast \
 *     -vvvv
 *
 * Example with all env vars:
 *   DEPLOYER_PRIVATE_KEY=0x... \
 *   SIGNATURE_CLAUSE_ADDRESS=0x9A6d4412bf93530aFC96eCC3D8F998D72E977D6E \
 *   DECLARATIVE_CLAUSE_ADDRESS=0xDfBEc9772904b74436DFDf79ee5701BCB2135dF7 \
 *   TRUSTED_ATTESTOR=0xE11f02d8372e335F2eF6369e4FB68517A1C76b5b \
 *   forge script script/DeploySimpleDocument.s.sol:DeploySimpleDocument \
 *     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
 *     --broadcast
 */
contract DeploySimpleDocument is Script {
    function run() external {
        // Get deployer private key
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Get EXISTING clause addresses (required)
        address signatureClause = vm.envAddress("SIGNATURE_CLAUSE_ADDRESS");
        address declarativeClause = vm.envAddress("DECLARATIVE_CLAUSE_ADDRESS");

        // Optional trusted attestor
        address trustedAttestor = vm.envOr("TRUSTED_ATTESTOR", address(0));

        console2.log("=== Deploying SimpleDocumentAgreement ===");
        console2.log("Using existing SignatureClauseLogicV3:", signatureClause);
        console2.log("Using existing DeclarativeClauseLogicV3:", declarativeClause);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SimpleDocumentAgreement with existing clause addresses
        SimpleDocumentAgreement agreement = new SimpleDocumentAgreement(declarativeClause, signatureClause);
        console2.log("SimpleDocumentAgreement deployed at:", address(agreement));

        // Set trusted attestor if provided
        if (trustedAttestor != address(0)) {
            agreement.setTrustedAttestor(trustedAttestor, true);
            console2.log("Trusted attestor set:", trustedAttestor);
        }

        vm.stopBroadcast();

        // Output deployment info
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("Network: Avalanche Fuji Testnet");
        console2.log("SimpleDocumentAgreement:", address(agreement));
        console2.log("");
        console2.log("Add to .env.local:");
        console2.log("VITE_SIMPLE_DOCUMENT_TEMPLATE=", address(agreement));
    }
}
