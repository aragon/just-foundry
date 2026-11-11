#!/usr/bin/env bash
# fund.sh — send a share of the deployer's balance to some addresses, split equally
# Usage: fund.sh <percent> <address>...   (run from the project root, after env_load)
#
# <percent> is 0.01% to 100%, with up to two decimals and always with its % (4%, 0.5%, 12.25%). That share of the
# deployer's balance, after setting aside the gas these transfers can cost, is split equally among the
# addresses. Signs with DEPLOYER_KEY using the network's gas flags (resolve-gas-params).
#
# Nothing is sent when an address is malformed or repeated, the percent is out of range, the RPC serves another
# chain, or the balance can't cover the transfers' gas. A summary (network, RPC host, balance, each amount and
# the total) asks "Proceed?", then each transfer asks again with its address and amount: "n" skips it.
# Each transfer gets one line: ok, skipped, FAILED (not funded: the node refused it, or it was mined and reverted)
# or UNKNOWN (no receipt within TX_RECEIPT_TIMEOUT seconds, default 300, or no answer: it may still be mined,
# so check an explorer before running again). Any FAILED or UNKNOWN makes the exit non-zero.
# It records nothing: running it again sends again (a top-up tool).
#
# Gas, the same rule on every chain: each transfer is estimated (`cast estimate`) and sent with a gas limit of
# twice its estimate, at a known price: the network's forced --gas-price if it has one, otherwise twice the
# current gas price. The reserve is the sum of those limits at that price, the most the transfers can cost in
# execution gas, plus the L1 data fee of each transfer on OP-stack rollups (see L1_FEE_WEI). The amounts come
# from the balance minus a first reserve (1-wei estimates); the estimates for the real amounts must still fit.
# A limit is never below 21,000. A transfer whose estimate fails (it would revert) or is above 30,000,000 is
# reported FAILED and nothing is sent to that address.
# Amounts are counted in whole gwei and the percent in basis points, so nothing needs more than shell arithmetic.
set -uo pipefail

PERCENT="${1:-}"
shift || true
ADDRESSES=("$@")

# The percent in basis points (4% is 400). Written one way: with its %, no leading zero but in "0.x", at most two decimals
[[ "$PERCENT" == *% ]] || { echo "Error: write the percent with %, e.g. 4%, got '$PERCENT'" >&2; exit 1; }
BP=0
if [[ "$PERCENT" =~ ^(0|[1-9][0-9]{0,2})(\.([0-9]{1,2}))?%$ ]]; then
    DECIMALS="${BASH_REMATCH[3]}00"
    BP=$(( ${BASH_REMATCH[1]} * 100 + 10#${DECIMALS:0:2} ))
fi
[ "$BP" -ge 1 ] && [ "$BP" -le 10000 ] \
    || { echo "Error: the percent must be from 0.01% to 100%, with at most two decimals and no leading zeros (4%, 0.5%, 12.25%), got '$PERCENT'" >&2; exit 1; }
[ "${#ADDRESSES[@]}" -gt 0 ] || { echo "Error: give at least one address to fund" >&2; exit 1; }
SEEN=""
for address in "${ADDRESSES[@]}"; do
    [[ "$address" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "Error: '$address' is not an address" >&2; exit 1; }
    lower=$(tr 'A-F' 'a-f' <<<"$address")
    ! grep -qxF "$lower" <<<"$SEEN" || { echo "Error: $address appears twice" >&2; exit 1; }
    SEEN="$SEEN$lower"$'\n'
done
[ -n "${DEPLOYER_KEY:-}" ] || { echo "Error: DEPLOYER_KEY is not set" >&2; exit 1; }
TX_RECEIPT_TIMEOUT="${TX_RECEIPT_TIMEOUT:-300}"
[[ "$TX_RECEIPT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "Error: TX_RECEIPT_TIMEOUT must be a positive number of seconds" >&2; exit 1; }

RPC_HOST=$(sed -E 's|^([a-zA-Z]+://)([^/@]*@)?([^/?#]+).*|\1\3|' <<<"$RPC_URL")
RPC_CHAIN=$(cast chain-id --rpc-url "$RPC_URL") || { echo "Error: can't reach the RPC of $NETWORK_NAME" >&2; exit 1; }
[ "$RPC_CHAIN" = "$CHAIN_ID" ] || { echo "Error: the RPC of $NETWORK_NAME serves chain $RPC_CHAIN, not $CHAIN_ID" >&2; exit 1; }

# wei (a decimal string of any size) to whole gwei, rounded down
to_gwei() { local wei="$1"; [ "${#wei}" -gt 9 ] && echo "${wei:0:${#wei}-9}" || echo 0; }

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY") || { echo "Error: DEPLOYER_KEY is not a valid key" >&2; exit 1; }
GAS_FLAGS=$(just resolve-gas-params) || exit 1
PRICE_WEI=$(sed -n 's/.*--gas-price \([0-9]*\).*/\1/p' <<<"$GAS_FLAGS")
if [ -z "$PRICE_WEI" ]; then
    PRICE_WEI=$(( $(cast gas-price --rpc-url "$RPC_URL") * 2 ))
    GAS_FLAGS="$GAS_FLAGS --gas-price $PRICE_WEI"
fi
BALANCE_WEI=$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL") || { echo "Error: can't read the balance of $DEPLOYER" >&2; exit 1; }

# Gas estimates for sending <value> to each address: ESTIMATES[i] and LIMITS[i] (twice the estimate, at least
# 21,000, the gas of any transfer), or LIMITS[i] empty when nothing can be sent there, with the reason in
# WHY_NOT[i]: the estimate failed (the transfer would revert), or it is above 30,000,000, more than a transfer
# can sensibly need. RESERVE_GWEI is the sum, for each transfer, of its limit at the price plus L1_FEE_GWEI,
# rounded up to whole gwei. Prints nothing; returns 1 when no transfer can go through.
MIN_GAS_LIMIT=21000
MAX_ESTIMATE=30000000
estimate_all() {
    local value="$1" i estimate
    RESERVE_GWEI=0
    USABLE=0
    ESTIMATES=(); LIMITS=(); WHY_NOT=()
    for i in "${!ADDRESSES[@]}"; do
        ESTIMATES[$i]=""; LIMITS[$i]=""; WHY_NOT[$i]=""
        if ! estimate=$(cast estimate --from "$DEPLOYER" --value "$value" --rpc-url "$RPC_URL" "${ADDRESSES[$i]}" 2>/dev/null) \
            || [[ ! "$estimate" =~ ^[0-9]+$ ]]; then
            WHY_NOT[$i]="the transfer would revert (its gas estimate failed)"
        # Compared by length first, so that no estimate can overflow shell arithmetic
        elif [ "${#estimate}" -gt "${#MAX_ESTIMATE}" ] || [ "$estimate" -gt "$MAX_ESTIMATE" ]; then
            WHY_NOT[$i]="its gas estimate ($estimate) is above $MAX_ESTIMATE"
        else
            ESTIMATES[$i]=$estimate
            LIMITS[$i]=$((estimate * 2 > MIN_GAS_LIMIT ? estimate * 2 : MIN_GAS_LIMIT))
            # The price split in whole gwei and the rest, so that no product overflows shell arithmetic
            RESERVE_GWEI=$((RESERVE_GWEI + LIMITS[i] * (PRICE_WEI / 1000000000) + (LIMITS[i] * (PRICE_WEI % 1000000000) + 999999999) / 1000000000 + L1_FEE_GWEI))
            USABLE=$((USABLE + 1))
        fi
    done
    [ "$USABLE" -gt 0 ]
}

# OP-stack rollups (code at the GasPriceOracle predeploy) also charge an L1 data fee, and their nodes refuse a
# transfer the balance can't cover with it. L1_FEE_WEI, reserved for each transfer, is twice the oracle's fee
# now (the L1 price moves): its upper bound for the size of an unsigned transfer (getL1FeeUpperBound, Fjord and
# later), or else its fee for one (getL1Fee). Both add the signature themselves. The sample transfer is the
# largest this run can send, unsigned.
GAS_ORACLE=0x420000000000000000000000000000000000000F
L1_FEE_WEI=0
L1_FEE_GWEI=0
ORACLE_CODE=$(cast code "$GAS_ORACLE" --rpc-url "$RPC_URL") || { echo "Error: can't read the code at $GAS_ORACLE" >&2; exit 1; }
if [ "$ORACLE_CODE" != 0x ]; then
    l1_fee_error() { echo "Error: can't read the L1 data fee from $GAS_ORACLE ($1): nothing sent" >&2; exit 1; }
    SAMPLE=$(cast mktx --raw-unsigned --from "$DEPLOYER" $GAS_FLAGS --gas-limit $((MAX_ESTIMATE * 2)) --value "$BALANCE_WEI" \
        --nonce "$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")" --rpc-url "$RPC_URL" "${ADDRESSES[0]}" 2>/dev/null) \
        || l1_fee_error "no sample transfer"
    SAMPLE_SIZE=$(( (${#SAMPLE} - 2) / 2 ))
    if L1_FEE=$(cast call "$GAS_ORACLE" "getL1FeeUpperBound(uint256)(uint256)" "$SAMPLE_SIZE" --rpc-url "$RPC_URL" 2>/dev/null); then
        L1_FEE_HOW="getL1FeeUpperBound($SAMPLE_SIZE)"
    elif L1_FEE=$(cast call "$GAS_ORACLE" "getL1Fee(bytes)(uint256)" "$SAMPLE" --rpc-url "$RPC_URL" 2>/dev/null); then
        L1_FEE_HOW="getL1Fee of an unsigned transfer"
    else
        l1_fee_error "it answers neither getL1FeeUpperBound nor getL1Fee"
    fi
    L1_FEE=${L1_FEE%% *}  # cast adds a readable form: "2852598185 [2.852e9]"
    # At most 1 ether per transfer, which also keeps it within shell arithmetic
    [[ "$L1_FEE" =~ ^[0-9]{1,18}$ ]] || l1_fee_error "it answered '$L1_FEE'"
    L1_FEE_WEI=$((L1_FEE * 2))
    L1_FEE_GWEI=$(((L1_FEE_WEI + 999999999) / 1000000000))
fi

COUNT=${#ADDRESSES[@]}
BALANCE_GWEI=$(to_gwei "$BALANCE_WEI")
cant_cover() {
    echo "Error: the balance of $DEPLOYER ($(cast to-unit "$BALANCE_WEI" ether) ether) can't cover $1 ($(cast to-unit "${2}gwei" ether) ether of gas reserved)" >&2
    exit 1
}

# First reserve, from 1-wei transfers; it sets the amounts. Each address gets the same share of the budget,
# so an address whose transfer would revert leaves its share with the deployer.
estimate_all 1 || { echo "Error: no transfer can be sent (every gas estimate failed or is above $MAX_ESTIMATE): nothing sent" >&2; exit 1; }
SPENDABLE_GWEI=$((BALANCE_GWEI - RESERVE_GWEI))
[ "$SPENDABLE_GWEI" -gt 0 ] || cant_cover "the gas of the transfers" "$RESERVE_GWEI"
# BP/10000 of the spendable balance, split in two so that no product can overflow
SHARE_GWEI=$((SPENDABLE_GWEI / 10000 * BP + SPENDABLE_GWEI % 10000 * BP / 10000))
AMOUNT_GWEI=$((SHARE_GWEI / COUNT))
[ "$AMOUNT_GWEI" -gt 0 ] || { echo "Error: $PERCENT of the balance split in $COUNT is less than 1 gwei each" >&2; exit 1; }
AMOUNT=$(cast to-unit "${AMOUNT_GWEI}gwei" ether)

# Final reserve, from the real amounts: the limits used to send, which must still fit
estimate_all "${AMOUNT_GWEI}gwei" || { echo "Error: no transfer can be sent (every gas estimate failed or is above $MAX_ESTIMATE): nothing sent" >&2; exit 1; }
TOTAL_GWEI=$((AMOUNT_GWEI * USABLE + RESERVE_GWEI))
[ "$TOTAL_GWEI" -le "$BALANCE_GWEI" ] || cant_cover "$USABLE transfer(s) of $AMOUNT ether with their gas" "$RESERVE_GWEI"

# Prints the receipt of a transaction once mined, looking it up until TX_RECEIPT_TIMEOUT seconds have passed.
# Returns 1 when it isn't mined by then (the RPC answers null), and 2 when the lookup fails (printing the error).
await_receipt() {
    local tx="$1" out deadline=$((SECONDS + TX_RECEIPT_TIMEOUT))
    while :; do
        out=$(cast rpc eth_getTransactionReceipt "$tx" --rpc-url "$RPC_URL" 2>&1) || { echo "$out"; return 2; }
        [ "$out" = null ] || { echo "$out"; return 0; }
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 1
    done
}

# Asks a yes/no question; true only for "y". Off a terminal the answer is echoed, so the output reads in order.
ask() {
    local answer=""
    printf "%s [y/N] " "$1"
    read -r answer || true
    [ -t 0 ] || echo "$answer"
    [ "$answer" = "y" ]
}

printf "\n== fund on %s (chain %s)\n   rpc:      %s\n   deployer: %s\n   balance:  %s ether\n   gas:      %s ether reserved for %s transfer(s), each at twice its estimate\n   flags:    %s\n" \
    "$NETWORK_NAME" "$RPC_CHAIN" "$RPC_HOST" "$DEPLOYER" "$(cast to-unit "$BALANCE_WEI" ether)" \
    "$(cast to-unit "${RESERVE_GWEI}gwei" ether)" "$USABLE" "$GAS_FLAGS"
[ "$L1_FEE_WEI" = 0 ] || echo "   l1 fee:   $(cast to-unit "$L1_FEE_WEI" ether) ether per transfer, in the reserve (OP-stack L1 data fee: twice $L1_FEE_HOW)"
echo "   $PERCENT of the rest, split in $COUNT:"
for i in "${!ADDRESSES[@]}"; do
    if [ -n "${LIMITS[$i]}" ]; then
        echo "   ${ADDRESSES[$i]}  $AMOUNT ether  (gas estimate ${ESTIMATES[$i]}, limit ${LIMITS[$i]})"
    else
        echo "   ${ADDRESSES[$i]}  nothing: ${WHY_NOT[$i]}"
    fi
done
echo "   total:    $(cast to-unit "$((AMOUNT_GWEI * USABLE))gwei" ether) ether to $USABLE address(es)"
ask "Proceed?" || { echo "Nothing sent"; exit 0; }

# Each transfer, once confirmed: a successful receipt is funded; a revert (at estimation, or once mined) is not
# funded; no receipt at all (a timeout, an RPC error) is unknown, since the transfer may still be mined
REVERTED=()
UNKNOWN=()
SKIPPED=()
for i in "${!ADDRESSES[@]}"; do
    address=${ADDRESSES[$i]}
    if [ -z "${LIMITS[$i]}" ]; then
        echo "FAILED  $address: ${WHY_NOT[$i]}, nothing sent, not funded"
        REVERTED+=("$address")
        continue
    fi
    if ! ask "Send $AMOUNT ether to $address?"; then
        echo "skipped $address: answered no, nothing sent"
        SKIPPED+=("$address")
        continue
    fi
    # Signed here, so that its hash is known even when the node answers with an error
    RAW=$(cast mktx --private-key "$DEPLOYER_KEY" $GAS_FLAGS --gas-limit "${LIMITS[$i]}" --value "${AMOUNT_GWEI}gwei" \
        --rpc-url "$RPC_URL" "$address" 2>&1 </dev/null)
    if [[ ! "$RAW" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "FAILED  $address: the transfer couldn't be signed ($(tail -1 <<<"$RAW")), nothing sent, not funded"
        REVERTED+=("$address")
        continue
    fi
    TX=$(cast keccak "$RAW")
    # Only an error answered by the node (a JSON-RPC error response) means it refused the transfer; any other
    # error (a timeout, a lost connection) may follow a broadcast that went through
    if ! PUBLISHED=$(cast publish --async --rpc-url "$RPC_URL" "$RAW" 2>&1 </dev/null); then
        if grep -q "server returned an error response" <<<"$PUBLISHED"; then
            echo "FAILED  $address: the node refused the transfer ($(tail -1 <<<"$PUBLISHED")), nothing sent, not funded"
            REVERTED+=("$address")
        else
            echo "UNKNOWN $address: no answer to the broadcast of tx $TX ($(tail -1 <<<"$PUBLISHED")): check $address on an explorer before running again"
            UNKNOWN+=("$address")
        fi
        continue
    fi
    RECEIPT=$(await_receipt "$TX"); OUTCOME=$?
    if [ "$OUTCOME" = 1 ]; then
        echo "UNKNOWN $address: no receipt for tx $TX after ${TX_RECEIPT_TIMEOUT}s: check $address on an explorer before running again"
        UNKNOWN+=("$address")
    elif [ "$OUTCOME" = 2 ]; then
        echo "UNKNOWN $address: can't read the receipt of tx $TX ($(tail -1 <<<"$RECEIPT")): check $address on an explorer before running again"
        UNKNOWN+=("$address")
    elif [ "$(jq -r '.status' <<<"$RECEIPT")" = "0x1" ]; then
        echo "ok      $address $AMOUNT ether, tx $TX"
    else
        echo "FAILED  $address: tx $TX reverted, not funded"
        REVERTED+=("$address")
    fi
done
[ -z "${SKIPPED[*]:-}" ] || echo "Skipped: ${SKIPPED[*]}"
[ -z "${REVERTED[*]:-}" ] || echo "Not funded: ${REVERTED[*]}"
[ -z "${UNKNOWN[*]:-}" ] || echo "Unknown, check on an explorer before running again: ${UNKNOWN[*]}"
[ -z "${REVERTED[*]:-}${UNKNOWN[*]:-}" ] || exit 1
