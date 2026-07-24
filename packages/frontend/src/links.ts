import type { Address } from "viem";
import { contractsByChain } from "./config.js";

/** Block-explorer base URL for a chain, when one is configured (undefined for local Anvil). */
export const explorerFor = (chainId: number): string | undefined => contractsByChain.get(chainId)?.explorerUrl;

export const addressUrl = (chainId: number, address: string): string | undefined => {
  const base = explorerFor(chainId);
  return base ? `${base}/address/${address}` : undefined;
};

export const txUrl = (chainId: number, hash: string): string | undefined => {
  const base = explorerFor(chainId);
  return base ? `${base}/tx/${hash}` : undefined;
};

export interface MarketLink { label: string; href: string }

/**
 * External market-aggregator links for a launch. These are Polygon PoS (137) products, so
 * they are only produced for mainnet launches. Pre-graduation the token has no public pool,
 * so DexScreener/GeckoTerminal are keyed on the token until the official pair carries liquidity.
 */
export function externalMarketLinks(
  chainId: number,
  token: Address,
  officialPair: Address,
  graduated: boolean,
): MarketLink[] {
  if (chainId !== 137) return [];
  const poolRef = graduated ? officialPair : token;
  return [
    { label: "DexScreener", href: `https://dexscreener.com/polygon/${poolRef}` },
    { label: "GeckoTerminal", href: `https://www.geckoterminal.com/polygon_pos/pools/${officialPair}` },
    { label: "QuickSwap", href: `https://quickswap.exchange/#/swap?outputCurrency=${token}` },
  ];
}
