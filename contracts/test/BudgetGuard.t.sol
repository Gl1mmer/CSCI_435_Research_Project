// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {RequesterApproveEscrow} from "../src/RequesterApproveEscrow.sol";
import {VerifierAttestedEscrow} from "../src/VerifierAttestedEscrow.sol";
import {BudgetGuard} from "../src/BudgetGuard.sol";

contract BudgetGuardTest is Test {
    uint256 constant WINDOW = 5;
    uint256 constant FEE = 20_000;
    uint256 constant PAYMENT = 1_000_000; // 1 mUSD
    uint256 constant PER_TASK_CAP = 2_000_000; // 2 mUSD
    uint256 constant EPOCH_BUDGET = 5_000_000; // 5 mUSD
    uint256 constant EPOCH_LENGTH = 100; // blocks
    uint256 constant FUNDS = 100_000_000; // 100 mUSD held by the guard
    bytes32 constant RESULT = keccak256("result");

    MockUSD token;
    RequesterApproveEscrow escrowA;
    VerifierAttestedEscrow escrowC;
    BudgetGuard guard;

    address owner = makeAddr("owner");
    address orchestrator = makeAddr("orchestrator");
    address worker = makeAddr("worker");
    address verifier = makeAddr("verifier");
    address stranger = makeAddr("stranger");

    event EscrowAllowed(address indexed escrow, bool allowed);
    event Spent(address indexed escrow, uint256 amount, uint256 epoch);
    event Withdrawn(address indexed to, uint256 amount);

    function setUp() public {
        token = new MockUSD();
        escrowA = new RequesterApproveEscrow(token, WINDOW, WINDOW, WINDOW);
        escrowC = new VerifierAttestedEscrow(token, WINDOW, WINDOW, WINDOW, verifier, FEE);
        guard = new BudgetGuard(token, owner, orchestrator, PER_TASK_CAP, EPOCH_BUDGET, EPOCH_LENGTH);

        token.mint(address(guard), FUNDS);
        vm.startPrank(owner);
        guard.setEscrowAllowed(address(escrowA), true);
        guard.setEscrowAllowed(address(escrowC), true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _createA(uint256 payment) internal returns (uint256 taskId) {
        vm.prank(orchestrator);
        taskId = guard.createTask(escrowA, worker, payment);
    }

    function _acceptAndSubmit(EscrowBase escrow, uint256 taskId) internal {
        vm.startPrank(worker);
        escrow.acceptTask(taskId);
        escrow.submitResult(taskId, RESULT);
        vm.stopPrank();
    }

    function _state(EscrowBase escrow, uint256 taskId) internal view returns (EscrowBase.State state) {
        (, state,,,,) = escrow.tasks(taskId);
    }

    // ------------------------------------------------------------ constructor

    function test_ConstructorStoresParameters() public view {
        assertEq(address(guard.token()), address(token));
        assertEq(guard.owner(), owner);
        assertEq(guard.orchestrator(), orchestrator);
        assertEq(guard.perTaskCap(), PER_TASK_CAP);
        assertEq(guard.epochBudget(), EPOCH_BUDGET);
        assertEq(guard.epochLength(), EPOCH_LENGTH);
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(BudgetGuard.ZeroAddress.selector);
        new BudgetGuard(IERC20(address(0)), owner, orchestrator, PER_TASK_CAP, EPOCH_BUDGET, EPOCH_LENGTH);
        vm.expectRevert(BudgetGuard.ZeroAddress.selector);
        new BudgetGuard(token, address(0), orchestrator, PER_TASK_CAP, EPOCH_BUDGET, EPOCH_LENGTH);
        vm.expectRevert(BudgetGuard.ZeroAddress.selector);
        new BudgetGuard(token, owner, address(0), PER_TASK_CAP, EPOCH_BUDGET, EPOCH_LENGTH);
    }

    function test_ConstructorRejectsZeroEpochLength() public {
        vm.expectRevert(BudgetGuard.ZeroEpochLength.selector);
        new BudgetGuard(token, owner, orchestrator, PER_TASK_CAP, EPOCH_BUDGET, 0);
    }

    // ------------------------------------------------------------- createTask

    function test_CreateTaskLocksGuardFundsAndGuardIsRequester() public {
        vm.expectEmit(address(guard));
        emit Spent(address(escrowA), PAYMENT, vm.getBlockNumber() / EPOCH_LENGTH);
        uint256 taskId = _createA(PAYMENT);

        (address requester,, address storedWorker, uint256 payment,,) = escrowA.tasks(taskId);
        assertEq(requester, address(guard));
        assertEq(storedWorker, worker);
        assertEq(payment, PAYMENT);
        assertEq(token.balanceOf(address(guard)), FUNDS - PAYMENT);
        assertEq(token.balanceOf(address(escrowA)), PAYMENT);
        assertEq(guard.spentInEpoch(), PAYMENT);
    }

    function test_CreateTaskLeavesNoAllowanceBehind() public {
        _createA(PAYMENT);
        assertEq(token.allowance(address(guard), address(escrowA)), 0);
    }

    function test_OnlyOrchestratorCreatesTasks() public {
        vm.prank(stranger);
        vm.expectRevert(BudgetGuard.NotOrchestrator.selector);
        guard.createTask(escrowA, worker, PAYMENT);

        vm.prank(owner); // not even the owner: spending is the orchestrator's job
        vm.expectRevert(BudgetGuard.NotOrchestrator.selector);
        guard.createTask(escrowA, worker, PAYMENT);
    }

    // -------------------------------------------------------------- allowlist

    function test_EscrowNotOnAllowlistIsRejected() public {
        RequesterApproveEscrow other = new RequesterApproveEscrow(token, WINDOW, WINDOW, WINDOW);

        vm.prank(orchestrator);
        vm.expectRevert(BudgetGuard.EscrowNotAllowed.selector);
        guard.createTask(other, worker, PAYMENT);
    }

    function test_OwnerCanRemoveEscrowFromAllowlist() public {
        vm.expectEmit(address(guard));
        emit EscrowAllowed(address(escrowA), false);
        vm.prank(owner);
        guard.setEscrowAllowed(address(escrowA), false);

        vm.prank(orchestrator);
        vm.expectRevert(BudgetGuard.EscrowNotAllowed.selector);
        guard.createTask(escrowA, worker, PAYMENT);
    }

    function test_OnlyOwnerChangesAllowlist() public {
        vm.prank(stranger);
        vm.expectRevert(BudgetGuard.NotOwner.selector);
        guard.setEscrowAllowed(stranger, true);

        vm.prank(orchestrator); // a stolen orchestrator key must not be able to add an escrow
        vm.expectRevert(BudgetGuard.NotOwner.selector);
        guard.setEscrowAllowed(stranger, true);
    }

    // ----------------------------------------------------------- per-task cap

    function test_TaskAtTheCapIsAllowed() public {
        _createA(PER_TASK_CAP);
        assertEq(token.balanceOf(address(escrowA)), PER_TASK_CAP);
    }

    function test_TaskOverTheCapIsRejected() public {
        vm.prank(orchestrator);
        vm.expectRevert(BudgetGuard.OverTaskCap.selector);
        guard.createTask(escrowA, worker, PER_TASK_CAP + 1);
    }

    function test_CapCountsTheVerifierFee() public {
        // In mechanism C the escrow pulls payment + fee, and that sum must fit the cap.
        vm.prank(orchestrator);
        vm.expectRevert(BudgetGuard.OverTaskCap.selector);
        guard.createTask(escrowC, worker, PER_TASK_CAP - FEE + 1);

        vm.prank(orchestrator);
        guard.createTask(escrowC, worker, PER_TASK_CAP - FEE);
        assertEq(token.balanceOf(address(escrowC)), PER_TASK_CAP);
        assertEq(guard.spentInEpoch(), PER_TASK_CAP);
    }

    // ----------------------------------------------------------- epoch budget

    function test_EpochBudgetStopsFurtherTasks() public {
        for (uint256 i = 0; i < 5; i++) {
            _createA(PAYMENT); // 5 x 1 mUSD uses the whole 5 mUSD budget
        }
        assertEq(guard.spentInEpoch(), EPOCH_BUDGET);

        vm.prank(orchestrator);
        vm.expectRevert(BudgetGuard.OverEpochBudget.selector);
        guard.createTask(escrowA, worker, 1);
    }

    function test_BudgetIsFullAgainInTheNextEpoch() public {
        for (uint256 i = 0; i < 5; i++) {
            _createA(PAYMENT);
        }
        vm.roll(vm.getBlockNumber() + EPOCH_LENGTH);

        _createA(PAYMENT);

        assertEq(guard.currentEpoch(), vm.getBlockNumber() / EPOCH_LENGTH);
        assertEq(guard.spentInEpoch(), PAYMENT);
    }

    function test_RefundDoesNotGiveBudgetBack() public {
        uint256 taskId = _createA(PAYMENT);
        vm.roll(vm.getBlockNumber() + WINDOW + 1); // the worker never accepts
        vm.prank(orchestrator);
        guard.reclaim(escrowA, taskId);

        assertEq(token.balanceOf(address(guard)), FUNDS); // the money is back
        assertEq(guard.spentInEpoch(), PAYMENT); // but it still counts as spent this epoch
    }

    /// The scenario the guard exists for: the orchestrator key is stolen and the thief
    /// creates tasks for its own address as fast as it can.
    function test_StolenOrchestratorKeyIsLimitedToTheEpochBudget() public {
        address thief = makeAddr("thief");
        vm.startPrank(orchestrator);
        for (uint256 i = 0; i < 100; i++) {
            try guard.createTask(escrowA, thief, PER_TASK_CAP) {} catch {}
        }
        vm.stopPrank();

        uint256 locked = FUNDS - token.balanceOf(address(guard));
        assertLe(locked, EPOCH_BUDGET);
        assertEq(locked, 4_000_000); // two tasks of 2 mUSD fit; a third would exceed 5 mUSD
    }

    function testFuzz_SpendingNeverExceedsEpochBudget(uint256[12] memory payments) public {
        vm.startPrank(orchestrator);
        for (uint256 i = 0; i < payments.length; i++) {
            uint256 payment = bound(payments[i], 1, PER_TASK_CAP + 500_000); // some are over the cap
            try guard.createTask(escrowA, worker, payment) {} catch {}
            assertLe(guard.spentInEpoch(), EPOCH_BUDGET);
        }
        vm.stopPrank();

        // Everything that left the guard is in the escrow and is counted as spent.
        assertEq(FUNDS - token.balanceOf(address(guard)), guard.spentInEpoch());
        assertEq(token.balanceOf(address(escrowA)), guard.spentInEpoch());
    }

    // ------------------------------------------------- forwarded requester calls

    function test_ApproveThroughGuardPaysWorker() public {
        uint256 taskId = _createA(PAYMENT);
        _acceptAndSubmit(escrowA, taskId);

        vm.prank(orchestrator);
        guard.approve(escrowA, taskId);

        assertEq(uint256(_state(escrowA, taskId)), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(worker), PAYMENT);
    }

    function test_RejectThroughGuardRefundsTheGuard() public {
        uint256 taskId = _createA(PAYMENT);
        _acceptAndSubmit(escrowA, taskId);

        vm.prank(orchestrator);
        guard.reject(escrowA, taskId);

        assertEq(uint256(_state(escrowA, taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(address(guard)), FUNDS);
        assertEq(token.balanceOf(orchestrator), 0); // the refund goes to the guard, not to the key
    }

    function test_VerifierTimeoutThroughGuardRefundsPaymentAndFee() public {
        vm.prank(orchestrator);
        uint256 taskId = guard.createTask(escrowC, worker, PAYMENT);
        _acceptAndSubmit(escrowC, taskId);
        vm.roll(vm.getBlockNumber() + WINDOW + 1);

        vm.prank(orchestrator);
        guard.verifierTimeout(escrowC, taskId);

        assertEq(uint256(_state(escrowC, taskId)), uint256(EscrowBase.State.Refunded));
        assertEq(token.balanceOf(address(guard)), FUNDS);
    }

    function test_OnlyOrchestratorUsesForwardedCalls() public {
        uint256 taskId = _createA(PAYMENT);
        _acceptAndSubmit(escrowA, taskId);

        vm.startPrank(stranger);
        vm.expectRevert(BudgetGuard.NotOrchestrator.selector);
        guard.approve(escrowA, taskId);
        vm.expectRevert(BudgetGuard.NotOrchestrator.selector);
        guard.reject(escrowA, taskId);
        vm.expectRevert(BudgetGuard.NotOrchestrator.selector);
        guard.reclaim(escrowA, taskId);
        vm.expectRevert(BudgetGuard.NotOrchestrator.selector);
        guard.verifierTimeout(escrowC, taskId);
        vm.stopPrank();
    }

    function test_ForwardedCallsNeedAnAllowedEscrow() public {
        RequesterApproveEscrow other = new RequesterApproveEscrow(token, WINDOW, WINDOW, WINDOW);

        vm.startPrank(orchestrator);
        vm.expectRevert(BudgetGuard.EscrowNotAllowed.selector);
        guard.approve(other, 1);
        vm.expectRevert(BudgetGuard.EscrowNotAllowed.selector);
        guard.reject(other, 1);
        vm.expectRevert(BudgetGuard.EscrowNotAllowed.selector);
        guard.reclaim(other, 1);
        vm.stopPrank();
    }

    // --------------------------------------------------------------- withdraw

    function test_OwnerWithdraws() public {
        vm.expectEmit(address(guard));
        emit Withdrawn(owner, 30_000_000);
        vm.prank(owner);
        guard.withdraw(30_000_000);

        assertEq(token.balanceOf(owner), 30_000_000);
        assertEq(token.balanceOf(address(guard)), FUNDS - 30_000_000);
    }

    function test_OnlyOwnerWithdraws() public {
        vm.prank(orchestrator); // a stolen orchestrator key cannot simply take the balance
        vm.expectRevert(BudgetGuard.NotOwner.selector);
        guard.withdraw(1);

        vm.prank(stranger);
        vm.expectRevert(BudgetGuard.NotOwner.selector);
        guard.withdraw(1);
    }
}
