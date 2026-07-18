# Phase 9 static-analysis and manual-review record

Reviewed: 2026-07-18

Scope: production contracts under `contracts/src`, including the dedicated guarded V2 implementation. The command used was:

```sh
cd contracts
slither . --filter-paths 'lib|test|script'
```

Slither completed analysis of 67 contracts and reported 84 detector results. No critical or high-severity issue remained after triage. The actionable low/informational findings were addressed by explicitly initializing the non-final-buy refund, rejecting zero-address launch-deployer and guarded-router dependencies, and removing a redundant factory expression.

## Accepted findings

- `arbitrary-send-eth` and low-level ETH calls: intentional beneficiary-owned pull claims. Ownership is fixed before the call, liabilities are cleared with checks-effects-interactions, every claim path is reentrancy guarded, zero recipients are rejected, and failed sends revert without destroying the liability.
- Pair/router reentrancy findings: inherited Uniswap V2 ordering. Every pair state-changing external entry point uses the V2 `lock` mutex. Router balance-delta checks are standard support for fee-on-transfer tokens and the router holds no protocol custody.
- Factory/curve reentrancy findings: `createLaunch`, launch, trading, graduation, and claim entry points use reentrancy guards. Factory callback and malicious claim-recipient tests exercise these boundaries. Graduation is atomic and a failing manager rolls the final buy back.
- Strict equality in guarded bootstrap: required security policy. The first mint must start from empty reserves, clear donations, reject transfer-tax/rebasing bootstrap assets, and mint exactly once.
- Weak PRNG/timestamp: the pair timestamp is the standard V2 cumulative-price clock with intentional `uint32` wraparound; it is not randomness. Trading deadlines intentionally compare against `block.timestamp`.
- Unchecked/unused return values: tuple members are intentionally ignored. The router's V2 LP `transferFrom` behavior is pinned upstream behavior; official first liquidity bypasses this path and uses `bootstrapMint`.
- Calls in loops: standard bounded-by-calldata V2 multi-hop routing. A caller pays for and controls path length; no privileged state or protocol batch loop depends on it.
- Old Solidity versions, assembly, low-level token calls, naming, and complexity: the guarded pair/router are pinned V2-compatible Solidity 0.5.16/0.6.6 code. CREATE2 and permissive ERC-20 return-data handling are required for V2 compatibility. Uppercase ABI names preserve V2 interfaces.
- `constable-states`: `feeTo` and `feeToSetter` intentionally retain the V2 factory ABI while having no setters, permanently disabling protocol LP fees.
- Missing inheritance on `TestWrappedNative`: test-only mock, excluded from production deployment.

## Manual-review focus and evidence

- Supply and custody: multi-launch invariant accounts for every token across curves, actors, managers, pairs, burn address, factory, and deployer.
- ETH solvency: invariant reconciles reserves, fees, refunds, sell credits, withdrawals, graduation allocation, and forced ETH independently.
- Authority and immutability: invariant rotates defaults while proving existing launch manager, treasury, creator, pair, and metadata snapshots remain unchanged.
- Graduation: invariant proves at-most-once execution, permanent curve closure, zero treasury LP, all usable LP at the burn address, token burn accounting, and pool price continuity.
- Adversarial behavior: invalid allowance/balance sells, rejecting and reentrant recipients, unsolicited token donations, forced ETH, manager failure, and rounding-only round trips are exercised.

## Remaining external gates

- A fork test requires the Phase 10 public-network address configuration; Amoy factory/router/wrapped-native addresses are intentionally unset.
- An independent security reviewer must perform and sign off the separate manual review before testnet. This document is the implementation-author review and is not independent sign-off or a professional audit.
