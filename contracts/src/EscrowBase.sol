// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title EscrowBase
/// @notice The part of the task life-cycle that all three settlement mechanisms share:
///         a requester creates a task and locks the payment, the worker accepts it and
///         submits a result hash, and the requester takes the money back if the worker
///         misses a deadline. How a submitted task is settled is decided by the contract
///         that inherits from this one.
/// @dev    Time is counted in block numbers only. Each task has one `deadline`: the last
///         block in which the next expected step may happen. An action is allowed while
///         `block.number <= deadline`; a timeout function is allowed once
///         `block.number > deadline`.
abstract contract EscrowBase is ReentrancyGuard {
    // SafeERC20 reverts when a token transfer fails instead of returning false silently.
    using SafeERC20 for IERC20;

    /// @dev None is first so that a task id that was never created reads as None and
    ///      every function rejects it. Paid and Refunded are terminal: no function
    ///      accepts a task in either state, so a task can never be settled twice.
    enum State {
        None,
        Created,
        Accepted,
        Submitted,
        Disputed, // used by the optimistic-stake mechanism only
        Paid,
        Refunded
    }

    struct Task {
        address requester;
        State state; // one byte, stored in the same slot as `requester` to save gas
        address worker;
        uint256 payment;
        bytes32 resultHash; // hash of the off-chain result; the result itself is never on-chain
        uint256 deadline; // last block in which the next expected step may happen
    }

    /// @notice The ERC-20 token all payments, fees and bonds are made in.
    IERC20 public immutable token;
    /// @notice Blocks the worker has to accept a task after it is created.
    uint256 public immutable acceptWindow;
    /// @notice Blocks the worker has to submit a result after accepting.
    uint256 public immutable submitWindow;
    /// @notice Blocks in which a submitted result can be judged: approve or reject in A,
    ///         attest in C, challenge in B.
    uint256 public immutable reviewWindow;

    /// @notice Number of tasks created so far. Task ids run from 1 to taskCount.
    uint256 public taskCount;
    mapping(uint256 taskId => Task) public tasks;

    event TaskCreated(uint256 indexed taskId, address indexed requester, address indexed worker, uint256 payment);
    event TaskAccepted(uint256 indexed taskId);
    event ResultSubmitted(uint256 indexed taskId, bytes32 resultHash);
    /// @dev Emitted exactly once for a task that ends in Paid. `amount` is the payment.
    event TaskPaid(uint256 indexed taskId, address indexed to, uint256 amount);
    /// @dev Emitted exactly once for a task that ends in Refunded. `amount` is what the
    ///      requester gets back of its own deposit.
    event TaskRefunded(uint256 indexed taskId, address indexed to, uint256 amount);
    /// @dev Bonds exist in the optimistic-stake mechanism only; A and C never emit this.
    event BondPaid(uint256 indexed taskId, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroPayment();
    error WrongState();
    error NotRequester();
    error NotWorker();
    error TooEarly();
    error TooLate();

    constructor(IERC20 token_, uint256 acceptWindow_, uint256 submitWindow_, uint256 reviewWindow_) {
        require(address(token_) != address(0), ZeroAddress());
        token = token_;
        acceptWindow = acceptWindow_;
        submitWindow = submitWindow_;
        reviewWindow = reviewWindow_;
    }

    /// @notice Tokens the requester must approve and lock to create a task with this
    ///         payment. It is the payment itself; mechanism C adds the verifier fee.
    function requesterDeposit(uint256 payment) public view virtual returns (uint256) {
        return payment;
    }

    /// @notice Tokens the worker must approve and lock to accept a task with this
    ///         payment. Zero here; mechanism B overrides it with the worker bond.
    function workerBond(
        uint256 /* payment */
    )
        public
        view
        virtual
        returns (uint256)
    {
        return 0;
    }

    /// @notice The requester creates a task for one named worker and locks the deposit.
    ///         The requester must have approved this contract for requesterDeposit(payment).
    function createTask(address worker, uint256 payment) external returns (uint256 taskId) {
        require(worker != address(0), ZeroAddress());
        require(payment > 0, ZeroPayment());

        // Pre-increment, so the first id is 1 and id 0 always means "no such task".
        taskId = ++taskCount;
        tasks[taskId] = Task({
            requester: msg.sender,
            state: State.Created,
            worker: worker,
            payment: payment,
            resultHash: bytes32(0),
            deadline: block.number + acceptWindow
        });
        emit TaskCreated(taskId, msg.sender, worker, payment);

        // State is written before the token is called (checks-effects-interactions).
        token.safeTransferFrom(msg.sender, address(this), requesterDeposit(payment));
    }

    /// @notice The named worker accepts the task within the accept window.
    ///         In mechanism B this also locks the worker's bond.
    function acceptTask(uint256 taskId) external {
        Task storage t = tasks[taskId];
        require(t.state == State.Created, WrongState());
        require(msg.sender == t.worker, NotWorker());
        require(block.number <= t.deadline, TooLate());

        t.state = State.Accepted;
        t.deadline = block.number + submitWindow;
        emit TaskAccepted(taskId);

        uint256 bond = workerBond(t.payment);
        if (bond > 0) {
            token.safeTransferFrom(msg.sender, address(this), bond);
        }
    }

    /// @notice The worker submits the hash of its result within the submit window.
    function submitResult(uint256 taskId, bytes32 resultHash) external {
        Task storage t = tasks[taskId];
        require(t.state == State.Accepted, WrongState());
        require(msg.sender == t.worker, NotWorker());
        require(block.number <= t.deadline, TooLate());

        t.state = State.Submitted;
        t.resultHash = resultHash;
        t.deadline = block.number + reviewWindow;
        emit ResultSubmitted(taskId, resultHash);
    }

    /// @notice The requester takes its deposit back when the worker never accepted, or
    ///         accepted and never submitted. In mechanism B a worker that accepted and
    ///         did not deliver also loses its bond to the requester.
    function reclaim(uint256 taskId) external nonReentrant {
        Task storage t = tasks[taskId];
        require(t.state == State.Created || t.state == State.Accepted, WrongState());
        require(msg.sender == t.requester, NotRequester());
        require(block.number > t.deadline, TooEarly());

        uint256 refund = requesterDeposit(t.payment);
        // A bond was locked only if the worker got as far as accepting.
        uint256 bond = t.state == State.Accepted ? workerBond(t.payment) : 0;

        t.state = State.Refunded;
        emit TaskRefunded(taskId, t.requester, refund);
        if (bond > 0) {
            emit BondPaid(taskId, t.requester, bond);
        }

        token.safeTransfer(t.requester, refund + bond);
    }
}
