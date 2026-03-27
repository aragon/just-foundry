#!/usr/bin/env bash
# verify-contracts.sh — verify all deployed contracts from the latest broadcast
# Usage: verify-contracts.sh <chain_id> <script_file> [forge verify-contract flags...]
set -euo pipefail

CHAIN_ID="$1"
SCRIPT_FILE="$2"
shift 2

BROADCAST="broadcast/${SCRIPT_FILE}/${CHAIN_ID}/run-latest.json"

[ -f "$BROADCAST" ] || { echo "Error: No broadcast found at $BROADCAST"; exit 1; }

echo "Verifying contracts from: $BROADCAST"
echo ""

PASS=0
FAIL=0

while IFS= read -r row; do
    ADDRESS=$(echo "$row" | jq -r '.contractAddress')
    NAME=$(echo "$row" | jq -r '.contractName')

    echo "--- $NAME ($ADDRESS)"
    if forge verify-contract \
            --watch \
            --chain "$CHAIN_ID" \
            --rpc-url "$RPC_URL" \
            --guess-constructor-args \
            "$@" \
            "$ADDRESS" "$NAME"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  [FAILED]"
    fi
    echo ""
done < <(jq -c '[.transactions[] | select(.transactionType == "CREATE" or .transactionType == "CREATE2")] | unique_by(.contractAddress) | .[]' "$BROADCAST")

echo "$PASS verified, $FAIL failed"
[ "$FAIL" -eq 0 ]
