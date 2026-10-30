# Software Requirements Specification
**Project:** Decentralized Payments and Coordination for Agent Economies  
**Version:** 1.0 — Pre-Implementation Draft  
**Status:** Proposed for Supervisor Review  
**Current Stage:** Week 11

## 1. Project Objective

The objective is to develop a prototype that enables AI agents to delegate tasks and settle payments through Ethereum smart contracts.

The system will compare three settlement mechanisms:

- **Mechanism A — Requester-Approve:** The requester approves or rejects submitted work.
- **Mechanism C — Verifier-Attested:** An independent verifier evaluates the work and authorizes settlement.
- **Mechanism B — Optimistic-Stake:** Workers deposit collateral, and submitted work can be challenged before payment.

The research will evaluate wrongful payments, honest-party losses, gas consumption, and settlement latency.

## 2. System Architecture

**Required by Proposal**

The system shall contain:

1. **Requester Agent:** Creates tasks, assigns payments, and hires workers.
2. **Worker Agent:** Accepts tasks and submits results.
3. **Verifier Agent:** Evaluates submitted work.
4. **Challenger Agent:** Identifies potentially incorrect work and initiates disputes.
5. **Smart Contracts:** Manage escrow funds, task states, settlement, and disputes.
6. **Experiment Runner:** Executes predefined scenarios and collects measurements.

**Technology Stack**

- Solidity — smart contracts
- Foundry — compilation and testing
- Anvil — local Ethereum blockchain
- OpenZeppelin — standard contract libraries
- Python and web3.py — agents and blockchain interactions
- Mock ERC-20 — test payments
- pandas and matplotlib — analysis and visualizations

## 3. Functional Requirements

### FR-01: Task Creation

The system shall allow a requester to:

- Create a task with a unique identifier.
- Specify the worker and payment amount.
- Specify a completion deadline.
- Lock payment tokens in escrow.

**Acceptance criterion:** A task is recorded on-chain, and the corresponding funds are held by the contract.

### FR-02: Task Lifecycle

**Required by Proposal**

A task shall follow these main states:

`CREATED → ACCEPTED → SUBMITTED → PAID / REFUNDED`

**Proposed Design Decision**

Additional states may include:

- `DISPUTED` — a submitted result has been challenged.
- `EXPIRED` — a deadline has passed without required action.

The contract shall prevent invalid state transitions.

**Acceptance criterion:** No task can be settled twice or moved from a terminal state back to an active state.

### FR-03: Requester-Approve Settlement

The contract shall:

1. Lock the requester’s payment.
2. Allow the worker to submit a result.
3. Allow the requester to approve or reject the work.
4. Release payment when approved.
5. Allow the worker to claim payment if the requester remains silent beyond the specified deadline.

**Design decision to finalize:** The exact timeout and conditions for rejection and refund.

### FR-04: Verifier-Attested Settlement

The contract shall:

1. Assign an authorized verifier.
2. Accept a verifier decision after work submission.
3. Release payment after approval.
4. Refund the requester after rejection.
5. Account for the verifier fee.

**Acceptance criterion:** Only the authorized verifier may submit a valid verification decision.

### FR-05: Optimistic-Stake Settlement

The contract shall:

1. Require the worker to deposit collateral.
2. Open a challenge window after submission.
3. Allow eligible challengers to dispute a result.
4. Use an authorized arbiter to resolve disputes.
5. Release payment if no challenge succeeds.
6. Apply the defined slashing rules to the losing party.

**Design decisions to finalize:**

- Stake amount
- Challenge duration
- Challenger eligibility and reward
- Dispute-bond requirements
- Distribution of slashed collateral

### FR-06: Timeout and Missing-Agent Handling

**Proposed Design Detail**

The system shall provide timeout rules for:

- Workers who never accept a task.
- Workers who accept but never submit work.
- Requesters who do not respond.
- Verifiers who fail to provide a decision.

Each timeout shall produce a defined settlement outcome or a clearly specified recovery path.

**Acceptance criterion:** No funds remain permanently inaccessible solely because an agent stops responding, assuming authorized settlement transactions can eventually be submitted.

### FR-07: Agent Simulation

**Required by Proposal**

The experiment shall simulate:

- Honest workers
- Lazy workers
- Plausible-but-wrong workers
- Absent workers
- Honest requesters
- Free-riding requesters

Worker behavior and verifier error rates shall be configurable.

### FR-08: Ground Truth and Verification

The system shall use a dataset containing tasks with independently established correct outcomes.

Approximately 150 labeled tasks shall be used to evaluate one real LLM judge.

The evaluation shall measure:

- False Accept Rate
- False Reject Rate

LLM decisions shall be cached for reproducibility.

**Acceptance criterion:** Verifier predictions can be compared with independent ground-truth labels.

### FR-09: Gas Measurement

For each task, the experiment runner shall record gas consumed by all included settlement-related transactions.

**Proposed Design Detail**

Reports shall distinguish gas costs paid by:

- Requester
- Worker
- Verifier
- Challenger
- Arbiter

The accounting method shall explicitly state whether failed and reverted transactions are included.

### FR-10: Experiment Execution

**Required by Proposal**

The full experimental design shall include:

- 3 settlement mechanisms
- 6 faulty-worker proportions between 0% and 50%
- 4 verifier-accuracy settings
- 10 random seeds
- 200 tasks per run

This corresponds to 144,000 simulated task executions.

All experiments shall use recorded random seeds and reproducible configurations.

### FR-11: Metrics and Reporting

The system shall calculate:

**Wrongful-Payment Rate**

Paid faulty tasks / All faulty tasks

**Honest-Loss Rate**

Unpaid honest tasks / All honest tasks

**Gas per Settled Task**

Total gas consumed by included task transactions.

**Blocks to Finality**

Blocks elapsed between task creation and its final settlement transaction, excluding underlying probabilistic chain finality.

Results shall include means and 95% confidence intervals across experimental seeds.

### FR-12: BudgetGuard (Optional)

The proposed BudgetGuard shall:

- Enforce a maximum payment per task.
- Enforce a spending limit per epoch.
- Restrict spending to approved escrow contracts.

The experiment shall compare compromised-orchestrator losses with and without the guard, if time permits.

## 4. Security Requirements

### SR-01: No Double Payment

A task must never release the same escrow payment more than once.

### SR-02: Token Conservation

All token movements shall be accounted for across escrow balances, payouts, refunds, fees, bonds, and penalties.

### SR-03: Access Control

Only authorized participants may execute restricted operations.

### SR-04: Deadline Enforcement

Settlements and challenges must respect their configured block deadlines.

### SR-05: Safe Token Transfers

Contracts shall use appropriate ERC-20 transfer protections and tested libraries.

### SR-06: Dispute Integrity

An unauthorized agent must not be able to resolve a dispute or withdraw another participant's collateral.

## 5. Non-Functional Requirements

### NFR-01: Reproducibility

All experiments must be reproducible using documented commands, dependencies, seeds, and configurations.

### NFR-02: Testability

Contracts shall include unit tests, fuzz tests, and invariant tests using Foundry.

### NFR-03: Static Analysis

Solidity contracts shall be analyzed using Slither.

### NFR-04: Data Collection

Experiment outputs shall be stored in machine-readable formats such as CSV or JSON.

### NFR-05: Documentation

The GitHub repository shall contain:

- README with exact installation and execution instructions
- Source code
- Contract tests
- Experiment scripts
- Data or data-generation instructions
- Scripts to regenerate figures
- Fixed dependency versions
- Licensing and attribution information

### NFR-06: Public Testnet Validation

Approximately 30 tasks per mechanism shall be repeated on Sepolia, if the primary implementation is completed.

Measurements shall distinguish local-chain results from public-testnet results.

## 6. Research Validation

The evaluation shall use comparable task scenarios across settlement mechanisms.

Experiments shall investigate:

1. Increasing faulty-worker proportions.
2. Different verifier error rates.
3. Gas costs per settled task.
4. Honest-party losses.
5. Challenge profitability.
6. Settlement latency.

An analytical model shall be used as an independent consistency check against experimental results.

Negative results must be reported without modification.

## 7. Implementation Priorities

**Priority 1 — Minimum Working Prototype**

- Mock ERC-20
- Basic escrow contract
- Task creation and submission
- Requester approval and payment
- Refund and timeout handling
- Python transaction client
- Gas measurement

**Priority 2 — Core Comparison**

- Verifier-attested settlement
- Verifier error simulation
- Automated experiment runner
- Wrongful-payment and honest-loss analysis
- Baseline comparison
- Reproducible figures

**Priority 3 — Extended Evaluation**

- Optimistic-stake settlement
- Dispute handling and collateral
- Challenger economic incentives
- Full experimental parameter grid
- Sepolia validation

**Priority 4 — Optional**

- BudgetGuard
- Compromised-orchestrator scenarios
- Additional adversarial conditions

## 8. Open Technical Decisions

The following parameters require finalization before implementation:

1. Task data representation: on-chain storage versus off-chain results with on-chain hashes.
2. Exact deadlines for task submission, approval, and challenges.
3. Stake amounts and challenger rewards.
4. Verifier fee model.
5. Gas accounting boundaries and fee-payer responsibilities.
6. Ground-truth dataset selection and labeling method.
7. Handling of unavailable verifiers and arbiters.
8. Minimum viable experimental scope under the remaining course schedule.

## 9. Immediate Milestone — Week 11

The team shall aim to deliver:

- An initialized GitHub repository.
- One compiled escrow contract.
- A successful local task-payment transaction.
- A successful timeout or rejection test.
- The first recorded gas measurement.
- Documentation of remaining unresolved design decisions.

The full comparison and experimental results remain subsequent milestones.
