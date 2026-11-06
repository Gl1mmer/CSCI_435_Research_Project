// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {MockUSD} from "../../src/MockUSD.sol";
import {EscrowBase} from "../../src/EscrowBase.sol";

/// In an invariant test Foundry does not call the escrow directly. It calls the public
/// functions of this handler in a random order with random arguments, and the handler
/// turns each call into a sensible escrow call: an existing task id, and the caller the
/// function belongs to. Calls the escrow rejects (wrong state, too early, too late)
/// simply revert and are skipped.
///
/// This contract holds the actions every mechanism shares. Each mechanism adds its own
/// settlement actions in a contract that inherits from this one.
abstract contract EscrowHandler is Test {
    uint256 constant START_BALANCE = 1e18;
    uint256 constant MAX_PAYMENT = 1e9; // 1,000 mUSD
    uint256 constant MAX_TASKS = 8;

    MockUSD immutable token;
    EscrowBase immutable escrow;

    /// The addresses that act as requesters, workers and challengers.
    address[] public actors;

    /// How many TaskPaid and TaskRefunded events each task has emitted so far.
    mapping(uint256 taskId => uint256) public paidEvents;
    mapping(uint256 taskId => uint256) public refundedEvents;

    constructor(MockUSD token_, EscrowBase escrow_) {
        token = token_;
        escrow = escrow_;

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], START_BALANCE);
            vm.prank(actors[i]);
            token.approve(address(escrow), type(uint256).max);
        }
    }

    /// Reads the events of the wrapped call and counts the settlement events per task.
    modifier countSettlements() {
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(escrow)) continue;
            // topics[0] identifies the event, topics[1] is the indexed task id.
            if (logs[i].topics[0] == EscrowBase.TaskPaid.selector) {
                paidEvents[uint256(logs[i].topics[1])]++;
            } else if (logs[i].topics[0] == EscrowBase.TaskRefunded.selector) {
                refundedEvents[uint256(logs[i].topics[1])]++;
            }
        }
    }

    // ------------------------------------------------------------- shared actions

    /// Stops after a few tasks per run. With more, the random calls would be spread
    /// over so many tasks that hardly any task got far enough to be settled.
    function createTask(uint256 requesterSeed, uint256 workerSeed, uint256 payment) external countSettlements {
        if (escrow.taskCount() == MAX_TASKS) return;
        payment = bound(payment, 1, MAX_PAYMENT);
        vm.prank(_actor(requesterSeed));
        escrow.createTask(_actor(workerSeed), payment);
    }

    function acceptTask(uint256 taskSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_worker(taskId));
        escrow.acceptTask(taskId);
    }

    function submitResult(uint256 taskSeed, bytes32 resultHash) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_worker(taskId));
        escrow.submitResult(taskId, resultHash);
    }

    function reclaim(uint256 taskSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_requester(taskId));
        escrow.reclaim(taskId);
    }

    /// Lets time pass, so that deadlines are sometimes met and sometimes missed.
    function skipBlocks(uint256 blocks) external {
        vm.roll(vm.getBlockNumber() + bound(blocks, 1, 3));
    }

    // ------------------------------------------------------- used by the invariants

    /// All tokens that are not inside the escrow. Mechanism C adds the verifier.
    function tokensOutsideEscrow() public view virtual returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }

    // --------------------------------------------------------------------- helpers

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// Maps a random number to an existing task id. With no task yet it returns 0,
    /// which the escrow rejects.
    function _task(uint256 seed) internal view returns (uint256) {
        uint256 count = escrow.taskCount();
        return count == 0 ? 0 : 1 + seed % count;
    }

    function _requester(uint256 taskId) internal view returns (address requester) {
        (requester,,,,,) = escrow.tasks(taskId);
    }

    function _worker(uint256 taskId) internal view returns (address worker) {
        (,, worker,,,) = escrow.tasks(taskId);
    }
}
