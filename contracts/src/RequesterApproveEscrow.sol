// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowBase} from "./EscrowBase.sol";

/// @title RequesterApproveEscrow (mechanism A, the baseline)
/// @notice The requester judges the submitted work itself. It approves (the worker is
///         paid) or rejects (the requester is refunded) within the review window. If the
///         requester stays silent past the window, the worker claims the payment.
/// @dev    Rejection needs no proof, so a free-riding requester can reject good work and
///         get its money back. That weakness is what the experiment measures.
contract RequesterApproveEscrow is EscrowBase {
    using SafeERC20 for IERC20;

    constructor(IERC20 token_, uint256 acceptWindow_, uint256 submitWindow_, uint256 reviewWindow_)
        EscrowBase(token_, acceptWindow_, submitWindow_, reviewWindow_)
    {}

    /// @notice The requester accepts the result: the worker is paid.
    function approve(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        require(msg.sender == t.requester, NotRequester());
        require(block.number <= t.deadline, TooLate());

        t.state = State.Paid;
        emit TaskPaid(taskId, t.worker, t.payment);
        token.safeTransfer(t.worker, t.payment);
    }

    /// @notice The requester refuses the result: the requester is refunded.
    function reject(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        require(msg.sender == t.requester, NotRequester());
        require(block.number <= t.deadline, TooLate());

        t.state = State.Refunded;
        emit TaskRefunded(taskId, t.requester, t.payment);
        token.safeTransfer(t.requester, t.payment);
    }

    /// @notice The requester neither approved nor rejected in time: the worker takes
    ///         the payment. Without this a silent requester could lock the money forever.
    function claimAfterTimeout(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        require(msg.sender == t.worker, NotWorker());
        require(block.number > t.deadline, TooEarly());

        t.state = State.Paid;
        emit TaskPaid(taskId, t.worker, t.payment);
        token.safeTransfer(t.worker, t.payment);
    }
}
