import type { BackendDatabase } from "./database.js";

export interface ChainEvent {
  chainId: number; transactionHash: string; logIndex: number; blockNumber: number; blockHash: string; parentHash: string;
  confirmed: boolean; eventName: string; address: string; args: Record<string, string>; timestamp: number;
}

export interface AuthoritativeLaunchState { lifecycle: string; curveInventory: bigint; realReserve: bigint; blockNumber: bigint }
export interface ContractStateReader { readLaunchState(chainId: number, launchId: bigint): Promise<AuthoritativeLaunchState> }

const text = (args: Record<string, string>, key: string, fallback = "") => args[key] ?? fallback;
const add = (left: string, right: string) => (BigInt(left) + BigInt(right)).toString();
const subFloor = (left: string, right: string) => { const value = BigInt(left) - BigInt(right); return (value < 0n ? 0n : value).toString(); };

export class EventIndexer {
  constructor(private readonly db: BackendDatabase, private readonly reader?: ContractStateReader, private readonly wrappedNative?: string) {}

  async ingest(events: readonly ChainEvent[]): Promise<void> {
    const ordered = [...events].sort((a, b) => a.blockNumber - b.blockNumber || a.logIndex - b.logIndex);
    for (const event of ordered) this.ingestOne(event);
    for (const chainId of new Set(ordered.map((event) => event.chainId))) await this.rebuild(chainId);
  }

  private ingestOne(event: ChainEvent): void {
    const sqlite = this.db.sqlite;
    this.checkpoint(event.chainId, event.blockNumber, event.blockHash, event.parentHash, event.confirmed);
    sqlite.prepare("INSERT INTO chain_events(chain_id,transaction_hash,log_index,block_number,block_hash,parent_hash,confirmed,event_name,address,args_json,timestamp) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(chain_id,transaction_hash,log_index) DO UPDATE SET confirmed=MAX(confirmed,excluded.confirmed)")
      .run(event.chainId, event.transactionHash, event.logIndex, event.blockNumber, event.blockHash, event.parentHash, event.confirmed ? 1 : 0, event.eventName, event.address, JSON.stringify(event.args), event.timestamp);
  }

  checkpoint(chainId: number, blockNumber: number, blockHash: string, parentHash: string, confirmed: boolean): void {
    const sqlite = this.db.sqlite;
    const checkpoint = sqlite.prepare("SELECT block_hash FROM indexer_checkpoints WHERE chain_id=? AND block_number=?").get(chainId, blockNumber) as { block_hash: string } | undefined;
    if (checkpoint && checkpoint.block_hash !== blockHash) this.rewind(chainId, blockNumber);
    const parent = sqlite.prepare("SELECT block_hash FROM indexer_checkpoints WHERE chain_id=? AND block_number=?").get(chainId, blockNumber - 1) as { block_hash: string } | undefined;
    if (parent && parent.block_hash !== parentHash) this.rewind(chainId, blockNumber - 1);
    sqlite.prepare("INSERT OR REPLACE INTO indexer_checkpoints(chain_id,block_number,block_hash,parent_hash,confirmed) VALUES(?,?,?,?,?)")
      .run(chainId, blockNumber, blockHash, parentHash, confirmed ? 1 : 0);
  }

  resumeBlock(chainId: number, deploymentBlock: bigint): bigint {
    const checkpoint = this.db.sqlite.prepare("SELECT MAX(block_number) block_number FROM indexer_checkpoints WHERE chain_id=?")
      .get(chainId) as { block_number: number | null } | undefined;
    return checkpoint?.block_number === null || checkpoint?.block_number === undefined
      ? deploymentBlock
      : BigInt(checkpoint.block_number) + 1n;
  }

  rewind(chainId: number, fromBlock: number): void {
    this.db.sqlite.prepare("DELETE FROM chain_events WHERE chain_id=? AND block_number>=?").run(chainId, fromBlock);
    this.db.sqlite.prepare("DELETE FROM indexer_checkpoints WHERE chain_id=? AND block_number>=?").run(chainId, fromBlock);
  }

  async rebuild(chainId: number): Promise<void> {
    const sqlite = this.db.sqlite;
    sqlite.exec("BEGIN");
    try {
      sqlite.prepare("DELETE FROM trades WHERE chain_id=?").run(chainId);
      sqlite.prepare("DELETE FROM holders WHERE chain_id=?").run(chainId);
      sqlite.prepare("DELETE FROM projects WHERE chain_id=?").run(chainId);
      const rows = sqlite.prepare("SELECT * FROM chain_events WHERE chain_id=? ORDER BY block_number,log_index").all(chainId) as Array<Record<string, string | number>>;
      // Factory registration events are emitted after an optional atomic creator buy.
      // Build the project registry first so earlier child-contract logs in the same
      // transaction can be projected during the second pass.
      for (const row of rows) {
        if (row.event_name === "LaunchCreated" || row.event_name === "MetadataCommitted") this.project(row);
      }
      for (const row of rows) {
        if (row.event_name !== "LaunchCreated" && row.event_name !== "MetadataCommitted") this.project(row);
      }
      sqlite.exec("COMMIT");
    } catch (error) { sqlite.exec("ROLLBACK"); throw error; }
    if (this.reader) await this.refreshAuthoritativeState(chainId);
  }

  private project(row: Record<string, string | number>): void {
    const sqlite = this.db.sqlite;
    const args = JSON.parse(String(row.args_json)) as Record<string, string>;
    const chainId = Number(row.chain_id);
    const launchId = text(args, "launchId", "0");
    if (row.event_name === "LaunchCreated") {
      sqlite.prepare("INSERT INTO projects(chain_id,launch_id,creator,token,curve,official_pair,treasury,manager,lifecycle) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(chain_id,launch_id) DO UPDATE SET creator=excluded.creator,token=excluded.token,curve=excluded.curve,official_pair=excluded.official_pair,treasury=excluded.treasury,manager=excluded.manager,lifecycle=excluded.lifecycle")
        .run(chainId, launchId, text(args,"creator"), text(args,"token"), text(args,"curve"), text(args,"officialPair"), text(args,"treasury"), text(args,"graduationManager"), "trading");
    } else if (row.event_name === "MetadataCommitted") {
      sqlite.prepare("INSERT INTO projects(chain_id,launch_id,metadata_uri,metadata_hash,lifecycle) VALUES(?,?,?,?,'created') ON CONFLICT(chain_id,launch_id) DO UPDATE SET metadata_uri=excluded.metadata_uri,metadata_hash=excluded.metadata_hash")
        .run(chainId, launchId, text(args,"metadataURI"), text(args,"metadataHash"));
    } else if (row.event_name === "GraduationReady") {
      sqlite.prepare("UPDATE projects SET lifecycle='graduation-ready' WHERE chain_id=? AND lower(token)=lower(?)").run(chainId, text(args,"token"));
    } else if (row.event_name === "GraduationExecuted") {
      sqlite.prepare("UPDATE projects SET lifecycle='graduated' WHERE chain_id=? AND lower(token)=lower(?)").run(chainId, text(args,"token"));
    } else if (row.event_name === "TokensPurchased" || row.event_name === "TokensSold") {
      // Match on lower(curve): stored addresses are EIP-55 checksummed (decoded event args) while the
      // emitting log address is lowercase, so an exact `=` would silently drop every curve trade.
      const project = sqlite.prepare("SELECT launch_id FROM projects WHERE chain_id=? AND lower(curve)=lower(?)").get(chainId, String(row.address)) as { launch_id: string } | undefined;
      if (!project) return;
      const buy = row.event_name === "TokensPurchased";
      sqlite.prepare("INSERT OR REPLACE INTO trades(chain_id,transaction_hash,log_index,launch_id,trader,side,token_amount,gross_base,net_base,block_number,timestamp) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
        .run(chainId, String(row.transaction_hash), Number(row.log_index), project.launch_id, text(args,buy?"buyer":"seller"), buy?"buy":"sell", text(args,buy?"tokensOut":"tokensIn","0"), text(args,buy?"grossBaseExecuted":"grossBaseOut","0"), text(args,buy?"netBaseToCurve":"netBaseCredit","0"), String(row.block_number), Number(row.timestamp));
    } else if (row.event_name === "Transfer") {
      const project = sqlite.prepare("SELECT launch_id FROM projects WHERE chain_id=? AND lower(token)=lower(?)").get(chainId, String(row.address)) as { launch_id: string } | undefined;
      if (!project) return;
      const value = text(args,"value","0"); const from = text(args,"from"); const to = text(args,"to");
      if (!/^0x0{40}$/i.test(from)) this.adjustHolder(chainId, project.launch_id, from, value, false);
      if (!/^0x0{40}$/i.test(to)) this.adjustHolder(chainId, project.launch_id, to, value, true);
    } else if (row.event_name === "Swap") {
      // Post-graduation trades happen on the official Uniswap V2 pair. Classify each swap as a
      // buy (native base in, token out) or sell (token in, native base out) and record it in the
      // same trades table so the market chart and swap feed span the whole curve→AMM lifecycle.
      if (!this.wrappedNative) return;
      const project = sqlite.prepare("SELECT launch_id,token FROM projects WHERE chain_id=? AND lower(official_pair)=lower(?)").get(chainId, String(row.address)) as { launch_id: string; token: string } | undefined;
      if (!project) return;
      const tokenIsToken0 = project.token.toLowerCase() < this.wrappedNative.toLowerCase();
      const a0In = text(args,"amount0In","0"), a1In = text(args,"amount1In","0"), a0Out = text(args,"amount0Out","0"), a1Out = text(args,"amount1Out","0");
      const tokenIn = tokenIsToken0 ? a0In : a1In, tokenOut = tokenIsToken0 ? a0Out : a1Out;
      const baseIn = tokenIsToken0 ? a1In : a0In, baseOut = tokenIsToken0 ? a1Out : a0Out;
      const buy = BigInt(baseIn) > 0n;
      const tokenAmount = buy ? tokenOut : tokenIn;
      const grossBase = buy ? baseIn : baseOut;
      if (BigInt(tokenAmount) === 0n && BigInt(grossBase) === 0n) return;
      sqlite.prepare("INSERT OR REPLACE INTO trades(chain_id,transaction_hash,log_index,launch_id,trader,side,token_amount,gross_base,net_base,block_number,timestamp) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
        .run(chainId, String(row.transaction_hash), Number(row.log_index), project.launch_id, text(args,"to"), buy ? "buy" : "sell", tokenAmount, grossBase, grossBase, String(row.block_number), Number(row.timestamp));
    }
  }

  private adjustHolder(chainId: number, launchId: string, holder: string, amount: string, increase: boolean): void {
    const existing = this.db.sqlite.prepare("SELECT balance FROM holders WHERE chain_id=? AND launch_id=? AND holder=?").get(chainId, launchId, holder) as { balance: string } | undefined;
    const balance = increase ? add(existing?.balance ?? "0", amount) : subFloor(existing?.balance ?? "0", amount);
    this.db.sqlite.prepare("INSERT OR REPLACE INTO holders(chain_id,launch_id,holder,balance) VALUES(?,?,?,?)").run(chainId, launchId, holder, balance);
  }

  async refreshAuthoritativeState(chainId: number): Promise<void> {
    if (!this.reader) return;
    const launches = this.db.sqlite.prepare("SELECT launch_id FROM projects WHERE chain_id=?").all(chainId) as Array<{ launch_id: string }>;
    for (const { launch_id } of launches) {
      const state = await this.reader.readLaunchState(chainId, BigInt(launch_id));
      this.db.sqlite.prepare("UPDATE projects SET lifecycle=?,curve_inventory=?,real_reserve=?,authoritative_block=? WHERE chain_id=? AND launch_id=?")
        .run(state.lifecycle, state.curveInventory.toString(), state.realReserve.toString(), state.blockNumber.toString(), chainId, launch_id);
    }
  }
}
