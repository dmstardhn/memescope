$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$ProjectRoot = (Get-Location).Path

if (-not (Test-Path "package.json")) {
    throw "package.json tidak ditemukan. Jalankan script ini dari folder memecoin-analyst."
}

if (-not (Test-Path "src/app/scanner/page.tsx")) {
    throw "src/app/scanner/page.tsx tidak ditemukan. Pastikan kamu berada di project memecoin-analyst."
}

Write-Step "Membuat backup scanner lama"
$BackupDir = "backup-stage-02"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
Copy-Item "src/app/scanner/page.tsx" "$BackupDir/scanner-page.tsx.bak" -Force

Write-Step "Membuat market types"
@'
export type DexPair = {
  chainId?: string;
  dexId?: string;
  url?: string;
  pairAddress?: string;
  labels?: string[];
  baseToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };
  quoteToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };
  priceNative?: string;
  priceUsd?: string | null;
  txns?: Record<
    string,
    {
      buys?: number;
      sells?: number;
    }
  >;
  volume?: Record<string, number>;
  priceChange?: Record<string, number> | null;
  liquidity?: {
    usd?: number | null;
    base?: number;
    quote?: number;
  } | null;
  fdv?: number | null;
  marketCap?: number | null;
  pairCreatedAt?: number | null;
  info?: {
    imageUrl?: string | null;
    websites?: Array<{ url?: string }>;
    socials?: Array<{ platform?: string; handle?: string }>;
  };
  boosts?: {
    active?: number;
  };
};

export type LiveToken = {
  chainId: "solana";
  dexId: string;
  pairAddress: string;
  tokenAddress: string;
  name: string;
  symbol: string;
  quoteSymbol: string;
  imageUrl: string | null;
  dexUrl: string;
  priceUsd: number;
  marketCap: number;
  fdv: number;
  liquidity: number;
  volume5m: number;
  volume1h: number;
  volume6h: number;
  volume24h: number;
  buys5m: number;
  sells5m: number;
  buys1h: number;
  sells1h: number;
  priceChange5m: number;
  priceChange1h: number;
  priceChange6h: number;
  priceChange24h: number;
  pairCreatedAt: number | null;
  ageMinutes: number | null;
  boosts: number;
  score: number;
  riskLabel: "Lower" | "Medium" | "Higher";
};

export type SolanaMarketResponse = {
  ok: boolean;
  source: string;
  mode: string;
  refreshMs: number;
  discoveryRefreshMs: number;
  updatedAt: number;
  discovered: number;
  tokens: LiveToken[];
  error?: string;
};
'@ | Set-Content -Encoding UTF8 "src/lib/dex-types.ts"

Write-Step "Membuat scoring engine"
@'
import type { DexPair, LiveToken } from "@/lib/dex-types";

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function timeframe(
  source: Record<string, number> | null | undefined,
  key: string,
) {
  return n(source?.[key]);
}

function txn(
  source: DexPair["txns"],
  frame: string,
  side: "buys" | "sells",
) {
  return n(source?.[frame]?.[side]);
}

export function scorePair(pair: DexPair): number {
  const liquidity = n(pair.liquidity?.usd);
  const marketCap = n(pair.marketCap ?? pair.fdv);
  const volume5m = timeframe(pair.volume, "m5");
  const volume1h = timeframe(pair.volume, "h1");
  const change5m = timeframe(pair.priceChange ?? undefined, "m5");
  const buys5m = txn(pair.txns, "m5", "buys");
  const sells5m = txn(pair.txns, "m5", "sells");
  const trades5m = buys5m + sells5m;

  const liquidityScore = clamp(
    18 * Math.log10(Math.max(liquidity, 1)) - 35,
  );

  const liquidityRatio =
    marketCap > 0 ? clamp((liquidity / marketCap) * 260) : 20;

  const activityScore = clamp(
    Math.log10(Math.max(volume5m, 1)) * 18 +
      Math.log10(Math.max(volume1h, 1)) * 8 -
      44,
  );

  const buyRatio =
    trades5m > 0 ? buys5m / Math.max(trades5m, 1) : 0.5;
  const flowScore = clamp(50 + (buyRatio - 0.5) * 90);

  const momentumScore = clamp(50 + change5m * 1.6);

  const score =
    liquidityScore * 0.28 +
    liquidityRatio * 0.22 +
    activityScore * 0.25 +
    flowScore * 0.15 +
    momentumScore * 0.1;

  return Math.round(clamp(score));
}

export function riskFromPair(
  pair: DexPair,
): LiveToken["riskLabel"] {
  const liquidity = n(pair.liquidity?.usd);
  const marketCap = n(pair.marketCap ?? pair.fdv);
  const ratio = marketCap > 0 ? liquidity / marketCap : 0;
  const sells = txn(pair.txns, "m5", "sells");
  const buys = txn(pair.txns, "m5", "buys");

  if (
    liquidity < 10_000 ||
    (marketCap > 0 && ratio < 0.05) ||
    (sells > buys * 2 && sells > 10)
  ) {
    return "Higher";
  }

  if (liquidity < 30_000 || (marketCap > 0 && ratio < 0.12)) {
    return "Medium";
  }

  return "Lower";
}

export function pairToLiveToken(pair: DexPair): LiveToken | null {
  const tokenAddress = pair.baseToken?.address;
  const pairAddress = pair.pairAddress;

  if (!tokenAddress || !pairAddress) return null;

  const now = Date.now();
  const createdAt =
    typeof pair.pairCreatedAt === "number" ? pair.pairCreatedAt : null;

  return {
    chainId: "solana",
    dexId: pair.dexId || "unknown",
    pairAddress,
    tokenAddress,
    name: pair.baseToken?.name || "Unknown Token",
    symbol: pair.baseToken?.symbol || "UNKNOWN",
    quoteSymbol: pair.quoteToken?.symbol || "",
    imageUrl: pair.info?.imageUrl || null,
    dexUrl:
      pair.url ||
      `https://dexscreener.com/solana/${encodeURIComponent(pairAddress)}`,
    priceUsd: n(pair.priceUsd),
    marketCap: n(pair.marketCap),
    fdv: n(pair.fdv),
    liquidity: n(pair.liquidity?.usd),
    volume5m: timeframe(pair.volume, "m5"),
    volume1h: timeframe(pair.volume, "h1"),
    volume6h: timeframe(pair.volume, "h6"),
    volume24h: timeframe(pair.volume, "h24"),
    buys5m: txn(pair.txns, "m5", "buys"),
    sells5m: txn(pair.txns, "m5", "sells"),
    buys1h: txn(pair.txns, "h1", "buys"),
    sells1h: txn(pair.txns, "h1", "sells"),
    priceChange5m: timeframe(pair.priceChange ?? undefined, "m5"),
    priceChange1h: timeframe(pair.priceChange ?? undefined, "h1"),
    priceChange6h: timeframe(pair.priceChange ?? undefined, "h6"),
    priceChange24h: timeframe(pair.priceChange ?? undefined, "h24"),
    pairCreatedAt: createdAt,
    ageMinutes: createdAt
      ? Math.max(0, Math.floor((now - createdAt) / 60_000))
      : null,
    boosts: n(pair.boosts?.active),
    score: scorePair(pair),
    riskLabel: riskFromPair(pair),
  };
}
'@ | Set-Content -Encoding UTF8 "src/lib/market-score.ts"

Write-Step "Membuat Solana real-market API"
New-Item -ItemType Directory -Force -Path "src/app/api/market/solana" | Out-Null

@'
import { NextResponse } from "next/server";
import type {
  DexPair,
  SolanaMarketResponse,
} from "@/lib/dex-types";
import { pairToLiveToken } from "@/lib/market-score";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const DISCOVERY_TTL = 20_000;
const MARKET_TTL = 2_000;
const MAX_TOKENS = 30;

type DiscoveryItem = {
  chainId?: string;
  tokenAddress?: string;
};

let discoveryCache: {
  expiresAt: number;
  addresses: string[];
} = {
  expiresAt: 0,
  addresses: [],
};

let marketCache: {
  expiresAt: number;
  payload: SolanaMarketResponse | null;
} = {
  expiresAt: 0,
  payload: null,
};

async function getJson(url: string) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "MemeScope/0.2",
    },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `Upstream request failed (${response.status})`,
    );
  }

  return response.json();
}

function asArray<T>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[];
  if (value && typeof value === "object") return [value as T];
  return [];
}

async function discoverSolanaAddresses() {
  const now = Date.now();

  if (
    discoveryCache.addresses.length > 0 &&
    now < discoveryCache.expiresAt
  ) {
    return discoveryCache.addresses;
  }

  const settled = await Promise.allSettled([
    getJson("https://api.dexscreener.com/token-profiles/latest/v1"),
    getJson("https://api.dexscreener.com/token-boosts/latest/v1"),
    getJson("https://api.dexscreener.com/token-boosts/top/v1"),
  ]);

  const addresses = new Set<string>();

  for (const result of settled) {
    if (result.status !== "fulfilled") continue;

    for (const item of asArray<DiscoveryItem>(result.value)) {
      if (
        item.chainId?.toLowerCase() === "solana" &&
        item.tokenAddress
      ) {
        addresses.add(item.tokenAddress);
      }

      if (addresses.size >= MAX_TOKENS) break;
    }

    if (addresses.size >= MAX_TOKENS) break;
  }

  const nextAddresses = Array.from(addresses).slice(0, MAX_TOKENS);

  if (nextAddresses.length > 0) {
    discoveryCache = {
      expiresAt: now + DISCOVERY_TTL,
      addresses: nextAddresses,
    };
  }

  return nextAddresses;
}

function chooseBestPairs(pairs: DexPair[]) {
  const best = new Map<string, DexPair>();

  for (const pair of pairs) {
    const address = pair.baseToken?.address;
    if (!address) continue;

    const current = best.get(address);
    const currentLiquidity = Number(current?.liquidity?.usd || 0);
    const nextLiquidity = Number(pair.liquidity?.usd || 0);

    if (!current || nextLiquidity > currentLiquidity) {
      best.set(address, pair);
    }
  }

  return Array.from(best.values());
}

async function fetchMarketPairs(addresses: string[]) {
  if (addresses.length === 0) return [];

  const encoded = addresses
    .map((address) => encodeURIComponent(address))
    .join(",");

  const data = await getJson(
    `https://api.dexscreener.com/tokens/v1/solana/${encoded}`,
  );

  if (Array.isArray(data)) {
    return data as DexPair[];
  }

  if (
    data &&
    typeof data === "object" &&
    Array.isArray((data as { pairs?: DexPair[] }).pairs)
  ) {
    return (data as { pairs: DexPair[] }).pairs;
  }

  return [];
}

export async function GET() {
  const now = Date.now();

  if (
    marketCache.payload &&
    now < marketCache.expiresAt
  ) {
    return NextResponse.json(marketCache.payload, {
      headers: {
        "Cache-Control": "no-store",
      },
    });
  }

  try {
    const addresses = await discoverSolanaAddresses();

    if (addresses.length === 0) {
      throw new Error("No Solana token candidates discovered.");
    }

    const pairs = await fetchMarketPairs(addresses);
    const bestPairs = chooseBestPairs(pairs);

    const tokens = bestPairs
      .map(pairToLiveToken)
      .filter((token) => token !== null)
      .filter((token) => token.liquidity > 0)
      .sort((a, b) => {
        const scoreDiff = b.score - a.score;
        if (scoreDiff !== 0) return scoreDiff;
        return b.volume5m - a.volume5m;
      });

    const payload: SolanaMarketResponse = {
      ok: true,
      source: "DEX Screener",
      mode: "near-real-time REST",
      refreshMs: MARKET_TTL,
      discoveryRefreshMs: DISCOVERY_TTL,
      updatedAt: Date.now(),
      discovered: addresses.length,
      tokens,
    };

    marketCache = {
      expiresAt: Date.now() + MARKET_TTL,
      payload,
    };

    return NextResponse.json(payload, {
      headers: {
        "Cache-Control": "no-store",
      },
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Unknown market error";

    if (marketCache.payload) {
      return NextResponse.json(
        {
          ...marketCache.payload,
          ok: false,
          error: message,
        },
        {
          headers: {
            "Cache-Control": "no-store",
          },
        },
      );
    }

    return NextResponse.json(
      {
        ok: false,
        source: "DEX Screener",
        mode: "near-real-time REST",
        refreshMs: MARKET_TTL,
        discoveryRefreshMs: DISCOVERY_TTL,
        updatedAt: Date.now(),
        discovered: 0,
        tokens: [],
        error: message,
      } satisfies SolanaMarketResponse,
      {
        status: 502,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  }
}
'@ | Set-Content -Encoding UTF8 "src/app/api/market/solana/route.ts"

Write-Step "Mengganti scanner menjadi live market scanner"
@'
"use client";

import { AppShell } from "@/components/app-shell";
import { StatCard } from "@/components/stat-card";
import type {
  LiveToken,
  SolanaMarketResponse,
} from "@/lib/dex-types";
import { age, money, pct } from "@/lib/format";
import {
  Activity,
  ArrowUpRight,
  CircleDot,
  RefreshCw,
  Search,
  Signal,
  Wifi,
  WifiOff,
} from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

const REFRESH_MS = 2_000;

function price(value: number) {
  if (!Number.isFinite(value) || value <= 0) return "$0";

  if (value >= 1) {
    return `$${value.toLocaleString("en-US", {
      maximumFractionDigits: 6,
    })}`;
  }

  if (value >= 0.01) return `$${value.toFixed(6)}`;
  if (value >= 0.0001) return `$${value.toFixed(8)}`;

  return `$${value.toPrecision(5)}`;
}

function secondsAgo(timestamp: number, now: number) {
  const seconds = Math.max(
    0,
    Math.floor((now - timestamp) / 1000),
  );

  if (seconds < 2) return "just now";
  return `${seconds}s ago`;
}

function riskClass(risk: LiveToken["riskLabel"]) {
  if (risk === "Lower") {
    return "border-emerald-400/20 bg-emerald-400/10 text-emerald-300";
  }

  if (risk === "Higher") {
    return "border-rose-400/20 bg-rose-400/10 text-rose-300";
  }

  return "border-amber-400/20 bg-amber-400/10 text-amber-300";
}

export default function ScannerPage() {
  const [market, setMarket] =
    useState<SolanaMarketResponse | null>(null);
  const [query, setQuery] = useState("");
  const [risk, setRisk] = useState("All");
  const [sort, setSort] = useState("Score");
  const [error, setError] = useState("");
  const [now, setNow] = useState(Date.now());
  const [priceMoves, setPriceMoves] = useState<
    Record<string, "up" | "down">
  >({});

  const previousPrices = useRef<Record<string, number>>({});
  const fetching = useRef(false);

  const loadMarket = useCallback(async () => {
    if (fetching.current) return;
    fetching.current = true;

    try {
      const response = await fetch("/api/market/solana", {
        cache: "no-store",
      });
      const data =
        (await response.json()) as SolanaMarketResponse;

      if (!response.ok && !data.tokens?.length) {
        throw new Error(data.error || "Market request failed");
      }

      const nextMoves: Record<string, "up" | "down"> = {};

      for (const token of data.tokens || []) {
        const previous =
          previousPrices.current[token.pairAddress];

        if (
          previous !== undefined &&
          token.priceUsd !== previous
        ) {
          nextMoves[token.pairAddress] =
            token.priceUsd > previous ? "up" : "down";
        }

        previousPrices.current[token.pairAddress] =
          token.priceUsd;
      }

      setPriceMoves(nextMoves);
      setMarket(data);
      setError(data.error || "");

      window.setTimeout(() => {
        setPriceMoves({});
      }, 850);
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "Unable to load live market.",
      );
    } finally {
      fetching.current = false;
    }
  }, []);

  useEffect(() => {
    loadMarket();

    const marketTimer = window.setInterval(
      loadMarket,
      REFRESH_MS,
    );

    const clockTimer = window.setInterval(() => {
      setNow(Date.now());
    }, 1_000);

    return () => {
      window.clearInterval(marketTimer);
      window.clearInterval(clockTimer);
    };
  }, [loadMarket]);

  const tokens = useMemo(() => {
    const source = [...(market?.tokens || [])];
    const q = query.trim().toLowerCase();

    const filtered = source
      .filter((token) => {
        if (!q) return true;

        return (
          token.name.toLowerCase().includes(q) ||
          token.symbol.toLowerCase().includes(q) ||
          token.tokenAddress.toLowerCase().includes(q) ||
          token.pairAddress.toLowerCase().includes(q)
        );
      })
      .filter(
        (token) =>
          risk === "All" || token.riskLabel === risk,
      );

    filtered.sort((a, b) => {
      if (sort === "5m Volume") {
        return b.volume5m - a.volume5m;
      }

      if (sort === "Liquidity") {
        return b.liquidity - a.liquidity;
      }

      if (sort === "Newest") {
        const aTime = a.pairCreatedAt ?? 0;
        const bTime = b.pairCreatedAt ?? 0;
        return bTime - aTime;
      }

      if (sort === "5m Change") {
        return b.priceChange5m - a.priceChange5m;
      }

      return b.score - a.score;
    });

    return filtered;
  }, [market?.tokens, query, risk, sort]);

  const stats = useMemo(() => {
    const source = market?.tokens || [];

    const volume = source.reduce(
      (sum, token) => sum + token.volume5m,
      0,
    );

    const liquidity = source.reduce(
      (sum, token) => sum + token.liquidity,
      0,
    );

    const trades = source.reduce(
      (sum, token) =>
        sum + token.buys5m + token.sells5m,
      0,
    );

    return {
      volume,
      liquidity,
      trades,
    };
  }, [market?.tokens]);

  const connected = Boolean(market?.tokens?.length);

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-center xl:justify-between">
          <div>
            <div className="flex items-center gap-2 text-sm text-emerald-300">
              <Signal className="h-4 w-4" />
              Solana Memecoin Intelligence
            </div>
            <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
              Live Market Scanner
            </h1>
            <p className="mt-1 max-w-2xl text-sm text-zinc-500">
              Active Solana tokens discovered from DEX Screener
              profiles and boosts, with market data refreshing
              automatically.
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <div
              className={`flex items-center gap-2 rounded-full border px-3 py-2 text-xs ${
                connected
                  ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                  : "border-rose-400/20 bg-rose-400/10 text-rose-300"
              }`}
            >
              {connected ? (
                <Wifi className="h-3.5 w-3.5" />
              ) : (
                <WifiOff className="h-3.5 w-3.5" />
              )}
              {connected ? "Market connected" : "Connecting"}
            </div>

            <div className="rounded-full border border-white/8 bg-white/[0.025] px-3 py-2 text-xs text-zinc-500">
              Auto refresh · 2s
            </div>
          </div>
        </div>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        <section className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          <StatCard
            label="Live pairs"
            value={String(market?.tokens?.length || 0)}
            sub={`${market?.discovered || 0} token candidates`}
          />
          <StatCard
            label="5M volume"
            value={money(stats.volume)}
            sub="Visible live universe"
          />
          <StatCard
            label="Liquidity"
            value={money(stats.liquidity)}
            sub="Combined USD liquidity"
          />
          <StatCard
            label="5M trades"
            value={stats.trades.toLocaleString("en-US")}
            sub="Buys + sells"
          />
        </section>

        <section className="rounded-2xl border border-white/8 bg-white/[0.025]">
          <div className="flex flex-col gap-3 border-b border-white/8 p-4 xl:flex-row xl:items-center xl:justify-between">
            <div className="relative min-w-0 flex-1">
              <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />
              <input
                value={query}
                onChange={(event) =>
                  setQuery(event.target.value)
                }
                placeholder="Filter symbol, name, token CA or pair..."
                className="h-10 w-full rounded-xl border border-white/8 bg-black/20 pl-10 pr-3 text-sm outline-none transition placeholder:text-zinc-700 focus:border-emerald-400/50"
              />
            </div>

            <div className="flex flex-wrap gap-2">
              <select
                value={risk}
                onChange={(event) =>
                  setRisk(event.target.value)
                }
                className="h-10 rounded-xl border border-white/8 bg-[#0e1118] px-3 text-sm text-zinc-300 outline-none"
              >
                <option>All</option>
                <option>Lower</option>
                <option>Medium</option>
                <option>Higher</option>
              </select>

              <select
                value={sort}
                onChange={(event) =>
                  setSort(event.target.value)
                }
                className="h-10 rounded-xl border border-white/8 bg-[#0e1118] px-3 text-sm text-zinc-300 outline-none"
              >
                <option>Score</option>
                <option>5m Volume</option>
                <option>Liquidity</option>
                <option>Newest</option>
                <option>5m Change</option>
              </select>

              <button
                onClick={loadMarket}
                className="inline-flex h-10 items-center gap-2 rounded-xl border border-white/8 bg-white/[0.03] px-3 text-sm text-zinc-300 hover:bg-white/[0.06]"
              >
                <RefreshCw className="h-4 w-4" />
                Refresh
              </button>
            </div>
          </div>

          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-white/8 px-4 py-3 text-xs">
            <div className="flex items-center gap-2 text-zinc-500">
              <CircleDot
                className={`h-3.5 w-3.5 ${
                  connected
                    ? "text-emerald-300"
                    : "text-zinc-600"
                }`}
              />
              Source: {market?.source || "DEX Screener"}
              <span className="text-zinc-700">•</span>
              {market?.mode || "near-real-time REST"}
            </div>

            <div className="text-zinc-600">
              Updated{" "}
              {market?.updatedAt
                ? secondsAgo(market.updatedAt, now)
                : "—"}
            </div>
          </div>

          {error ? (
            <div className="border-b border-amber-400/10 bg-amber-400/5 px-4 py-3 text-xs text-amber-200/70">
              {error}
            </div>
          ) : null}

          <div className="overflow-x-auto">
            <table className="w-full min-w-[1240px] border-collapse text-left text-sm">
              <thead className="text-xs uppercase tracking-[0.08em] text-zinc-600">
                <tr className="border-b border-white/8">
                  <th className="px-4 py-3 font-medium">Token</th>
                  <th className="px-4 py-3 font-medium">Price</th>
                  <th className="px-4 py-3 font-medium">Score</th>
                  <th className="px-4 py-3 font-medium">Risk</th>
                  <th className="px-4 py-3 font-medium">Age</th>
                  <th className="px-4 py-3 font-medium">Market Cap</th>
                  <th className="px-4 py-3 font-medium">Liquidity</th>
                  <th className="px-4 py-3 font-medium">5M Volume</th>
                  <th className="px-4 py-3 font-medium">5M B/S</th>
                  <th className="px-4 py-3 font-medium">5M</th>
                  <th className="px-4 py-3 font-medium">1H</th>
                  <th className="px-4 py-3 font-medium"></th>
                </tr>
              </thead>

              <tbody>
                {tokens.map((token) => {
                  const move =
                    priceMoves[token.pairAddress];

                  return (
                    <tr
                      key={token.pairAddress}
                      className="border-b border-white/5 transition hover:bg-white/[0.025]"
                    >
                      <td className="px-4 py-4">
                        <div className="flex items-center gap-3">
                          {token.imageUrl ? (
                            <img
                              src={token.imageUrl}
                              alt=""
                              className="h-9 w-9 rounded-full border border-white/8 object-cover"
                            />
                          ) : (
                            <div className="grid h-9 w-9 place-items-center rounded-full border border-white/8 bg-white/5 text-xs text-zinc-500">
                              {token.symbol
                                .slice(0, 2)
                                .toUpperCase()}
                            </div>
                          )}

                          <div className="min-w-0">
                            <div className="font-medium text-white">
                              ${token.symbol}
                            </div>
                            <div className="max-w-40 truncate text-xs text-zinc-600">
                              {token.name} · {token.dexId}
                            </div>
                          </div>
                        </div>
                      </td>

                      <td className="px-4 py-4">
                        <div
                          className={`inline-flex rounded-md px-1.5 py-1 font-medium transition-colors duration-300 ${
                            move === "up"
                              ? "bg-emerald-400/15 text-emerald-200"
                              : move === "down"
                                ? "bg-rose-400/15 text-rose-200"
                                : "text-zinc-200"
                          }`}
                        >
                          {price(token.priceUsd)}
                        </div>
                      </td>

                      <td className="px-4 py-4">
                        <span className="rounded-lg border border-emerald-400/20 bg-emerald-400/10 px-2 py-1 font-semibold text-emerald-300">
                          {token.score}
                        </span>
                      </td>

                      <td className="px-4 py-4">
                        <span
                          className={`rounded-full border px-2.5 py-1 text-xs ${riskClass(token.riskLabel)}`}
                        >
                          {token.riskLabel}
                        </span>
                      </td>

                      <td className="px-4 py-4 text-zinc-400">
                        {token.ageMinutes === null
                          ? "—"
                          : age(token.ageMinutes)}
                      </td>

                      <td className="px-4 py-4 text-zinc-300">
                        {money(
                          token.marketCap ||
                            token.fdv,
                        )}
                      </td>

                      <td className="px-4 py-4 text-zinc-300">
                        {money(token.liquidity)}
                      </td>

                      <td className="px-4 py-4 text-zinc-300">
                        {money(token.volume5m)}
                      </td>

                      <td className="px-4 py-4">
                        <span className="text-emerald-300">
                          {token.buys5m}
                        </span>
                        <span className="px-1 text-zinc-700">
                          /
                        </span>
                        <span className="text-rose-300">
                          {token.sells5m}
                        </span>
                      </td>

                      <td
                        className={`px-4 py-4 ${
                          token.priceChange5m >= 0
                            ? "text-emerald-300"
                            : "text-rose-300"
                        }`}
                      >
                        {pct(token.priceChange5m)}
                      </td>

                      <td
                        className={`px-4 py-4 ${
                          token.priceChange1h >= 0
                            ? "text-emerald-300"
                            : "text-rose-300"
                        }`}
                      >
                        {pct(token.priceChange1h)}
                      </td>

                      <td className="px-4 py-4">
                        <a
                          href={token.dexUrl}
                          target="_blank"
                          rel="noreferrer"
                          className="inline-flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
                        >
                          DEX
                          <ArrowUpRight className="h-3.5 w-3.5" />
                        </a>
                      </td>
                    </tr>
                  );
                })}

                {!tokens.length ? (
                  <tr>
                    <td
                      colSpan={12}
                      className="px-4 py-16 text-center"
                    >
                      <Activity className="mx-auto h-6 w-6 text-zinc-700" />
                      <div className="mt-3 text-sm text-zinc-500">
                        {market
                          ? "No token matches the current filters."
                          : "Connecting to the Solana market feed..."}
                      </div>
                    </td>
                  </tr>
                ) : null}
              </tbody>
            </table>
          </div>
        </section>

        <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-4 text-xs leading-5 text-zinc-600">
          Stage 02 uses DEX Screener REST market data and
          refreshes the selected market universe automatically.
          The score is a market-quality heuristic based on
          liquidity, activity, buy/sell flow and short-term
          momentum. It is not a prediction or investment
          recommendation. Direct Solana WebSocket transaction
          streaming will be added when an RPC provider is
          connected.
        </div>
      </div>
    </AppShell>
  );
}
'@ | Set-Content -Encoding UTF8 "src/app/scanner/page.tsx"

Write-Step "Membersihkan cache Next.js"
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue

Write-Step "Menjalankan lint"
npm run lint

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Stage 02 Real Market berhasil dipasang." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor White
Write-Host "  npm run dev" -ForegroundColor Yellow
Write-Host ""
Write-Host "Lalu buka:" -ForegroundColor White
Write-Host "  http://localhost:3000/scanner" -ForegroundColor Yellow
Write-Host ""
Write-Host "Backup scanner lama:" -ForegroundColor White
Write-Host "  $BackupDir\scanner-page.tsx.bak" -ForegroundColor DarkGray
