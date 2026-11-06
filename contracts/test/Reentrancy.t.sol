// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EscrowBase} from "../src/EscrowBase.sol";
import {RequesterApproveEscrow} from "../src/RequesterApproveEscrow.sol";

/// A hostile token. While the escrow is paying a task out, the token calls back into
/// the escrow and tries to settle the same task a second time.
///
/// The token is also the task's requester, so its call back passes the caller check and
/// only the escrow's re-entrancy protection can stop it.
contract ReentrantToken is ERC20 {
    RequesterApproveEscrow public escrow;
    uint256 public taskId; // the task that is attacked
    bool public reenterWithReject; // false: call approve again, true: call reject
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() ERC20("Reentrant", "RE") {}

    function setUp(RequesterApproveEscrow escrow_, bool reenterWithReject_) external {
        escrow = escrow_;
        reenterWithReject = reenterWithReject_;
    }

    /// Creates the task to attack and a second one. The second task's payment stays in
    /// the escrow, so a successful second payout would have money to take.
    function createTasks(address worker, uint256 payment) external {
        _mint(address(this), 2 * payment);
        _approve(address(this), address(escrow), 2 * payment);
        taskId = escrow.createTask(worker, payment);
        escrow.createTask(worker, payment);
    }

    function approveTask() external {
        escrow.approve(taskId);
    }

    /// OpenZeppelin's ERC20 calls _update for every transfer. The attack starts when
    /// tokens leave the escrow, which only happens in the middle of a payout.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(escrow) && !reentryAttempted) {
            reentryAttempted = true;
            if (reenterWithReject) {
                try escrow.reject(taskId) {
                    reentrySucceeded = true;
                } catch {}
            } else {
                try escrow.approve(taskId) {
                    reentrySucceeded = true;
                } catch {}
            }
        }
    }
}

/// Slither cannot see the token calls the escrows make through SafeERC20 (see
/// docs/slither-report.md), so re-entrancy is tested here with a real attack.
contract ReentrancyTest is Test {
    uint256 constant PAYMENT = 1_000_000;

    ReentrantToken token;
    RequesterApproveEscrow escrow;
    address worker = makeAddr("worker");

    function _attack(bool reenterWithReject) internal {
        token = new ReentrantToken();
        escrow = new RequesterApproveEscrow(token, 5, 5, 5);
        token.setUp(escrow, reenterWithReject);
        token.createTasks(worker, PAYMENT); // task 1 is attacked, task 2 only holds money

        vm.startPrank(worker);
        escrow.acceptTask(1);
        escrow.submitResult(1, keccak256("result"));
        vm.stopPrank();

        token.approveTask(); // the payout during which the token calls back
    }

    function _assertPaidExactlyOnce() internal view {
        assertTrue(token.reentryAttempted());
        assertFalse(token.reentrySucceeded());

        (, EscrowBase.State state,,,,) = escrow.tasks(1);
        assertEq(uint256(state), uint256(EscrowBase.State.Paid));
        assertEq(token.balanceOf(worker), PAYMENT);
        assertEq(token.balanceOf(address(token)), 0); // the requester got nothing back
        assertEq(token.balanceOf(address(escrow)), PAYMENT); // task 2's payment is untouched
    }

    function test_SecondApproveDuringPayoutFails() public {
        _attack(false);
        _assertPaidExactlyOnce();
    }

    function test_RejectDuringApprovePayoutFails() public {
        _attack(true);
        _assertPaidExactlyOnce();
    }
}
