// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockUSD} from "../../src/MockUSD.sol";
import {OptimisticStakeEscrow} from "../../src/OptimisticStakeEscrow.sol";
import {EscrowHandler} from "./EscrowHandler.sol";
import {EscrowInvariants} from "./EscrowInvariants.sol";

/// The shared actions plus challenge and the three ways mechanism B settles a task.
contract OptimisticStakeHandler is EscrowHandler {
    OptimisticStakeEscrow immutable escrowB;

    constructor(MockUSD token_, OptimisticStakeEscrow escrow_) EscrowHandler(token_, escrow_) {
        escrowB = escrow_;
    }

    /// Any actor may challenge. When the random actor is the task's worker the escrow
    /// rejects the call.
    function challenge(uint256 taskSeed, uint256 challengerSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_actor(challengerSeed));
        escrowB.challenge(taskId);
    }

    function finalize(uint256 taskSeed) external countSettlements {
        escrowB.finalize(_task(taskSeed));
    }

    function resolve(uint256 taskSeed, bool workerWins) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(escrowB.arbiter());
        escrowB.resolve(taskId, workerWins);
    }

    function arbiterTimeout(uint256 taskSeed) external countSettlements {
        escrowB.arbiterTimeout(_task(taskSeed));
    }
}

contract OptimisticStakeEscrowInvariantTest is EscrowInvariants {
    function setUp() public {
        token = new MockUSD();
        // Windows of 6 blocks, bond 10% of the payment. The arbiter never holds tokens.
        OptimisticStakeEscrow escrowB = new OptimisticStakeEscrow(token, 6, 6, 6, 6, makeAddr("arbiter"), 1_000);
        escrow = escrowB;
        handler = new OptimisticStakeHandler(token, escrowB);

        targetContract(address(handler));
    }
}
