# just-foundry

A drop-in task runner and environment manager for Foundry projects. Add it as a submodule and your project gets a one stop shop with easy network switching, per-network flag resolution, deployment helpers, testing, verification helpers and even secrets management. All configured to work on every supported chain.

---

## Install

```sh
git submodule add https://github.com/aragon/just-foundry.git lib/just-foundry
```

Create a two-line `justfile` at your project root:

```just
default: help
import 'lib/just-foundry/justfile'

# Optional: override if you use a different deployment script
# DEPLOY_SCRIPT := "script/Deploy.s.sol:DeployScript"
```

Initialize submodules and set up your target network:

```sh
git submodule update --init --recursive
just init sepolia
```

> **Fresh clones:** `just init` imports its recipes from `lib/just-foundry/justfile`, so the submodule needs exist first.

Run `just help` to see everything available.

Secrets and env vars:

- Add your secrets and overrides to `.env` at the project root (gitignored).
- Recommended: Consider creating `.vars.yaml` with the secrets your project needs ([See below](#secrets))

```yaml
# .vars.yaml
keys:
  - DEPLOYER_KEY
  - ETHERSCAN_API_KEY
  - RPC_URL
  # - ...
```


---

## Commands

```
$ just
Available recipes:
    default
    help                                    # Show available commands

    [setup]
    init network="mainnet"                  # Initialize the project for a given network (default: mainnet)
    switch network override=""              # Select the active network (pass "override" for local copy)
    setup                                   # Install Foundry

    [script]
    predeploy                               # Dry-run the deploy script (no broadcast)
    deploy *args                            # Deploy: run tests then broadcast, with log

    [script-base]
    run script *args                        # Broadcast a forge script (logged; name derived from contract/file)
    dry-run script                          # Simulate running a forge script (no broadcast)

    [test]
    test *args                              # Run all unit tests
    test-fork *args                         # Run fork tests (requires RPC_URL)
    test-coverage                           # Generate HTML coverage report under ./report

    [helpers]
    env                                     # Show current environment (resolved values + sources)
    ipfs-pin file                           # Pin a file to IPFS via Pinata (requires PINATA_JWT in vars or .env)
    balance                                 # Show current wallet balance

    [develop]
    clean                                   # Clean compiler artifacts and coverage reports
    storage-info contract                   # Show the storage layout of a contract
    anvil                                   # Start a forked EVM (set FORK_BLOCK_NUMBER in .env to pin a block)

    [verification]
    verify type="" script=""                # Verify all contracts from the latest broadcast (defaults to DEPLOY_SCRIPT)
```

Additional helpers (not in `just help`): `gas-price`, `nonce`, `clean-nonce`, `clean-nonces`, `refund`. See [Debug helpers](#debug-helpers).

---

## Environment variables

All variables below are resolved automatically from the active network config when you call `env_load`. You can override any of them in your `.env` file or via `vars`.

| Variable | Description |
|---|---|
| `RPC_URL` | JSON-RPC endpoint (public fallback; override with a private one) |
| `CHAIN_ID` | EVM chain ID |
| `NETWORK_NAME` | Network name (derived from your last `just switch` or `just init`) |
| `VERIFIER` | Default verifier (`etherscan`, `blockscout`, `sourcify`, `zksync`, `routescan-mainnet`, `routescan-testnet`) |
| `BLOCKSCOUT_HOST_NAME` | Blockscout host — required when `VERIFIER=blockscout` |
| `FOUNDRY_EVM_VERSION` | EVM version override (e.g. `shanghai` for Chiliz) — picked up by Foundry automatically |
| `DAO_FACTORY_ADDRESS` | Aragon OSx `DAOFactory` |
| `PLUGIN_REPO_FACTORY_ADDRESS` | Aragon OSx `PluginRepoFactory` |
| `PLUGIN_SETUP_PROCESSOR_ADDRESS` | Aragon OSx `PluginSetupProcessor` |
| `MANAGEMENT_DAO_ADDRESS` | Aragon management DAO |
| `MANAGEMENT_DAO_MULTISIG_ADDRESS` | Aragon management DAO multisig |
| `TOKEN_VOTING_PLUGIN_REPO_ADDRESS` | Token Voting plugin repo |
| `MULTISIG_PLUGIN_REPO_ADDRESS` | Multisig plugin repo |
| `LOCK_TO_VOTE_PLUGIN_REPO_ADDRESS` | Lock to Vote plugin repo |
| `ADMIN_PLUGIN_REPO_ADDRESS` | Admin plugin repo |
| `SPP_PLUGIN_REPO_ADDRESS` | Staged Proposal Processor plugin repo |

The following are **not** in the network config — supply them in your local `.env` or via `vars`:

| Variable | Description |
|---|---|
| `DEPLOYER_KEY` | Deployer wallet private key |
| `ETHERSCAN_API_KEY` | Required when `VERIFIER=etherscan` |
| `PINATA_JWT` | Required for `just ipfs-pin` |
| `REFUND_ADDRESS` | Destination for `just refund` |
| `FORK_BLOCK_NUMBER` | Pin fork tests to a specific block (optional) |

---

## How it works

### Network config

Each supported network has a config file with public variables at `lib/just-foundry/networks/<name>.env`:

```sh
RPC_URL="https://eth-sepolia.drpc.org"   # public fallback; override with `vars`
CHAIN_ID="11155111"
VERIFIER="etherscan"
BLOCKSCOUT_HOST_NAME="eth-sepolia.blockscout.com" # alternative

DAO_FACTORY_ADDRESS="0x..."
PLUGIN_REPO_FACTORY_ADDRESS="0x..."
# ... all Aragon OSx addresses for this network
```

`just switch <network>` creates a symlink `lib/just-foundry/.env → networks/<network>.env`. The symlink defines which network is active: `NETWORK_NAME` is exported with the appropriate value.

### Local overrides

To customize a network's config (e.g. change the RPC URL or add addresses for a custom deployment), create a local override:

```sh
just switch sepolia override
```

This copies the upstream template to `.env.sepolia` at your project root. From that point, the local copy is used instead of the upstream file: edit it freely. The symlink still determines `NETWORK_NAME`.

Add `.env.*` to your project's `.gitignore` to keep override files out of version control.

### Secrets

Network environment files only contain public values that you can override. Secrets need to be provided by the user. Two options:

**Option 1 — plain `.env` file** at the root of your project.

**Option 2 — using `vars` (recommended).** An age-encrypted local store. Install it, store your keys, and every project resolves them automatically:

```sh
# Install
just install-vars

# Store your secrets and overrides
vars set DEPLOYER_KEY
vars set ETHERSCAN_API_KEY
vars set sepolia/RPC_URL "https://sepolia.drpc.org"
vars set hoodi/RPC_URL "https://hoodi.drpc.org"
vars resolve

# Verify everything looks right
just env
```

Both options are supported — `vars resolve` overrides the values from the active network config and `.env`, if present.

### Profiles and network switching

When you run `just switch sepolia`, the active network becomes `sepolia`. You may want to allow certain environment vars to change depending on the environment, which can be achieved by using profiles.

`just` tasks that resolve secrets will automatically call `vars resolve -p <nework>` (if the tool is installed and such profile exists in `.vars.yaml`):

```yaml
# Env vars required by the project
keys:
  - DEPLOYER_KEY
  - ETHERSCAN_API_KEY
  - RPC_URL

# Profiles: mapping specific env vars, depending on the environment
profiles:
  sepolia:
    DEPLOYER_KEY: sepolia/DEPLOYER_KEY
    RPC_URL: sepolia/RPC_URL
  mainnet:
    DEPLOYER_KEY: mainnet/DEPLOYER_KEY
```

This lets you store per-network credentials in your:

```sh
# store your secrets locally
vars set sepolia/DEPLOYER_KEY     # testnet wallet
vars set mainnet/DEPLOYER_KEY     # prod wallet
vars set sepolia/RPC_URL          # private RPC endpoint
```

### `just env`

Shows the fully resolved environment — every variable once, with its effective value and source:

```
Network:  sepolia (11155111)
Verifier: etherscan

  [vars]     DEPLOYER_KEY                   1234****
  [vars]     ETHERSCAN_API_KEY              abcd****
  [dotenv]   RPC_URL                        https://sepolia.drpc.org
  [dotenv]   DAO_FACTORY_ADDRESS            0xB815791c...
  [not set]  REFUND_ADDRESS
```

---

## Customization

### Override the deploy script

The default deploy script is `script/Deploy.s.sol:DeployScript`. Override it in your root `justfile`:

```just
default: help
import 'lib/just-foundry/justfile'

DEPLOY_SCRIPT := "script/MyDeploy.s.sol:MyScript"
```

### Override or shadow recipes

Any inherited recipe can be replaced by redefining it with the same name in your project's justfile. just-foundry sets `allow-duplicate-recipes`, so your definition silently wins over the imported one.

Common cases:

**Replace** an inherited recipe with your own logic: same name, different body:

```just
default: help
import 'lib/just-foundry/justfile'

# Custom deploy: extra steps before broadcasting
deploy *args:
    just my-pre-deploy-hook
    just run script/Deploy.s.sol:Deploy {{ args }}
    just my-post-deploy-hook
```

**Shadow recipes that don't apply** — useful when the project has no canonical single-deploy script. Mark the shadow `[private]` so it's hidden from `just --list`:

```just
default: help
import 'lib/just-foundry/justfile'

[private]
deploy *args:
    @echo "Use 'just deploy-<component>' (e.g. 'just deploy-foo')." >&2
    @exit 1

[private]
predeploy:
    @echo "Use 'just predeploy-<component>'." >&2
    @exit 1
```

### Add your own recipes

Define them in your root `justfile` after the import.

**Broadcast a script** — use `just run <script>` as the building block. The log filename is derived automatically: contract name when the script has a `:Contract` suffix, otherwise the file's basename (without `.s.sol`):

```just
default: help
import 'lib/just-foundry/justfile'

# Logs to logs/Upgrade-<network>-<timestamp>.log
upgrade:
    just run script/Upgrade.s.sol:Upgrade

# Logs to logs/Seed-<network>-<timestamp>.log
seed:
    just run script/Seed.s.sol
```

**Dry-run** — use `just dry-run <script>`:

```just
check:
    just dry-run script/Check.s.sol:Check
```

**Custom logic before broadcasting** — source `{{ JUST_LIB }}` directly:

```just
deploy-and-verify *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source {{ JUST_LIB }} && env_load
    echo "Deploying to $NETWORK_NAME..."
    just run script/Deploy.s.sol:Deploy {{ args }}
    just verify
```

**Custom logged command** — call `run_logged` directly for non-forge executables:

```just
snapshot:
    #!/usr/bin/env bash
    source {{ JUST_LIB }} && env_load
    LOG="logs/snapshot-$NETWORK_NAME-$(date +%y-%m-%d-%H-%M).log"
    run_logged "$LOG" my-command --network "$NETWORK_NAME"
    echo "Log: $LOG"
```

`JUST_LIB` exposes: `env_load [--verbose]`, `env_network_name`, `env_show`, `run_logged <log> <cmd…>`, `strip_ansi <file>`.

---

## Supported networks

| Network | Chain ID |
|---------|----------|
| mainnet | 1 |
| sepolia | 11155111 |
| arbitrum | 42161 |
| optimism | 10 |
| base | 8453 |
| polygon | 137 |
| avalanche | 43114 |
| chiliz | 88888 |
| corn | 21000000 |
| katana | 747474 |
| hemi | 43111 |
| monad | 143 |
| peaq | 3338 |
| zksync | 324 |
| zksync-sepolia | 300 |

To add a network, open a PR with a new `networks/<name>.env` file.

> **ZkSync note:** The `zksync` and `zksync-sepolia` networks require a separate Foundry fork. Run `just setup-zksync` to install it — this places `forge-zksync` alongside the standard `forge` binary, and recipes will pick the right one automatically based on the active network.

---

## Debug helpers

These recipes are hidden from `just help` but available to run directly:

```sh
just balance             # deployer wallet balance
just gas-price           # current gas price on active network
just nonce               # current deployer nonce
just clean-nonce 27      # cancel a stuck tx by replacing it at nonce 27
just clean-nonces 2 3 4  # cancel multiple stuck txs
just refund              # sweep remaining balance to REFUND_ADDRESS
```

---

## Resources

- [Foundry Book](https://getfoundry.sh/)
- [Aragon OSx Docs](https://docs.aragon.org/osx/)
- [Safe Vars (secrets manager)](https://github.com/vars-cli/vars)
