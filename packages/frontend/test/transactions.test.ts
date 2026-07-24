import { describe,expect,it,vi } from "vitest";
import { runTransaction,transactionError } from "../src/transactions.js";

const hash=`0x${"1".repeat(64)}` as const;
describe("wallet transaction states",()=>{
  it.each([["User rejected request","rejected"],["execution reverted","reverted"],["replacement underpriced","replaced"],["transaction dropped","dropped"],["network offline","rpc-error"]] as const)("classifies %s",(message,phase)=>expect(transactionError(new Error(message)).phase).toBe(phase));
  it("reports wallet, submission, confirmation and success",async()=>{const update=vi.fn();await runTransaction(async()=>hash,async()=>({status:"success"}),update);expect(update.mock.calls.map(call=>call[0].phase)).toEqual(["wallet","submitted","confirming","confirmed"])});
});
