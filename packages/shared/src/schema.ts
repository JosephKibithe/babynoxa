import { METADATA_SCHEMA_VERSION, type Hex, type ProjectMetadataV1 } from "./types.js";

export interface MetadataInput {
  schemaVersion?: number;
  name: string;
  symbol: string;
  description: string;
  image: string;
  imageHash: Hex;
  website: string;
  twitter?: string;
  telegram?: string;
  discord?: string;
}

export class MetadataValidationError extends Error {
  constructor(public readonly field: string, message: string) {
    super(`${field}: ${message}`);
    this.name = "MetadataValidationError";
  }
}

function length(field: string, value: string, minimum: number, maximum: number): string {
  const trimmed = value.trim();
  const count = [...trimmed].length;
  if (count < minimum || count > maximum) throw new MetadataValidationError(field, `must contain ${minimum}-${maximum} characters`);
  return trimmed;
}

function httpsUrl(field: string, value: string, hosts?: readonly string[]): string {
  if (value.length > 2_048) throw new MetadataValidationError(field, "URL exceeds 2048 characters");
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new MetadataValidationError(field, "must be a valid URL");
  }
  if (parsed.protocol !== "https:") throw new MetadataValidationError(field, "must use HTTPS");
  if (parsed.username || parsed.password) throw new MetadataValidationError(field, "embedded credentials are forbidden");
  if (hosts && !hosts.some((host) => parsed.hostname === host || parsed.hostname.endsWith(`.${host}`))) {
    throw new MetadataValidationError(field, "host is not supported");
  }
  return parsed.toString();
}

function optionalUrl(field: string, value: string | undefined, hosts: readonly string[]): string | undefined {
  return value === undefined || value.trim() === "" ? undefined : httpsUrl(field, value, hosts);
}

export function parseMetadataV1(input: MetadataInput): ProjectMetadataV1 {
  if ((input.schemaVersion ?? METADATA_SCHEMA_VERSION) !== METADATA_SCHEMA_VERSION) {
    throw new MetadataValidationError("schemaVersion", `unsupported version ${String(input.schemaVersion)}`);
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(input.imageHash)) throw new MetadataValidationError("imageHash", "must be a 32-byte hex hash");
  const symbol = length("symbol", input.symbol, 2, 10);
  if (!/^[A-Z0-9]+$/.test(symbol)) throw new MetadataValidationError("symbol", "must contain only uppercase letters and numbers");

  const metadata: ProjectMetadataV1 = {
    schemaVersion: METADATA_SCHEMA_VERSION,
    name: length("name", input.name, 1, 32),
    symbol,
    description: length("description", input.description, 0, 500),
    image: httpsUrl("image", input.image),
    imageHash: input.imageHash.toLowerCase() as Hex,
    website: httpsUrl("website", input.website),
  };
  const twitter = optionalUrl("twitter", input.twitter, ["x.com", "twitter.com"]);
  const telegram = optionalUrl("telegram", input.telegram, ["t.me", "telegram.me"]);
  const discord = optionalUrl("discord", input.discord, ["discord.gg", "discord.com"]);
  if (twitter) metadata.twitter = twitter;
  if (telegram) metadata.telegram = telegram;
  if (discord) metadata.discord = discord;
  return metadata;
}

export function parseProjectMetadata(value: unknown): ProjectMetadataV1 {
  if (value === null || typeof value !== "object") throw new MetadataValidationError("metadata", "must be an object");
  return parseMetadataV1(value as MetadataInput);
}
