// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {OptimisticStakeEscrow} from "../src/OptimisticStakeEscrow.sol";

/// Unit tests for mechanism B. The shared functions are tested in
/// RequesterApproveEscrow.t.sol; here they are tested only where the bond changes them.
contract OptimisticStakeEscrowTest is Test {
    uint256 constant ACCEPT_WINDOW = 5;
    uint256 constant SUBMIT_WINDOW = 10;
    uint256 constant CHALLENGE_WINDOW = 7;
    uint256 constant ARBITER_WINDOW = 9;
    uint256 constant BOND_BPS = 1_000; // 10%
    uint256 constant PAYMENT = 1_000_000; // 1 mUSD
    uint256 constant BOND = 100_000; // 10% of the payment
    uint256 constant START_BALANCE = 10 * PAYMENT;
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    OptimisticStakeEscrow escrow;

    address requester = makeAddr("requester");
    address worker = makeAddr("worker");
    address challenger = makeAddr("challenger");
    address arbiter = makeAddr("arbiter");
    address stranger = makeAddr("stranger");

    event TaskPaid(uint256 indexed taskId, address indexed to, uint256 amount);
    event TaskRefunded(uint256 indexed taskId, address indexed to, uint256 amount);
    event BondPaid(uint256 indexed taskId, address indexed to, uint256 amount);
    event TaskChallenged(uint256 indexed taskId, address indexed challenger);

    function setUp() public {
        token = new MockUSD();
        escrow = new OptimisticStakeEscrow(
            token, ACCEPT_WINDOW, SUBMIT_WINDOW, CHALLENGE_WINDOW, ARBITER_WINDOW, arbiter, BOND_BPS
        );

        // Requester, worker and challenger each start with the same balance and let the
        // escrow pull from it.
        address[3] memory funded = [requester, worker, challenger];
        for (uint256 i = 0; i < funded.length; i++) {
            token.mint(funded[i], START_BALANCE);
            vm.prank(funded[i]);
            token.approve(address(escrow), type(uint256).max);
        }
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

    function _disputed() internal returns (uint256 taskId) {
        taskId = _submitted();
        vm.prank(challenger);
        escrow.challenge(taskId);
    }

    function _state(uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    function _deadline(uint256 taskId) internal view returns (uint256 deadline) {
        (,,,,, deadline) = escrow.tasks(taskId);
    }

    function _skipBlocks(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    // ------------------------------------------------------------ constructor

    function test_ConstructorStoresParameters() public view {
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.bondBps(), BOND_BPS);
        assertEq(escrow.arbiterWindow(), ARBITER_WINDOW);
        assertEq(escrow.reviewWindow(), CHALLENGE_WINDOW); // the base's review window
    }

    function test_ConstructorRejectsZeroArbiter() public {
        vm.expectRevert(EscrowBase.ZeroAddress.selector);
        new OptimisticStakeEscrow(
            token, ACCEPT_WINDOW, SUBMIT_WINDOW, CHALLENGE_WINDOW, ARBITER_WINDOW, address(0), BOND_BPS
        );
    }

    // ------------------------------------------------------------------ bonds

    function test_BondIsAShareOfThePayment() public view {
        assertEq(escrow.workerBond(PAYMENT), BOND);
        assertEq(escrow.workerBond(2 * PAYMENT), 2 * BOND);
        assertEq(escrow.workerBond(9), 0); // 10% of 9 units rounds down to nothing
        assertEq(escrow.requesterDeposit(PAYMENT), PAYMENT); // the requester locks no bond
    }

    function test_AcceptLocksWorkerBond() public {
        uint256 taskId = _accepted();

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Accepted));
        assertEq(token.balanceOf(worker), START_BALANCE - BOND);
        assertEq(token.balanceOf(address(escrow)), PAYMENT + BOND);
    }

    function test_AcceptRevertsWhenWorkerCannotPayBond() public {
        address poorWorker = makeAddr("poorWorker");
        vm.prank(requester);
        uint256 taskId = escrow.createTask(poorWorker, PAYMENT);

        vm.startPrank(poorWorker);
        token.approve(address(escrow), BOND);
        vm.expectRevert(); // approved, but holds no tokens
        escrow.acceptTask(taskId);
        vm.stopPrank();

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Created));
    }

    function test_ChallengeLocksChallengerBond() public {
        uint256 taskId = _submitted();

        vm.expectEmit(address(escrow));
        emit TaskChallenged(taskId, challenger);
        vm.prank(challenger);
        escrow.challenge(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Disputed));
        assertEq(escrow.challengerOf(taskId), challenger);
        assertEq(_deadline(taskId), vm.getBlockNumber() + ARBITER_WINDOW);
        assertEq(token.balanceOf(challenger), START_BALANCE - BOND);
        assertEq(token.balanceOf(address(escrow)), PAYMENT + 2 * BOND);
    }

    // ------------------------------------------------- worker misses a window

    function test_ReclaimBeforeAcceptReturnsPaymentOnly() public {
        uint256 taskId = _create();
        _skipBlocks(ACCEPT_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), START_BALANCE);
        assertEq(token.balanceOf(worker), START_BALANCE); // no bond was ever locked
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ReclaimAfterAcceptGivesWorkerBondToRequester() public {
        uint256 taskId = _accepted();
        _skipBlocks(SUBMIT_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.expectEmit(address(escrow));
        emit BondPaid(taskId, requester, BOND);
        vm.prank(requester);
        escrow.reclaim(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), START_BALANCE + BOND);
        assertEq(token.balanceOf(worker), START_BALANCE - BOND);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------------------ no challenge

    function test_FinalizePaysWorkerAndReturnsBond() public {
        uint256 taskId = _submitted();
        _skipBlocks(CHALLENGE_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskPaid(taskId, worker, PAYMENT);
        vm.expectEmit(address(escrow));
        emit BondPaid(taskId, worker, BOND);
        vm.prank(stranger); // anyone may finalise
        escrow.finalize(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(worker), START_BALANCE + PAYMENT);
        assertEq(token.balanceOf(requester), START_BALANCE - PAYMENT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_FinalizeRevertsInsideChallengeWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(CHALLENGE_WINDOW);

        vm.expectRevert(EscrowBase.TooEarly.selector);
        escrow.finalize(taskId);
    }

    function test_FinalizeRevertsOnDisputedTask() public {
        uint256 taskId = _disputed();
        _skipBlocks(CHALLENGE_WINDOW + ARBITER_WINDOW + 1);

        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.finalize(taskId);
    }

    // -------------------------------------------------------------- challenge

    function test_ChallengeWorksInLastBlockOfWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(CHALLENGE_WINDOW);

        vm.prank(challenger);
        escrow.challenge(taskId);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Disputed));
    }

    function test_ChallengeRevertsAfterWindow() public {
        uint256 taskId = _submitted();
        _skipBlocks(CHALLENGE_WINDOW + 1);

        vm.prank(challenger);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.challenge(taskId);
    }

    function test_WorkerCannotChallengeItsOwnTask() public {
        uint256 taskId = _submitted();

        vm.prank(worker);
        vm.expectRevert(OptimisticStakeEscrow.WorkerCannotChallenge.selector);
        escrow.challenge(taskId);
    }

    function test_SecondChallengeReverts() public {
        uint256 taskId = _disputed();

        vm.prank(stranger);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.challenge(taskId);
    }

    function test_ChallengeRevertsBeforeSubmission() public {
        uint256 created = _create();
        uint256 accepted = _accepted();

        vm.startPrank(challenger);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.challenge(created);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.challenge(accepted);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.challenge(99); // unknown task
        vm.stopPrank();
    }

    function test_ChallengeRevertsWhenChallengerCannotPayBond() public {
        uint256 taskId = _submitted();

        vm.prank(stranger); // holds no tokens and approved nothing
        vm.expectRevert();
        escrow.challenge(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Submitted));
    }

    // ------------------------------------------------------- arbiter resolves

    function test_ChallengeUpheldRefundsRequesterAndSlashesWorker() public {
        uint256 taskId = _disputed();

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.expectEmit(address(escrow));
        emit BondPaid(taskId, challenger, 2 * BOND);
        vm.prank(arbiter);
        escrow.resolve(taskId, false);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), START_BALANCE);
        assertEq(token.balanceOf(worker), START_BALANCE - BOND); // lost its bond
        assertEq(token.balanceOf(challenger), START_BALANCE + BOND); // won the worker's bond
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ChallengeRejectedPaysWorkerAndSlashesChallenger() public {
        uint256 taskId = _disputed();

        vm.expectEmit(address(escrow));
        emit TaskPaid(taskId, worker, PAYMENT);
        vm.expectEmit(address(escrow));
        emit BondPaid(taskId, worker, 2 * BOND);
        vm.prank(arbiter);
        escrow.resolve(taskId, true);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(requester), START_BALANCE - PAYMENT);
        assertEq(token.balanceOf(worker), START_BALANCE + PAYMENT + BOND); // paid, plus the challenger's bond
        assertEq(token.balanceOf(challenger), START_BALANCE - BOND); // lost its bond
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_RequesterCanBeTheChallenger() public {
        uint256 taskId = _submitted();
        vm.prank(requester);
        escrow.challenge(taskId);

        vm.prank(arbiter);
        escrow.resolve(taskId, false);

        // The requester gets its payment back, its own bond back, and the worker's bond.
        assertEq(token.balanceOf(requester), START_BALANCE + BOND);
        assertEq(token.balanceOf(worker), START_BALANCE - BOND);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_OnlyArbiterResolves() public {
        uint256 taskId = _disputed();

        address[4] memory others = [stranger, requester, worker, challenger];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(OptimisticStakeEscrow.NotArbiter.selector);
            escrow.resolve(taskId, true);
        }
    }

    function test_ResolveWorksInLastBlockOfWindow() public {
        uint256 taskId = _disputed();
        _skipBlocks(ARBITER_WINDOW);

        vm.prank(arbiter);
        escrow.resolve(taskId, true);
        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Paid));
    }

    function test_ResolveRevertsAfterWindow() public {
        uint256 taskId = _disputed();
        _skipBlocks(ARBITER_WINDOW + 1);

        vm.prank(arbiter);
        vm.expectRevert(EscrowBase.TooLate.selector);
        escrow.resolve(taskId, true);
    }

    function test_ResolveRevertsWithoutChallenge() public {
        uint256 taskId = _submitted();

        vm.prank(arbiter);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.resolve(taskId, false);
    }

    // --------------------------------------------------------- arbiter silent

    function test_ArbiterTimeoutReturnsEveryDeposit() public {
        uint256 taskId = _disputed();
        _skipBlocks(ARBITER_WINDOW + 1);

        vm.expectEmit(address(escrow));
        emit TaskRefunded(taskId, requester, PAYMENT);
        vm.expectEmit(address(escrow));
        emit BondPaid(taskId, worker, BOND);
        vm.expectEmit(address(escrow));
        emit BondPaid(taskId, challenger, BOND);
        vm.prank(stranger); // anyone may cancel the dispute
        escrow.arbiterTimeout(taskId);

        assertEq(uint256(_state(taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(requester), START_BALANCE);
        assertEq(token.balanceOf(worker), START_BALANCE);
        assertEq(token.balanceOf(challenger), START_BALANCE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_ArbiterTimeoutRevertsInsideWindow() public {
        uint256 taskId = _disputed();
        _skipBlocks(ARBITER_WINDOW);

        vm.expectRevert(EscrowBase.TooEarly.selector);
        escrow.arbiterTimeout(taskId);
    }

    function test_ArbiterTimeoutRevertsWithoutChallenge() public {
        uint256 taskId = _submitted();
        _skipBlocks(CHALLENGE_WINDOW + ARBITER_WINDOW + 1);

        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.arbiterTimeout(taskId);
    }

    // ------------------------------------------------------------- final state

    function test_DisputedTaskCannotBeReclaimed() public {
        uint256 taskId = _disputed();
        _skipBlocks(ARBITER_WINDOW + 1);

        vm.prank(requester);
        vm.expectRevert(EscrowBase.WrongState.selector);
        escrow.reclaim(taskId);
    }

    function test_FinalizedTaskIsFinal() public {
        uint256 taskId = _submitted();
        _skipBlocks(CHALLENGE_WINDOW + 1);
        escrow.finalize(taskId);

        _assertEveryFunctionReverts(taskId);
        assertEq(token.balanceOf(worker), START_BALANCE + PAYMENT); // paid once
    }

    function test_ResolvedTaskIsFinal() public {
        uint256 taskId = _disputed();
        vm.prank(arbiter);
        escrow.resolve(taskId, false);

        _assertEveryFunctionReverts(taskId);
        assertEq(token.balanceOf(challenger), START_BALANCE + BOND); // bonds paid once
        assertEq(token.balanceOf(requester), START_BALANCE); // refunded once
    }

    /// Calls every state-changing function on a settled task, in and after the windows.
    function _assertEveryFunctionReverts(uint256 taskId) internal {
        for (uint256 round = 0; round < 2; round++) {
            vm.startPrank(worker);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.acceptTask(taskId);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.submitResult(taskId, RESULT);
            vm.stopPrank();

            vm.prank(requester);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.reclaim(taskId);

            vm.prank(challenger);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.challenge(taskId);

            vm.prank(arbiter);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.resolve(taskId, true);

            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.finalize(taskId);
            vm.expectRevert(EscrowBase.WrongState.selector);
            escrow.arbiterTimeout(taskId);

            _skipBlocks(ACCEPT_WINDOW + SUBMIT_WINDOW + CHALLENGE_WINDOW + ARBITER_WINDOW + 1);
        }
    }

    // --------------------------------------------------------------- zero bond

    function test_ZeroBondDeploymentStillSettles() public {
        OptimisticStakeEscrow free = new OptimisticStakeEscrow(
            token, ACCEPT_WINDOW, SUBMIT_WINDOW, CHALLENGE_WINDOW, ARBITER_WINDOW, arbiter, 0
        );
        vm.startPrank(requester);
        token.approve(address(free), PAYMENT);
        uint256 taskId = free.createTask(worker, PAYMENT);
        vm.stopPrank();

        vm.startPrank(worker);
        free.acceptTask(taskId);
        free.submitResult(taskId, RESULT);
        vm.stopPrank();

        vm.prank(stranger); // with no bond, anyone can challenge for free
        free.challenge(taskId);
        vm.prank(arbiter);
        free.resolve(taskId, true);

        assertEq(token.balanceOf(worker), START_BALANCE + PAYMENT);
        assertEq(token.balanceOf(address(free)), 0);
    }
}
