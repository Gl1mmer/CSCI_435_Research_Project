#!/usr/bin/env bash
# Deploys the contracts to a local Anvil chain, sends one task through each settlement
# mechanism with real transactions, and prints the gas used by every transaction.
#
# Start `anvil` in another terminal first, then run from the contracts/ folder:
#   bash script/gas_one_task.sh
set -euo pipefail

export ETH_RPC_URL=http://127.0.0.1:8545

# Anvil's fixed test accounts 0 to 5. Anvil signs for them, so no private key is needed.
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
REQUESTER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
WORKER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
VERIFIER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
ARBITER=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
CHALLENGER=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc

PAYMENT=1000000   # 1 mUSD
FUNDS=10000000    # 10 mUSD for each funded account
RESULT=$(cast keccak "result")

# A contract's address follows from the deployer and its nonce. The script deploys the
# token and then escrows A, C and B, so they take the deployer's next four nonces.
NONCE=$(cast nonce $DEPLOYER)
address_at() { cast compute-address $DEPLOYER --nonce $((NONCE + $1)) | awk '{print $NF}'; }
TOKEN=$(address_at 0)
ESCROW_A=$(address_at 1)
ESCROW_C=$(address_at 2)
ESCROW_B=$(address_at 3)

# Fix the script's parameters here, so that values left over in the caller's
# environment cannot change what is measured.
ACCEPT_WINDOW=5 SUBMIT_WINDOW=5 REVIEW_WINDOW=5 CHALLENGE_WINDOW=5 ARBITER_WINDOW=5 \
VERIFIER=$VERIFIER VERIFIER_FEE=10000 ARBITER=$ARBITER BOND_BPS=1000 \
    forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --broadcast --unlocked --sender $DEPLOYER > /dev/null

# send <from> <contract> <signature> [arguments]: sends one transaction, prints its gas.
send() {
    local from=$1
    shift
    cast send "$@" --unlocked --from "$from" | awk '/^gasUsed/ {print $2}'
}

# step <label> <role> <from> <contract> <signature> [arguments]: one row of the table.
TOTAL=0
step() {
    local label=$1 role=$2
    shift 2
    local gas
    gas=$(send "$@")
    TOTAL=$((TOTAL + gas))
    printf "  %-14s %-11s %8d\n" "$label" "$role" "$gas"
}
total() {
    printf "  %-26s %8d\n\n" "total for the task" "$TOTAL"
    TOTAL=0
}

# Setup, not part of any task: fund the accounts and let each escrow pull tokens.
for account in $REQUESTER $WORKER $CHALLENGER; do
    send $account $TOKEN "mint(address,uint256)" $account $FUNDS > /dev/null
    for escrow in $ESCROW_A $ESCROW_C $ESCROW_B; do
        send $account $TOKEN "approve(address,uint256)" $escrow $FUNDS > /dev/null
    done
done

echo "A requester-approve: approved"
step createTask requester $REQUESTER $ESCROW_A "createTask(address,uint256)" $WORKER $PAYMENT
step acceptTask worker $WORKER $ESCROW_A "acceptTask(uint256)" 1
step submitResult worker $WORKER $ESCROW_A "submitResult(uint256,bytes32)" 1 $RESULT
step approve requester $REQUESTER $ESCROW_A "approve(uint256)" 1
total

echo "C verifier-attested: passed"
step createTask requester $REQUESTER $ESCROW_C "createTask(address,uint256)" $WORKER $PAYMENT
step acceptTask worker $WORKER $ESCROW_C "acceptTask(uint256)" 1
step submitResult worker $WORKER $ESCROW_C "submitResult(uint256,bytes32)" 1 $RESULT
step attest verifier $VERIFIER $ESCROW_C "attest(uint256,bool)" 1 true
total

echo "B optimistic stake: not challenged"
step createTask requester $REQUESTER $ESCROW_B "createTask(address,uint256)" $WORKER $PAYMENT
step acceptTask worker $WORKER $ESCROW_B "acceptTask(uint256)" 1
step submitResult worker $WORKER $ESCROW_B "submitResult(uint256,bytes32)" 1 $RESULT
cast rpc anvil_mine 6 > /dev/null   # let the 5-block challenge window pass
step finalize worker $WORKER $ESCROW_B "finalize(uint256)" 1
total

echo "B optimistic stake: challenged, challenge upheld"
step createTask requester $REQUESTER $ESCROW_B "createTask(address,uint256)" $WORKER $PAYMENT
step acceptTask worker $WORKER $ESCROW_B "acceptTask(uint256)" 2
step submitResult worker $WORKER $ESCROW_B "submitResult(uint256,bytes32)" 2 $RESULT
step challenge challenger $CHALLENGER $ESCROW_B "challenge(uint256)" 2
step resolve arbiter $ARBITER $ESCROW_B "resolve(uint256,bool)" 2 false
total

# Every task is settled, so no escrow may hold tokens any more.
for escrow in $ESCROW_A $ESCROW_C $ESCROW_B; do
    balance=$(cast call $TOKEN "balanceOf(address)(uint256)" $escrow | awk '{print $1}')
    if [ "$balance" != "0" ]; then
        echo "error: escrow $escrow still holds $balance units" >&2
        exit 1
    fi
done
echo "all escrows are empty"
