import type { Address } from "viem";

export interface ChainContracts {
  chainId: number;
  name: string;
  currency: string;
  rpcUrl: string;
  explorerUrl?: string;
  factory: Address;
  router: Address;
  wrappedNative: Address;
  manager: Address;
  /** Canonical Multicall3 address, when deployed on the chain. Enables batched reads via viem multicall. */
  multicall3?: Address;
}

/** Multicall3 is deployed at the same canonical address on most public chains, including Polygon and Amoy. */
export const CANONICAL_MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";

const local: ChainContracts = {
  chainId: 31337,
  name: "Anvil",
  currency: "ETH",
  rpcUrl: import.meta.env.VITE_LOCAL_RPC_URL ?? "http://127.0.0.1:8545",
  factory: "0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9",
  router: "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  wrappedNative: "0x5FbDB2315678afecb367f032d93F642f64180aa3",
  manager: "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
};

const amoyFactory = import.meta.env.VITE_AMOY_FACTORY as Address | undefined;
const amoyRouter = import.meta.env.VITE_AMOY_ROUTER as Address | undefined;
const amoyWrapped = import.meta.env.VITE_AMOY_WRAPPED_NATIVE as Address | undefined;
const amoyManager = import.meta.env.VITE_AMOY_MANAGER as Address | undefined;

const mainnetFactory = import.meta.env.VITE_POLYGON_MAINNET_FACTORY as Address | undefined;
const mainnetRouter = import.meta.env.VITE_POLYGON_MAINNET_ROUTER as Address | undefined;
const mainnetWrapped = import.meta.env.VITE_POLYGON_MAINNET_WRAPPED_NATIVE as Address | undefined;
const mainnetManager = import.meta.env.VITE_POLYGON_MAINNET_MANAGER as Address | undefined;

export const contractsByChain = new Map<number, ChainContracts>([
  ...(mainnetFactory && mainnetRouter && mainnetWrapped && mainnetManager ? [[137, {
    chainId: 137,
    name: "Polygon",
    currency: "POL",
    rpcUrl: import.meta.env.VITE_POLYGON_MAINNET_RPC_URL ?? "https://polygon.gateway.tenderly.co",
    explorerUrl: "https://polygonscan.com",
    factory: mainnetFactory,
    router: mainnetRouter,
    wrappedNative: mainnetWrapped,
    manager: mainnetManager,
    multicall3: CANONICAL_MULTICALL3,
  } satisfies ChainContracts] as const] : []),
  [local.chainId, local],
  ...(amoyFactory && amoyRouter && amoyWrapped && amoyManager ? [[80002, {
    chainId: 80002,
    name: "Polygon Amoy",
    currency: "POL",
    rpcUrl: import.meta.env.VITE_AMOY_RPC_URL ?? "https://rpc-amoy.polygon.technology",
    explorerUrl: "https://amoy.polygonscan.com",
    factory: amoyFactory,
    router: amoyRouter,
    wrappedNative: amoyWrapped,
    manager: amoyManager,
    multicall3: CANONICAL_MULTICALL3,
  } satisfies ChainContracts] as const] : []),
]);

export const API_URL = (import.meta.env.VITE_API_URL as string | undefined) ?? "http://127.0.0.1:3000";
export const supportedChainIds = [...contractsByChain.keys()];

export function nativeCurrencyFor(chainId: number | undefined): string {
  return (chainId === undefined ? undefined : contractsByChain.get(chainId))?.currency
    ?? contractsByChain.values().next().value?.currency
    ?? "NATIVE";
}

export function requireChainContracts(chainId: number | undefined): ChainContracts {
  const contracts = chainId === undefined ? undefined : contractsByChain.get(chainId);
  if (!contracts) throw new Error(`Unsupported network. Switch to ${[...contractsByChain.values()].map((chain) => chain.name).join(" or ")}.`);
  return contracts;
}
