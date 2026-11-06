# Contract design

What the escrow contracts do, how to call them, and why they are built this way.
Written so that the Python side can drive the contracts with web3.py without reading
the Solidity.

Status: mechanisms A (`RequesterApproveEscrow`) and C (`VerifierAttestedEscrow`) are
implemented. Mechanism B is added on the same base; its section is filled in when the
contract lands.

## 1. Conventions

- **Token.** All amounts are in units of `MockUSD`, an ERC-20 token with 6 decimals.
  1 mUSD = 1,000,000 units, so US$0.001 is 1,000 units. Anyone can call
  `mint(to, amount)`.
- **Time.** Only block numbers, never timestamps. Each task has one `deadline`, the last
  block in which the next expected step may happen. An action (accept, submit, approve,
  reject, attest) works while `block.number <= deadline`. A timeout function (reclaim,
  claimAfterTimeout, verifierTimeout) works once `block.number > deadline`. So a window of 5 set in block
  100 allows the action in blocks 100 to 105 and the timeout from block 106.
- **Task ids** start at 1 and count up by one per contract. `taskCount()` is the latest id.
- **Results stay off-chain.** The contract stores only a `bytes32` hash of the result.
  The contract never knows whether a result is correct; ground truth lives in the runner.
- **One transaction per step and per role.** Every function below is called by exactly
  one role, so the gas of a transaction belongs to that role.

## 2. Life-cycle

```
                 acceptTask            submitResult
   Created ───────────────► Accepted ───────────────► Submitted
      │                        │                          │
      │ reclaim                │ reclaim                  │ settled by the mechanism
      │ (accept window         │ (submit window           │
      │  missed)               │  missed)                 ├──► Paid       worker gets the payment
      ▼                        ▼                          └──► Refunded   requester gets it back
   Refunded                 Refunded
```

`Paid` and `Refunded` are terminal. No function accepts a task in either state, so a
task is settled exactly once.

State numbers, as returned by `tasks(taskId)`:

| Value | State | Meaning |
|-------|-------|---------|
| 0 | None | no task with this id |
| 1 | Created | payment locked, waiting for the worker to accept |
| 2 | Accepted | waiting for the worker to submit |
| 3 | Submitted | result hash stored, waiting for settlement |
| 4 | Disputed | mechanism B only: challenged, waiting for the arbiter |
| 5 | Paid | terminal: the worker received the payment |
| 6 | Refunded | terminal: the requester received the payment back |

## 3. Shared interface (`EscrowBase`)

Every mechanism has these.

### Constructor parameters

| Parameter | Type | Meaning |
|-----------|------|---------|
| `token_` | address | the ERC-20 used for payment; must not be zero |
| `acceptWindow_` | uint256 | blocks the worker has to accept after creation |
| `submitWindow_` | uint256 | blocks the worker has to submit after accepting |
| `reviewWindow_` | uint256 | blocks in which a submitted result can be judged |

All are fixed at deployment and readable through `token()`, `acceptWindow()`,
`submitWindow()`, `reviewWindow()`.

### Functions

| Function | Caller | Allowed when | Effect |
|----------|--------|--------------|--------|
| `createTask(address worker, uint256 payment) → uint256 taskId` | anyone; becomes the requester | `worker != 0`, `payment > 0`, caller approved the escrow for `requesterDeposit(payment)` | pulls the deposit, state `Created`, deadline = now + acceptWindow |
| `acceptTask(uint256 taskId)` | the task's worker | state `Created`, within deadline | state `Accepted`, deadline = now + submitWindow |
| `submitResult(uint256 taskId, bytes32 resultHash)` | the task's worker | state `Accepted`, within deadline | stores the hash, state `Submitted`, deadline = now + reviewWindow |
| `reclaim(uint256 taskId)` | the task's requester | state `Created` or `Accepted`, after deadline | refunds the deposit, state `Refunded` |
| `requesterDeposit(uint256 payment) → uint256` | anyone (view) | always | tokens the requester must approve for a task of this payment |
| `workerBond(uint256 payment) → uint256` | anyone (view) | always | tokens the worker must approve before accepting (0 in A and C) |
| `tasks(uint256 taskId)` | anyone (view) | always | `(requester, state, worker, payment, resultHash, deadline)` |
| `taskCount() → uint256` | anyone (view) | always | number of tasks created |

### Events

| Event | Emitted by | Meaning |
|-------|-----------|---------|
| `TaskCreated(uint256 indexed taskId, address indexed requester, address indexed worker, uint256 payment)` | `createTask` | new task, payment locked |
| `TaskAccepted(uint256 indexed taskId)` | `acceptTask` | |
| `ResultSubmitted(uint256 indexed taskId, bytes32 resultHash)` | `submitResult` | |
| `TaskPaid(uint256 indexed taskId, address indexed to, uint256 amount)` | any settlement that ends in `Paid` | exactly once per paid task; `to` is the worker, `amount` the payment |
| `TaskRefunded(uint256 indexed taskId, address indexed to, uint256 amount)` | any settlement that ends in `Refunded` | exactly once per refunded task; `to` is the requester, `amount` what it gets back of its deposit |
| `BondPaid(uint256 indexed taskId, address indexed to, uint256 amount)` | mechanism B only | a bond leaving the escrow |

Every state change emits an event carrying the task id. The final outcome of a task is
read from whether it emitted `TaskPaid` or `TaskRefunded`.

### Errors

Custom errors, no message strings.

| Error | Raised when |
|-------|-------------|
| `ZeroAddress()` | token or worker is the zero address |
| `ZeroPayment()` | `createTask` with payment 0 |
| `WrongState()` | the task is not in the state the function needs (also for unknown ids) |
| `NotRequester()` / `NotWorker()` / `NotVerifier()` | the caller is not the party this function belongs to |
| `TooLate()` | an action after its deadline |
| `TooEarly()` | a timeout function before the deadline has passed |

The state is checked first, then the caller, then the deadline.

## 4. Mechanism A: `RequesterApproveEscrow`

The requester judges the work. No extra constructor parameters, no fee, no bond.

| Function | Caller | Allowed when | Effect |
|----------|--------|--------------|--------|
| `approve(uint256 taskId)` | requester | `Submitted`, within the review window | pays the worker, `Paid`, emits `TaskPaid` |
| `reject(uint256 taskId)` | requester | `Submitted`, within the review window | refunds the requester, `Refunded`, emits `TaskRefunded` |
| `claimAfterTimeout(uint256 taskId)` | worker | `Submitted`, after the review window | pays the worker, `Paid`, emits `TaskPaid` |

Rejection needs no proof. A free-riding requester can reject correct work and keep
both the result and the money; this is the weakness the experiment measures.

## 5. Mechanism C: `VerifierAttestedEscrow`

One verifier address, fixed at deployment, judges the work and earns a flat fee.

Extra constructor parameters, after the three windows:

| Parameter | Type | Meaning |
|-----------|------|---------|
| `verifier_` | address | the only address that may attest; must not be zero |
| `verifierFee_` | uint256 | flat fee per task in token units; may be 0 |

Readable through `verifier()` and `verifierFee()`.

The requester pays the fee: `requesterDeposit(payment)` returns `payment + verifierFee`,
and `createTask` pulls that amount.

| Function | Caller | Allowed when | Effect |
|----------|--------|--------------|--------|
| `attest(uint256 taskId, bool pass)` | verifier | `Submitted`, within the review window | `pass = true`: pays the worker, `Paid`, emits `TaskPaid`. `pass = false`: refunds the payment to the requester, `Refunded`, emits `TaskRefunded`. Both: sends the fee to the verifier, emits `FeePaid` |
| `verifierTimeout(uint256 taskId)` | requester | `Submitted`, after the review window | refunds payment and fee to the requester, `Refunded`, emits `TaskRefunded` with `amount = payment + fee` |

Extra event: `FeePaid(uint256 indexed taskId, address indexed to, uint256 amount)`,
emitted by `attest` only.

`reclaim` (worker missed a window) also returns payment and fee, so its `TaskRefunded`
amount is `payment + fee`. After `attest(false)` the amount is `payment` only, because
the fee went to the verifier.

Limitations:

- If the verifier is silent the worker is not paid, even for good work.
- The contract does not stop the verifier address from also being a task's requester
  or worker. The experiment uses separate addresses.

## 6. Decisions and reasons

| Decision | Reason |
|----------|--------|
| Result hash on-chain, result off-chain | storing results would dominate gas and the contract cannot judge them anyway |
| Windows in blocks, set in the constructor | deterministic runs; small windows let many tasks finish quickly |
| One `deadline` field reused for each step | only one step is ever pending, so one field is enough and costs one storage slot |
| After the deadline only the timeout path works | one rule for every window; a late approve or reject cannot race a claim |
| Worker misses accept or submit window → requester reclaims | the requester's money must not stay locked because a worker is absent |
| A: requester rejects → refund, no dispute | this is the baseline; its weakness against free-riding is a result, not a bug |
| A: requester silent → worker claims | the worker's payment must not stay locked because a requester is absent |
| Timeout functions restricted to the party that receives the money | the receiver is the only one with a reason to call, and the gas is then attributed to that role |
| `SafeERC20`, state written before token calls, `ReentrancyGuard` on functions that pay out | standard protection against failed transfers and re-entrancy |
| C: one verifier fixed at deployment | the simplest form of third-party attestation; choosing among verifiers is out of scope |
| C: flat fee, locked at creation, paid for any verdict | the verifier's income does not depend on the verdict, so the fee gives it no reason to favour a side; locking it up front means the verifier cannot be left unpaid |
| C: verifier silent → payment and fee back to the requester | no verdict means no proof the work was good, and the fee was not earned |
| Custom errors | cheaper than revert strings and easy to match from tests and web3.py |
| `Task.state` stored beside `requester` | both fit in one 32-byte slot, which saves a storage write on creation |

Departure from `SRS.md` FR-01: the SRS lets the requester give a completion deadline per
task. Here the windows are per contract, so that every task in a run has the same timing.

## 7. Using the contracts from Python

`forge build` writes one JSON file per contract:

```
contracts/out/MockUSD.sol/MockUSD.json
contracts/out/RequesterApproveEscrow.sol/RequesterApproveEscrow.json
contracts/out/VerifierAttestedEscrow.sol/VerifierAttestedEscrow.json
```

`abi` is the ABI and `bytecode.object` the deployment bytecode. This example was run
against Anvil with the versions in `requirements.txt`; start `anvil` first and run it
from the repository root.

```python
import json
from web3 import Web3
from web3.logs import DISCARD

w3 = Web3(Web3.HTTPProvider("http://127.0.0.1:8545"))
deployer, requester, worker = w3.eth.accounts[:3]   # Anvil's unlocked test accounts

def load(name):
    with open(f"contracts/out/{name}.sol/{name}.json") as f:
        artifact = json.load(f)
    return artifact["abi"], artifact["bytecode"]["object"]

def deploy(name, *args):
    abi, bytecode = load(name)
    tx = w3.eth.contract(abi=abi, bytecode=bytecode).constructor(*args).transact({"from": deployer})
    receipt = w3.eth.wait_for_transaction_receipt(tx)
    return w3.eth.contract(address=receipt.contractAddress, abi=abi)

def send(call, sender):
    receipt = w3.eth.wait_for_transaction_receipt(call.transact({"from": sender}))
    assert receipt.status == 1
    return receipt

token = deploy("MockUSD")
escrow = deploy("RequesterApproveEscrow", token.address, 5, 5, 5)   # accept, submit, review windows

payment = 1_000_000                                                  # 1 mUSD
send(token.functions.mint(requester, payment), requester)
send(token.functions.approve(escrow.address, escrow.functions.requesterDeposit(payment).call()), requester)

receipt = send(escrow.functions.createTask(worker, payment), requester)
task_id = escrow.events.TaskCreated().process_receipt(receipt, errors=DISCARD)[0]["args"]["taskId"]

gas = {"createTask": receipt.gasUsed}
gas["acceptTask"] = send(escrow.functions.acceptTask(task_id), worker).gasUsed
gas["submitResult"] = send(escrow.functions.submitResult(task_id, Web3.keccak(text="result")), worker).gasUsed
gas["approve"] = send(escrow.functions.approve(task_id), requester).gasUsed

state = escrow.functions.tasks(task_id).call()[1]                    # 5 = Paid, 6 = Refunded
print(task_id, state, gas, token.functions.balanceOf(worker).call())
```

Notes for the runner:

- Anvil mines one block per transaction by default, so every transaction moves the
  clock by one block. To let a window expire, mine empty blocks with the `anvil_mine`
  RPC method, for example `w3.provider.make_request("anvil_mine", [6])`.
- Mechanism C is deployed with two more arguments,
  `deploy("VerifierAttestedEscrow", token.address, 5, 5, 5, verifier, fee)`, and settled
  with `escrow.functions.attest(task_id, True)` sent by the verifier.
- Call `requesterDeposit(payment)` and `workerBond(payment)` to learn how much each
  side must approve. The same two calls work for all three mechanisms.
- The first `createTask` on a fresh deployment costs more gas than later ones, because
  it writes the task counter and the escrow's token balance for the first time.
- A reverted transaction still uses gas. Whether reverted transactions are counted per
  task is the runner's decision (SRS FR-09).

## 8. Gas baseline

`contracts/.gas-snapshot` holds the gas of every unit test, written by `forge snapshot`.
`forge test --gas-report` prints gas per contract function. The README has the gas of
one real task on Anvil.
