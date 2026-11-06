// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../../src/MockUSD.sol";
import {EscrowBase} from "../../src/EscrowBase.sol";
import {VerifierAttestedEscrow} from "../../src/VerifierAttestedEscrow.sol";

/// Fuzz tests for mechanism C: random payments and fees, random review windows and
/// random call order.
contract VerifierAttestedEscrowFuzzTest is Test {
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    address requester = makeAddr("requester");
    address worker = makeAddr("worker");
    address verifier = makeAddr("verifier");

    function setUp() public {
        token = new MockUSD();
    }

    // ---------------------------------------------------------------- helpers

    /// Deploys an escrow with the given review window and fee, and creates one task.
    function _escrowWithTask(uint256 reviewWindow, uint256 fee, uint256 payment)
        internal
        returns (VerifierAttestedEscrow escrow, uint256 taskId)
    {
        escrow = new VerifierAttestedEscrow(token, 3, 3, reviewWindow, verifier, fee);
        token.mint(requester, payment + fee);
        vm.startPrank(requester);
        token.approve(address(escrow), payment + fee);
        taskId = escrow.createTask(worker, payment);
        vm.stopPrank();
    }

    function _acceptAndSubmit(VerifierAttestedEscrow escrow, uint256 taskId) internal {
        vm.startPrank(worker);
        escrow.acceptTask(taskId);
        escrow.submitResult(taskId, RESULT);
        vm.stopPrank();
    }

    function _state(VerifierAttestedEscrow escrow, uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    function _skipBlocks(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    // ---------------------------------------------------------------- amounts

    function testFuzz_AttestSplitsPaymentAndFee(uint256 payment, uint256 fee, bool pass) public {
        payment = bound(payment, 1, type(uint128).max);
        fee = bound(fee, 0, type(uint128).max);
        (VerifierAttestedEscrow escrow, uint256 taskId) = _escrowWithTask(5, fee, payment);
        assertEq(token.balanceOf(address(escrow)), payment + fee);
        _acceptAndSubmit(escrow, taskId);

        vm.prank(verifier);
        escrow.attest(taskId, pass);

        assertEq(token.balanceOf(worker), pass ? payment : 0);
        assertEq(token.balanceOf(requester), pass ? 0 : payment);
        assertEq(token.balanceOf(verifier), fee);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFuzz_ReclaimReturnsPaymentAndFee(uint256 payment, uint256 fee, bool workerAccepts) public {
        payment = bound(payment, 1, type(uint128).max);
        fee = bound(fee, 0, type(uint128).max);
        (VerifierAttestedEscrow escrow, uint256 taskId) = _escrowWithTask(5, fee, payment);
        if (workerAccepts) {
            vm.prank(worker);
            escrow.acceptTask(taskId);
        }
        _skipBlocks(4); // past the 3-block accept or submit window

        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(token.balanceOf(requester), payment + fee);
        assertEq(token.balanceOf(verifier), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ---------------------------------------------------------------- windows

    function testFuzz_ReviewWindow(uint256 window, uint256 delay, bool pass) public {
        window = bound(window, 0, 1_000);
        delay = bound(delay, 0, 2_000);
        (VerifierAttestedEscrow escrow, uint256 taskId) = _escrowWithTask(window, 20_000, 1_000_000);
        _acceptAndSubmit(escrow, taskId);
        _skipBlocks(delay);

        if (delay <= window) {
            vm.prank(requester);
            vm.expectRevert(EscrowBase.TooEarly.selector);
            escrow.verifierTimeout(taskId);

            vm.prank(verifier);
            escrow.attest(taskId, pass);
            assertEq(token.balanceOf(verifier), 20_000);
        } else {
            vm.prank(verifier);
            vm.expectRevert(EscrowBase.TooLate.selector);
            escrow.attest(taskId, pass);

            vm.prank(requester);
            escrow.verifierTimeout(taskId);
            assertEq(token.balanceOf(requester), 1_020_000);
            assertEq(token.balanceOf(verifier), 0);
        }
    }

    // ------------------------------------------------------------- call order

    /// Sixteen random calls at one task, each from the role the function belongs to.
    /// Whatever the order, the escrow holds payment and fee until the task is settled
    /// and nothing afterwards, no token is lost, and a settled task stays settled.
    function testFuzz_AnyCallOrderKeepsFundsConsistent(uint8[16] memory steps) public {
        uint256 payment = 1_000_000;
        uint256 fee = 20_000;
        (VerifierAttestedEscrow escrow, uint256 taskId) = _escrowWithTask(3, fee, payment);
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
                vm.prank(verifier);
                try escrow.attest(taskId, true) {} catch {}
            } else if (action == 3) {
                vm.prank(verifier);
                try escrow.attest(taskId, false) {} catch {}
            } else if (action == 4) {
                vm.prank(requester);
                try escrow.verifierTimeout(taskId) {} catch {}
            } else if (action == 5) {
                vm.prank(requester);
                try escrow.reclaim(taskId) {} catch {}
            } else {
                _skipBlocks(2);
            }

            EscrowBase.State state = _state(escrow, taskId);
            bool settled = state == EscrowBase.State.Paid || state == EscrowBase.State.Refunded;

            assertEq(token.balanceOf(address(escrow)), settled ? 0 : payment + fee);
            assertEq(token.balanceOf(worker), state == EscrowBase.State.Paid ? payment : 0);
            // Payment and fee are always somewhere among the four holders.
            assertEq(
                token.balanceOf(address(escrow)) + token.balanceOf(requester) + token.balanceOf(worker)
                    + token.balanceOf(verifier),
                payment + fee
            );

            if (settledAs != EscrowBase.State.None) {
                assertEq(uint256(state), uint256(settledAs)); // a settled task never changes
            } else if (settled) {
                settledAs = state;
            }
        }
    }
}
