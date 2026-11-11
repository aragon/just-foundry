#!/usr/bin/env bash
# verify-contracts.sh — verify the latest deployment of each contract in the latest broadcast (one that reverted
# or was never mined counts as a failure)
# Usage: [FORGE=forge-zksync] verify-contracts.sh <chain_id> <script_file> [forge verify-contract flags...]
# Reads the deployments with deployments.sh, so standard EVM and zkSync broadcasts are both covered.
set -euo pipefail

CHAIN_ID="$1"
SCRIPT_FILE="$2"
shift 2
FORGE="${FORGE:-forge}"

BROADCAST="broadcast/${SCRIPT_FILE}/${CHAIN_ID}/run-latest.json"
DEPLOYMENTS=$(bash "$(dirname "$0")/deployments.sh" "$BROADCAST" "$CHAIN_ID")

echo "Verifying contracts from: $BROADCAST"
echo ""

PASS=0
FAIL=0

# The latest deployment of each contract, in broadcast order
while IFS=$'\t' read -r NAME ADDRESS STATUS ARGS; do
    [ -n "$NAME" ] || continue
    if [ "$STATUS" != "ok" ]; then
        # Never an older deployment instead: the latest one is what the release would use
        echo "--- $NAME ($ADDRESS): the latest deployment $([ "$STATUS" = reverted ] && echo reverted || echo was not mined), not verified"
        FAIL=$((FAIL + 1))
        echo ""
        continue
    fi
    case "$ARGS" in
        "?") ARGS_FLAGS=(--guess-constructor-args) ;;  # no artifact to read them from
        "") ARGS_FLAGS=() ;;
        *) ARGS_FLAGS=(--constructor-args "$ARGS") ;;
    esac

    echo "--- $NAME ($ADDRESS)"
    if "$FORGE" verify-contract \
            --watch \
            --chain "$CHAIN_ID" \
            --rpc-url "$RPC_URL" \
            ${ARGS_FLAGS[@]+"${ARGS_FLAGS[@]}"} \
            "$@" \
            "$ADDRESS" "$NAME"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "  [FAILED]"
    fi
    echo ""
done < <(awk -F'\t' '!/^unknown:/ { last[$1] = NR; line[NR] = $0 }
    END { for (i = 1; i <= NR; i++) if (i in line) { split(line[i], f, "\t"); if (last[f[1]] == i) print line[i] } }' <<<"$DEPLOYMENTS")

echo "$PASS verified, $FAIL failed"
[ "$FAIL" -eq 0 ]
