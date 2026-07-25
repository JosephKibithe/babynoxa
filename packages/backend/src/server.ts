import { createServer, type IncomingHttpHeaders } from "node:http";
import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { MetadataService, MemoryStorageAdapter } from "@babynoxa/metadata-service";
import {
  createPublicClient,
  decodeEventLog,
  defineChain,
  http,
  parseAbi,
  type Address,
} from "viem";
import { BackendApi } from "./api.js";
import { canonicalEventAbis } from "./abis.js";
import { loadConfig } from "./config.js";
import { BackendDatabase } from "./database.js";
import { EventIndexer, type ChainEvent, type ContractStateReader } from "./indexer.js";

const rpcUrl = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const host = process.env.HOST ?? "127.0.0.1";
const port = Number(process.env.PORT ?? "3000");
const databasePath = process.env.DATABASE_PATH ?? resolve("tmp/local.sqlite");
mkdirSync(dirname(databasePath), { recursive: true });

const config = loadConfig({
  ...process.env,
  CHAIN_ID: process.env.CHAIN_ID ?? "31337",
  DEPLOYMENT_BLOCK: process.env.DEPLOYMENT_BLOCK ?? "0",
  FACTORY_ADDRESS: process.env.FACTORY_ADDRESS ?? "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
  DATABASE_PATH: databasePath,
  ADMIN_TOKEN: process.env.ADMIN_TOKEN ?? "local-admin-token-only",
  CONFIRMATIONS: process.env.CONFIRMATIONS ?? "0",
});

if (!Number.isInteger(port) || port < 1 || port > 65_535) throw new Error("PORT must be a valid TCP port");

const chain = defineChain({
  id: config.chainId,
  name: config.chainId === 31_337 ? "Anvil" : `Chain ${config.chainId}`,
  nativeCurrency: { name: "Native", symbol: config.chainId === 31_337 ? "ETH" : "NATIVE", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});
const client = createPublicClient({ chain, transport: http(rpcUrl) });
const eventAbi = parseAbi(canonicalEventAbis);
const factoryReadAbi = parseAbi([
  "function getLaunch(uint256 launchId) view returns ((uint256 launchId,address creator,address token,address curve,address officialPair,address treasury,address graduationManager,bytes32 metadataHash,string metadataURI) record)",
]);
const curveReadAbi = parseAbi([
  "function state() view returns (uint8)",
  "function curveTokenInventory() view returns (uint256)",
  "function realBaseReserve() view returns (uint256)",
]);
const lifecycle = ["created", "trading", "graduation-ready", "graduated"] as const;

const stateReader: ContractStateReader = {
  async readLaunchState(_chainId, launchId) {
    const record = await client.readContract({
      address: config.factoryAddress,
      abi: factoryReadAbi,
      functionName: "getLaunch",
      args: [launchId],
    });
    const [state, curveInventory, realReserve, blockNumber] = await Promise.all([
      client.readContract({ address: record.curve, abi: curveReadAbi, functionName: "state" }),
      client.readContract({ address: record.curve, abi: curveReadAbi, functionName: "curveTokenInventory" }),
      client.readContract({ address: record.curve, abi: curveReadAbi, functionName: "realBaseReserve" }),
      client.getBlockNumber(),
    ]);
    const current = lifecycle[Number(state)];
    if (!current) throw new Error(`Unknown launch state ${state}`);
    return { lifecycle: current, curveInventory, realReserve, blockNumber };
  },
};

const db = new BackendDatabase(config.databasePath);
db.migrate();
const indexer = new EventIndexer(db, stateReader, config.wrappedNative);
// Reproject already-persisted chain events on boot so indexer/projection logic changes (e.g. trade
// matching) take effect without waiting for the next live event, and without a full re-sync.
if ((db.sqlite.prepare("SELECT COUNT(*) c FROM chain_events WHERE chain_id=?").get(config.chainId) as { c: number }).c > 0) {
  await indexer.rebuild(config.chainId);
}
const metadata = new MetadataService(new MemoryStorageAdapter());
const api = new BackendApi(db, config, metadata);
let nextBlock = indexer.resumeBlock(config.chainId, config.deploymentBlock);
let syncing = false;
const MAX_BLOCK_RANGE = 2_000n;
const MAX_ADDRESSES_PER_QUERY = 50;

const argumentText = (value: unknown): string => {
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return value;
  return String(value ?? "");
};

async function syncChain(): Promise<void> {
  if (syncing) return;
  syncing = true;
  try {
    const head = await client.getBlockNumber();
    const confirmedHead = head - BigInt(config.confirmations);
    if (confirmedHead < nextBlock) return;
    while (nextBlock <= confirmedHead) {
      const rangeEnd = nextBlock + MAX_BLOCK_RANGE - 1n < confirmedHead
        ? nextBlock + MAX_BLOCK_RANGE - 1n
        : confirmedHead;
      await syncRange(nextBlock, rangeEnd);
      nextBlock = rangeEnd + 1n;
    }
  } finally {
    syncing = false;
  }
}

async function syncRange(fromBlock: bigint, toBlock: bigint): Promise<void> {
    const factoryLogs = await client.getLogs({
      address: config.factoryAddress,
      fromBlock,
      toBlock,
    });
    const rows = db.sqlite.prepare(
      "SELECT token,curve,official_pair,manager FROM projects WHERE chain_id=?",
    ).all(config.chainId) as Array<{ token?: string; curve?: string; official_pair?: string; manager?: string }>;
    const tracked = new Map<string, Address>();
    const track = (value: unknown) => {
      if (typeof value !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(value)) return;
      if (value.toLowerCase() === config.factoryAddress.toLowerCase()) return;
      tracked.set(value.toLowerCase(), value as Address);
    };
    for (const row of rows) {
      track(row.token);
      track(row.curve);
      track(row.official_pair);
      track(row.manager);
    }
    for (const log of factoryLogs) {
      try {
        const decoded = decodeEventLog({ abi: eventAbi, data: log.data, topics: log.topics, strict: false });
        if (decoded.eventName !== "LaunchCreated") continue;
        const args = (decoded.args ?? {}) as Record<string, unknown>;
        track(args.token);
        track(args.curve);
        track(args.officialPair);
        track(args.graduationManager);
      } catch {
        // Ignore factory logs outside the canonical event boundary.
      }
    }
    const trackedAddresses = [...tracked.values()];
    const childLogs: typeof factoryLogs = [];
    for (let start = 0; start < trackedAddresses.length; start += MAX_ADDRESSES_PER_QUERY) {
      const address = trackedAddresses.slice(start, start + MAX_ADDRESSES_PER_QUERY);
      childLogs.push(...await client.getLogs({ address, fromBlock, toBlock }));
    }
    const logs = [...factoryLogs, ...childLogs];
    const blocks = new Map<bigint, Awaited<ReturnType<typeof client.getBlock>>>();
    const events: ChainEvent[] = [];
    for (const log of logs) {
      if (log.blockNumber === null || log.blockHash === null || log.transactionHash === null || log.logIndex === null) continue;
      let decoded: ReturnType<typeof decodeEventLog>;
      try {
        decoded = decodeEventLog({ abi: eventAbi, data: log.data, topics: log.topics, strict: false });
      } catch {
        continue;
      }
      let block = blocks.get(log.blockNumber);
      if (!block) {
        block = await client.getBlock({ blockNumber: log.blockNumber });
        blocks.set(log.blockNumber, block);
      }
      const args = Object.fromEntries(
        Object.entries((decoded.args ?? {}) as Record<string, unknown>).map(([key, value]) => [key, argumentText(value)]),
      );
      events.push({
        chainId: config.chainId,
        transactionHash: log.transactionHash,
        logIndex: log.logIndex,
        blockNumber: Number(log.blockNumber),
        blockHash: log.blockHash,
        parentHash: block.parentHash,
        confirmed: true,
        eventName: decoded.eventName,
        address: log.address,
        args,
        timestamp: Number(block.timestamp),
      });
    }
    if (events.length > 0) await indexer.ingest(events);
    let checkpointBlock = blocks.get(toBlock);
    if (!checkpointBlock) checkpointBlock = await client.getBlock({ blockNumber: toBlock });
    if (checkpointBlock.hash === null) throw new Error(`Confirmed block ${toBlock} has no hash`);
    indexer.checkpoint(
      config.chainId,
      Number(toBlock),
      checkpointBlock.hash,
      checkpointBlock.parentHash,
      true,
    );
}

const copyHeaders = (headers: IncomingHttpHeaders): Headers => {
  const copied = new Headers();
  for (const [name, value] of Object.entries(headers)) {
    if (Array.isArray(value)) value.forEach((item) => copied.append(name, item));
    else if (value !== undefined) copied.set(name, value);
  }
  return copied;
};

const server = createServer(async (request, response) => {
  response.setHeader("access-control-allow-origin", "*");
  response.setHeader("access-control-allow-headers", "content-type, authorization, ngrok-skip-browser-warning");
  response.setHeader("access-control-allow-methods", "GET, POST, OPTIONS");
  if (request.method === "OPTIONS") {
    response.writeHead(204).end();
    return;
  }
  try {
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const chunk of request) {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += bytes.length;
      if (size > 2_000_000) throw new Error("request body exceeds 2 MB");
      chunks.push(bytes);
    }
    const method = request.method ?? "GET";
    const body = chunks.length > 0 ? Buffer.concat(chunks).toString("utf8") : undefined;
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? `${host}:${port}`}`);
    const backendResponse = await api.handle(new Request(url, {
      method,
      headers: copyHeaders(request.headers),
      ...(method === "GET" || method === "HEAD" || body === undefined ? {} : { body }),
    }));
    response.statusCode = backendResponse.status;
    backendResponse.headers.forEach((value, name) => response.setHeader(name, value));
    response.end(Buffer.from(await backendResponse.arrayBuffer()));
  } catch (error) {
    response.statusCode = error instanceof Error && error.message.includes("2 MB") ? 413 : 500;
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ error: error instanceof Error ? error.message : String(error) }));
  }
});

await syncChain();
const interval = setInterval(() => void syncChain().catch((error) => console.error("Indexer sync failed", error)), 1_000);
server.listen(port, host, () => {
  console.log(`BabyNoxa backend listening at http://${host}:${port}`);
  console.log(`RPC ${rpcUrl}; factory ${config.factoryAddress}; database ${config.databasePath}`);
});

const stop = () => {
  clearInterval(interval);
  server.close(() => {
    db.close();
    process.exit(0);
  });
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
