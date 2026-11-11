#!/usr/bin/env bash
# tests/run.sh — tests for the just-foundry recipes, run against the fixture project in tests/fixtures/project
# Usage: bash tests/run.sh   (needs just, jq and forge)
#
# Each test runs in a fresh copy of the fixture project, with this repo copied to lib/just-foundry, the way
# a plugin repo imports it. The fixture broadcasts are real: tests/fixtures/README.md says how they were made.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE="$REPO/tests/fixtures/project"
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

# --- clean-nonce and refund send with the chain's gas flags ---

P=$(new_project)
cd "$P"
mkdir -p stubs
cat > stubs/cast <<'EOF2'
#!/usr/bin/env bash
case "$1" in
    wallet) echo 0x00000000000000000000000000000000000000aa ;;
    balance) echo 1000000000000000000 ;;
    gas-price) echo 1 ;;
    send) echo "$*" >> cast-calls.log ;;
esac
EOF2
# Test-sized numbers only: enough to stand in for bc
printf '#!/usr/bin/env bash\nread -r e; echo $(( e ))\n' > stubs/bc
chmod +x stubs/*
printf 'DEPLOYER_KEY=0x01\nREFUND_ADDRESS=0x00000000000000000000000000000000000000bb\n' > .env
just switch chiliz >/dev/null
PATH="$PWD/stubs:$PATH" just clean-nonce 7 >/dev/null 2>&1
check "clean-nonce: the chain's gas flags" "1" "$(grep -c -- '--legacy --gas-price 5200000000000' cast-calls.log)"
rm -f cast-calls.log
echo y | PATH="$PWD/stubs:$PATH" just refund >/dev/null 2>&1
check "refund: the chain's gas flags" "1" "$(grep -c -- '--legacy --gas-price 5200000000000' cast-calls.log)"
# 1 ETH minus 50,000 gas at the forced 5,200 gwei, not at the node's quote of 1 wei
check "refund: what is left after gas at the forced price" "1" "$(grep -c -- '--value 740000000000000000 ' cast-calls.log)"
just switch mainnet >/dev/null
rm -f cast-calls.log
echo y | PATH="$PWD/stubs:$PATH" just refund >/dev/null 2>&1
check "refund: the node's gas price where none is forced" "1" "$(grep -c -- '--value 999999999999950000 ' cast-calls.log)"
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

echo ""
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
