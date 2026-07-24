import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { backend, demoBackend, type BackendClient } from "./api.js";
import { EmptyState, Shell } from "./components.js";
import { CreatePage } from "./pages/CreatePage.js";
import { DiscoveryPage } from "./pages/DiscoveryPage.js";
import { PortfolioPage } from "./pages/PortfolioPage.js";
import { TokenPage } from "./pages/TokenPage.js";
import { WalletProvider } from "./wallet.js";

const adminDashboardEnabled = import.meta.env.VITE_ENABLE_ADMIN_DASHBOARD === "true";
const AdminDashboard = adminDashboardEnabled
  ? lazy(() => import("./pages/AdminPage.js").then((module) => ({ default: module.AdminPage })))
  : null;

export default function App(){const[path,setPath]=useState(window.location.pathname);const demo=new URLSearchParams(window.location.search).has("demo");useEffect(()=>{const update=()=>setPath(window.location.pathname);window.addEventListener("popstate",update);const click=(event:MouseEvent)=>{const anchor=(event.target as Element).closest("a");if(!anchor||anchor.target||anchor.origin!==location.origin)return;event.preventDefault();const target=new URL(anchor.href);if(demo)target.searchParams.set("demo","1");history.pushState({},"",target);update();window.scrollTo(0,0)};document.addEventListener("click",click);return()=>{window.removeEventListener("popstate",update);document.removeEventListener("click",click)}},[demo]);const client=useMemo<BackendClient>(()=>demo?{...backend,launches:demoBackend.launches,launch:demoBackend.launch,trending:demoBackend.trending,prepareMetadata:demoBackend.prepareMetadata}:backend,[demo]);let page=path==="/"?<DiscoveryPage client={client}/>:path==="/create"?<CreatePage client={client} demo={demo}/>:path==="/portfolio"?<PortfolioPage client={client}/>:path==="/admin"&&AdminDashboard?<Suspense fallback={<EmptyState title="Loading" copy="Opening the internal console."/>}><AdminDashboard/></Suspense>:path.startsWith("/token/")?<TokenPage client={client} demo={demo}/>:<EmptyState title="Page not found" copy="This route does not exist."/>;return <WalletProvider demo={demo}><Shell>{demo&&<div className="demo-ribbon">Interactive demo network · no real funds</div>}{page}</Shell></WalletProvider>}
