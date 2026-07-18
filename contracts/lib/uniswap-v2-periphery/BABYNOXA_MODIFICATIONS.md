# BabyNoxa modifications

Modified on 2026-07-18.

`contracts/libraries/UniswapV2Library.sol` uses the initialization-code hash of the pair bytecode produced by BabyNoxa's pinned Foundry build. This replaces the upstream Ethereum deployment hash so `Router02.pairFor` resolves pairs created by the locally compiled factory.

The deployment script and integration tests recompute this hash and fail before deployment if the pair bytecode changes.
