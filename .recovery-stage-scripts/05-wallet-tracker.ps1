$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not (Test-Path "package.json")) {
    throw "package.json tidak ditemukan. Jalankan dari folder memecoin-analyst."
}

if (-not (Test-Path "src/components/sidebar.tsx")) {
    throw "Project MemeScope belum terdeteksi."
}

Step "Backup Stage 05"
$BackupDir = "backup-stage-05"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Copy-Item "src/components/sidebar.tsx" "$BackupDir/sidebar.tsx.bak" -Force

Step "Membuat wallet types"
@'
export type WalletHolding = {
  mint: string;
  amount: number;
  decimals: number;
  symbol: string | null;
  name: string | null;
  priceUsd: number;
  valueUsd: number;
  marketCap: number;
  liquidity: number;
  dexUrl: string | null;
};

export type WalletActivity = {
  signature: string;
  blockTime: number | null;
  status: "success" | "failed";
  mint: string | null;
  delta: number;
  direction: "acquired" | "disposed" | "other";
  currentPriceUsd: number;
  currentDeltaValueUsd: number;
};

export type WalletReport = {
  ok: boolean;
  address: string;
  solBalance: number;
  visibleTokenValueUsd: number;
  holdings: WalletHolding[];
  recentActivity: WalletActivity[];
  recentSignatureCount: number;
  distinctTokensTouched: number;
  activityScore: number;
  positionTier: "Small" | "Medium" | "Large";
  rpcSource: string;
  updatedAt: number;
  limitations: string[];
  error?: string;
};
'@ | Set-Content -Encoding UTF8 "src/lib/wallet-types.ts"

Step "Membuat Solana wallet inspector API"
New-Item -ItemType Directory -Force -Path "src/app/api/wallet/solana/[address]" | Out-Null

@'
import { NextRequest, NextResponse } from "next/server";
import type {
  WalletActivity,
  WalletHolding,
  WalletReport,
} from "@/lib/wallet-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PUBLIC_RPC = "https://api.mainnet.solana.com";
const CACHE_MS = 12_000;
const MAX_HOLDINGS = 12;
const MAX_SIGNATURES = 8;

const cache = new Map<
  string,
  { expiresAt: number; report: WalletReport }
>();

type Json = Record<string, any>;

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

async function rpc(
  rpcUrl: string,
  method: string,
  params: unknown[],
  id: number,
) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id,
      method,
      params,
    }),
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(`Solana RPC returned ${response.status}`);
  }

  const data = (await response.json()) as Json;

  if (data.error) {
    throw new Error(
      data.error.message || `${method} failed`,
    );
  }

  return data.result;
}

async function rpcBatchTransactions(
  rpcUrl: string,
  signatures: string[],
) {
  if (!signatures.length) return [];

  const body = signatures.map((signature, index) => ({
    jsonrpc: "2.0",
    id: index + 100,
    method: "getTransaction",
    params: [
      signature,
      {
        commitment: "confirmed",
        maxSupportedTransactionVersion: 0,
        encoding: "jsonParsed",
      },
    ],
  }));

  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(body),
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `Solana transaction batch returned ${response.status}`,
    );
  }

  const data = (await response.json()) as Json[];

  if (!Array.isArray(data)) return [];

  return data
    .sort((a, b) => n(a.id) - n(b.id))
    .map((item) => item.result ?? null);
}

async function fetchDexData(mints: string[]) {
  const unique = Array.from(new Set(mints)).slice(0, 30);

  if (!unique.length) {
    return new Map<string, Json>();
  }

  const joined = unique
    .map((mint) => encodeURIComponent(mint))
    .join(",");

  const response = await fetch(
    `https://api.dexscreener.com/tokens/v1/solana/${joined}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "MemeScope/0.5",
      },
      cache: "no-store",
    },
  );

  if (!response.ok) {
    return new Map<string, Json>();
  }

  const data = await response.json();
  const pairs = Array.isArray(data)
    ? data
    : Array.isArray(data?.pairs)
      ? data.pairs
      : [];

  const best = new Map<string, Json>();

  for (const pair of pairs as Json[]) {
    const mint = pair?.baseToken?.address;
    if (!mint) continue;

    const existing = best.get(mint);
    const existingLiq = n(existing?.liquidity?.usd);
    const nextLiq = n(pair?.liquidity?.usd);

    if (!existing || nextLiq > existingLiq) {
      best.set(mint, pair);
    }
  }

  return best;
}

function tokenAmount(balance: Json) {
  return n(
    balance?.uiTokenAmount?.uiAmountString ??
      balance?.uiTokenAmount?.uiAmount,
  );
}

function ownerBalances(
  balances: Json[] | undefined,
  owner: string,
) {
  const map = new Map<string, number>();

  for (const item of balances || []) {
    if (item?.owner !== owner || !item?.mint) continue;

    map.set(
      item.mint,
      (map.get(item.mint) || 0) + tokenAmount(item),
    );
  }

  return map;
}

function buildActivity(
  wallet: string,
  signatures: Json[],
  transactions: Array<Json | null>,
) {
  const activities: WalletActivity[] = [];
  const touched = new Set<string>();

  transactions.forEach((tx, index) => {
    if (!tx) return;

    const sig = signatures[index];
    const pre = ownerBalances(
      tx?.meta?.preTokenBalances,
      wallet,
    );
    const post = ownerBalances(
      tx?.meta?.postTokenBalances,
      wallet,
    );

    const mints = new Set([
      ...pre.keys(),
      ...post.keys(),
    ]);

    let created = 0;

    for (const mint of mints) {
      const delta =
        (post.get(mint) || 0) -
        (pre.get(mint) || 0);

      if (Math.abs(delta) < 1e-12) continue;

      touched.add(mint);

      activities.push({
        signature:
          sig?.signature ||
          tx?.transaction?.signatures?.[0] ||
          "",
        blockTime:
          typeof tx?.blockTime === "number"
            ? tx.blockTime
            : sig?.blockTime ?? null,
        status:
          tx?.meta?.err == null
            ? "success"
            : "failed",
        mint,
        delta,
        direction:
          delta > 0 ? "acquired" : "disposed",
        currentPriceUsd: 0,
        currentDeltaValueUsd: 0,
      });

      created += 1;
      if (created >= 3) break;
    }

    if (created === 0) {
      activities.push({
        signature:
          sig?.signature ||
          tx?.transaction?.signatures?.[0] ||
          "",
        blockTime:
          typeof tx?.blockTime === "number"
            ? tx.blockTime
            : sig?.blockTime ?? null,
        status:
          tx?.meta?.err == null
            ? "success"
            : "failed",
        mint: null,
        delta: 0,
        direction: "other",
        currentPriceUsd: 0,
        currentDeltaValueUsd: 0,
      });
    }
  });

  return {
    activities: activities.slice(0, 18),
    touched,
  };
}

export async function GET(
  _request: NextRequest,
  context: { params: Promise<{ address: string }> },
) {
  const { address } = await context.params;

  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address)) {
    return NextResponse.json(
      { ok: false, error: "Invalid Solana wallet address." },
      { status: 400 },
    );
  }

  const cached = cache.get(address);

  if (cached && Date.now() < cached.expiresAt) {
    return NextResponse.json(cached.report, {
      headers: { "Cache-Control": "no-store" },
    });
  }

  const customRpc = process.env.SOLANA_RPC_URL?.trim();
  const rpcUrl = customRpc || PUBLIC_RPC;
  const now = Date.now();

  try {
    const [balanceResult, tokenAccountsResult, signatures] =
      await Promise.all([
        rpc(
          rpcUrl,
          "getBalance",
          [address, { commitment: "confirmed" }],
          1,
        ),
        rpc(
          rpcUrl,
          "getTokenAccountsByOwner",
          [
            address,
            { programId: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA" },
            {
              encoding: "jsonParsed",
              commitment: "confirmed",
            },
          ],
          2,
        ),
        rpc(
          rpcUrl,
          "getSignaturesForAddress",
          [
            address,
            {
              commitment: "confirmed",
              limit: MAX_SIGNATURES,
            },
          ],
          3,
        ),
      ]);

    const rawAccounts = Array.isArray(
      tokenAccountsResult?.value,
    )
      ? tokenAccountsResult.value
      : [];

    const rawHoldings = rawAccounts
      .map((item: Json) => {
        const info =
          item?.account?.data?.parsed?.info;
        const mint = info?.mint;
        const token = info?.tokenAmount;

        return {
          mint,
          amount: n(
            token?.uiAmountString ??
              token?.uiAmount,
          ),
          decimals: n(token?.decimals),
        };
      })
      .filter(
        (item: Json) =>
          item.mint && item.amount > 0,
      )
      .sort(
        (a: Json, b: Json) =>
          b.amount - a.amount,
      )
      .slice(0, MAX_HOLDINGS);

    const signatureList = Array.isArray(signatures)
      ? signatures
      : [];

    let transactions: Array<Json | null> = [];

    try {
      transactions = await rpcBatchTransactions(
        rpcUrl,
        signatureList.map(
          (item: Json) => item.signature,
        ),
      );
    } catch {
      transactions = [];
    }

    const activityData = buildActivity(
      address,
      signatureList,
      transactions,
    );

    const allMints = Array.from(
      new Set([
        ...rawHoldings.map(
          (item: Json) => item.mint,
        ),
        ...Array.from(activityData.touched),
      ]),
    );

    const dex = await fetchDexData(allMints);

    const holdings: WalletHolding[] =
      rawHoldings.map((item: Json) => {
        const pair = dex.get(item.mint);
        const priceUsd = n(pair?.priceUsd);
        const amount = n(item.amount);

        return {
          mint: item.mint,
          amount,
          decimals: n(item.decimals),
          symbol:
            pair?.baseToken?.symbol || null,
          name:
            pair?.baseToken?.name || null,
          priceUsd,
          valueUsd: amount * priceUsd,
          marketCap: n(
            pair?.marketCap ?? pair?.fdv,
          ),
          liquidity: n(
            pair?.liquidity?.usd,
          ),
          dexUrl: pair?.url || null,
        };
      });

    holdings.sort(
      (a, b) => b.valueUsd - a.valueUsd,
    );

    const activities = activityData.activities.map(
      (activity) => {
        const pair = activity.mint
          ? dex.get(activity.mint)
          : null;
        const priceUsd = n(pair?.priceUsd);

        return {
          ...activity,
          currentPriceUsd: priceUsd,
          currentDeltaValueUsd:
            Math.abs(activity.delta) * priceUsd,
        };
      },
    );

    const visibleTokenValueUsd = holdings.reduce(
      (sum, item) => sum + item.valueUsd,
      0,
    );

    const txCount = signatureList.length;
    const diversity = activityData.touched.size;

    const activityScore = Math.round(
      clamp(
        txCount * 7 +
          diversity * 9 +
          Math.min(
            25,
            Math.log10(
              visibleTokenValueUsd + 1,
            ) * 6,
          ),
      ),
    );

    const positionTier =
      visibleTokenValueUsd >= 25_000
        ? ("Large" as const)
        : visibleTokenValueUsd >= 2_500
          ? ("Medium" as const)
          : ("Small" as const);

    const report: WalletReport = {
      ok: true,
      address,
      solBalance:
        n(balanceResult?.value) / 1_000_000_000,
      visibleTokenValueUsd,
      holdings,
      recentActivity: activities,
      recentSignatureCount: txCount,
      distinctTokensTouched: diversity,
      activityScore,
      positionTier,
      rpcSource: customRpc
        ? "Custom Solana RPC"
        : "Solana public RPC",
      updatedAt: now,
      limitations: [
        "USD values use current DEX market prices, not historical entry prices.",
        "Visible token value only includes non-zero SPL Token accounts inspected in this stage and tokens with usable DEX pricing.",
        "Token-2022 accounts, NFTs, LP positions, staked assets, lending positions and off-chain balances can be missing.",
        "Activity score measures recent observable activity and portfolio visibility; it is not a profitability or smart-money score.",
        customRpc
          ? "Custom RPC is configured."
          : "Public Solana RPC is rate-limited and intended only for development.",
      ],
    };

    cache.set(address, {
      expiresAt: now + CACHE_MS,
      report,
    });

    return NextResponse.json(report, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Wallet analysis failed.",
      },
      {
        status: 502,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }
}
'@ | Set-Content -Encoding UTF8 -LiteralPath "src/app/api/wallet/solana/[address]/route.ts"

Step "Membuat Wallet Tracker UI"
New-Item -ItemType Directory -Force -Path "src/app/wallets" | Out-Null

@'
"use client";

import { AppShell } from "@/components/app-shell";
import type { WalletReport } from "@/lib/wallet-types";
import {
  Activity,
  ArrowDownRight,
  ArrowUpRight,
  Copy,
  ExternalLink,
  Plus,
  RefreshCw,
  Search,
  Trash2,
  WalletCards,
  Waves,
} from "lucide-react";
import {
  FormEvent,
  useEffect,
  useMemo,
  useState,
} from "react";
import { useSearchParams } from "next/navigation";

const STORAGE_KEY = "memescope-tracked-wallets";

function short(address: string) {
  if (address.length < 16) return address;
  return `${address.slice(0, 7)}…${address.slice(-7)}`;
}

function money(value: number) {
  if (!Number.isFinite(value)) return "$0";
  if (value >= 1_000_000)
    return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000)
    return `$${(value / 1_000).toFixed(1)}K`;
  if (value >= 1)
    return `$${value.toFixed(2)}`;
  return `$${value.toPrecision(4)}`;
}

function amount(value: number) {
  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value);
}

function time(blockTime: number | null) {
  if (!blockTime) return "—";
  return new Date(
    blockTime * 1000,
  ).toLocaleString();
}

export default function WalletsPage() {
  const searchParams = useSearchParams();
  const initial =
    searchParams.get("address") || "";

  const [input, setInput] = useState(initial);
  const [selected, setSelected] =
    useState(initial);
  const [tracked, setTracked] = useState<
    string[]
  >([]);
  const [report, setReport] =
    useState<WalletReport | null>(null);
  const [loading, setLoading] =
    useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    try {
      const parsed = JSON.parse(
        localStorage.getItem(STORAGE_KEY) ||
          "[]",
      );
      if (Array.isArray(parsed)) {
        setTracked(parsed);
      }
    } catch {
      setTracked([]);
    }
  }, []);

  useEffect(() => {
    if (!selected) return;

    let cancelled = false;

    async function run() {
      setLoading(true);

      try {
        const response = await fetch(
          `/api/wallet/solana/${encodeURIComponent(
            selected,
          )}`,
          { cache: "no-store" },
        );
        const data = await response.json();

        if (!response.ok || !data.ok) {
          throw new Error(
            data.error || "Wallet analysis failed.",
          );
        }

        if (!cancelled) {
          setReport(data as WalletReport);
          setError("");
        }
      } catch (err) {
        if (!cancelled) {
          setReport(null);
          setError(
            err instanceof Error
              ? err.message
              : "Wallet analysis failed.",
          );
        }
      } finally {
        if (!cancelled) {
          setLoading(false);
        }
      }
    }

    run();

    const timer = window.setInterval(run, 15_000);

    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [selected]);

  const visibleHoldings = useMemo(
    () => report?.holdings || [],
    [report],
  );

  function persist(next: string[]) {
    setTracked(next);
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(next),
    );
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const value = input.trim();

    if (
      !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
        value,
      )
    ) {
      setError("Invalid Solana wallet address.");
      return;
    }

    setSelected(value);
  }

  function addTracked() {
    if (!selected) return;
    if (tracked.includes(selected)) return;
    persist([selected, ...tracked].slice(0, 20));
  }

  function removeTracked(address: string) {
    persist(
      tracked.filter((item) => item !== address),
    );
  }

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="flex items-center gap-2 text-sm text-emerald-300">
          <WalletCards className="h-4 w-4" />
          Solana Wallet Intelligence
        </div>
        <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
          Wallet & Whale Tracker
        </h1>
        <p className="mt-1 max-w-2xl text-sm text-zinc-500">
          Inspect recent wallet activity, current visible
          holdings and position size using on-chain data.
        </p>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        <section className="grid gap-4 xl:grid-cols-[.7fr_1.3fr]">
          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
            <form
              onSubmit={submit}
              className="flex gap-2"
            >
              <div className="relative min-w-0 flex-1">
                <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />
                <input
                  value={input}
                  onChange={(event) =>
                    setInput(event.target.value)
                  }
                  placeholder="Paste Solana wallet address"
                  className="h-10 w-full rounded-xl border border-white/8 bg-black/20 pl-10 pr-3 text-sm outline-none placeholder:text-zinc-700 focus:border-emerald-400/40"
                />
              </div>
              <button
                className="rounded-xl bg-white px-4 text-sm font-medium text-black"
              >
                Inspect
              </button>
            </form>

            <div className="mt-5 flex items-center justify-between">
              <div>
                <div className="text-sm font-medium text-white">
                  Tracked wallets
                </div>
                <div className="text-xs text-zinc-600">
                  Saved locally in this browser
                </div>
              </div>

              {selected ? (
                <button
                  onClick={addTracked}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-white/8 px-2.5 py-1.5 text-xs text-zinc-400 hover:text-white"
                >
                  <Plus className="h-3.5 w-3.5" />
                  Track
                </button>
              ) : null}
            </div>

            <div className="mt-3 space-y-2">
              {tracked.length ? (
                tracked.map((address) => (
                  <div
                    key={address}
                    className={`flex items-center justify-between gap-2 rounded-xl border p-3 ${
                      address === selected
                        ? "border-emerald-400/20 bg-emerald-400/5"
                        : "border-white/5 bg-black/15"
                    }`}
                  >
                    <button
                      onClick={() => {
                        setInput(address);
                        setSelected(address);
                      }}
                      className="min-w-0 flex-1 truncate text-left font-mono text-xs text-zinc-400 hover:text-white"
                    >
                      {short(address)}
                    </button>

                    <button
                      onClick={() =>
                        removeTracked(address)
                      }
                      className="text-zinc-700 hover:text-rose-300"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                ))
              ) : (
                <div className="rounded-xl border border-white/5 bg-black/15 p-4 text-xs leading-5 text-zinc-600">
                  Inspect a wallet, then click Track to
                  keep it here.
                </div>
              )}
            </div>
          </div>

          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            {!selected ? (
              <div className="grid min-h-48 place-items-center text-center">
                <div>
                  <Waves className="mx-auto h-7 w-7 text-zinc-700" />
                  <div className="mt-3 text-sm text-zinc-500">
                    Enter a Solana wallet to begin.
                  </div>
                </div>
              </div>
            ) : loading && !report ? (
              <div className="grid min-h-48 place-items-center text-center">
                <div>
                  <RefreshCw className="mx-auto h-6 w-6 animate-spin text-emerald-300" />
                  <div className="mt-3 text-sm text-zinc-500">
                    Reading wallet activity…
                  </div>
                </div>
              </div>
            ) : report ? (
              <>
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div className="min-w-0">
                    <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">
                      Wallet
                    </div>
                    <button
                      onClick={() =>
                        navigator.clipboard.writeText(
                          report.address,
                        )
                      }
                      className="mt-1 inline-flex max-w-full items-center gap-2 font-mono text-sm text-zinc-300 hover:text-white"
                    >
                      <span className="truncate">
                        {short(report.address)}
                      </span>
                      <Copy className="h-3.5 w-3.5 shrink-0" />
                    </button>
                  </div>

                  <div className="rounded-full border border-white/8 px-3 py-1.5 text-xs text-zinc-400">
                    {report.positionTier} visible position
                  </div>
                </div>

                <div className="mt-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                  {[
                    [
                      "SOL balance",
                      `${report.solBalance.toFixed(
                        3,
                      )} SOL`,
                    ],
                    [
                      "Visible token value",
                      money(
                        report.visibleTokenValueUsd,
                      ),
                    ],
                    [
                      "Activity score",
                      `${report.activityScore}/100`,
                    ],
                    [
                      "Recent signatures",
                      String(
                        report.recentSignatureCount,
                      ),
                    ],
                  ].map(([label, value]) => (
                    <div
                      key={label}
                      className="rounded-xl border border-white/8 bg-black/20 p-3"
                    >
                      <div className="text-xs text-zinc-600">
                        {label}
                      </div>
                      <div className="mt-1 text-lg font-medium text-white">
                        {value}
                      </div>
                    </div>
                  ))}
                </div>
              </>
            ) : (
              <div className="grid min-h-48 place-items-center text-sm text-zinc-600">
                No wallet report.
              </div>
            )}
          </div>
        </section>

        {error ? (
          <div className="rounded-2xl border border-rose-400/15 bg-rose-400/5 p-4 text-sm text-rose-200">
            {error}
          </div>
        ) : null}

        {report ? (
          <>
            <section className="grid gap-4 xl:grid-cols-[1fr_1fr]">
              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="flex items-center gap-2">
                  <WalletCards className="h-4 w-4 text-zinc-400" />
                  <h2 className="font-medium text-white">
                    Visible holdings
                  </h2>
                </div>

                <div className="mt-4 space-y-2">
                  {visibleHoldings.length ? (
                    visibleHoldings.map(
                      (holding) => (
                        <div
                          key={holding.mint}
                          className="grid grid-cols-[1fr_auto] gap-3 rounded-xl border border-white/5 bg-black/15 p-3"
                        >
                          <div className="min-w-0">
                            <div className="font-medium text-zinc-200">
                              {holding.symbol
                                ? `$${holding.symbol}`
                                : short(
                                    holding.mint,
                                  )}
                            </div>
                            <div className="mt-1 truncate text-xs text-zinc-600">
                              {holding.name ||
                                holding.mint}
                            </div>
                            <div className="mt-2 text-xs text-zinc-500">
                              {amount(
                                holding.amount,
                              )}{" "}
                              tokens
                            </div>
                          </div>

                          <div className="text-right">
                            <div className="font-medium text-white">
                              {money(
                                holding.valueUsd,
                              )}
                            </div>
                            <div className="mt-1 text-xs text-zinc-600">
                              MC{" "}
                              {money(
                                holding.marketCap,
                              )}
                            </div>
                            {holding.dexUrl ? (
                              <a
                                href={
                                  holding.dexUrl
                                }
                                target="_blank"
                                rel="noreferrer"
                                className="mt-2 inline-flex items-center gap-1 text-xs text-emerald-300"
                              >
                                DEX
                                <ExternalLink className="h-3 w-3" />
                              </a>
                            ) : null}
                          </div>
                        </div>
                      ),
                    )
                  ) : (
                    <div className="rounded-xl border border-white/5 p-4 text-xs text-zinc-600">
                      No priced SPL holdings were found.
                    </div>
                  )}
                </div>
              </div>

              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="flex items-center gap-2">
                  <Activity className="h-4 w-4 text-zinc-400" />
                  <h2 className="font-medium text-white">
                    Recent token activity
                  </h2>
                </div>

                <div className="mt-4 space-y-2">
                  {report.recentActivity.length ? (
                    report.recentActivity.map(
                      (activity, index) => (
                        <div
                          key={`${activity.signature}-${index}`}
                          className="rounded-xl border border-white/5 bg-black/15 p-3"
                        >
                          <div className="flex items-start justify-between gap-3">
                            <div className="flex min-w-0 gap-2">
                              {activity.direction ===
                              "acquired" ? (
                                <ArrowDownRight className="mt-0.5 h-4 w-4 shrink-0 text-emerald-300" />
                              ) : activity.direction ===
                                "disposed" ? (
                                <ArrowUpRight className="mt-0.5 h-4 w-4 shrink-0 text-rose-300" />
                              ) : (
                                <Activity className="mt-0.5 h-4 w-4 shrink-0 text-zinc-600" />
                              )}

                              <div className="min-w-0">
                                <div className="text-sm text-zinc-300">
                                  {activity.direction ===
                                  "acquired"
                                    ? "Token balance increased"
                                    : activity.direction ===
                                        "disposed"
                                      ? "Token balance decreased"
                                      : "Wallet transaction"}
                                </div>

                                <div className="mt-1 truncate font-mono text-xs text-zinc-600">
                                  {activity.mint ||
                                    activity.signature}
                                </div>
                              </div>
                            </div>

                            {activity.mint ? (
                              <div className="shrink-0 text-right">
                                <div
                                  className={`text-sm ${
                                    activity.delta >= 0
                                      ? "text-emerald-300"
                                      : "text-rose-300"
                                  }`}
                                >
                                  {activity.delta >=
                                  0
                                    ? "+"
                                    : ""}
                                  {amount(
                                    activity.delta,
                                  )}
                                </div>
                                <div className="mt-1 text-xs text-zinc-600">
                                  current ≈{" "}
                                  {money(
                                    activity.currentDeltaValueUsd,
                                  )}
                                </div>
                              </div>
                            ) : null}
                          </div>

                          <div className="mt-2 text-[11px] text-zinc-700">
                            {time(
                              activity.blockTime,
                            )}
                          </div>
                        </div>
                      ),
                    )
                  ) : (
                    <div className="rounded-xl border border-white/5 p-4 text-xs text-zinc-600">
                      Recent token balance changes were not
                      available from the inspected transactions.
                    </div>
                  )}
                </div>
              </div>
            </section>

            <section className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
              <h2 className="font-medium text-white">
                Data quality
              </h2>
              <div className="mt-3 grid gap-2 md:grid-cols-2">
                {report.limitations.map(
                  (item) => (
                    <div
                      key={item}
                      className="rounded-xl border border-white/5 bg-black/15 p-3 text-xs leading-5 text-zinc-600"
                    >
                      {item}
                    </div>
                  ),
                )}
              </div>
              <div className="mt-4 text-xs text-zinc-700">
                RPC: {report.rpcSource} · updated{" "}
                {new Date(
                  report.updatedAt,
                ).toLocaleTimeString()}
              </div>
            </section>
          </>
        ) : null}
      </div>
    </AppShell>
  );
}
'@ | Set-Content -Encoding UTF8 "src/app/wallets/page.tsx"

Step "Update sidebar dengan Wallets"
@'
"use client";

import {
  Bell,
  Eye,
  LayoutDashboard,
  Radar,
  Rocket,
  Settings,
  Sparkles,
  WalletCards,
} from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

const items = [
  {
    href: "/scanner",
    label: "Scanner",
    icon: Radar,
  },
  {
    href: "/discover",
    label: "Discover",
    icon: Rocket,
  },
  {
    href: "/wallets",
    label: "Wallets",
    icon: WalletCards,
  },
  {
    href: "/watchlist",
    label: "Watchlist",
    icon: Eye,
  },
  {
    href: "/alerts",
    label: "Alerts",
    icon: Bell,
  },
  {
    href: "/settings",
    label: "Settings",
    icon: Settings,
  },
];

export function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="hidden min-h-screen w-64 shrink-0 border-r border-white/8 bg-[#090b10] lg:block">
      <div className="sticky top-0 p-5">
        <div className="mb-8 flex items-center gap-3">
          <div className="grid h-10 w-10 place-items-center rounded-xl border border-emerald-400/30 bg-emerald-400/10">
            <Sparkles className="h-5 w-5 text-emerald-300" />
          </div>
          <div>
            <div className="font-semibold tracking-tight text-white">
              MemeScope
            </div>
            <div className="text-xs text-zinc-500">
              Market Intelligence
            </div>
          </div>
        </div>

        <div className="mb-3 flex items-center gap-2 px-3 text-xs uppercase tracking-[0.18em] text-zinc-600">
          <LayoutDashboard className="h-3.5 w-3.5" />
          Workspace
        </div>

        <nav className="space-y-1">
          {items.map((item) => {
            const active =
              pathname === item.href ||
              pathname.startsWith(`${item.href}/`);
            const Icon = item.icon;

            return (
              <Link
                key={item.href}
                href={item.href}
                className={`flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm transition ${
                  active
                    ? "bg-white text-black"
                    : "text-zinc-400 hover:bg-white/5 hover:text-white"
                }`}
              >
                <Icon className="h-4 w-4" />
                {item.label}
              </Link>
            );
          })}
        </nav>

        <div className="mt-8 rounded-2xl border border-white/8 bg-white/[0.025] p-4">
          <div className="mb-1 text-xs text-zinc-500">
            Build
          </div>
          <div className="flex items-center gap-2 text-sm text-zinc-200">
            <span className="h-2 w-2 rounded-full bg-emerald-400" />
            Stage 05
          </div>
          <p className="mt-2 text-xs leading-5 text-zinc-600">
            Market, risk, discovery and wallet intelligence
            enabled.
          </p>
        </div>
      </div>
    </aside>
  );
}
'@ | Set-Content -Encoding UTF8 "src/components/sidebar.tsx"

Step "Membersihkan cache"
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue

Step "Menjalankan lint"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Stage 05 Wallet Tracker berhasil dipasang." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor White
Write-Host "  npm run dev" -ForegroundColor Yellow
Write-Host ""
Write-Host "Buka:" -ForegroundColor White
Write-Host "  http://localhost:3000/wallets" -ForegroundColor Yellow
Write-Host ""
Write-Host "Paste Solana wallet address lalu klik Inspect." -ForegroundColor DarkGray
