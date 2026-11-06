// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../../src/MockUSD.sol";
import {EscrowBase} from "../../src/EscrowBase.sol";
import {OptimisticStakeEscrow} from "../../src/OptimisticStakeEscrow.sol";

/// Fuzz tests for mechanism B: random payments and bond sizes, random challenge and
/// arbiter windows, and random call order.
contract OptimisticStakeEscrowFuzzTest is Test {
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    address requester = makeAddr("requester");
    address worker = makeAddr("worker");
    address challenger = makeAddr("challenger");
    address arbiter = makeAddr("arbiter");

    function setUp() public {
        token = new MockUSD();
    }

    // ---------------------------------------------------------------- helpers

    /// Deploys an escrow, gives each party exactly what it will have to lock, and takes
    /// one task as far as Submitted. So every balance starts from zero after locking.
    function _escrowWithSubmittedTask(uint256 challengeWindow, uint256 arbiterWindow, uint256 bondBps, uint256 payment)
        internal
        returns (OptimisticStakeEscrow escrow, uint256 taskId, uint256 bond)
    {
        escrow = new OptimisticStakeEscrow(token, 3, 3, challengeWindow, arbiterWindow, arbiter, bondBps);
        bond = escrow.workerBond(payment);

        token.mint(requester, payment);
        token.mint(worker, bond);
        token.mint(challenger, bond);
        vm.prank(challenger);
        token.approve(address(escrow), bond);

        vm.startPrank(requester);
        token.approve(address(escrow), payment);
        taskId = escrow.createTask(worker, payment);
        vm.stopPrank();

        vm.startPrank(worker);
        token.approve(address(escrow), bond);
        escrow.acceptTask(taskId);
        escrow.submitResult(taskId, RESULT);
        vm.stopPrank();
    }

    function _state(OptimisticStakeEscrow escrow, uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    function _skipBlocks(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    // ---------------------------------------------------------------- amounts

    function testFuzz_BondFormula(uint256 payment, uint256 bondBps) public {
        payment = bound(payment, 1, type(uint128).max);
        bondBps = bound(bondBps, 0, 20_000); // up to 200% of the payment
        OptimisticStakeEscrow escrow = new OptimisticStakeEscrow(token, 3, 3, 3, 3, arbiter, bondBps);

        uint256 bond = escrow.workerBond(payment);

        assertEq(bond, payment * bondBps / 10_000);
        if (bondBps <= 10_000) assertLe(bond, payment);
    }

    function testFuzz_FinalizeReturnsPaymentAndBond(uint256 payment, uint256 bondBps) public {
        payment = bound(payment, 1, type(uint128).max);
        bondBps = bound(bondBps, 0, 20_000);
        (OptimisticStakeEscrow escrow, uint256 taskId, uint256 bond) = _escrowWithSubmittedTask(3, 3, bondBps, payment);
        assertEq(token.balanceOf(address(escrow)), payment + bond);
        _skipBlocks(4);

        escrow.finalize(taskId);

        assertEq(token.balanceOf(worker), payment + bond);
        assertEq(token.balanceOf(requester), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFuzz_ResolveMovesBothBondsToTheWinner(uint256 payment, uint256 bondBps, bool workerWins) public {
        payment = bound(payment, 1, type(uint128).max);
        bondBps = bound(bondBps, 0, 20_000);
        (OptimisticStakeEscrow escrow, uint256 taskId, uint256 bond) = _escrowWithSubmittedTask(3, 3, bondBps, payment);
        vm.prank(challenger);
        escrow.challenge(taskId);
        assertEq(token.balanceOf(address(escrow)), payment + 2 * bond);

        vm.prank(arbiter);
        escrow.resolve(taskId, workerWins);

        if (workerWins) {
            assertEq(token.balanceOf(worker), payment + 2 * bond);
            assertEq(token.balanceOf(requester), 0);
            assertEq(token.balanceOf(challenger), 0);
        } else {
            assertEq(token.balanceOf(worker), 0);
            assertEq(token.balanceOf(requester), payment);
            assertEq(token.balanceOf(challenger), 2 * bond);
        }
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFuzz_ArbiterTimeoutReturnsDeposits(uint256 payment, uint256 bondBps) public {
        payment = bound(payment, 1, type(uint128).max);
        bondBps = bound(bondBps, 0, 20_000);
        (OptimisticStakeEscrow escrow, uint256 taskId, uint256 bond) = _escrowWithSubmittedTask(3, 3, bondBps, payment);
        vm.prank(challenger);
        escrow.challenge(taskId);
        _skipBlocks(4);

        escrow.arbiterTimeout(taskId);

        assertEq(token.balanceOf(requester), payment);
        assertEq(token.balanceOf(worker), bond);
        assertEq(token.balanceOf(challenger), bond);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ---------------------------------------------------------------- windows

    function testFuzz_ChallengeWindow(uint256 window, uint256 delay) public {
        window = bound(window, 0, 1_000);
        delay = bound(delay, 0, 2_000);
        (OptimisticStakeEscrow escrow, uint256 taskId,) = _escrowWithSubmittedTask(window, 3, 1_000, 1_000_000);
        _skipBlocks(delay);

        if (delay <= window) {
            vm.expectRevert(EscrowBase.TooEarly.selector);
            escrow.finalize(taskId);

            vm.prank(challenger);
            escrow.challenge(taskId);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Disputed));
        } else {
            vm.prank(challenger);
            vm.expectRevert(EscrowBase.TooLate.selector);
            escrow.challenge(taskId);

            escrow.finalize(taskId);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Paid));
        }
    }

    function testFuzz_ArbiterWindow(uint256 window, uint256 delay, bool workerWins) public {
        window = bound(window, 0, 1_000);
        delay = bound(delay, 0, 2_000);
        (OptimisticStakeEscrow escrow, uint256 taskId,) = _escrowWithSubmittedTask(3, window, 1_000, 1_000_000);
        vm.prank(challenger);
        escrow.challenge(taskId);
        _skipBlocks(delay);

        if (delay <= window) {
            vm.expectRevert(EscrowBase.TooEarly.selector);
            escrow.arbiterTimeout(taskId);

            vm.prank(arbiter);
            escrow.resolve(taskId, workerWins);
            assertEq(
                uint256(_state(escrow, taskId)), uint256(workerWins ? EscrowBase.State.Paid : EscrowBase.State.Refunded)
            );
        } else {
            vm.prank(arbiter);
            vm.expectRevert(EscrowBase.TooLate.selector);
            escrow.resolve(taskId, workerWins);

            escrow.arbiterTimeout(taskId);
            assertEq(uint256(_state(escrow, taskId)), uint256(EscrowBase.State.Refunded));
        }
    }

    // ------------------------------------------------------------- call order

    /// Sixteen random calls at one submitted task. Whatever the order, the escrow holds
    /// exactly the open deposits (payment, worker bond, and the challenger bond while
    /// disputed), no token is lost, and a settled task stays settled.
    function testFuzz_AnyCallOrderKeepsFundsConsistent(uint8[16] memory steps) public {
        uint256 payment = 1_000_000;
        (OptimisticStakeEscrow escrow, uint256 taskId, uint256 bond) = _escrowWithSubmittedTask(3, 3, 1_000, payment);
        EscrowBase.State settledAs = EscrowBase.State.None;

        for (uint256 i = 0; i < steps.length; i++) {
            uint256 action = steps[i] % 7;
            if (action == 0) {
                vm.prank(challenger);
                try escrow.challenge(taskId) {} catch {}
            } else if (action == 1) {
                try escrow.finalize(taskId) {} catch {}
            } else if (action == 2) {
                vm.prank(arbiter);
                try escrow.resolve(taskId, true) {} catch {}
            } else if (action == 3) {
                vm.prank(arbiter);
                try escrow.resolve(taskId, false) {} catch {}
            } else if (action == 4) {
                try escrow.arbiterTimeout(taskId) {} catch {}
            } else if (action == 5) {
                vm.prank(requester);
                try escrow.reclaim(taskId) {} catch {}
            } else {
                _skipBlocks(2);
            }

            EscrowBase.State state = _state(escrow, taskId);
            bool settled = state == EscrowBase.State.Paid || state == EscrowBase.State.Refunded;

            uint256 expectedInEscrow = 0;
            if (state == EscrowBase.State.Submitted) expectedInEscrow = payment + bond;
            if (state == EscrowBase.State.Disputed) expectedInEscrow = payment + 2 * bond;
            assertEq(token.balanceOf(address(escrow)), expectedInEscrow);

            // The payment and both bonds are always somewhere among the four holders.
            assertEq(
                token.balanceOf(address(escrow)) + token.balanceOf(requester) + token.balanceOf(worker)
                    + token.balanceOf(challenger),
                payment + 2 * bond
            );

            if (settledAs != EscrowBase.State.None) {
                assertEq(uint256(state), uint256(settledAs)); // a settled task never changes
            } else if (settled) {
                settledAs = state;
            }
        }
    }
}
