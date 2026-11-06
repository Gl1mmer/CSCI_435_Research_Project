// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowBase} from "./EscrowBase.sol";

/// @title VerifierAttestedEscrow (mechanism C)
/// @notice A verifier, fixed when the contract is deployed, judges the submitted work.
///         If it passes the work the worker is paid; if it fails the work the requester
///         is refunded. The requester locks a flat verifier fee together with the
///         payment, and the verifier earns that fee for every verdict, pass or fail.
/// @dev    The fee does not depend on the verdict, so the verifier gains nothing by
///         favouring one side. If the verifier gives no verdict in the review window
///         the requester takes back the payment and the fee.
contract VerifierAttestedEscrow is EscrowBase {
    using SafeERC20 for IERC20;

    /// @notice The only address allowed to attest.
    address public immutable verifier;
    /// @notice Flat fee per task, in token units, paid by the requester to the verifier.
    uint256 public immutable verifierFee;

    event FeePaid(uint256 indexed taskId, address indexed to, uint256 amount);

    error NotVerifier();

    constructor(
        IERC20 token_,
        uint256 acceptWindow_,
        uint256 submitWindow_,
        uint256 reviewWindow_,
        address verifier_,
        uint256 verifierFee_
    ) EscrowBase(token_, acceptWindow_, submitWindow_, reviewWindow_) {
        require(verifier_ != address(0), ZeroAddress());
        verifier = verifier_;
        verifierFee = verifierFee_;
    }

    /// @notice The requester locks the payment plus the verifier fee.
    function requesterDeposit(uint256 payment) public view override returns (uint256) {
        return payment + verifierFee;
    }

    /// @notice The verifier gives its verdict: `pass` pays the worker, otherwise the
    ///         requester is refunded. The verifier receives its fee in both cases.
    function attest(uint256 taskId, bool pass) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        require(msg.sender == verifier, NotVerifier());
        require(block.number <= t.deadline, TooLate());

        address payee;
        if (pass) {
            t.state = State.Paid;
            payee = t.worker;
            emit TaskPaid(taskId, payee, t.payment);
        } else {
            t.state = State.Refunded;
            payee = t.requester;
            emit TaskRefunded(taskId, payee, t.payment);
        }
        emit FeePaid(taskId, verifier, verifierFee);

        token.safeTransfer(payee, t.payment);
        token.safeTransfer(verifier, verifierFee);
    }

    /// @notice The verifier gave no verdict in time: the requester takes back the
    ///         payment and the unearned fee. The worker is not paid even if its work was
    ///         good, which is a known limitation of relying on one verifier.
    function verifierTimeout(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        require(msg.sender == t.requester, NotRequester());
        require(block.number > t.deadline, TooEarly());

        uint256 refund = t.payment + verifierFee;
        t.state = State.Refunded;
        emit TaskRefunded(taskId, t.requester, refund);
        token.safeTransfer(t.requester, refund);
    }
}
