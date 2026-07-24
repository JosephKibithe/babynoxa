import { useEffect, useMemo, useState } from "react";
import { formatEther, formatUnits } from "viem";
import type { BackendClient } from "../api.js";
import { Button, CopyButton, EmptyState, short } from "../components.js";
import { nativeCurrencyFor } from "../config.js";
import type { ProjectRecord } from "../domain.js";
import { addressUrl } from "../links.js";
import { useWallet, type WalletPosition } from "../wallet.js";

type Tab = "holdings" | "created" | "claims";
type ClaimRow = { key: "refund" | "credit" | "creator" | "treasury"; label: string; value: bigint; allowed: boolean };

const claimRows = (project: ProjectRecord, position: WalletPosition, address?: string): ClaimRow[] => [
  { key: "refund", label: "Refund", value: position.refund, allowed: true },
  { key: "credit", label: "Sell credit", value: position.credit, allowed: true },
  { key: "creator", label: "Creator fees", value: position.creatorFees, allowed: address?.toLowerCase() === project.creator.toLowerCase() },
  { key: "treasury", label: "Treasury fees", value: position.treasuryFees, allowed: address?.toLowerCase() === project.treasury.toLowerCase() },
];

const formatBalance = (wei: bigint) => {
  const n = Number(formatUnits(wei, 18));
  if (!Number.isFinite(n) || n === 0) return "0";
  return new Intl.NumberFormat("en", { notation: n >= 1_000_000 ? "compact" : "standard", maximumFractionDigits: n >= 1 ? 2 : 4 }).format(n);
};

const estimateNative = (position: WalletPosition) => {
  if (position.balance <= 0n || position.virtualToken <= 0n) return 0n;
  return (position.balance * position.virtualBase) / position.virtualToken;
};

const avatarHue = (address: string) => Number.parseInt(address.slice(2, 8), 16) % 360;

function HoldingRow({ project, position }: { project: ProjectRecord; position: WalletPosition }) {
  const metadata = project.metadata;
  const currency = nativeCurrencyFor(project.chain_id);
  const value = estimateNative(position);
  return (
    <a className="holding-row" href={`/token/${project.launch_id}`}>
      <div className="token-avatar">{metadata?.image ? <img src={metadata.image} alt="" loading="lazy" /> : metadata?.symbol?.slice(0, 2) ?? "NX"}</div>
      <div className="holding-id">
        <strong>{metadata?.name ?? `Launch #${project.launch_id}`}</strong>
        <span>${metadata?.symbol ?? short(project.token)}</span>
      </div>
      <div className="holding-bal">
        <strong>{formatBalance(position.balance)}</strong>
        <span>{value > 0n ? `≈ ${Number(formatEther(value)).toFixed(4)} ${currency}` : currency}</span>
      </div>
    </a>
  );
}

function CreatedRow({ project }: { project: ProjectRecord }) {
  const metadata = project.metadata;
  return (
    <a className="holding-row" href={`/token/${project.launch_id}`}>
      <div className="token-avatar">{metadata?.image ? <img src={metadata.image} alt="" loading="lazy" /> : metadata?.symbol?.slice(0, 2) ?? "NX"}</div>
      <div className="holding-id">
        <strong>{metadata?.name ?? `Launch #${project.launch_id}`}</strong>
        <span>${metadata?.symbol ?? short(project.token)}</span>
      </div>
      <div className="holding-bal">
        <strong>Created</strong>
        <span>{project.lifecycle === "graduated" ? "AMM" : "Curve"}</span>
      </div>
    </a>
  );
}

function ClaimsList({ projects, positions }: { projects: ProjectRecord[]; positions: Record<string, WalletPosition> }) {
  const wallet = useWallet();
  const cards = projects.flatMap((project) => {
    const position = positions[project.launch_id];
    if (!position) return [];
    const currency = nativeCurrencyFor(project.chain_id);
    const symbol = project.metadata?.symbol ?? `#${project.launch_id}`;
    return claimRows(project, position, wallet.address)
      .filter((row) => row.allowed && row.value > 0n)
      .map((row) => ({ project, row, currency, symbol }));
  });
  if (!cards.length) return <EmptyState title="No claims" copy="Nothing claimable for this wallet right now." />;
  return (
    <div className="claims-list">
      {cards.map(({ project, row, currency, symbol }) => (
        <article className="claim-row" key={`${project.launch_id}-${row.key}`}>
          <div>
            <strong>${symbol}</strong>
            <span>{row.label}</span>
          </div>
          <strong>{Number(formatEther(row.value)).toFixed(5)} {currency}</strong>
          <Button onClick={() => void wallet.claim(project, row.key)}>Claim</Button>
        </article>
      ))}
    </div>
  );
}

export function PortfolioPage({ client }: { client: BackendClient }) {
  const wallet = useWallet();
  const [projects, setProjects] = useState<ProjectRecord[]>([]);
  const [positions, setPositions] = useState<Record<string, WalletPosition>>({});
  const [nativeBal, setNativeBal] = useState(0n);
  const [tab, setTab] = useState<Tab>("holdings");
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!wallet.address) {
      setProjects([]);
      setPositions({});
      setNativeBal(0n);
      return;
    }
    let live = true;
    setLoading(true);
    void Promise.all([
      client.launches(),
      wallet.readNativeBalance().catch(() => 0n),
    ]).then(async ([result, native]) => {
      if (!live) return;
      setNativeBal(native);
      setProjects(result.projects);
      const entries = await Promise.all(result.projects.map(async (project) => [project.launch_id, await wallet.readPosition(project)] as const));
      if (!live) return;
      setPositions(Object.fromEntries(entries));
    }).catch(() => {
      if (!live) return;
      setProjects([]);
      setPositions({});
    }).finally(() => {
      if (live) setLoading(false);
    });
    return () => { live = false; };
  }, [client, wallet.address, wallet.transaction.phase]);

  const holdings = useMemo(
    () => projects.filter((project) => (positions[project.launch_id]?.balance ?? 0n) > 0n),
    [projects, positions],
  );
  const created = useMemo(
    () => projects.filter((project) => project.creator.toLowerCase() === wallet.address?.toLowerCase()),
    [projects, wallet.address],
  );
  const claimCount = useMemo(
    () => projects.reduce((count, project) => {
      const position = positions[project.launch_id];
      if (!position) return count;
      return count + claimRows(project, position, wallet.address).filter((row) => row.allowed && row.value > 0n).length;
    }, 0),
    [projects, positions, wallet.address],
  );
  const holdingsValue = useMemo(
    () => holdings.reduce((sum, project) => sum + estimateNative(positions[project.launch_id]!), 0n),
    [holdings, positions],
  );

  if (!wallet.address) {
    return (
      <section className="profile-page">
        <div className="profile-empty">
          <div className="profile-avatar ghost">?</div>
          <h1>Connect wallet</h1>
          <p>View your launchpad balances and claims.</p>
          <Button className="primary" onClick={() => void wallet.connect()}>Connect wallet</Button>
        </div>
      </section>
    );
  }

  const currency = nativeCurrencyFor(wallet.chainId);
  const explorer = addressUrl(wallet.chainId ?? 137, wallet.address);

  return (
    <section className="profile-page">
      <header className="profile-head">
        <div className="profile-avatar" style={{ background: `linear-gradient(145deg,hsl(${avatarHue(wallet.address)} 55% 42%),hsl(${(avatarHue(wallet.address) + 40) % 360} 45% 22%))` }}>
          {wallet.address.slice(2, 4).toUpperCase()}
        </div>
        <div className="profile-id">
          <div className="profile-title">
            <h1>{short(wallet.address)}</h1>
            <CopyButton value={wallet.address} label="wallet address" />
            {explorer && <a href={explorer} target="_blank" rel="noreferrer">Explorer ↗</a>}
          </div>
          <div className="profile-stats">
            <span><strong>{Number(formatEther(nativeBal)).toFixed(4)}</strong> {currency}</span>
            <span><strong>{holdings.length}</strong> holdings</span>
            <span><strong>{Number(formatEther(holdingsValue)).toFixed(4)}</strong> {currency} est.</span>
          </div>
        </div>
      </header>

      <div className="profile-tabs" role="tablist">
        <button type="button" role="tab" aria-selected={tab === "holdings"} className={tab === "holdings" ? "active" : ""} onClick={() => setTab("holdings")}>
          Holdings{holdings.length ? ` (${holdings.length})` : ""}
        </button>
        <button type="button" role="tab" aria-selected={tab === "created"} className={tab === "created" ? "active" : ""} onClick={() => setTab("created")}>
          Created{created.length ? ` (${created.length})` : ""}
        </button>
        <button type="button" role="tab" aria-selected={tab === "claims"} className={tab === "claims" ? "active" : ""} onClick={() => setTab("claims")}>
          Claims{claimCount ? ` (${claimCount})` : ""}
        </button>
      </div>

      {loading ? <div className="profile-loading skeleton" /> : null}

      {!loading && tab === "holdings" && (
        holdings.length
          ? <div className="holdings-list">{holdings.map((project) => <HoldingRow key={project.launch_id} project={project} position={positions[project.launch_id]!} />)}</div>
          : <EmptyState title="No holdings" copy="Buy a launchpad token to see it here." />
      )}

      {!loading && tab === "created" && (
        created.length
          ? <div className="holdings-list">{created.map((project) => <CreatedRow key={project.launch_id} project={project} />)}</div>
          : <EmptyState title="Nothing created" copy="Tokens you launch will show up here." />
      )}

      {!loading && tab === "claims" && <ClaimsList projects={projects} positions={positions} />}
    </section>
  );
}
