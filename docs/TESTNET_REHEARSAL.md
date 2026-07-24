# Polygon Amoy monitored rehearsal

**Status: not run.** Fill every field with durable evidence; do not replace evidence
with screenshots alone.

## Deployment record

- Candidate manifest/hash:
- Git commit (clean, signed/tagged):
- Chain ID: `80002`
- RPC providers used (at least two):
- Deployment UTC start/end:
- Deployer / owner / treasury addresses:
- Deployment block and transaction hashes:
- Factory / manager / guarded factory / router / wrapped-native addresses:
- Explorer source-verification URLs:
- CI run containing the active Amoy fork test:

## Monitored lifecycle

- [ ] Validate every configured address has expected bytecode hash and wiring.
- [ ] Create launch without creator buy; confirm public trading only after atomic completion.
- [ ] Create launch with creator buy; verify the 20M output cap.
- [ ] Exercise buy, approval, sell, refund, credit, creator fee, and treasury fee claims.
- [ ] Complete a curve and verify atomic graduation, price tolerance, burn amounts,
      zero creator/treasury LP, and usable LP at the dead address.
- [ ] Trade both directions through the unlocked guarded V2 router.
- [ ] Stop/restart/rebuild the indexer and compare all derived state.
- [ ] Simulate RPC failure, stale quotes, transaction rejection/replacement, backend
      restart, moderation, and metadata outage.
- [ ] Observe at least 24 hours for indexer lag, reorg handling, RPC disagreement,
      unexpected balances, errors, and resource use.

## Sign-off

Record every anomaly, severity, owner, fix commit, rerun, and residual risk. Security,
engineering, operations, and product owners must sign. Successful rehearsal does not
authorize mainnet or real-value use.
