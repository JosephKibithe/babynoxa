# Dependency and license review

Reviewed for the Phase 14 pre-audit candidate on 2026-07-19.

## Solidity dependencies

| Dependency | Vendored version | License | Use |
|---|---:|---|---|
| OpenZeppelin Contracts | 5.4.0 | MIT | ERC-20, ownership, reentrancy, safe transfer, math |
| Uniswap V2 core | 1.0.1 | GPL-3.0-or-later | Pair/reference AMM core |
| Uniswap V2 periphery | 1.1.0-beta.0 | GPL-3.0-or-later | Router/reference periphery |
| Uniswap lib | 1.1.1 | GPL-3.0-or-later | V2 arithmetic helpers |
| forge-std | 1.16.2 | Apache-2.0 OR MIT | Tests and deployment scripts only |

The V2 periphery fixture contains the repository-documented pair-hash modification;
the guarded V2 contracts are modified/derived works. Distribution must retain source,
license notices, modification notices, and GPL obligations. This is an engineering
inventory, not a legal opinion; qualified counsel must confirm the distribution plan.

## JavaScript dependencies

Production packages are React/React DOM 19.2.7, viem 2.55.4, and sharp 0.34.5.
Release tooling includes Vite 7.3.6, Vitest 3.2.7, Playwright 1.61.1, TypeScript
5.9.3, and testing libraries recorded exactly in package manifests and
`package-lock.json`. React, viem, and Vite are MIT; Sharp and Playwright are
Apache-2.0; TypeScript is Apache-2.0. Transitive license notices must be generated
from the final lockfile before distribution.

`npm audit` reported zero known vulnerabilities across 269 dependencies on the
review date. That result is time-bound and CI repeats the audit; it is not a guarantee
that dependencies are vulnerability-free.
