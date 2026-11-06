// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {RequesterApproveEscrow} from "../src/RequesterApproveEscrow.sol";

/// Deploys the test token and the escrow contracts.
///
/// The windows are read from environment variables so one script serves every
/// experiment setting; each falls back to 5 blocks when the variable is not set.
///
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///       --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract Deploy is Script {
    function run() external {
        uint256 acceptWindow = vm.envOr("ACCEPT_WINDOW", uint256(5));
        uint256 submitWindow = vm.envOr("SUBMIT_WINDOW", uint256(5));
        uint256 reviewWindow = vm.envOr("REVIEW_WINDOW", uint256(5));

        // Everything between startBroadcast and stopBroadcast is sent as real transactions.
        vm.startBroadcast();
        MockUSD token = new MockUSD();
        RequesterApproveEscrow escrowA = new RequesterApproveEscrow(token, acceptWindow, submitWindow, reviewWindow);
        vm.stopBroadcast();

        console.log("MockUSD                ", address(token));
        console.log("RequesterApproveEscrow ", address(escrowA));
    }
}
