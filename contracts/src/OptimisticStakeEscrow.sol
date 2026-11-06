// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowBase} from "./EscrowBase.sol";

/// @title OptimisticStakeEscrow (mechanism B)
/// @notice Nobody judges the work unless somebody objects. The worker locks a bond when
///         it accepts. After it submits, a challenge window opens. If nobody challenges,
///         anyone can finalise and the worker gets the payment and its bond back. If
///         somebody challenges, they lock an equal bond and a fixed arbiter decides:
///         the winner takes both bonds, and the payment goes to the worker (challenge
///         rejected) or back to the requester (challenge upheld).
/// @dev    The base contract's reviewWindow is the challenge window here.
contract OptimisticStakeEscrow is EscrowBase {
    using SafeERC20 for IERC20;

    /// @dev 10,000 basis points = 100%.
    uint256 public constant BPS = 10_000;

    /// @notice The only address allowed to resolve a dispute.
    address public immutable arbiter;
    /// @notice Size of a bond as a share of the task payment, in basis points.
    ///         The worker's bond and the challenger's bond are the same amount.
    uint256 public immutable bondBps;
    /// @notice Blocks the arbiter has to resolve a dispute after a challenge.
    uint256 public immutable arbiterWindow;

    /// @notice Who challenged each disputed task. One challenger per task.
    mapping(uint256 taskId => address) public challengerOf;

    event TaskChallenged(uint256 indexed taskId, address indexed challenger);

    error NotArbiter();
    error WorkerCannotChallenge();

    constructor(
        IERC20 token_,
        uint256 acceptWindow_,
        uint256 submitWindow_,
        uint256 challengeWindow_,
        uint256 arbiterWindow_,
        address arbiter_,
        uint256 bondBps_
    ) EscrowBase(token_, acceptWindow_, submitWindow_, challengeWindow_) {
        require(arbiter_ != address(0), ZeroAddress());
        arbiter = arbiter_;
        bondBps = bondBps_;
        arbiterWindow = arbiterWindow_;
    }

    /// @notice The bond for a task of this payment. The worker locks it in acceptTask and
    ///         a challenger locks the same amount in challenge. Division rounds down, so
    ///         a very small payment can have a bond of zero.
    function workerBond(uint256 payment) public view override returns (uint256) {
        return payment * bondBps / BPS;
    }

    /// @notice Anyone except the task's worker disputes a submitted result inside the
    ///         challenge window by locking a bond. The challenger must have approved
    ///         this contract for workerBond(payment).
    function challenge(uint256 taskId) external {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        // A faulty worker could otherwise challenge itself first, which blocks every
        // real challenger and gets its own bond back whatever the arbiter decides.
        require(msg.sender != t.worker, WorkerCannotChallenge());
        require(block.number <= t.deadline, TooLate());

        t.state = State.Disputed;
        t.deadline = block.number + arbiterWindow;
        challengerOf[taskId] = msg.sender;
        emit TaskChallenged(taskId, msg.sender);

        uint256 bond = workerBond(t.payment);
        if (bond > 0) {
            token.safeTransferFrom(msg.sender, address(this), bond);
        }
    }

    /// @notice Nobody challenged in time: anyone may finalise. The worker receives the
    ///         payment and gets its bond back.
    function finalize(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Submitted, WrongState());
        require(block.number > t.deadline, TooEarly());

        uint256 bond = workerBond(t.payment);
        t.state = State.Paid;
        emit TaskPaid(taskId, t.worker, t.payment);
        emit BondPaid(taskId, t.worker, bond);
        token.safeTransfer(t.worker, t.payment + bond);
    }

    /// @notice The arbiter settles a dispute. The loser's bond is slashed: the winner
    ///         gets its own bond back plus the loser's bond.
    /// @param workerWins true  = challenge rejected: the worker is paid.
    ///                   false = challenge upheld: the requester is refunded.
    function resolve(uint256 taskId, bool workerWins) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Disputed, WrongState());
        require(msg.sender == arbiter, NotArbiter());
        require(block.number <= t.deadline, TooLate());

        // The worker's bond and the challenger's bond are both held by this contract.
        uint256 bothBonds = 2 * workerBond(t.payment);
        if (workerWins) {
            t.state = State.Paid;
            emit TaskPaid(taskId, t.worker, t.payment);
            emit BondPaid(taskId, t.worker, bothBonds);
            token.safeTransfer(t.worker, t.payment + bothBonds);
        } else {
            address challenger = challengerOf[taskId];
            t.state = State.Refunded;
            emit TaskRefunded(taskId, t.requester, t.payment);
            emit BondPaid(taskId, challenger, bothBonds);
            token.safeTransfer(t.requester, t.payment);
            token.safeTransfer(challenger, bothBonds);
        }
    }

    /// @notice The arbiter did not resolve the dispute in time: anyone may cancel it.
    ///         Nobody is slashed and every deposit goes back to the party that made it.
    ///         The worker is not paid even if its work was good, which is a known
    ///         limitation of relying on one arbiter.
    function arbiterTimeout(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Disputed, WrongState());
        require(block.number > t.deadline, TooEarly());

        uint256 bond = workerBond(t.payment);
        address challenger = challengerOf[taskId];
        t.state = State.Refunded;
        emit TaskRefunded(taskId, t.requester, t.payment);
        emit BondPaid(taskId, t.worker, bond);
        emit BondPaid(taskId, challenger, bond);
        token.safeTransfer(t.requester, t.payment);
        token.safeTransfer(t.worker, bond);
        token.safeTransfer(challenger, bond);
    }
}
