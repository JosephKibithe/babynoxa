# BabyNoxa contracts

Foundry workspace for the BabyNoxa bonding curve and its pinned V2-compatible test AMM.

## V2 test stack

The test stack vendors:

- Uniswap V2 core `v1.0.1`
- Uniswap V2 periphery at commit `ed24991304291297c3b4a52818d02f46a17aa9a2`
- Uniswap Solidity library `v1.1.1`

The periphery pair initialization-code hash is intentionally patched to match the pair bytecode produced by this repository's Foundry settings. See `lib/uniswap-v2-periphery/BABYNOXA_MODIFICATIONS.md`.

This deployment is for local networks and Polygon Amoy testing only. `TestWrappedNative` is not a production wrapped-native asset. The V2 factory is deployed with `feeTo == address(0)` and `feeToSetter == address(0)`, permanently disabling the optional V2 protocol fee. The normal 0.30% V2 swap fee remains in the pool.

## Build and test

```sh
forge build
forge test
```

## Deploy to local Anvil

Start Anvil:

```sh
anvil --chain-id 31337
```

In another terminal, use one of Anvil's development-only private keys:

```sh
PRIVATE_KEY=<anvil-development-key> forge script script/DeployTestV2.s.sol:DeployTestV2 \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

The script prints and validates the factory, Router02, and test wrapped-native addresses. Foundry broadcast files and private transaction inputs are ignored by Git.

## Deploy to Polygon Amoy

Use a dedicated testnet deployer with test POL. This currently deploys the standard permissionless V2 factory and is suitable for isolated AMM testing only; do not connect it to public BabyNoxa launches until pair pre-seeding protection is implemented and tested.

```sh
PRIVATE_KEY=<amoy-test-deployer-key> forge script script/DeployTestV2.s.sol:DeployTestV2 \
  --rpc-url <amoy-rpc-url> \
  --broadcast
```

Never commit the private key or place it directly in shell history. Record the resulting addresses under chain ID `80002` only after verifying `router.factory()`, `router.WETH()`, factory fee settings, and deployed bytecode.
