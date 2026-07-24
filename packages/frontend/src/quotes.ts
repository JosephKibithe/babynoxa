export const BPS = 10_000n;
export const TRADE_FEE_BPS = 100n;
export const CURVE_ALLOCATION = 800_000_000n * 10n ** 18n;
export const CREATOR_CAP = 20_000_000n * 10n ** 18n;
export const QUOTE_TTL_MS = 20_000;

const ceilDiv = (numerator: bigint, denominator: bigint) => (numerator + denominator - 1n) / denominator;

export interface BuyQuote {
  grossBase: bigint;
  grossBaseUsed: bigint;
  refund: bigint;
  fee: bigint;
  netBase: bigint;
  tokensOut: bigint;
  minimumTokensOut: bigint;
  completesCurve: boolean;
  quotedAt: number;
}

export interface SellQuote {
  tokensIn: bigint;
  grossBase: bigint;
  fee: bigint;
  netBase: bigint;
  minimumBaseOut: bigint;
  quotedAt: number;
}

const feeFor = (gross: bigint) => gross * TRADE_FEE_BPS / BPS;
export const applySlippage = (amount: bigint, slippageBps: number) => amount * (BPS - BigInt(slippageBps)) / BPS;

export function quoteBuy(virtualBase: bigint, virtualToken: bigint, inventory: bigint, gross: bigint, slippageBps: number, now = Date.now()): BuyQuote {
  if (virtualBase <= 0n || virtualToken <= inventory || inventory <= 0n || gross < 200n) throw new Error("Buy amount is below the 200 wei minimum or reserves are unavailable.");
  const fullFee = feeFor(gross);
  const net = gross - fullFee;
  const candidateBase = virtualBase + net;
  const candidateToken = ceilDiv(virtualBase * virtualToken, candidateBase);
  const candidateOut = virtualToken - candidateToken;
  if (candidateOut <= 0n) throw new Error("Amount is too small to return tokens.");
  if (candidateOut < inventory) return { grossBase:gross, grossBaseUsed:gross, refund:0n, fee:fullFee, netBase:net, tokensOut:candidateOut, minimumTokensOut:applySlippage(candidateOut,slippageBps), completesCurve:false, quotedAt:now };
  const finalToken = virtualToken - inventory;
  const finalBase = ceilDiv(virtualBase * virtualToken, finalToken);
  const requiredNet = finalBase - virtualBase;
  const used = requiredNet + requiredNet * TRADE_FEE_BPS / (BPS - TRADE_FEE_BPS);
  if (used > gross) throw new Error("Insufficient amount to complete the curve.");
  return { grossBase:gross, grossBaseUsed:used, refund:gross-used, fee:feeFor(used), netBase:requiredNet, tokensOut:inventory, minimumTokensOut:applySlippage(inventory,slippageBps), completesCurve:true, quotedAt:now };
}

export function quoteSell(virtualBase: bigint, virtualToken: bigint, realReserve: bigint, tokens: bigint, slippageBps: number, now = Date.now()): SellQuote {
  if (tokens <= 0n) throw new Error("Enter tokens to sell.");
  const newVirtualBase = ceilDiv(virtualBase * virtualToken, virtualToken + tokens);
  const gross = virtualBase - newVirtualBase;
  if (gross < 200n || gross > realReserve) throw new Error("Sell is below the minimum or exceeds available reserve.");
  const fee = feeFor(gross);
  const net = gross - fee;
  return { tokensIn:tokens, grossBase:gross, fee, netBase:net, minimumBaseOut:applySlippage(net,slippageBps), quotedAt:now };
}

export const isQuoteStale = (quotedAt: number, now = Date.now()) => now - quotedAt > QUOTE_TTL_MS;
export const deadlineFromNow = (minutes = 10, now = Date.now()) => BigInt(Math.floor(now / 1_000) + minutes * 60);
