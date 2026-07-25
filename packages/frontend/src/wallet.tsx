import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { createPublicClient, createWalletClient, custom, http, type Address, type EIP1193Provider, type Hex } from "viem";
import { defineChain } from "viem";
import { curveAbi, erc20Abi, factoryAbi, routerAbi } from "./abis.js";
import { contractsByChain, requireChainContracts, type ChainContracts } from "./config.js";
import type { ProjectRecord, TransactionState, WalletState } from "./domain.js";
import { deadlineFromNow } from "./quotes.js";
import { runTransaction } from "./transactions.js";

declare global { interface Window { ethereum?: EIP1193Provider } }

interface Eip6963Detail { info:{uuid:string;name:string;icon:string;rdns:string}; provider:EIP1193Provider }
/** Wallets discovered via EIP-6963 — the reliable way to tell wallets apart when several inject at once. */
const announcedProviders: Eip6963Detail[] = [];
if (typeof window !== "undefined") {
  window.addEventListener("eip6963:announceProvider", (event) => {
    const detail = (event as CustomEvent<Eip6963Detail>).detail;
    if (detail?.provider && !announcedProviders.some((existing) => existing.info.uuid === detail.info.uuid)) announcedProviders.push(detail);
  });
  window.dispatchEvent(new Event("eip6963:requestProvider"));
}

/**
 * Resolve the injected wallet. When multiple wallets are installed (e.g. Rabby hijacks
 * window.ethereum), prefer genuine MetaMask; otherwise fall back to whatever is injected.
 */
const injectedProvider = (): EIP1193Provider | undefined => {
  const metamask = announcedProviders.find((detail) => detail.info.rdns === "io.metamask");
  if (metamask) return metamask.provider;
  const ethereum = window.ethereum as (EIP1193Provider & { providers?: EIP1193Provider[] }) | undefined;
  if (ethereum?.providers?.length) return ethereum.providers.find((provider) => (provider as { isMetaMask?: boolean }).isMetaMask) ?? ethereum.providers[0];
  return ethereum ?? announcedProviders[0]?.provider;
};

interface LaunchWrite { name:string;symbol:string;metadataURI:string;metadataHash:Hex;minimumCreatorTokensOut:bigint;value:bigint }
export interface WalletPosition { virtualBase:bigint;virtualToken:bigint;realReserve:bigint;inventory:bigint;balance:bigint;allowance:bigint;refund:bigint;credit:bigint;creatorFees:bigint;treasuryFees:bigint }
interface WalletContextValue extends WalletState {
  connect():Promise<WalletState>; switchToSupported(state?:WalletState):Promise<WalletState>; submit(action:(account:Address,chainId:number)=>Promise<Hex>):Promise<void>;
  createLaunch(input:LaunchWrite):Promise<void>; buy(project:ProjectRecord,minOut:bigint,value:bigint):Promise<void>; approve(project:ProjectRecord,amount:bigint,spender?:Address):Promise<void>; sell(project:ProjectRecord,tokens:bigint,minBase:bigint):Promise<void>; claim(project:ProjectRecord,kind:"refund"|"credit"|"creator"|"treasury"):Promise<void>; ammBuy(project:ProjectRecord,minOut:bigint,value:bigint):Promise<void>; ammSell(project:ProjectRecord,tokens:bigint,minOut:bigint):Promise<void>;
  readPosition(project:ProjectRecord):Promise<WalletPosition>; quoteAmm(project:ProjectRecord,amount:bigint,side:"buy"|"sell"):Promise<bigint>;
  /** Native balance (POL/ETH) for the connected wallet on the active chain — used by buy % quick-fills. */
  readNativeBalance():Promise<bigint>;
  transaction:TransactionState;
}

const WalletContext = createContext<WalletContextValue | null>(null);
const demoAddress = `0x${"1".repeat(40)}` as Address;
const chainFor = (contracts: ChainContracts) => defineChain({
  id: contracts.chainId,
  name: contracts.name,
  nativeCurrency: { name: contracts.currency, symbol: contracts.currency, decimals: 18 },
  rpcUrls: { default: { http: [contracts.rpcUrl] } },
  ...(contracts.multicall3 ? { contracts: { multicall3: { address: contracts.multicall3 } } } : {}),
});

export function WalletProvider({children,demo=false}:{children:ReactNode;demo?:boolean}) {
  const [wallet,setWallet]=useState<WalletState>(demo?{status:"connected",address:demoAddress,chainId:31337}:{status:"disconnected"});
  const [transaction,setTransaction]=useState<TransactionState>({phase:"idle"});

  const readState=useCallback(async():Promise<WalletState|null>=>{ const ethereum=injectedProvider(); if(!ethereum)return null; const accounts=await ethereum.request({method:"eth_accounts"}) as Address[]; const raw=await ethereum.request({method:"eth_chainId"}) as string; const chainId=Number.parseInt(raw,16); const address=accounts[0]; return address?{address,chainId,status:contractsByChain.has(chainId)?"connected":"unsupported"}:{chainId,status:"disconnected"}; },[]);
  const sync=useCallback(async()=>{ if(demo)return; try{const state=await readState();if(state)setWallet(state);}catch{/* keep previous state on transient provider errors */} },[demo,readState]);
  useEffect(()=>{ void sync(); const ethereum=injectedProvider(); if(demo||!ethereum)return; const handler=()=>void sync(); ethereum.on?.("accountsChanged",handler); ethereum.on?.("chainChanged",handler); return()=>{ethereum.removeListener?.("accountsChanged",handler);ethereum.removeListener?.("chainChanged",handler);};},[demo,sync]);

  const switchToSupported=async(state?:WalletState):Promise<WalletState>=>{const current=state??wallet;if(demo)return current;const ethereum=injectedProvider();const contracts=[...contractsByChain.values()][0];if(!ethereum||!contracts)return current;const chainId=`0x${contracts.chainId.toString(16)}`;try{try{await ethereum.request({method:"wallet_switchEthereumChain",params:[{chainId}]});}catch(error){if((error as {code?:number}).code!==4902)throw error;await ethereum.request({method:"wallet_addEthereumChain",params:[{chainId,chainName:contracts.name,nativeCurrency:{name:contracts.currency,symbol:contracts.currency,decimals:18},rpcUrls:[contracts.rpcUrl],...(contracts.explorerUrl?{blockExplorerUrls:[contracts.explorerUrl]}:{})}]});}const next=(await readState())??current;setWallet(next);return next;}catch(error){const message=error instanceof Error?error.message:String(error);const base=(await readState().catch(()=>null))??current;const next={...base,error:message};setWallet(next);return next;}};
  const connect=async():Promise<WalletState>=>{ if(demo)return wallet; const ethereum=injectedProvider(); if(!ethereum){const next:WalletState={status:"disconnected",error:"No injected wallet found."};setWallet(next);return next;} setWallet({status:"connecting"}); try{await ethereum.request({method:"eth_requestAccounts"});let next=(await readState())??({status:"disconnected"} as WalletState);if(next.status==="unsupported")next=await switchToSupported(next);setWallet(next);return next;}catch(error){const next:WalletState={status:"disconnected",error:error instanceof Error?error.message:String(error)};setWallet(next);return next;} };
  const submit=async(action:(account:Address,chainId:number)=>Promise<Hex>)=>{let state:WalletState=wallet;if(!state.address||!state.chainId)state=await connect();if(state.address&&state.chainId&&!contractsByChain.has(state.chainId))state=await switchToSupported(state);if(!state.address||!state.chainId||!contractsByChain.has(state.chainId))return;const contracts=requireChainContracts(state.chainId);if(demo){await runTransaction(async()=>action(state.address!,state.chainId!),async()=>({status:"success"}),setTransaction);return;}const chain=chainFor(contracts);const publicClient=createPublicClient({chain,transport:http(contracts.rpcUrl)});await runTransaction(()=>action(state.address!,state.chainId!),async(hash)=>{const receipt=await publicClient.waitForTransactionReceipt({hash,timeout:120_000});return{status:receipt.status};},setTransaction);};
  const write=async(chainId:number,account:Address,parameters:Record<string,unknown>):Promise<Hex>=>{if(demo)return `0x${"f".repeat(64)}` as Hex;const ethereum=injectedProvider();if(!ethereum)throw new Error("Wallet unavailable");const contracts=requireChainContracts(chainId);return createWalletClient({account,chain:chainFor(contracts),transport:custom(ethereum)}).writeContract(parameters as never);};
  const publicFor=(chainId:number)=>{const contracts=requireChainContracts(chainId);return createPublicClient({chain:chainFor(contracts),transport:http(contracts.rpcUrl)});};
  const readPosition=async(p:ProjectRecord):Promise<WalletPosition>=>{if(demo){const inventory=BigInt(p.curve_inventory);const sold=800_000_000n*10n**18n-inventory;const virtualToken=1_066_666_667n*10n**18n-sold;const virtualBase=(1_425_000_000_000_000_000n*(1_066_666_667n*10n**18n)+virtualToken-1n)/virtualToken;return{virtualBase,virtualToken,realReserve:BigInt(p.real_reserve),inventory,balance:12_000_000n*10n**18n,allowance:2n**256n-1n,refund:25_000_000_000_000_000n,credit:15_000_000_000_000_000n,creatorFees:5_000_000_000_000_000n,treasuryFees:5_000_000_000_000_000n};}if(!wallet.chainId||!wallet.address)throw new Error("Connect wallet to read position");const client=publicFor(wallet.chainId);const contracts=requireChainContracts(wallet.chainId);const spender=p.lifecycle==="graduated"?contracts.router:p.curve;const calls=[{address:p.curve,abi:curveAbi,functionName:"virtualBaseReserve"},{address:p.curve,abi:curveAbi,functionName:"virtualTokenReserve"},{address:p.curve,abi:curveAbi,functionName:"realBaseReserve"},{address:p.curve,abi:curveAbi,functionName:"curveTokenInventory"},{address:p.token,abi:erc20Abi,functionName:"balanceOf",args:[wallet.address]},{address:p.token,abi:erc20Abi,functionName:"allowance",args:[wallet.address,spender]},{address:p.curve,abi:curveAbi,functionName:"claimableRefundOf",args:[wallet.address]},{address:p.curve,abi:curveAbi,functionName:"claimableBaseOf",args:[wallet.address]},{address:p.curve,abi:curveAbi,functionName:"creatorTradingFees"},{address:p.curve,abi:curveAbi,functionName:"treasuryTradingFees"}] as const;const results=contracts.multicall3?await client.multicall({allowFailure:false,contracts:calls}):await (Promise.all(calls.map((call)=>client.readContract(call as never))) as Promise<[bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint]>);return{virtualBase:results[0],virtualToken:results[1],realReserve:results[2],inventory:results[3],balance:results[4],allowance:results[5],refund:results[6],credit:results[7],creatorFees:results[8],treasuryFees:results[9]};};
  const quoteAmm=async(p:ProjectRecord,amount:bigint,side:"buy"|"sell")=>{if(demo)return amount*2n;if(!wallet.chainId)throw new Error("Connect wallet to quote");const contracts=requireChainContracts(wallet.chainId);const path=side==="buy"?[contracts.wrappedNative,p.token]:[p.token,contracts.wrappedNative];const amounts=await publicFor(wallet.chainId).readContract({address:contracts.router,abi:routerAbi,functionName:"getAmountsOut",args:[amount,path]});return amounts[amounts.length-1]??0n;};
  const readNativeBalance=async():Promise<bigint>=>{if(demo)return 5n*10n**18n;if(!wallet.chainId||!wallet.address)throw new Error("Connect wallet to read balance");return publicFor(wallet.chainId).getBalance({address:wallet.address});};

  const createLaunch=async(input:LaunchWrite)=>submit((account,chainId)=>{const contracts=requireChainContracts(chainId);return write(chainId,account,{account,address:contracts.factory,abi:factoryAbi,functionName:"createLaunch",args:[{name:input.name,symbol:input.symbol,metadataURI:input.metadataURI,metadataHash:input.metadataHash,minimumCreatorTokensOut:input.minimumCreatorTokensOut,deadline:deadlineFromNow()}],value:input.value});});
  const buy=async(p:ProjectRecord,minOut:bigint,value:bigint)=>submit((account,chainId)=>write(chainId,account,{account,address:p.curve,abi:curveAbi,functionName:"buy",args:[minOut,deadlineFromNow()],value}));
  const approve=async(p:ProjectRecord,amount:bigint,spender?:Address)=>submit((account,chainId)=>{const contracts=requireChainContracts(chainId);return write(chainId,account,{account,address:p.token,abi:erc20Abi,functionName:"approve",args:[spender??(p.lifecycle==="graduated"?contracts.router:p.curve),amount]});});
  const sell=async(p:ProjectRecord,tokens:bigint,minBase:bigint)=>submit((account,chainId)=>write(chainId,account,{account,address:p.curve,abi:curveAbi,functionName:"sell",args:[tokens,minBase,deadlineFromNow()]}));
  const claim=async(p:ProjectRecord,kind:"refund"|"credit"|"creator"|"treasury")=>submit((account,chainId)=>write(chainId,account,{account,address:p.curve,abi:curveAbi,functionName:kind==="refund"?"claimRefund":kind==="credit"?"claimBaseCredit":kind==="creator"?"claimCreatorFees":"claimTreasuryFees"}));
  const ammBuy=async(p:ProjectRecord,minOut:bigint,value:bigint)=>submit((account,chainId)=>{const contracts=requireChainContracts(chainId);return write(chainId,account,{account,address:contracts.router,abi:routerAbi,functionName:"swapExactETHForTokensSupportingFeeOnTransferTokens",args:[minOut,[contracts.wrappedNative,p.token],account,deadlineFromNow()],value});});
  const ammSell=async(p:ProjectRecord,tokens:bigint,minOut:bigint)=>submit((account,chainId)=>{const contracts=requireChainContracts(chainId);return write(chainId,account,{account,address:contracts.router,abi:routerAbi,functionName:"swapExactTokensForETHSupportingFeeOnTransferTokens",args:[tokens,minOut,[p.token,contracts.wrappedNative],account,deadlineFromNow()]});});
  const value=useMemo<WalletContextValue>(()=>({...wallet,connect,switchToSupported,submit,createLaunch,buy,approve,sell,claim,ammBuy,ammSell,readPosition,quoteAmm,readNativeBalance,transaction}),[wallet,transaction]);
  return <WalletContext.Provider value={value}>{children}</WalletContext.Provider>;
}

export function useWallet(){const value=useContext(WalletContext);if(!value)throw new Error("WalletProvider missing");return value;}
