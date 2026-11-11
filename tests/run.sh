#!/usr/bin/env bash
# tests/run.sh — tests for the just-foundry recipes, run against the fixture project in tests/fixtures/project
# Usage: bash tests/run.sh   (needs just, jq and forge)
#
# Each test runs in a fresh copy of the fixture project, with this repo copied to lib/just-foundry, the way
# a plugin repo imports it. The fixture broadcasts are real: tests/fixtures/README.md says how they were made.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)

MISSING=""
for tool in just jq forge cast anvil; do command -v "$tool" >/dev/null || MISSING="$MISSING $tool"; done
[ -z "$MISSING" ] || { echo "Error: missing:$MISSING. Install them first (see README > Testing just-foundry)." >&2; exit 1; }
FIXTURE="$REPO/tests/fixtures/project"
# The fixture's artifacts keep only bytecode.object (tests/fixtures/README.md). A forge command run inside it
# (build, inspect...) rewrites them, and the tests that match broadcasts against bytecode would then fail.
for artifact in "$FIXTURE"/out/*/*.json; do
    [ "$(jq -c '[paths(scalars)]' "$artifact")" = '[["bytecode","object"]]' ] \
        || { echo "Error: $artifact was rebuilt in place: restore tests/fixtures/project from git (see tests/fixtures/README.md)" >&2; exit 1; }
done
PASSED=0
FAILED=0

# Latest deployment of each fixture contract. Thing and Parent were deployed several times, last with CREATE2.
EVM_THING=0xbcff644a6371a7edd92b8005c0ef63d8bbf4a08c
EVM_OTHER=0xe7f1725e7734ce288f8367e1bb143e90bb3f0512
EVM_PARENT=0xb8ac9c17c6f3a7092634c5d1a5d32579e1ccf787
ZK_THING=0x44bac3a4199a6b75c39d9654e4e9f3310b8ce1f5
ZK_OTHER=0x82778c3185fd0666d3f34f8930b4287405d9fbe4
ZK_PARENT=0xf8723fb77f93e4b281f6aedf2db645a8b6e128ba
# Constructor arguments of the latest Thing (id 3) and Parent (8)
ARGS_3=0x0000000000000000000000000000000000000000000000000000000000000003
ARGS_8=0x0000000000000000000000000000000000000000000000000000000000000008

# A fresh copy of the fixture project, as a plugin repo would look with lib/just-foundry
new_project() {
    local dir
    dir=$(mktemp -d)
    cp -r "$FIXTURE"/. "$dir"/
    mkdir -p "$dir/lib/just-foundry"
    (cd "$REPO" && tar --exclude=./.git --exclude=./.env --exclude=./tests -cf - .) | tar -xf - -C "$dir/lib/just-foundry"
    cat > "$dir/justfile" <<'EOF'
import 'lib/just-foundry/justfile'

DEPLOY_SCRIPT := "script/Deploy.s.sol:DeployScript"

# Prints the network and fails on zkSync, for each-network
probe:
    #!/usr/bin/env bash
    source lib/just-foundry/lib.sh && env_load
    echo "network=$NETWORK_NAME chain=$CHAIN_ID evm_version=${FOUNDRY_EVM_VERSION:-unset}"
    [ "$CHAIN_ID" != "324" ]
EOF
    echo "$dir"
}

# A node left over from an earlier run would answer in place of the one about to start: refuse to go on
require_free_port() {
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
        echo "Error: port $1 is in use (a node left over from an earlier run?): stop it and run again" >&2
        exit 1
    fi
}

# Waits until the node started as <pid> answers at <url>; stops the run if it exits or never answers
wait_for_node() {
    local pid="$1" url="$2"
    for _ in $(seq 1 300); do
        kill -0 "$pid" 2>/dev/null || { echo "Error: the node for $url exited" >&2; exit 1; }
        cast chain-id --rpc-url "$url" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    echo "Error: no answer from $url after 60s" >&2
    exit 1
}

nonzero() { [ "$1" -ne 0 ] && echo 1 || echo 0; }

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASSED=$((PASSED + 1))
        echo "ok      $name"
    else
        FAILED=$((FAILED + 1))
        echo "FAILED  $name"
        echo "          expected: $expected"
        echo "          actual:   $actual"
    fi
}

# --- deployed-address ---

P=$(new_project)
cd "$P"
just switch mainnet >/dev/null
check "evm: latest of a contract deployed three times (CREATE, CREATE, CREATE2)" "$EVM_THING" "$(just deployed-address Thing)"
check "evm: a contract deployed once" "$EVM_OTHER" "$(just deployed-address Other)"
check "evm: latest Parent, not its child" "$EVM_PARENT" "$(just deployed-address Parent)"
check "evm: explicit script" "$EVM_THING" "$(just deployed-address Thing script/Deploy.s.sol:DeployScript)"
check "evm: the zkSync name is ignored" "$EVM_THING" "$(just deployed-address Thing "" Other)"
check "evm: one line of output" "1" "$(just deployed-address Thing | wc -l | tr -d ' ')"
OUT=$(just deployed-address Missing 2>&1); CODE=$?
check "evm: unknown contract fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
check "evm: unknown contract says why" "1" "$(grep -c 'No deployment of Missing' <<<"$OUT")"

just switch zksync >/dev/null
check "zksync: latest of a contract deployed three times (create, create, create2)" "$ZK_THING" "$(just deployed-address Thing)"
check "zksync: a contract deployed once" "$ZK_OTHER" "$(just deployed-address Other)"
check "zksync: latest Parent, not its child" "$ZK_PARENT" "$(just deployed-address Parent)"
check "zksync: the zkSync name wins" "$ZK_OTHER" "$(just deployed-address Thing "" Other)"
OUT=$(just deployed-address Missing 2>&1); CODE=$?
check "zksync: unknown contract fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
rm -rf zkout
OUT=$(just deployed-address Thing 2>&1); CODE=$?
check "zksync: without zkout/ it fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
check "zksync: without zkout/ it says why" "1" "$(grep -c 'zkout' <<<"$OUT")"
just switch sepolia >/dev/null
OUT=$(just deployed-address Thing 2>&1); CODE=$?
check "no broadcast for the network fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
check "no broadcast says where it looked" "1" "$(grep -c 'broadcast/Deploy.s.sol/11155111/run-latest.json' <<<"$OUT")"
cd / && rm -rf "$P"

# --- the same lookup in verify-contracts.sh and _flatten-one ---

P=$(new_project)
cd "$P"
cat > stub-forge <<'EOF'
#!/usr/bin/env bash
echo "$*" >> verify-calls.log
EOF
chmod +x stub-forge
for net in mainnet zksync; do
    just switch "$net" >/dev/null
    rm -f verify-calls.log
    (source lib/just-foundry/lib.sh && env_load && FORGE=./stub-forge RPC_URL=http://localhost \
        bash lib/just-foundry/scripts/verify-contracts.sh "$CHAIN_ID" Deploy.s.sol --extra-flag >/dev/null)
    check "$net verify: one call per contract" "3" "$(wc -l < verify-calls.log | tr -d ' ')"
    if [ "$net" = mainnet ]; then thing=$EVM_THING; parent=$EVM_PARENT; else thing=$ZK_THING; parent=$ZK_PARENT; fi
    check "$net verify: latest Thing with its arguments" "1" \
        "$(grep -c -- "--constructor-args $ARGS_3 --extra-flag $thing Thing$" verify-calls.log)"
    check "$net verify: latest Parent with its arguments" "1" \
        "$(grep -c -- "--constructor-args $ARGS_8 --extra-flag $parent Parent$" verify-calls.log)"
    check "$net verify: Other has no constructor arguments" "1" \
        "$(grep -c -- "--rpc-url http://localhost --extra-flag 0x[0-9a-f]* Other$" verify-calls.log)"
done
# The verify recipe picks forge-zksync, --zksync and the zkSync verifier on zkSync
mkdir -p stubs
cp stub-forge stubs/forge
cp stub-forge stubs/forge-zksync
just switch zksync >/dev/null
rm -f verify-calls.log
PATH="$PWD/stubs:$PATH" just verify >/dev/null 2>&1
check "zksync verify recipe: three calls" "3" "$(wc -l < verify-calls.log | tr -d ' ')"
check "zksync verify recipe: zkSync flags" "3" "$(grep -c -- "--zksync --verifier zksync --verifier-url https://zksync2-mainnet-explorer.zksync.io/contract_verification" verify-calls.log)"
just switch mainnet >/dev/null
rm -f verify-calls.log
PATH="$PWD/stubs:$PATH" just verify sourcify >/dev/null 2>&1
check "mainnet verify recipe: no zkSync flags" "0" "$(grep -c -- "--zksync" verify-calls.log)"
check "mainnet verify recipe: the chosen verifier" "3" "$(grep -c -- "--verifier sourcify" verify-calls.log)"
rm -rf stubs
for net in mainnet zksync; do
    just switch "$net" >/dev/null
    rm -rf flat
    just _flatten-one src/Thing.sol:Thing >/dev/null 2>&1
    check "$net flatten: constructor arguments of the latest Thing" "$ARGS_3" "$(cat flat/Thing.args.txt 2>/dev/null)"
    just _flatten-one src/Thing.sol:Other >/dev/null 2>&1
    check "$net flatten: no arguments file for Other" "no" "$([ -f flat/Other.args.txt ] && echo yes || echo no)"
done
cd / && rm -rf "$P"

# --- each-network ---

P=$(new_project)
cd "$P"
NETWORK_COUNT=$(ls lib/just-foundry/networks/*.env | wc -l | tr -d ' ')
just switch sepolia >/dev/null
OUT=$(just each-network probe 2>&1); CODE=$?
check "each-network: fails when one network fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
check "each-network: one ok line per passing network" "$((NETWORK_COUNT - 1))" "$(grep -c '^ok ' <<<"$OUT")"
check "each-network: the failing network is reported" "1" "$(grep -c '^FAILED  zksync' <<<"$OUT")"
check "each-network: one log per network, under logs/ named <recipe>-<network>-<timestamp>" "$NETWORK_COUNT" "$(ls logs/probe-*-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9].log | wc -l | tr -d ' ')"
check "each-network: each log is its network's" "network=polygon chain=137 evm_version=unset" "$(head -1 logs/probe-polygon-[0-9][0-9]-*.log)"
check "each-network: one network's env does not reach the next" "1" "$(grep -c 'evm_version=unset' logs/probe-citrea-[0-9][0-9]-*.log)"
check "each-network: the active network is restored" "sepolia" "$(source lib/just-foundry/lib.sh && env_active_network)"
rm -f lib/just-foundry/.env
just each-network probe >/dev/null 2>&1
check "each-network: no active network before, none after" "" "$(source lib/just-foundry/lib.sh && env_active_network)"
just switch base >/dev/null
OUT=$(just each-network help 2>&1); CODE=$?
check "each-network: exits 0 when every network passes" "0" "$CODE"
cd / && rm -rf "$P"

# --- deployed-address: many zkout artifacts, an empty zkout/, a deployment without an address ---

P=$(new_project)
cd "$P"
just switch zksync >/dev/null
# 3,000 more artifacts: the hash → name map must not depend on the command-line size limit
for i in $(seq 1 3000); do
    mkdir -p "zkout/Gen$i.sol"
    printf '{"hash":"%064x"}\n' "$i" > "zkout/Gen$i.sol/Gen$i.json"
done
check "zksync: 3,000 more artifacts in zkout/" "$ZK_THING" "$(just deployed-address Thing 2>&1)"
rm -rf zkout && mkdir zkout
OUT=$(just deployed-address Thing 2>&1); CODE=$?
check "zksync: an empty zkout/ fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
check "zksync: an empty zkout/ says why" "1" "$(grep -c 'No artifacts in zkout/' <<<"$OUT")"
rm -rf zkout && cp -r "$FIXTURE/zkout" zkout
B=broadcast/Deploy.s.sol/324/run-latest.json
jq '.transactions[3].additionalContracts = []' "$B" > b.json && mv b.json "$B"
OUT=$(just deployed-address Thing 2>&1); CODE=$?
check "zksync: a deployment without an address fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
check "zksync: a deployment without an address says why" "1" "$(grep -c 'no deployed address' <<<"$OUT")"
cd / && rm -rf "$P"

# --- verify: guessing the constructor arguments when the artifact is missing ---

P=$(new_project)
cd "$P"
printf '#!/usr/bin/env bash\necho "$*" >> verify-calls.log\n' > stub-forge && chmod +x stub-forge
rm out/Thing.sol/Thing.json
just switch mainnet >/dev/null
(source lib/just-foundry/lib.sh && env_load && FORGE=./stub-forge RPC_URL=http://localhost \
    bash lib/just-foundry/scripts/verify-contracts.sh "$CHAIN_ID" Deploy.s.sol >/dev/null)
check "evm verify: no artifact, so the arguments are guessed" "1" \
    "$(grep -c -- "--guess-constructor-args $EVM_THING Thing$" verify-calls.log)"
check "evm verify: the others still get theirs" "1" "$(grep -c -- "--constructor-args $ARGS_8 $EVM_PARENT Parent$" verify-calls.log)"
cd / && rm -rf "$P"

# --- each-network passes its arguments through as they were given ---

P=$(new_project)
cd "$P"
cat >> justfile <<'EOF2'

# Prints its arguments, one per line
[positional-arguments]
show-args *args:
    #!/usr/bin/env bash
    printf '[%s]\n' "$@"
EOF2
just switch base >/dev/null
just each-network show-args "two words" 'a "quoted" one' '$HOME' >/dev/null 2>&1
check "each-network: arguments arrive intact" '[two words]|[a "quoted" one]|[$HOME]' "$(paste -sd'|' logs/show-args-base-[0-9][0-9]-*.log)"
cd / && rm -rf "$P"

# --- clean-nonce sends with the chain's gas flags ---

P=$(new_project)
cd "$P"
mkdir -p stubs
cat > stubs/cast <<'EOF2'
#!/usr/bin/env bash
case "$1" in
    wallet) echo 0x00000000000000000000000000000000000000aa ;;
    send) echo "$*" >> cast-calls.log ;;
esac
EOF2
chmod +x stubs/*
printf 'DEPLOYER_KEY=0x01\n' > .env
just switch chiliz >/dev/null
PATH="$PWD/stubs:$PATH" just clean-nonce 7 >/dev/null 2>&1
check "clean-nonce: the chain's gas flags" "1" "$(grep -c -- '--legacy --gas-price 5200000000000' cast-calls.log)"
cd / && rm -rf "$P"

# --- a deployment counts only when its receipt says it succeeded ---

P=$(new_project)
cd "$P"
printf '#!/usr/bin/env bash\necho "$*" >> verify-calls.log\n' > stub-forge && chmod +x stub-forge
for net in mainnet zksync; do
    just switch "$net" >/dev/null
    if [ "$net" = mainnet ]; then B=broadcast/Deploy.s.sol/1/run-latest.json; else B=broadcast/Deploy.s.sol/324/run-latest.json; fi
    cp "$B" original.json
    # The latest Thing (transaction 4) reverted
    jq '.receipts[3].status = "0x0"' original.json > "$B"
    OUT=$(just deployed-address Thing 2>&1); CODE=$?
    check "$net: the latest deployment reverted, so it fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
    check "$net: ... and says so, without falling back to an older one" "1" "$(grep -c 'latest deployment of Thing .* reverted' <<<"$OUT")"
    check "$net: the other contracts are still found" "1" "$(just deployed-address Parent 2>/dev/null | grep -c '^0x')"
    rm -f verify-calls.log
    OUT=$( (source lib/just-foundry/lib.sh && env_load && FORGE=./stub-forge RPC_URL=http://localhost \
        bash lib/just-foundry/scripts/verify-contracts.sh "$CHAIN_ID" Deploy.s.sol) 2>&1); CODE=$?
    check "$net verify: the reverted one is not verified" "0" "$(grep -c ' Thing$' verify-calls.log)"
    check "$net verify: ... counts as a failure" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
    check "$net verify: the others are verified" "2" "$(wc -l < verify-calls.log | tr -d ' ')"
    rm -rf flat
    just _flatten-one src/Thing.sol:Thing >/dev/null 2>&1
    check "$net flatten: no arguments from a reverted deployment" "no" "$([ -f flat/Thing.args.txt ] && echo yes || echo no)"
    # The latest Thing was never mined: no receipt at all
    jq 'del(.receipts[3])' original.json > "$B"
    OUT=$(just deployed-address Thing 2>&1); CODE=$?
    check "$net: the latest deployment was not mined, so it fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
    check "$net: ... and says so" "1" "$(grep -c 'latest deployment of Thing .* not mined' <<<"$OUT")"
    cp original.json "$B"
done
cd / && rm -rf "$P"

# --- the resolve recipes answer for the active network, whatever the shell carries ---

P=$(new_project)
cd "$P"
just switch hemi >/dev/null
check "hemi: its own gas flags" "--legacy --gas-price 100000000" "$(just resolve-gas-params)"
check "hemi, shell carrying Chiliz's CHAIN_ID: still hemi's gas flags" "--legacy --gas-price 100000000" "$(CHAIN_ID=88888 just resolve-gas-params)"
check "hemi, shell carrying Chiliz's CHAIN_ID: still hemi's script flags" "--legacy --gas-price 100000000" "$(CHAIN_ID=88888 just resolve-script-params)"
just switch zksync >/dev/null
mkdir -p stubs && printf '#!/usr/bin/env bash\n' > stubs/forge-zksync && chmod +x stubs/forge-zksync
check "zksync, shell carrying mainnet's CHAIN_ID: still forge-zksync" "forge-zksync" "$(CHAIN_ID=1 PATH="$PWD/stubs:$PATH" just resolve-forge)"
check "zksync, shell carrying mainnet's CHAIN_ID: still --slow" "--slow" "$(CHAIN_ID=1 just resolve-script-params)"
just switch mainnet >/dev/null
check "mainnet, shell carrying zkSync's CHAIN_ID: plain forge" "forge" "$(CHAIN_ID=324 just resolve-forge)"
check "mainnet, shell carrying Chiliz's CHAIN_ID: no gas flags" "" "$(CHAIN_ID=88888 just resolve-gas-params)"
check "deployed-address loads the network itself" "$EVM_THING" "$(CHAIN_ID=324 just deployed-address Thing 2>/dev/null)"
cd / && rm -rf "$P"

# --- a broadcast must be for the active network's chain ---

P=$(new_project)
cd "$P"
for net in mainnet zksync; do
    just switch "$net" >/dev/null
    if [ "$net" = mainnet ]; then B=broadcast/Deploy.s.sol/1/run-latest.json; else B=broadcast/Deploy.s.sol/324/run-latest.json; fi
    cp "$B" original.json
    jq '.chain = 5' original.json > "$B"
    OUT=$(just deployed-address Thing 2>&1); CODE=$?
    check "$net: a broadcast for another chain fails" "1" "$([ $CODE -ne 0 ] && echo 1 || echo 0)"
    check "$net: ... and says so" "1" "$(grep -c 'is for chain 5, not' <<<"$OUT")"
    cp original.json "$B"
done
cd / && rm -rf "$P"

# --- flatten never takes arguments from another broadcast when the latest deployment failed ---

P=$(new_project)
cd "$P"
just switch mainnet >/dev/null
B=broadcast/Deploy.s.sol/1/run-latest.json
# An older broadcast of another script, where Thing was deployed successfully
mkdir -p broadcast/Older.s.sol/1
jq '.timestamp -= 1000' "$B" > broadcast/Older.s.sol/1/run-latest.json
# In the most recent one, Thing's latest deployment reverted
jq '.receipts[3].status = "0x0"' "$B" > b.json && mv b.json "$B"
rm -rf flat
OUT=$(just _flatten-one src/Thing.sol:Thing 2>&1)
check "flatten: no arguments when the latest deployment failed" "no" "$([ -f flat/Thing.args.txt ] && echo yes || echo no)"
check "flatten: says why" "1" "$(grep -c 'latest deployment of Thing .* reverted' <<<"$OUT")"
check "flatten: still flattens" "yes" "$([ -f flat/Thing.flat.sol ] && echo yes || echo no)"
# The older broadcast is used when it is the most recent one deploying the contract
jq '.timestamp += 5000' broadcast/Older.s.sol/1/run-latest.json > b.json && mv b.json broadcast/Older.s.sol/1/run-latest.json
rm -rf flat
just _flatten-one src/Thing.sol:Thing >/dev/null 2>&1
check "flatten: arguments from the most recent broadcast" "$ARGS_3" "$(cat flat/Thing.args.txt 2>/dev/null)"
cd / && rm -rf "$P"

# --- env_active_network and gas flags ---

P=$(new_project)
cd "$P"
check "env_active_network: none selected" "" "$(source lib/just-foundry/lib.sh && env_active_network)"
just switch chiliz >/dev/null
check "env_active_network: selected network" "chiliz" "$(source lib/just-foundry/lib.sh && env_active_network)"
check "networks: marks the active one" "1" "$(just networks | grep -c '^  \* chiliz ')"
check "gas params: chiliz" "--legacy --gas-price 5200000000000" "$(just resolve-gas-params)"
check "script params: chiliz" "--legacy --gas-price 5200000000000" "$(just resolve-script-params)"
just switch zksync >/dev/null
check "gas params: zksync has none" "" "$(just resolve-gas-params)"
check "script params: zksync adds --slow" "--slow" "$(just resolve-script-params)"
just switch mainnet >/dev/null
check "gas params: mainnet has none" "" "$(just resolve-gas-params)"
cd / && rm -rf "$P"

# --- fund: a share of the deployer's balance, split equally, each transfer confirmed ---

FUND_PORT=8660
FIXED_PORT=8661
require_free_port "$FUND_PORT"
require_free_port "$FIXED_PORT"
anvil --port "$FUND_PORT" --silent &
FUND_ANVIL_PID=$!
# Chain 88888 is Chiliz's ID: its forced flags (--legacy --gas-price 5200 gwei) apply there
anvil --port "$FIXED_PORT" --chain-id 88888 --silent &
FIXED_ANVIL_PID=$!
trap 'kill $FUND_ANVIL_PID $FIXED_ANVIL_PID 2>/dev/null' EXIT
FUND_RPC="http://127.0.0.1:$FUND_PORT"
FIXED_RPC="http://127.0.0.1:$FIXED_PORT"
wait_for_node "$FUND_ANVIL_PID" "$FUND_RPC"
wait_for_node "$FIXED_ANVIL_PID" "$FIXED_RPC"

P=$(new_project)
cd "$P"
printf 'RPC_URL="%s"\nCHAIN_ID="31337"\n' "$FUND_RPC" > lib/just-foundry/networks/local-fund.env
printf 'RPC_URL="%s"\nCHAIN_ID="88888"\n' "$FIXED_RPC" > lib/just-foundry/networks/local-fixed.env
DEPLOYER_KEY=0x00000000000000000000000000000000000000000000000000000000000d0d0d
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_KEY")
A1=0x00000000000000000000000000000000000000a1
A2=0x00000000000000000000000000000000000000a2
A3=0x00000000000000000000000000000000000000a3
printf 'DEPLOYER_KEY=%s\n' "$DEPLOYER_KEY" > .env
ether() { cast to-unit "$1" ether; }
# Whole gwei: balances are compared in gwei, since 100 ether in wei doesn't fit shell integers
gwei() { cast to-unit "$1" gwei | cut -d. -f1; }
balance() { cast balance "$1" --rpc-url "${2:-$FUND_RPC}"; }
deployer_nonce() { cast nonce "$DEPLOYER" --rpc-url "${1:-$FUND_RPC}"; }
reset_balances() {
    local rpc="${2:-$FUND_RPC}" a
    cast rpc anvil_setBalance "$DEPLOYER" "$(cast to-hex "$1")" --rpc-url "$rpc" >/dev/null
    for a in $A1 $A2 $A3; do cast rpc anvil_setBalance "$a" 0x0 --rpc-url "$rpc" >/dev/null; done
}
fund() { just fund "$@" 2>&1; }
# "y" to the summary and to every transfer
YES='y\ny\ny\ny\ny\n'
# Prints yes when the ether balance of $1 is above $2 and below $3
between() { awk -v b="$(ether "$(balance "$1")")" -v lo="$2" -v hi="$3" 'BEGIN { print (b > lo && b < hi) ? "yes" : "no" }'; }

just switch local-fund >/dev/null
reset_balances 100000000000000000000  # 100 ether
OUT=$(printf "$YES" | fund 10% $A1 $A2 $A3); CODE=$?
check "split: exits 0" "0" "$CODE"
check "split: the three addresses get the same amount" "yes" \
    "$([ "$(balance $A1)" = "$(balance $A2)" ] && [ "$(balance $A2)" = "$(balance $A3)" ] && echo yes || echo no)"
# 10% of 100 ether, less the little gas reserved for three transfers, in three: just under 3.3333.. ether each
check "split: a third of 10% of the balance after the gas reserve" "yes" "$(between $A1 3.333 3.33334)"
check "split: one line per address" "3" "$(grep -c '^ok      0x00000000000000000000000000000000000000a[123] ' <<<"$OUT")"
check "split: the summary shows the network, the balance, each amount and the total" "1 1 3 1" \
    "$(grep -c "rpc:      $FUND_RPC" <<<"$OUT") $(grep -c 'balance:  100 ether' <<<"$OUT") $(grep -c '^   0x00000000000000000000000000000000000000a[123]  3.333[0-9]* ether  (gas estimate 21000, limit 42000)$' <<<"$OUT") $(grep -c '^   total:    9.999[0-9]* ether to 3 address(es)$' <<<"$OUT")"
check "split: one question for the summary, then one per transfer with its address and amount" "1 3" \
    "$(grep -c 'Proceed? \[y/N\]' <<<"$OUT") $(grep -c 'Send 3.333[0-9]* ether to 0x00000000000000000000000000000000000000a[123]? \[y/N\]' <<<"$OUT")"

# The percent: always with its %, up to two decimals, from 0.01% to 100%
reset_balances 100000000000000000000
OUT=$(printf "$YES" | fund 4% $A1 $A2); CODE=$?
check "percent 4%: 2 ether each, less a little gas" "0 yes yes" "$CODE $(between $A1 1.999 2) $(between $A2 1.999 2)"
reset_balances 100000000000000000000
OUT=$(printf "$YES" | fund 0.5% $A1); CODE=$?
check "percent 0.5: half an ether, less a little gas" "0 yes" "$CODE $(between $A1 0.499 0.5)"
reset_balances 100000000000000000000
OUT=$(printf "$YES" | fund 12.25% $A1); CODE=$?
check "percent 12.25%: 12.25 ether, less a little gas" "0 yes" "$CODE $(between $A1 12.249 12.25)"
reset_balances 100000000000000000000
OUT=$(printf "$YES" | fund 0.01% $A1); CODE=$?
check "percent 0.01% (the smallest): 0.01 ether, less a little gas" "0 yes" "$CODE $(between $A1 0.0099 0.01)"
reset_balances 100000000000000000000
OUT=$(printf "$YES" | fund 0.09% $A1); CODE=$?
check "percent 0.09 (09 is not even octal): 0.09 ether, less a little gas" "0 yes" "$CODE $(between $A1 0.0899 0.09)"
reset_balances 100000000000000000000
OUT=$(printf "$YES" | fund 100.00% $A1); CODE=$?
check "percent 100.00%: all but the gas" "0 yes" "$CODE $(between $A1 99.99 100)"

reset_balances 1000000000000000000  # 1 ether
OUT=$(printf "$YES" | fund 100% $A1 $A2); CODE=$?
check "gas reserve: 100% still leaves the deployer enough to pay for the transfers" "0 2" \
    "$CODE $(grep -c '^ok      ' <<<"$OUT")"
check "gas reserve: something is left with the deployer" "yes" "$([ "$(balance "$DEPLOYER")" != 0 ] && echo yes || echo no)"

# A deployer balance far above what shell arithmetic holds in wei, at a high percent: no overflow
reset_balances 50000000000000000000000000  # 50 million ether
OUT=$(printf "$YES" | fund 99.99% $A1); CODE=$?
check "large balance: 99.99% of 50 million ether, exactly as computed" "0 yes" "$CODE $(between $A1 49994999 49995000)"

# Declined at the summary: nothing sent
reset_balances 100000000000000000000
NONCE=$(deployer_nonce)
OUT=$(printf 'n\n' | fund 10% $A1 $A2); CODE=$?
check "decline the summary: nothing sent" "0 $NONCE 0 0 1" "$CODE $(deployer_nonce) $(balance $A1) $(balance $A2) $(grep -c '^Nothing sent$' <<<"$OUT")"

# Declined for one transfer: that address is skipped, not failed, and the others are paid
reset_balances 100000000000000000000
NONCE=$(deployer_nonce)
OUT=$(printf 'y\ny\nn\ny\n' | fund 10% $A1 $A2 $A3); CODE=$?
check "decline one transfer: exits 0, the others are paid, it gets nothing" "0 yes yes 0 $((NONCE + 2))" \
    "$CODE $([ "$(balance $A1)" != 0 ] && echo yes || echo no) $([ "$(balance $A3)" != 0 ] && echo yes || echo no) $(balance $A2) $(deployer_nonce)"
check "decline one transfer: reported skipped, never failed" "1 1 0" \
    "$(grep -c "^skipped $A2: answered no, nothing sent$" <<<"$OUT") $(grep -c "^Skipped: $A2$" <<<"$OUT") $(grep -c 'FAILED\|Not funded' <<<"$OUT")"
SHOWN=$(sed -n "s/^   $A1  \([0-9.]*\) ether  (gas.*/\1/p" <<<"$OUT")
check "decline one transfer: the others get exactly the amount shown" "$SHOWN $SHOWN" "$(ether "$(balance $A1)") $(ether "$(balance $A3)")"

# What is sent is what was confirmed: an estimate or a gas price that moves after the summary changes nothing
mkdir -p moving
cat > moving/cast <<EOF
#!/usr/bin/env bash
# The two estimates of the run (1 wei, then the amount) answer 21,000, any later one 5,000,000; a gas price quoted
# after the first is 5 gwei, not the 2 gwei sent with (twice the first quote)
count() { local n; n=\$(cat "$P/moving/\$1" 2>/dev/null || echo 0); echo \$((n + 1)) > "$P/moving/\$1"; echo "\$n"; }
if [ "\$1" = estimate ]; then [ "\$(count estimates)" -lt 2 ] && echo 21000 || echo 5000000; exit 0; fi
if [ "\$1" = gas-price ]; then [ "\$(count quotes)" -lt 1 ] && echo 1000000000 || echo 5000000000; exit 0; fi
exec "$(command -v cast)" "\$@"
EOF
chmod +x moving/cast
reset_balances 100000000000000000000
OUT=$(printf "$YES" | PATH="$P/moving:$PATH" just fund 10% $A1 2>&1); CODE=$?
TX=$(sed -n 's/^ok      .* tx \(0x[0-9a-f]*\)$/\1/p' <<<"$OUT")
SENT=$(cast rpc eth_getTransactionByHash "${TX:-0x0}" --rpc-url "$FUND_RPC")
check "moving estimate and price: sent with the limit and price shown, the amount shown received" \
    "0 42000 2000000000 $(sed -n "s/^   $A1  \([0-9.]*\) ether  (gas.*/\1/p" <<<"$OUT")" \
    "$CODE $(cast to-dec "$(jq -r .gas <<<"$SENT")") $(cast to-dec "$(jq -r .maxFeePerGas <<<"$SENT")") $(ether "$(balance $A1)")"
rm -rf moving
# No answer at all (the input ends) is a no
reset_balances 100000000000000000000
OUT=$(printf 'y\ny\n' | fund 10% $A1 $A2 $A3); CODE=$?
check "no answer for a transfer: skipped" "0 yes 0 0 1" \
    "$CODE $([ "$(balance $A1)" != 0 ] && echo yes || echo no) $(balance $A2) $(balance $A3) $(grep -c "^Skipped: $A2 $A3$" <<<"$OUT")"

# Refused before sending anything
refused() {  # refused <name> <expected message> <args...>
    local name="$1" message="$2"
    shift 2
    NONCE=$(deployer_nonce)
    OUT=$(printf "$YES" | fund "$@"); CODE=$?
    check "refused, $name: fails, nothing sent" "1 $NONCE 0" "$(nonzero $CODE) $(deployer_nonce) $(balance $A1)"
    check "refused, $name: says why" "1" "$(grep -c -- "$message" <<<"$OUT")"
}
reset_balances 100000000000000000000
refused "malformed address" "is not an address" 10% $A1 0x1234
refused "duplicate address" "appears twice" 10% $A1 $A2 0x00000000000000000000000000000000000000A1
refused "no address" "at least one address" 10%
PERCENT_ERROR="the percent must be from 0.01% to 100%"
refused "percent 0" "$PERCENT_ERROR" 0% $A1
refused "percent 0.00" "$PERCENT_ERROR" 0.00% $A1
refused "percent 0.001 (three decimals)" "$PERCENT_ERROR" 0.001% $A1
refused "percent 101" "$PERCENT_ERROR" 101% $A1
refused "percent 100.01" "$PERCENT_ERROR" 100.01% $A1
refused "percent not a number" "$PERCENT_ERROR" ten% $A1
refused "percent with a leading zero (octal 010 would be 8%)" "$PERCENT_ERROR" 010% $A1
refused "percent 08 (not even octal)" "$PERCENT_ERROR" 08% $A1
refused "percent 00.5" "$PERCENT_ERROR" 00.5% $A1
refused "percent .5 (no leading 0)" "$PERCENT_ERROR" .5% $A1
refused "percent 4. (no decimals after the point)" "$PERCENT_ERROR" 4.% $A1
refused "percent 4%% (two signs)" "$PERCENT_ERROR" 4%% $A1
refused "percent -4" "$PERCENT_ERROR" -4% $A1
refused "percent 999.99 (three digits before the point)" "$PERCENT_ERROR" 999.99% $A1
refused "percent 1e1" "$PERCENT_ERROR" 1e1% $A1
refused "percent 4, without %" "write the percent with %, e.g. 4%" 4 $A1
refused "percent 0.5, without %" "write the percent with %, e.g. 4%" 0.5 $A1
reset_balances 1000
refused "balance can't cover the gas" "can't cover" 10% $A1

# refund: the same primitive, all of the balance but the gas, to REFUND_ADDRESS
reset_balances 100000000000000000000
NONCE=$(deployer_nonce)
printf 'DEPLOYER_KEY=%s\nREFUND_ADDRESS=%s\n' "$DEPLOYER_KEY" "$A3" > .env
OUT=$(printf "$YES" | just refund 2>&1); CODE=$?
check "refund: everything but the gas goes to REFUND_ADDRESS, in one transfer" "0 yes $((NONCE + 1))" \
    "$CODE $(between $A3 99.99 100) $(deployer_nonce)"
RESERVE=$(gwei "$(cast to-wei "$(sed -n 's/^   gas:      \([0-9.]*\) ether reserved.*/\1/p' <<<"$OUT")" ether)")
check "refund: REFUND_ADDRESS gets exactly the balance less the reserve shown; the deployer keeps part of the reserve" "yes yes" \
    "$([ "$(gwei "$(balance $A3)")" = $((100000000000 - RESERVE)) ] && echo yes || echo no) $(L=$(gwei "$(balance "$DEPLOYER")"); [ "$L" -gt 0 ] && [ "$L" -le "$RESERVE" ] && echo yes || echo no)"
check "refund: the same confirmations as fund" "1 1" "$(grep -c 'Proceed? \[y/N\]' <<<"$OUT") $(grep -c "Send .* ether to $A3? \[y/N\]" <<<"$OUT")"
for refund_address in "" 0x0000000000000000000000000000000000000001; do
    printf 'DEPLOYER_KEY=%s\nREFUND_ADDRESS=%s\n' "$DEPLOYER_KEY" "$refund_address" > .env
    NONCE=$(deployer_nonce)
    OUT=$(printf "$YES" | just refund 2>&1); CODE=$?
    check "refund: REFUND_ADDRESS '${refund_address}' is refused, nothing sent" "1 $NONCE 1" \
        "$(nonzero $CODE) $(deployer_nonce) $(grep -c 'REFUND_ADDRESS is not set' <<<"$OUT")"
done
printf 'DEPLOYER_KEY=%s\n' "$DEPLOYER_KEY" > .env

# A recipient that reverts: reported as failed, the others are still paid
mkdir -p refuser-src
cat > refuser-src/Refuser.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Refuser {
    receive() external payable {
        revert("no");
    }
}
EOF
TEST_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
REFUSER=$(forge create refuser-src/Refuser.sol:Refuser --rpc-url "$FUND_RPC" --private-key "$TEST_KEY" --broadcast 2>/dev/null \
    | sed -n 's/^Deployed to: //p')
reset_balances 100000000000000000000
NONCE=$(deployer_nonce)
OUT=$(printf "$YES" | fund 10% $A1 "$REFUSER" $A2); CODE=$?
check "reverting recipient: exits non-zero" "1" "$(nonzero $CODE)"
check "reverting recipient: FAILED at its estimate, nothing sent to it" "1 1 $((NONCE + 2))" "$(grep -ci "^FAILED  $REFUSER: the transfer would revert (its gas estimate failed), nothing sent, not funded" <<<"$OUT") $(grep -ci "^Not funded: $REFUSER$" <<<"$OUT") $(deployer_nonce)"
check "reverting recipient: the others are paid" "yes yes 0" \
    "$([ "$(balance $A1)" != 0 ] && echo yes || echo no) $([ "$(balance $A2)" != 0 ] && echo yes || echo no) $(balance "$REFUSER")"

# A transfer without a receipt is unknown, since it may still be mined: a receipt that doesn't come within
# TX_RECEIPT_TIMEOUT, a receipt lookup that fails, or a broadcast whose answer is lost (a timeout, with a lagging
# node behind a load balancer that doesn't know the transfer yet). A late receipt is waited for.
mkdir -p unknown
cat > unknown/cast <<EOF
#!/usr/bin/env bash
mode=\$(cat "$P/unknown/mode")
if [ "\$1" = rpc ] && [ "\$2" = eth_getTransactionReceipt ]; then
    case "\$mode" in
        never-mined) echo null; exit 0 ;;
        lookup-fails) echo "Error: error sending request for url" >&2; exit 1 ;;
        late)  # null for the first two lookups
            n=\$(cat "$P/unknown/lookups" 2>/dev/null || echo 0); echo \$((n + 1)) > "$P/unknown/lookups"
            [ "\$n" -lt 2 ] && { echo null; exit 0; } ;;
    esac
fi
if [ "\$mode" = lost-answer ]; then
    [ "\$1" = rpc ] && [ "\$2" = eth_getTransactionByHash ] && { echo null; exit 0; }
    if [ "\$1" = publish ]; then
        "$(command -v cast)" "\$@" >/dev/null 2>&1
        echo "Error: error sending request for url: operation timed out" >&2
        exit 1
    fi
fi
exec "$(command -v cast)" "\$@"
EOF
chmod +x unknown/cast
for case in "never-mined|no receipt for tx TX after 2s" \
    "lookup-fails|can't read the receipt of tx TX (Error: error sending request for url)" \
    "lost-answer|no answer to the broadcast of tx TX (Error: error sending request for url: operation timed out)"; do
    mode=${case%%|*}
    why=$(sed 's/TX/0x[0-9a-f]\\{64\\}/' <<<"${case#*|}")
    echo "$mode" > unknown/mode
    reset_balances 100000000000000000000
    NONCE=$(deployer_nonce)
    OUT=$(printf "$YES" | TX_RECEIPT_TIMEOUT=2 PATH="$P/unknown:$PATH" just fund 10% $A1 2>&1); CODE=$?
    check "$mode: unknown, with its transaction and the way forward" "1 1" \
        "$(grep -c "^UNKNOWN $A1: $why: check $A1 on an explorer before running again$" <<<"$OUT") $(grep -c "^Unknown, check on an explorer before running again: $A1$" <<<"$OUT")"
    check "$mode: never said to be failed or not funded, exits non-zero" "0 1" "$(grep -c 'FAILED\|not funded\|Not funded' <<<"$OUT") $(nonzero $CODE)"
    for _ in $(seq 1 25); do [ "$(balance $A1)" != 0 ] && break; sleep 0.2; done
    check "$mode: the transfer did land, which is why it's unknown" "yes $((NONCE + 1))" "$([ "$(balance $A1)" != 0 ] && echo yes || echo no) $(deployer_nonce)"
done
echo late > unknown/mode
reset_balances 100000000000000000000
OUT=$(printf "$YES" | TX_RECEIPT_TIMEOUT=30 PATH="$P/unknown:$PATH" just fund 10% $A1 2>&1); CODE=$?
check "late receipt: waited for, then ok" "0 1" "$CODE $(grep -c "^ok      $A1 " <<<"$OUT")"
rm -rf unknown

# Refused by the node before broadcast (as op-geth does when the L1 fee isn't covered): failed, nothing sent
mkdir -p refused-tx
cat > refused-tx/cast <<EOF
#!/usr/bin/env bash
if [ "\$1" = publish ]; then
    echo "Error: server returned an error response: error code -32000: insufficient funds for gas * price + value" >&2
    exit 1
fi
exec "$(command -v cast)" "\$@"
EOF
chmod +x refused-tx/cast
reset_balances 100000000000000000000
NONCE=$(deployer_nonce)
OUT=$(printf "$YES" | PATH="$P/refused-tx:$PATH" just fund 10% $A1 $A2 2>&1); CODE=$?
check "refused by the node: FAILED, nothing sent, never unknown" "1 2 1 0 $NONCE" \
    "$(nonzero $CODE) $(grep -c "^FAILED  0x00000000000000000000000000000000000000a[12]: the node refused the transfer (Error: server returned an error response: error code -32000: insufficient funds for gas \* price + value), nothing sent, not funded$" <<<"$OUT") $(grep -c "^Not funded: $A1 $A2$" <<<"$OUT") $(grep -c 'UNKNOWN' <<<"$OUT") $(deployer_nonce)"
rm -rf refused-tx

# OP-stack chains (code at the GasPriceOracle predeploy): the L1 data fee of each transfer is reserved too, at
# twice what the oracle gives, so that a 100% run still leaves it with the deployer
ORACLE=0x420000000000000000000000000000000000000F
mkdir -p oracle-src
cat > oracle-src/Oracles.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Fjord and later: an upper bound of the L1 fee for a transaction of a given size
contract BoundOracle {
    function getL1FeeUpperBound(uint256) external pure returns (uint256) {
        return 1e15;
    }
}

// Before Fjord: the L1 fee of a given signed transaction
contract FeeOracle {
    function getL1Fee(bytes calldata) external pure returns (uint256) {
        return 3e15;
    }
}

// Answers neither
contract MuteOracle {}
EOF
oracle() {  # oracle <contract>: put its code at the predeploy address ("" removes it)
    local code=0x
    if [ -n "$1" ]; then
        code=$(cast code "$(forge create "oracle-src/Oracles.sol:$1" --rpc-url "$FUND_RPC" --private-key "$TEST_KEY" --broadcast 2>/dev/null \
            | sed -n 's/^Deployed to: //p')" --rpc-url "$FUND_RPC")
    fi
    cast rpc anvil_setCode "$ORACLE" "$code" --rpc-url "$FUND_RPC" >/dev/null
}
oracle BoundOracle
reset_balances 1000000000000000000  # 1 ether
OUT=$(printf "$YES" | fund 100% $A1 $A2); CODE=$?
check "op-stack, upper bound: shown as part of the reserve, twice the bound per transfer" "0 1" \
    "$CODE $(grep -c '^   l1 fee:   0.0020* ether per transfer, in the reserve (OP-stack L1 data fee: twice getL1FeeUpperBound([0-9]*))$' <<<"$OUT")"
check "op-stack, upper bound: 100% leaves both transfers' L1 fee with the deployer" "yes" \
    "$([ "$(gwei "$(balance "$DEPLOYER")")" -ge 4000000 ] && echo yes || echo no)"
reset_balances 1000000000000000000
printf 'DEPLOYER_KEY=%s\nREFUND_ADDRESS=%s\n' "$DEPLOYER_KEY" "$A3" > .env
OUT=$(printf "$YES" | just refund 2>&1); CODE=$?
check "op-stack, refund: sent, the L1 fee left with the deployer" "0 yes yes" \
    "$CODE $([ "$(balance $A3)" != 0 ] && echo yes || echo no) $([ "$(gwei "$(balance "$DEPLOYER")")" -ge 2000000 ] && echo yes || echo no)"
printf 'DEPLOYER_KEY=%s\n' "$DEPLOYER_KEY" > .env
oracle FeeOracle
reset_balances 1000000000000000000
OUT=$(printf "$YES" | fund 100% $A1); CODE=$?
check "op-stack, before Fjord: the fee of a signed transfer, twice, kept back" "0 1 yes" \
    "$CODE $(grep -c '^   l1 fee:   0.0060* ether per transfer, in the reserve (OP-stack L1 data fee: twice getL1Fee of an unsigned transfer)$' <<<"$OUT") $([ "$(gwei "$(balance "$DEPLOYER")")" -ge 6000000 ] && echo yes || echo no)"
oracle MuteOracle
reset_balances 1000000000000000000
NONCE=$(deployer_nonce)
OUT=$(printf "$YES" | fund 10% $A1); CODE=$?
check "op-stack, an oracle that answers neither: refused, nothing sent" "1 $NONCE 1" \
    "$(nonzero $CODE) $(deployer_nonce) $(grep -c "can't read the L1 data fee from $ORACLE" <<<"$OUT")"
oracle ""
reset_balances 1000000000000000000
OUT=$(printf "$YES" | fund 10% $A1); CODE=$?
check "no oracle: no L1 fee" "0 0" "$CODE $(grep -c 'l1 fee' <<<"$OUT")"

# From Hacky's gate checks, adjusted to estimated gas

# A recipient that burns a lot of gas: its estimate covers it, so it is paid like the others, and the deployer
# loses at most the amounts plus the gas reserved on the screen
mkdir -p guzzler-src
cat > guzzler-src/Guzzler.sol <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Guzzler {
    uint256[] public junk;

    receive() external payable {
        for (uint256 i; i < 50; i++) junk.push(i);
    }
}
EOF
GUZZLER=$(forge create guzzler-src/Guzzler.sol:Guzzler --rpc-url "$FUND_RPC" --private-key "$TEST_KEY" --broadcast 2>/dev/null \
    | sed -n 's/^Deployed to: //p')
reset_balances 100000000000000000000
BEFORE=$(gwei "$(balance "$DEPLOYER")")
OUT=$(printf "$YES" | fund 10% $A1 "$GUZZLER" $A2); CODE=$?
RESERVE=$(gwei "$(cast to-wei "$(sed -n 's/^   gas:      \([0-9.]*\) ether reserved.*/\1/p' <<<"$OUT")" ether)")
SENT=$(( $(gwei "$(balance $A1)") + $(gwei "$(balance $A2)") + $(gwei "$(balance "$GUZZLER")") ))
check "gas guzzler: estimated well above a plain transfer, and paid like the others" "0 3 yes" \
    "$CODE $(grep -c '^ok      ' <<<"$OUT") $([ "$(sed -n "s/^   $GUZZLER  .*(gas estimate \([0-9]*\), .*/\1/p" <<<"$OUT")" -gt 100000 ] && echo yes || echo no)"
check "gas guzzler: the deployer lost at most the amounts plus the reserve shown" "yes" \
    "$([ $((BEFORE - $(gwei "$(balance "$DEPLOYER")"))) -le $((SENT + RESERVE + 1)) ] && echo yes || echo no)"

# EIP-1559 pricing: the maximum fee is twice the quote, and what a transfer pays fits within its limit at that fee
reset_balances 100000000000000000000
QUOTE=$(cast gas-price --rpc-url "$FUND_RPC")
OUT=$(printf "$YES" | fund 10% $A1)
TX=$(sed -n 's/^ok      .* tx \(0x[0-9a-f]*\)$/\1/p' <<<"$OUT")
LIMIT=$(sed -n "s/^   $A1  .*(gas estimate [0-9]*, limit \([0-9]*\))\$/\1/p" <<<"$OUT")
MAX_FEE=$(cast to-dec "$(cast rpc eth_getTransactionByHash "$TX" --rpc-url "$FUND_RPC" | jq -r .maxFeePerGas)")
RECEIPT=$(cast rpc eth_getTransactionReceipt "$TX" --rpc-url "$FUND_RPC")
PAID=$(( $(cast to-dec "$(jq -r .gasUsed <<<"$RECEIPT")") * $(cast to-dec "$(jq -r .effectiveGasPrice <<<"$RECEIPT")") ))
check "1559: the maximum fee is twice the quote" "$((2 * QUOTE))" "$MAX_FEE"
check "1559: what the transfer paid fits within its limit at that fee" "yes" "$([ "$PAID" -le $((LIMIT * MAX_FEE)) ] && echo yes || echo no)"

# DEPLOYER_KEY never reaches the screen, even when the run fails
for key in 0x0000000000000000000000000000000000000000000000000000000000c0ffee 0xd0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0; do
    printf 'DEPLOYER_KEY=%s\n' "$key" > .env
    OUT=$(printf "$YES" | fund 10% $A1); CODE=$?
    check "a key without funds (${key:0:6}…${key: -6}): fails, and the key never appears" "1 0" "$(nonzero $CODE) $(grep -c "${key:2}" <<<"$OUT")"
done
printf 'DEPLOYER_KEY=%s\n' "$DEPLOYER_KEY" > .env

# Running it twice pays twice: a top-up, as documented
reset_balances 100000000000000000000
printf "$YES" | fund 10% $A1 >/dev/null
ONCE=$(gwei "$(balance $A1)")
printf "$YES" | fund 10% $A1 >/dev/null
check "run twice: paid twice (a top-up)" "yes" "$([ "$(gwei "$(balance $A1)")" -gt "$ONCE" ] && [ "$ONCE" -gt 0 ] && echo yes || echo no)"

# Estimates outside sensible bounds, from a cast stub answering a chosen estimate for A1 (or for every address)
mkdir -p odd-estimate
cat > odd-estimate/cast <<EOF
#!/usr/bin/env bash
if [ "\$1" = estimate ] && { [ "\${@: -1}" = "$A1" ] || [ -f "$P/odd-estimate/all" ]; }; then
    cat "$P/odd-estimate/value"
    exit 0
fi
exec "$(command -v cast)" "\$@"
EOF
chmod +x odd-estimate/cast

# A tiny estimate: the limit is raised to 21,000, and the transfer goes through
echo 100 > odd-estimate/value
reset_balances 100000000000000000000
OUT=$(printf "$YES" | PATH="$P/odd-estimate:$PATH" just fund 10% $A1 2>&1); CODE=$?
TX=$(sed -n "s/^ok      $A1 .* tx \(0x[0-9a-f]*\)\$/\1/p" <<<"$OUT")
check "tiny estimate: shown with the limit raised to 21,000" "1" "$(grep -c "^   $A1  .*(gas estimate 100, limit 21000)\$" <<<"$OUT")"
check "tiny estimate: sent with a 21,000 limit, and funded" "0 21000 yes" \
    "$CODE $(cast to-dec "$(cast rpc eth_getTransactionByHash "${TX:-0x0}" --rpc-url "$FUND_RPC" | jq -r .gas)" 2>/dev/null) $([ "$(balance $A1)" != 0 ] && echo yes || echo no)"

# An absurd estimate (2^62): FAILED before sending, with the reason; the others are paid; the reserve stays sane
echo 4611686018427387904 > odd-estimate/value
reset_balances 100000000000000000000
NONCE=$(deployer_nonce)
OUT=$(printf "$YES" | PATH="$P/odd-estimate:$PATH" just fund 10% $A1 $A2 2>&1); CODE=$?
check "absurd estimate: FAILED with the reason, nothing sent to it" "1 1 0 $((NONCE + 1))" \
    "$(nonzero $CODE) $(grep -c "^FAILED  $A1: its gas estimate (4611686018427387904) is above 30000000, nothing sent, not funded\$" <<<"$OUT") $(balance $A1) $(deployer_nonce)"
check "absurd estimate: the others are paid, and the reserve isn't wrapped around" "yes 0" \
    "$([ "$(balance $A2)" != 0 ] && echo yes || echo no) $(grep -c '^   gas:      0 ether reserved\|^   gas:      -' <<<"$OUT")"
touch odd-estimate/all
NONCE=$(deployer_nonce)
OUT=$(printf "$YES" | PATH="$P/odd-estimate:$PATH" just fund 10% $A1 $A2 2>&1); CODE=$?
check "absurd estimates for every address: refused, nothing sent" "1 $NONCE 1" \
    "$(nonzero $CODE) $(deployer_nonce) $(grep -c 'no transfer can be sent (every gas estimate failed or is above 30000000)' <<<"$OUT")"
rm -rf odd-estimate

# The estimates for the real amounts exceed the first reserve: refused before anything is sent
mkdir -p growing
cat > growing/cast <<EOF
#!/usr/bin/env bash
# A 1-wei transfer is estimated at 21,000 gas, the real amounts at 20,000,000 (still under the 30,000,000 bound)
if [ "\$1" = estimate ]; then
    for a in "\$@"; do [ "\$prev" = --value ] && value=\$a; prev=\$a; done
    [ "\$value" = 1 ] && echo 21000 || echo 20000000
    exit 0
fi
exec "$(command -v cast)" "\$@"
EOF
chmod +x growing/cast
reset_balances 1000000000000000000  # 1 ether
NONCE=$(deployer_nonce)
OUT=$(printf "$YES" | PATH="$P/growing:$PATH" just fund 100% $A1 $A2 2>&1); CODE=$?
check "estimates grow with the amounts: refused, nothing sent" "1 $NONCE 0" "$(nonzero $CODE) $(deployer_nonce) $(balance $A1)"
check "estimates grow with the amounts: says why" "1" "$(grep -c "can't cover 2 transfer(s) of .* ether with their gas" <<<"$OUT")"
rm -rf growing

# A network with a forced gas price: the transfers use it, and the reserve is counted at it
just switch local-fixed >/dev/null
reset_balances 100000000000000000000 "$FIXED_RPC"
OUT=$(printf "$YES" | fund 10% $A1); CODE=$?
TX=$(sed -n 's/^ok      0x00000000000000000000000000000000000000a1 .* tx \(0x[0-9a-f]*\)$/\1/p' <<<"$OUT")
check "forced gas price: sent as a legacy transaction at that price" "0 0x0 5200000000000" \
    "$CODE $(cast rpc eth_getTransactionByHash "$TX" --rpc-url "$FIXED_RPC" | jq -r .type) $(cast to-dec "$(cast tx "$TX" gasPrice --rpc-url "$FIXED_RPC")")"
# Two transfers limited at twice a 21,000 estimate, at 5,200 gwei, need 0.4368 of the 0.4 ether held
reset_balances 400000000000000000 "$FIXED_RPC"
NONCE=$(deployer_nonce "$FIXED_RPC")
OUT=$(printf "$YES" | fund 10% $A1 $A2); CODE=$?
check "forced gas price: the reserve is counted at it" "1 $NONCE 1" \
    "$(nonzero $CODE) $(deployer_nonce "$FIXED_RPC") $(grep -c "can't cover" <<<"$OUT")"
# A large estimate at that price: 2,000,000 gas at 5,200 gwei is 10.4 ether, more wei than shell integers hold
mkdir -p big-estimate
cat > big-estimate/cast <<EOF
#!/usr/bin/env bash
[ "\$1" = estimate ] && { echo 1000000; exit 0; }
exec "$(command -v cast)" "\$@"
EOF
chmod +x big-estimate/cast
reset_balances 100000000000000000000 "$FIXED_RPC"
OUT=$(printf "$YES" | PATH="$P/big-estimate:$PATH" just fund 10% $A1 2>&1); CODE=$?
check "forced gas price, a large limit: the reserve is counted exactly, not wrapped around" "0 1 yes" \
    "$CODE $(grep -c '^   gas:      10.40* ether reserved for 1 transfer(s)' <<<"$OUT") $(awk -v b="$(ether "$(balance $A1 "$FIXED_RPC")")" 'BEGIN { print (b > 8.95 && b <= 8.96) ? "yes" : "no" }')"
rm -rf big-estimate
cd / && rm -rf "$P"
kill $FUND_ANVIL_PID $FIXED_ANVIL_PID 2>/dev/null
trap - EXIT

# --- fund on anvil-zksync: a transfer there needs more gas than on other chains (pubdata) ---

if command -v anvil-zksync >/dev/null; then
    ZK_PORT=8662
    require_free_port "$ZK_PORT"
    # anvil-zksync writes its log and cache in the current directory: give it its own
    ZK_DIR=$(mktemp -d)
    (cd "$ZK_DIR" && exec anvil-zksync --port "$ZK_PORT" >/dev/null 2>&1) &
    ZK_PID=$!
    trap 'kill $ZK_PID 2>/dev/null; rm -rf "$ZK_DIR"' EXIT
    ZK_RPC="http://127.0.0.1:$ZK_PORT"
    for _ in $(seq 1 120); do cast chain-id --rpc-url "$ZK_RPC" >/dev/null 2>&1 && break; sleep 1; done
    P=$(new_project)
    cd "$P"
    printf 'RPC_URL="%s"\nCHAIN_ID="260"\n' "$ZK_RPC" > lib/just-foundry/networks/local-zk.env
    just switch local-zk >/dev/null
    ZK_KEY=0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110  # a rich anvil-zksync account
    ZK_TO=0x1111111111111111111111111111111111111111
    printf 'DEPLOYER_KEY=%s\n' "$ZK_KEY" > .env
    OUT=$(printf "$YES" | just fund 10% $ZK_TO 2>&1); CODE=$?
    ESTIMATE=$(sed -n 's/.*(gas estimate \([0-9]*\), limit [0-9]*)$/\1/p' <<<"$OUT")
    check "zksync fund: the screen shows an estimate above 100,000 gas" "yes" "$([ "${ESTIMATE:-0}" -gt 100000 ] && echo yes || echo no)"
    check "zksync fund: funded, exits 0" "0 1" "$CODE $(grep -c "^ok      $ZK_TO [0-9.]* ether, tx 0x" <<<"$OUT")"
    ZK_TX=$(sed -n "s/^ok      $ZK_TO .* tx \(0x[0-9a-f]*\)\$/\1/p" <<<"$OUT")
    ZK_GAS_USED=$(cast to-dec "$(cast rpc eth_getTransactionReceipt "$ZK_TX" --rpc-url "$ZK_RPC" | jq -r .gasUsed)")
    check "zksync fund: mined, using more than 100,000 gas and less than the limit (twice the estimate)" "0x1 yes" \
        "$(cast rpc eth_getTransactionReceipt "$ZK_TX" --rpc-url "$ZK_RPC" | jq -r .status) $([ "$ZK_GAS_USED" -gt 100000 ] && [ "$ZK_GAS_USED" -le $((ESTIMATE * 2)) ] && echo yes || echo no)"
    check "zksync fund: received" "yes" "$([ "$(cast balance $ZK_TO --rpc-url "$ZK_RPC")" != 0 ] && echo yes || echo no)"
    cd / && rm -rf "$P"
    kill $ZK_PID 2>/dev/null; rm -rf "$ZK_DIR"
    trap - EXIT
else
    echo "SKIP    fund on anvil-zksync: install anvil-zksync (just setup-zksync) to run it"
fi

echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
