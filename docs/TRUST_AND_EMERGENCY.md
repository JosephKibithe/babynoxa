# Trust assumptions, authority, and emergency behavior

## Onchain authority

The factory owner can change the default treasury and active graduation manager for
**future launches only**, transfer ownership through the two-step flow, or renounce
ownership. Each launch snapshots its creator, treasury, manager, curve, token, and
official pair. Existing launches cannot be redirected to a new treasury or manager.

The creator can make the optional capped launch purchase, trade normally afterward,
and claim its own curve-fee share. The treasury can claim its own curve-fee share and
graduation allocation. Neither receives LP. Traders control their tokens, sell
credits, and refunds through pull claims.

There is no proxy upgrade, mint authority, confiscation, blacklist, transfer tax,
owner trading pause, reserve sweep, fee seizure, administrator graduation override,
LP recovery, or keeper reimbursement.

## Offchain authority

Backend administrators can hide or restore comments and create an audit record.
They cannot modify contract balances, lifecycle, supply, fees, metadata commitments,
or indexed chain history. Operators control API availability, RPC selection,
indexer confirmations, and presentation; these are availability/integrity trust
assumptions, not economic authority.

## Emergency response

Contracts deliberately have no emergency pause. During a suspected incident:

1. Stop new frontend transaction prompts and metadata preparation.
2. Keep a static incident page and publish affected chains, contracts, and blocks.
3. Preserve database, RPC, application, and deployment logs; take no destructive action.
4. Independently compare bytecode, configuration, balances, liabilities, and events.
5. Users may still interact directly with immutable contracts, including owned claims.
6. Do not promise reversal, rescue, migration, compensation, or recovery before legal
   and security review; the contracts provide no privileged mechanism for those acts.
7. Resume UI/API operation only after a written root cause, impact boundary, and
   approval from security and release owners.

Before any public launch, a mistaken deployment can be abandoned and replaced only
if no users were invited and no value was accepted. Never reuse a compromised key or
misconfigured address. After users participate, deploy-and-forget is not a rollback.

## Operational key assumptions

- Deployment, factory-owner, and treasury keys must be distinct production roles.
- Hardware-backed multisig control is required for owner and treasury roles.
- No seed phrase, private key, keystore, admin token, or RPC credential belongs in git.
- Signers, quorum, recovery, rotation, and loss procedures must be recorded privately
  and tested before Amoy; this repository intentionally contains no secrets.
