import { DatabaseSync } from "node:sqlite";

const migrations = [
  `CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);
   CREATE TABLE projects(chain_id INTEGER NOT NULL, launch_id TEXT NOT NULL, creator TEXT, token TEXT, curve TEXT, official_pair TEXT, treasury TEXT, manager TEXT, metadata_uri TEXT, metadata_hash TEXT, lifecycle TEXT NOT NULL DEFAULT 'created', curve_inventory TEXT NOT NULL DEFAULT '0', real_reserve TEXT NOT NULL DEFAULT '0', authoritative_block TEXT, PRIMARY KEY(chain_id, launch_id));
   CREATE TABLE metadata_versions(id INTEGER PRIMARY KEY AUTOINCREMENT, chain_id INTEGER NOT NULL, launch_id TEXT, uri TEXT NOT NULL, hash TEXT NOT NULL, canonical_json TEXT NOT NULL, version INTEGER NOT NULL, created_at TEXT NOT NULL);
   CREATE TABLE trades(chain_id INTEGER NOT NULL, transaction_hash TEXT NOT NULL, log_index INTEGER NOT NULL, launch_id TEXT NOT NULL, trader TEXT NOT NULL, side TEXT NOT NULL, token_amount TEXT NOT NULL, gross_base TEXT NOT NULL, net_base TEXT NOT NULL, block_number TEXT NOT NULL, timestamp INTEGER NOT NULL, PRIMARY KEY(chain_id, transaction_hash, log_index));
   CREATE TABLE holders(chain_id INTEGER NOT NULL, launch_id TEXT NOT NULL, holder TEXT NOT NULL, balance TEXT NOT NULL, PRIMARY KEY(chain_id, launch_id, holder));
   CREATE TABLE comments(id INTEGER PRIMARY KEY AUTOINCREMENT, chain_id INTEGER NOT NULL, launch_id TEXT NOT NULL, author TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'visible', created_at TEXT NOT NULL);
   CREATE TABLE moderation_actions(id INTEGER PRIMARY KEY AUTOINCREMENT, comment_id INTEGER NOT NULL, action TEXT NOT NULL, actor TEXT NOT NULL, reason TEXT NOT NULL, created_at TEXT NOT NULL);
   CREATE TABLE audit_log(id INTEGER PRIMARY KEY AUTOINCREMENT, actor TEXT NOT NULL, action TEXT NOT NULL, target TEXT NOT NULL, details TEXT NOT NULL, created_at TEXT NOT NULL);
   CREATE TABLE chain_events(chain_id INTEGER NOT NULL, transaction_hash TEXT NOT NULL, log_index INTEGER NOT NULL, block_number INTEGER NOT NULL, block_hash TEXT NOT NULL, parent_hash TEXT NOT NULL, confirmed INTEGER NOT NULL, event_name TEXT NOT NULL, address TEXT NOT NULL, args_json TEXT NOT NULL, timestamp INTEGER NOT NULL, PRIMARY KEY(chain_id, transaction_hash, log_index));
   CREATE TABLE indexer_checkpoints(chain_id INTEGER NOT NULL, block_number INTEGER NOT NULL, block_hash TEXT NOT NULL, parent_hash TEXT NOT NULL, confirmed INTEGER NOT NULL, PRIMARY KEY(chain_id, block_number));`,
  `CREATE INDEX IF NOT EXISTS projects_search ON projects(chain_id, creator, token);
   CREATE INDEX IF NOT EXISTS trades_launch_block ON trades(chain_id, launch_id, block_number, log_index);
   CREATE INDEX IF NOT EXISTS events_replay ON chain_events(chain_id, block_number, log_index);`,
] as const;

export class BackendDatabase {
  readonly sqlite: DatabaseSync;
  constructor(path = ":memory:") { this.sqlite = new DatabaseSync(path); this.sqlite.exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;"); }
  migrate(): void {
    this.sqlite.exec("CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");
    const has = this.sqlite.prepare("SELECT 1 FROM schema_migrations WHERE version=?");
    const add = this.sqlite.prepare("INSERT INTO schema_migrations(version,applied_at) VALUES(?,?)");
    migrations.forEach((sql, index) => { const version = index + 1; if (!has.get(version)) { this.sqlite.exec("BEGIN"); try { this.sqlite.exec(sql); add.run(version, new Date().toISOString()); this.sqlite.exec("COMMIT"); } catch (error) { this.sqlite.exec("ROLLBACK"); throw error; } } });
  }
  close(): void { this.sqlite.close(); }
  get migrationVersion(): number { return Number((this.sqlite.prepare("SELECT COALESCE(MAX(version),0) version FROM schema_migrations").get() as { version: number }).version); }
}
