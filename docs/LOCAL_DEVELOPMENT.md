# Local Development

This guide covers the two practical ways to run BabyNoxa on your machine:

1. A fully local stack on Anvil.
2. A local frontend and backend pointed at the live Polygon mainnet test deployment.

The local Anvil path is the safest place to develop contract or UI changes. The Polygon path is useful when you want to exercise the current QuickSwap-graduation deployment from your own browser and local indexer.

## Prerequisites

- Node.js and npm
- Foundry (`forge`, `cast`, `anvil`)
- Repository dependencies installed with:

```sh
npm install
```

## Option 1: Fully local on Anvil

This runs the contracts, backend, and frontend entirely on your machine.

### 1. Start Anvil

From any terminal:

```sh
anvil --chain-id 31337
```

Leave this running.

### 2. Deploy the local BabyNoxa stack

In a second terminal:

```sh
cd contracts
export PRIVATE_KEY=<anvil-development-key>
forge script script/DeployBabyNoxa.s.sol:DeployBabyNoxa \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --slow \
  --gas-estimate-multiplier 200
```

Optional smoke test:

```sh
forge script script/SmokeBabyNoxa.s.sol:SmokeBabyNoxa \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --slow \
  --gas-estimate-multiplier 200
```

The deployment writes `contracts/deployments/31337.json`. The deterministic local addresses currently match:

```json
{
  "babyNoxaFactory": "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
  "graduationManagerV1": "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
  "guardedV2Router02": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  "wrappedNative": "0x5FbDB2315678afecb367f032d93F642f64180aa3"
}
```

### 3. Start the backend

From the repo root:

```sh
npm run dev --workspace @babynoxa/backend
```

For a standard local Anvil flow, the backend defaults are already correct:

- RPC: `http://127.0.0.1:8545`
- factory: `0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9`
- port: `3000`
- confirmations: `0`

If you need to override them, set `RPC_URL`, `FACTORY_ADDRESS`, `DEPLOYMENT_BLOCK`, `DATABASE_PATH`, `ADMIN_TOKEN`, `HOST`, or `PORT`.

### 4. Create the frontend env file

Create `packages/frontend/.env.local`:

```dotenv
VITE_API_URL=http://127.0.0.1:3000
VITE_LOCAL_RPC_URL=http://127.0.0.1:8545
VITE_ENABLE_ADMIN_DASHBOARD=false
```

Do not set the Polygon Amoy or Polygon mainnet variables for a purely local run.

### 5. Start the frontend

From the repo root:

```sh
npm run dev --workspace @babynoxa/frontend
```

The Vite dev server is pinned to:

```text
http://localhost:4173/
```

### 6. Use the app

- Open `http://localhost:4173/`
- Connect an Anvil account in your wallet
- Switch to chain `31337` if your wallet does not do it automatically

You can also append `?demo=1` to any frontend route for the deterministic no-funds browser transport.

## Option 2: Local app against the live Polygon QuickSwap test deployment

Use this when you want the frontend and backend running locally while pointing at the current mainnet test deployment.

## Important warning

This path uses a real Polygon mainnet deployment and is still an unaudited mainnet test. Real POL is involved if you transact.

### Current Polygon mainnet QuickSwap test addresses

These addresses come from `contracts/deployments/137-quickswap.json`:

```text
Factory:  0x96C718AdF387B04284A3a526aC0228d9ffD6d5f6
Manager:  0x620969f2783629174d1Fdfb1602F656B381fc97b
Router:   0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff
WPOL:     0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
Block:    90683404
```

### 1. Start the backend indexer

Use one of these two equivalent commands.

From the repo root:

```sh
PORT=3001 \
HOST=127.0.0.1 \
RPC_URL=https://polygon.gateway.tenderly.co \
CHAIN_ID=137 \
CONFIRMATIONS=2 \
FACTORY_ADDRESS=0x96C718AdF387B04284A3a526aC0228d9ffD6d5f6 \
DEPLOYMENT_BLOCK=90683404 \
DATABASE_PATH=/absolute/path/to/babynoxa/tmp/mainnet-quickswap.sqlite \
ADMIN_TOKEN=local-admin-token-only \
WRAPPED_NATIVE=0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270 \
npm run dev --workspace @babynoxa/backend
```

Or from `packages/backend`:

```sh
cd packages/backend
PORT=3001 \
HOST=127.0.0.1 \
RPC_URL=https://polygon.gateway.tenderly.co \
CHAIN_ID=137 \
CONFIRMATIONS=2 \
FACTORY_ADDRESS=0x96C718AdF387B04284A3a526aC0228d9ffD6d5f6 \
DEPLOYMENT_BLOCK=90683404 \
DATABASE_PATH=/absolute/path/to/babynoxa/tmp/mainnet-quickswap.sqlite \
ADMIN_TOKEN=local-admin-token-only \
WRAPPED_NATIVE=0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270 \
npm run dev
```

Notes:

- The backend uses port `3001` here so it does not collide with the default local-Anvil backend.
- `https://polygon.gateway.tenderly.co` was the public RPC that successfully served the ranged `eth_getLogs` calls needed by the indexer during setup.
- A dedicated paid RPC is a better long-term choice for sustained mainnet use.
- `WRAPPED_NATIVE` must be set for the Polygon deployment so post-graduation QuickSwap swaps are classified correctly as buys or sells in the live indexer.

### 2. Create the frontend env file

Create `packages/frontend/.env.local`:

```dotenv
VITE_API_URL=http://127.0.0.1:3001
VITE_ENABLE_ADMIN_DASHBOARD=false

VITE_POLYGON_MAINNET_RPC_URL=https://polygon.drpc.org
VITE_POLYGON_MAINNET_FACTORY=0x96C718AdF387B04284A3a526aC0228d9ffD6d5f6
VITE_POLYGON_MAINNET_MANAGER=0x620969f2783629174d1Fdfb1602F656B381fc97b
VITE_POLYGON_MAINNET_ROUTER=0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff
VITE_POLYGON_MAINNET_WRAPPED_NATIVE=0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270
```

### 3. Start the frontend

From the repo root:

```sh
npm run dev --workspace @babynoxa/frontend
```

Open:

```text
http://localhost:4173/
```

### 4. Connect your wallet

- Switch your wallet to Polygon mainnet (`137`)
- Use funded test wallets carefully
- New launches created through this factory graduate onto canonical QuickSwap V2

## Quick verification checklist

After starting the stack, these checks should pass:

### Local Anvil mode

- backend health: `curl http://127.0.0.1:3000/health`
- launch list: `curl http://127.0.0.1:3000/launches`
- frontend: open `http://localhost:4173/`

### Polygon mainnet test mode

- backend ready: `curl http://127.0.0.1:3001/ready`
- launch list: `curl http://127.0.0.1:3001/launches`
- frontend: open `http://localhost:4173/`

## Common issues

### Unsupported network

If the frontend says the network is unsupported:

- local mode: make sure your wallet is on Anvil `31337`
- Polygon mode: make sure all four Polygon mainnet env vars are set

### Frontend cannot load backend data

Check that `VITE_API_URL` matches the backend port:

- local Anvil backend: `3000`
- Polygon mainnet test backend: `3001`

### Polygon indexer RPC errors

If the backend fails on historical `eth_getLogs`, switch to an RPC that supports ranged log queries. During the current setup, some free public Polygon RPCs rejected these requests even though normal `eth_call` and `eth_blockNumber` worked.
