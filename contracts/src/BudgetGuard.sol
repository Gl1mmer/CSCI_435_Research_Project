// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EscrowBase} from "./EscrowBase.sol";
import {RequesterApproveEscrow} from "./RequesterApproveEscrow.sol";
import {VerifierAttestedEscrow} from "./VerifierAttestedEscrow.sol";

/// @title BudgetGuard
/// @notice A wallet for an orchestrating agent with spending limits enforced on-chain.
///         The guard holds the tokens. The orchestrator's key can only spend them by
///         creating tasks, and only within three limits: the escrow must be on an
///         allowlist, one task may not lock more than `perTaskCap`, and all tasks
///         created in one epoch may not lock more than `epochBudget`.
/// @dev    Two keys. The owner is meant to be kept offline: it sets the allowlist and
///         withdraws funds. The orchestrator is the agent's everyday key and is the one
///         assumed to be at risk. If it is stolen, the thief can lock at most
///         `epochBudget` per epoch instead of taking the whole balance.
///
///         The guard itself becomes the requester of every task it creates, so the
///         requester's functions of the escrows are forwarded through the guard and
///         every refund returns to the guard.
contract BudgetGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable owner;
    address public immutable orchestrator;
    /// @notice The most one task may lock, counting the verifier fee in mechanism C.
    uint256 public immutable perTaskCap;
    /// @notice The most that all tasks created in one epoch may lock in total.
    uint256 public immutable epochBudget;
    /// @notice Length of an epoch in blocks. Epoch number = block.number / epochLength.
    uint256 public immutable epochLength;

    mapping(address escrow => bool) public allowedEscrow;
    /// @notice The epoch in which the guard last created a task.
    uint256 public currentEpoch;
    /// @notice What the tasks created in `currentEpoch` have locked so far.
    uint256 public spentInEpoch;

    event EscrowAllowed(address indexed escrow, bool allowed);
    /// @dev The task id is in the escrow's TaskCreated event of the same transaction.
    event Spent(address indexed escrow, uint256 amount, uint256 epoch);
    event Withdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroEpochLength();
    error NotOwner();
    error NotOrchestrator();
    error EscrowNotAllowed();
    error OverTaskCap();
    error OverEpochBudget();

    modifier onlyOwner() {
        require(msg.sender == owner, NotOwner());
        _;
    }

    modifier onlyOrchestrator() {
        require(msg.sender == orchestrator, NotOrchestrator());
        _;
    }

    modifier onlyAllowed(address escrow) {
        require(allowedEscrow[escrow], EscrowNotAllowed());
        _;
    }

    constructor(
        IERC20 token_,
        address owner_,
        address orchestrator_,
        uint256 perTaskCap_,
        uint256 epochBudget_,
        uint256 epochLength_
    ) {
        require(address(token_) != address(0) && owner_ != address(0) && orchestrator_ != address(0), ZeroAddress());
        // The epoch number is block.number / epochLength, so the length cannot be zero.
        require(epochLength_ > 0, ZeroEpochLength());
        token = token_;
        owner = owner_;
        orchestrator = orchestrator_;
        perTaskCap = perTaskCap_;
        epochBudget = epochBudget_;
        epochLength = epochLength_;
    }

    // ------------------------------------------------------------------ owner

    /// @notice Adds an escrow contract to the allowlist or removes it.
    function setEscrowAllowed(address escrow, bool allowed) external onlyOwner {
        allowedEscrow[escrow] = allowed;
        emit EscrowAllowed(escrow, allowed);
    }

    /// @notice The owner takes tokens out of the guard. To fund the guard, anyone can
    ///         simply transfer tokens to its address.
    function withdraw(uint256 amount) external onlyOwner {
        emit Withdrawn(owner, amount);
        token.safeTransfer(owner, amount);
    }

    // ----------------------------------------------------------- orchestrator

    /// @notice Creates a task on an allowed escrow, paid from the guard's balance, if
    ///         it fits the per-task cap and what is left of this epoch's budget.
    function createTask(EscrowBase escrow, address worker, uint256 payment)
        external
        onlyOrchestrator
        onlyAllowed(address(escrow))
        returns (uint256 taskId)
    {
        // What the escrow will pull: the payment, plus the verifier fee in mechanism C.
        uint256 deposit = escrow.requesterDeposit(payment);
        require(deposit <= perTaskCap, OverTaskCap());

        uint256 epoch = block.number / epochLength;
        if (epoch != currentEpoch) {
            // A new epoch has started, so the whole budget is available again.
            currentEpoch = epoch;
            spentInEpoch = 0;
        }
        require(spentInEpoch + deposit <= epochBudget, OverEpochBudget());
        spentInEpoch += deposit;
        emit Spent(address(escrow), deposit, epoch);

        // Approve exactly this deposit. createTask pulls all of it, so the escrow is
        // never left with an allowance it could use later.
        token.forceApprove(address(escrow), deposit);
        taskId = escrow.createTask(worker, payment);
    }

    // The guard is the requester of its tasks, so only the guard can call the escrow
    // functions reserved for the requester. These four forward them unchanged. None of
    // them can move tokens out of the guard: a refund comes back to the guard.

    /// @notice Mechanisms A, C and B: take the deposit back after the worker missed a window.
    function reclaim(EscrowBase escrow, uint256 taskId) external onlyOrchestrator onlyAllowed(address(escrow)) {
        escrow.reclaim(taskId);
    }

    /// @notice Mechanism A: accept the result.
    function approve(RequesterApproveEscrow escrow, uint256 taskId)
        external
        onlyOrchestrator
        onlyAllowed(address(escrow))
    {
        escrow.approve(taskId);
    }

    /// @notice Mechanism A: refuse the result.
    function reject(RequesterApproveEscrow escrow, uint256 taskId)
        external
        onlyOrchestrator
        onlyAllowed(address(escrow))
    {
        escrow.reject(taskId);
    }

    /// @notice Mechanism C: take payment and fee back after the verifier stayed silent.
    function verifierTimeout(VerifierAttestedEscrow escrow, uint256 taskId)
        external
        onlyOrchestrator
        onlyAllowed(address(escrow))
    {
        escrow.verifierTimeout(taskId);
    }
}
