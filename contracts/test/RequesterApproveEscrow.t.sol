// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {RequesterApproveEscrow} from "../src/RequesterApproveEscrow.sol";

/// Unit tests for mechanism A. They also cover everything in EscrowBase, because A adds
/// no deposits of its own to the shared functions.
contract RequesterApproveEscrowTest is Test {
    uint256 constant ACCEPT_WINDOW = 5;
    uint256 constant SUBMIT_WINDOW = 10;
    uint256 constant REVIEW_WINDOW = 7;
    uint256 constant PAYMENT = 1_000_000; // 1 mUSD
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    RequesterApproveEscrow escrow;

    address requester = makeAddr("requester");
    address worker = makeAddr("worker");
    address stranger = makeAddr("stranger");

    // Copies of the contract's events, needed by vm.expectEmit.
    event TaskCreated(uint256 indexed taskId, address indexed requester, address indexed worker, uint256 payment);
    event TaskAccepted(uint256 indexed taskId);
    event ResultSubmitted(uint256 indexed taskId, bytes32 resultHash);
    event TaskPaid(uint256 indexed taskId, address indexed to, uint256 amount);
    event TaskRefunded(uint256 indexed taskId, address indexed to, uint256 amount);

    function setUp() public {
        token = new MockUSD();
        escrow = new RequesterApproveEscrow(token, ACCEPT_WINDOW, SUBMIT_WINDOW, REVIEW_WINDOW);

        token.mint(requester, 10 * PAYMENT);
        vm.prank(requester);
        token.approve(address(escrow), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _create() internal returns (uint256 taskId) {
        vm.prank(requester);
        taskId = escrow.createTask(worker, PAYMENT);
    }

    function _accepted() internal returns (uint256 taskId) {
        taskId = _create();
        vm.prank(worker);
        escrow.acceptTask(taskId);
    }

    function _submitted() internal returns (uint256 taskId) {
        taskId = _accepted();
        vm.prank(worker);
        escrow.submitResult(taskId, RESULT);
    }

    function _paid() internal returns (uint256 taskId) {
        taskId = _submitted();
        vm.prank(requester);
        escrow.approve(taskId);
    }

    function _refunded() internal returns (uint256 taskId) {
        taskId = _submitted();
        vm.prank(requester);
        escrow.reject(taskId);
    }

    function _state(uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    function _deadline(uint256 taskId) internal view returns (uint256 deadline) {
        (,,,,, deadline) = escrow.tasks(taskId);
    }

    function _skipBlocks(uint256 n) internal {
        vm.roll(block.number + n);
    }

    // ------------------------------------------------------------ constructor

    function test_ConstructorStoresParameters() public view {
        assertEq(address(escrow.token()), address(token));
        assertEq(escrow.acceptWindow(), ACCEPT_WINDOW);
        assertEq(escrow.submitWindow(), SUBMIT_WINDOW);
        assertEq(escrow.reviewWindow(), REVIEW_WINDOW);
        assertEq(escrow.taskCount(), 0);
    }

    function test_ConstructorRejectsZeroToken() public {
        vm.expectRevert(EscrowBase.ZeroAddress.selector);
        new RequesterApproveEscrow(IERC20(address(0)), ACCEPT_WINDOW, SUBMIT_WINDOW, REVIEW_WINDOW);
    }

    function test_DepositsAreThePaymentAndNoBond() public view {
        assertEq(escrow.requesterDeposit(PAYMENT), PAYMENT);
        assertEq(escrow.workerBond(PAYMENT), 0);
    }

    // ------------------------------------------------------------- createTask

    function test_CreateLocksPaymentAndStoresTask() public {
        vm.expectEmit(address(escrow));
        emit TaskCreated(1, requester, worker, PAYMENT);
        uint256 taskId = _create();

        assertEq(taskId, 1);
        assertEq(escrow.taskCount(), 1);
        assertEq(token.balanceOf(address(escrow)), PAYMENT);
        assertEq(token.balanceOf(requester), 9 * PAYMENT);

        (
            address storedRequester,
            EscrowBase.State state,
            address storedWorker,
            uint256 payment,
            bytes32 resultHash,
            uint256 deadline
        ) = escrow.tasks(taskId);
        assertEq(storedRequester, requester);
        assertEq(uint256(state), uint256(EscrowBase.State.Created));
        assertEq(storedWorker, worker);
        assertEq(payment, PAYMENT);
        assertEq(resultHash, bytes32(0));
        assertEq(deadline, block.number + ACCEPT_WINDOW);
    }

    function test_TaskIdsCountUpFromOne() public {
        assertEq(_create(), 1);
        assertEq(_create(), 2);
        assertEq(_create(), 3);
        assertEq(token.balanceOf(address(escrow)), 3 * PAYMENT);
    }

    function test_CreateRevertsOnZeroWorker() public {
        vm.prank(requester);
        vm.expectRevert(EscrowBase.ZeroAddress.selector);
        escrow.createTask(address(0), PAYMENT);
    }

    function test_CreateRevertsOnZeroPayment() public {
        vm.prank(requester);
        vm.expectRevert(EscrowBase.ZeroPayment.selector);
        escrow.createTask(worker, 0);
    }

    function test_CreateRevertsWithoutAllowance() public {
        token.mint(stranger, PAYMENT);
        vm.prank(stranger); // never approved the escrow
        vm.expectRevert();
        escrow.createTask(worker, PAYMENT);
    }

    function test_CreateRevertsWithoutBalance() public {
        vm.startPrank(stranger); // approved but holds no tokens
        token.approve(address(escrow), PAYMENT);
        vm.expectRevert();
        escrow.createTask(worker, PAYMENT);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- happy path

    function test_HappyPathPaysWorker() public {
        uint256 taskId = _create();

        vm.expectEmit(address(escrow));
        emit TaskAccepted(taskId);
        vm.prank(worker);
        escrow.acceptTask(taskId);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Accepted));
        assertEq(_deadline(taskId), block.number + SUBMIT_WINDOW);

        vm.expectEmit(address(escrow));
        emit ResultSubmitted(taskId, RESULT);
        vm.prank(worker);
        escrow.submitResult(taskId, RESULT);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Submitted));
        assertEq(_deadline(taskId), block.number + REVIEW_WINDOW);
        (,,,, bytes32 resultHash,) = escrow.tasks(taskId);
        assertEq(resultHash, RESULT);

        vm.expectEmit(address(escrow));
        emit TaskPaid(taskId, worker, PAYMENT);
        vm.prank(requester);
        escrow.approve(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(worker), PAYMENT);
        assertEq(token.balanceOf(requester), 9 * PAYMENT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ---------------------------------------------------------------- reject

    function test_RejectRefundsRequester() public {
        uint256 taskId = _submitted();

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.prank(requester);
        escrow.reject(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(worker), 0);
        assertEq(token.balanceOf(requester), 10 * PAYMENT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------- requester stays silent

    function test_WorkerClaimsWhenRequesterIsSilent() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskPaid(taskId, worker, PAYMENT);
        vm.prank(worker);
        escrow.claimAfterTimeout(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(worker), PAYMENT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ClaimRevertsInsideReviewWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW); // last block of the window: still the requester's turn

        vm.prank(worker);
        vm.expectRevert(EscrowBase.TooEarly.selector);
        escrow.claimAfterTimeout(taskId);
    }

    // ------------------------------------------------- worker misses a window

    function test_ReclaimWhenWorkerNeverAccepts() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), 10 * PAYMENT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReclaimWhenWorkerNeverSubmits() public {
        uint256 taskId = _accepted();
        _skipBlocks(SUBMIT_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), 10 * PAYMENT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReclaimRevertsInsideAcceptWindow() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.TooEarly.selector);
        escrow.reclaim(taskId);
    }

    function test_ReclaimRevertsInsideSubmitWindow() public {
        uint256 taskId = _accepted();
        _skipBlocks(SUBMIT_WINDOW);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.TooEarly.selector);
        escrow.reclaim(taskId);
    }

    // ------------------------------------------------- deadlines for actions

    function test_AcceptWorksInLastBlockOfWindow() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW);

        vm.prank(worker);
        escrow.acceptTask(taskId);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Accepted));
    }

    function test_AcceptRevertsAfterWindow() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW + 1);

        vm.prank(worker);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.acceptTask(taskId);
    }

    function test_SubmitWorksInLastBlockOfWindow() public {
        uint256 taskId = _accepted();
        _skipBlocks(SUBMIT_WINDOW);

        vm.prank(worker);
        escrow.submitResult(taskId, RESULT);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Submitted));
    }

    function test_SubmitRevertsAfterWindow() public {
        uint256 taskId = _accepted();
        _skipBlocks(SUBMIT_WINDOW + 1);

        vm.prank(worker);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.submitResult(taskId, RESULT);
    }

    function test_ApproveWorksInLastBlockOfWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW);

        vm.prank(requester);
        escrow.approve(taskId);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
    }

    function test_ApproveRevertsAfterWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.approve(taskId);
    }

    function test_RejectRevertsAfterWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.reject(taskId);
    }

    // --------------------------------------------------- forbidden transitions

    function test_UnknownTaskIsRejectedEverywhere() public {
        uint256 unknown = 99;

        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.acceptTask(unknown);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.submitResult(unknown, RESULT);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.approve(unknown);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reject(unknown);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.claimAfterTimeout(unknown);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reclaim(unknown);
    }

    function test_CreatedTaskAllowsOnlyAcceptAndReclaim() public {
        uint256 taskId = _create();

        vm.startPrank(worker);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.submitResult(taskId, RESULT);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.claimAfterTimeout(taskId);
        vm.stopPrank();

        vm.startPrank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.approve(taskId);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reject(taskId);
        vm.stopPrank();
    }

    function test_AcceptedTaskAllowsOnlySubmitAndReclaim() public {
        uint256 taskId = _accepted();

        vm.startPrank(worker);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.acceptTask(taskId);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.claimAfterTimeout(taskId);
        vm.stopPrank();

        vm.startPrank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.approve(taskId);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reject(taskId);
        vm.stopPrank();
    }

    function test_SubmittedTaskCannotGoBack() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1); // so that time is never the reason for the revert

        vm.startPrank(worker);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.acceptTask(taskId);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.submitResult(taskId, RESULT);
        vm.stopPrank();

        vm.prank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reclaim(taskId);
    }

    function test_PaidTaskIsFinal() public {
        uint256 taskId = _paid();
        _assertEveryFunctionReverts(taskId);
        assertEq(token.balanceOf(worker), PAYMENT); // paid once, not twice
    }

    function test_RefundedTaskIsFinal() public {
        uint256 taskId = _refunded();
        _assertEveryFunctionReverts(taskId);
        assertEq(token.balanceOf(requester), 10 * PAYMENT); // refunded once, not twice
    }

    function test_ReclaimedTaskIsFinal() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW + 1);
        vm.prank(requester);
        escrow.reclaim(taskId);

        _assertEveryFunctionReverts(taskId);
        assertEq(token.balanceOf(requester), 10 * PAYMENT);
    }

    /// Calls every state-changing function on a settled task, in and after the window.
    function _assertEveryFunctionReverts(uint256 taskId) internal {
        for (uint256 round = 0; round < 2; round++) {
            vm.startPrank(worker);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.acceptTask(taskId);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.submitResult(taskId, RESULT);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.claimAfterTimeout(taskId);
            vm.stopPrank();

            vm.startPrank(requester);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.approve(taskId);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.reject(taskId);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.reclaim(taskId);
            vm.stopPrank();

            _skipBlocks(ACCEPT_WINDOW + SUBMIT_WINDOW + REVIEW_WINDOW + 1);
        }
    }

    // ------------------------------------------------------------ wrong caller

    function test_OnlyWorkerAccepts() public {
        uint256 taskId = _create();

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotWorker.selector);
        escrow.acceptTask(taskId);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.NotWorker.selector);
        escrow.acceptTask(taskId);
    }

    function test_OnlyWorkerSubmits() public {
        uint256 taskId = _accepted();

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotWorker.selector);
        escrow.submitResult(taskId, RESULT);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.NotWorker.selector);
        escrow.submitResult(taskId, RESULT);
    }

    function test_OnlyRequesterApproves() public {
        uint256 taskId = _submitted();

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.approve(taskId);

        vm.prank(worker); // a worker must not be able to approve its own work
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.approve(taskId);
    }

    function test_OnlyRequesterRejects() public {
        uint256 taskId = _submitted();

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.reject(taskId);

        vm.prank(worker);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.reject(taskId);
    }

    function test_OnlyWorkerClaimsAfterTimeout() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotWorker.selector);
        escrow.claimAfterTimeout(taskId);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.NotWorker.selector);
        escrow.claimAfterTimeout(taskId);
    }

    function test_OnlyRequesterReclaims() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW + 1);

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.reclaim(taskId);

        vm.prank(worker);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.reclaim(taskId);
    }

    // ------------------------------------------------------- tasks are separate

    function test_SettlingOneTaskLeavesTheOtherLocked() public {
        uint256 first = _submitted();
        uint256 second = _submitted();

        vm.prank(requester);
        escrow.approve(first);

        assertEq(uint256(_state(first)), uint256(EscrowBase.State.Paid));
        assertEq(uint256(_state(second)), uint256(EscrowBase.State.Submitted));
        assertEq(token.balanceOf(address(escrow)), PAYMENT); // the second payment is still held
    }
}
