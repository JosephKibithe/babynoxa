import { describe, expect, it } from "vitest";
import { applySlippage, isQuoteStale, quoteBuy, quoteSell } from "../src/quotes.js";

const ETHER=10n**18n;
describe("curve quote parity",()=>{
  it("applies the exact 1% floor fee and conservative token rounding",()=>{const quote=quoteBuy(1_425n*10n**15n,1_066_666_667n*ETHER,800_000_000n*ETHER,ETHER,100,1_000);expect(quote.fee).toBe(10n**16n);expect(quote.netBase).toBe(99n*10n**16n);expect(quote.minimumTokensOut).toBe(applySlippage(quote.tokensOut,100));expect(quote.tokensOut).toBeGreaterThan(0n)});
  it("quotes sells against real reserve and deducts the fee",()=>{const quote=quoteSell(2n*ETHER,700_000_000n*ETHER,ETHER,1_000_000n*ETHER,50);expect(quote.netBase).toBe(quote.grossBase-quote.fee);expect(quote.minimumBaseOut).toBe(applySlippage(quote.netBase,50))});
  it("expires quotes after the stale threshold",()=>{expect(isQuoteStale(1_000,20_999)).toBe(false);expect(isQuoteStale(1_000,21_001)).toBe(true)});
});
