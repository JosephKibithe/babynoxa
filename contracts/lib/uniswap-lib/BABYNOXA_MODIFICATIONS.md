# BabyNoxa modifications

Modified on 2026-07-18.

The vendored source remains Uniswap Solidity library v1.1.1. BabyNoxa applies two compatibility-only changes:

- `AddressStringUtil` and `SafeERC20Namer` use `bytes1` instead of the removed `byte` alias, and address conversion passes through `uint160`. This preserves the same values while compiling under both the package's Solidity 0.6.6 toolchain and BabyNoxa's Solidity 0.8.x editor/build tooling.
- The TypeScript test target is ES2015 instead of deprecated ES5. This changes no Solidity runtime code.

Both modified Solidity libraries are compile-checked with Solidity 0.6.6 and Solidity 0.8.27.
