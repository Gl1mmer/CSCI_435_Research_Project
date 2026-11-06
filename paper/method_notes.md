# Notes for the method section: the contracts

Facts about the on-chain part of the testbed, for the team to write the method and
limitations sections from. These are notes, not paper text. Every number here comes
from a command in this repository; the command is named next to it. Measured on
2026-11-06.

Details of every function and event: `docs/DESIGN.md`. Slither: `docs/slither-report.md`.

## 1. Toolchain

| Item | Version or value |
|------|------------------|
| Solidity compiler | 0.8.30, optimizer on, 200 runs, EVM version cancun |
| Foundry (forge, anvil, cast) | 1.9.0 |
| OpenZeppelin Contracts | 5.7.0 (`ERC20`, `SafeERC20`, `ReentrancyGuard`) |
| forge-std | 1.17.0 (tests and scripts only) |
| Slither | 0.11.6 |
| Chain for measurements | local Anvil, chain id 31337, one block per transaction |

All versions are pinned in `contracts/foundry.toml` and `contracts/soldeer.lock`.

## 2. Contracts

| Contract | Lines | Role |
|----------|------:|------|
| `MockUSD` | 22 | ERC-20 test token, 6 decimals, open mint |
| `EscrowBase` | 178 | shared task life-cycle: create, accept, submit, reclaim |
| `RequesterApproveEscrow` | 57 | mechanism A |
| `VerifierAttestedEscrow` | 84 | mechanism C |
| `OptimisticStakeEscrow` | 142 | mechanism B |
| `BudgetGuard` | 170 | spending limits for SQ3 |

Line counts include comments (`wc -l contracts/src/*.sol`, 653 in total). The three
mechanisms inherit the same base, so they differ only in how a submitted task is settled.

## 3. Task life-cycle

States: `Created → Accepted → Submitted → Paid | Refunded`, and `Disputed` between
`Submitted` and the end in mechanism B only. `Paid` and `Refunded` are terminal.

- The requester creates a task for one named worker and locks the payment in the escrow.
- The worker accepts within the accept window, then submits a 32-byte hash of its
  result within the submit window. The result itself stays off-chain.
- If the worker misses either window, the requester reclaims its deposit (`Refunded`).
- A submitted task is settled by the mechanism (section 4).

Time is counted in block numbers only. Each task has one deadline, reset at every step.
An action is valid in blocks up to and including the deadline; the matching timeout
function is valid from the next block. So at any block exactly one of the two is possible.

The contract never sees whether a result is correct. Correctness exists only in the
experiment runner, which decides how each agent acts.

## 4. Settlement rules

### A, requester-approve (baseline)

- Within the review window the requester calls `approve` (worker paid) or `reject`
  (requester refunded). A rejection needs no justification.
- After the review window neither is possible and the worker calls `claimAfterTimeout`
  (worker paid).

### C, verifier-attested

- One verifier address is fixed when the contract is deployed.
- The requester locks a flat verifier fee together with the payment.
- Within the review window the verifier calls `attest(pass)`: pass pays the worker,
  fail refunds the payment to the requester. The verifier receives the fee either way.
- After the review window the requester calls `verifierTimeout` and gets payment and
  fee back.
- If the worker missed a window, `reclaim` returns payment and fee.

### B, optimistic stake

- The worker locks a bond when it accepts. Bond = payment × `bondBps` / 10,000, rounded down.
- After submission a challenge window opens. Anyone except the task's worker can
  `challenge` by locking a bond of the same size. One challenge per task.
- No challenge in the window: anyone calls `finalize`; the worker gets the payment and
  its bond back.
- Challenge: a fixed arbiter calls `resolve` within the arbiter window.
  - Challenge rejected: worker gets the payment and both bonds.
  - Challenge upheld: requester gets the payment back, challenger gets both bonds.
- Arbiter silent past its window: anyone calls `arbiterTimeout`; the payment returns to
  the requester and each bond to the party that locked it.
- A worker that accepted and never submitted loses its bond to the requester in `reclaim`.

## 5. Parameters

All are constructor arguments, fixed for the life of a deployment.

| Parameter | Mechanisms | Meaning | Default in `Deploy.s.sol` |
|-----------|------------|---------|---------------------------|
| accept window | A, C, B | blocks to accept after creation | 5 |
| submit window | A, C, B | blocks to submit after accepting | 5 |
| review window | A, C | blocks to approve, reject or attest after submission | 5 |
| challenge window | B | blocks to challenge after submission | 5 |
| arbiter window | B | blocks to resolve after a challenge | 5 |
| verifier | C | the attesting address | Anvil account 3 |
| verifier fee | C | flat fee per task | 10,000 units (0.01 mUSD) |
| arbiter | B | the resolving address | Anvil account 4 |
| bond | B | share of the payment, in basis points | 1,000 (10%) |

The defaults are placeholders for local runs. The values used in the experiments are
chosen by the runner and must be reported with the results.

Amounts are in units of a 6-decimal token: 1 mUSD = 1,000,000 units.

## 6. BudgetGuard (SQ3)

- Holds the orchestrator's tokens. Two keys: an owner (allowlist, withdrawals) and an
  orchestrator (creates tasks, acts as their requester).
- A task is created only if the escrow is on the allowlist, the task locks at most
  `perTaskCap`, and the tasks of the current epoch lock at most `epochBudget` in total.
  An epoch is a fixed number of blocks.
- What counts against both limits is the amount that leaves the guard: the payment,
  plus the verifier fee in C. Refunds return to the guard but do not restore budget
  within the epoch.
- The guard is the requester of its tasks and forwards `approve`, `reject`, `reclaim`
  and `verifierTimeout`.
- A stolen orchestrator key can still lock, and in mechanism A pay out, up to
  `epochBudget` per epoch. Without the guard it could move the whole balance at once.

## 7. Tests

Run with `forge test` in `contracts/`; it reports 140 tests, all passing, on Windows 11
and in the Linux container `ghcr.io/foundry-rs/foundry:v1.9.0`.

| Kind | Count | What they cover |
|------|------:|-----------------|
| unit | 119 | every settlement path, every forbidden transition, every wrong caller, the first and last block of every window, events, the two re-entrancy attacks |
| fuzz | 18 | random payments, fees and bond sizes; random window lengths and delays; random call order on one task; guard spending never above the budget |
| invariant | 9 | 3 properties × 3 mechanisms (forge counts them as 3 tests) |

Unit tests per contract: `MockUSD` 4, A (and the base) 38, C 21, B 31, `BudgetGuard` 23
plus 1 fuzz, re-entrancy 2.

Fuzz settings: 500 runs per test, fixed seed `0x435` (`contracts/foundry.toml`).

Invariant settings: per mechanism 50 runs of 100 random calls (5,000 calls), made
through a handler that picks an existing task and the right caller, with up to 8 tasks
per run among 3 accounts and windows of 6 blocks. Checked after every call:

1. **Escrow balance equals open deposits.** The escrow's token balance equals the sum,
   over all unsettled tasks, of payment, fee and bonds locked for that task.
2. **A task is settled at most once and stays settled.** A `Paid` task has emitted
   exactly one `TaskPaid` and no `TaskRefunded`; a `Refunded` task the opposite; an open
   task neither.
3. **No token leaves the system.** Escrow balance plus the balances of all participants
   equals the total supply.

## 8. Static analysis

Slither 0.11.6 on all six contracts: 18 results, all informational, all in
OpenZeppelin's code (inline assembly, version pragmas). None in the project's
contracts, so nothing was changed.

A limit of that result: Slither's re-entrancy detectors do not see token calls made
through `SafeERC20`, because OpenZeppelin 5.7 makes them in inline assembly. A bug
planted to check this was reported when the call was a plain `token.transfer` and not
reported with `safeTransfer`. Re-entrancy is therefore covered by the code order (state
and events before token calls), by `nonReentrant` on every function that pays out, and
by `contracts/test/Reentrancy.t.sol`.

## 9. Gas

Real transactions on a fresh Anvil chain, from `contracts/script/gas_one_task.sh`
(payment 1 mUSD, fee 0.01 mUSD, bond 10%, windows 5 blocks):

| Scenario | Transactions (gas) | Total |
|----------|--------------------|------:|
| A, approved | createTask 176,296; acceptTask 35,163; submitResult 58,071; approve 48,723 | 318,253 |
| C, passed | createTask 176,416; acceptTask 35,185; submitResult 58,071; attest 76,128 | 345,800 |
| B, not challenged | createTask 176,296; acceptTask 58,955; submitResult 58,160; finalize 50,950 | 344,361 |
| B, challenge upheld | createTask 159,196; acceptTask 58,955; submitResult 58,160; challenge 81,514; resolve 59,612 | 417,437 |

`createTask` on escrow A through the `BudgetGuard`, same script: 159,196 direct;
192,704 for the guard's first task (+33,508); 175,604 for its next task (+16,408).

Deployment, from the walk-through in the README: `MockUSD` 507,896;
`RequesterApproveEscrow` 911,455; `VerifierAttestedEscrow` 1,010,761;
`OptimisticStakeEscrow` 1,248,718; `BudgetGuard` 774,223.

These are single examples. Gas for the same call changes with the state of storage:
writing a zero slot for the first time costs about 17,000 gas more than updating it,
and emptying a slot gives a refund. In the table, the three `createTask` calls at about
176,000 are each the first task on their escrow and the one at 159,196 is a second
task. The per-task gas reported in the paper must come from the experiment runner,
which records every transaction of every task.

Gas of the remaining functions (`reject`, `claimAfterTimeout`, `reclaim`,
`verifierTimeout`, `arbiterTimeout`, the guard's forwarded calls) is printed by
`forge test --gas-report`. `contracts/.gas-snapshot` records the gas of every test and
`forge snapshot --check` verifies it; the Windows and Linux runs give identical values.

## 10. Limitations the contracts impose

- **One trusted arbiter (B).** The contract cannot check its decision. The experiment
  assumes it is always correct.
- **One fixed verifier (C).** No choice among verifiers, no appeal against a verdict.
- **Silent verifier or arbiter.** The payment returns to the requester, so an honest
  worker is not paid. This counts as an honest-party loss when it happens.
- **Free rejection (A).** By design: it is the free-riding the experiment measures.
- **Self-challenge through a second address (B).** The task's worker cannot challenge
  from its own address, but can from another one. If it does so first, it gets its own
  bond back when the challenge is upheld, and other challengers are shut out because
  only one challenge per task is possible.
- **Zero bond on very small payments (B).** The bond is rounded down; with 10% it is
  zero for payments under 10 units, and a challenge is then free.
- **Per-contract windows.** Every task of a deployment has the same windows. The SRS
  (FR-01) asked for a deadline chosen per task.
- **No partial payment, no multi-worker tasks, one level of delegation.**
- **Verifier, arbiter and task parties are not required to be different addresses.**
  The experiment uses separate addresses.
- **Test token.** `MockUSD` can be minted by anyone; the escrows themselves work with
  any standard ERC-20, but fee-on-transfer or rebasing tokens are not supported.
- **Guard.** It bounds a loss, it does not prevent one; its limits cannot be changed
  after deployment; it does not post challenger bonds in B.
- **Local chain.** Anvil mines one block per transaction and has no competing
  transactions, so nothing here says anything about latency or ordering on a public chain.
