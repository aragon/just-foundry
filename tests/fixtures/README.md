# Test fixtures

`project/` is a minimal plugin-like project: `src/Thing.sol` (contracts `Thing`, `Other`, and `Parent`,
whose constructor deploys an `Other`) and `script/Deploy.s.sol`, which deploys, in this order:

| # | Contract | How | Constructor argument |
|---|----------|-----|----------------------|
| 1 | Thing | `new` | 1 |
| 2 | Other | `new` | – |
| 3 | Thing | `new` | 2 |
| 4 | Thing | `new{salt}` (CREATE2) | 3 |
| 5 | Parent | `new` | 7 |
| 6 | Parent | `new{salt}` (CREATE2) | 8 |

So `Thing` and `Parent` have several deployments, and the latest of each is a CREATE2 one.

The broadcasts are the files forge wrote when this script ran for real:

- `broadcast/Deploy.s.sol/1/` — forge 1.3.5 against `anvil` (chain 31337), filed under chain 1 (with its `chain` field set to 1) so that
  `just switch mainnet` reads it.
- `broadcast/Deploy.s.sol/324/` — foundry-zksync 0.1.10 (`forge script --zksync --slow`) against
  anvil-zksync 0.7.1 (chain 260), filed under chain 324 (with its `chain` field set to 324) so that `just switch zksync` reads it. The
  `factoryDeps` (the full contract bytecode, 200 KB) and receipt logs are emptied: nothing reads them.

`out/` and `zkout/` keep only the fields the recipes read from the artifacts: `bytecode.object` and `hash`.

To regenerate, work in a temporary copy of `project/`, never in place (forge would leave full artifacts, `cache/`
and `out/build-info/` here, and the suite refuses to run on them): build the copy with both toolchains, run the
script against `anvil` and against
`anvil-zksync` with `--broadcast`, then copy the two `run-latest.json` files (emptying `factoryDeps` and
`logs`) and the artifacts, trimmed the same way, back here. The addresses at the top of `tests/run.sh` change with them.
