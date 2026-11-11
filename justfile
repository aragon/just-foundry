# NOTE: All recipes imported from this file will run on the path importing it

set shell := ["bash", "-c"]
set dotenv-load := false
set allow-duplicate-variables
set allow-duplicate-recipes

JUST_LIB := "lib/just-foundry/lib.sh"
DEPLOY_SCRIPT := "script/Deploy.s.sol:DeployScript"

# Show available commands
help:
    @just --list --unsorted

# Select the active network (pass "override" to create a local editable copy)
[group('setup')]
switch network override="":
    #!/usr/bin/env bash
    set -euo pipefail
    TEMPLATE="lib/just-foundry/networks/{{ network }}.env"
    if [ ! -f "$TEMPLATE" ]; then
        echo "Error: network '{{ network }}' not found."
        just networks
        exit 1
    fi
    ln -sf "networks/{{ network }}.env" lib/just-foundry/.env
    if [ -n "{{ override }}" ] && [ "{{ override }}" != "override" ]; then
        echo "Error: unknown option '{{ override }}'. Did you mean: just switch {{ network }} override" >&2
        exit 1
    fi
    if [ "{{ override }}" = "override" ]; then
        LOCAL=".env.{{ network }}"
        if [ -f "$LOCAL" ]; then
            echo "Override '$LOCAL' already exists. Skipping copy."
        else
            cp "$TEMPLATE" "$LOCAL"
            echo "Created local override: $LOCAL"
        fi
    fi
    echo "Switched to network: {{ network }}"

# List the available networks and their chain IDs (* = active)
[group('setup')]
networks:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }}
    DIR="{{ source_directory() }}/networks"
    ACTIVE=$(env_active_network)
    echo "Available networks:"
    for f in "$DIR"/*.env; do
        NAME=$(basename "$f" .env)
        CHAIN_ID=$(sed -n 's/^CHAIN_ID="\{0,1\}\([0-9]*\)"\{0,1\}$/\1/p' "$f")
        MARK=" "; [ "$NAME" = "$ACTIVE" ] && MARK="*"
        printf "  %s %-18s %s\n" "$MARK" "$NAME" "$CHAIN_ID"
    done

# Install Foundry if missing
[group('setup')]
setup:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v forge &>/dev/null; then
        echo "Foundry is already installed ($(forge --version | head -1))"
    else
        echo "Installing Foundry..."
        curl -L https://foundry.paradigm.xyz | bash
        # Called by path: the installer only adds ~/.foundry/bin to PATH for new shells
        "$HOME/.foundry/bin/foundryup"
    fi
    if ! command -v vars &>/dev/null; then
        echo "Note: 'vars' is optional but recommended. Install it with 'just install-vars', or define your secrets in .env."
    fi

# Install foundry-zksync alongside standard Foundry (forge-zksync / cast-zksync)
[private]
setup-zksync:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v forge-zksync &>/dev/null; then
        echo "forge-zksync is already installed ($(forge-zksync --version | head -1))"
        exit 0
    fi
    echo "Installing foundry-zksync..."
    curl -L https://raw.githubusercontent.com/matter-labs/foundry-zksync/main/install-foundry-zksync | bash
    "$HOME/.foundry/bin/foundryup-zksync"
    mv ~/.foundry/bin/forge ~/.foundry/bin/forge-zksync
    mv ~/.foundry/bin/cast ~/.foundry/bin/cast-zksync
    echo "Reinstalling standard Foundry to restore forge / cast..."
    just setup
    echo "Done. Use 'forge' for standard EVM and 'forge-zksync' for ZkSync networks."

# Install vars (secret manager — recommended, https://github.com/vars-cli/vars)
[private]
install-vars:
    #!/usr/bin/env bash
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -L "https://github.com/vars-cli/vars/releases/download/v0.3.0/vars_0.3.0_${OS}_${ARCH}.tar.gz" | tar xz
    sudo mv vars /usr/local/bin/
    echo "vars installed on /usr/local/bin/."

# Dry-run the deploy script (no broadcast)
[group('script')]
predeploy:
    just dry-run {{ DEPLOY_SCRIPT }}

# Deploy: run tests then broadcast (logs to logs/<contract>-<network>-<timestamp>.log)
[group('script')]
deploy *args:
    just test
    just run {{ DEPLOY_SCRIPT }} {{ args }}

# Broadcast a forge script — log name is derived from the contract name (or filename)
[group('script-base')]
run script *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load --verbose
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    SCRIPT_PARAMS=$(just resolve-script-params) || exit 1
    VERIFIER_PARAMS=$(just resolve-verifier-params) || exit 1
    NAME=$(basename "{{ script }}")
    if [[ "$NAME" == *:* ]]; then
        NAME="${NAME##*:}"      # contract name after the colon
    else
        NAME="${NAME%.s.sol}"   # strip .s.sol or .sol extension
        NAME="${NAME%.sol}"
    fi
    LOG="logs/${NAME}-$NETWORK_NAME-$(date +%y-%m-%d-%H-%M).log"
    mkdir -p logs
    CMD=($FORGE script {{ script }} \
        --rpc-url "$RPC_URL" \
        --retries 10 --delay 10 \
        --broadcast --verify \
        $BUILD_PARAMS $SCRIPT_PARAMS $VERIFIER_PARAMS \
        -vvv {{ args }})
    run_logged "$LOG" "${CMD[@]}"
    echo "Log: $LOG"

# Simulate running a forge script (no broadcast)
[group('script-base')]
dry-run script:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load --verbose
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    SCRIPT_PARAMS=$(just resolve-script-params) || exit 1
    export SIMULATION=true
    $FORGE script {{ script }} \
        --rpc-url "$RPC_URL" \
        $BUILD_PARAMS $SCRIPT_PARAMS \
        -vvv

# Print the address of the latest deployment of a contract in the active network's broadcast (zk_contract: its name on zkSync, if different)
[group('script-base')]
deployed-address contract script="" zk_contract="":
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    SCRIPT="{{ if script == "" { DEPLOY_SCRIPT } else { script } }}"
    NAME="{{ contract }}"
    case "$CHAIN_ID" in 300|324) [ -z "{{ zk_contract }}" ] || NAME="{{ zk_contract }}" ;; esac
    BROADCAST="broadcast/$(basename "${SCRIPT%%:*}")/$CHAIN_ID/run-latest.json"
    bash lib/just-foundry/scripts/deployments.sh "$BROADCAST" "$CHAIN_ID" "$NAME" | cut -f2

# Run a recipe on every network, each in its own process, logging to logs/<recipe>-<network>-<timestamp>.log; restores the active network
[group('script-base')]
[positional-arguments]
each-network recipe *args:
    #!/usr/bin/env bash
    set -uo pipefail
    source {{ JUST_LIB }}
    # Positional arguments: the recipe's own arguments reach it exactly as given, spaces and quotes included
    RECIPE="$1"; shift
    ACTIVE=$(env_active_network)
    # Put back the network that was active, or none if none was
    trap 'if [ -n "$ACTIVE" ]; then just switch "$ACTIVE" >/dev/null; else rm -f lib/just-foundry/.env; fi' EXIT
    mkdir -p logs
    STAMP=$(date +%y-%m-%d-%H-%M)
    FAILED=()
    for f in lib/just-foundry/networks/*.env; do
        NAME=$(basename "$f" .env)
        LOG="logs/$RECIPE-$NAME-$STAMP.log"
        # A new `just` process per network: no environment carries over, and a failure doesn't stop the loop
        if just switch "$NAME" >/dev/null && just "$RECIPE" ${1+"$@"} > "$LOG" 2>&1; then
            echo "ok      $NAME"
        else
            echo "FAILED  $NAME (see $LOG)"
            FAILED+=("$NAME")
        fi
    done
    [ -z "${FAILED[*]:-}" ] || { echo "Failed on: ${FAILED[*]}"; exit 1; }

# Run all unit tests
[group('test')]
test *args:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    ETHERSCAN_API_KEY="" $FORGE test $BUILD_PARAMS -vvv --no-match-path "./test/*fork*/*.sol" {{ args }}

# Run fork tests (requires RPC_URL)
[group('test')]
test-fork *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load --verbose
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    $FORGE test $BUILD_PARAMS -vvv \
        --match-path "./test/*fork*/*.sol" \
        --rpc-url "$RPC_URL" \
        ${FORK_BLOCK_NUMBER:+--fork-block-number $FORK_BLOCK_NUMBER} \
        {{ args }}

# Generate HTML coverage report under ./report
[group('test')]
test-coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    which lcov > /dev/null || { echo "Error: install lcov (sudo apt install lcov)"; exit 1; }
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    $FORGE coverage --report lcov $BUILD_PARAMS
    lcov --remove lcov.info -o lcov.info.pruned 'test/**/*.sol' 'script/**/*.sol'
    genhtml lcov.info.pruned -o report
    which open > /dev/null && open report/index.html || true
    which xdg-open > /dev/null && xdg-open report/index.html || true

# Show current environment (resolved values + sources)
[group('helpers')]
env:
    #!/usr/bin/env bash
    source {{ JUST_LIB }}
    env_show

# Pin a file to IPFS via Pinata (requires PINATA_JWT in vars or .env)
[group('helpers')]
ipfs-pin file:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    bash lib/just-foundry/scripts/ipfs-pin.sh "{{ file }}"

# Clean compiler artifacts and coverage reports
[group('develop')]
clean:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    FORGE=$(just resolve-forge) || exit 1
    $FORGE clean
    rm -rf ./out ./zkout lcov.info* ./report

# Show the storage layout of a contract
[group('develop')]
storage-info contract:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    FORGE=$(just resolve-forge) || exit 1
    $FORGE inspect {{ contract }} storage-layout

# Check storage layout upgrade compatibility between two contracts (requires jq)
# Example: just check-upgrade MyContractV1 MyContractV2
[group('develop')]
check-upgrade from to:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v jq &>/dev/null || { echo "Error: jq is required (sudo apt install jq / brew install jq)"; exit 1; }
    source {{ JUST_LIB }} && env_load
    FORGE=$(just resolve-forge) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    $FORGE build --quiet $BUILD_PARAMS
    REF=$($FORGE inspect {{ from }} storage-layout --json)
    NEW=$($FORGE inspect {{ to }} storage-layout --json)
    ERRORS=0
    while IFS=$'\t' read -r slot offset label; do
        match=$(echo "$NEW" | jq -r --arg s "$slot" --argjson o "$offset" --arg l "$label" \
            '.storage[] | select(.slot==$s and .offset==$o and .label==$l) | .label')
        if [ -z "$match" ]; then
            echo "  INCOMPATIBLE: '$label' at slot $slot offset $offset — missing or moved in {{ to }}"
            ERRORS=$((ERRORS + 1))
        fi
    done < <(echo "$REF" | jq -r '.storage[] | select(.label != "__gap") | [.slot, .offset, .label] | @tsv')
    if [ "$ERRORS" -gt 0 ]; then
        echo "Storage layout check FAILED ($ERRORS incompatible slot(s)): {{ from }} → {{ to }}"
        exit 1
    fi
    echo "Storage layout check passed: {{ from }} → {{ to }} is safe to upgrade"

# Sync networks/*.env from artifacts-hub JSONs (--dry-run to preview, --force to overwrite conflicts)
[group('maintenance')]
sync-addresses *args:
    #!/usr/bin/env bash
    bash "{{ source_directory() }}/scripts/sync-addresses.sh" {{ args }}

# Start a forked EVM (set FORK_BLOCK_NUMBER in .env to pin a block)
[group('develop')]
anvil:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load --verbose
    anvil -f "$RPC_URL" ${FORK_BLOCK_NUMBER:+--fork-block-number $FORK_BLOCK_NUMBER}

# Verify the latest deployment of each contract in the latest broadcast, EVM or zkSync (type: etherscan|blockscout|sourcify)
[group('verification')]
verify type="" script="":
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load --verbose
    [ -n "{{ type }}" ] && export VERIFIER="{{ type }}"
    SCRIPT="{{ if script == "" { DEPLOY_SCRIPT } else { script } }}"
    [ "${VERIFIER:-}" != "etherscan" ] && unset ETHERSCAN_API_KEY
    VERIFIER_PARAMS=$(just resolve-verifier-params) || exit 1
    BUILD_PARAMS=$(just resolve-build-params) || exit 1
    SCRIPT_FILE=$(basename "$SCRIPT" | cut -d: -f1)
    FORGE=$(just resolve-forge) || exit 1
    FORGE="$FORGE" bash lib/just-foundry/scripts/verify-contracts.sh "$CHAIN_ID" "$SCRIPT_FILE" $BUILD_PARAMS $VERIFIER_PARAMS

# Flatten every concrete src/ contract (or one), plus ABI-encoded ctor args from broadcast/. See README > "Flatten for manual verification".
[group('verification')]
flatten target="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "{{ target }}" ]; then
        just _flatten-one "{{ target }}"
        exit 0
    fi
    count=0
    while IFS= read -r src; do
        base=$(basename "$src")
        [ -d "out/$base" ] || continue
        for out_json in out/"$base"/*.json; do
            [ -e "$out_json" ] || continue
            bc_len=$(jq -r '.bytecode.object // "" | length' "$out_json" 2>/dev/null || echo 0)
            [ "${bc_len:-0}" -gt 2 ] || continue
            NAME=$(basename "$out_json" .json)
            just _flatten-one "${src}:${NAME}"
            count=$((count + 1))
        done
    done < <(find src -type f -name '*.sol')
    [ "$count" -gt 0 ] || { echo "No concrete contracts under src/. Did you 'forge build' first?" >&2; exit 1; }

# Flatten one <src.sol:Name>; write flat/<Name>.args.txt when the active network has a matching deployment.
[private]
_flatten-one target:
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET="{{ target }}"
    [[ "$TARGET" == *:* ]] || { echo "Expected <path/to/Contract.sol:ContractName>, got '$TARGET'" >&2; exit 1; }
    SRC="${TARGET%%:*}"; NAME="${TARGET##*:}"
    mkdir -p flat
    grep -qE '^flat/?$' .gitignore 2>/dev/null || echo 'flat/' >> .gitignore
    forge flatten "$SRC" > "flat/${NAME}.flat.sol"
    echo "Flattened → flat/${NAME}.flat.sol"

    source {{ JUST_LIB }} && env_load 2>/dev/null || true
    [ -z "${CHAIN_ID:-}" ] && exit 0

    # The latest deployment of NAME, in the most recent of the network's broadcasts that deployed it at all.
    # When that one didn't succeed, no arguments: never an older deployment's, as for deployed-address.
    row=""; from=""; latest=-1
    for broadcast in broadcast/*/"${CHAIN_ID}"/run-latest.json; do
        [ -e "$broadcast" ] || continue
        found=$(bash lib/just-foundry/scripts/deployments.sh "$broadcast" "$CHAIN_ID" 2>/dev/null \
            | awk -F'\t' -v n="$NAME" '$1 == n { line = $0 } END { print line }') || continue
        [ -n "$found" ] || continue
        timestamp=$(jq -r '.timestamp // 0' "$broadcast")
        [ "$timestamp" -ge "$latest" ] || continue
        row="$found"; from="$broadcast"; latest="$timestamp"
    done
    [ -n "$row" ] || exit 0
    status=$(cut -f3 <<<"$row"); args=$(cut -f4 <<<"$row")
    if [ "$status" != "ok" ]; then
        echo "Args      skipped: the latest deployment of $NAME in $from $([ "$status" = reverted ] && echo reverted || echo was not mined)"
        exit 0
    fi
    [ -n "$args" ] && [ "$args" != "?" ] || exit 0
    echo "$args" > "flat/${NAME}.args.txt"
    echo "Args      → flat/${NAME}.args.txt"

# Forge binary: forge for standard EVM, forge-zksync for ZkSync networks (chain 324/300)
[private]
resolve-forge:
    #!/usr/bin/env bash
    source {{ JUST_LIB }}
    env_load || exit 1  # always: a CHAIN_ID left in the shell must not win over the active network
    case "${CHAIN_ID:-}" in
        324|300)
            command -v forge-zksync &>/dev/null || { echo "Error: forge-zksync is not installed. Run 'just setup-zksync'." >&2; exit 1; }
            echo "forge-zksync"
            ;;
        *)
            echo "forge"
    esac

# Compiler flags (--zksync for ZkSync networks)
[private]
resolve-build-params:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    case "${CHAIN_ID:-}" in
        324|300)
            echo "--zksync"
            ;;
    esac

# Script execution flags: the chain's gas flags, plus --slow on ZkSync
[private]
resolve-script-params:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }}
    env_load || exit 1  # always: a CHAIN_ID left in the shell must not win over the active network
    GAS_PARAMS=$(just resolve-gas-params)
    case "${CHAIN_ID:-}" in
        324|300) echo "--slow${GAS_PARAMS:+ $GAS_PARAMS}" ;;
        *) echo "$GAS_PARAMS" ;;
    esac

# Chain-specific gas flags, accepted by both `forge script` and `cast send`
[private]
resolve-gas-params:
    #!/usr/bin/env bash
    source {{ JUST_LIB }}
    env_load || exit 1  # always: a CHAIN_ID left in the shell must not win over the active network
    case "${CHAIN_ID:-}" in
        43111)
            echo "--legacy --gas-price 100000000"
            ;;
        88888)
            echo "--legacy --gas-price 5200000000000"
            # echo "--gas-price 5200000000000 --priority-gas-price 1000000000"
            ;;
    esac

# Verifier flags (reads VERIFIER, BLOCKSCOUT_HOST_NAME, ETHERSCAN_API_KEY from env)
[private]
resolve-verifier-params:
    #!/usr/bin/env bash
    case "${VERIFIER:-}" in
        etherscan)
            # forge auto-detects etherscan and reads ETHERSCAN_API_KEY from env directly
            [ -n "${ETHERSCAN_API_KEY:-}" ] || { echo "Error: ETHERSCAN_API_KEY is not set" >&2; exit 1; }
            ;;
        blockscout)
            [ -n "${BLOCKSCOUT_HOST_NAME:-}" ] || { echo "Error: BLOCKSCOUT_HOST_NAME is not set" >&2; exit 1; }
            echo "--verifier blockscout --verifier-url https://$BLOCKSCOUT_HOST_NAME/api?" ;;
        sourcify)
            echo "--verifier sourcify" ;;
        zksync)
            if [ "${CHAIN_ID:-}" = "300" ]; then
                echo "--verifier zksync --verifier-url https://explorer.sepolia.era.zksync.dev/contract_verification"
            elif [ "${CHAIN_ID:-}" = "324" ]; then
                echo "--verifier zksync --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification"
            fi ;;
        routescan-mainnet)
            echo "--verifier custom --verifier-url https://api.routescan.io/v2/network/mainnet/evm/$CHAIN_ID/etherscan --etherscan-api-key verifyContract" ;;
        routescan-testnet)
            echo "--verifier custom --verifier-url https://api.routescan.io/v2/network/testnet/evm/$CHAIN_ID/etherscan --etherscan-api-key verifyContract" ;;
        *)
            echo "Error: unsupported verifier '${VERIFIER:-}'. Supported: etherscan, blockscout, sourcify, zksync, routescan-mainnet, routescan-testnet" >&2
            exit 1 ;;
    esac

# --- Debug helpers (not listed — see lib/just-foundry/README.md) ---

# Show current wallet balance
[group('helpers')]
balance:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")
    BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")
    echo "Balance of $DEPLOYER_ADDRESS ($NETWORK_NAME):"
    cast --to-unit "$BALANCE" ether

[private]
gas-price:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    echo "Gas price ($NETWORK_NAME):"
    cast gas-price --rpc-url "$RPC_URL"

[private]
nonce:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")
    cast nonce "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL"

# Cancel a stuck transaction by sending a 0-value tx at the same nonce
[private]
clean-nonce nonce:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")
    cast send --private-key "$DEPLOYER_KEY" $(just resolve-gas-params) \
        --rpc-url "$RPC_URL" \
        --value 0 \
        --nonce {{ nonce }} \
        "$DEPLOYER_ADDRESS"

# Cancel multiple stuck transactions: just clean-nonces "2 3 4"
[private]
clean-nonces *nonces:
    #!/usr/bin/env bash
    for nonce in {{ nonces }}; do
        just clean-nonce "$nonce"
    done

# Transfer remaining deployer balance to REFUND_ADDRESS
[private]
refund:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    if [ -z "${REFUND_ADDRESS:-}" ] || [[ "$REFUND_ADDRESS" =~ ^0x0{39}[0-9a-fA-F]$ ]]; then
        echo "REFUND_ADDRESS is not set. Aborting."
        exit 1
    fi
    DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_KEY")
    BALANCE=$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC_URL")
    GAS_PARAMS=$(just resolve-gas-params)
    # The price the transaction will pay: the chain's forced --gas-price if it has one, else the node's
    GAS_PRICE=$(sed -n 's/.*--gas-price \([0-9]*\).*/\1/p' <<<"$GAS_PARAMS")
    [ -n "$GAS_PRICE" ] || GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
    SPENDABLE=$(echo "$BALANCE - $GAS_PRICE * 50000" | bc)
    if [ "$(echo "$SPENDABLE > 0" | bc)" = "0" ]; then
        echo "Insufficient balance to cover gas. Aborting."
        exit 1
    fi
    echo "Refunding $SPENDABLE wei → $REFUND_ADDRESS"
    read -rp "Continue? (y/N) " CONFIRM
    [ "$CONFIRM" = "y" ] || { echo "Aborting"; exit 1; }
    cast send --private-key "$DEPLOYER_KEY" $GAS_PARAMS \
        --rpc-url "$RPC_URL" \
        --value "$SPENDABLE" \
        "$REFUND_ADDRESS"
