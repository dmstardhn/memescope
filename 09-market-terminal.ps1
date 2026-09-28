$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 09 - Market Terminal Expansion" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $full = Join-Path $root $Path
    $dir = Split-Path -Parent $full

    if ($dir -and !(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    [System.IO.File]::WriteAllText($full, $Content, $utf8NoBom)
    Write-Host "Created: $Path" -ForegroundColor Green
}

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "package.json tidak ditemukan. Jalankan dari root project memecoin-analyst."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-stage09-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$filesToBackup = @(
    "src/app/scanner/page.tsx",
    "src/app/discover/page.tsx"
)

foreach ($file in $filesToBackup) {
    $full = Join-Path $root $file
    if (Test-Path -LiteralPath $full) {
        $name = ($file -replace '[\\/]', '__') + ".bak"
        Copy-Item -LiteralPath $full -Destination (Join-Path $backupDir $name) -Force
    }
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""

# =========================================================
# 1. TYPES
# =========================================================

$types = @'
export type TerminalSourceFlags = {
  latestProfile: boolean;
  recentUpdate: boolean;
  boostedLatest: boolean;
  boostedTop: boolean;
  communityTakeover: boolean;
  advertised: boolean;
};

export type TerminalToken = {
  address: string;
  pairAddress: string;
  dexId: string;
  dexUrl: string | null;

  symbol: string;
  name: string;
  imageUrl: string | null;

  priceUsd: number | null;
  priceNative: number | null;

  priceChange: {
    m5: number | null;
    h1: number | null;
    h6: number | null;
    h24: number | null;
  };

  volume: {
    m5: number;
    h1: number;
    h6: number;
    h24: number;
  };

  txns: {
    m5: { buys: number; sells: number };
    h1: { buys: number; sells: number };
    h6: { buys: number; sells: number };
    h24: { buys: number; sells: number };
  };

  liquidityUsd: number;
  marketCap: number | null;
  fdv: number | null;
  pairCreatedAt: number | null;
  pairAgeMinutes: number | null;

  boostsActive: number;
  boostAmount: number;
  boostTotalAmount: number;

  websites: string[];
  socials: Array<{
    platform: string;
    handle: string;
  }>;

  sources: TerminalSourceFlags;

  volumeSpike5m: number | null;
  buyShare5m: number | null;
  liquidityToMcap: number | null;

  activityScore: number;
};

export type TerminalResponse = {
  generatedAt: number;
  tokenCount: number;
  sourceCount: number;
  tokens: TerminalToken[];
  warnings: string[];
};
'@

Write-Utf8NoBom "src/lib/terminal-types.ts" $types

# =========================================================
# 2. TERMINAL API
# =========================================================

$api = @'
import { NextResponse } from "next/server";

import type {
  TerminalResponse,
  TerminalSourceFlags,
  TerminalToken,
} from "@/lib/terminal-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type ProfileItem = {
  chainId?: string;
  tokenAddress?: string;
};

type BoostItem = {
  chainId?: string;
  tokenAddress?: string;
  amount?: number;
  totalAmount?: number;
};

type Pair = {
  chainId?: string;
  dexId?: string;
  url?: string;
  pairAddress?: string;

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
  priceChange?: Record<string, number>;

  liquidity?: {
    usd?: number | null;
  };

  fdv?: number | null;
  marketCap?: number | null;
  pairCreatedAt?: number | null;

  info?: {
    imageUrl?: string | null;

    websites?: Array<{
      url?: string;
    }> | null;

    socials?: Array<{
      platform?: string;
      handle?: string;
    }> | null;
  };

  boosts?: {
    active?: number;
  };
};

type Candidate = {
  address: string;
  sources: TerminalSourceFlags;
  boostAmount: number;
  boostTotalAmount: number;
};

let cache:
  | {
      expiresAt: number;
      payload: TerminalResponse;
    }
  | null = null;

const BASE = "https://api.dexscreener.com";

function blankSources(): TerminalSourceFlags {
  return {
    latestProfile: false,
    recentUpdate: false,
    boostedLatest: false,
    boostedTop: false,
    communityTakeover: false,
    advertised: false,
  };
}

function safeNumber(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function nullableNumber(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function tx(
  pair: Pair,
  period: "m5" | "h1" | "h6" | "h24",
) {
  return {
    buys: safeNumber(pair.txns?.[period]?.buys),
    sells: safeNumber(pair.txns?.[period]?.sells),
  };
}

function vol(
  pair: Pair,
  period: "m5" | "h1" | "h6" | "h24",
) {
  return safeNumber(pair.volume?.[period]);
}

function pct(
  pair: Pair,
  period: "m5" | "h1" | "h6" | "h24",
) {
  const value = pair.priceChange?.[period];

  return typeof value === "number" &&
    Number.isFinite(value)
    ? value
    : null;
}

function chooseBestPair(
  address: string,
  pairs: Pair[],
) {
  const candidates = pairs
    .filter(
      (pair) =>
        pair.chainId === "solana" &&
        pair.baseToken?.address === address,
    )
    .sort(
      (a, b) =>
        safeNumber(b.liquidity?.usd) -
        safeNumber(a.liquidity?.usd),
    );

  return candidates[0] ?? null;
}

function computeActivityScore(
  pair: Pair,
  volumeSpike5m: number | null,
  buyShare5m: number | null,
  pairAgeMinutes: number | null,
) {
  const liquidity = safeNumber(pair.liquidity?.usd);
  const volume5m = vol(pair, "m5");

  let score = 0;

  if (liquidity >= 500_000) score += 20;
  else if (liquidity >= 150_000) score += 17;
  else if (liquidity >= 50_000) score += 13;
  else if (liquidity >= 20_000) score += 8;
  else if (liquidity >= 5_000) score += 3;

  if (volume5m >= 250_000) score += 20;
  else if (volume5m >= 100_000) score += 17;
  else if (volume5m >= 25_000) score += 13;
  else if (volume5m >= 5_000) score += 8;
  else if (volume5m > 0) score += 3;

  if (volumeSpike5m !== null) {
    score += clamp(volumeSpike5m * 4, 0, 20);
  }

  if (buyShare5m !== null) {
    score += clamp((buyShare5m - 0.45) * 50, 0, 15);
  }

  const change5m = pct(pair, "m5") ?? 0;
  score += clamp(change5m / 2, 0, 10);

  if (pairAgeMinutes !== null) {
    if (pairAgeMinutes <= 30) score += 10;
    else if (pairAgeMinutes <= 120) score += 7;
    else if (pairAgeMinutes <= 1_440) score += 4;
  }

  const boosts = safeNumber(pair.boosts?.active);
  score += clamp(boosts, 0, 5);

  return Math.round(clamp(score, 0, 100));
}

async function getJson<T>(
  path: string,
  warnings: string[],
): Promise<T | null> {
  try {
    const response = await fetch(`${BASE}${path}`, {
      headers: {
        Accept: "application/json",
      },
      cache: "no-store",
    });

    if (!response.ok) {
      warnings.push(`${path}: HTTP ${response.status}`);
      return null;
    }

    return (await response.json()) as T;
  } catch (error) {
    warnings.push(
      `${path}: ${
        error instanceof Error
          ? error.message
          : "request failed"
      }`,
    );

    return null;
  }
}

function addCandidates(
  map: Map<string, Candidate>,
  items: Array<ProfileItem | BoostItem> | null,
  flag: keyof TerminalSourceFlags,
) {
  for (const item of items ?? []) {
    if (
      item.chainId !== "solana" ||
      !item.tokenAddress
    ) {
      continue;
    }

    const existing = map.get(item.tokenAddress) ?? {
      address: item.tokenAddress,
      sources: blankSources(),
      boostAmount: 0,
      boostTotalAmount: 0,
    };

    existing.sources[flag] = true;

    const boost = item as BoostItem;

    existing.boostAmount = Math.max(
      existing.boostAmount,
      safeNumber(boost.amount),
    );

    existing.boostTotalAmount = Math.max(
      existing.boostTotalAmount,
      safeNumber(boost.totalAmount),
    );

    map.set(item.tokenAddress, existing);
  }
}

export async function GET() {
  if (
    cache &&
    cache.expiresAt > Date.now()
  ) {
    return NextResponse.json(cache.payload);
  }

  const warnings: string[] = [];

  const [
    latestProfiles,
    recentProfiles,
    latestBoosts,
    topBoosts,
    takeovers,
    ads,
  ] = await Promise.all([
    getJson<ProfileItem[]>(
      "/token-profiles/latest/v1",
      warnings,
    ),
    getJson<ProfileItem[]>(
      "/token-profiles/recent-updates/v1",
      warnings,
    ),
    getJson<BoostItem[]>(
      "/token-boosts/latest/v1",
      warnings,
    ),
    getJson<BoostItem[]>(
      "/token-boosts/top/v1",
      warnings,
    ),
    getJson<ProfileItem[]>(
      "/community-takeovers/latest/v1",
      warnings,
    ),
    getJson<ProfileItem[]>(
      "/ads/latest/v1",
      warnings,
    ),
  ]);

  const candidates = new Map<string, Candidate>();

  addCandidates(
    candidates,
    latestProfiles,
    "latestProfile",
  );

  addCandidates(
    candidates,
    recentProfiles,
    "recentUpdate",
  );

  addCandidates(
    candidates,
    latestBoosts,
    "boostedLatest",
  );

  addCandidates(
    candidates,
    topBoosts,
    "boostedTop",
  );

  addCandidates(
    candidates,
    takeovers,
    "communityTakeover",
  );

  addCandidates(
    candidates,
    ads,
    "advertised",
  );

  const addresses = Array.from(
    candidates.keys(),
  ).slice(0, 180);

  const allPairs: Pair[] = [];

  for (
    let index = 0;
    index < addresses.length;
    index += 30
  ) {
    const chunk = addresses.slice(
      index,
      index + 30,
    );

    const pairs = await getJson<Pair[]>(
      `/tokens/v1/solana/${chunk.join(",")}`,
      warnings,
    );

    if (Array.isArray(pairs)) {
      allPairs.push(...pairs);
    }
  }

  const now = Date.now();
  const tokens: TerminalToken[] = [];

  for (const address of addresses) {
    const candidate = candidates.get(address);

    if (!candidate) continue;

    const pair = chooseBestPair(
      address,
      allPairs,
    );

    if (!pair || !pair.baseToken?.address) {
      continue;
    }

    const m5 = tx(pair, "m5");
    const total5m = m5.buys + m5.sells;

    const buyShare5m =
      total5m > 0
        ? m5.buys / total5m
        : null;

    const volume5m = vol(pair, "m5");
    const volume1h = vol(pair, "h1");

    const expected5m =
      volume1h > 0
        ? volume1h / 12
        : 0;

    const volumeSpike5m =
      expected5m > 0
        ? volume5m / expected5m
        : null;

    const pairCreatedAt =
      typeof pair.pairCreatedAt === "number"
        ? pair.pairCreatedAt
        : null;

    const pairAgeMinutes =
      pairCreatedAt !== null
        ? Math.max(
            0,
            (now - pairCreatedAt) / 60_000,
          )
        : null;

    const liquidityUsd = safeNumber(
      pair.liquidity?.usd,
    );

    const marketCap =
      typeof pair.marketCap === "number"
        ? pair.marketCap
        : null;

    const liquidityToMcap =
      marketCap && marketCap > 0
        ? liquidityUsd / marketCap
        : null;

    const activityScore =
      computeActivityScore(
        pair,
        volumeSpike5m,
        buyShare5m,
        pairAgeMinutes,
      );

    tokens.push({
      address,
      pairAddress: pair.pairAddress ?? "",
      dexId: pair.dexId ?? "unknown",
      dexUrl: pair.url ?? null,

      symbol:
        pair.baseToken.symbol ?? "UNKNOWN",

      name:
        pair.baseToken.name ?? "Unknown token",

      imageUrl:
        pair.info?.imageUrl ?? null,

      priceUsd:
        pair.priceUsd
          ? nullableNumber(pair.priceUsd)
          : null,

      priceNative:
        pair.priceNative
          ? nullableNumber(pair.priceNative)
          : null,

      priceChange: {
        m5: pct(pair, "m5"),
        h1: pct(pair, "h1"),
        h6: pct(pair, "h6"),
        h24: pct(pair, "h24"),
      },

      volume: {
        m5: volume5m,
        h1: volume1h,
        h6: vol(pair, "h6"),
        h24: vol(pair, "h24"),
      },

      txns: {
        m5,
        h1: tx(pair, "h1"),
        h6: tx(pair, "h6"),
        h24: tx(pair, "h24"),
      },

      liquidityUsd,

      marketCap,

      fdv:
        typeof pair.fdv === "number"
          ? pair.fdv
          : null,

      pairCreatedAt,
      pairAgeMinutes,

      boostsActive:
        safeNumber(pair.boosts?.active),

      boostAmount:
        candidate.boostAmount,

      boostTotalAmount:
        candidate.boostTotalAmount,

      websites:
        (pair.info?.websites ?? [])
          .map((item) => item.url)
          .filter(
            (value): value is string =>
              Boolean(value),
          ),

      socials:
        (pair.info?.socials ?? [])
          .map((item) => ({
            platform:
              item.platform ?? "social",
            handle:
              item.handle ?? "",
          }))
          .filter(
            (item) =>
              item.platform.length > 0,
          ),

      sources: candidate.sources,

      volumeSpike5m,
      buyShare5m,
      liquidityToMcap,

      activityScore,
    });
  }

  tokens.sort(
    (a, b) =>
      b.activityScore -
      a.activityScore,
  );

  const payload: TerminalResponse = {
    generatedAt: Date.now(),
    tokenCount: tokens.length,
    sourceCount: addresses.length,
    tokens,
    warnings,
  };

  cache = {
    expiresAt: Date.now() + 15_000,
    payload,
  };

  return NextResponse.json(payload);
}
'@

Write-Utf8NoBom "src/app/api/terminal/solana/route.ts" $api

# =========================================================
# 3. SCANNER PAGE
# =========================================================

$scanner = @'
"use client";

import Link from "next/link";
import {
  ExternalLink,
  Filter,
  RefreshCw,
  Search,
  SlidersHorizontal,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

import type {
  TerminalResponse,
  TerminalToken,
} from "@/lib/terminal-types";

type Tab =
  | "trending"
  | "new"
  | "gainers"
  | "volume"
  | "liquidity"
  | "boosted";

function money(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "—";
  }

  if (Math.abs(value) >= 1_000_000_000) {
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  }

  if (Math.abs(value) >= 1_000_000) {
    return `$${(value / 1_000_000).toFixed(2)}M`;
  }

  if (Math.abs(value) >= 1_000) {
    return `$${(value / 1_000).toFixed(1)}K`;
  }

  if (Math.abs(value) >= 1) {
    return `$${value.toFixed(2)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function price(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "—";
  }

  if (value >= 1) {
    return `$${value.toLocaleString(
      "en-US",
      {
        maximumFractionDigits: 6,
      },
    )}`;
  }

  if (value >= 0.01) {
    return `$${value.toFixed(5)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function percent(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return (
      <span className="text-zinc-600">
        —
      </span>
    );
  }

  const tone =
    value > 0
      ? "text-emerald-300"
      : value < 0
        ? "text-red-300"
        : "text-zinc-400";

  return (
    <span className={tone}>
      {value > 0 ? "+" : ""}
      {value.toFixed(2)}%
    </span>
  );
}

function age(minutes: number | null) {
  if (
    minutes === null ||
    !Number.isFinite(minutes)
  ) {
    return "—";
  }

  if (minutes < 60) {
    return `${Math.floor(minutes)}m`;
  }

  if (minutes < 1_440) {
    return `${Math.floor(
      minutes / 60,
    )}h`;
  }

  return `${Math.floor(
    minutes / 1_440,
  )}d`;
}

function rowSort(
  tab: Tab,
  a: TerminalToken,
  b: TerminalToken,
) {
  if (tab === "new") {
    return (
      (a.pairAgeMinutes ??
        Number.POSITIVE_INFINITY) -
      (b.pairAgeMinutes ??
        Number.POSITIVE_INFINITY)
    );
  }

  if (tab === "gainers") {
    return (
      (b.priceChange.m5 ?? -99999) -
      (a.priceChange.m5 ?? -99999)
    );
  }

  if (tab === "volume") {
    return b.volume.m5 - a.volume.m5;
  }

  if (tab === "liquidity") {
    return (
      b.liquidityUsd -
      a.liquidityUsd
    );
  }

  if (tab === "boosted") {
    return (
      b.boostsActive -
        a.boostsActive ||
      b.boostTotalAmount -
        a.boostTotalAmount
    );
  }

  return (
    b.activityScore -
    a.activityScore
  );
}

function TokenIdentity({
  token,
}: {
  token: TerminalToken;
}) {
  return (
    <div className="flex min-w-[210px] items-center gap-3">
      {token.imageUrl ? (
        <img
          src={token.imageUrl}
          alt=""
          className="h-9 w-9 rounded-full border border-white/10 object-cover"
        />
      ) : (
        <div className="flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/5 text-xs font-bold text-zinc-500">
          {token.symbol.slice(0, 2)}
        </div>
      )}

      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="max-w-[120px] truncate font-semibold text-white">
            {token.symbol}
          </span>

          {token.boostsActive > 0 && (
            <span className="rounded bg-amber-400/10 px-1.5 py-0.5 text-[9px] font-semibold text-amber-300">
              BOOST
            </span>
          )}
        </div>

        <div className="max-w-[165px] truncate text-[11px] text-zinc-600">
          {token.name}
        </div>
      </div>
    </div>
  );
}

export default function ScannerPage() {
  const [data, setData] =
    useState<TerminalResponse | null>(
      null,
    );

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  const [tab, setTab] =
    useState<Tab>("trending");

  const [query, setQuery] =
    useState("");

  const [minLiquidity, setMinLiquidity] =
    useState(0);

  const [maxAgeHours, setMaxAgeHours] =
    useState(0);

  async function load(
    silent = false,
  ) {
    if (!silent) setLoading(true);

    try {
      const response = await fetch(
        "/api/terminal/solana",
        {
          cache: "no-store",
        },
      );

      const result =
        (await response.json()) as
          | TerminalResponse
          | { error?: string };

      if (!response.ok) {
        throw new Error(
          "error" in result
            ? result.error
            : "Scanner failed.",
        );
      }

      setData(
        result as TerminalResponse,
      );

      setError("");
    } catch (loadError) {
      setError(
        loadError instanceof Error
          ? loadError.message
          : "Scanner failed.",
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();

    const timer = window.setInterval(
      () => {
        void load(true);
      },
      15_000,
    );

    return () =>
      window.clearInterval(timer);
  }, []);

  const filtered = useMemo(() => {
    const needle =
      query.trim().toLowerCase();

    return [...(data?.tokens ?? [])]
      .filter((token) => {
        if (
          needle &&
          !token.symbol
            .toLowerCase()
            .includes(needle) &&
          !token.name
            .toLowerCase()
            .includes(needle) &&
          !token.address
            .toLowerCase()
            .includes(needle)
        ) {
          return false;
        }

        if (
          token.liquidityUsd <
          minLiquidity
        ) {
          return false;
        }

        if (
          maxAgeHours > 0 &&
          token.pairAgeMinutes !==
            null &&
          token.pairAgeMinutes >
            maxAgeHours * 60
        ) {
          return false;
        }

        if (
          tab === "boosted" &&
          token.boostsActive <= 0 &&
          token.boostTotalAmount <= 0
        ) {
          return false;
        }

        return true;
      })
      .sort((a, b) =>
        rowSort(tab, a, b),
      );
  }, [
    data,
    query,
    minLiquidity,
    maxAgeHours,
    tab,
  ]);

  const totals = useMemo(() => {
    const tokens = data?.tokens ?? [];

    return {
      volume5m: tokens.reduce(
        (sum, token) =>
          sum + token.volume.m5,
        0,
      ),

      liquidity: tokens.reduce(
        (sum, token) =>
          sum +
          token.liquidityUsd,
        0,
      ),

      newPairs: tokens.filter(
        (token) =>
          token.pairAgeMinutes !==
            null &&
          token.pairAgeMinutes <= 60,
      ).length,

      boosted: tokens.filter(
        (token) =>
          token.boostsActive > 0,
      ).length,
    };
  }, [data]);

  const tabs: Array<{
    id: Tab;
    label: string;
  }> = [
    {
      id: "trending",
      label: "Trending",
    },
    {
      id: "new",
      label: "New",
    },
    {
      id: "gainers",
      label: "Gainers 5m",
    },
    {
      id: "volume",
      label: "Volume 5m",
    },
    {
      id: "liquidity",
      label: "Liquidity",
    },
    {
      id: "boosted",
      label: "Boosted",
    },
  ];

  return (
    <main className="mx-auto w-full max-w-[1900px] px-3 py-5 lg:px-6">
      <div className="mb-5 flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="text-[10px] uppercase tracking-[0.22em] text-emerald-300">
            Solana market terminal
          </div>

          <h1 className="mt-1 text-2xl font-semibold tracking-tight text-white">
            Scanner
          </h1>

          <p className="mt-1 text-sm text-zinc-500">
            Dense market view for recent,
            active and boosted Solana tokens.
          </p>
        </div>

        <button
          onClick={() =>
            void load()
          }
          disabled={loading}
          className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5 disabled:opacity-50"
        >
          <RefreshCw
            className={`h-3.5 w-3.5 ${
              loading
                ? "animate-spin"
                : ""
            }`}
          />
          Refresh
        </button>
      </div>

      <section className="mb-4 grid grid-cols-2 gap-2 md:grid-cols-4">
        {[
          [
            "Pairs loaded",
            data?.tokenCount ?? 0,
          ],
          [
            "5m volume",
            money(totals.volume5m),
          ],
          [
            "Liquidity",
            money(totals.liquidity),
          ],
          [
            "New <1h",
            totals.newPairs,
          ],
        ].map(([label, value]) => (
          <div
            key={String(label)}
            className="rounded-xl border border-white/10 bg-white/[0.025] px-4 py-3"
          >
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              {label}
            </div>
            <div className="mt-1 text-lg font-semibold text-white">
              {value}
            </div>
          </div>
        ))}
      </section>

      <section className="mb-3 rounded-xl border border-white/10 bg-white/[0.02] p-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-[230px] flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />

            <input
              value={query}
              onChange={(event) =>
                setQuery(
                  event.target.value,
                )
              }
              placeholder="Search name, symbol or mint"
              className="w-full rounded-lg border border-white/10 bg-black/30 py-2.5 pl-9 pr-3 text-sm text-white outline-none placeholder:text-zinc-700 focus:border-emerald-400/30"
            />
          </div>

          <div className="flex items-center gap-2 rounded-lg border border-white/10 bg-black/20 px-3 py-2">
            <Filter className="h-3.5 w-3.5 text-zinc-600" />

            <select
              value={minLiquidity}
              onChange={(event) =>
                setMinLiquidity(
                  Number(
                    event.target.value,
                  ),
                )
              }
              className="bg-transparent text-xs text-zinc-300 outline-none"
            >
              <option value={0}>
                Any liquidity
              </option>
              <option value={5000}>
                Liq ≥ $5K
              </option>
              <option value={20000}>
                Liq ≥ $20K
              </option>
              <option value={50000}>
                Liq ≥ $50K
              </option>
              <option value={100000}>
                Liq ≥ $100K
              </option>
            </select>
          </div>

          <div className="flex items-center gap-2 rounded-lg border border-white/10 bg-black/20 px-3 py-2">
            <SlidersHorizontal className="h-3.5 w-3.5 text-zinc-600" />

            <select
              value={maxAgeHours}
              onChange={(event) =>
                setMaxAgeHours(
                  Number(
                    event.target.value,
                  ),
                )
              }
              className="bg-transparent text-xs text-zinc-300 outline-none"
            >
              <option value={0}>
                Any age
              </option>
              <option value={1}>
                Age ≤ 1h
              </option>
              <option value={6}>
                Age ≤ 6h
              </option>
              <option value={24}>
                Age ≤ 24h
              </option>
              <option value={168}>
                Age ≤ 7d
              </option>
            </select>
          </div>
        </div>

        <div className="mt-3 flex gap-1 overflow-x-auto">
          {tabs.map((item) => (
            <button
              key={item.id}
              onClick={() =>
                setTab(item.id)
              }
              className={`whitespace-nowrap rounded-lg px-3 py-2 text-xs transition ${
                tab === item.id
                  ? "bg-white text-black"
                  : "text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
              }`}
            >
              {item.label}
            </button>
          ))}
        </div>
      </section>

      {error && (
        <div className="mb-3 rounded-xl border border-red-400/20 bg-red-400/[0.05] p-3 text-sm text-red-200">
          {error}
        </div>
      )}

      <section className="overflow-hidden rounded-xl border border-white/10 bg-[#090b0f]">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[1720px] border-collapse text-left">
            <thead className="sticky top-0 z-10 bg-[#0d1015] text-[10px] uppercase tracking-[0.12em] text-zinc-600">
              <tr>
                <th className="px-4 py-3">
                  Token
                </th>
                <th className="px-3 py-3">
                  Age
                </th>
                <th className="px-3 py-3">
                  Price
                </th>
                <th className="px-3 py-3">
                  5m
                </th>
                <th className="px-3 py-3">
                  1h
                </th>
                <th className="px-3 py-3">
                  6h
                </th>
                <th className="px-3 py-3">
                  24h
                </th>
                <th className="px-3 py-3">
                  Txns 5m
                </th>
                <th className="px-3 py-3">
                  Vol 5m
                </th>
                <th className="px-3 py-3">
                  Vol 1h
                </th>
                <th className="px-3 py-3">
                  Liquidity
                </th>
                <th className="px-3 py-3">
                  Market Cap
                </th>
                <th className="px-3 py-3">
                  FDV
                </th>
                <th className="px-3 py-3">
                  Spike
                </th>
                <th className="px-3 py-3">
                  Score
                </th>
                <th className="px-3 py-3">
                  DEX
                </th>
                <th className="px-3 py-3">
                  Action
                </th>
              </tr>
            </thead>

            <tbody>
              {filtered.map(
                (token, index) => (
                  <tr
                    key={token.address}
                    className="border-t border-white/[0.055] text-xs transition hover:bg-white/[0.025]"
                  >
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-3">
                        <span className="w-5 text-[10px] text-zinc-700">
                          {index + 1}
                        </span>
                        <TokenIdentity
                          token={token}
                        />
                      </div>
                    </td>

                    <td className="px-3 py-3 text-zinc-400">
                      {age(
                        token.pairAgeMinutes,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono text-zinc-200">
                      {price(
                        token.priceUsd,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.m5,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.h1,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.h6,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.h24,
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span className="text-emerald-300">
                        {
                          token.txns.m5
                            .buys
                        }
                      </span>
                      <span className="mx-1 text-zinc-700">
                        /
                      </span>
                      <span className="text-red-300">
                        {
                          token.txns.m5
                            .sells
                        }
                      </span>
                    </td>

                    <td className="px-3 py-3 text-zinc-300">
                      {money(
                        token.volume.m5,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-400">
                      {money(
                        token.volume.h1,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-200">
                      {money(
                        token.liquidityUsd,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-300">
                      {money(
                        token.marketCap,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-500">
                      {money(token.fdv)}
                    </td>

                    <td className="px-3 py-3">
                      {token.volumeSpike5m !==
                      null ? (
                        <span
                          className={
                            token.volumeSpike5m >=
                            2
                              ? "text-amber-300"
                              : "text-zinc-400"
                          }
                        >
                          {token.volumeSpike5m.toFixed(
                            2,
                          )}
                          x
                        </span>
                      ) : (
                        "—"
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span
                        className={`font-semibold ${
                          token.activityScore >=
                          70
                            ? "text-emerald-300"
                            : token.activityScore >=
                                45
                              ? "text-amber-300"
                              : "text-zinc-400"
                        }`}
                      >
                        {
                          token.activityScore
                        }
                      </span>
                    </td>

                    <td className="px-3 py-3 text-zinc-500">
                      {token.dexId}
                    </td>

                    <td className="px-3 py-3">
                      <div className="flex items-center gap-2">
                        <Link
                          href={`/token/${token.address}`}
                          className="rounded-lg border border-emerald-400/15 bg-emerald-400/[0.06] px-2.5 py-1.5 text-[11px] text-emerald-300 hover:bg-emerald-400/10"
                        >
                          Analyze
                        </Link>

                        {token.dexUrl && (
                          <a
                            href={
                              token.dexUrl
                            }
                            target="_blank"
                            rel="noreferrer"
                            className="rounded-lg border border-white/10 p-1.5 text-zinc-500 hover:text-white"
                          >
                            <ExternalLink className="h-3.5 w-3.5" />
                          </a>
                        )}
                      </div>
                    </td>
                  </tr>
                ),
              )}
            </tbody>
          </table>
        </div>

        {!loading &&
          filtered.length === 0 && (
            <div className="p-10 text-center text-sm text-zinc-600">
              No tokens match the current
              filters.
            </div>
          )}

        {loading && !data && (
          <div className="flex items-center justify-center gap-2 p-12 text-sm text-zinc-500">
            <RefreshCw className="h-4 w-4 animate-spin" />
            Loading terminal data…
          </div>
        )}
      </section>

      <div className="mt-3 flex flex-wrap justify-between gap-2 text-[10px] text-zinc-700">
        <span>
          Showing {filtered.length} of{" "}
          {data?.tokenCount ?? 0} loaded
          Solana tokens
        </span>

        <span>
          Activity Score is a ranking
          heuristic, not a probability or
          trade recommendation.
        </span>
      </div>
    </main>
  );
}
'@

Write-Utf8NoBom "src/app/scanner/page.tsx" $scanner

# =========================================================
# 4. DISCOVER PAGE
# =========================================================

$discover = @'
"use client";

import Link from "next/link";
import {
  ArrowUpRight,
  Flame,
  Globe2,
  Megaphone,
  RefreshCw,
  Rocket,
  Search,
  Sparkles,
  Users,
  Zap,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

import type {
  TerminalResponse,
  TerminalToken,
} from "@/lib/terminal-types";

type DiscoveryMode =
  | "new"
  | "trending"
  | "spike"
  | "gainers"
  | "boosted"
  | "takeover";

function money(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "—";
  }

  if (value >= 1_000_000_000) {
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  }

  if (value >= 1_000_000) {
    return `$${(value / 1_000_000).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(value / 1_000).toFixed(1)}K`;
  }

  return `$${value.toFixed(2)}`;
}

function age(minutes: number | null) {
  if (minutes === null) return "—";

  if (minutes < 60) {
    return `${Math.floor(minutes)}m`;
  }

  if (minutes < 1_440) {
    return `${Math.floor(
      minutes / 60,
    )}h`;
  }

  return `${Math.floor(
    minutes / 1_440,
  )}d`;
}

function pct(value: number | null) {
  if (value === null) return "—";

  return `${value > 0 ? "+" : ""}${value.toFixed(
    1,
  )}%`;
}

function sortTokens(
  mode: DiscoveryMode,
  tokens: TerminalToken[],
) {
  const output = [...tokens];

  if (mode === "new") {
    return output.sort(
      (a, b) =>
        (a.pairAgeMinutes ??
          Number.POSITIVE_INFINITY) -
        (b.pairAgeMinutes ??
          Number.POSITIVE_INFINITY),
    );
  }

  if (mode === "spike") {
    return output.sort(
      (a, b) =>
        (b.volumeSpike5m ?? -1) -
        (a.volumeSpike5m ?? -1),
    );
  }

  if (mode === "gainers") {
    return output.sort(
      (a, b) =>
        (b.priceChange.m5 ?? -9999) -
        (a.priceChange.m5 ?? -9999),
    );
  }

  if (mode === "boosted") {
    return output
      .filter(
        (token) =>
          token.boostsActive > 0 ||
          token.sources.boostedLatest ||
          token.sources.boostedTop,
      )
      .sort(
        (a, b) =>
          b.boostsActive -
            a.boostsActive ||
          b.activityScore -
            a.activityScore,
      );
  }

  if (mode === "takeover") {
    return output
      .filter(
        (token) =>
          token.sources
            .communityTakeover,
      )
      .sort(
        (a, b) =>
          b.activityScore -
          a.activityScore,
      );
  }

  return output.sort(
    (a, b) =>
      b.activityScore -
      a.activityScore,
  );
}

function TokenCard({
  token,
}: {
  token: TerminalToken;
}) {
  const buys = token.txns.m5.buys;
  const sells = token.txns.m5.sells;
  const total = buys + sells;

  const buyShare =
    total > 0
      ? Math.round(
          (buys / total) * 100,
        )
      : null;

  return (
    <article className="rounded-2xl border border-white/10 bg-white/[0.025] p-4 transition hover:border-white/15 hover:bg-white/[0.035]">
      <div className="flex items-start justify-between gap-3">
        <div className="flex min-w-0 items-center gap-3">
          {token.imageUrl ? (
            <img
              src={token.imageUrl}
              alt=""
              className="h-11 w-11 shrink-0 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-white/10 bg-black/20 text-xs font-bold text-zinc-500">
              {token.symbol.slice(0, 2)}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <h3 className="truncate text-base font-semibold text-white">
                {token.symbol}
              </h3>

              {token.sources
                .communityTakeover && (
                <span className="rounded bg-violet-400/10 px-1.5 py-0.5 text-[9px] text-violet-300">
                  CTO
                </span>
              )}

              {token.boostsActive >
                0 && (
                <span className="rounded bg-amber-400/10 px-1.5 py-0.5 text-[9px] text-amber-300">
                  BOOST
                </span>
              )}
            </div>

            <div className="truncate text-xs text-zinc-600">
              {token.name}
            </div>
          </div>
        </div>

        <div className="text-right">
          <div
            className={`text-xl font-semibold ${
              token.activityScore >= 70
                ? "text-emerald-300"
                : token.activityScore >= 45
                  ? "text-amber-300"
                  : "text-zinc-400"
            }`}
          >
            {token.activityScore}
          </div>

          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            activity
          </div>
        </div>
      </div>

      <div className="mt-4 grid grid-cols-3 gap-2">
        <div className="rounded-xl bg-black/20 p-2.5">
          <div className="text-[10px] text-zinc-600">
            Age
          </div>
          <div className="mt-1 text-xs font-medium text-zinc-200">
            {age(
              token.pairAgeMinutes,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-2.5">
          <div className="text-[10px] text-zinc-600">
            MC
          </div>
          <div className="mt-1 text-xs font-medium text-zinc-200">
            {money(
              token.marketCap ??
                token.fdv,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-2.5">
          <div className="text-[10px] text-zinc-600">
            Liquidity
          </div>
          <div className="mt-1 text-xs font-medium text-zinc-200">
            {money(
              token.liquidityUsd,
            )}
          </div>
        </div>
      </div>

      <div className="mt-3 grid grid-cols-4 gap-2 text-center">
        <div>
          <div className="text-[9px] text-zinc-700">
            5m
          </div>
          <div
            className={`mt-1 text-xs ${
              (token.priceChange.m5 ??
                0) >= 0
                ? "text-emerald-300"
                : "text-red-300"
            }`}
          >
            {pct(
              token.priceChange.m5,
            )}
          </div>
        </div>

        <div>
          <div className="text-[9px] text-zinc-700">
            Vol 5m
          </div>
          <div className="mt-1 text-xs text-zinc-300">
            {money(
              token.volume.m5,
            )}
          </div>
        </div>

        <div>
          <div className="text-[9px] text-zinc-700">
            Spike
          </div>
          <div className="mt-1 text-xs text-amber-300">
            {token.volumeSpike5m !==
            null
              ? `${token.volumeSpike5m.toFixed(
                  1,
                )}x`
              : "—"}
          </div>
        </div>

        <div>
          <div className="text-[9px] text-zinc-700">
            Buy %
          </div>
          <div className="mt-1 text-xs text-zinc-300">
            {buyShare !== null
              ? `${buyShare}%`
              : "—"}
          </div>
        </div>
      </div>

      <div className="mt-4 flex flex-wrap gap-1.5">
        {token.sources.latestProfile && (
          <span className="rounded-full border border-white/5 px-2 py-1 text-[9px] text-zinc-500">
            new profile
          </span>
        )}

        {token.sources.recentUpdate && (
          <span className="rounded-full border border-white/5 px-2 py-1 text-[9px] text-zinc-500">
            updated
          </span>
        )}

        {token.sources.advertised && (
          <span className="rounded-full border border-white/5 px-2 py-1 text-[9px] text-zinc-500">
            ad
          </span>
        )}

        {token.socials
          .slice(0, 2)
          .map((social) => (
            <span
              key={`${social.platform}-${social.handle}`}
              className="rounded-full border border-white/5 px-2 py-1 text-[9px] text-zinc-600"
            >
              {social.platform}
            </span>
          ))}

        {token.websites.length >
          0 && (
          <span className="rounded-full border border-white/5 px-2 py-1 text-[9px] text-zinc-600">
            website
          </span>
        )}
      </div>

      <div className="mt-4 flex items-center justify-between">
        <div className="text-[10px] text-zinc-700">
          {token.dexId}
        </div>

        <div className="flex gap-2">
          <Link
            href={`/token/${token.address}`}
            className="rounded-lg border border-emerald-400/15 bg-emerald-400/[0.06] px-2.5 py-1.5 text-[10px] text-emerald-300"
          >
            Analyze
          </Link>

          {token.dexUrl && (
            <a
              href={token.dexUrl}
              target="_blank"
              rel="noreferrer"
              className="rounded-lg border border-white/10 p-1.5 text-zinc-500 hover:text-white"
            >
              <ArrowUpRight className="h-3.5 w-3.5" />
            </a>
          )}
        </div>
      </div>
    </article>
  );
}

export default function DiscoverPage() {
  const [data, setData] =
    useState<TerminalResponse | null>(
      null,
    );

  const [mode, setMode] =
    useState<DiscoveryMode>(
      "trending",
    );

  const [query, setQuery] =
    useState("");

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  async function load(
    silent = false,
  ) {
    if (!silent) setLoading(true);

    try {
      const response = await fetch(
        "/api/terminal/solana",
        {
          cache: "no-store",
        },
      );

      const result =
        (await response.json()) as
          | TerminalResponse
          | { error?: string };

      if (!response.ok) {
        throw new Error(
          "error" in result
            ? result.error
            : "Discover failed.",
        );
      }

      setData(
        result as TerminalResponse,
      );

      setError("");
    } catch (loadError) {
      setError(
        loadError instanceof Error
          ? loadError.message
          : "Discover failed.",
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();

    const timer = window.setInterval(
      () => {
        void load(true);
      },
      15_000,
    );

    return () =>
      window.clearInterval(timer);
  }, []);

  const visible = useMemo(() => {
    const needle =
      query.trim().toLowerCase();

    const base = (data?.tokens ?? []).filter(
      (token) =>
        !needle ||
        token.symbol
          .toLowerCase()
          .includes(needle) ||
        token.name
          .toLowerCase()
          .includes(needle) ||
        token.address
          .toLowerCase()
          .includes(needle),
    );

    return sortTokens(
      mode,
      base,
    ).slice(0, 48);
  }, [data, mode, query]);

  const modes: Array<{
    id: DiscoveryMode;
    label: string;
    icon: typeof Flame;
  }> = [
    {
      id: "trending",
      label: "Trending",
      icon: Flame,
    },
    {
      id: "new",
      label: "New",
      icon: Sparkles,
    },
    {
      id: "spike",
      label: "Volume Spike",
      icon: Zap,
    },
    {
      id: "gainers",
      label: "Gainers",
      icon: Rocket,
    },
    {
      id: "boosted",
      label: "Boosted",
      icon: Megaphone,
    },
    {
      id: "takeover",
      label: "Community Takeover",
      icon: Users,
    },
  ];

  return (
    <main className="mx-auto w-full max-w-[1700px] px-4 py-6 lg:px-7">
      <section className="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.2em] text-emerald-300">
            <Globe2 className="h-3.5 w-3.5" />
            Solana discovery engine
          </div>

          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
            Discover
          </h1>

          <p className="mt-2 max-w-2xl text-sm leading-6 text-zinc-500">
            New profiles, updated tokens,
            boosts, community takeovers,
            gainers and abnormal 5-minute
            activity in one board.
          </p>
        </div>

        <button
          onClick={() =>
            void load()
          }
          disabled={loading}
          className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5"
        >
          <RefreshCw
            className={`h-3.5 w-3.5 ${
              loading
                ? "animate-spin"
                : ""
            }`}
          />
          Refresh
        </button>
      </section>

      <section className="mb-5 rounded-2xl border border-white/10 bg-white/[0.02] p-3">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />

          <input
            value={query}
            onChange={(event) =>
              setQuery(
                event.target.value,
              )
            }
            placeholder="Search tokens"
            className="w-full rounded-xl border border-white/10 bg-black/25 py-3 pl-10 pr-3 text-sm text-white outline-none placeholder:text-zinc-700 focus:border-emerald-400/30"
          />
        </div>

        <div className="mt-3 flex gap-1 overflow-x-auto">
          {modes.map((item) => {
            const Icon = item.icon;

            return (
              <button
                key={item.id}
                onClick={() =>
                  setMode(item.id)
                }
                className={`flex whitespace-nowrap items-center gap-2 rounded-xl px-3 py-2 text-xs transition ${
                  mode === item.id
                    ? "bg-white text-black"
                    : "text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
                }`}
              >
                <Icon className="h-3.5 w-3.5" />
                {item.label}
              </button>
            );
          })}
        </div>
      </section>

      {error && (
        <div className="mb-5 rounded-xl border border-red-400/20 bg-red-400/[0.05] p-3 text-sm text-red-200">
          {error}
        </div>
      )}

      {loading && !data ? (
        <div className="flex min-h-[400px] items-center justify-center gap-2 rounded-2xl border border-white/10 text-sm text-zinc-500">
          <RefreshCw className="h-4 w-4 animate-spin" />
          Loading discovery feed…
        </div>
      ) : (
        <section className="grid gap-4 md:grid-cols-2 xl:grid-cols-3 2xl:grid-cols-4">
          {visible.map((token) => (
            <TokenCard
              key={token.address}
              token={token}
            />
          ))}
        </section>
      )}

      {!loading &&
        visible.length === 0 && (
          <div className="rounded-2xl border border-white/10 p-12 text-center text-sm text-zinc-600">
            Nothing found in this category.
          </div>
        )}

      <div className="mt-5 flex flex-wrap justify-between gap-2 text-[10px] text-zinc-700">
        <span>
          {visible.length} cards visible ·{" "}
          {data?.tokenCount ?? 0} tokens
          loaded
        </span>

        <span>
          Volume Spike compares current 5m
          volume with the 1h average 5m
          pace.
        </span>
      </div>
    </main>
  );
}
'@

Write-Utf8NoBom "src/app/discover/page.tsx" $discover

# =========================================================
# 5. Clear cache
# =========================================================

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 09 berhasil dipasang" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Scanner sekarang punya:" -ForegroundColor Cyan
Write-Host " - dense market table"
Write-Host " - up to ~180 discovery candidates"
Write-Host " - Trending / New / Gainers / Volume / Liquidity / Boosted"
Write-Host " - 5m / 1h / 6h / 24h price change"
Write-Host " - 5m buys & sells"
Write-Host " - 5m / 1h volumes"
Write-Host " - liquidity / MC / FDV / age / DEX"
Write-Host " - volume spike + activity score"
Write-Host " - search + liquidity + age filters"
Write-Host ""
Write-Host "Discover sekarang punya:" -ForegroundColor Cyan
Write-Host " - Trending"
Write-Host " - New"
Write-Host " - Volume Spike"
Write-Host " - Gainers"
Write-Host " - Boosted"
Write-Host " - Community Takeover"
Write-Host " - up to 48 rich token cards per category"
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor Cyan
Write-Host "npm run dev" -ForegroundColor White
Write-Host ""
