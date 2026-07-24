# Phase 14 release readiness

## Current decision

**NOT APPROVED FOR PRODUCTION OR REAL VALUE.** The repository is a reproducible
pre-audit candidate. Local engineering gates are prepared, but the professional
contract audit, audit retest, qualified legal/privacy review, Polygon Amoy
deployment rehearsal, public source verification, and explicit production decision
have not occurred.

## Mainnet graduation venue change (post-candidate)

The Polygon mainnet deployment now graduates launches onto the canonical **QuickSwap
V2** AMM (via `BabyNoxaFactoryQS` + `GraduationManagerV2`) instead of the guarded
`GuardedV2*` stack, so graduated tokens are discoverable on QuickSwap/DexScreener and
tradeable through QuickSwap's router. Local/Amoy paths are unchanged and still use the
guarded stack. This is a **new candidate**: it adds contract source and changes the
mainnet deployment topology, so it invalidates prior audit evidence and must be frozen,
re-reviewed, and re-audited before any production decision. The security tradeoff (a
permissionless pair's first-liquidity seed can be griefed to brick a single launch's
graduation) is documented in `docs/PHASE_10_DEPLOYMENT.md`. Coverage:
`test/integration/QuickSwapGraduation.t.sol` and
`test/fork/PolygonQuickSwapGraduationFork.t.sol`.

## Frozen candidate

`release/candidate-v1.json` records the economic constants, exact compilers,
optimizer/EVM settings, source-tree digest, lockfile digest, and deployed-bytecode
hashes. A change to any contract source, compiler, optimizer setting, deployment
input, or vendored dependency creates a new candidate and invalidates prior audit
evidence.

The recorded base commit identifies the repository ancestry. Because Phases 12–14
are currently uncommitted workspace changes, the source-tree digest—not the base
commit alone—is the candidate identity. A release manager must commit the reviewed
tree and replace this statement with the final commit before an audit begins.

## Automated gates

`.github/workflows/ci.yml` runs immutable-SHA-pinned actions and covers:

- npm clean install, advisory audit, strict type checks, unit/component/integration tests;
- production frontend build and desktop/mobile browser flows;
- Solidity formatting and exact-compiler build;
- unit, ABI, analysis, integration, high-depth fuzz, invariant, and adversarial tests;
- a mandatory Amoy fork-wiring test using repository secrets/variables;
- pinned Slither static analysis against the accepted-finding baseline documented in
  `docs/PHASE_9_SECURITY_REVIEW.md`; any unrecognized detector fails CI.

Local runs leave the Amoy fork test inert when deployment values are absent. CI sets
`AMOY_FORK_REQUIRED=true`, so its public-deployment job fails until all six values
are configured; CI cannot turn green by silently skipping this gate.

## Required release evidence

| Gate | Evidence required | Status |
|---|---|---|
| Reproducible candidate | Candidate JSON and clean CI | Prepared locally |
| NatSpec/API publication | `docs/CONTRACT_NATSPEC.md` plus verified explorer source | Local docs prepared; explorer pending |
| Contract audit | Named independent firm report with commit/hash scope | Pending |
| Audit retest | Closure or accepted-risk record for every finding | Pending |
| Application security | Internal review plus external deployment/penetration review | Internal review complete; external review pending |
| Legal/privacy/moderation | Written qualified review for launch jurisdictions and age model | Pending |
| Amoy rehearsal | Completed `docs/TESTNET_REHEARSAL.md` with tx links and monitoring results | Pending |
| Public artifacts | Completed Amoy publication JSON, ABIs, source, blocks, policy | Pending |
| Production decision | Signed `docs/PRODUCTION_APPROVAL.md` with all approvers | Pending |

No missing external gate may be converted into a checkbox by a developer, automated
agent, successful local test, or successful testnet transaction.

## Local verification record — 2026-07-19

- `npm audit --audit-level=high`: no known vulnerabilities reported.
- `npm run typecheck`: all four workspace packages passed strict checks.
- `npm test`: 31 backend, frontend, metadata, and shared-package tests passed.
- Frontend production build: passed; Vite reported only its advisory chunk-size warning.
- Playwright: 8 desktop/mobile lifecycle and moderation flows passed.
- `forge fmt --check`, exact-compiler build, and the complete Foundry suite: passed.
- Phase 9 profile: 256 invariant runs at depth 1,000 and the dedicated adversarial
  regression suite passed.
- Slither 0.11.3: passed after applying the documented, reviewed detector baseline;
  the unfiltered report remains recorded in `docs/PHASE_9_SECURITY_REVIEW.md`.
- `npm run candidate:verify`: source, lockfile, constants, and all eight deployed
  bytecode hashes matched `release/candidate-v1.json`.
- The Amoy fork harness compiled and passed in its local unconfigured mode. This is
  not an Amoy result; CI requires configuration and the public rehearsal is pending.

## Polygon mainnet no-spend fork reconnaissance — 2026-07-21

- Added `contracts/test/fork/PolygonMainnetRehearsal.t.sol`. The test is inert unless
  `POLYGON_MAINNET_RPC_URL` is configured and never broadcasts a transaction.
- A required fork run passed against Polygon PoS chain `137` at block `90634688`.
  It verified canonical WPOL at `0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270`,
  deployed the frozen guarded BabyNoxa stack inside the fork, created a launch,
  completed the current curve, graduated into burned guarded-V2 liquidity, and
  executed a post-graduation native-POL swap.
- The fork also verified QuickSwap Router02 wiring to its documented factory and
  WPOL, then confirmed that the standard permissionless factory is rejected by
  BabyNoxa's guarded-bootstrap constructor boundary. QuickSwap remains suitable
  only as an optional secondary venue after graduation, not as the official first
  liquidity venue.
- The current V1 geometry requires `4.274999994656250007 POL` net or approximately
  `4.318181813 POL` gross to complete the curve. A `3 POL` trading budget cannot
  graduate this candidate.
- At the sampled mainnet gas price of `284660983542` wei, the measured stack
  deployment gas of approximately `17.74 million` alone implied about `5.05 POL`,
  before launch creation, curve completion, graduation, or swaps. This observation
  is time-sensitive and is budget evidence only, not a gas-price prediction.
- `forge fmt --check`, the complete Foundry regression suite, and
  `npm run candidate:verify` passed afterward. All eight deployed-bytecode hashes
  still match the frozen pre-audit manifest.

This fork result is not an Amoy rehearsal, professional audit, production approval,
or authorization to use real value. Polygon mainnet remains blocked by every
pending external gate listed above.
