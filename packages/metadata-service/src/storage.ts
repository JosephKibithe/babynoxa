import { sha256Hex, type Hex } from "@babynoxa/shared";

export interface StorageAdapter {
  put(bytes: Uint8Array): Promise<string>;
  get(uri: string): Promise<Uint8Array>;
}

export class HashVerifiedStorage {
  constructor(private readonly adapter: StorageAdapter) {}

  async store(bytes: Uint8Array): Promise<{ uri: string; hash: Hex }> {
    const hash = sha256Hex(bytes);
    const uri = await this.adapter.put(bytes);
    const retrieved = await this.adapter.get(uri);
    const retrievedHash = sha256Hex(retrieved);
    if (retrievedHash !== hash) throw new Error(`Storage hash mismatch: expected ${hash}, received ${retrievedHash}`);
    return { uri, hash };
  }
}

export class MemoryStorageAdapter implements StorageAdapter {
  private readonly values = new Map<string, Uint8Array>();

  async put(bytes: Uint8Array): Promise<string> {
    const uri = `memory://sha256/${sha256Hex(bytes).slice(2)}`;
    this.values.set(uri, Uint8Array.from(bytes));
    return uri;
  }

  async get(uri: string): Promise<Uint8Array> {
    const value = this.values.get(uri);
    if (!value) throw new Error(`Missing storage object: ${uri}`);
    return Uint8Array.from(value);
  }
}
