// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockUSD} from "../../src/MockUSD.sol";
import {RequesterApproveEscrow} from "../../src/RequesterApproveEscrow.sol";
import {EscrowHandler} from "./EscrowHandler.sol";
import {EscrowInvariants} from "./EscrowInvariants.sol";

/// The shared actions plus the three ways mechanism A settles a submitted task.
contract RequesterApproveHandler is EscrowHandler {
    RequesterApproveEscrow immutable escrowA;

    constructor(MockUSD token_, RequesterApproveEscrow escrow_) EscrowHandler(token_, escrow_) {
        escrowA = escrow_;
    }

    function approve(uint256 taskSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_requester(taskId));
        escrowA.approve(taskId);
    }

    function reject(uint256 taskSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_requester(taskId));
        escrowA.reject(taskId);
    }

    function claimAfterTimeout(uint256 taskSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_worker(taskId));
        escrowA.claimAfterTimeout(taskId);
    }
}

contract RequesterApproveEscrowInvariantTest is EscrowInvariants {
    function setUp() public {
        token = new MockUSD();
        // Windows of 6 blocks: some random sequences finish inside them, and skipBlocks
        // (1 to 3 blocks per call) makes others miss them.
        RequesterApproveEscrow escrowA = new RequesterApproveEscrow(token, 6, 6, 6);
        escrow = escrowA;
        handler = new RequesterApproveHandler(token, escrowA);

        // Fuzz only the handler, not the escrow or the token directly.
        targetContract(address(handler));
    }
}
