# BabyNoxa contracts

Foundry workspace for the BabyNoxa bonding curve and its pinned V2-compatible AMM fixtures.

`src/BondingCurve.sol` is the production real-token/real-ETH curve. It is funded and opened by the factory boundary, preserves separate reserve/fee/refund/credit buckets, and calls its snapshotted `GraduationManagerV1` atomically on the final buy. Its Phase 7 fee operations use per-curve pull custody, immutable creator and treasury beneficiaries, beneficiary-selected `claimTo` recipients, launch-aware claim telemetry, and cumulative accrued/claimed accounting. No separate administrator-controlled treasury vault exists in V1.

`src/GraduationManagerV1.sol` is the production guarded-AMM graduation path. It accepts only registered lifecycle-ready curves, wraps exact liquidity base, burns unused reserve tokens, clears unsolicited manager/pair balances under the approved policy, bootstraps the official pair, verifies all usable LP is burned, enforces the absolute and relative price-continuity limits, and leaves no normal graduation assets behind. The real local curve-manager-pair integration and post-graduation Router02 swap are covered by `test/integration/GraduationManagerV1.t.sol`.

`src/BabyNoxaFactory.sol` is the production atomic launch and immutable registry path. It creates the guarded official pair, deploys and funds the fixed-supply token and curve, commits launch metadata, snapshots treasury/manager versions, and performs the optional creator buy before returning control. `src/BabyNoxaLaunchDeployer.sol` is its immutable factory-only constructor helper; it exists solely to keep creation bytecode outside the factory runtime and has no proxy, delegate-call, administration, or upgrade behavior. The complete factory-created lifecycle is covered by `test/integration/BabyNoxaFactory.t.sol`.

## V2 test stack

The test stack vendors:

- Uniswap V2 core `v1.0.1`
- Uniswap V2 periphery at commit `ed24991304291297c3b4a52818d02f46a17aa9a2`
- Uniswap Solidity library `v1.1.1`

The upstream fixture's periphery pair initialization-code hash is intentionally patched to match the standard pair bytecode produced by this repository's Foundry settings. It is retained to characterize the attacks that a permissionless factory permits. See `lib/uniswap-v2-periphery/BABYNOXA_MODIFICATIONS.md`.

The selected local stack adds `GuardedV2Factory`, `GuardedV2Pair`, and `GuardedV2Router02`. Official pair creation is launch-factory-only. Each pair locks all reserve-changing V2 operations until its snapshotted manager atomically burns donations, pulls the exact initial reserves, burns all usable first-mint LP, and permanently removes bootstrap authority. The guarded router resolves pairs through the dedicated factory registry rather than the upstream pair-bytecode hash.

Both local factories keep `feeTo == address(0)` and `feeToSetter == address(0)`, permanently disabling the optional V2 protocol fee. The normal 0.30% V2 swap fee remains in the pool. `TestWrappedNative` is a local test asset and must not be configured as a production wrapped-native token.

## Build and test

```sh
forge build
forge test
```

## Deploy the complete stack to local Anvil

Start Anvil:

```sh
anvil --chain-id 31337
```

In another terminal, use one of Anvil's development-only private keys:

```sh
export PRIVATE_KEY=<anvil-development-key>
forge script script/DeployBabyNoxa.s.sol:DeployBabyNoxa \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --gas-estimate-multiplier 200
forge script script/SmokeBabyNoxa.s.sol:SmokeBabyNoxa \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --gas-estimate-multiplier 200
```

The deployment script creates and validates the test wrapped-native token, guarded factory, guarded Router02, BabyNoxa factory, launch deployer, and GraduationManagerV1; it activates the manager and writes `deployments/31337.json`. The smoke script exercises both launch choices and the complete curve-to-AMM lifecycle. Generated deployment and broadcast artifacts are ignored by Git; `deployments/31337.example.json` documents the schema.

`DeployGuardedTestV2.s.sol` remains an isolated guarded-AMM fixture. `DeployTestV2.s.sol` remains available for tests of the rejected permissionless factory. Neither is the complete launchpad deployment path.

## Deploy to Polygon Amoy

The complete deployment, explorer-verification, ownership-finalization, and rollback procedures are in [`docs/PHASE_10_DEPLOYMENT.md`](../docs/PHASE_10_DEPLOYMENT.md). Amoy requires an explicitly supplied, bytecode-verified wrapped-native address. Never commit a private key or place it directly in shell history.
