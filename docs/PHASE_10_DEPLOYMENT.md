# Phase 10 deployment and recovery runbook

## Supported configuration

The deployment script accepts only:

- Local Anvil: chain ID `31337`; deploys `TestWrappedNative` automatically.
- Polygon Amoy: chain ID `80002`; either requires a bytecode-verified `WRAPPED_NATIVE`
  address or explicitly deploys the repository's public-testnet-only wrapper with
  `DEPLOY_TEST_WRAPPED_NATIVE=true`.

Polygon PoS mainnet remains unapproved for production. The script permits only an
explicitly acknowledged `UNAPPROVED_MAINNET_TEST` deployment on chain `137`, pins
canonical WPOL, and forbids `TestWrappedNative`. This exception does not satisfy or
waive any Phase 14 gate.

### Graduation venue on mainnet: QuickSwap V2

Unlike local/Amoy (which deploy the guarded `GuardedV2*` stack), the Polygon mainnet
path wires the curve onto the canonical **QuickSwap V2** deployment so graduated tokens
are discoverable on QuickSwap and DexScreener. It deploys `BabyNoxaFactoryQS` and
`GraduationManagerV2` against QuickSwap's factory
(`0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32`) and router
(`0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff`); no guarded factory/router is deployed.
The artifact records `graduationVenue: "QUICKSWAP_V2"` and the
`quickSwapV2Factory` / `quickSwapV2Router02` / `graduationManagerV2` keys.

Tradeoff: QuickSwap pairs are permissionless stock Uniswap V2 pairs, so the atomic,
un-frontrunnable first-liquidity guarantee of the guarded pair is replaced with a
defensive seed. `GraduationManagerV2` skims donated balances to the burn address,
rejects a pair that already holds liquidity (nonzero reserves or LP supply), mints all
usable LP straight to the dead address, and enforces the same terminal price-continuity
band. A griefer can still brick a single launch's graduation by permanently locking
synced reserves into its pair before the completing buy — an accepted cost of listing on
a permissionless AMM. See `test/integration/QuickSwapGraduation.t.sol` and
`test/fork/PolygonQuickSwapGraduationFork.t.sol`.

## Explicit unapproved Polygon mainnet test

This path spends real POL and creates immutable public contracts. It is not a
production approval. Before running it, independently verify chain `137`, canonical
WPOL, the signer balance and nonce, current fee data, predicted addresses, exact
bytecode hashes, and a maximum acceptable gas price. Never reuse the Amoy environment
file or configure the test wrapper.

The deployment requires:

```sh
export MAINNET_TEST_ACK=I_ACKNOWLEDGE_UNAUDITED_MAINNET_TEST
forge script script/DeployBabyNoxa.s.sol:DeployBabyNoxa \
  --rpc-url "$POLYGON_MAINNET_RPC_URL" --broadcast --slow \
  --gas-estimate-multiplier 200 --with-gas-price "$MAX_ACCEPTED_GAS_PRICE"
```

The script pins WPOL to `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270`
and writes `deployments/137.json` with `unapprovedMainnetTest: true` and
`releaseStatus: "UNAPPROVED_MAINNET_TEST"`. Do not publish the deployment as an
audited or approved release.

`BABYNOXA_TREASURY` is an address, not a deployed vault. V1 intentionally uses the immutable per-curve treasury beneficiary model. `BABYNOXA_OWNER` defaults to the deployer and must equal it during initial deployment so the script can activate the manager. Transfer ownership only after verification and smoke testing.

## Clean local deployment and lifecycle

From `contracts/`, start a clean node:

```sh
anvil --chain-id 31337
```

Use a local Anvil development key only:

```sh
export PRIVATE_KEY=<anvil-development-key>
forge script script/DeployBabyNoxa.s.sol:DeployBabyNoxa \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --gas-estimate-multiplier 200
forge script script/SmokeBabyNoxa.s.sol:SmokeBabyNoxa \
  --rpc-url http://127.0.0.1:8545 --broadcast --slow --gas-estimate-multiplier 200
```

The deploy script writes `deployments/31337.json`. The smoke script reads it and:

1. Creates a zero-value launch.
2. Buys, approves, sells, and claims the sell credit and role fees.
3. Performs the final buy and atomic graduation, then claims the refund and remaining fees.
4. Swaps wrapped native for the graduated token through Router02.
5. Verifies curve trading is closed, bootstrap authority is erased, treasury LP is zero, and usable LP is at the dead address.
6. Creates a second launch with an atomic creator buy and verifies it remains in curve trading.

`--slow` is required because every smoke transaction depends on the preceding receipt. The 200% gas-estimate multiplier avoids local RPC underestimation on storage-clearing claim transactions.

## Amoy deployment and explorer verification

Before spending test POL:

1. Confirm RPC chain ID `80002` independently.
2. Confirm the official wrapped-native address and bytecode from authoritative Polygon documentation.
   If Amoy has no authoritative canonical deployment, set `DEPLOY_TEST_WRAPPED_NATIVE=true`
   to deploy the repository wrapper in the same guarded broadcast. Record it as test-only.
3. Use a dedicated testnet deployer and treasury address; never use an Anvil key.
4. Build and run the complete Foundry suite from a clean checkout.

Deploy:

```sh
export PRIVATE_KEY=<dedicated-testnet-key>
export BABYNOXA_TREASURY=<testnet-treasury>
export DEPLOY_TEST_WRAPPED_NATIVE=true
forge script script/DeployBabyNoxa.s.sol:DeployBabyNoxa \
  --rpc-url "$AMOY_RPC_URL" --broadcast --slow --gas-estimate-multiplier 200
```

Alternatively, leave `DEPLOY_TEST_WRAPPED_NATIVE` unset and export a verified
`WRAPPED_NATIVE` address. The two modes are mutually exclusive in practice: when the
test-wrapper flag is true, the script deploys and records its own wrapper and ignores
`WRAPPED_NATIVE`. `TestWrappedNative` is acceptable only on local networks and public
testnets; it is not a production dependency.

Do not pass `BABYNOXA_OWNER` unless it is the deployer. After deployment, compare `deployments/80002.json` with direct RPC reads for every address and relationship. Verify source using Foundry's `forge verify-contract` for `BabyNoxaFactory`, `BabyNoxaLaunchDeployer`, `GraduationManagerV1`, `GuardedV2Factory`, `GuardedV2Pair`, and `GuardedV2Router02`, supplying exact compiler, optimizer, EVM-version, constructor arguments, and chain `80002`. Record explorer URLs, deployment block, transaction hashes, bytecode hashes, and the verified wrapped-native source beside the artifact.

Before ownership transfer, create test launches and repeat the complete lifecycle checks manually or with an Amoy-specific smoke script using non-production metadata. The local smoke script deliberately rejects non-31337 chains.

## Rollback and ownership finalization

Contracts are immutable and cannot be deleted or upgraded. A mistaken deployment is abandoned, not repaired in place.

Before accepting ownership or publishing addresses:

1. Stop immediately if any transaction, bytecode, constructor input, chain ID, or wiring check differs.
2. Do not create public launches and do not call `transferOwnership`.
3. Mark the artifact `ABANDONED` in the deployment record with the reason and transaction hashes.
4. Rotate a compromised deployer key and treasury address where applicable.
5. Correct configuration and deploy a completely new stack; never reuse an old guarded factory because its launch-factory authority is immutable.
6. Publish only the replacement artifact and explicitly list superseded addresses.

After bytecode verification and lifecycle rehearsal, initiate `transferOwnership(newOwner)` from the deployer. The intended multisig or operational owner must independently verify all addresses before calling `acceptOwnership()`. If it does not accept, the deployer remains owner and can abandon the stack without transferring control. Treasury rotation affects only future launches; existing curves retain their snapshotted beneficiary.
