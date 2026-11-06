// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../../src/MockUSD.sol";
import {EscrowBase} from "../../src/EscrowBase.sol";
import {RequesterApproveEscrow} from "../../src/RequesterApproveEscrow.sol";

/// Fuzz tests for mechanism A and the shared base: Foundry calls each test many times
/// with random arguments. They cover random amounts, random windows and random call order.
contract RequesterApproveEscrowFuzzTest is Test {
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    address requester = makeAddr("requester");
    address worker = makeAddr("worker");

    function setUp() public {
        token = new MockUSD();
    }

    // ---------------------------------------------------------------- helpers

    /// Deploys an escrow with the given windows and creates one task of `payment`.
    function _escrowWithTask(uint256 acceptWindow, uint256 submitWindow, uint256 reviewWindow, uint256 payment)
        internal
        returns (RequesterApproveEscrow escrow, uint256 taskId)
    {
        escrow = new RequesterApproveEscrow(token, acceptWindow, submitWindow, reviewWindow);
        token.mint(requester, payment);
        vm.startPrank(requester);
        token.approve(address(escrow), payment);
        taskId = escrow.createTask(worker, payment);
        vm.stopPrank();
    }

    function _acceptAndSubmit(RequesterApproveEscrow escrow, uint256 taskId) internal {
        vm.startPrank(worker);
        escrow.acceptTask(taskId);
        escrow.submitResult(taskId, RESULT);
        vm.stopPrank();
    }

    function _state(RequesterApproveEscrow escrow, uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    function _skipBlocks(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    // ---------------------------------------------------------------- amounts

    function testFuzz_ApprovePaysExactAmount(uint256 payment) public {
        payment = bound(payment, 1, type(uint128).max);
        (RequesterApproveEscrow escrow, uint256 taskId) = _escrowWithTask(5, 5, 5, payment);
        _acceptAndSubmit(escrow, taskId);

        vm.prank(requester);
        escrow.approve(taskId);

        assertEq(token.balanceOf(worker), payment);
        assertEq(token.balanceOf(requester), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFuzz_RejectRefundsExactAmount(uint256 payment) public {
        payment = bound(payment, 1, type(uint128).max);
        (RequesterApproveEscrow escrow, uint256 taskId) = _escrowWithTask(5, 5, 5, payment);
        _acceptAndSubmit(escrow, taskId);

        vm.prank(requester);
        escrow.reject(taskId);

        assertEq(token.balanceOf(worker), 0);
        assertEq(token.balanceOf(requester), payment);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ---------------------------------------------------------------- windows
    // For every window and every delay exactly one of the two sides can act: the party
    // whose turn it is while the window is open, the other party once it has closed.

    function testFuzz_AcceptWindow(uint256 window, uint256 delay) public {
        window = bound(window, 0, 1_000);
        delay = bound(delay, 0, 2_000);
        (RequesterApproveEscrow escrow, uint256 taskId) = _escrowWithTask(window, 5, 5, 1_000_000);
        _skipBlocks(delay);

        if (delay <= window) {
            vm.prank(requester);
            vm.expectRevert(EscrowBase.TooEarly.selector);
            escrow.reclaim(taskId);

            vm.prank(worker);
            escrow.acceptTask(taskId);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Accepted));
        } else {
            vm.prank(worker);
            vm.expectRevert(EscrowBase.TooLate.selector);
            escrow.acceptTask(taskId);

            vm.prank(requester);
            escrow.reclaim(taskId);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Refunded));
        }
    }

    function testFuzz_SubmitWindow(uint256 window, uint256 delay) public {
        window = bound(window, 0, 1_000);
        delay = bound(delay, 0, 2_000);
        (RequesterApproveEscrow escrow, uint256 taskId) = _escrowWithTask(5, window, 5, 1_000_000);
        vm.prank(worker);
        escrow.acceptTask(taskId);
        _skipBlocks(delay);

        if (delay <= window) {
            vm.prank(requester);
            vm.expectRevert(EscrowBase.TooEarly.selector);
            escrow.reclaim(taskId);

            vm.prank(worker);
            escrow.submitResult(taskId, RESULT);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Submitted));
        } else {
            vm.prank(worker);
            vm.expectRevert(EscrowBase.TooLate.selector);
            escrow.submitResult(taskId, RESULT);

            vm.prank(requester);
            escrow.reclaim(taskId);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Refunded));
        }
    }

    function testFuzz_ReviewWindow(uint256 window, uint256 delay, bool approves) public {
        window = bound(window, 0, 1_000);
        delay = bound(delay, 0, 2_000);
        (RequesterApproveEscrow escrow, uint256 taskId) = _escrowWithTask(5, 5, window, 1_000_000);
        _acceptAndSubmit(escrow, taskId);
        _skipBlocks(delay);

        if (delay <= window) {
            vm.prank(worker);
            vm.expectRevert(EscrowBase.TooEarly.selector);
            escrow.claimAfterTimeout(taskId);

            vm.prank(requester);
            if (approves) escrow.approve(taskId);
            else escrow.reject(taskId);
            assertEq(token.balanceOf(approves ? worker : requester), 1_000_000);
        } else {
            vm.prank(requester);
            vm.expectRevert(EscrowBase.TooLate.selector);
            if (approves) escrow.approve(taskId);
            else escrow.reject(taskId);

            vm.prank(worker);
            escrow.claimAfterTimeout(taskId);
            assertEq(token.balanceOf(worker), 1_000_000);
        }
    }

    // ------------------------------------------------------------- call order

    /// Sends sixteen random calls at one task, each from the role the function belongs
    /// to. Calls that are not allowed at that moment revert and are ignored. Whatever
    /// the order, the escrow holds the payment until the task is settled and nothing
    /// afterwards, the payment goes to exactly one party, and a settled task stays settled.
    function testFuzz_AnyCallOrderKeepsFundsConsistent(uint8[16] memory steps) public {
        uint256 payment = 1_000_000;
        (RequesterApproveEscrow escrow, uint256 taskId) = _escrowWithTask(3, 3, 3, payment);
        EscrowBase.State settledAs = EscrowBase.State.None;

        for (uint256 i = 0; i < steps.length; i++) {
            uint256 action = steps[i] % 7;
            if (action == 0) {
                vm.prank(worker);
                try escrow.acceptTask(taskId) {} catch {}
            } else if (action == 1) {
                vm.prank(worker);
                try escrow.submitResult(taskId, RESULT) {} catch {}
            } else if (action == 2) {
                vm.prank(requester);
                try escrow.approve(taskId) {} catch {}
            } else if (action == 3) {
                vm.prank(requester);
                try escrow.reject(taskId) {} catch {}
            } else if (action == 4) {
                vm.prank(worker);
                try escrow.claimAfterTimeout(taskId) {} catch {}
            } else if (action == 5) {
                vm.prank(requester);
                try escrow.reclaim(taskId) {} catch {}
            } else {
                _skipBlocks(2);
            }

            EscrowBase.State state = _state(escrow, taskId);
            bool settled = state == EscrowBase.State.Paid || state == EscrowBase.State.Refunded;

            assertEq(token.balanceOf(address(escrow)), settled ? 0 : payment);
            assertEq(token.balanceOf(worker), state == EscrowBase.State.Paid ? payment : 0);
            assertEq(token.balanceOf(requester), state == EscrowBase.State.Refunded ? payment : 0);

            if (settledAs != EscrowBase.State.None) {
                assertEq(uint256(state), uint256(settledAs)); // a settled task never changes
            } else if (settled) {
                settledAs = state;
            }
        }
    }
}
