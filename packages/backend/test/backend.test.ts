import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { MetadataService, MemoryStorageAdapter } from "@babynoxa/metadata-service";
import { BackendApi, BackendDatabase, EventIndexer, loadConfig, type ChainEvent, type ContractStateReader } from "../src/index.js";

const zero = `0x${"0".repeat(40)}`;
const creator = `0x${"1".repeat(40)}`;
const token = `0x${"2".repeat(40)}`;
const curve = `0x${"3".repeat(40)}`;
const pair = `0x${"4".repeat(40)}`;
const hash = (value: string) => `0x${value.repeat(64).slice(0, 64)}`;
const event = (eventName: string, blockNumber: number, logIndex: number, args: Record<string,string>, overrides: Partial<ChainEvent> = {}): ChainEvent => ({ chainId: 31337, transactionHash: hash(String(blockNumber)+String(logIndex)), logIndex, blockNumber, blockHash: hash(String(blockNumber)), parentHash: hash(String(blockNumber-1)), confirmed: true, eventName, address: eventName.includes("Token") || eventName === "Transfer" ? token : curve, args, timestamp: blockNumber * 10, ...overrides });
const launchEvents = () => [
  event("MetadataCommitted", 1, 0, { launchId:"1", token, metadataHash:hash("a"), metadataURI:"memory://metadata" }),
  event("LaunchCreated", 1, 1, { launchId:"1", creator, token, curve, officialPair:pair, treasury:creator, graduationManager:pair }),
  event("Transfer", 2, 0, { from:zero, to:curve, value:"1000" }, { address:token }),
  event("TokensPurchased", 3, 1, { buyer:creator, grossBaseExecuted:"100", netBaseToCurve:"99", tokensOut:"100" }, { address:curve }),
  event("Transfer", 3, 0, { from:curve, to:creator, value:"100" }, { address:token }),
];

const reader: ContractStateReader = { async readLaunchState() { return { lifecycle:"trading", curveInventory:700n, realReserve:99n, blockNumber:3n }; } };

test("configuration validation and forward-only migrations are repeatable", () => {
  assert.throws(() => loadConfig({}), /CHAIN_ID/);
  const config = loadConfig({ CHAIN_ID:"31337", DEPLOYMENT_BLOCK:"0", FACTORY_ADDRESS:creator, DATABASE_PATH:":memory:", ADMIN_TOKEN:"a-secure-admin-token", CONFIRMATIONS:"2" });
  assert.equal(config.chainId, 31337);
  const directory = mkdtempSync(join(tmpdir(), "babynoxa-db-")); const path = join(directory,"backend.sqlite");
  const first = new BackendDatabase(path); first.migrate(); assert.equal(first.migrationVersion,2); first.close();
  const second = new BackendDatabase(path); second.migrate(); assert.equal(second.migrationVersion,2); second.close(); rmSync(directory,{recursive:true});
});

test("duplicate and out-of-order events rebuild one deterministic authoritative view", async () => {
  const db = new BackendDatabase(); db.migrate(); const indexer = new EventIndexer(db, reader);
  const events = launchEvents(); await indexer.ingest([events[4]!, events[2]!, events[0]!, events[3]!, events[1]!, events[3]!]);
  assert.equal((db.sqlite.prepare("SELECT COUNT(*) count FROM chain_events").get() as {count:number}).count,5);
  assert.equal((db.sqlite.prepare("SELECT COUNT(*) count FROM trades").get() as {count:number}).count,1);
  const project = db.sqlite.prepare("SELECT * FROM projects WHERE launch_id='1'").get() as Record<string,string>;
  assert.equal(project.metadata_hash,hash("a")); assert.equal(project.curve_inventory,"700"); assert.equal(project.real_reserve,"99");
  assert.equal((db.sqlite.prepare("SELECT balance FROM holders WHERE holder=?").get(creator) as {balance:string}).balance,"100");
  db.close();
});

test("atomic creator-buy logs emitted before factory registration are retained", async () => {
  const db = new BackendDatabase(); db.migrate(); const indexer = new EventIndexer(db, reader);
  await indexer.ingest([
    event("TokensPurchased", 1, 0, { buyer:creator, grossBaseExecuted:"100", netBaseToCurve:"99", tokensOut:"100" }, { address:curve }),
    event("Transfer", 1, 1, { from:curve, to:creator, value:"100" }, { address:token }),
    event("MetadataCommitted", 1, 2, { launchId:"1", token, metadataHash:hash("a"), metadataURI:"memory://metadata" }),
    event("LaunchCreated", 1, 3, { launchId:"1", creator, token, curve, officialPair:pair, treasury:creator, graduationManager:pair }),
  ]);
  assert.equal((db.sqlite.prepare("SELECT COUNT(*) count FROM trades").get() as {count:number}).count, 1);
  assert.equal((db.sqlite.prepare("SELECT balance FROM holders WHERE holder=?").get(creator) as {balance:string}).balance, "100");
  db.close();
});

test("empty-range checkpoints persist the next block across restarts", () => {
  const db = new BackendDatabase(); db.migrate();
  const indexer = new EventIndexer(db);
  assert.equal(indexer.resumeBlock(137, 100n), 100n);
  indexer.checkpoint(137, 125, hash("c"), hash("b"), true);
  assert.equal(indexer.resumeBlock(137, 100n), 126n);
  db.close();
});

test("reorg rewind and full deletion/rebuild converge to the same chain-derived state", async () => {
  const db = new BackendDatabase(); db.migrate(); const indexer = new EventIndexer(db, reader); await indexer.ingest(launchEvents());
  const replacement = event("TokensPurchased",3,1,{buyer:creator,grossBaseExecuted:"200",netBaseToCurve:"198",tokensOut:"150"},{address:curve,blockHash:hash("f"),parentHash:hash("2"),transactionHash:hash("e")});
  await indexer.ingest([replacement]);
  assert.equal((db.sqlite.prepare("SELECT gross_base FROM trades").get() as {gross_base:string}).gross_base,"200");
  const raw = db.sqlite.prepare("SELECT * FROM chain_events ORDER BY block_number,log_index").all();
  const snapshot = () => JSON.stringify({
    projects:db.sqlite.prepare("SELECT * FROM projects ORDER BY launch_id").all(),
    trades:db.sqlite.prepare("SELECT * FROM trades ORDER BY block_number,log_index").all(),
    holders:db.sqlite.prepare("SELECT * FROM holders ORDER BY launch_id,holder").all(),
  });
  const before = snapshot();
  await indexer.rebuild(31337);
  assert.equal(snapshot(),before); assert.ok(raw.length >= 4); db.close();
});

test("API health, lookup, search, comments, moderation audit, and read-only contract boundary", async () => {
  const db = new BackendDatabase(); db.migrate(); await new EventIndexer(db,reader).ingest(launchEvents());
  const metadata = new MetadataService(new MemoryStorageAdapter(), { fetch: async () => new Response(new Uint8Array()) as Response, lookup: async()=>["93.184.216.34"] });
  const config = loadConfig({ CHAIN_ID:"31337", FACTORY_ADDRESS:creator, DATABASE_PATH:":memory:", ADMIN_TOKEN:"a-secure-admin-token" });
  const api = new BackendApi(db,config,metadata);
  assert.equal((await api.handle(new Request("http://local/health"))).status,200);
  assert.equal((await api.handle(new Request("http://local/ready"))).status,200);
  assert.equal((await api.handle(new Request("http://local/launches/1"))).status,200);
  assert.equal((await api.handle(new Request("http://local/launches?q=memory"))).status,200);
  const chart = await (await api.handle(new Request("http://local/launches/1/chart"))).json() as { tradeCount:number; volume:string };
  assert.deepEqual(chart,{points:[{timestamp:30,blockNumber:"3",side:"buy",grossBase:"100",tokenAmount:"100"}],tradeCount:1,volume:"100"});
  const creatorPage = await (await api.handle(new Request(`http://local/creators/${creator}`))).json() as { projects:unknown[] };
  assert.equal(creatorPage.projects.length,1);
  const invalidComment = await api.handle(new Request("http://local/launches/1/comments",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({author:"not-an-address",body:"hello"})})); assert.equal(invalidComment.status,400);
  const created = await api.handle(new Request("http://local/launches/1/comments",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({author:creator,body:"hello"})})); assert.equal(created.status,201);
  const unauthorized = await api.handle(new Request("http://local/admin/comments/1/moderate",{method:"POST",headers:{"content-type":"application/json",authorization:"Bearer wrong-token"},body:JSON.stringify({actor:"moderator",action:"hide",reason:"spam"})})); assert.equal(unauthorized.status,401);
  const moderated = await api.handle(new Request("http://local/admin/comments/1/moderate",{method:"POST",headers:{"content-type":"application/json",authorization:"Bearer a-secure-admin-token"},body:JSON.stringify({actor:"moderator",action:"hide",reason:"spam"})})); assert.equal(moderated.status,200);
  const missing = await api.handle(new Request("http://local/admin/comments/999/moderate",{method:"POST",headers:{"content-type":"application/json",authorization:"Bearer a-secure-admin-token"},body:JSON.stringify({actor:"moderator",action:"hide",reason:"spam"})})); assert.equal(missing.status,400);
  assert.equal((db.sqlite.prepare("SELECT COUNT(*) count FROM audit_log").get() as {count:number}).count,1);
  for (const path of ["/mint","/withdraw","/reserves","/graduate","/admin/supply"]) assert.equal((await api.handle(new Request(`http://local${path}`,{method:"POST"}))).status,404);
  db.close();
});
