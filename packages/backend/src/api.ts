import type { MetadataService, PrepareMetadataInput } from "@babynoxa/metadata-service";
import { timingSafeEqual } from "node:crypto";
import type { BackendConfig } from "./config.js";
import type { BackendDatabase } from "./database.js";

const json = (body: unknown, status = 200) => Response.json(body, { status });
const CURVE_ALLOCATION = 800_000_000n * 10n ** 18n;

type TradeRow = { side: string; gross_base: string; token_amount: string; timestamp: number; block_number: string };

const tradeMetrics = (trades: readonly TradeRow[]) => {
  let volume = 0n;
  for (const trade of trades) volume += BigInt(trade.gross_base);
  return { tradeCount: trades.length, volume: volume.toString() };
};

const authorized = (provided: string | null, expected: string) => {
  const prefix = "Bearer ";
  if (!provided?.startsWith(prefix)) return false;
  const actual = Buffer.from(provided.slice(prefix.length));
  const wanted = Buffer.from(expected);
  return actual.length === wanted.length && timingSafeEqual(actual, wanted);
};

export class BackendApi {
  constructor(private readonly db: BackendDatabase, private readonly config: BackendConfig, private readonly metadata: MetadataService) {}

  /** Attach the committed metadata (name/symbol/description/image) to project rows so list views can render it, not just the detail view. */
  private withMetadata<T extends { metadata_uri?: string; metadata_hash?: string }>(projects: readonly T[]): Array<T & { metadata?: unknown }> {
    const stmt = this.db.sqlite.prepare("SELECT canonical_json FROM metadata_versions WHERE chain_id=? AND uri=? AND hash=? ORDER BY version DESC,id DESC LIMIT 1");
    return projects.map((project) => {
      const row = project.metadata_uri && project.metadata_hash
        ? stmt.get(this.config.chainId, project.metadata_uri, project.metadata_hash) as { canonical_json: string } | undefined
        : undefined;
      return row ? { ...project, metadata: JSON.parse(row.canonical_json) as unknown } : project;
    });
  }

  async handle(request: Request): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/health") return json({ status: "ok" });
      if (request.method === "GET" && url.pathname === "/ready") return json({ status: this.db.migrationVersion >= 2 ? "ready" : "not-ready", chainId: this.config.chainId }, this.db.migrationVersion >= 2 ? 200 : 503);
      if (request.method === "POST" && url.pathname === "/metadata/prepare") {
        const prepared = await this.metadata.prepare(await request.json() as PrepareMetadataInput);
        this.db.sqlite.prepare("INSERT INTO metadata_versions(chain_id,uri,hash,canonical_json,version,created_at) VALUES(?,?,?,?,?,?)")
          .run(this.config.chainId, prepared.metadataUri, prepared.metadataHash, JSON.stringify(prepared.metadata), 1, new Date().toISOString());
        return json(prepared, 201);
      }
      const launch = url.pathname.match(/^\/launches\/(\d+)$/);
      if (request.method === "GET" && launch) {
        const project = this.db.sqlite.prepare("SELECT * FROM projects WHERE chain_id=? AND launch_id=?").get(this.config.chainId, launch[1]!);
        if (!project) return json({ error: "not found" }, 404);
        const trades = this.db.sqlite.prepare("SELECT * FROM trades WHERE chain_id=? AND launch_id=? ORDER BY CAST(block_number AS INTEGER),log_index").all(this.config.chainId, launch[1]!) as unknown as TradeRow[];
        const holders = this.db.sqlite.prepare("SELECT holder,balance FROM holders WHERE chain_id=? AND launch_id=? AND balance!='0' ORDER BY CAST(balance AS INTEGER) DESC").all(this.config.chainId, launch[1]!);
        const inventory = BigInt((project as { curve_inventory: string }).curve_inventory);
        const progressBps = inventory > CURVE_ALLOCATION ? 0 : Number((CURVE_ALLOCATION - inventory) * 10_000n / CURVE_ALLOCATION);
        const [projectWithMetadata] = this.withMetadata([project as { metadata_uri?: string; metadata_hash?: string }]);
        return json({ project: projectWithMetadata, trades, holders, metrics: { ...tradeMetrics(trades), progressBps } });
      }
      const chart = url.pathname.match(/^\/launches\/(\d+)\/chart$/);
      if (request.method === "GET" && chart) {
        const trades = this.db.sqlite.prepare("SELECT side,gross_base,token_amount,timestamp,block_number FROM trades WHERE chain_id=? AND launch_id=? ORDER BY CAST(block_number AS INTEGER),log_index").all(this.config.chainId, chart[1]!) as unknown as TradeRow[];
        const points = trades.map((trade) => ({ timestamp: trade.timestamp, blockNumber: trade.block_number, side: trade.side, grossBase: trade.gross_base, tokenAmount: trade.token_amount }));
        return json({ points, ...tradeMetrics(trades) });
      }
      const creator = url.pathname.match(/^\/creators\/(0x[0-9a-fA-F]{40})$/);
      if (request.method === "GET" && creator) {
        const projects = this.db.sqlite.prepare("SELECT * FROM projects WHERE chain_id=? AND lower(creator)=lower(?) ORDER BY CAST(launch_id AS INTEGER) DESC").all(this.config.chainId, creator[1]!) as Array<{ metadata_uri?: string; metadata_hash?: string }>;
        return json({ creator: creator[1]!.toLowerCase(), projects: this.withMetadata(projects) });
      }
      if (request.method === "GET" && url.pathname === "/launches") {
        const query = `%${(url.searchParams.get("q") ?? "").toLowerCase()}%`;
        const projects = this.db.sqlite.prepare("SELECT * FROM projects WHERE chain_id=? AND (lower(COALESCE(metadata_uri,'')) LIKE ? OR lower(COALESCE(creator,'')) LIKE ? OR lower(COALESCE(token,'')) LIKE ?) ORDER BY CAST(launch_id AS INTEGER) DESC LIMIT 100")
          .all(this.config.chainId, query, query, query) as Array<{ metadata_uri?: string; metadata_hash?: string }>;
        return json({ projects: this.withMetadata(projects) });
      }
      if (request.method === "GET" && url.pathname === "/trending") {
        const projects = this.db.sqlite.prepare("SELECT p.*,COUNT(t.log_index) trade_count,COALESCE(SUM(CAST(t.gross_base AS INTEGER)),0) volume FROM projects p LEFT JOIN trades t ON t.chain_id=p.chain_id AND t.launch_id=p.launch_id WHERE p.chain_id=? GROUP BY p.launch_id ORDER BY volume DESC,trade_count DESC LIMIT 50").all(this.config.chainId) as Array<{ metadata_uri?: string; metadata_hash?: string }>;
        return json({ projects: this.withMetadata(projects) });
      }
      const comments = url.pathname.match(/^\/launches\/(\d+)\/comments$/);
      if (comments && request.method === "GET") return json({ comments: this.db.sqlite.prepare("SELECT * FROM comments WHERE chain_id=? AND launch_id=? AND status='visible' ORDER BY id").all(this.config.chainId, comments[1]!) });
      if (comments && request.method === "POST") {
        const body = await request.json() as { author?: string; body?: string };
        if (!body.author || !/^0x[0-9a-fA-F]{40}$/.test(body.author) || !body.body?.trim() || body.body.length > 1_000) return json({ error: "invalid comment" }, 400);
        if (!this.db.sqlite.prepare("SELECT 1 FROM projects WHERE chain_id=? AND launch_id=?").get(this.config.chainId, comments[1]!)) return json({ error: "launch not found" }, 404);
        const result = this.db.sqlite.prepare("INSERT INTO comments(chain_id,launch_id,author,body,created_at) VALUES(?,?,?,?,?)").run(this.config.chainId, comments[1]!, body.author, body.body.trim(), new Date().toISOString());
        return json({ id: Number(result.lastInsertRowid) }, 201);
      }
      const moderation = url.pathname.match(/^\/admin\/comments\/(\d+)\/moderate$/);
      if (moderation && request.method === "POST") {
        if (!authorized(request.headers.get("authorization"), this.config.adminToken)) return json({ error: "unauthorized" }, 401);
        const body = await request.json() as { action?: string; reason?: string; actor?: string };
        if (!body.actor || body.actor.length > 100 || !body.reason || body.reason.length > 500 || !["hide", "restore"].includes(body.action ?? "")) return json({ error: "invalid moderation" }, 400);
        const status = body.action === "hide" ? "hidden" : "visible";
        this.db.sqlite.exec("BEGIN");
        try {
          const updated = this.db.sqlite.prepare("UPDATE comments SET status=? WHERE id=?").run(status, moderation[1]!);
          if (Number(updated.changes) !== 1) throw new Error("comment not found");
          this.db.sqlite.prepare("INSERT INTO moderation_actions(comment_id,action,actor,reason,created_at) VALUES(?,?,?,?,?)").run(moderation[1]!, body.action!, body.actor, body.reason, new Date().toISOString());
          this.db.sqlite.prepare("INSERT INTO audit_log(actor,action,target,details,created_at) VALUES(?,?,?,?,?)").run(body.actor, `comment.${body.action}`, `comment:${moderation[1]!}`, JSON.stringify({ reason: body.reason }), new Date().toISOString());
          this.db.sqlite.exec("COMMIT");
        } catch (error) { this.db.sqlite.exec("ROLLBACK"); throw error; }
        return json({ status });
      }
      return json({ error: "not found" }, 404);
    } catch (error) { return json({ error: error instanceof Error ? error.message : String(error) }, 400); }
  }
}
