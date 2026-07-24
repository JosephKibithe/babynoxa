# Backend and frontend security review

## Scope and result

Internal review covered `packages/backend`, `packages/metadata-service`,
`packages/shared`, and `packages/frontend`. No unresolved critical or high-severity
issue was identified in the reviewed local design. This is not an external
penetration test and does not replace deployment-specific review.

## Controls verified

- Contract economic state is read-only from the backend and reconciled from chain reads.
- Event identity, block hashes, confirmations, rewind, and full replay are tested.
- Metadata fetching blocks private/reserved addresses, revalidates redirects, bounds
  bytes/decoded memory, sniffs types, fully decodes content, and hash-verifies storage.
- React rendering escapes user content; external links isolate opener state.
- Wallet transactions enforce chain allowlists, slippage minima, absolute deadlines,
  stale-quote expiry, and explicit transaction failure states.
- Token approvals are exact-amount, venue-specific approvals rather than unlimited grants.
- Moderation uses a constant-time bearer comparison, bounded fields, existing-comment
  checks, atomic audit logging, and no economic endpoint.
- The public frontend has no Admin navigation item, returns not-found for `/admin`,
  and tree-shakes the moderation client/dashboard from default production builds.
  An internal build requires the explicit `VITE_ENABLE_ADMIN_DASHBOARD=true` flag;
  backend authentication remains mandatory in either case.
- External font loading was removed to avoid an unnecessary third-party request.
- No production secret is present in tracked environment templates.

## Deployment controls still required

- Put the backend behind TLS, strict origin/CORS policy, request-body limits, rate
  limits, authentication middleware, structured redacted logs, and network egress rules.
- Require wallet-signed comment authorship or label comments as unverified aliases.
- Set CSP, HSTS, frame-ancestors, Referrer-Policy, Permissions-Policy, and MIME-sniffing headers.
- Separate moderation credentials from infrastructure credentials and rotate them.
- Monitor RPC disagreement, indexer lag/reorg depth, metadata failures, transaction
  reverts, authentication failures, and moderation anomalies.
- Perform an external penetration test against the actual testnet deployment and hosting stack.

These deployment controls are release blockers even though the local application tests pass.
