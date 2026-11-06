# Settlement mechanisms for agent-to-agent payments

CSCI 435 Blockchain and Cryptocurrencies, Research Track Project.

AI agents that hire other AI agents need a rule for deciding when delegated work gets paid.
This repository is a testbed that measures three on-chain rules on the same task life-cycle:

- **A, requester-approve:** the hiring agent approves or rejects the work.
- **C, verifier-attested:** a fixed verifier passes or fails the work and is paid a fee.
- **B, optimistic stake:** the worker posts a bond and is paid after a challenge window
  unless someone challenges; an arbiter settles challenges.

We compare them on wrongful payments, honest-party losses and gas cost as the share of
faulty agents grows. The research question and plan are in `proposal.md`, the requirements
in `SRS.md`.

## Layout

```
contracts/        Foundry project: Solidity contracts, tests, deploy script
src/agentpay/     Python package: chain client, runner, metrics, agents
scripts/          experiment, figure and calibration scripts
data/             task set, judge cache, gas-price snapshot
results/          CSV and JSON written by the runner
figures/          written by scripts only
paper/            LaTeX source of the paper
docs/             design decisions and parameters
```

## Install

### Foundry (contracts)

The contracts are built and tested with Foundry **v1.9.0** (`forge`, `anvil`, `cast`).

Linux, macOS or WSL:

```bash
curl -L https://foundry.paradigm.xyz | bash
# open a new terminal, then
foundryup --install v1.9.0
```

Windows (Git Bash), without the installer script:

```bash
mkdir -p ~/.foundry/bin && cd ~/.foundry
curl -L -o foundry.zip https://github.com/foundry-rs/foundry/releases/download/v1.9.0/foundry_v1.9.0_win32_amd64.zip
unzip -o foundry.zip -d ~/.foundry/bin
export PATH="$HOME/.foundry/bin:$PATH"    # add this line to ~/.bashrc to keep it
```

Check the install:

```bash
forge --version    # forge Version: 1.9.0
```

### Solidity dependencies

Dependencies are pinned in `contracts/foundry.toml` and `contracts/soldeer.lock` and are
not stored in git. Restore them with:

```bash
cd contracts
forge soldeer install
```

### Python

Python 3.13. The versions in `requirements.txt` are exact.

```bash
python -m venv .venv
source .venv/bin/activate          # Windows Git Bash: source .venv/Scripts/activate
pip install -r requirements.txt
```

## Build and test the contracts

```bash
cd contracts
forge build
forge test -vv
```

`forge test --gas-report` adds a gas table per function. `forge snapshot --check` compares
the gas of every test with the tracked baseline in `contracts/.gas-snapshot`.

## Deploy and settle one task on a local chain

This sends real transactions to a local Anvil chain: deploy, then one task through
mechanism A (create, accept, submit, approve). The interface is described in
`docs/DESIGN.md`.

Terminal 1, the chain:

```bash
anvil
```

Terminal 2, from `contracts/`. The addresses are Anvil's fixed test accounts 0, 1 and 2,
which Anvil signs for itself, so no private key is needed.

```bash
export ETH_RPC_URL=http://127.0.0.1:8545
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
REQUESTER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
WORKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

# Deploy the token and the three escrows. Defaults: every window 5 blocks, verifier =
# Anvil account 3, verifier fee 10,000 units, arbiter = Anvil account 4, bond 10%.
# To change them set ACCEPT_WINDOW, SUBMIT_WINDOW, REVIEW_WINDOW, CHALLENGE_WINDOW,
# ARBITER_WINDOW, VERIFIER, VERIFIER_FEE, ARBITER or BOND_BPS in the environment.
forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --broadcast --unlocked --sender $DEPLOYER

# On a fresh Anvil the script always prints the same addresses. These are the token
# and the mechanism A escrow.
TOKEN=0x5FbDB2315678afecb367f032d93F642f64180aa3
ESCROW=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

# Setup: give the requester 1 mUSD (1,000,000 units) and let the escrow pull it.
cast send $TOKEN "mint(address,uint256)" $REQUESTER 1000000 --unlocked --from $REQUESTER
cast send $TOKEN "approve(address,uint256)" $ESCROW 1000000 --unlocked --from $REQUESTER

# The task. Each command prints a receipt; the gas is the gasUsed line.
cast send $ESCROW "createTask(address,uint256)" $WORKER 1000000 --unlocked --from $REQUESTER
cast send $ESCROW "acceptTask(uint256)" 1 --unlocked --from $WORKER
cast send $ESCROW "submitResult(uint256,bytes32)" 1 $(cast keccak "result") --unlocked --from $WORKER
cast send $ESCROW "approve(uint256)" 1 --unlocked --from $REQUESTER

# Check: the worker holds the payment and the escrow holds nothing.
cast call $TOKEN "balanceOf(address)(uint256)" $WORKER
cast call $TOKEN "balanceOf(address)(uint256)" $ESCROW
```

Gas measured with these commands on 2026-11-06 (Foundry 1.9.0, solc 0.8.30, optimizer
200 runs, EVM version cancun, fresh Anvil):

| Transaction | Sender | Gas used |
|-------------|--------|---------:|
| deploy `MockUSD` | deployer | 507,896 |
| deploy `RequesterApproveEscrow` | deployer | 911,455 |
| `mint` | requester | 68,379 |
| `approve` (token) | requester | 46,330 |
| `createTask` | requester | 166,696 |
| `acceptTask` | worker | 35,163 |
| `submitResult` | worker | 58,071 |
| `approve` (task) | requester | 65,823 |
| **the task: create to approve** | | **325,753** |

This is the first task on a new deployment. Its `createTask` is more expensive than
later ones because it writes the task counter and the escrow's token balance for the
first time.

### One task through each mechanism

`script/gas_one_task.sh` does the same for all three mechanisms and prints the gas of
every transaction. With `anvil` running, from `contracts/`:

```bash
bash script/gas_one_task.sh
```

Output on 2026-11-06 with the same toolchain (payment 1 mUSD, verifier fee 0.01 mUSD,
bond 10%, every window 5 blocks):

```
A requester-approve: approved
  createTask     requester     176296
  acceptTask     worker         35163
  submitResult   worker         58071
  approve        requester      48723
  total for the task           318253

C verifier-attested: passed
  createTask     requester     176416
  acceptTask     worker         35185
  submitResult   worker         58071
  attest         verifier       76128
  total for the task           345800

B optimistic stake: not challenged
  createTask     requester     176296
  acceptTask     worker         58955
  submitResult   worker         58160
  finalize       worker         50950
  total for the task           344361

B optimistic stake: challenged, challenge upheld
  createTask     requester     159196
  acceptTask     worker         58955
  submitResult   worker         58160
  challenge      challenger     81514
  resolve        arbiter        59612
  total for the task           417437

all escrows are empty
```

Gas depends on the state of the token's storage, so these are examples, not constants.
Mechanism A costs 318,253 here and 325,753 in the walk-through above for the same four
calls: in the walk-through the requester's balance and allowance drop to exactly zero in
`createTask` (two storage refunds, 9,600 gas less) and the worker's balance is written
for the first time in `approve` (17,100 gas more). The second task on escrow B has a
cheaper `createTask` because the task counter is already set. The numbers for the paper
come from the experiment runner, which measures every task.

## Run the experiments

_To be written with the Python runner (`src/agentpay/`, `scripts/`)._

## Regenerate the figures

_To be written with `scripts/make_figures.py`._

## Reused code

| Library | Version | Used for | Licence |
|---------|---------|----------|---------|
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | 5.7.0 | ERC-20 token, `SafeERC20`, `ReentrancyGuard` | MIT |
| [forge-std](https://github.com/foundry-rs/forge-std) | 1.17.0 | test and script helpers | MIT or Apache-2.0 |

Both are downloaded by `forge soldeer install` and are not copied into this repository.
Everything under `contracts/src`, `contracts/test` and `contracts/script` is written by
the team.

## AI use

AI assistance (Claude, Anthropic) was used to write and debug code and to improve wording
in this repository; the team has reviewed all of it and is responsible for it.

## Licence

MIT, see `LICENSE`.
