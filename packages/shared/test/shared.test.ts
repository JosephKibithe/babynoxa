import assert from "node:assert/strict";
import test from "node:test";
import { canonicalJson, parseMetadataV1, sha256Hex } from "../src/index.js";

const hash = `0x${"ab".repeat(32)}` as const;
const valid = { name: "Baby Noxa", symbol: "NOXA1", description: "Launch", image: "https://cdn.example/image.png", imageHash: hash, website: "https://example.com", twitter: "https://x.com/babynoxa", telegram: "https://t.me/babynoxa", discord: "https://discord.gg/example" };

test("canonical JSON and hash ignore object insertion order", () => {
  const a = { z: 1, nested: { b: 2, a: 1 }, a: "first" };
  const b = { a: "first", nested: { a: 1, b: 2 }, z: 1 };
  assert.equal(canonicalJson(a), canonicalJson(b));
  assert.equal(sha256Hex(canonicalJson(a)), sha256Hex(canonicalJson(b)));
});

test("metadata text boundaries are enforced", () => {
  for (const [field, value, passes] of [
    ["name", "A", true], ["name", "A".repeat(32), true], ["name", "", false], ["name", "A".repeat(33), false],
    ["symbol", "AB", true], ["symbol", "A1".repeat(5), true], ["symbol", "A", false], ["symbol", "ABCDEFGHIJK", false], ["symbol", "lower", false],
    ["description", "", true], ["description", "D".repeat(500), true], ["description", "D".repeat(501), false],
  ] as const) {
    const input = { ...valid, [field]: value };
    if (passes) assert.doesNotThrow(() => parseMetadataV1(input));
    else assert.throws(() => parseMetadataV1(input));
  }
});

test("HTTPS and supported social hosts are enforced", () => {
  assert.doesNotThrow(() => parseMetadataV1(valid));
  for (const patch of [
    { website: "http://example.com" }, { image: "https://user:pass@example.com/a.png" },
    { twitter: "https://example.com/user" }, { telegram: "https://evil.example/user" },
    { discord: "https://notdiscord.example/invite" },
  ]) assert.throws(() => parseMetadataV1({ ...valid, ...patch }));
});

test("schema compatibility is explicit", () => {
  assert.equal(parseMetadataV1(valid).schemaVersion, 1);
  assert.throws(() => parseMetadataV1({ ...valid, schemaVersion: 2 }), /unsupported version/);
});
