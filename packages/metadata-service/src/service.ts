import { canonicalJson, parseMetadataV1, type PreparedMetadata } from "@babynoxa/shared";
import { fetchAndValidateMedia, type MediaValidatorOptions } from "./media.js";
import { HashVerifiedStorage, type StorageAdapter } from "./storage.js";

export interface PrepareMetadataInput {
  name: string;
  symbol: string;
  description: string;
  image?: string;
  website?: string;
  twitter?: string;
  telegram?: string;
  discord?: string;
}

export class MetadataService {
  private readonly storage: HashVerifiedStorage;

  constructor(adapter: StorageAdapter, private readonly mediaOptions: MediaValidatorOptions = {}) {
    this.storage = new HashVerifiedStorage(adapter);
  }

  async prepare(input: PrepareMetadataInput): Promise<PreparedMetadata> {
    const image = input.image?.trim();
    parseMetadataV1({ ...input, ...(image ? { imageHash: `0x${"00".repeat(32)}` as const } : {}) });
    const media = image ? await fetchAndValidateMedia(image, this.mediaOptions) : undefined;
    const metadata = parseMetadataV1({ ...input, ...(media ? { image: media.url, imageHash: media.hash } : {}) });
    const bytes = new TextEncoder().encode(canonicalJson(metadata));
    const stored = await this.storage.store(bytes);
    return { metadata, metadataUri: stored.uri, metadataHash: stored.hash, ...(media ? { imageHash: media.hash } : {}) };
  }
}
