export const METADATA_SCHEMA_VERSION = 1 as const;

export type Hex = `0x${string}`;
export type Address = `0x${string}`;
export type LaunchLifecycle = "created" | "trading" | "graduation-ready" | "graduated";

export interface ProjectMetadataV1 {
  schemaVersion: typeof METADATA_SCHEMA_VERSION;
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

export type ProjectMetadata = ProjectMetadataV1;

export interface LaunchView {
  chainId: number;
  launchId: bigint;
  creator: Address;
  token: Address;
  curve: Address;
  officialPair: Address;
  treasury: Address;
  graduationManager: Address;
  metadataUri: string;
  metadataHash: Hex;
  lifecycle: LaunchLifecycle;
}

export interface TokenView {
  address: Address;
  name: string;
  symbol: string;
  decimals: 18;
  totalSupply: bigint;
}

export interface TradeView {
  chainId: number;
  transactionHash: Hex;
  logIndex: number;
  launchId: bigint;
  trader: Address;
  side: "buy" | "sell";
  tokenAmount: bigint;
  grossBaseAmount: bigint;
  netBaseAmount: bigint;
  blockNumber: bigint;
  timestamp: number;
}

export interface ContractEventView {
  chainId: number;
  transactionHash: Hex;
  logIndex: number;
  blockNumber: bigint;
  blockHash: Hex;
  eventName: string;
  address: Address;
  args: Readonly<Record<string, unknown>>;
}

export interface PreparedMetadata {
  metadata: ProjectMetadataV1;
  metadataUri: string;
  metadataHash: Hex;
  imageHash: Hex;
}
