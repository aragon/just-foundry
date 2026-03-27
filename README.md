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

Initialize for your target network:

```sh
just init sepolia
```

Run `just help` to see everything available.

Secrets and env vars:

- Copy `.env.example` into `.env` and customize your deployment settings.
- Recommended: Consider creating `.vars.yaml` with the secrets your project needs ([See below](#secrets))

```yaml
# .vars.yaml
keys:
  - DEPLOYMENT_PRIVATE_KEY
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
    switch network                          # Select the active network
    setup                                   # Install Foundry

    [script]
    predeploy                               # Simulate the deploy script
    deploy                                  # Deploy: run tests, broadcast, tee to log
    resume-deploy                           # Resume a pending deployment
    run script *args                        # Run a forge script (broadcast)
    simulate script                         # Simulate a forge script (no broadcast)

    [helpers]
    env                                     # Show current environment (resolved values + sources)
    balance                                 # Show current wallet balance

    [test]
    test *args                              # Run all unit tests
    test-fork *args                         # Run fork tests (requires RPC_URL)
    test-coverage                           # Generate HTML coverage report under ./report

    [develop]
    clean                                   # Clean compiler artifacts and coverage reports
    storage-info contract                   # Show the storage layout of a contract
    anvil                                   # Start a forked EVM (set FORK_BLOCK_NUMBER in .env to pin a block)

    [verification]
    verify verifier="" script=DEPLOY_SCRIPT # Verify all contracts from the latest broadcast
```

Additional helpers (not in `just help`): `gas-price`, `nonce`, `clean-nonce`, `clean-nonces`, `refund`. See [Debug helpers](#debug-helpers).

---

## How it works

### Network config

Each supported network has a flat config file with public variables at `lib/just-foundry/networks/<name>.env`:

```sh
RPC_URL="https://eth-sepolia.drpc.org"   # public fallback; override with `vars`
CHAIN_ID="11155111"
NETWORK_NAME="sepolia"
VERIFIER="etherscan"
BLOCKSCOUT_HOST_NAME="eth-sepolia.blockscout.com" # alternative

DAO_FACTORY_ADDRESS="0x..."
PLUGIN_REPO_FACTORY_ADDRESS="0x..."
# ... all Aragon OSx addresses for this network
```

These files contain ready to use constants that your Foundry project can consume.

`just switch <network>` creates a symlink `lib/just-foundry/.env → networks/<network>.env`. That symlink defines which network is currently active.

### Secrets

Network environment files only contain public values that you can override. Secrets need to be provided by the user. Two options:

**Option 1 — plain `.env` file** at the root of your project.

**Option 2 — using `vars` (recommended).** An age-encrypted local store. Install it, store your keys, and every project resolves them automatically:

```sh
# Install
just install-vars

# Store your secrets and overrides
vars set DEPLOYMENT_PRIVATE_KEY
vars set ETHERSCAN_API_KEY
vars set sepolia/RPC_URL "https://sepolia.drpc.org"
vars set hoodi/RPC_URL "https://hoodi.drpc.org"
vars resolve

# Verify everything looks right
just env
```

Both options are supported — `vars resolve` overrides the values from `lib/just-foundry/.env` and `.env`, if present.

### Profiles and network switching

When you run `just switch sepolia`, the active network becomes `sepolia`. You may want to allow certain environment vars to change depending on the environment, which can be achieved by using profiles.

`just` tasks that resolve secrets will automatically call `vars resolve -p <nework>` (if the tool is installed and such profile exists in `.vars.yaml`):

```yaml
# Env vars required by the project
keys:
  - DEPLOYMENT_PRIVATE_KEY
  - ETHERSCAN_API_KEY
  - RPC_URL

# Profiles: mapping specific env vars, depending on the environment
profiles:
  sepolia:
    DEPLOYMENT_PRIVATE_KEY: sepolia/DEPLOYMENT_PRIVATE_KEY
    RPC_URL: sepolia/RPC_URL
  mainnet:
    DEPLOYMENT_PRIVATE_KEY: mainnet/DEPLOYMENT_PRIVATE_KEY
```

This lets you store per-network credentials in your:

```sh
# store your secrets locally
vars set sepolia/DEPLOYMENT_PRIVATE_KEY   # testnet wallet
vars set mainnet/DEPLOYMENT_PRIVATE_KEY   # prod wallet
vars set sepolia/RPC_URL                  # private RPC endpoint
```

### `just env`

Shows the fully resolved environment — every variable once, with its effective value and source:

```
Network:  sepolia (11155111)
Verifier: etherscan

  [vars]     DEPLOYMENT_PRIVATE_KEY         1234****
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

### Add your own recipes

Define them in your root `justfile` after the import:

```just
default: help
import 'lib/just-foundry/justfile'

# Seed the protocol with test data
seed:
    #!/usr/bin/env bash
    source {{ENV_RESOLVE_LIB}} && env_load
    just run script/Seed.s.sol:Seed
    just run script/Seed.s.sol:Seed --slow --legacy
```

`ENV_RESOLVE_LIB` loads the primitives to resolve and use environment variables from the available sources (`env_load_network`, `env_load`, and `env_show`).

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
| katana | 747 |
| peaq | 3338 |
| zksync | 324 |
| zksync-sepolia | 300 |

To add a network, open a PR with a new `networks/<name>.env` file.

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
