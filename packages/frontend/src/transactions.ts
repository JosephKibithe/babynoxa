import type { Hex } from "viem";
import type { TransactionState } from "./domain.js";

export function transactionError(error: unknown): TransactionState {
  const message = error instanceof Error ? error.message : String(error);
  const lower = message.toLowerCase();
  if (lower.includes("user rejected") || lower.includes("user denied") || lower.includes("4001")) return { phase:"rejected", message:"Request rejected in wallet." };
  if (lower.includes("revert")) return { phase:"reverted", message };
  if (lower.includes("replacement") || lower.includes("repriced")) return { phase:"replaced", message };
  if (lower.includes("dropped") || lower.includes("not found")) return { phase:"dropped", message:"Transaction was dropped. Refresh balances before retrying." };
  return { phase:"rpc-error", message:`RPC request failed: ${message}` };
}

export async function runTransaction(send: () => Promise<Hex>, confirm: (hash: Hex) => Promise<{ status: "success" | "reverted" }>, update: (state: TransactionState) => void): Promise<void> {
  update({ phase:"wallet", message:"Confirm in your wallet" });
  try {
    const hash = await send();
    update({ phase:"submitted", hash, message:"Transaction submitted" });
    update({ phase:"confirming", hash, message:"Waiting for confirmation" });
    const receipt = await confirm(hash);
    update(receipt.status === "success" ? { phase:"confirmed", hash, message:"Confirmed onchain" } : { phase:"reverted", hash, message:"Transaction reverted onchain" });
  } catch (error) { update(transactionError(error)); }
}
