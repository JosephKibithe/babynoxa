import { isIP } from "node:net";
import { lookup as nodeLookup } from "node:dns/promises";
import sharp from "sharp";
import { sha256Hex, type Hex } from "@babynoxa/shared";

export const MAX_MEDIA_BYTES = 5 * 1024 * 1024;
export const MAX_MEDIA_DIMENSION = 4_096;
export const MAX_GIF_FRAMES = 300;
export const MAX_GIF_DURATION_MS = 30_000;
export const MAX_REDIRECTS = 3;
export const MAX_DECODED_RGBA_BYTES = 256 * 1024 * 1024;

export interface ValidatedMedia {
  url: string;
  hash: Hex;
  format: "png" | "jpeg" | "webp" | "gif";
  bytes: number;
  width: number;
  height: number;
  frames: number;
  durationMs: number;
}

export interface MediaValidatorOptions {
  fetch?: typeof fetch;
  lookup?: (hostname: string) => Promise<readonly string[]>;
}

export class MediaValidationError extends Error {}

function isForbiddenIpv4(address: string): boolean {
  const octets = address.split(".").map(Number);
  const [a, b] = octets;
  if (a === undefined || b === undefined) return true;
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}

function isForbiddenAddress(address: string): boolean {
  const kind = isIP(address);
  if (kind === 4) return isForbiddenIpv4(address);
  if (kind === 6) {
    const normalized = address.toLowerCase();
    return normalized === "::" || normalized === "::1" || normalized.startsWith("fe8") || normalized.startsWith("fe9")
      || normalized.startsWith("fea") || normalized.startsWith("feb") || normalized.startsWith("fc")
      || normalized.startsWith("fd") || normalized.startsWith("::ffff:127.") || normalized.startsWith("::ffff:10.")
      || normalized.startsWith("::ffff:192.168.");
  }
  return true;
}

async function defaultLookup(hostname: string): Promise<readonly string[]> {
  return (await nodeLookup(hostname, { all: true, verbatim: true })).map(({ address }) => address);
}

async function assertPublicTarget(url: URL, lookup: (hostname: string) => Promise<readonly string[]>): Promise<void> {
  if (url.protocol !== "https:") throw new MediaValidationError("Media URL must use HTTPS");
  if (url.username || url.password) throw new MediaValidationError("Media URL credentials are forbidden");
  if (url.href.length > 2_048) throw new MediaValidationError("Media URL exceeds 2048 characters");
  const hostname = url.hostname.toLowerCase();
  if (hostname === "localhost" || hostname.endsWith(".localhost")) throw new MediaValidationError("Private media target rejected");
  const addresses = isIP(hostname) ? [hostname] : await lookup(hostname);
  if (addresses.length === 0 || addresses.some(isForbiddenAddress)) throw new MediaValidationError("Private or reserved media target rejected");
}

async function boundedBody(response: Response): Promise<Uint8Array> {
  if (!response.body) throw new MediaValidationError("Media response has no body");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_MEDIA_BYTES) {
      await reader.cancel();
      throw new MediaValidationError("Media exceeds 5 MiB encoded limit");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}

export async function fetchAndValidateMedia(input: string, options: MediaValidatorOptions = {}): Promise<ValidatedMedia> {
  const fetcher = options.fetch ?? fetch;
  const lookup = options.lookup ?? defaultLookup;
  let current: URL;
  try { current = new URL(input); } catch { throw new MediaValidationError("Invalid media URL"); }

  let response: Response | undefined;
  for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
    await assertPublicTarget(current, lookup);
    response = await fetcher(current, { redirect: "manual", headers: { accept: "image/png,image/jpeg,image/webp,image/gif" } });
    if (![301, 302, 303, 307, 308].includes(response.status)) break;
    if (redirects === MAX_REDIRECTS) throw new MediaValidationError("Too many media redirects");
    const location = response.headers.get("location");
    if (!location) throw new MediaValidationError("Redirect is missing Location");
    current = new URL(location, current);
  }
  if (!response?.ok) throw new MediaValidationError(`Media fetch failed with status ${response?.status ?? 0}`);

  const bytes = await boundedBody(response);
  let metadata: sharp.Metadata;
  try {
    metadata = await sharp(bytes, { animated: true, failOn: "error", limitInputPixels: MAX_MEDIA_DIMENSION ** 2 }).metadata();
  } catch (error) {
    throw new MediaValidationError(`Media decode failed: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (!metadata.format || !["png", "jpeg", "webp", "gif"].includes(metadata.format)) throw new MediaValidationError("Unsupported media type");
  const width = metadata.width ?? 0;
  const height = metadata.pageHeight ?? metadata.height ?? 0;
  if (width < 1 || height < 1 || width > MAX_MEDIA_DIMENSION || height > MAX_MEDIA_DIMENSION) {
    throw new MediaValidationError("Media dimensions exceed 4096 x 4096");
  }
  const frames = metadata.pages ?? 1;
  const durationMs = (metadata.delay ?? []).reduce((total, delay) => total + delay, 0);
  if (metadata.format === "gif" && (frames > MAX_GIF_FRAMES || durationMs > MAX_GIF_DURATION_MS)) {
    throw new MediaValidationError("GIF animation limits exceeded");
  }
  if (width * height * frames * 4 > MAX_DECODED_RGBA_BYTES) {
    throw new MediaValidationError("Media exceeds decoded memory safety limit");
  }
  try {
    await sharp(bytes, { animated: true, failOn: "error", limitInputPixels: MAX_MEDIA_DIMENSION ** 2 }).raw().toBuffer();
  } catch (error) {
    throw new MediaValidationError(`Media pixel decode failed: ${error instanceof Error ? error.message : String(error)}`);
  }

  return { url: current.toString(), hash: sha256Hex(bytes), format: metadata.format as ValidatedMedia["format"], bytes: bytes.byteLength, width, height, frames, durationMs };
}
