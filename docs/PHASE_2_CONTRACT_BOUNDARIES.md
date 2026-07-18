# BabyNoxa V1 production contract boundaries

Status: Phase 2 ABI and authority specification, implemented locally through Phase 8

This document defines the production-facing V1 contract boundaries now implemented by the token, curve, factory, and graduation manager. The payable simulator remains an independent economic oracle; it is not itself a production implementation.

## Deployment model

V1 uses ordinary constructor deployments initiated by `BabyNoxaFactory`. An immutable, factory-only `BabyNoxaLaunchDeployer` holds token and curve creation bytecode so the production factory stays below EIP-170. It is not a proxy, performs no delegate call, has no owner or upgrade path, and explicitly assigns the production factory as each curve's launch authority.

- No proxy or delegate-call upgrade path.
- No minimal-proxy clones.
- No `CREATE2` deployment in V1.
- No administrator can replace code used by an existing launch.
- A future implementation version is deployed as a new factory and/or graduation manager.

This choice favors explicit immutable configuration and simpler review over deterministic addresses or marginal deployment-gas savings. Launch IDs and the factory registry are the canonical discovery mechanism.

## Shared data model

`BabyNoxaTypes.sol` defines:

- `CreateLaunchParams`: creator inputs, metadata commitment, creator-buy slippage, and deadline.
- `LaunchConfig`: immutable creator, token, treasury, graduation-manager, pair, and virtual-reserve snapshot passed to a curve.
- `LaunchRecord`: factory registry record for deployed addresses and immutable metadata commitment.
- `GraduationParams`: terminal curve state and AMM execution bounds sent to the snapshotted manager.
- `GraduationResult`: exact treasury, liquidity, token-burn, and LP-burn result returned to the curve.

The curve remains the source of truth for the current `LaunchState`. The factory registry does not maintain a second mutable lifecycle state.

## Atomic launch and supply handoff

One `createLaunch` transaction performs the complete handoff:

1. Validate non-empty token name, symbol, metadata URI, nonzero metadata hash, deadline, and creator-buy value policy.
2. Allocate the next launch ID and snapshot the current treasury and active graduation manager.
3. Deploy a normal fixed-supply token whose constructor mints exactly 1,000,000,000 tokens temporarily to the factory.
4. Create the guarded official token/wrapped-native pair in bootstrap-locked mode with the snapshotted graduation manager.
5. Deploy the curve with the immutable `LaunchConfig` and token address.
6. Transfer the complete token supply from the factory to the curve.
7. Assert that the factory token balance is zero, the curve balance is exactly 1,000,000,000 tokens, and total supply is exact.
8. Register the launch and immutable metadata commitment before opening public trading.
9. Call the curve's factory-only `launch`, forwarding the creator's optional purchase and crediting its token output to the recorded creator.

Every step occurs in the same transaction. A failure in pair creation, curve deployment, token handoff, creator purchase, or registration reverts all preceding work. The factory must never retain launch tokens after a successful transaction.

The curve internally assigns 800,000,000 tokens to trade inventory and 200,000,000 tokens to the graduation reserve. The creator receives no free allocation.

## Graduation handoff

The final buy remains atomic with graduation:

1. The curve exhausts its real trade inventory and enters `GraduationReady`.
2. The curve calculates and records the 10% graduation treasury allocation as a pull-payment liability for its snapshotted treasury.
3. The curve transfers the 200,000,000-token graduation reserve to its snapshotted graduation manager and calls `graduate` with the terminal reserve state.
4. Only the 90% liquidity-base amount is sent as `msg.value`; the manager independently recomputes the full allocation and rejects inconsistent parameters or value.
5. The manager clears and verifies the guarded pair, supplies the price-matched token amount and base amount, burns unused graduation tokens, and sends all usable LP directly to the burn address.
6. The manager returns exact results. The curve verifies them and enters `Graduated`.

If any step fails, the final buy and every graduation transfer revert. The manager never owns treasury LP or creator LP, and no keeper reimbursement is paid.

## Authority matrix

| Actor | Authorized actions | Explicit limits |
| --- | --- | --- |
| Factory | Validate launch inputs, deploy token/curve, create the guarded pair, transfer the initial supply, register the launch, and call the curve's one-time `launch` | Cannot trade for itself, retain tokens, change an existing record, withdraw curve assets, or call `launch` twice |
| Factory owner | Two-step ownership transfer; change default treasury and active manager for future launches | Changes do not affect existing treasury, manager, pair, metadata, or curve snapshots |
| Creator | Submit immutable launch metadata, fund the optional atomic creator buy, receive creator curve fees, and redirect only those fees with `claimTo` | Cannot mint, pause, blacklist, confiscate, change curve math, replace metadata, replace treasury/manager, withdraw reserves, or receive free tokens/LP |
| Trader | Buy and sell within state, balance, dust, deadline, and slippage rules; claim or redirect only their own refund and sell credit | Cannot access another account's tokens, credits, refunds, or fees |
| Snapshotted treasury | Claim or redirect its curve trading fees and graduation allocation | Receives no LP; cannot access creator fees, user claims, curve reserves, or forced ETH |
| Snapshotted graduation manager | Graduate only a registered curve that selected it at launch; initialize only its guarded official pair; add first liquidity; burn unused tokens and all usable LP | Cannot graduate twice, operate a different launch's assets, change the treasury snapshot, retain LP, or reopen curve trading |
| Metadata/backend administrator | Moderate off-chain visibility and maintain editable social records | Has no on-chain balance, supply, fee, trading, metadata-commitment, or graduation authority |

## Actions no administrator can perform

No V1 administrator selector may:

- mint or destroy another holder's tokens;
- pause token transfers or curve trading;
- add transfer taxes, blacklists, maximum wallets, or arbitrary balance mutation;
- replace an existing creator, treasury, graduation manager, official pair, metadata URI, or metadata hash;
- withdraw real curve reserves, graduation liquidity, creator fees, treasury fees belonging to another snapshot, user credits, refunds, or forced ETH;
- change curve reserves, price geometry, allocations, fee rates, dust limits, or graduation state;
- recover or redirect burned graduation tokens or LP;
- upgrade an existing launch through proxy administration.

## Treasury boundary

V1 snapshots a treasury beneficiary address per launch. The address may be an EOA, multisig, or independently reviewed controller contract. No dedicated BabyNoxa treasury-vault contract has been approved for V1, so Phase 2 intentionally defines no treasury-vault interface.

The snapshotted address calls `claimTreasuryFees` or `claimTreasuryFeesTo` on each curve. Factory ownership does not imply treasury withdrawal authority. Treasury rotation changes only the default used by future launches.

## Canonical events

The production interfaces freeze these indexer events:

| Emitter | Event | Indexed fields |
| --- | --- | --- |
| Factory | `LaunchCreated` | `launchId`, `creator`, `token` |
| Factory | `MetadataCommitted` | `launchId`, `token`, `metadataHash` |
| Curve | `TokensPurchased` | `buyer` |
| Curve | `TokensSold` | `seller` |
| Curve | `CreatorFeeAccrued` | `beneficiary`, `trader` |
| Curve | `TreasuryFeeAccrued` | `beneficiary`, `trader` |
| Curve | `GraduationReady` | `token`, `graduationManager` |
| Curve | `LaunchEtherClaimed` | `launchId`, `beneficiary`, `recipient` |
| Graduation manager | `GraduationExecuted` | `token`, `curve`, `officialPair` |
| Graduation manager | `LiquidityCreated` | `token`, `officialPair` |
| Graduation manager | `LiquidityBurned` | `token`, `officialPair`, `burnAddress` |
| Graduation manager | `GraduationTokensBurned` | `token`, `curve` |

Event history supports indexing, but current contract state remains authoritative.

## Interface ownership

- `IBabyNoxaToken`: standard ERC-20 metadata plus caller-owned burning; deliberately no administrative token controls.
- `IBondingCurve`: immutable launch configuration, trading, pull claims, solvency views, and lifecycle events.
- `IGraduationManager`: immutable deployment dependencies and registered-curve-only atomic graduation.
- `IBabyNoxaFactory`: deployment, immutable registry, metadata commitments, and future-launch-only defaults.
- `IV2Factory`, `IV2Pair`, `IV2Router02`, and `IWrappedNative`: minimal external AMM boundaries already used by the local fixture.

Changing any frozen selector, struct layout, or canonical event signature requires an explicit interface-version change and corresponding snapshot-test update.
