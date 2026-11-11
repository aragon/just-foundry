#!/usr/bin/env bash
# send-tx-batch.sh — send each <folder>/<network>.json transaction on its network, after confirmation
# Usage: send-tx-batch.sh <folder> <max_age_minutes> [event signature]   (just send-tx-batch defaults the age to 1440)
#
# A transaction file is {"chainId": number, "to": address, "data": hex}, named after the network it is for.
# For each file, in this order:
#   - <network>.sent exists: already sent from this machine, skipped.
#   - <network>.pending exists: a transaction was signed for this file but its outcome wasn't known. It is
#     resolved first (see resolve_pending), and nothing new is signed while it stays unknown.
#   - Older than <max_age_minutes>: not sent (counts as not sent: generate it again).
#   - Otherwise the network is selected; the RPC must serve the network's chain and the file's chainId.
#     The chain, RPC host, sender, target, calldata and gas flags are shown, and the transaction is sent
#     once the user answers "y": signed with `cast mktx` (one Ledger prompt), recorded in <network>.pending
#     (hash, nonce, sender, signed bytes, and the hash of the file's content), and only then broadcast with
#     `cast publish`, whose reported hash is recorded too. Its receipt is awaited (TX_RECEIPT_TIMEOUT
#     seconds, 300 by default).
# Outcome of a transaction:
#   - Success: <network>.sent ({"txHash"}, plus "proposalId": the first indexed topic of the given event,
#     emitted by the target); the .json and .pending files are removed. A missing event is a failure,
#     but the transaction stays recorded as sent.
#   - Mined revert: .pending is removed and the .json kept, so a later run sends it again.
#   - Unknown (timeout, RPC error, Ctrl-C): .pending and .json are kept.
# This script never removes a .pending file whose transaction might have been mined: when it can't tell,
# it says what the RPC observed and leaves the decision to a person checking an explorer.
# Exits non-zero when any network wasn't sent (apart from declines and .sent skips), listing them.
# The active network is selected again at the end.
#
# The signer is TX_SIGNER: `cast` wallet flags, "--ledger" by default (its first account).
# Never pipe answers in (`yes |`): every network would be confirmed without being read.
set -uo pipefail

DIR="$1"
MAX_AGE="$2"
EVENT="${3:-}"
TX_SIGNER="${TX_SIGNER:---ledger}"
TX_RECEIPT_TIMEOUT="${TX_RECEIPT_TIMEOUT:-300}"

[[ "$MAX_AGE" =~ ^[1-9][0-9]*$ ]] || { echo "Error: the maximum age must be a positive number of minutes, got '$MAX_AGE'" >&2; exit 1; }
[[ "$TX_RECEIPT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "Error: TX_RECEIPT_TIMEOUT must be a positive number of seconds" >&2; exit 1; }
[ -d "$DIR" ] || { echo "Error: no directory $DIR" >&2; exit 1; }
command -v jq &>/dev/null || { echo "Error: jq is required" >&2; exit 1; }

source lib/just-foundry/lib.sh
env_restore_network_on_exit

# Looks up the receipt of a transaction until <seconds> have passed (0: once), under any of the given hashes.
# Prints the receipt and returns 0 when mined; returns 1 when the RPC says it isn't mined (yet), and 2 when
# the last lookup failed (an RPC error: whether it was mined is unknown).
#   Usage: await_receipt <seconds> <hash> [another hash the same transaction may be known by]
await_receipt() {
    local deadline=$((SECONDS + $1)) hash out outcome
    shift
    while true; do
        outcome=1
        for hash in "$@"; do
            [ -n "$hash" ] || continue
            if out=$(cast rpc eth_getTransactionReceipt "$hash" --rpc-url "$RPC_URL" 2>/dev/null); then
                [ "$out" = "null" ] || { echo "$out"; return 0; }
            else
                outcome=2
            fi
        done
        [ "$SECONDS" -lt "$deadline" ] || return "$outcome"
        sleep 2
    done
}

# The RPC's scheme and host, for display: no path, query or credentials (they can carry API keys)
rpc_host() {
    sed -E 's|^([a-zA-Z]+://)([^/@]*@)?([^/?#]+).*|\1\3|' <<<"$RPC_URL"
}

# The hash of a transaction file's content, as recorded in .pending
content_hash() {
    cast keccak "$(jq -r '"\(.chainId)|\(.to | ascii_downcase)|\(.data | ascii_downcase)"' "$1")"
}

# Records a successful receipt: writes .sent and removes the .json and .pending files.
# Fails (after recording) when an event was expected and the target didn't emit it.
record_success() {
    local file="$1" receipt="$2" to="$3" base="${1%.json}"
    local tx topic id=""
    tx=$(jq -r '.transactionHash' <<<"$receipt")
    if [ -z "$EVENT" ]; then
        jq -n --arg tx "$tx" '{txHash: $tx}' > "$base.sent"
    else
        topic=$(cast sig-event "$EVENT")
        id=$(jq -r --arg t "$topic" --arg a "$to" \
            '[.logs[] | select(.topics[0] == $t and (.address | ascii_downcase) == ($a | ascii_downcase))][0].topics[1] // empty' \
            <<<"$receipt")
        if [ -n "$id" ]; then
            id=$(cast to-dec "$id")
            echo "   id:    $id"
            jq -n --arg tx "$tx" --arg id "$id" '{txHash: $tx, proposalId: $id}' > "$base.sent"
        else
            jq -n --arg tx "$tx" '{txHash: $tx}' > "$base.sent"
        fi
    fi
    rm -f "$file" "$base.pending"
    if [ -n "$EVENT" ] && [ -z "$id" ]; then
        echo "Error: $tx succeeded but $to emitted no $EVENT: check what it did (recorded as sent)" >&2
        return 1
    fi
}

# Applies a receipt: 0 success, 1 failure.
apply_receipt() {
    local file="$1" receipt="$2" to="$3"
    if [ "$(jq -r '.status' <<<"$receipt")" = "0x1" ]; then
        record_success "$file" "$receipt" "$to"
    else
        rm -f "${file%.json}.pending"
        echo "Error: the transaction reverted (file kept: run again to send it again)" >&2
        return 1
    fi
}

# Explains an await_receipt outcome other than "mined" (1: not mined in time, 2: the lookup failed)
not_confirmed() {
    local outcome="$1" tx="$2" base="$3"
    if [ "$outcome" = 2 ]; then
        echo "Error: can't read the receipt of $tx on $(rpc_host): kept in $base.pending, run again" >&2
    else
        echo "Error: no receipt for $tx yet: kept in $base.pending, run again to check it" >&2
    fi
}

# Sends one file on the active network. Exit code: 0 sent, 2 declined, anything else not sent.
send_one() {
    local file="$1" name="$2" base="${1%.json}"
    local chain to data rpc_chain from gas nonce raw tx published receipt outcome errors
    env_load || return 1
    chain=$(jq -r '.chainId // ""' "$file") && to=$(jq -r '.to // ""' "$file") && data=$(jq -r '.data // ""' "$file") \
        || { echo "Error: $file is not valid JSON" >&2; return 1; }
    [[ "$chain" =~ ^[0-9]+$ ]] || { echo "Error: $file: \"chainId\" is not a number: '$chain'" >&2; return 1; }
    [[ "$to" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "Error: $file: \"to\" is not an address: '$to'" >&2; return 1; }
    [[ "$data" =~ ^0x([0-9a-fA-F]{2})*$ ]] || { echo "Error: $file: \"data\" is not hex: '$data'" >&2; return 1; }

    # The chain the RPC actually serves must be the network's and the file's
    rpc_chain=$(cast chain-id --rpc-url "$RPC_URL") || { echo "Error: can't reach the RPC of $name" >&2; return 1; }
    [ "$rpc_chain" = "$CHAIN_ID" ] || { echo "Error: the RPC of $name serves chain $rpc_chain, not $CHAIN_ID" >&2; return 1; }
    [ "$chain" = "$CHAIN_ID" ] || { echo "Error: $file is for chain $chain, but $name is chain $CHAIN_ID" >&2; return 1; }

    # A transaction already signed for this file: its outcome first, never a second one while unknown
    if [ -f "$base.pending" ]; then
        resolve_pending "$file" "$to"
        return
    fi

    from=$(cast wallet address $TX_SIGNER) || { echo "Error: can't read the signer's address" >&2; return 1; }
    gas=$(just resolve-gas-params) || return 1
    # The next nonce including the signer's transactions not mined yet, so none of them is replaced
    nonce=$(cast nonce "$from" --block pending --rpc-url "$RPC_URL") || { echo "Error: can't read the nonce of $from" >&2; return 1; }
    printf "\n== %s (chain %s)\n   rpc:   %s\n   from:  %s (nonce %s)\n   to:    %s\n   data:  %s\n   flags: %s\n" \
        "$name" "$rpc_chain" "$(rpc_host)" "$from" "$nonce" "$to" "$data" "${gas:-none}"
    local answer=""
    read -r -p "Send? [y/N] " answer || true
    [ "$answer" = "y" ] || return 2

    # Sign, record, then broadcast: no transaction can be broadcast without being recorded first
    raw=$(cast mktx $TX_SIGNER $gas --from "$from" --nonce "$nonce" --rpc-url "$RPC_URL" "$to" "$data") \
        || { echo "Error: signing failed" >&2; return 1; }
    tx=$(cast keccak "$raw")
    jq -n --arg tx "$tx" --arg nonce "$nonce" --arg from "$from" --arg raw "$raw" --arg content "$(content_hash "$file")" \
        '{txHash: $tx, nonce: ($nonce | tonumber), from: $from, raw: $raw, fileHash: $content}' > "$base.pending" \
        && [ -s "$base.pending" ] \
        || { echo "Error: can't write $base.pending: nothing broadcast" >&2; return 1; }
    echo "   tx:    $tx"
    errors=$(mktemp)
    if ! published=$(cast publish --async "$raw" --rpc-url "$RPC_URL" 2>"$errors"); then
        echo "Error: the broadcast failed: $(cat "$errors")" >&2
        echo "   Kept in $base.pending: the next run broadcasts the same transaction again (see the README if its fee is too low)." >&2
        rm -f "$errors"
        return 1
    fi
    rm -f "$errors"
    # Record the hash the node reports next to the computed one, and look up both from now on
    published=$(tr -d '"' <<<"$published" | tr 'A-F' 'a-f')
    jq --arg p "$published" '.publishedHash = $p' "$base.pending" > "$base.pending.tmp" && mv "$base.pending.tmp" "$base.pending"
    if [ "$published" != "$tx" ]; then
        echo "Error: the node reports $published for the transaction signed as $tx: both kept in $base.pending, run again to check them" >&2
        return 1
    fi
    receipt=$(await_receipt "$TX_RECEIPT_TIMEOUT" "$tx"); outcome=$?
    [ "$outcome" = 0 ] || { not_confirmed "$outcome" "$tx" "$base"; return 1; }
    apply_receipt "$file" "$receipt" "$to"
}

# Resolves <network>.pending: the transaction signed for this file earlier, whose outcome isn't known.
#   - The file must still be the one that was signed; otherwise nothing is resolved.
#   - It has a receipt: applied as for a new send.
#   - The receipt can't be read (an RPC error): unknown, kept for the next run.
#   - Not mined, and its nonce is still the signer's next one: the same signed transaction is broadcast
#     again (it can only ever be mined once) and its receipt awaited.
#   - Not mined, and the signer's nonce has moved past it: either it was mined and this RPC lags behind, or
#     another transaction used that nonce. The receipt is read once more; if still absent, what this RPC
#     observed is printed, and only a person, after checking an explorer, may delete the .pending file.
resolve_pending() {
    local file="$1" to="$2" base="${1%.json}"
    local tx published nonce from raw content receipt outcome current
    tx=$(jq -r '.txHash // ""' "$base.pending"); published=$(jq -r '.publishedHash // ""' "$base.pending")
    # One lookup per distinct hash: the node usually reports the same hash as the signed one
    [ "$published" != "$tx" ] || published=""
    nonce=$(jq -r '.nonce // ""' "$base.pending"); content=$(jq -r '.fileHash // ""' "$base.pending")
    from=$(jq -r '.from // ""' "$base.pending"); raw=$(jq -r '.raw // ""' "$base.pending")
    [[ "$nonce" =~ ^[0-9]+$ ]] && [ -n "$raw" ] && [ -n "$from" ] && [ -n "$content" ] \
        || { echo "Error: $base.pending is incomplete: check $tx by hand" >&2; return 1; }
    printf "   pending: %s (nonce %s of %s)\n   pending to:   %s\n   pending data: %s\n" "$tx" "$nonce" "$from" \
        "$(cast decode-transaction "$raw" | jq -r .to)" "$(cast decode-transaction "$raw" | jq -r .input)"
    if [ "$(content_hash "$file")" != "$content" ]; then
        echo "Error: $file changed since $tx was signed: restore it, or delete $base.pending after checking the transaction on an explorer" >&2
        return 1
    fi

    receipt=$(await_receipt 0 "$tx" "$published"); outcome=$?
    [ "$outcome" = 0 ] && { apply_receipt "$file" "$receipt" "$to"; return; }
    [ "$outcome" = 2 ] && { not_confirmed 2 "$tx" "$base"; return 1; }

    current=$(cast nonce "$from" --rpc-url "$RPC_URL") || { echo "Error: can't read the nonce of $from on $(rpc_host): run again" >&2; return 1; }
    if [ "$current" -le "$nonce" ]; then
        # Already known to the node, or dropped: either way the same bytes, never a second transaction
        cast publish --async "$raw" --rpc-url "$RPC_URL" >/dev/null 2>&1 || true
        receipt=$(await_receipt "$TX_RECEIPT_TIMEOUT" "$tx" "$published"); outcome=$?
        [ "$outcome" = 0 ] || { not_confirmed "$outcome" "$tx" "$base"; return 1; }
        apply_receipt "$file" "$receipt" "$to"
        return
    fi

    # The nonce moved: the transaction may have been mined after the first lookup
    receipt=$(await_receipt 0 "$tx" "$published"); outcome=$?
    [ "$outcome" = 0 ] && { apply_receipt "$file" "$receipt" "$to"; return; }
    [ "$outcome" = 2 ] && { not_confirmed 2 "$tx" "$base"; return 1; }
    echo "   On $(rpc_host): no receipt for $tx, and nonce $nonce of $from has been used."
    echo "Error: if an explorer confirms $tx is absent, delete $base.pending and run again" >&2
    return 1
}

NETWORKS=$(for f in lib/just-foundry/networks/*.env; do basename "$f" .env; done)
NOT_SENT=()
shopt -s nullglob
for file in "$DIR"/*.json; do
    name=$(basename "$file" .json)
    if [ -f "$DIR/$name.sent" ]; then
        echo "SKIP    $name: already sent ($(jq -c . "$DIR/$name.sent"))"
        continue
    fi
    # Exactly a network's name: file systems that ignore case would otherwise accept Polygon.json
    if ! grep -qxF -- "$name" <<<"$NETWORKS"; then
        echo "FAILED  $name: no network named $name"
        NOT_SENT+=("$name")
        continue
    fi
    if [ ! -f "$DIR/$name.pending" ] && [ -n "$(find "$file" -mmin +"$MAX_AGE")" ]; then
        echo "STALE   $name: $file is older than $MAX_AGE minutes, generate it again"
        NOT_SENT+=("$name")
        continue
    fi
    just switch "$name" >/dev/null || { NOT_SENT+=("$name"); continue; }
    # A subshell: the network's environment doesn't reach the next one
    ( send_one "$file" "$name" )
    case $? in
        0) echo "SENT    $name" ;;
        2) echo "SKIP    $name: declined" ;;
        *) echo "FAILED  $name"; NOT_SENT+=("$name") ;;
    esac
done

[ -z "${NOT_SENT[*]:-}" ] || { echo "Not sent: ${NOT_SENT[*]}"; exit 1; }
