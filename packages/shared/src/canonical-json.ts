import { createHash } from "node:crypto";
import type { Hex } from "./types.js";

function normalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(normalize);
  if (value !== null && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(record)
        .sort()
        .filter((key) => record[key] !== undefined)
        .map((key) => [key, normalize(record[key])]),
    );
  }
  if (typeof value === "bigint") throw new TypeError("Canonical JSON does not support bigint");
  if (typeof value === "number" && !Number.isFinite(value)) throw new TypeError("Canonical JSON requires finite numbers");
  return value;
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(normalize(value));
}

export function sha256Hex(value: string | Uint8Array): Hex {
  return `0x${createHash("sha256").update(value).digest("hex")}`;
}
