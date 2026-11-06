// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {RequesterApproveEscrow} from "../src/RequesterApproveEscrow.sol";
import {VerifierAttestedEscrow} from "../src/VerifierAttestedEscrow.sol";
import {OptimisticStakeEscrow} from "../src/OptimisticStakeEscrow.sol";
import {BudgetGuard} from "../src/BudgetGuard.sol";

/// Deploys the test token, the three escrow contracts and a BudgetGuard that is
/// allowed to use all three.
///
/// The parameters are read from environment variables so one script serves every
/// experiment setting. Each falls back to the default written next to it when the
/// variable is not set. The default verifier, arbiter and orchestrator are Anvil's
/// test accounts 3, 4 and 1. The account that sends the transactions becomes the
/// owner of the guard.
///
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast \
///       --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract Deploy is Script {
    function run() external {
        // The three windows every mechanism has. The other parameters are read where
        // they are used: a function can only hold a limited number of local variables.
        uint256 acceptWindow = vm.envOr("ACCEPT_WINDOW", uint256(5));
        uint256 submitWindow = vm.envOr("SUBMIT_WINDOW", uint256(5));
        uint256 reviewWindow = vm.envOr("REVIEW_WINDOW", uint256(5)); // A and C

        // Every contract creation and call between startBroadcast and stopBroadcast is
        // sent as a real transaction. Reading the environment is not.
        vm.startBroadcast();

        MockUSD token = new MockUSD();

        RequesterApproveEscrow escrowA = new RequesterApproveEscrow(token, acceptWindow, submitWindow, reviewWindow);

        VerifierAttestedEscrow escrowC = new VerifierAttestedEscrow(
            token,
            acceptWindow,
            submitWindow,
            reviewWindow,
            vm.envOr("VERIFIER", 0x90F79bf6EB2c4f870365E785982E1f101E93b906),
            vm.envOr("VERIFIER_FEE", uint256(10_000)) // 0.01 mUSD
        );

        OptimisticStakeEscrow escrowB = new OptimisticStakeEscrow(
            token,
            acceptWindow,
            submitWindow,
            vm.envOr("CHALLENGE_WINDOW", uint256(5)),
            vm.envOr("ARBITER_WINDOW", uint256(5)),
            vm.envOr("ARBITER", 0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65),
            vm.envOr("BOND_BPS", uint256(1_000)) // 10% of the payment
        );

        BudgetGuard guard = new BudgetGuard(
            token,
            msg.sender, // the account given with --sender becomes the owner
            vm.envOr("ORCHESTRATOR", 0x70997970C51812dc3A010C7d01b50e0d17dc79C8),
            vm.envOr("PER_TASK_CAP", uint256(2_000_000)), // 2 mUSD
            vm.envOr("EPOCH_BUDGET", uint256(10_000_000)), // 10 mUSD
            vm.envOr("EPOCH_LENGTH", uint256(100)) // blocks
        );
        guard.setEscrowAllowed(address(escrowA), true);
        guard.setEscrowAllowed(address(escrowC), true);
        guard.setEscrowAllowed(address(escrowB), true);

        vm.stopBroadcast();

        console.log("MockUSD                ", address(token));
        console.log("RequesterApproveEscrow ", address(escrowA));
        console.log("VerifierAttestedEscrow ", address(escrowC));
        console.log("OptimisticStakeEscrow  ", address(escrowB));
        console.log("BudgetGuard            ", address(guard));
    }
}
