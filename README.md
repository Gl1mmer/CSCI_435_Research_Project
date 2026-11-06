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
