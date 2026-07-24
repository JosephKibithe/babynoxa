# Public contract API and NatSpec companion

The project-owned Solidity source uses `@title`, `@notice`, `@dev`, `@param`,
`@return`, and `@inheritdoc` on the core API. Inherited OpenZeppelin ERC-20 and
ownership APIs and the V2-compatible router/pair APIs retain their upstream NatSpec.
This companion states the public semantics that must be published with explorer ABIs.

## BabyNoxaFactory

`createLaunch` atomically validates immutable metadata inputs, deploys and funds the
fixed-supply token and curve, creates the guarded official pair, snapshots treasury
and manager, executes the optional capped creator buy, and opens trading. Registry
getters are views only. `setDefaultTreasury` and `setActiveGraduationManager` affect
future snapshots only. Ownership uses OpenZeppelin two-step transfer.

`MetadataCommitted` and `LaunchCreated` are canonical indexer events;
`DefaultTreasuryUpdated` and `GraduationManagerActivated` report future-default
changes. Factory errors identify invalid addresses/configuration, metadata inputs,
duplicate commitments, missing manager, failed token/base handoff, or invalid pair.

## BabyNoxaToken and BabyNoxaLaunchDeployer

The token constructor mints exactly one billion 18-decimal units once to the supplied
recipient. Standard ERC-20 transfers/allowances and caller-owned `burn` are the only
balance mutations. The deployer is factory-bound and deploys tokens/curves only for
that immutable factory; it owns no administrative lifecycle capability.

## BondingCurve

View functions expose immutable launch identities, lifecycle, virtual and real
reserves, curve/graduation inventory, fee liabilities, claims, and accounting totals.
`launch` is factory-only and one-time. `buy`/`sell` require Trading state, caller
slippage minima, deadline, minimum trade, inventory/balance, and solvency. Claims are
pull payments and beneficiary-owned; creator/treasury fee claims are role-restricted.

Canonical events report purchases, sales, separate fee accruals, graduation readiness,
refund/credit accrual, and beneficiary/recipient claims. Errors distinguish state,
authorization, deadline, cap, balance, slippage, reserve, token-transfer, claim,
graduation, and accounting failures.

## GraduationManagerV1

Immutable getters expose factory, V2 factory, router, wrapped native asset, and burn
address. `graduate` accepts only a registered ready curve with matching snapshot,
recomputes allocations, validates the empty guarded pair, burns unsolicited and unused
assets under policy, bootstraps exact price-matched liquidity, and sends all usable LP
to the dead address. Events report graduation, liquidity, LP burn, token burn, and
unsolicited-asset handling; errors identify caller/configuration/value/pair/price,
transfer, deadline, residue, and invariant failures.

## Guarded V2 stack

The factory creates official pairs only for the immutable launch factory and keeps
protocol fee roles at zero. Each pair blocks mint/burn/swap/skim/sync until its
snapshotted manager performs the one-time guarded bootstrap, clears donations, mints
minimum liquidity to zero and usable LP to the dead address, then permanently erases
bootstrap authority. The router is V2-compatible and uses this factory's canonical
pair lookup. Upstream-compatible function/event/error semantics remain subject to the
vendored GPL source and modification notices.
