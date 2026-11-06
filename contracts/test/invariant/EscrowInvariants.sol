// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockUSD} from "../../src/MockUSD.sol";
import {EscrowBase} from "../../src/EscrowBase.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/// The properties that must hold for every mechanism after every call, whatever the
/// order of calls. Foundry runs many random call sequences against the handler and
/// checks each `invariant_` function after every call.
///
/// The three test contracts (one per mechanism) inherit these checks and only set up
/// `token`, `escrow` and `handler`.
abstract contract EscrowInvariants is Test {
    MockUSD token;
    EscrowBase escrow;
    EscrowHandler handler;

    /// Token conservation inside the escrow: its balance is exactly the sum of what the
    /// open tasks have locked (payments, fees and bonds). More would mean stuck tokens,
    /// less would mean one task was paid with another task's money.
    function invariant_BalanceEqualsOpenDeposits() public view {
        uint256 locked = 0;
        uint256 count = escrow.taskCount();
        for (uint256 taskId = 1; taskId <= count; taskId++) {
            locked += _lockedBy(taskId);
        }
        assertEq(token.balanceOf(address(escrow)), locked);
    }

    /// No task is settled twice and a settled task never changes: a Paid task emitted
    /// TaskPaid exactly once and never TaskRefunded, a Refunded task the opposite, and
    /// an open task has emitted neither.
    function invariant_TaskSettledAtMostOnce() public view {
        uint256 count = escrow.taskCount();
        for (uint256 taskId = 1; taskId <= count; taskId++) {
            (, EscrowBase.State state,,,,) = escrow.tasks(taskId);
            uint256 paid = handler.paidEvents(taskId);
            uint256 refunded = handler.refundedEvents(taskId);

            if (state == EscrowBase.State.Paid) {
                assertEq(paid, 1);
                assertEq(refunded, 0);
            } else if (state == EscrowBase.State.Refunded) {
                assertEq(paid, 0);
                assertEq(refunded, 1);
            } else {
                assertEq(paid, 0);
                assertEq(refunded, 0);
            }
        }
    }

    /// Token conservation overall: every token is either in the escrow or held by one
    /// of the known parties. Nothing is sent to an address that should not receive it.
    function invariant_NoTokenLeavesTheSystem() public view {
        assertEq(token.balanceOf(address(escrow)) + handler.tokensOutsideEscrow(), token.totalSupply());
    }

    /// What one task has locked in the escrow, by state. requesterDeposit and
    /// workerBond are the mechanism's own rules, so this works for A, C and B.
    function _lockedBy(uint256 taskId) internal view returns (uint256) {
        (, EscrowBase.State state,, uint256 payment,,) = escrow.tasks(taskId);
        if (state == EscrowBase.State.Created) {
            return escrow.requesterDeposit(payment);
        }
        if (state == EscrowBase.State.Accepted || state == EscrowBase.State.Submitted) {
            return escrow.requesterDeposit(payment) + escrow.workerBond(payment);
        }
        if (state == EscrowBase.State.Disputed) {
            // the worker's bond and the challenger's bond
            return escrow.requesterDeposit(payment) + 2 * escrow.workerBond(payment);
        }
        return 0; // Paid or Refunded: everything has left the escrow
    }
}
