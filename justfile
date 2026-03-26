# NOTE: All recipes imported from this file will run on the path importing it
set shell := ["bash", "-c"]
set dotenv-load := false

ENV_RESOLVE_LIB := "lib/just-foundry/env.sh"
DEPLOY_SCRIPT := "script/Deploy.s.sol:DeployScript"   # Default deploy script: override in root justfile

# Show available commands
help:
    @just --list --unsorted

# Initialize the project for a given network (default: mainnet)
[group('setup')]
init network="mainnet":
    #!/usr/bin/env bash
    if ! command -v forge &>/dev/null; then
        echo "Error: Foundry is not installed. Run 'just setup' to install it."
        exit 1
    fi
    if ! command -v vars &>/dev/null; then
        echo "Note: 'vars' is not installed. It is recommended but entirely optional."
        echo "      You can copy .env.example into .env and define your secrets there."
        echo "      You can install vars with 'just install-vars'"
    fi
    just switch {{network}}
    git submodule update --init --recursive

# Select the active network
[group('setup')]
switch network:
    #!/usr/bin/env bash
    set -euo pipefail
    NETWORKS_DIR="lib/just-foundry/networks"
    if [ ! -f "$NETWORKS_DIR/{{network}}.env" ]; then
        echo "Error: network '{{network}}' not found."
        echo "Available networks: $(ls "$NETWORKS_DIR"/*.env | xargs -I{} basename {} .env | tr '\n' ' ')"
        exit 1
    fi
    ln -sf "networks/{{network}}.env" lib/just-foundry/.env
    echo "Using network: {{network}}"

# Install Foundry
[group('setup')]
setup:
    curl -L https://foundry.paradigm.xyz | bash

# Install vars (secret manager — recommended, https://github.com/vars-cli/vars)
[private]
install-vars:
    #!/usr/bin/env bash
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    curl -L "https://github.com/vars-cli/vars/releases/download/v0.1.0/vars_0.1.0_${OS}_${ARCH}.tar.gz" | tar xz
    sudo mv vars /usr/local/bin/
    echo "vars installed."

# Simulate the deploy script
[group('script')]
predeploy:
    just simulate {{DEPLOY_SCRIPT}}

# Deploy: run tests, broadcast, tee to log
[group('script')]
deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_network_env
    mkdir -p logs artifacts
    LOG_FILE="logs/deployment-$NETWORK_NAME-$(date +"%y-%m-%d-%H-%M").log"
    just test 2>&1 | tee -a "$LOG_FILE"
    just run {{DEPLOY_SCRIPT}} 2>&1 | tee -a "$LOG_FILE"
    echo "Logs saved in $LOG_FILE"

# Resume a pending deployment
[group('script')]
resume-deploy:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_network_env
    mkdir -p logs artifacts
    LOG_FILE="logs/deployment-$NETWORK_NAME-$(date +"%y-%m-%d-%H-%M").log"
    just run {{DEPLOY_SCRIPT}} --resume 2>&1 | tee -a "$LOG_FILE"
    echo "Logs saved in $LOG_FILE"

# Run a forge script (broadcast)
[group('script')]
run script *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_env
    BUILD_PARAMS=$(just resolve-build-params)
    SCRIPT_PARAMS=$(just resolve-script-params)
    VERIFIER_PARAMS=$(just resolve-verifier-params)
    forge script {{script}} \
        --rpc-url "$RPC_URL" \
        --retries 10 --delay 10 \
        --broadcast --verify \
        $BUILD_PARAMS $SCRIPT_PARAMS $VERIFIER_PARAMS \
        -vvv {{args}}

# Simulate a forge script (no broadcast)
[group('script')]
simulate script:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_env
    export SIMULATION=true
    echo "export SIMULATION=true"
    BUILD_PARAMS=$(just resolve-build-params)
    forge script {{script}} \
        --rpc-url "$RPC_URL" \
        $BUILD_PARAMS \
        -vvv

# Show current environment (resolved values + sources)
[group('helpers')]
env:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}}
    show_env

# Run all unit tests
[group('test')]
test *args:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_env
    BUILD_PARAMS=$(just resolve-build-params)
    ETHERSCAN_API_KEY="" forge test $BUILD_PARAMS -vvv --no-match-path "./test/*fork*/*.sol" {{args}}

# Run fork tests (requires RPC_URL)
[group('test')]
test-fork *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_env
    BUILD_PARAMS=$(just resolve-build-params)
    forge test $BUILD_PARAMS -vvv \
        --match-path "./test/*fork*/*.sol" \
        --rpc-url "$RPC_URL" \
        ${FORK_BLOCK_NUMBER:+--fork-block-number $FORK_BLOCK_NUMBER} \
        {{args}}

# Generate HTML coverage report under ./report
[group('test')]
test-coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_network_env
    which lcov > /dev/null || { echo "Error: install lcov (sudo apt install lcov)"; exit 1; }
    BUILD_PARAMS=$(just resolve-build-params)
    forge coverage --report lcov $BUILD_PARAMS
    lcov --remove lcov.info -o lcov.info.pruned 'test/**/*.sol' 'script/**/*.sol'
    genhtml lcov.info.pruned -o report
    which open > /dev/null && open report/index.html || true
    which xdg-open > /dev/null && xdg-open report/index.html || true

# Clean compiler artifacts and coverage reports
[group('develop')]
clean:
    forge clean
    rm -rf ./out ./zkout lcov.info* ./report

# Show the storage layout of a contract
[group('develop')]
storage-info contract:
    forge inspect {{contract}} storage-layout

# Start a forked EVM (set FORK_BLOCK_NUMBER in .env to pin a block)
[group('develop')]
anvil:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_env
    anvil -f "$RPC_URL" ${FORK_BLOCK_NUMBER:+--fork-block-number $FORK_BLOCK_NUMBER}

# Verify the last deployment on Etherscan
[group('verification')]
verify-etherscan script=DEPLOY_SCRIPT:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_env
    SCRIPT_FILE=$(basename "{{script}}" | cut -d: -f1)
    bash script/verify-contracts.sh "$CHAIN_ID" etherscan "https://api.etherscan.io/v2/api" "$ETHERSCAN_API_KEY" "$SCRIPT_FILE"

# Verify the last deployment on BlockScout
[group('verification')]
verify-blockscout script=DEPLOY_SCRIPT:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_network_env
    SCRIPT_FILE=$(basename "{{script}}" | cut -d: -f1)
    bash script/verify-contracts.sh "$CHAIN_ID" blockscout "https://$BLOCKSCOUT_HOST_NAME/api?" "" "$SCRIPT_FILE"

# Verify the last deployment on Sourcify
[group('verification')]
verify-sourcify script=DEPLOY_SCRIPT:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_network_env
    SCRIPT_FILE=$(basename "{{script}}" | cut -d: -f1)
    bash script/verify-contracts.sh "$CHAIN_ID" sourcify "" "" "$SCRIPT_FILE"

# Compiler flags (zksync requires --zksync)
[private]
resolve-build-params:
    #!/usr/bin/env bash
    if [ "${CHAIN_ID:-}" = "324" ] || [ "${CHAIN_ID:-}" = "300" ]; then
        echo "--zksync"
    fi

# Script execution flags (chain-specific gas/speed params)
[private]
resolve-script-params:
    #!/usr/bin/env bash
    if [ "${CHAIN_ID:-}" = "324" ] || [ "${CHAIN_ID:-}" = "300" ]; then
        echo "--slow"
    elif [ "${CHAIN_ID:-}" = "88888" ]; then
        echo "--priority-gas-price 1000000000 --gas-price 5200000000000"
    fi

# Verifier flags (reads VERIFIER, BLOCKSCOUT_HOST_NAME, ETHERSCAN_API_KEY from env)
[private]
resolve-verifier-params:
    #!/usr/bin/env bash
    case "${VERIFIER:-}" in
        etherscan)
            echo "--verifier etherscan --verifier-url https://api.etherscan.io/v2/api --etherscan-api-key $ETHERSCAN_API_KEY" ;;
        blockscout)
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
    esac

# --- Debug helpers (not listed — see lib/just-foundry/README.md) ---

# Show current wallet balance
[group('helpers')]
balance:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_env
    DEPLOYMENT_ADDRESS=$(cast wallet address "$DEPLOYMENT_PRIVATE_KEY")
    BALANCE=$(cast balance "$DEPLOYMENT_ADDRESS" --rpc-url "$RPC_URL")
    echo "Balance of $DEPLOYMENT_ADDRESS ($NETWORK_NAME):"
    cast --to-unit "$BALANCE" ether

[private]
gas-price:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_env
    echo "Gas price ($NETWORK_NAME):"
    cast gas-price --rpc-url "$RPC_URL"

[private]
nonce:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_env
    DEPLOYMENT_ADDRESS=$(cast wallet address "$DEPLOYMENT_PRIVATE_KEY")
    cast nonce "$DEPLOYMENT_ADDRESS" --rpc-url "$RPC_URL"

# Cancel a stuck transaction by sending a 0-value tx at the same nonce
[private]
clean-nonce nonce:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && load_env
    DEPLOYMENT_ADDRESS=$(cast wallet address "$DEPLOYMENT_PRIVATE_KEY")
    cast send --private-key "$DEPLOYMENT_PRIVATE_KEY" \
        --rpc-url "$RPC_URL" \
        --value 0 \
        --nonce {{nonce}} \
        "$DEPLOYMENT_ADDRESS"

# Cancel multiple stuck transactions: just clean-nonces "2 3 4"
[private]
clean-nonces nonces:
    #!/usr/bin/env bash
    for nonce in {{nonces}}; do
        just clean-nonce "$nonce"
    done

# Transfer remaining deployer balance to REFUND_ADDRESS
[private]
refund:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ENV_RESOLVE_LIB}} && load_env
    if [ -z "${REFUND_ADDRESS:-}" ] || [ "$REFUND_ADDRESS" = "0x0000000000000000000000000000000000000000" ]; then
        echo "REFUND_ADDRESS is not set. Aborting."
        exit 1
    fi
    DEPLOYMENT_ADDRESS=$(cast wallet address "$DEPLOYMENT_PRIVATE_KEY")
    BALANCE=$(cast balance "$DEPLOYMENT_ADDRESS" --rpc-url "$RPC_URL")
    GAS_PRICE=$(cast gas-price --rpc-url "$RPC_URL")
    SPENDABLE=$(echo "$BALANCE - $GAS_PRICE * 50000" | bc)
    if [ "$(echo "$SPENDABLE > 0" | bc)" = "0" ]; then
        echo "Insufficient balance to cover gas. Aborting."
        exit 1
    fi
    echo "Refunding $SPENDABLE wei → $REFUND_ADDRESS"
    read -rp "Continue? (y/N) " CONFIRM
    [ "$CONFIRM" = "y" ] || { echo "Aborting"; exit 1; }
    cast send --private-key "$DEPLOYMENT_PRIVATE_KEY" \
        --rpc-url "$RPC_URL" \
        --value "$SPENDABLE" \
        "$REFUND_ADDRESS"
