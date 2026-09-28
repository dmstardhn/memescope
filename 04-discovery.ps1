$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not (Test-Path "package.json")) {
    throw "package.json tidak ditemukan. Jalankan script ini dari folder memecoin-analyst."
}

if (-not (Test-Path "src/lib/market-score.ts")) {
    throw "Stage 02/03 belum terdeteksi. Pastikan project sebelumnya sudah terpasang."
}

Step "Backup file yang akan diubah"
$BackupDir = "backup-stage-04"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

if (Test-Path "src/components/sidebar.tsx") {
    Copy-Item "src/components/sidebar.tsx" "$BackupDir/sidebar.tsx.bak" -Force
}
if (Test-Path ".env.example") {
    Copy-Item ".env.example" "$BackupDir/env.example.bak" -Force
}

Step "Install WebSocket server dependency"
npm install ws
npm install -D @types/ws

Step "Membuat discovery types"
@'
export type DiscoverCategory =
  | "new"
  | "trending"
  | "volume-spike"
  | "high-score";

export type DiscoverToken = {
  chainId: "solana";
  tokenAddress: string;
  pairAddress: string;
  name: string;
  symbol: string;
  imageUrl: string | null;
  dexId: string;
  dexUrl: string;
  priceUsd: number;
  marketCap: number;
  fdv: number;
  liquidity: number;
  volume5m: number;
  volume1h: number;
  volume24h: number;
  buys5m: number;
  sells5m: number;
  priceChange5m: number;
  priceChange1h: number;
  pairCreatedAt: number | null;
  ageMinutes: number | null;
  score: number;
  trendScore: number;
  volumeSpikeRatio: number;
  buySellRatio: number;
  boosts: number;
  categories: DiscoverCategory[];
};

export type DiscoverResponse = {
  ok: boolean;
  source: string;
  updatedAt: number;
  refreshMs: number;
  discoveryRefreshMs: number;
  candidates: number;
  tokens: DiscoverToken[];
  error?: string;
};

export type PumpLiveEvent = {
  receivedAt: number;
  type: "new-token" | "migration" | "unknown";
  mint: string | null;
  name: string | null;
  symbol: string | null;
  signature: string | null;
  rawType: string | null;
};
'@ | Set-Content -Encoding UTF8 "src/lib/discover-types.ts"

Step "Membuat discovery engine"
@'
import type { DexPair } from "@/lib/dex-types";
import type {
  DiscoverCategory,
  DiscoverToken,
} from "@/lib/discover-types";
import {
  pairToLiveToken,
  scorePair,
} from "@/lib/market-score";

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

function logScore(value: number, scale: number) {
  if (value <= 0) return 0;
  return clamp(Math.log10(value + 1) * scale);
}

export function enrichDiscoverPair(
  pair: DexPair,
): DiscoverToken | null {
  const base = pairToLiveToken(pair);
  if (!base) return null;

  const buys = base.buys5m;
  const sells = base.sells5m;
  const totalTrades = buys + sells;

  const buySellRatio =
    sells > 0 ? buys / sells : buys > 0 ? buys : 0;

  // Compare current 5m activity against the expected 5m slice
  // of the current 1h aggregate. Ratio > 1 means acceleration.
  const expected5m =
    base.volume1h > 0 ? base.volume1h / 12 : 0;

  const volumeSpikeRatio =
    expected5m > 0
      ? base.volume5m / expected5m
      : base.volume5m > 0
        ? 1
        : 0;

  const flow =
    totalTrades > 0 ? buys / totalTrades : 0.5;

  const trendScore = Math.round(
    clamp(
      logScore(base.volume5m, 18) * 0.28 +
        clamp(volumeSpikeRatio * 22) * 0.26 +
        clamp(50 + base.priceChange5m * 1.8) * 0.18 +
        clamp(50 + (flow - 0.5) * 110) * 0.18 +
        clamp(base.boosts * 10) * 0.1,
    ),
  );

  const categories: DiscoverCategory[] = [];

  if (
    base.ageMinutes !== null &&
    base.ageMinutes <= 360
  ) {
    categories.push("new");
  }

  if (
    trendScore >= 62 &&
    base.volume5m >= 2_000
  ) {
    categories.push("trending");
  }

  if (
    volumeSpikeRatio >= 1.8 &&
    base.volume5m >= 1_000
  ) {
    categories.push("volume-spike");
  }

  if (scorePair(pair) >= 70) {
    categories.push("high-score");
  }

  return {
    chainId: "solana",
    tokenAddress: base.tokenAddress,
    pairAddress: base.pairAddress,
    name: base.name,
    symbol: base.symbol,
    imageUrl: base.imageUrl,
    dexId: base.dexId,
    dexUrl: base.dexUrl,
    priceUsd: base.priceUsd,
    marketCap: base.marketCap,
    fdv: base.fdv,
    liquidity: base.liquidity,
    volume5m: base.volume5m,
    volume1h: base.volume1h,
    volume24h: base.volume24h,
    buys5m: base.buys5m,
    sells5m: base.sells5m,
    priceChange5m: base.priceChange5m,
    priceChange1h: base.priceChange1h,
    pairCreatedAt: base.pairCreatedAt,
    ageMinutes: base.ageMinutes,
    score: base.score,
    trendScore,
    volumeSpikeRatio: n(volumeSpikeRatio),
    buySellRatio: n(buySellRatio),
    boosts: base.boosts,
    categories,
  };
}
'@ | Set-Content -Encoding UTF8 "src/lib/discover-engine.ts"

Step "Membuat discovery API"
New-Item -ItemType Directory -Force -Path "src/app/api/discover/solana" | Out-Null

@'
import { NextResponse } from "next/server";
import type { DexPair } from "@/lib/dex-types";
import type { DiscoverResponse } from "@/lib/discover-types";
import { enrichDiscoverPair } from "@/lib/discover-engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const DISCOVERY_TTL = 15_000;
const MARKET_TTL = 3_000;
const MAX_ADDRESSES = 30;

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
  payload: DiscoverResponse | null;
} = {
  expiresAt: 0,
  payload: null,
};

async function json(url: string) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "MemeScope/0.4",
    },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `DEX Screener upstream returned ${response.status}`,
    );
  }

  return response.json();
}

function toArray<T>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[];
  if (value && typeof value === "object")
    return [value as T];
  return [];
}

async function discoverAddresses() {
  const now = Date.now();

  if (
    discoveryCache.addresses.length &&
    now < discoveryCache.expiresAt
  ) {
    return discoveryCache.addresses;
  }

  const endpoints = [
    "https://api.dexscreener.com/token-profiles/latest/v1",
    "https://api.dexscreener.com/token-profiles/recent-updates/v1",
    "https://api.dexscreener.com/token-boosts/latest/v1",
    "https://api.dexscreener.com/token-boosts/top/v1",
  ];

  const settled = await Promise.allSettled(
    endpoints.map((endpoint) => json(endpoint)),
  );

  const ordered: string[] = [];
  const seen = new Set<string>();

  for (const result of settled) {
    if (result.status !== "fulfilled") continue;

    for (const item of toArray<DiscoveryItem>(
      result.value,
    )) {
      const address = item.tokenAddress;

      if (
        item.chainId?.toLowerCase() !== "solana" ||
        !address ||
        seen.has(address)
      ) {
        continue;
      }

      seen.add(address);
      ordered.push(address);

      if (ordered.length >= MAX_ADDRESSES) break;
    }

    if (ordered.length >= MAX_ADDRESSES) break;
  }

  if (ordered.length) {
    discoveryCache = {
      expiresAt: now + DISCOVERY_TTL,
      addresses: ordered,
    };
  }

  return ordered;
}

async function fetchPairs(addresses: string[]) {
  if (!addresses.length) return [];

  const joined = addresses
    .map((address) => encodeURIComponent(address))
    .join(",");

  const data = await json(
    `https://api.dexscreener.com/tokens/v1/solana/${joined}`,
  );

  if (Array.isArray(data)) return data as DexPair[];

  if (
    data &&
    typeof data === "object" &&
    Array.isArray(
      (data as { pairs?: DexPair[] }).pairs,
    )
  ) {
    return (data as { pairs: DexPair[] }).pairs;
  }

  return [];
}

function bestPairPerToken(pairs: DexPair[]) {
  const map = new Map<string, DexPair>();

  for (const pair of pairs) {
    const address = pair.baseToken?.address;
    if (!address) continue;

    const existing = map.get(address);
    const oldLiquidity = Number(
      existing?.liquidity?.usd || 0,
    );
    const newLiquidity = Number(
      pair.liquidity?.usd || 0,
    );

    if (!existing || newLiquidity > oldLiquidity) {
      map.set(address, pair);
    }
  }

  return Array.from(map.values());
}

export async function GET() {
  const now = Date.now();

  if (
    marketCache.payload &&
    now < marketCache.expiresAt
  ) {
    return NextResponse.json(marketCache.payload, {
      headers: { "Cache-Control": "no-store" },
    });
  }

  try {
    const addresses = await discoverAddresses();
    const pairs = await fetchPairs(addresses);
    const best = bestPairPerToken(pairs);

    const tokens = best
      .map(enrichDiscoverPair)
      .filter((token) => token !== null)
      .filter(
        (token) =>
          token.liquidity > 0 ||
          token.volume5m > 0,
      )
      .sort((a, b) => {
        if (
          a.ageMinutes !== null &&
          b.ageMinutes !== null &&
          a.ageMinutes !== b.ageMinutes
        ) {
          return a.ageMinutes - b.ageMinutes;
        }

        return b.trendScore - a.trendScore;
      });

    const payload: DiscoverResponse = {
      ok: true,
      source: "DEX Screener discovery + market data",
      updatedAt: Date.now(),
      refreshMs: MARKET_TTL,
      discoveryRefreshMs: DISCOVERY_TTL,
      candidates: addresses.length,
      tokens,
    };

    marketCache = {
      expiresAt: Date.now() + MARKET_TTL,
      payload,
    };

    return NextResponse.json(payload, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Discovery failed.";

    if (marketCache.payload) {
      return NextResponse.json(
        {
          ...marketCache.payload,
          ok: false,
          error: message,
        },
        {
          headers: { "Cache-Control": "no-store" },
        },
      );
    }

    return NextResponse.json(
      {
        ok: false,
        source: "DEX Screener discovery + market data",
        updatedAt: Date.now(),
        refreshMs: MARKET_TTL,
        discoveryRefreshMs: DISCOVERY_TTL,
        candidates: 0,
        tokens: [],
        error: message,
      } satisfies DiscoverResponse,
      {
        status: 502,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }
}
'@ | Set-Content -Encoding UTF8 "src/app/api/discover/solana/route.ts"

Step "Membuat PumpPortal WebSocket hub (aktif saat API key tersedia)"
@'
import WebSocket from "ws";
import type { PumpLiveEvent } from "@/lib/discover-types";

type Listener = (event: PumpLiveEvent) => void;

type PumpHub = {
  socket: WebSocket | null;
  connecting: boolean;
  listeners: Set<Listener>;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
};

declare global {
  // eslint-disable-next-line no-var
  var __memeScopePumpHub: PumpHub | undefined;
}

function getHub(): PumpHub {
  if (!globalThis.__memeScopePumpHub) {
    globalThis.__memeScopePumpHub = {
      socket: null,
      connecting: false,
      listeners: new Set(),
      reconnectTimer: null,
    };
  }

  return globalThis.__memeScopePumpHub;
}

function normalizeEvent(raw: Record<string, unknown>): PumpLiveEvent {
  const rawType =
    typeof raw.txType === "string"
      ? raw.txType
      : typeof raw.type === "string"
        ? raw.type
        : typeof raw.event === "string"
          ? raw.event
          : null;

  const lower = rawType?.toLowerCase() || "";

  let type: PumpLiveEvent["type"] = "unknown";

  if (
    lower.includes("create") ||
    lower.includes("new")
  ) {
    type = "new-token";
  } else if (
    lower.includes("migrat") ||
    lower.includes("complete")
  ) {
    type = "migration";
  }

  const value = (key: string) =>
    typeof raw[key] === "string"
      ? (raw[key] as string)
      : null;

  return {
    receivedAt: Date.now(),
    type,
    mint:
      value("mint") ||
      value("tokenAddress") ||
      value("address"),
    name: value("name"),
    symbol: value("symbol"),
    signature:
      value("signature") || value("sig"),
    rawType,
  };
}

function broadcast(event: PumpLiveEvent) {
  const hub = getHub();
  for (const listener of hub.listeners) {
    try {
      listener(event);
    } catch {
      // Never let one browser listener break the hub.
    }
  }
}

export function pumpConfigured() {
  return Boolean(
    process.env.PUMPPORTAL_API_KEY?.trim(),
  );
}

export function ensurePumpConnection() {
  const apiKey =
    process.env.PUMPPORTAL_API_KEY?.trim();

  if (!apiKey) return false;

  const hub = getHub();

  if (
    hub.socket?.readyState === WebSocket.OPEN ||
    hub.socket?.readyState === WebSocket.CONNECTING ||
    hub.connecting
  ) {
    return true;
  }

  hub.connecting = true;

  const socket = new WebSocket(
    `wss://pumpportal.fun/api/data?api-key=${encodeURIComponent(
      apiKey,
    )}`,
  );

  hub.socket = socket;

  socket.on("open", () => {
    hub.connecting = false;

    socket.send(
      JSON.stringify({
        method: "subscribeNewToken",
      }),
    );

    socket.send(
      JSON.stringify({
        method: "subscribeMigration",
      }),
    );
  });

  socket.on("message", (data) => {
    try {
      const raw = JSON.parse(
        data.toString(),
      ) as Record<string, unknown>;

      broadcast(normalizeEvent(raw));
    } catch {
      // Ignore malformed upstream messages.
    }
  });

  socket.on("error", () => {
    // close handler will schedule reconnect.
  });

  socket.on("close", () => {
    hub.connecting = false;
    hub.socket = null;

    if (
      hub.listeners.size > 0 &&
      !hub.reconnectTimer
    ) {
      hub.reconnectTimer = setTimeout(() => {
        hub.reconnectTimer = null;
        ensurePumpConnection();
      }, 3_000);
    }
  });

  return true;
}

export function subscribePump(listener: Listener) {
  const hub = getHub();
  hub.listeners.add(listener);
  ensurePumpConnection();

  return () => {
    hub.listeners.delete(listener);
  };
}
'@ | Set-Content -Encoding UTF8 "src/lib/pumpportal-hub.ts"

Step "Membuat SSE endpoint PumpPortal"
New-Item -ItemType Directory -Force -Path "src/app/api/pump/live" | Out-Null

@'
import {
  pumpConfigured,
  subscribePump,
} from "@/lib/pumpportal-hub";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const encoder = new TextEncoder();

  if (!pumpConfigured()) {
    return new Response(
      encoder.encode(
        `event: status\ndata: ${JSON.stringify({
          configured: false,
          message:
            "PUMPPORTAL_API_KEY is not configured.",
        })}\n\n`,
      ),
      {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
          Connection: "keep-alive",
        },
      },
    );
  }

  let unsubscribe: (() => void) | null = null;
  let heartbeat: ReturnType<
    typeof setInterval
  > | null = null;

  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(
        encoder.encode(
          `event: status\ndata: ${JSON.stringify({
            configured: true,
            message: "PumpPortal stream connecting.",
          })}\n\n`,
        ),
      );

      unsubscribe = subscribePump((event) => {
        controller.enqueue(
          encoder.encode(
            `event: pump\ndata: ${JSON.stringify(
              event,
            )}\n\n`,
          ),
        );
      });

      heartbeat = setInterval(() => {
        try {
          controller.enqueue(
            encoder.encode(
              `event: heartbeat\ndata: ${Date.now()}\n\n`,
            ),
          );
        } catch {
          // Client disconnected.
        }
      }, 15_000);
    },
    cancel() {
      unsubscribe?.();

      if (heartbeat) {
        clearInterval(heartbeat);
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    },
  });
}
'@ | Set-Content -Encoding UTF8 "src/app/api/pump/live/route.ts"

Step "Membuat Discover UI"
New-Item -ItemType Directory -Force -Path "src/app/discover" | Out-Null

@'
"use client";

import { AppShell } from "@/components/app-shell";
import type {
  DiscoverCategory,
  DiscoverResponse,
  DiscoverToken,
  PumpLiveEvent,
} from "@/lib/discover-types";
import {
  Activity,
  ArrowUpRight,
  Flame,
  Gauge,
  Radio,
  Rocket,
  Search,
  Sparkles,
  TrendingUp,
  Zap,
} from "lucide-react";
import Link from "next/link";
import {
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";

const tabs: Array<{
  id: DiscoverCategory;
  label: string;
}> = [
  { id: "new", label: "New" },
  { id: "trending", label: "Trending" },
  {
    id: "volume-spike",
    label: "Volume Spike",
  },
  {
    id: "high-score",
    label: "High Score",
  },
];

function money(value: number) {
  if (!Number.isFinite(value)) return "$0";
  if (value >= 1_000_000_000)
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000)
    return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000)
    return `$${(value / 1_000).toFixed(1)}K`;
  if (value >= 1)
    return `$${value.toFixed(2)}`;
  return `$${value.toPrecision(5)}`;
}

function age(minutes: number | null) {
  if (minutes === null) return "—";
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 1440)
    return `${Math.floor(minutes / 60)}h`;
  return `${Math.floor(minutes / 1440)}d`;
}

function pct(value: number) {
  return `${value > 0 ? "+" : ""}${value.toFixed(1)}%`;
}

function sortForCategory(
  tokens: DiscoverToken[],
  category: DiscoverCategory,
) {
  const filtered = tokens.filter((token) =>
    token.categories.includes(category),
  );

  if (category === "new") {
    return filtered.sort(
      (a, b) =>
        (a.ageMinutes ?? Number.MAX_SAFE_INTEGER) -
        (b.ageMinutes ?? Number.MAX_SAFE_INTEGER),
    );
  }

  if (category === "volume-spike") {
    return filtered.sort(
      (a, b) =>
        b.volumeSpikeRatio - a.volumeSpikeRatio,
    );
  }

  if (category === "high-score") {
    return filtered.sort(
      (a, b) => b.score - a.score,
    );
  }

  return filtered.sort(
    (a, b) => b.trendScore - a.trendScore,
  );
}

export default function DiscoverPage() {
  const [data, setData] =
    useState<DiscoverResponse | null>(null);
  const [tab, setTab] =
    useState<DiscoverCategory>("new");
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [pumpStatus, setPumpStatus] =
    useState<
      "connecting" | "configured" | "not-configured"
    >("connecting");
  const [pumpEvents, setPumpEvents] = useState<
    PumpLiveEvent[]
  >([]);

  const load = useCallback(async () => {
    try {
      const response = await fetch(
        "/api/discover/solana",
        { cache: "no-store" },
      );
      const next =
        (await response.json()) as DiscoverResponse;

      if (!response.ok && !next.tokens?.length) {
        throw new Error(
          next.error || "Discovery request failed.",
        );
      }

      setData(next);
      setError(next.error || "");
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "Discovery request failed.",
      );
    }
  }, []);

  useEffect(() => {
    load();
    const timer = window.setInterval(load, 3_000);
    return () => window.clearInterval(timer);
  }, [load]);

  useEffect(() => {
    const source = new EventSource("/api/pump/live");

    source.addEventListener("status", (event) => {
      try {
        const payload = JSON.parse(
          (event as MessageEvent).data,
        ) as {
          configured?: boolean;
        };

        setPumpStatus(
          payload.configured
            ? "configured"
            : "not-configured",
        );
      } catch {
        setPumpStatus("not-configured");
      }
    });

    source.addEventListener("pump", (event) => {
      try {
        const payload = JSON.parse(
          (event as MessageEvent).data,
        ) as PumpLiveEvent;

        setPumpStatus("configured");

        setPumpEvents((current) => [
          payload,
          ...current,
        ].slice(0, 12));
      } catch {
        // Ignore malformed SSE event.
      }
    });

    source.onerror = () => {
      if (pumpStatus === "connecting") {
        setPumpStatus("not-configured");
      }
    };

    return () => source.close();
  }, [pumpStatus]);

  const tokens = useMemo(() => {
    const q = query.trim().toLowerCase();

    return sortForCategory(
      [...(data?.tokens || [])],
      tab,
    ).filter((token) => {
      if (!q) return true;

      return (
        token.name.toLowerCase().includes(q) ||
        token.symbol.toLowerCase().includes(q) ||
        token.tokenAddress.toLowerCase().includes(q)
      );
    });
  }, [data?.tokens, query, tab]);

  const categoryCounts = useMemo(() => {
    const result: Record<DiscoverCategory, number> = {
      new: 0,
      trending: 0,
      "volume-spike": 0,
      "high-score": 0,
    };

    for (const token of data?.tokens || []) {
      for (const category of token.categories) {
        result[category] += 1;
      }
    }

    return result;
  }, [data?.tokens]);

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-center xl:justify-between">
          <div>
            <div className="flex items-center gap-2 text-sm text-emerald-300">
              <Rocket className="h-4 w-4" />
              Solana Discovery
            </div>
            <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
              Early Token Radar
            </h1>
            <p className="mt-1 max-w-2xl text-sm text-zinc-500">
              Find recent pairs, accelerating volume,
              short-term momentum and stronger market-quality
              candidates before deeper analysis.
            </p>
          </div>

          <div className="flex items-center gap-2 rounded-full border border-white/8 bg-white/[0.025] px-3 py-2 text-xs text-zinc-500">
            <Radio
              className={`h-3.5 w-3.5 ${
                pumpStatus === "configured"
                  ? "text-emerald-300"
                  : "text-zinc-600"
              }`}
            />
            Pump live:{" "}
            {pumpStatus === "configured"
              ? "connected"
              : pumpStatus === "connecting"
                ? "checking"
                : "API key pending"}
          </div>
        </div>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          {[
            [
              "New",
              categoryCounts.new,
              Rocket,
            ],
            [
              "Trending",
              categoryCounts.trending,
              TrendingUp,
            ],
            [
              "Volume Spike",
              categoryCounts["volume-spike"],
              Zap,
            ],
            [
              "High Score",
              categoryCounts["high-score"],
              Gauge,
            ],
          ].map(([label, count, Icon]) => {
            const IconComponent =
              Icon as typeof Rocket;

            return (
              <div
                key={String(label)}
                className="rounded-2xl border border-white/8 bg-white/[0.025] p-4"
              >
                <div className="flex items-center justify-between">
                  <div className="text-xs uppercase tracking-[0.1em] text-zinc-600">
                    {label as string}
                  </div>
                  <IconComponent className="h-4 w-4 text-zinc-600" />
                </div>
                <div className="mt-2 text-2xl font-semibold text-white">
                  {count as number}
                </div>
              </div>
            );
          })}
        </section>

        <section className="rounded-2xl border border-white/8 bg-white/[0.025]">
          <div className="border-b border-white/8 p-4">
            <div className="flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
              <div className="flex flex-wrap gap-2">
                {tabs.map((item) => (
                  <button
                    key={item.id}
                    onClick={() => setTab(item.id)}
                    className={`rounded-xl px-3 py-2 text-sm transition ${
                      tab === item.id
                        ? "bg-white text-black"
                        : "border border-white/8 bg-black/20 text-zinc-500 hover:text-white"
                    }`}
                  >
                    {item.label}
                    <span className="ml-2 opacity-50">
                      {categoryCounts[item.id]}
                    </span>
                  </button>
                ))}
              </div>

              <div className="relative w-full xl:w-80">
                <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />
                <input
                  value={query}
                  onChange={(event) =>
                    setQuery(event.target.value)
                  }
                  placeholder="Search token or CA"
                  className="h-10 w-full rounded-xl border border-white/8 bg-black/20 pl-10 pr-3 text-sm outline-none placeholder:text-zinc-700 focus:border-emerald-400/40"
                />
              </div>
            </div>
          </div>

          {error ? (
            <div className="border-b border-amber-400/10 bg-amber-400/5 px-4 py-3 text-xs text-amber-200/70">
              {error}
            </div>
          ) : null}

          <div className="overflow-x-auto">
            <table className="w-full min-w-[1220px] border-collapse text-left text-sm">
              <thead className="text-xs uppercase tracking-[0.08em] text-zinc-600">
                <tr className="border-b border-white/8">
                  <th className="px-4 py-3 font-medium">
                    Token
                  </th>
                  <th className="px-4 py-3 font-medium">
                    Age
                  </th>
                  <th className="px-4 py-3 font-medium">
                    Score
                  </th>
                  <th className="px-4 py-3 font-medium">
                    Trend
                  </th>
                  <th className="px-4 py-3 font-medium">
                    Market Cap
                  </th>
                  <th className="px-4 py-3 font-medium">
                    Liquidity
                  </th>
                  <th className="px-4 py-3 font-medium">
                    5M Volume
                  </th>
                  <th className="px-4 py-3 font-medium">
                    Spike
                  </th>
                  <th className="px-4 py-3 font-medium">
                    B/S
                  </th>
                  <th className="px-4 py-3 font-medium">
                    5M
                  </th>
                  <th className="px-4 py-3 font-medium"></th>
                </tr>
              </thead>

              <tbody>
                {tokens.map((token) => (
                  <tr
                    key={token.pairAddress}
                    className="border-b border-white/5 hover:bg-white/[0.025]"
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
                          <div className="grid h-9 w-9 place-items-center rounded-full border border-white/8 bg-white/5 text-xs text-zinc-600">
                            {token.symbol
                              .slice(0, 2)
                              .toUpperCase()}
                          </div>
                        )}

                        <div>
                          <div className="font-medium text-white">
                            ${token.symbol}
                          </div>
                          <div className="max-w-40 truncate text-xs text-zinc-600">
                            {token.name} · {token.dexId}
                          </div>
                        </div>
                      </div>
                    </td>

                    <td className="px-4 py-4 text-zinc-400">
                      {age(token.ageMinutes)}
                    </td>

                    <td className="px-4 py-4">
                      <span className="rounded-lg border border-emerald-400/20 bg-emerald-400/10 px-2 py-1 font-medium text-emerald-300">
                        {token.score}
                      </span>
                    </td>

                    <td className="px-4 py-4">
                      <span className="rounded-lg border border-sky-400/15 bg-sky-400/5 px-2 py-1 text-sky-300">
                        {token.trendScore}
                      </span>
                    </td>

                    <td className="px-4 py-4 text-zinc-300">
                      {money(
                        token.marketCap || token.fdv,
                      )}
                    </td>

                    <td className="px-4 py-4 text-zinc-300">
                      {money(token.liquidity)}
                    </td>

                    <td className="px-4 py-4 text-zinc-300">
                      {money(token.volume5m)}
                    </td>

                    <td className="px-4 py-4">
                      <span
                        className={
                          token.volumeSpikeRatio >= 2
                            ? "text-amber-300"
                            : "text-zinc-400"
                        }
                      >
                        {token.volumeSpikeRatio.toFixed(
                          1,
                        )}
                        x
                      </span>
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

                    <td className="px-4 py-4">
                      <div className="flex items-center gap-3">
                        <Link
                          href={`/token/${token.tokenAddress}`}
                          className="text-xs font-medium text-emerald-300 hover:text-emerald-200"
                        >
                          Analyze
                        </Link>

                        <a
                          href={token.dexUrl}
                          target="_blank"
                          rel="noreferrer"
                          className="inline-flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
                        >
                          DEX
                          <ArrowUpRight className="h-3.5 w-3.5" />
                        </a>
                      </div>
                    </td>
                  </tr>
                ))}

                {!tokens.length ? (
                  <tr>
                    <td
                      colSpan={11}
                      className="px-4 py-16 text-center"
                    >
                      <Activity className="mx-auto h-6 w-6 text-zinc-700" />
                      <div className="mt-3 text-sm text-zinc-500">
                        No token currently matches this
                        category.
                      </div>
                    </td>
                  </tr>
                ) : null}
              </tbody>
            </table>
          </div>
        </section>

        <section className="grid gap-4 xl:grid-cols-[1fr_.7fr]">
          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            <div className="flex items-center gap-2">
              <Flame className="h-4 w-4 text-amber-300" />
              <h2 className="font-medium text-white">
                How discovery works
              </h2>
            </div>

            <div className="mt-4 grid gap-3 md:grid-cols-2">
              <div className="rounded-xl border border-white/5 bg-black/20 p-3">
                <div className="text-sm text-white">
                  Volume Spike
                </div>
                <p className="mt-1 text-xs leading-5 text-zinc-600">
                  Compares the current 5-minute volume
                  against the expected 5-minute slice of
                  the 1-hour volume. A value above 1x
                  indicates acceleration.
                </p>
              </div>

              <div className="rounded-xl border border-white/5 bg-black/20 p-3">
                <div className="text-sm text-white">
                  Trend Score
                </div>
                <p className="mt-1 text-xs leading-5 text-zinc-600">
                  Combines recent volume, acceleration,
                  price momentum, buy flow and active
                  boosts. It is a discovery heuristic, not
                  a price prediction.
                </p>
              </div>
            </div>
          </div>

          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            <div className="flex items-center justify-between gap-3">
              <div>
                <div className="flex items-center gap-2">
                  <Sparkles className="h-4 w-4 text-emerald-300" />
                  <h2 className="font-medium text-white">
                    Pump live feed
                  </h2>
                </div>
                <p className="mt-1 text-xs text-zinc-600">
                  Direct creation/migration stream
                </p>
              </div>

              <div
                className={`rounded-full border px-2.5 py-1 text-xs ${
                  pumpStatus === "configured"
                    ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                    : "border-white/8 text-zinc-600"
                }`}
              >
                {pumpStatus === "configured"
                  ? "Live"
                  : "Key pending"}
              </div>
            </div>

            <div className="mt-4 space-y-2">
              {pumpEvents.length ? (
                pumpEvents.slice(0, 6).map(
                  (event, index) => (
                    <div
                      key={`${event.receivedAt}-${index}`}
                      className="rounded-xl border border-white/5 bg-black/20 p-3"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <div className="text-xs font-medium text-zinc-300">
                          {event.type === "migration"
                            ? "Migration"
                            : event.type === "new-token"
                              ? "New token"
                              : event.rawType ||
                                "Pump event"}
                        </div>
                        <div className="text-[11px] text-zinc-700">
                          {new Date(
                            event.receivedAt,
                          ).toLocaleTimeString()}
                        </div>
                      </div>
                      <div className="mt-1 truncate text-xs text-zinc-600">
                        {event.symbol
                          ? `$${event.symbol}`
                          : event.name ||
                            event.mint ||
                            "Event received"}
                      </div>
                    </div>
                  ),
                )
              ) : (
                <div className="rounded-xl border border-white/5 bg-black/20 p-4 text-xs leading-5 text-zinc-600">
                  Add{" "}
                  <code className="text-zinc-400">
                    PUMPPORTAL_API_KEY
                  </code>{" "}
                  later to activate the direct Pump.fun /
                  PumpSwap creation and migration stream.
                  The main discovery table works without
                  it.
                </div>
              )}
            </div>
          </div>
        </section>
      </div>
    </AppShell>
  );
}
'@ | Set-Content -Encoding UTF8 "src/app/discover/page.tsx"

Step "Update sidebar"
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
              pathname.startsWith(
                `${item.href}/`,
              );
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
            Stage 04
          </div>
          <p className="mt-2 text-xs leading-5 text-zinc-600">
            Live market, risk analyzer and early-token
            discovery enabled.
          </p>
        </div>
      </div>
    </aside>
  );
}
'@ | Set-Content -Encoding UTF8 "src/components/sidebar.tsx"

Step "Update environment example"
@'
# DEX Screener public endpoints do not require an API key.

# Solana on-chain risk analyzer.
# Empty = public Solana RPC for local development.
SOLANA_RPC_URL=

# Stage 04 direct Pump.fun/PumpSwap stream.
# Optional. Main discovery page works without it.
PUMPPORTAL_API_KEY=

# Future:
SOLANA_WSS_URL=
EVM_RPC_URL=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
AI_API_KEY=
'@ | Set-Content -Encoding UTF8 ".env.example"

Step "Membersihkan Next.js cache"
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue

Step "Menjalankan lint"
npm run lint

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Stage 04 Discovery berhasil dipasang." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor White
Write-Host "  npm run dev" -ForegroundColor Yellow
Write-Host ""
Write-Host "Buka:" -ForegroundColor White
Write-Host "  http://localhost:3000/discover" -ForegroundColor Yellow
Write-Host ""
Write-Host "Tanpa API key:" -ForegroundColor White
Write-Host "  New / Trending / Volume Spike / High Score tetap aktif." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Dengan PUMPPORTAL_API_KEY nanti:" -ForegroundColor White
Write-Host "  Direct new-token + migration stream aktif." -ForegroundColor DarkGray
