import { useEffect, useMemo, useState } from "react";
import { formatEther, formatUnits, parseEther, parseUnits } from "viem";
import type { BackendClient } from "../api.js";
import { demoBackend } from "../api.js";
import { Button, CopyButton, EmptyState, Field, TransactionBanner, compactNumber, short, timeAgo } from "../components.js";
import { nativeCurrencyFor } from "../config.js";
import { type LaunchDetail, type ProjectRecord } from "../domain.js";
import { addressUrl, externalMarketLinks, txUrl } from "../links.js";
import { applySlippage, isQuoteStale, quoteBuy, quoteSell, type BuyQuote, type SellQuote } from "../quotes.js";
import { useWallet, type WalletPosition } from "../wallet.js";

const emptyPosition:WalletPosition={virtualBase:0n,virtualToken:0n,realReserve:0n,inventory:0n,balance:0n,allowance:0n,refund:0n,credit:0n,creatorFees:0n,treasuryFees:0n};
const normalizeId=()=>window.location.pathname.split("/").filter(Boolean)[1]??"1";
const TOTAL_SUPPLY=1_000_000_000n*10n**18n;
const TOTAL_SUPPLY_TOKENS=1_000_000_000;
const venueName=(project:ProjectRecord)=>project.chain_id===137?"QuickSwap V2":"V2 AMM";
const formatPrice=(price:number)=>price<=0?"—":price<1e-4?price.toExponential(2):price.toLocaleString(undefined,{maximumFractionDigits:6});
const formatMcap=(value:number,currency:string)=>{
  if(value<=0)return "—";
  if(value>=1_000_000)return `${(value/1_000_000).toFixed(2)}M ${currency}`;
  if(value>=1_000)return `${(value/1_000).toFixed(2)}k ${currency}`;
  if(value>=1)return `${value.toFixed(2)} ${currency}`;
  return `${value.toExponential(2)} ${currency}`;
};
const tradePrice=(tokenAmount:string,grossBase:string)=>{
  const tokens=Number(formatUnits(BigInt(tokenAmount),18));
  const base=Number(formatEther(BigInt(grossBase)));
  return tokens>0?base/tokens:0;
};
type ChartWindow="5m"|"1h"|"6h"|"1d"|"all";
const WINDOW_SECONDS:Record<Exclude<ChartWindow,"all">,number>={ "5m":300,"1h":3_600,"6h":21_600,"1d":86_400 };
const WINDOW_LABEL:Record<ChartWindow,string>={ "5m":"5M","1h":"1H","6h":"6H","1d":"1D",all:"ALL" };

function MarketChart({detail,position,currency,progress}:{detail:LaunchDetail;position:WalletPosition;currency:string;progress:number}){
  const[window,setWindow]=useState<ChartWindow>("all");
  const now=Math.floor(Date.now()/1000);
  const cutoff=window==="all"?0:now-WINDOW_SECONDS[window];
  const points=useMemo(()=>detail.trades
    .filter(trade=>trade.timestamp>=cutoff)
    .map(trade=>{const price=tradePrice(trade.token_amount,trade.gross_base);return{timestamp:trade.timestamp,price,mcap:price*TOTAL_SUPPLY_TOKENS,side:trade.side};})
    .filter(point=>point.price>0),[detail.trades,cutoff]);

  const lastTrade=detail.trades.length?detail.trades[detail.trades.length-1]:undefined;
  const spotPrice=lastTrade?tradePrice(lastTrade.token_amount,lastTrade.gross_base)
    :position.virtualToken>0n?Number(formatEther(position.virtualBase*10n**18n/position.virtualToken)):0;
  const marketCap=spotPrice*TOTAL_SUPPLY_TOKENS;
  const windowStart=points[0]?.mcap??0;
  const windowEnd=points.length?points[points.length-1]!.mcap:marketCap;
  const changePct=windowStart>0?((windowEnd-windowStart)/windowStart)*100:undefined;
  const volume=Number(formatEther(BigInt(detail.metrics.volume)));

  const n=points.length;
  const values=points.map(point=>point.mcap);
  const hi=values.length?Math.max(...values):marketCap||1;
  const lo=values.length?Math.min(...values):0;
  const span=hi-lo||hi||1;
  const x=(index:number)=>n<=1?300:index/(n-1)*600;
  const y=(value:number)=>150-((value-lo)/span)*128;
  const line=n?points.map((point,index)=>`${index?"L":"M"} ${x(index).toFixed(1)} ${y(point.mcap).toFixed(1)}`).join(" "):"";
  const area=n?`M0 160 ${points.map((point,index)=>`L ${x(index).toFixed(1)} ${y(point.mcap).toFixed(1)}`).join(" ")} L600 160Z`:"";
  const positive=changePct===undefined||changePct>=0;

  return <section className="market-card">
    <div className="metric-strip">
      <div><span>Market cap</span><strong>{formatMcap(marketCap,currency)}</strong></div>
      <div><span>Real reserve</span><strong>{Number(formatEther(BigInt(detail.project.real_reserve))).toFixed(4)} {currency}</strong></div>
      <div><span>Volume</span><strong>{volume.toLocaleString(undefined,{maximumFractionDigits:3})} {currency}</strong></div>
      <div><span>Graduation</span><strong>{progress.toFixed(1)}%</strong><small>{detail.project.lifecycle==="graduated"?"LP burned":"curve sold"}</small></div>
    </div>
    <div className="chart-head">
      <div>
        <strong className="chart-hero">{formatMcap(marketCap,currency)}</strong>
        <p className={`chart-change ${positive?"up":"down"}`}>
          {changePct===undefined?"—":`${changePct>=0?"+":""}${changePct.toFixed(2)}%`}
          <span>{WINDOW_LABEL[window]}</span>
        </p>
      </div>
      <div className="timeframe" role="group" aria-label="Chart timeframe">
        {(Object.keys(WINDOW_LABEL) as ChartWindow[]).map(key=>(
          <button key={key} type="button" className={window===key?"active":""} onClick={()=>setWindow(key)}>{WINDOW_LABEL[key]}</button>
        ))}
      </div>
    </div>
    {n?<div className="chart" aria-label={`Market cap across ${n} trades`}>
      <svg role="img" viewBox="0 0 600 166" preserveAspectRatio="none">
        <title>Market cap over time</title>
        <defs>
          <linearGradient id="chart-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor={positive?"#65d6a1":"#ff5a58"} stopOpacity=".38"/>
            <stop offset="1" stopColor={positive?"#65d6a1":"#ff5a58"} stopOpacity="0"/>
          </linearGradient>
        </defs>
        <path className={`chart-area ${positive?"":"down"}`} d={area}/>
        <path className={`chart-line ${positive?"":"down"}`} d={line}/>
        {points.map((point,index)=><circle key={`${point.timestamp}-${index}`} cx={x(index).toFixed(1)} cy={y(point.mcap).toFixed(1)} r="2.6" className={`dot ${point.side}`}/>)}
      </svg>
      <div className="chart-axis"><span>high {formatMcap(hi,currency)}</span><span>low {formatMcap(lo,currency)}</span></div>
    </div>:<EmptyState title="No chart data yet" copy="The chart plots market cap from confirmed curve and AMM trades once the first swap lands."/>}
  </section>;
}

function MarketLinks({project}:{project:ProjectRecord}){
  const graduated=project.lifecycle==="graduated";
  const contract=addressUrl(project.chain_id,project.token);
  const pool=addressUrl(project.chain_id,project.official_pair);
  const links=[...(contract?[{label:"Contract",href:contract}]:[]),...(pool?[{label:"Pool",href:pool}]:[]),...externalMarketLinks(project.chain_id,project.token,project.official_pair,graduated)];
  if(!links.length)return null;
  return <div className="market-links">{links.map(link=><a key={link.label} className="market-link" href={link.href} target="_blank" rel="noreferrer">{link.label} ↗</a>)}</div>;
}

function MetadataHeader({project}:{project:ProjectRecord}){
  const metadata=project.metadata;
  const socials=[metadata?.website&&{label:"Website",href:metadata.website},metadata?.twitter&&{label:"X",href:metadata.twitter},metadata?.telegram&&{label:"Telegram",href:metadata.telegram},metadata?.discord&&{label:"Discord",href:metadata.discord}].filter(Boolean) as Array<{label:string;href:string}>;
  const creatorHref=addressUrl(project.chain_id,project.creator);
  return <section className="token-hero-card">
    <div className="token-hero-top">
      <div className="token-avatar large">{metadata?.image?<img src={metadata.image} alt=""/>:metadata?.symbol?.slice(0,2)??"NX"}</div>
      <div className="token-hero-identity">
        <h1>{metadata?.name??`Launch #${project.launch_id}`}</h1>
        <p className="token-ticker">${metadata?.symbol??short(project.token)}</p>
      </div>
    </div>
    <div className="token-hero-body">
      <p className="token-hero-desc">{metadata?.description??"Metadata is committed onchain and awaiting public gateway resolution."}</p>
      <div className="token-hero-meta">
        {creatorHref?<a href={creatorHref} target="_blank" rel="noreferrer">Creator <code>{short(project.creator)}</code></a>:<span>Creator <code>{short(project.creator)}</code></span>}
        <span className="token-addr">Token <code>{short(project.token)}</code><CopyButton value={project.token} label="token address"/></span>
        {socials.map(social=><a key={social.label} href={social.href} target="_blank" rel="noreferrer">{social.label} ↗</a>)}
      </div>
      <MarketLinks project={project}/>
    </div>
  </section>;
}

function TradingPanel({project,position,reload,demo}:{project:ProjectRecord;position:WalletPosition;reload:()=>Promise<void>;demo:boolean}){
  const wallet=useWallet();
  const currency=nativeCurrencyFor(project.chain_id);
  const[side,setSide]=useState<"buy"|"sell">("buy");
  const[amount,setAmount]=useState("");
  const[slippage,setSlippage]=useState(100);
  const[clock,setClock]=useState(Date.now());
  const[ammQuote,setAmmQuote]=useState<bigint>();
  const[nativeBalance,setNativeBalance]=useState(0n);
  const PERCENTS=[25,50,75,100] as const;
  // Leave a small gas buffer on 100% buys so the wallet can still pay the tx fee.
  const BUY_GAS_BUFFER=10n**16n; // 0.01 native

  useEffect(()=>{const timer=setInterval(()=>setClock(Date.now()),1000);return()=>clearInterval(timer)},[]);
  useEffect(()=>{
    if(!wallet.address){setNativeBalance(0n);return;}
    let live=true;
    void wallet.readNativeBalance().then(value=>{if(live)setNativeBalance(value)}).catch(()=>{if(live)setNativeBalance(0n)});
    return()=>{live=false};
  },[wallet.address,wallet.chainId,wallet.transaction.phase]);

  const curveQuote=useMemo<BuyQuote|SellQuote|undefined>(()=>{
    if(!amount||project.lifecycle==="graduated")return;
    try{return side==="buy"?quoteBuy(position.virtualBase,position.virtualToken,position.inventory,parseEther(amount),slippage):quoteSell(position.virtualBase,position.virtualToken,position.realReserve,parseUnits(amount,18),slippage)}
    catch{return undefined}
  },[amount,project.lifecycle,side,slippage,position]);

  useEffect(()=>{
    setAmmQuote(undefined);
    if(project.lifecycle!=="graduated"||!amount)return;
    let live=true;
    const parsed=side==="buy"?parseEther(amount):parseUnits(amount,18);
    void wallet.quoteAmm(project,parsed,side).then(value=>{if(live)setAmmQuote(value)}).catch(()=>{});
    return()=>{live=false};
  },[amount,project,side,wallet.chainId]);

  const stale=curveQuote?isQuoteStale(curveQuote.quotedAt,clock):false;
  const expected=project.lifecycle==="graduated"?ammQuote:side==="buy"?(curveQuote as BuyQuote|undefined)?.tokensOut:(curveQuote as SellQuote|undefined)?.netBase;
  const available=side==="buy"?nativeBalance:position.balance;
  const availableLabel=side==="buy"
    ? `${Number(formatEther(nativeBalance)).toLocaleString(undefined,{maximumFractionDigits:4})} ${currency}`
    : `${Number(formatUnits(position.balance,18)).toLocaleString(undefined,{maximumFractionDigits:2})} ${project.metadata?.symbol??"TOKEN"}`;

  const applyPercent=(bps:number)=>{
    if(!wallet.address){void wallet.connect();return;}
    if(side==="buy"){
      const spendable=nativeBalance>BUY_GAS_BUFFER?nativeBalance-BUY_GAS_BUFFER:0n;
      const value=spendable*BigInt(bps)/100n;
      setAmount(value>0n?formatEther(value):"");
      return;
    }
    const value=position.balance*BigInt(bps)/100n;
    setAmount(value>0n?formatUnits(value,18):"");
  };

  const execute=async()=>{
    if(!wallet.address){await wallet.connect();return;}
    if(!amount||!expected)return;
    if(project.lifecycle==="graduated"){
      const minimum=applySlippage(expected,slippage);
      if(side==="buy")await wallet.ammBuy(project,minimum,parseEther(amount));
      else{const tokens=parseUnits(amount,18);if(position.allowance<tokens)await wallet.approve(project,tokens);await wallet.ammSell(project,tokens,minimum);}
    }else if(side==="buy")await wallet.buy(project,(curveQuote as BuyQuote).minimumTokensOut,parseEther(amount));
    else{const tokens=parseUnits(amount,18);if(position.allowance<tokens){await wallet.approve(project,tokens);return;}await wallet.sell(project,tokens,(curveQuote as SellQuote).minimumBaseOut);}
    if(demo){await demoBackend.trade(project.launch_id,side);}
    await reload();
  };

  return <aside className="trade-panel">
    <div className="trade-mode">
      <button className={side==="buy"?"active":""} onClick={()=>setSide("buy")}>Buy</button>
      <button className={side==="sell"?"active":""} onClick={()=>setSide("sell")}>Sell</button>
    </div>
    <div className="venue"><span>{project.lifecycle==="graduated"?venueName(project):"BabyNoxa curve"}</span><strong>{project.lifecycle==="graduated"?"Permissionless":"1% fee"}</strong></div>
    <Field label={side==="buy"?"You pay":"You sell"}>
      <div className="amount-input large">
        <input aria-label={side==="buy"?"Buy amount":"Sell amount"} inputMode="decimal" value={amount} onChange={event=>setAmount(event.target.value)} placeholder="0.00"/>
        <span>{side==="buy"?currency:project.metadata?.symbol??"TOKEN"}</span>
      </div>
    </Field>
    <div className="balance-row">
      <span>Available {wallet.address?availableLabel:"—"}</span>
    </div>
    <div className={`percent-row side-${side}`} role="group" aria-label="Quick amount">
      {PERCENTS.map(pct=><button key={pct} type="button" className="percent-btn" disabled={wallet.address?!available:false} onClick={()=>applyPercent(pct)}>{pct}%</button>)}
    </div>
    <div className="quote-box">
      <div><span>Expected output</span><strong>{expected?side==="buy"?`${Number(formatUnits(expected,18)).toLocaleString(undefined,{maximumFractionDigits:2})} tokens`:`${Number(formatEther(expected)).toFixed(6)} ${currency}`:"—"}</strong></div>
      <div><span>Slippage</span><select aria-label="Slippage tolerance" value={slippage} onChange={event=>setSlippage(Number(event.target.value))}><option value="50">0.5%</option><option value="100">1.0%</option><option value="200">2.0%</option></select></div>
      {curveQuote&&"fee"in curveQuote&&<div><span>Protocol fee</span><strong>{formatEther(curveQuote.fee)} {currency}</strong></div>}
      <div><span>Quote status</span><strong className={stale?"negative":"positive"}>{stale?"Stale — refresh amount":"Fresh"}</strong></div>
    </div>
    {side==="sell"&&position.allowance<(amount?parseUnits(amount,18):0n)&&project.lifecycle!=="graduated"&&<p className="callout">Approval is required first. The sell remains a separate wallet confirmation.</p>}
    <Button className={`primary wide ${!wallet.address||side==="buy"?"side-buy":"side-sell"}`} disabled={!expected||stale||wallet.transaction.phase==="confirming"} onClick={()=>void execute()}>{!wallet.address?"Connect wallet":side==="sell"&&position.allowance<(amount?parseUnits(amount,18):0n)?"Approve token":`${side==="buy"?"Buy":"Sell"} on ${project.lifecycle==="graduated"?"AMM":"curve"}`}</Button>
    {demo&&project.lifecycle!=="graduated"&&<button className="demo-action" onClick={()=>{demoBackend.graduate(project.launch_id);void reload()}}>Complete curve (demo)</button>}
    <TransactionBanner state={wallet.transaction}/>
  </aside>;
}
function Holders({detail}:{detail:LaunchDetail}){
  if(!detail.holders.length)return null;
  const rows=detail.holders.slice().sort((a,b)=>BigInt(b.balance)>BigInt(a.balance)?1:BigInt(b.balance)<BigInt(a.balance)?-1:0).slice(0,10);
  return <section><div className="section-head"><div><p className="eyebrow">Distribution</p><h2>Top holders</h2></div><span>{detail.holders.length} holders</span></div><div className="holder-list"><div className="holder-head"><span>#</span><span>Holder</span><span>Balance</span><span>Share</span></div>{rows.map((holder,index)=>{const share=Number(BigInt(holder.balance)*10_000n/TOTAL_SUPPLY)/100;return <div key={holder.holder}><span>{index+1}</span><code>{short(holder.holder)}</code><strong>{compactNumber(BigInt(holder.balance))}</strong><span>{share.toFixed(2)}%</span></div>;})}</div></section>;
}

function SwapList({detail,currency}:{detail:LaunchDetail;currency:string}){
  if(!detail.trades.length)return <EmptyState title="No swaps yet" copy="Trades will appear here once the first confirmed swap lands."/>;
  const rows=detail.trades.slice().reverse();
  return <div className="trade-list swaps"><div className="trade-head"><span>Type</span><span>Tokens</span><span>{currency}</span><span>Price</span><span>Time</span><span>Txn</span></div>{rows.map(trade=>{const tokens=Number(formatUnits(BigInt(trade.token_amount),18));const base=Number(formatEther(BigInt(trade.gross_base)));const price=tokens>0?base/tokens:0;const link=txUrl(detail.project.chain_id,trade.transaction_hash);return <div key={`${trade.transaction_hash}-${trade.timestamp}`}><span className={trade.side}>{trade.side}</span><strong>{tokens.toLocaleString(undefined,{maximumFractionDigits:1})}</strong><span>{base.toFixed(4)}</span><span>{formatPrice(price)}</span><span className="muted">{timeAgo(trade.timestamp)}</span>{link?<a className={`tx-link ${trade.side}`} href={link} target="_blank" rel="noreferrer"><code>{short(trade.transaction_hash)}</code></a>:<code className={`tx-link ${trade.side}`}>{short(trade.transaction_hash)}</code>}</div>;})}</div>;
}

export function TokenPage({client,demo}:{client:BackendClient;demo:boolean}){const id=normalizeId();const wallet=useWallet();const[detail,setDetail]=useState<LaunchDetail>();const[position,setPosition]=useState(emptyPosition);const[error,setError]=useState<string>();const load=async()=>{try{const result=await client.launch(id);setDetail(result);setError(undefined);if(wallet.address)setPosition(await wallet.readPosition(result.project));}catch(reason){setError(reason instanceof Error?reason.message:String(reason))}};useEffect(()=>{void load()},[id,wallet.address,wallet.transaction.phase]);if(error)return <EmptyState title="Market unavailable" copy={error}/>;if(!detail)return <div className="token-loading skeleton"/>;const p=detail.project;const currency=nativeCurrencyFor(p.chain_id);const progress=detail.metrics.progressBps/100;return <><MetadataHeader project={p}/><div className="market-layout"><div className="market-content"><MarketChart detail={detail} position={position} currency={currency} progress={progress}/><section><div className="section-head"><div><p className="eyebrow">Indexer data</p><h2>Swaps</h2></div><span>{detail.metrics.tradeCount} trades · {Number(formatEther(BigInt(detail.metrics.volume))).toFixed(3)} {currency}</span></div><SwapList detail={detail} currency={currency}/></section><Holders detail={detail}/></div><TradingPanel project={p} position={position} reload={load} demo={demo}/></div></>}
