export interface BackendConfig {
  chainId: number;
  deploymentBlock: bigint;
  factoryAddress: `0x${string}`;
  /** Wrapped-native (e.g. WPOL) address; required to classify post-graduation AMM swaps as buys/sells. */
  wrappedNative?: `0x${string}`;
  databasePath: string;
  adminToken: string;
  confirmations: number;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BackendConfig {
  const chainId = Number(env.CHAIN_ID);
  const deploymentBlock = BigInt(env.DEPLOYMENT_BLOCK ?? "0");
  const factoryAddress = env.FACTORY_ADDRESS ?? "";
  const wrappedNative = env.WRAPPED_NATIVE ?? "";
  const confirmations = Number(env.CONFIRMATIONS ?? "12");
  if (!Number.isSafeInteger(chainId) || chainId <= 0) throw new Error("CHAIN_ID must be a positive integer");
  if (!/^0x[0-9a-fA-F]{40}$/.test(factoryAddress)) throw new Error("FACTORY_ADDRESS must be a 20-byte hex address");
  if (wrappedNative && !/^0x[0-9a-fA-F]{40}$/.test(wrappedNative)) throw new Error("WRAPPED_NATIVE must be a 20-byte hex address");
  if (!env.DATABASE_PATH) throw new Error("DATABASE_PATH is required");
  if (!env.ADMIN_TOKEN || env.ADMIN_TOKEN.length < 16) throw new Error("ADMIN_TOKEN must contain at least 16 characters");
  if (!Number.isSafeInteger(confirmations) || confirmations < 0) throw new Error("CONFIRMATIONS must be a nonnegative integer");
  return { chainId, deploymentBlock, factoryAddress: factoryAddress as `0x${string}`, ...(wrappedNative ? { wrappedNative: wrappedNative as `0x${string}` } : {}), databasePath: env.DATABASE_PATH, adminToken: env.ADMIN_TOKEN, confirmations };
}
