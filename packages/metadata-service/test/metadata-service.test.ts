import assert from "node:assert/strict";
import test from "node:test";
import sharp from "sharp";
import { canonicalJson, sha256Hex } from "@babynoxa/shared";
import { fetchAndValidateMedia, MAX_MEDIA_BYTES, MediaValidationError, MetadataService } from "../src/index.js";
import { HashVerifiedStorage, MemoryStorageAdapter, type StorageAdapter } from "../src/storage.js";

const publicLookup = async () => ["93.184.216.34"];
const url = "https://cdn.example/token";

function fetchBytes(bytes: Uint8Array, contentType = "application/octet-stream"): typeof fetch {
  return (async () => new Response(Uint8Array.from(bytes).buffer, { status: 200, headers: { "content-type": contentType } })) as typeof fetch;
}

async function image(format: "png" | "jpeg" | "webp", width = 8, height = 8): Promise<Buffer> {
  const pipeline = sharp({ create: { width, height, channels: 4, background: { r: 20, g: 40, b: 60, alpha: 1 } } });
  return pipeline[format]().toBuffer();
}

test("sniffs and fully decodes PNG, JPEG, WebP and GIF independently of response MIME", async () => {
  const fixtures = [
    ["png", await image("png")], ["jpeg", await image("jpeg")], ["webp", await image("webp")],
    ["gif", await sharp({ create: { width: 8, height: 8, channels: 4, background: "red" } }).gif().toBuffer()],
  ] as const;
  for (const [format, bytes] of fixtures) {
    const result = await fetchAndValidateMedia(url, { fetch: fetchBytes(bytes, "image/jpeg"), lookup: publicLookup });
    assert.equal(result.format, format);
    assert.equal(result.hash, sha256Hex(bytes));
    assert.equal(result.width, 8);
    assert.equal(result.height, 8);
  }
});

test("rejects corrupt and MIME-spoofed non-images", async () => {
  for (const bytes of [new Uint8Array([0x89, 0x50, 0x4e, 0x47]), new TextEncoder().encode("not an image")]) {
    await assert.rejects(fetchAndValidateMedia(url, { fetch: fetchBytes(bytes, "image/png"), lookup: publicLookup }), MediaValidationError);
  }
});

test("rejects oversized decoded dimensions and encoded bodies", async () => {
  const oversized = await image("png", 4_097, 1);
  await assert.rejects(fetchAndValidateMedia(url, { fetch: fetchBytes(oversized), lookup: publicLookup }), /4096|pixel limit/);
  const body = new Uint8Array(MAX_MEDIA_BYTES + 1);
  await assert.rejects(fetchAndValidateMedia(url, { fetch: fetchBytes(body), lookup: publicLookup }), /5 MiB/);
});

test("fully decodes EXIF-bearing JPEG while hashing the approved original bytes", async () => {
  const exif = { IFD0: { Copyright: "BabyNoxa fixture", Artist: "Fixture" } };
  const bytes = await sharp({ create: { width: 4, height: 4, channels: 3, background: "blue" } }).jpeg().withMetadata({ exif }).toBuffer();
  assert.ok((await sharp(bytes).metadata()).exif);
  const result = await fetchAndValidateMedia(url, { fetch: fetchBytes(bytes), lookup: publicLookup });
  assert.equal(result.format, "jpeg");
  assert.equal(result.hash, sha256Hex(bytes));
});

test("blocks private targets and revalidates redirects", async () => {
  await assert.rejects(fetchAndValidateMedia("https://127.0.0.1/a.png", { fetch: fetchBytes(await image("png")), lookup: publicLookup }), /Private/);
  const redirectFetch = (async () => new Response(null, { status: 302, headers: { location: "https://169.254.169.254/latest/meta-data" } })) as typeof fetch;
  await assert.rejects(fetchAndValidateMedia(url, { fetch: redirectFetch, lookup: publicLookup }), /Private/);
});

test("rejects excessive redirects", async () => {
  const redirectFetch = (async (input: string | URL | Request) => {
    const current = new URL(input instanceof Request ? input.url : input.toString());
    const count = Number(current.searchParams.get("n") ?? "0");
    return new Response(null, { status: 302, headers: { location: `https://cdn.example/token?n=${count + 1}` } });
  }) as typeof fetch;
  await assert.rejects(fetchAndValidateMedia(url, { fetch: redirectFetch, lookup: publicLookup }), /Too many/);
});

test("storage round-trip mismatch fails closed", async () => {
  const corrupting: StorageAdapter = {
    async put() { return "memory://corrupt"; },
    async get() { return new TextEncoder().encode("different"); },
  };
  await assert.rejects(new HashVerifiedStorage(corrupting).store(new TextEncoder().encode("original")), /hash mismatch/i);
});

test("prepares, stores, retrieves and hashes canonical metadata for factory creation", async () => {
  const bytes = await image("webp");
  const adapter = new MemoryStorageAdapter();
  const service = new MetadataService(adapter, { fetch: fetchBytes(bytes), lookup: publicLookup });
  const prepared = await service.prepare({
    name: "Baby Noxa", symbol: "NOXA", description: "Educational launch", image: url,
    website: "https://babynoxa.example", twitter: "https://x.com/babynoxa",
  });
  assert.equal(prepared.imageHash, sha256Hex(bytes));
  assert.equal(prepared.metadataHash, sha256Hex(canonicalJson(prepared.metadata)));
  assert.match(prepared.metadataUri, /^memory:\/\/sha256\//);
  const stored = new TextDecoder().decode(await adapter.get(prepared.metadataUri));
  assert.equal(stored, canonicalJson(prepared.metadata));
  assert.equal(sha256Hex(stored), prepared.metadataHash);
});
