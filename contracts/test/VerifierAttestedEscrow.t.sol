// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {VerifierAttestedEscrow} from "../src/VerifierAttestedEscrow.sol";

/// Unit tests for mechanism C. The shared functions are tested in
/// RequesterApproveEscrow.t.sol; here they are tested only where the fee changes them.
contract VerifierAttestedEscrowTest is Test {
    uint256 constant ACCEPT_WINDOW = 5;
    uint256 constant SUBMIT_WINDOW = 10;
    uint256 constant REVIEW_WINDOW = 7;
    uint256 constant PAYMENT = 1_000_000; // 1 mUSD
    uint256 constant FEE = 20_000; // 0.02 mUSD
    uint256 constant START_BALANCE = 10 * (PAYMENT + FEE);
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    VerifierAttestedEscrow escrow;

    address requester = makeAddr("requester");
    address worker = makeAddr("worker");
    address verifier = makeAddr("verifier");
    address stranger = makeAddr("stranger");

    event TaskPaid(uint256 indexed taskId, address indexed to, uint256 amount);
    event TaskRefunded(uint256 indexed taskId, address indexed to, uint256 amount);
    event FeePaid(uint256 indexed taskId, address indexed to, uint256 amount);

    function setUp() public {
        token = new MockUSD();
        escrow = new VerifierAttestedEscrow(token, ACCEPT_WINDOW, SUBMIT_WINDOW, REVIEW_WINDOW, verifier, FEE);

        token.mint(requester, START_BALANCE);
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

    function _state(uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    function _skipBlocks(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    // ------------------------------------------------------------ constructor

    function test_ConstructorStoresVerifierAndFee() public view {
        assertEq(escrow.verifier(), verifier);
        assertEq(escrow.verifierFee(), FEE);
        assertEq(escrow.reviewWindow(), REVIEW_WINDOW);
    }

    function test_ConstructorRejectsZeroVerifier() public {
        vm.expectRevert(EscrowBase.ZeroAddress.selector);
        new VerifierAttestedEscrow(token, ACCEPT_WINDOW, SUBMIT_WINDOW, REVIEW_WINDOW, address(0), FEE);
    }

    function test_DepositIsPaymentPlusFeeAndNoBond() public view {
        assertEq(escrow.requesterDeposit(PAYMENT), PAYMENT + FEE);
        assertEq(escrow.workerBond(PAYMENT), 0);
    }

    // ------------------------------------------------------------- createTask

    function test_CreateLocksPaymentAndFee() public {
        _create();

        assertEq(token.balanceOf(address(escrow)), PAYMENT + FEE);
        assertEq(token.balanceOf(requester), START_BALANCE - PAYMENT - FEE);
    }

    function test_CreateRevertsWhenOnlyThePaymentIsApproved() public {
        token.mint(stranger, PAYMENT + FEE);
        vm.startPrank(stranger);
        token.approve(address(escrow), PAYMENT); // the fee is not covered
        vm.expectRevert();
        escrow.createTask(worker, PAYMENT);
        vm.stopPrank();
    }

    // ----------------------------------------------------------------- attest

    function test_PassPaysWorkerAndFeeGoesToVerifier() public {
        uint256 taskId = _submitted();

        vm.expectEmit(address(escrow));
        emit TaskPaid(taskId, worker, PAYMENT);
        vm.expectEmit(address(escrow));
        emit FeePaid(taskId, verifier, FEE);
        vm.prank(verifier);
        escrow.attest(taskId, true);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(worker), PAYMENT);
        assertEq(token.balanceOf(verifier), FEE);
        assertEq(token.balanceOf(requester), START_BALANCE - PAYMENT - FEE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_FailRefundsRequesterAndFeeGoesToVerifier() public {
        uint256 taskId = _submitted();

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.expectEmit(address(escrow));
        emit FeePaid(taskId, verifier, FEE);
        vm.prank(verifier);
        escrow.attest(taskId, false);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(worker), 0);
        assertEq(token.balanceOf(verifier), FEE);
        assertEq(token.balanceOf(requester), START_BALANCE - FEE); // the fee is spent either way
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_OnlyVerifierAttests() public {
        uint256 taskId = _submitted();

        vm.prank(stranger);
        vm.expectRevert(VerifierAttestedEscrow.NotVerifier.selector);
        escrow.attest(taskId, true);

        vm.prank(worker); // a worker must not be able to pass its own work
        vm.expectRevert(VerifierAttestedEscrow.NotVerifier.selector);
        escrow.attest(taskId, true);

        vm.prank(requester); // a requester must not be able to fail work to get a refund
        vm.expectRevert(VerifierAttestedEscrow.NotVerifier.selector);
        escrow.attest(taskId, false);
    }

    function test_AttestWorksInLastBlockOfWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW);

        vm.prank(verifier);
        escrow.attest(taskId, true);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
    }

    function test_AttestRevertsAfterWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.prank(verifier);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.attest(taskId, true);
    }

    function test_AttestRevertsBeforeSubmission() public {
        uint256 created = _create();
        uint256 accepted = _accepted();

        vm.startPrank(verifier);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.attest(created, true);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.attest(accepted, true);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.attest(99, true); // unknown task
        vm.stopPrank();
    }

    function test_AttestTwiceReverts() public {
        uint256 taskId = _submitted();

        vm.startPrank(verifier);
        escrow.attest(taskId, true);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.attest(taskId, true);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.attest(taskId, false);
        vm.stopPrank();

        assertEq(token.balanceOf(worker), PAYMENT); // paid once
        assertEq(token.balanceOf(verifier), FEE); // fee paid once
    }

    // -------------------------------------------------------- verifier silent

    function test_VerifierTimeoutRefundsPaymentAndFee() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT + FEE);
        vm.prank(requester);
        escrow.verifierTimeout(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), START_BALANCE);
        assertEq(token.balanceOf(worker), 0);
        assertEq(token.balanceOf(verifier), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_VerifierTimeoutRevertsInsideWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.TooEarly.selector);
        escrow.verifierTimeout(taskId);
    }

    function test_OnlyRequesterCallsVerifierTimeout() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.verifierTimeout(taskId);

        vm.prank(verifier);
        vm.expectRevert(EscrowBase.NotRequester.selector);
        escrow.verifierTimeout(taskId);
    }

    function test_VerifierTimeoutRevertsBeforeSubmissionAndAfterSettlement() public {
        uint256 accepted = _accepted();
        uint256 settled = _submitted();
        vm.prank(verifier);
        escrow.attest(settled, true);
        _skipBlocks(SUBMIT_WINDOW + REVIEW_WINDOW + 1);

        vm.startPrank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.verifierTimeout(accepted);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.verifierTimeout(settled);
        vm.stopPrank();
    }

    // ------------------------------------------------- worker misses a window

    function test_ReclaimReturnsFeeWhenWorkerNeverAccepts() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT + FEE);
        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(token.balanceOf(requester), START_BALANCE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReclaimReturnsFeeWhenWorkerNeverSubmits() public {
        uint256 taskId = _accepted();
        _skipBlocks(SUBMIT_WINDOW + 1);

        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), START_BALANCE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReclaimRevertsOnceSubmitted() public {
        uint256 taskId = _submitted();
        _skipBlocks(REVIEW_WINDOW + 1);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reclaim(taskId);
    }

    // ------------------------------------------------------------- final state

    function test_SettledTaskIsFinal() public {
        uint256 taskId = _submitted();
        vm.prank(verifier);
        escrow.attest(taskId, false);
        _skipBlocks(ACCEPT_WINDOW + SUBMIT_WINDOW + REVIEW_WINDOW + 1);

        vm.startPrank(worker);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.acceptTask(taskId);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.submitResult(taskId, RESULT);
        vm.stopPrank();

        vm.startPrank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reclaim(taskId);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.verifierTimeout(taskId);
        vm.stopPrank();

        vm.prank(verifier);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.attest(taskId, true);

        assertEq(token.balanceOf(requester), START_BALANCE - FEE);
        assertEq(token.balanceOf(worker), 0);
    }

    // ---------------------------------------------------------------- zero fee

    function test_ZeroFeeDeploymentStillSettles() public {
        VerifierAttestedEscrow free =
            new VerifierAttestedEscrow(token, ACCEPT_WINDOW, SUBMIT_WINDOW, REVIEW_WINDOW, verifier, 0);
        vm.startPrank(requester);
        token.approve(address(free), PAYMENT);
        uint256 taskId = free.createTask(worker, PAYMENT);
        vm.stopPrank();

        vm.startPrank(worker);
        free.acceptTask(taskId);
        free.submitResult(taskId, RESULT);
        vm.stopPrank();

        vm.prank(verifier);
        free.attest(taskId, true);

        assertEq(token.balanceOf(worker), PAYMENT);
        assertEq(token.balanceOf(verifier), 0);
        assertEq(token.balanceOf(address(free)), 0);
    }
}
