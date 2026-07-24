# BabyNoxa backend

Phase 12 provides a framework-neutral backend core built around Node's SQLite API.
The host process supplies a `MetadataService` and a chain `ContractStateReader`, then
adapts incoming HTTP requests to `BackendApi.handle`.

## Trust model

- Raw logs are uniquely identified by `(chain_id, transaction_hash, log_index)`.
- Block hashes and confirmation flags are retained in `chain_events` and
  `indexer_checkpoints`.
- A conflicting block hash rewinds that block and every descendant before replay.
- Every replay reconstructs derived tables from ordered raw logs.
- Lifecycle, curve inventory, and real reserve are refreshed from contract reads
  after replay; the database is never authoritative for economic state.
- The API has no mint, reserve withdrawal, fee reassignment, or graduation mutation
  route. Those actions remain exclusively within the contracts.

## API surface

- `GET /health`, `GET /ready`
- `POST /metadata/prepare`
- `GET /launches`, `GET /launches/:id`, `GET /launches/:id/chart`
- `GET /creators/:address`, `GET /trending`
- `GET|POST /launches/:id/comments`
- `POST /admin/comments/:id/moderate`

Run `npm run typecheck` and `npm test` from the repository root.

## Local Anvil runtime

After deploying the deterministic local stack, start the HTTP adapter and live
event indexer with:

```sh
npm run dev --workspace @babynoxa/backend
```

It defaults to Anvil at `http://127.0.0.1:8545`, the deterministic local factory,
port `3000`, zero confirmations, and an ignored SQLite file under `tmp/`. Override
`RPC_URL`, `FACTORY_ADDRESS`, `DEPLOYMENT_BLOCK`, `DATABASE_PATH`, `ADMIN_TOKEN`,
`HOST`, or `PORT` as needed. These defaults are development-only.
