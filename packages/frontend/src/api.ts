import type { PreparedMetadata, ProjectMetadataV1 } from "@babynoxa/shared";
import { API_URL } from "./config.js";
import type { LaunchDetail, ProjectRecord, TradeRecord } from "./domain.js";

const request = async <T>(path: string, init?: RequestInit): Promise<T> => {
  const headers = new Headers(init?.headers);
  // Bypass the ngrok free-tier browser interstitial so API calls return JSON.
  headers.set("ngrok-skip-browser-warning", "1");
  const response = await fetch(`${API_URL}${path}`, { ...init, headers });
  const body = await response.json() as T & { error?: string };
  if (!response.ok) throw new Error(body.error ?? `Backend request failed (${response.status})`);
  return body;
};

export const backend = {
  launches: (query = "") => request<{ projects: ProjectRecord[] }>(`/launches?q=${encodeURIComponent(query)}`),
  launch: (id: string) => request<LaunchDetail>(`/launches/${id}`),
  trending: () => request<{ projects: ProjectRecord[] }>("/trending"),
  creator: (address: string) => request<{ projects: ProjectRecord[] }>(`/creators/${address}`),
  prepareMetadata: (input: Omit<ProjectMetadataV1,"schemaVersion"|"imageHash">) => request<PreparedMetadata>("/metadata/prepare", { method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify(input) }),
  comments: (id: string) => request<{ comments: Array<{id:number;author:string;body:string;created_at:string}> }>(`/launches/${id}/comments`),
  comment: (id: string, author: string, body: string) => request<{id:number}>(`/launches/${id}/comments`, { method:"POST", headers:{"content-type":"application/json"}, body:JSON.stringify({author,body}) }),
};

export const adminBackend = {
  moderate: (commentId: number, token: string, actor: string, action: "hide"|"restore", reason: string) => request<{status:string}>(`/admin/comments/${commentId}/moderate`, { method:"POST", headers:{"content-type":"application/json",authorization:`Bearer ${token}`}, body:JSON.stringify({actor,action,reason}) }),
};

const address = (digit: string) => `0x${digit.repeat(40)}` as const;
const demoMetadata: ProjectMetadataV1 = { schemaVersion:1,name:"Noxa Nova",symbol:"NOVA",description:"A fixed-supply community launch moving toward immutable liquidity.",image:"https://images.unsplash.com/photo-1614728263952-84ea256f9679",imageHash:`0x${"a".repeat(64)}`,website:"https://example.com" };
const demoProject: ProjectRecord = { chain_id:31337,launch_id:"1",creator:address("1"),token:address("2"),curve:address("3"),official_pair:address("4"),treasury:address("1"),manager:address("5"),metadata_uri:"demo://nova",metadata_hash:`0x${"b".repeat(64)}`,lifecycle:"trading",curve_inventory:(510_000_000n*10n**18n).toString(),real_reserve:(870_000_000_000_000_000n).toString(),authoritative_block:"120",metadata:demoMetadata };
const demoTrades: TradeRecord[] = [{transaction_hash:`0x${"c".repeat(64)}`,trader:address("1"),side:"buy",token_amount:(12_000_000n*10n**18n).toString(),gross_base:(25n*10n**16n).toString(),net_base:(2475n*10n**14n).toString(),timestamp:Math.floor(Date.now()/1000)-1800}];

let demoProjects = [demoProject];
let demoTradeList = [...demoTrades];
let nextLaunch = 2;

export const demoBackend = {
  async launches(query = "") { return { projects:demoProjects.filter((project) => `${project.metadata?.name} ${project.metadata?.symbol}`.toLowerCase().includes(query.toLowerCase())) }; },
  async launch(id: string): Promise<LaunchDetail> { const project=demoProjects.find((item)=>item.launch_id===id); if(!project) throw new Error("Launch not found"); const trades=demoTradeList.filter((trade)=>id==="1" || trade.transaction_hash.endsWith(id.padStart(2,"0"))); return {project,trades,holders:[{holder:address("1"),balance:(12_000_000n*10n**18n).toString()}],metrics:{tradeCount:trades.length,volume:trades.reduce((sum,item)=>sum+BigInt(item.gross_base),0n).toString(),progressBps:Number((800_000_000n*10n**18n-BigInt(project.curve_inventory))*10_000n/(800_000_000n*10n**18n))}}; },
  async trending(){ return {projects:demoProjects}; },
  async prepareMetadata(input: Omit<ProjectMetadataV1,"schemaVersion"|"imageHash">): Promise<PreparedMetadata> { const imageHash=`0x${"d".repeat(64)}` as const;const metadata:ProjectMetadataV1={schemaVersion:1,name:input.name.trim(),symbol:input.symbol.trim(),description:input.description.trim()};const image=input.image?.trim();const website=input.website?.trim();const twitter=input.twitter?.trim();const telegram=input.telegram?.trim();const discord=input.discord?.trim();if(image){metadata.image=new URL(image).toString();metadata.imageHash=imageHash}if(website)metadata.website=new URL(website).toString();if(twitter)metadata.twitter=new URL(twitter).toString();if(telegram)metadata.telegram=new URL(telegram).toString();if(discord)metadata.discord=new URL(discord).toString();return{metadata,metadataUri:`https://metadata.babynoxa.test/${nextLaunch}.json`,metadataHash:`0x${"e".repeat(64)}`,...(metadata.imageHash?{imageHash:metadata.imageHash}:{})}; },
  create(metadata: ProjectMetadataV1, creator: `0x${string}`, withBuy: boolean) { const id=String(nextLaunch++); const project:ProjectRecord={...demoProject,launch_id:id,creator,metadata,metadata_uri:`demo://${id}`,metadata_hash:`0x${id.padStart(64,"0")}`,lifecycle:"trading",curve_inventory:((withBuy?780_000_000n:800_000_000n)*10n**18n).toString(),real_reserve:withBuy?(5n*10n**16n).toString():"0"}; demoProjects=[project,...demoProjects]; return project; },
  trade(id:string, side:"buy"|"sell") { const project=demoProjects.find((item)=>item.launch_id===id);if(project){if(side==="buy"){project.real_reserve=(BigInt(project.real_reserve)+9_900_000_000_000_000n).toString();project.curve_inventory=(BigInt(project.curve_inventory)-7_000_000n*10n**18n).toString();}else{project.real_reserve=(BigInt(project.real_reserve)-1_000_000_000n).toString();project.curve_inventory=(BigInt(project.curve_inventory)+10n**18n).toString();}}demoTradeList=[{...demoTrades[0]!,side,transaction_hash:`0x${(demoTradeList.length+1).toString(16).padStart(64,"0")}`,timestamp:Math.floor(Date.now()/1000)},...demoTradeList]; return this.launch(id); },
  graduate(id:string){ const project=demoProjects.find((item)=>item.launch_id===id); if(project) project.lifecycle="graduated"; },
  reset(){ demoProjects=[{...demoProject,lifecycle:"trading"}]; demoTradeList=[...demoTrades]; nextLaunch=2; },
};

export type BackendClient = typeof backend;
