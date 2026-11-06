// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {RequesterApproveEscrow} from "../src/RequesterApproveEscrow.sol";
import {VerifierAttestedEscrow} from "../src/VerifierAttestedEscrow.sol";

/// Deploys the test token and the escrow contracts.
///
/// The parameters are read from environment variables so one script serves every
/// experiment setting. Each falls back to the default below when the variable is not
/// set. The default verifier is Anvil's test account 3.
///
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///       --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract Deploy is Script {
    function run() external {
        uint256 acceptWindow = vm.envOr("ACCEPT_WINDOW", uint256(5));
        uint256 submitWindow = vm.envOr("SUBMIT_WINDOW", uint256(5));
        uint256 reviewWindow = vm.envOr("REVIEW_WINDOW", uint256(5));
        address verifier = vm.envOr("VERIFIER", 0x90F79bf6EB2c4f870365E785982E1f101E93b906);
        uint256 verifierFee = vm.envOr("VERIFIER_FEE", uint256(10_000)); // 0.01 mUSD

        // Everything between startBroadcast and stopBroadcast is sent as real transactions.
        vm.startBroadcast();
        MockUSD token = new MockUSD();
        RequesterApproveEscrow escrowA = new RequesterApproveEscrow(token, acceptWindow, submitWindow, reviewWindow);
        VerifierAttestedEscrow escrowC =
            new VerifierAttestedEscrow(token, acceptWindow, submitWindow, reviewWindow, verifier, verifierFee);
        vm.stopBroadcast();

        console.log("MockUSD                ", address(token));
        console.log("RequesterApproveEscrow ", address(escrowA));
        console.log("VerifierAttestedEscrow ", address(escrowC));
    }
}
