#!/usr/bin/env bash
# deployments.sh — the contracts a forge broadcast deployed, in broadcast order
# Usage: deployments.sh <run-latest.json> <chain_id> [contract]
#
# Prints one tab-separated line per deployment: <contract> <address> <status> <constructor args>.
# The status comes from the broadcast's receipt for the transaction: "ok" (status 0x1), "reverted", or
# "unmined" (no receipt: the run stopped before it was mined). The constructor args are hex ("" when the
# constructor takes none), or "?" when they can't be read because the contract's artifact is missing.
# With [contract], prints only the latest deployment of that contract, and fails when there is none or
# when that latest deployment didn't succeed (it never falls back to an older one).
# Run it from the project root (it reads out/ and zkout/).
#
# Standard EVM: the broadcast's CREATE and CREATE2 transactions, named by forge. CREATE2 input is the
#   32-byte salt followed by the init code; the arguments are what follows the artifact's bytecode.
# zkSync (chain 300/324): forge-zksync sends `create` (0x9c4d535b, to the ContractDeployer 0x…8006) and
#   `create2` (0x3cda3351, to the deterministic deployer 0x…10000) calls with no contract name. Both take
#   (bytes32 salt, bytes32 bytecodeHash, bytes constructorInput): the name is the zkout/ artifact with that
#   hash, and the address is the first of the transaction's additionalContracts (the ones after it are
#   contracts its constructor deployed).
set -euo pipefail

BROADCAST="$1"
CHAIN_ID="$2"
CONTRACT="${3:-}"

[ -f "$BROADCAST" ] || { echo "Error: no broadcast at $BROADCAST. Did the deploy script run on this network?" >&2; exit 1; }
BROADCAST_CHAIN=$(jq -r '.chain // ""' "$BROADCAST")
[ "$BROADCAST_CHAIN" = "$CHAIN_ID" ] \
    || { echo "Error: $BROADCAST is for chain ${BROADCAST_CHAIN:-?}, not $CHAIN_ID (was it moved by hand?)" >&2; exit 1; }

# jq: the status of the transaction whose hash is the input, from the given receipts
STATUS_JQ='def status($receipts): ascii_downcase as $h
    | ([$receipts[] | select((.transactionHash // "" | ascii_downcase) == $h) | .status][0] // null)
    | if . == null then "unmined" elif . == "0x1" then "ok" else "reverted" end;'

list_evm() {
    local name address status input bytecode artifact args
    while IFS=$'\t' read -r name address status input; do
        args="?"
        while IFS= read -r artifact; do
            bytecode=$(jq -r '.bytecode.object // ""' "$artifact")
            bytecode="${bytecode#0x}"
            [ -n "$bytecode" ] && [ "${input:0:${#bytecode}}" = "$bytecode" ] || continue
            args="${input:${#bytecode}}"
            [ -n "$args" ] && args="0x$args"
            break
        done < <(find out -mindepth 2 -maxdepth 2 -name "$name.json" 2>/dev/null)
        printf '%s\t%s\t%s\t%s\n' "$name" "$address" "$status" "$args"
    done < <(jq -r "$STATUS_JQ"'
        (.receipts // []) as $receipts
        | .transactions[]
        | select(.transactionType == "CREATE" or .transactionType == "CREATE2")
        | (.transaction.input | ltrimstr("0x")) as $input
        | [.contractName, .contractAddress, (.hash // "" | status($receipts)),
           (if .transactionType == "CREATE2" then $input[64:] else $input end)]
        | @tsv' "$BROADCAST")
}

list_zksync() {
    [ -d zkout ] || { echo "Error: no zkout/ directory. Build with forge-zksync (--zksync) first." >&2; exit 1; }
    # bytecode hash → contract name, from zkout/<File>.sol/<Name>.json. Built in a file: a project can have
    # thousands of artifacts, more than one command-line argument holds.
    local map
    map=$(mktemp)
    trap 'rm -f "$map"' EXIT  # list_zksync runs in a command substitution: this is its own shell
    find zkout -mindepth 2 -maxdepth 2 -name '*.json' -not -path 'zkout/build-info/*' \
        -exec jq -c 'select((.hash // "") != "")
            | {(.hash | ascii_downcase): (input_filename | split("/") | last | rtrimstr(".json"))}' {} + \
        | jq -s 'add // {}' > "$map"
    [ "$(jq 'length' "$map")" -gt 0 ] || { echo "Error: No artifacts in zkout/. Build with forge-zksync (--zksync) first." >&2; exit 1; }
    jq -r --slurpfile names "$map" "$STATUS_JQ"'
        def hexval: ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
        (.receipts // []) as $receipts
        | .transactions[]
        | .transaction.input as $input
        | select($input[0:10] == "0x9c4d535b" or $input[0:10] == "0x3cda3351")
        | $input[10:] as $body
        | ($body[64:128] | ascii_downcase) as $hash
        | (($body[128:192] | hexval) * 2) as $offset
        | (($body[$offset:$offset + 64] | hexval) * 2) as $length
        | [($names[0][$hash] // ("unknown:" + $hash)), (.additionalContracts[0].address // ""), (.hash // "" | status($receipts)),
           (if $length == 0 then "" else "0x" + $body[$offset + 64:$offset + 64 + $length] end)]
        | @tsv' "$BROADCAST"
}

if [ "$CHAIN_ID" != 300 ] && [ "$CHAIN_ID" != 324 ]; then
    DEPLOYMENTS=$(list_evm)
else
    DEPLOYMENTS=$(list_zksync)
fi

while IFS=$'\t' read -r name address _; do
    [ -n "$name" ] || continue
    if [[ ! "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "Error: the deployment of ${name#unknown:} in $BROADCAST has no deployed address ('$address')" >&2
        exit 1
    fi
    [[ "$name" == unknown:* ]] && echo "Warning: no zkout/ artifact has the bytecode hash ${name#unknown:} (rebuild?)" >&2
done <<<"$DEPLOYMENTS"

if [ -z "$CONTRACT" ]; then
    [ -z "$DEPLOYMENTS" ] || echo "$DEPLOYMENTS"
    exit 0
fi

LATEST=$(awk -F'\t' -v c="$CONTRACT" '$1 == c { line = $0 } END { print line }' <<<"$DEPLOYMENTS")
[ -n "$LATEST" ] || { echo "Error: No deployment of $CONTRACT in $BROADCAST" >&2; exit 1; }
case "$(cut -f3 <<<"$LATEST")" in
    ok) echo "$LATEST" ;;
    reverted) echo "Error: the latest deployment of $CONTRACT in $BROADCAST reverted: deploy it again" >&2; exit 1 ;;
    *) echo "Error: the latest deployment of $CONTRACT in $BROADCAST was not mined (no receipt): deploy it again" >&2; exit 1 ;;
esac
