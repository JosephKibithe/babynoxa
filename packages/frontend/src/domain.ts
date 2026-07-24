import type { Address, Hex, LaunchLifecycle, ProjectMetadataV1 } from "@babynoxa/shared";

export interface ProjectRecord {
  chain_id: number;
  launch_id: string;
  creator: Address;
  token: Address;
  curve: Address;
  official_pair: Address;
  treasury: Address;
  manager: Address;
  metadata_uri: string;
  metadata_hash: Hex;
  lifecycle: LaunchLifecycle;
  curve_inventory: string;
  real_reserve: string;
  authoritative_block: string;
  metadata?: ProjectMetadataV1;
}

export interface TradeRecord {
  transaction_hash: Hex;
  trader: Address;
  side: "buy" | "sell";
  token_amount: string;
  gross_base: string;
  net_base: string;
  timestamp: number;
}

export interface LaunchDetail {
  project: ProjectRecord;
  trades: TradeRecord[];
  holders: Array<{ holder: Address; balance: string }>;
  metrics: { tradeCount: number; volume: string; progressBps: number };
}

export interface WalletState {
  address?: Address;
  chainId?: number;
  status: "disconnected" | "connecting" | "connected" | "unsupported";
  error?: string;
}

export type TransactionPhase = "idle" | "wallet" | "submitted" | "confirming" | "confirmed" | "replaced" | "dropped" | "reverted" | "rejected" | "rpc-error";
export interface TransactionState { phase: TransactionPhase; hash?: Hex; message?: string }

export const LIFECYCLE_LABEL: Record<LaunchLifecycle, string> = {
  created: "Awaiting launch",
  trading: "Curve live",
  "graduation-ready": "Graduating",
  graduated: "AMM live",
};
