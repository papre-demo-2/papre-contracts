// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {PartyEscrowFactory} from "../src/escrow/PartyEscrowFactory.sol";
import {PartyEscrowProxy} from "../src/escrow/PartyEscrowProxy.sol";

/// @title DeployPartyEscrow
/// @notice Deploys the PartyEscrowFactory to Fuji testnet
/// @dev The factory deploys the implementation contract in its constructor
contract DeployPartyEscrow is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console.log("Deploying PartyEscrowFactory...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        vm.startBroadcast(deployerPrivateKey);

        // Deploy factory (implementation is deployed in constructor)
        PartyEscrowFactory factory = new PartyEscrowFactory();

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("PartyEscrowFactory:", address(factory));
        console.log("PartyEscrowProxy Implementation:", factory.implementation());
        console.log("");
        console.log("Add to papre-app/src/lib/contracts.ts:");
        console.log("  partyEscrowFactory: '", address(factory), "'");
    }
}
