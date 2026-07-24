# BabyNoxa frontend

React/Vite interface for the complete BabyNoxa lifecycle:

- discovery and verified launch detail pages;
- metadata preparation and atomic factory launch with an optional capped buy;
- curve quotes, approvals, buys, sells, refunds, credits, and authorized fee claims;
- automatic guarded-V2 trading mode after graduation;
- indexed charts and portfolio balances.

The public navigation never exposes the moderation dashboard. The `/admin` route is
also disabled by default; an isolated internal build may opt in with
`VITE_ENABLE_ADMIN_DASHBOARD=true`. Backend authentication remains mandatory and is
the security boundary regardless of frontend configuration.

The Anvil deployment is built in. Polygon Amoy or Polygon mainnet is accepted only
when all four corresponding deployment addresses are supplied through `.env`;
partial configurations are intentionally ignored. When mainnet is configured it is
the preferred wallet-switch target. Copy `.env.example` to `.env.local` for local use.

```sh
npm run dev --workspace @babynoxa/frontend
npm test --workspace @babynoxa/frontend
npm run test:e2e --workspace @babynoxa/frontend
npm run build --workspace @babynoxa/frontend
```

Append `?demo=1` to any route for the deterministic no-funds browser test transport.
It uses the same screens, quote engine, and transaction-state UI as the wallet path.
