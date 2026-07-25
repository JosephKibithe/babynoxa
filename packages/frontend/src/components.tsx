import { useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import { formatEther } from "viem";
import { LIFECYCLE_LABEL, type ProjectRecord, type TransactionState } from "./domain.js";
import { addressUrl, txUrl } from "./links.js";
import { useWallet } from "./wallet.js";

export const short = (value?: string) => value ? `${value.slice(0,6)}…${value.slice(-4)}` : "—";
export const compactNumber = (value: bigint, decimals=18) => new Intl.NumberFormat("en",{notation:"compact",maximumFractionDigits:2}).format(Number(value/10n**BigInt(decimals)));

export const timeAgo = (timestamp: number) => {
  const seconds = Math.max(0, Math.floor(Date.now()/1000) - timestamp);
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds/60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes/60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours/24)}d ago`;
};

export function CopyButton({value,label="value"}:{value:string;label?:string}){
  const [copied,setCopied]=useState(false);
  const copy=async()=>{try{await navigator.clipboard.writeText(value);setCopied(true);setTimeout(()=>setCopied(false),1200);}catch{/* clipboard unavailable */}};
  return <button type="button" className={`copy-btn ${copied?"copied":""}`} onClick={()=>void copy()} aria-label={`Copy ${label}`}>{copied?"Copied":"Copy"}</button>;
}

/** A labelled on-chain address with truncated value, copy control, and an explorer link when available. */
export function AddressRow({label,value,chainId,kind="address"}:{label:string;value:string;chainId:number;kind?:"address"|"tx"}){
  const href=kind==="tx"?txUrl(chainId,value):addressUrl(chainId,value);
  return <div className="addr-row"><dt>{label}</dt><dd><code>{short(value)}</code><CopyButton value={value} label={label}/>{href&&<a href={href} target="_blank" rel="noreferrer">Explorer ↗</a>}</dd></div>;
}

export function Icon({name}:{name:"discover"|"create"|"portfolio"|"arrow"|"wallet"|"shield"}) {
  const paths={discover:"M4 6h16M4 12h10M4 18h13",create:"M12 5v14M5 12h14",portfolio:"M4 7h16v11H4zM16 11h4",arrow:"M5 12h14m-5-5 5 5-5 5",wallet:"M3 6h16v13H3zM16 11h4v4h-4z",shield:"M12 3l8 4v5c0 5-3.4 8-8 9-4.6-1-8-4-8-9V7z"};
  return <svg aria-hidden="true" viewBox="0 0 24 24"><path d={paths[name]} /></svg>;
}

export function Button({children,className="",...props}:ButtonHTMLAttributes<HTMLButtonElement>){return <button className={`button ${className}`} {...props}>{children}</button>;}

export function WalletButton(){const wallet=useWallet();const button=wallet.status==="unsupported"?<Button onClick={()=>void wallet.switchToSupported()}>Switch network</Button>:<Button className="wallet-button" onClick={()=>void wallet.connect()}><Icon name="wallet"/><span>{wallet.address?short(wallet.address):wallet.status==="connecting"?"Connecting…":"Connect wallet"}</span></Button>;return <span className="wallet-control">{button}{wallet.error&&<small className="error" role="alert">{wallet.error}</small>}</span>;}

const nav=[{href:"/",label:"Discover",icon:"discover" as const},{href:"/create",label:"Create",icon:"create" as const},{href:"/portfolio",label:"Portfolio",icon:"portfolio" as const}];
export function Shell({children}:{children:ReactNode}){const path=window.location.pathname;return <><header className="topbar"><a className="brand" href="/" aria-label="BabyNoxa home"><span className="brand-mark">N</span><span>BabyNoxa</span></a><WalletButton/></header><main id="main">{children}</main><nav className="dock" aria-label="Primary navigation">{nav.map(item=><a key={item.href} href={item.href} aria-current={path===item.href?"page":undefined}><Icon name={item.icon}/><span>{item.label}</span></a>)}</nav></>}

export function PageHeader({eyebrow,title,copy,actions}:{eyebrow:string;title:string;copy:string;actions?:ReactNode}){return <section className="page-header"><div><p className="eyebrow">{eyebrow}</p><h1>{title}</h1><p className="lede">{copy}</p></div>{actions}</section>}

export function ProjectCard({project,featured=false}:{project:ProjectRecord;featured?:boolean}){const metadata=project.metadata;const progress=Number((800_000_000n*10n**18n-BigInt(project.curve_inventory))*10_000n/(800_000_000n*10n**18n))/100;return <a className={`project-card ${featured?"featured":""}`} href={`/token/${project.launch_id}`}><div className="card-gloss"/><div className="asset-row"><div className="token-avatar">{metadata?.image?<img src={metadata.image} alt="" loading="lazy"/>:metadata?.symbol?.slice(0,2)??"NX"}</div><div><strong>{metadata?.name??`Launch #${project.launch_id}`}</strong><span>${metadata?.symbol??short(project.token)}</span></div><span className={`status status-${project.lifecycle}`}>{LIFECYCLE_LABEL[project.lifecycle]}</span></div><p>{metadata?.description??"Verified fixed-supply launch metadata committed onchain."}</p><div className="progress-label"><span>Graduation progress</span><strong>{progress.toFixed(1)}%</strong></div><div className="progress"><i style={{width:`${Math.min(progress,100)}%`}}/></div><div className="card-footer"><span>Reserve {Number(formatEther(BigInt(project.real_reserve))).toFixed(3)}</span><span>View market <Icon name="arrow"/></span></div></a>}

export function TransactionBanner({state}:{state:TransactionState}){if(state.phase==="idle")return null;const bad=["rejected","reverted","dropped","rpc-error"].includes(state.phase);return <div className={`transaction-banner ${bad?"bad":""}`} role="status" aria-live="polite"><span className="tx-dot"/><div><strong>{state.phase.replace("-"," ")}</strong><p>{state.message}</p></div>{state.hash&&<code>{short(state.hash)}</code>}</div>}

export function EmptyState({title,copy}:{title:string;copy:string}){return <div className="empty"><span>∅</span><h2>{title}</h2><p>{copy}</p></div>}

export function Field({label,error,children,hint}:{label:string;error?:string|undefined;children:ReactNode;hint?:string|undefined}){return <label className={`field ${error?"has-error":""}`}><span>{label}</span>{children}{hint&&<small>{hint}</small>}{error&&<small className="error" role="alert">{error}</small>}</label>}
