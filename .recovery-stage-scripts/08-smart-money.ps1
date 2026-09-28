$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 08 - Smart Money Engine" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
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

# ---------------------------------------------------------
# 0. Basic checks + backup
# ---------------------------------------------------------

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "package.json tidak ditemukan. Jalankan script ini dari root project memecoin-analyst."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-stage08-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$sidebarPath = Join-Path $root "src/components/sidebar.tsx"
if (Test-Path -LiteralPath $sidebarPath) {
    Copy-Item -LiteralPath $sidebarPath -Destination (Join-Path $backupDir "sidebar.tsx.bak") -Force
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------
# 1. Types
# ---------------------------------------------------------

$types = @'
export type SmartMoneyEvent = {
  wallet: string;
  mint: string;
  amount: number;
  timestamp: number;
  signature: string;
};

export type SmartMoneySignal = {
  mint: string;
  symbol: string;
  name: string;
  walletCount: number;
  wallets: string[];
  eventCount: number;
  totalTokenInflow: number;
  latestTimestamp: number;

  priceUsd: number | null;
  liquidityUsd: number | null;
  marketCap: number | null;
  fdv: number | null;
  volume5m: number | null;
  buys5m: number | null;
  sells5m: number | null;
  priceChange5m: number | null;
  pairCreatedAt: number | null;
  dexUrl: string | null;

  attentionScore: number;
  classification: "cluster" | "single";
};

export type SmartMoneyResponse = {
  generatedAt: number;
  walletsRequested: number;
  walletsAnalyzed: number;
  signaturesInspected: number;
  transactionsInspected: number;
  windowMinutes: number;
  signals: SmartMoneySignal[];
  events: SmartMoneyEvent[];
  warnings: string[];
};
'@

Write-Utf8NoBom "src/lib/smart-money-types.ts" $types

# ---------------------------------------------------------
# 2. Smart Money API
# ---------------------------------------------------------

$api = @'
import { NextRequest, NextResponse } from "next/server";

import type {
  SmartMoneyEvent,
  SmartMoneyResponse,
  SmartMoneySignal,
} from "@/lib/smart-money-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Json = Record<string, unknown>;

type RpcRequest = {
  id: number;
  method: string;
  params: unknown[];
};

type TokenBalance = {
  mint?: string;
  owner?: string;
  uiTokenAmount?: {
    uiAmount?: number | null;
    uiAmountString?: string;
  };
};

type DexPair = {
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
  priceUsd?: string | null;
  liquidity?: {
    usd?: number | null;
  };
  marketCap?: number | null;
  fdv?: number | null;
  volume?: {
    m5?: number | null;
  };
  txns?: {
    m5?: {
      buys?: number;
      sells?: number;
    };
  };
  priceChange?: {
    m5?: number | null;
  };
  pairCreatedAt?: number | null;
};

const WSOL = "So11111111111111111111111111111111111111112";
const USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

const IGNORE_MINTS = new Set([WSOL, USDC]);

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isSolanaAddress(value: string) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(value);
}

function getRpcUrl() {
  const value = process.env.SOLANA_RPC_URL?.trim();

  if (!value) {
    throw new Error(
      "SOLANA_RPC_URL belum dikonfigurasi. Tambahkan private Solana RPC di .env.local.",
    );
  }

  return value;
}

async function rpc(
  request: RpcRequest,
): Promise<unknown> {
  const rpcUrl = getRpcUrl();

  for (let attempt = 1; attempt <= 4; attempt++) {
    const response = await fetch(rpcUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: request.id,
        method: request.method,
        params: request.params,
      }),
      cache: "no-store",
    });

    if (response.status === 429) {
      if (attempt === 4) {
        throw new Error("Solana RPC rate limit reached.");
      }

      await sleep(500 * 2 ** (attempt - 1));
      continue;
    }

    if (!response.ok) {
      throw new Error(`Solana RPC ${response.status}`);
    }

    const data = (await response.json()) as {
      result?: unknown;
      error?: { message?: string };
    };

    if (data.error) {
      throw new Error(data.error.message || `${request.method} failed`);
    }

    return data.result;
  }

  throw new Error(`${request.method} failed`);
}

async function rpcBatch(
  requests: RpcRequest[],
): Promise<Map<number, unknown>> {
  const rpcUrl = getRpcUrl();

  if (requests.length === 0) {
    return new Map();
  }

  for (let attempt = 1; attempt <= 4; attempt++) {
    const response = await fetch(rpcUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify(
        requests.map((request) => ({
          jsonrpc: "2.0",
          id: request.id,
          method: request.method,
          params: request.params,
        })),
      ),
      cache: "no-store",
    });

    if (response.status === 429) {
      if (attempt === 4) {
        throw new Error("Solana RPC batch rate limit reached.");
      }

      await sleep(700 * 2 ** (attempt - 1));
      continue;
    }

    if (!response.ok) {
      throw new Error(`Solana RPC ${response.status}`);
    }

    const payload = (await response.json()) as Array<{
      id?: number;
      result?: unknown;
      error?: { message?: string };
    }>;

    const output = new Map<number, unknown>();

    for (const item of Array.isArray(payload) ? payload : []) {
      if (typeof item.id !== "number") continue;
      if (item.error) continue;
      output.set(item.id, item.result);
    }

    return output;
  }

  return new Map();
}

function tokenAmount(balance: TokenBalance | undefined) {
  if (!balance?.uiTokenAmount) return 0;

  const raw =
    balance.uiTokenAmount.uiAmountString ??
    String(balance.uiTokenAmount.uiAmount ?? "0");

  const value = Number(raw);
  return Number.isFinite(value) ? value : 0;
}

function balancesForWallet(
  balances: unknown,
  wallet: string,
) {
  const map = new Map<string, number>();

  if (!Array.isArray(balances)) return map;

  for (const raw of balances) {
    const balance = raw as TokenBalance;

    if (balance.owner !== wallet || !balance.mint) {
      continue;
    }

    const amount = tokenAmount(balance);
    map.set(
      balance.mint,
      (map.get(balance.mint) ?? 0) + amount,
    );
  }

  return map;
}

function parseInflows(
  transaction: unknown,
  wallet: string,
  signature: string,
  fallbackTimestamp: number,
): SmartMoneyEvent[] {
  if (!transaction || typeof transaction !== "object") return [];

  const tx = transaction as {
    blockTime?: number | null;
    meta?: {
      err?: unknown;
      preTokenBalances?: unknown;
      postTokenBalances?: unknown;
    } | null;
  };

  if (!tx.meta || tx.meta.err) return [];

  const pre = balancesForWallet(
    tx.meta.preTokenBalances,
    wallet,
  );

  const post = balancesForWallet(
    tx.meta.postTokenBalances,
    wallet,
  );

  const mints = new Set([
    ...Array.from(pre.keys()),
    ...Array.from(post.keys()),
  ]);

  const timestamp =
    typeof tx.blockTime === "number"
      ? tx.blockTime * 1000
      : fallbackTimestamp;

  const events: SmartMoneyEvent[] = [];

  for (const mint of mints) {
    if (IGNORE_MINTS.has(mint)) continue;

    const before = pre.get(mint) ?? 0;
    const after = post.get(mint) ?? 0;
    const delta = after - before;

    if (!Number.isFinite(delta) || delta <= 0) continue;

    events.push({
      wallet,
      mint,
      amount: delta,
      timestamp,
      signature,
    });
  }

  return events;
}

async function fetchWalletEvents(
  wallet: string,
  signatureLimit: number,
  windowStart: number,
  idSeed: number,
) {
  const signatures = (await rpc({
    id: idSeed,
    method: "getSignaturesForAddress",
    params: [
      wallet,
      {
        limit: signatureLimit,
        commitment: "confirmed",
      },
    ],
  })) as Array<{
    signature?: string;
    blockTime?: number | null;
    err?: unknown;
  }> | null;

  const usable = (signatures ?? []).filter(
    (item) =>
      item.signature &&
      !item.err &&
      (!item.blockTime ||
        item.blockTime * 1000 >= windowStart),
  );

  const requests: RpcRequest[] = usable.map(
    (item, index) => ({
      id: idSeed + 100 + index,
      method: "getTransaction",
      params: [
        item.signature,
        {
          encoding: "jsonParsed",
          commitment: "confirmed",
          maxSupportedTransactionVersion: 0,
        },
      ],
    }),
  );

  const transactions = await rpcBatch(requests);
  const events: SmartMoneyEvent[] = [];

  usable.forEach((item, index) => {
    const signature = item.signature;
    if (!signature) return;

    const tx = transactions.get(idSeed + 100 + index);

    events.push(
      ...parseInflows(
        tx,
        wallet,
        signature,
        item.blockTime
          ? item.blockTime * 1000
          : Date.now(),
      ),
    );
  });

  return {
    events,
    signatureCount: usable.length,
    transactionCount: transactions.size,
  };
}

function chooseBestPair(
  mint: string,
  pairs: DexPair[],
) {
  const candidates = pairs.filter((pair) => {
    return (
      pair.chainId === "solana" &&
      (pair.baseToken?.address === mint ||
        pair.quoteToken?.address === mint)
    );
  });

  candidates.sort(
    (a, b) =>
      (b.liquidity?.usd ?? 0) -
      (a.liquidity?.usd ?? 0),
  );

  return candidates[0] ?? null;
}

async function fetchDexData(mints: string[]) {
  const output = new Map<string, DexPair>();

  for (let index = 0; index < mints.length; index += 30) {
    const chunk = mints.slice(index, index + 30);

    const response = await fetch(
      `https://api.dexscreener.com/tokens/v1/solana/${chunk.join(",")}`,
      {
        headers: {
          Accept: "application/json",
        },
        cache: "no-store",
      },
    );

    if (!response.ok) continue;

    const pairs = (await response.json()) as DexPair[];

    for (const mint of chunk) {
      const best = chooseBestPair(
        mint,
        Array.isArray(pairs) ? pairs : [],
      );

      if (best) output.set(mint, best);
    }
  }

  return output;
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function buildAttentionScore(
  walletCount: number,
  latestTimestamp: number,
  pair: DexPair | null,
) {
  const minutesAgo = Math.max(
    0,
    (Date.now() - latestTimestamp) / 60_000,
  );

  const walletScore = Math.min(
    52,
    walletCount * 18,
  );

  const recencyScore = clamp(
    22 - minutesAgo * 0.7,
    0,
    22,
  );

  const liquidity = pair?.liquidity?.usd ?? 0;

  let liquidityScore = 0;
  if (liquidity >= 250_000) liquidityScore = 12;
  else if (liquidity >= 100_000) liquidityScore = 10;
  else if (liquidity >= 50_000) liquidityScore = 8;
  else if (liquidity >= 20_000) liquidityScore = 5;
  else if (liquidity >= 5_000) liquidityScore = 2;

  const buys = pair?.txns?.m5?.buys ?? 0;
  const sells = pair?.txns?.m5?.sells ?? 0;
  const total = buys + sells;

  const buyShare =
    total > 0 ? buys / total : 0.5;

  const flowScore =
    total >= 10
      ? clamp((buyShare - 0.45) * 40, 0, 10)
      : 0;

  const pairCreatedAt = pair?.pairCreatedAt ?? 0;
  const ageHours =
    pairCreatedAt > 0
      ? (Date.now() - pairCreatedAt) / 3_600_000
      : Number.POSITIVE_INFINITY;

  const earlyScore =
    ageHours <= 6 ? 4 : ageHours <= 24 ? 2 : 0;

  return Math.round(
    clamp(
      walletScore +
        recencyScore +
        liquidityScore +
        flowScore +
        earlyScore,
      0,
      100,
    ),
  );
}

function tokenIdentity(
  mint: string,
  pair: DexPair | null,
) {
  if (!pair) {
    return {
      symbol: `${mint.slice(0, 4)}…${mint.slice(-4)}`,
      name: "Unknown token",
    };
  }

  if (pair.baseToken?.address === mint) {
    return {
      symbol: pair.baseToken.symbol || "UNKNOWN",
      name: pair.baseToken.name || "Unknown token",
    };
  }

  return {
    symbol: pair.quoteToken?.symbol || "UNKNOWN",
    name: pair.quoteToken?.name || "Unknown token",
  };
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as {
      wallets?: unknown;
      windowMinutes?: unknown;
      signatureLimit?: unknown;
    };

    const rawWallets = Array.isArray(body.wallets)
      ? body.wallets
      : [];

    const wallets = Array.from(
      new Set(
        rawWallets
          .filter((value): value is string => typeof value === "string")
          .map((value) => value.trim())
          .filter(isSolanaAddress),
      ),
    ).slice(0, 12);

    if (wallets.length === 0) {
      return NextResponse.json(
        {
          error:
            "Tambahkan minimal satu Solana wallet address yang valid.",
        },
        { status: 400 },
      );
    }

    const windowMinutes = clamp(
      Number(body.windowMinutes) || 30,
      5,
      180,
    );

    const signatureLimit = Math.round(
      clamp(
        Number(body.signatureLimit) || 8,
        3,
        15,
      ),
    );

    const windowStart =
      Date.now() - windowMinutes * 60_000;

    const events: SmartMoneyEvent[] = [];
    const warnings: string[] = [];

    let signaturesInspected = 0;
    let transactionsInspected = 0;
    let walletsAnalyzed = 0;

    // Sequential by wallet to stay friendly to lower RPC plans.
    for (let index = 0; index < wallets.length; index++) {
      const wallet = wallets[index];

      try {
        const result = await fetchWalletEvents(
          wallet,
          signatureLimit,
          windowStart,
          1_000 + index * 1_000,
        );

        events.push(...result.events);
        signaturesInspected += result.signatureCount;
        transactionsInspected += result.transactionCount;
        walletsAnalyzed += 1;
      } catch (error) {
        warnings.push(
          `${wallet.slice(0, 5)}…${wallet.slice(-4)}: ${
            error instanceof Error
              ? error.message
              : "wallet scan failed"
          }`,
        );
      }

      if (index < wallets.length - 1) {
        await sleep(110);
      }
    }

    const recentEvents = events
      .filter((event) => event.timestamp >= windowStart)
      .sort((a, b) => b.timestamp - a.timestamp);

    const grouped = new Map<
      string,
      {
        wallets: Set<string>;
        eventCount: number;
        totalTokenInflow: number;
        latestTimestamp: number;
      }
    >();

    for (const event of recentEvents) {
      const current = grouped.get(event.mint) ?? {
        wallets: new Set<string>(),
        eventCount: 0,
        totalTokenInflow: 0,
        latestTimestamp: 0,
      };

      current.wallets.add(event.wallet);
      current.eventCount += 1;
      current.totalTokenInflow += event.amount;
      current.latestTimestamp = Math.max(
        current.latestTimestamp,
        event.timestamp,
      );

      grouped.set(event.mint, current);
    }

    const mints = Array.from(grouped.keys()).slice(0, 60);
    const dexData = await fetchDexData(mints);

    const signals: SmartMoneySignal[] = Array.from(
      grouped.entries(),
    ).map(([mint, aggregate]) => {
      const pair = dexData.get(mint) ?? null;
      const identity = tokenIdentity(mint, pair);

      const walletsForMint = Array.from(
        aggregate.wallets,
      );

      return {
        mint,
        symbol: identity.symbol,
        name: identity.name,
        walletCount: walletsForMint.length,
        wallets: walletsForMint,
        eventCount: aggregate.eventCount,
        totalTokenInflow: aggregate.totalTokenInflow,
        latestTimestamp: aggregate.latestTimestamp,

        priceUsd: pair?.priceUsd
          ? Number(pair.priceUsd)
          : null,

        liquidityUsd:
          typeof pair?.liquidity?.usd === "number"
            ? pair.liquidity.usd
            : null,

        marketCap:
          typeof pair?.marketCap === "number"
            ? pair.marketCap
            : null,

        fdv:
          typeof pair?.fdv === "number"
            ? pair.fdv
            : null,

        volume5m:
          typeof pair?.volume?.m5 === "number"
            ? pair.volume.m5
            : null,

        buys5m:
          typeof pair?.txns?.m5?.buys === "number"
            ? pair.txns.m5.buys
            : null,

        sells5m:
          typeof pair?.txns?.m5?.sells === "number"
            ? pair.txns.m5.sells
            : null,

        priceChange5m:
          typeof pair?.priceChange?.m5 === "number"
            ? pair.priceChange.m5
            : null,

        pairCreatedAt:
          typeof pair?.pairCreatedAt === "number"
            ? pair.pairCreatedAt
            : null,

        dexUrl: pair?.url ?? null,

        attentionScore: buildAttentionScore(
          walletsForMint.length,
          aggregate.latestTimestamp,
          pair,
        ),

        classification:
          walletsForMint.length >= 2
            ? "cluster"
            : "single",
      };
    });

    signals.sort((a, b) => {
      if (b.walletCount !== a.walletCount) {
        return b.walletCount - a.walletCount;
      }

      if (b.attentionScore !== a.attentionScore) {
        return b.attentionScore - a.attentionScore;
      }

      return b.latestTimestamp - a.latestTimestamp;
    });

    const response: SmartMoneyResponse = {
      generatedAt: Date.now(),
      walletsRequested: wallets.length,
      walletsAnalyzed,
      signaturesInspected,
      transactionsInspected,
      windowMinutes,
      signals,
      events: recentEvents.slice(0, 100),
      warnings,
    };

    return NextResponse.json(response);
  } catch (error) {
    console.error("[Smart Money]", error);

    return NextResponse.json(
      {
        error:
          error instanceof Error
            ? error.message
            : "Smart Money analysis failed.",
      },
      { status: 500 },
    );
  }
}
'@

Write-Utf8NoBom "src/app/api/smart-money/solana/route.ts" $api

# ---------------------------------------------------------
# 3. Smart Money page
# ---------------------------------------------------------

$page = @'
"use client";

import Link from "next/link";
import {
  Activity,
  AlertTriangle,
  ExternalLink,
  Radio,
  RefreshCw,
  Save,
  Users,
  WalletCards,
  Zap,
} from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import type {
  SmartMoneyResponse,
  SmartMoneySignal,
} from "@/lib/smart-money-types";

const STORAGE_KEY = "memescope-smart-money-wallets";

function short(value: string) {
  return `${value.slice(0, 5)}…${value.slice(-4)}`;
}

function money(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "—";

  if (value >= 1_000_000_000) {
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  }

  if (value >= 1_000_000) {
    return `$${(value / 1_000_000).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(value / 1_000).toFixed(1)}K`;
  }

  if (value >= 1) {
    return `$${value.toFixed(2)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function tokenAmount(value: number) {
  if (!Number.isFinite(value)) return "—";

  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value);
}

function age(timestamp: number) {
  const seconds = Math.max(
    0,
    Math.floor((Date.now() - timestamp) / 1000),
  );

  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  return `${Math.floor(minutes / 60)}h ago`;
}

function scoreTone(score: number) {
  if (score >= 75) return "text-emerald-300";
  if (score >= 50) return "text-amber-300";
  return "text-zinc-300";
}

function SignalCard({
  signal,
}: {
  signal: SmartMoneySignal;
}) {
  const totalTrades =
    (signal.buys5m ?? 0) +
    (signal.sells5m ?? 0);

  const buyShare =
    totalTrades > 0
      ? Math.round(
          ((signal.buys5m ?? 0) / totalTrades) * 100,
        )
      : null;

  return (
    <article className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2">
            <h3 className="text-xl font-semibold text-white">
              {signal.symbol}
            </h3>

            {signal.classification === "cluster" && (
              <span className="rounded-full border border-emerald-400/20 bg-emerald-400/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.16em] text-emerald-300">
                wallet cluster
              </span>
            )}
          </div>

          <p className="mt-1 text-sm text-zinc-500">
            {signal.name}
          </p>

          <p className="mt-2 font-mono text-xs text-zinc-600">
            {short(signal.mint)}
          </p>
        </div>

        <div className="text-right">
          <div
            className={`text-3xl font-semibold ${scoreTone(
              signal.attentionScore,
            )}`}
          >
            {signal.attentionScore}
          </div>
          <div className="text-[10px] uppercase tracking-[0.18em] text-zinc-600">
            attention
          </div>
        </div>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Tracked wallets
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {signal.walletCount}
          </div>
        </div>

        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Inflow events
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {signal.eventCount}
          </div>
        </div>

        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Liquidity
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {money(signal.liquidityUsd)}
          </div>
        </div>

        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Market cap
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {money(signal.marketCap ?? signal.fdv)}
          </div>
        </div>
      </div>

      <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-xs text-zinc-400">
        <span>
          Last inflow:{" "}
          <strong className="text-zinc-200">
            {age(signal.latestTimestamp)}
          </strong>
        </span>

        <span>
          Observed token inflow:{" "}
          <strong className="text-zinc-200">
            {tokenAmount(signal.totalTokenInflow)}
          </strong>
        </span>

        <span>
          5m volume:{" "}
          <strong className="text-zinc-200">
            {money(signal.volume5m)}
          </strong>
        </span>

        <span>
          5m buy share:{" "}
          <strong className="text-zinc-200">
            {buyShare === null ? "—" : `${buyShare}%`}
          </strong>
        </span>
      </div>

      <div className="mt-4">
        <div className="mb-2 text-[10px] uppercase tracking-[0.16em] text-zinc-600">
          wallets observed
        </div>

        <div className="flex flex-wrap gap-2">
          {signal.wallets.map((wallet) => (
            <span
              key={wallet}
              className="rounded-lg border border-white/5 bg-black/20 px-2 py-1 font-mono text-[11px] text-zinc-400"
            >
              {short(wallet)}
            </span>
          ))}
        </div>
      </div>

      <div className="mt-5 flex flex-wrap gap-3">
        <Link
          href={`/token/${signal.mint}`}
          className="inline-flex items-center gap-2 rounded-xl border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-xs font-medium text-emerald-300 transition hover:bg-emerald-400/15"
        >
          Analyze token
          <ExternalLink className="h-3.5 w-3.5" />
        </Link>

        {signal.dexUrl && (
          <a
            href={signal.dexUrl}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 transition hover:bg-white/5"
          >
            DexScreener
            <ExternalLink className="h-3.5 w-3.5" />
          </a>
        )}
      </div>
    </article>
  );
}

export default function SmartMoneyPage() {
  const [walletText, setWalletText] = useState("");
  const [wallets, setWallets] = useState<string[]>([]);
  const [data, setData] =
    useState<SmartMoneyResponse | null>(null);

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [lastEventAt, setLastEventAt] =
    useState<number | null>(null);

  const runningRef = useRef(false);
  const refreshTimerRef =
    useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY);

    if (!saved) return;

    try {
      const parsed = JSON.parse(saved) as unknown;

      if (Array.isArray(parsed)) {
        const values = parsed.filter(
          (value): value is string =>
            typeof value === "string",
        );

        setWallets(values);
        setWalletText(values.join("\n"));
      }
    } catch {
      // Ignore malformed local storage.
    }
  }, []);

  const parsedWallets = useMemo(() => {
    return Array.from(
      new Set(
        walletText
          .split(/[\n,\s]+/)
          .map((value) => value.trim())
          .filter(Boolean),
      ),
    ).slice(0, 12);
  }, [walletText]);

  const analyze = useCallback(
    async (
      addresses: string[] = wallets,
      silent = false,
    ) => {
      if (addresses.length === 0 || runningRef.current) {
        return;
      }

      runningRef.current = true;

      if (!silent) setLoading(true);
      setError("");

      try {
        const response = await fetch(
          "/api/smart-money/solana",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              wallets: addresses,
              windowMinutes: 30,
              signatureLimit: 8,
            }),
          },
        );

        const result = await response.json();

        if (!response.ok) {
          throw new Error(
            result.error || "Smart Money scan failed.",
          );
        }

        setData(result as SmartMoneyResponse);
      } catch (scanError) {
        setError(
          scanError instanceof Error
            ? scanError.message
            : "Smart Money scan failed.",
        );
      } finally {
        runningRef.current = false;
        setLoading(false);
      }
    },
    [wallets],
  );

  const saveAndAnalyze = async () => {
    if (parsedWallets.length === 0) {
      setError("Masukkan minimal satu wallet Solana.");
      return;
    }

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(parsedWallets),
    );

    setWallets(parsedWallets);
    await analyze(parsedWallets);
  };

  // Reuse the Stage 05.1 wallet SSE stream.
  // On free RPC plans, keep live streams to the first five wallets.
  useEffect(() => {
    if (wallets.length === 0) return;

    const liveWallets = wallets.slice(0, 5);
    const sources: EventSource[] = [];

    const scheduleRefresh = () => {
      setLastEventAt(Date.now());

      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current);
      }

      refreshTimerRef.current = setTimeout(() => {
        void analyze(wallets, true);
      }, 650);
    };

    for (const wallet of liveWallets) {
      const source = new EventSource(
        `/api/wallet/stream/${encodeURIComponent(wallet)}`,
      );

      source.onmessage = scheduleRefresh;
      sources.push(source);
    }

    const fallback = window.setInterval(() => {
      void analyze(wallets, true);
    }, 20_000);

    return () => {
      sources.forEach((source) => source.close());
      window.clearInterval(fallback);

      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current);
      }
    };
  }, [wallets, analyze]);

  useEffect(() => {
    if (wallets.length > 0 && !data) {
      void analyze(wallets, true);
    }
  }, [wallets, data, analyze]);

  const clusters =
    data?.signals.filter(
      (signal) => signal.walletCount >= 2,
    ) ?? [];

  const singles =
    data?.signals.filter(
      (signal) => signal.walletCount === 1,
    ) ?? [];

  return (
    <main className="mx-auto w-full max-w-[1500px] px-4 py-6 lg:px-8">
      <section className="mb-7 flex flex-wrap items-start justify-between gap-5">
        <div>
          <div className="mb-2 flex items-center gap-2 text-xs uppercase tracking-[0.2em] text-emerald-300">
            <Radio className="h-4 w-4" />
            Stage 08
          </div>

          <h1 className="text-3xl font-semibold tracking-tight text-white">
            Smart Money Radar
          </h1>

          <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-400">
            Detect the same token flowing into multiple tracked
            Solana wallets. Wallet events trigger an event-driven
            refresh; a polling fallback keeps the board current.
          </p>
        </div>

        <div className="flex items-center gap-2 rounded-full border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-xs text-emerald-300">
          <span className="h-2 w-2 animate-pulse rounded-full bg-emerald-300" />
          {wallets.length > 0
            ? `Live watch · ${Math.min(wallets.length, 5)} wallets`
            : "Waiting for wallets"}
        </div>
      </section>

      <section className="grid gap-5 xl:grid-cols-[380px_minmax(0,1fr)]">
        <aside className="space-y-5">
          <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
            <div className="flex items-center gap-2 text-sm font-medium text-white">
              <WalletCards className="h-4 w-4 text-emerald-300" />
              Tracked wallets
            </div>

            <p className="mt-2 text-xs leading-5 text-zinc-500">
              One wallet per line. Maximum 12. The first five
              use the live wallet stream; all wallets are covered
              by fallback refresh.
            </p>

            <textarea
              value={walletText}
              onChange={(event) =>
                setWalletText(event.target.value)
              }
              placeholder={"WalletAddress1\nWalletAddress2\nWalletAddress3"}
              className="mt-4 min-h-44 w-full resize-y rounded-xl border border-white/10 bg-black/30 p-3 font-mono text-xs text-zinc-200 outline-none transition placeholder:text-zinc-700 focus:border-emerald-400/30"
            />

            <button
              onClick={saveAndAnalyze}
              disabled={loading}
              className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl bg-white px-4 py-3 text-sm font-semibold text-black transition hover:bg-zinc-200 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {loading ? (
                <RefreshCw className="h-4 w-4 animate-spin" />
              ) : (
                <Save className="h-4 w-4" />
              )}
              Save & analyze
            </button>

            {wallets.length > 0 && (
              <button
                onClick={() => void analyze(wallets)}
                disabled={loading}
                className="mt-2 flex w-full items-center justify-center gap-2 rounded-xl border border-white/10 px-4 py-3 text-sm text-zinc-300 transition hover:bg-white/5 disabled:opacity-50"
              >
                <RefreshCw className="h-4 w-4" />
                Refresh now
              </button>
            )}
          </div>

          <div className="rounded-2xl border border-amber-400/15 bg-amber-400/[0.04] p-4">
            <div className="flex gap-3">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-300" />

              <p className="text-xs leading-5 text-amber-100/70">
                “Smart money” here means wallets you choose to
                track. Stage 08 detects accumulation clusters; it
                does not yet claim those wallets are profitable.
                Historical PnL / win-rate scoring comes later.
              </p>
            </div>
          </div>

          {data && (
            <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
              <div className="text-[10px] uppercase tracking-[0.18em] text-zinc-600">
                Scan diagnostics
              </div>

              <div className="mt-4 grid grid-cols-2 gap-3 text-sm">
                <div>
                  <div className="text-zinc-500">
                    Wallets
                  </div>
                  <div className="mt-1 text-white">
                    {data.walletsAnalyzed}/{data.walletsRequested}
                  </div>
                </div>

                <div>
                  <div className="text-zinc-500">
                    Transactions
                  </div>
                  <div className="mt-1 text-white">
                    {data.transactionsInspected}
                  </div>
                </div>

                <div>
                  <div className="text-zinc-500">
                    Window
                  </div>
                  <div className="mt-1 text-white">
                    {data.windowMinutes}m
                  </div>
                </div>

                <div>
                  <div className="text-zinc-500">
                    Last event
                  </div>
                  <div className="mt-1 text-white">
                    {lastEventAt
                      ? age(lastEventAt)
                      : "—"}
                  </div>
                </div>
              </div>
            </div>
          )}
        </aside>

        <div className="min-w-0">
          {error && (
            <div className="mb-5 rounded-2xl border border-red-400/20 bg-red-400/[0.05] p-4 text-sm text-red-200">
              {error}
            </div>
          )}

          {!data && !loading && (
            <div className="flex min-h-[420px] flex-col items-center justify-center rounded-2xl border border-dashed border-white/10 bg-white/[0.015] p-8 text-center">
              <Zap className="h-8 w-8 text-emerald-300" />
              <h2 className="mt-4 text-lg font-semibold text-white">
                Add wallets to start the radar
              </h2>
              <p className="mt-2 max-w-md text-sm leading-6 text-zinc-500">
                MemeScope will look for recent token inflows and
                highlight tokens appearing across multiple tracked
                wallets.
              </p>
            </div>
          )}

          {loading && !data && (
            <div className="flex min-h-[420px] items-center justify-center rounded-2xl border border-white/10 bg-white/[0.015]">
              <div className="text-center">
                <RefreshCw className="mx-auto h-6 w-6 animate-spin text-emerald-300" />
                <div className="mt-3 text-sm text-zinc-400">
                  Scanning tracked wallets…
                </div>
              </div>
            </div>
          )}

          {data && (
            <div className="space-y-7">
              <section>
                <div className="mb-3 flex items-end justify-between gap-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <Users className="h-4 w-4 text-emerald-300" />
                      <h2 className="text-lg font-semibold text-white">
                        Accumulation clusters
                      </h2>
                    </div>
                    <p className="mt-1 text-xs text-zinc-500">
                      Same token observed flowing into 2+ tracked wallets.
                    </p>
                  </div>

                  <div className="text-xs text-zinc-600">
                    {clusters.length} detected
                  </div>
                </div>

                {clusters.length > 0 ? (
                  <div className="grid gap-4 2xl:grid-cols-2">
                    {clusters.map((signal) => (
                      <SignalCard
                        key={signal.mint}
                        signal={signal}
                      />
                    ))}
                  </div>
                ) : (
                  <div className="rounded-2xl border border-white/10 bg-white/[0.015] p-6 text-sm text-zinc-500">
                    No multi-wallet accumulation cluster was
                    observed in the current window.
                  </div>
                )}
              </section>

              <section>
                <div className="mb-3 flex items-end justify-between gap-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <Activity className="h-4 w-4 text-zinc-400" />
                      <h2 className="text-lg font-semibold text-white">
                        Single-wallet inflows
                      </h2>
                    </div>
                    <p className="mt-1 text-xs text-zinc-500">
                      Useful context, but weaker than a wallet cluster.
                    </p>
                  </div>

                  <div className="text-xs text-zinc-600">
                    {singles.length} tokens
                  </div>
                </div>

                <div className="grid gap-4 2xl:grid-cols-2">
                  {singles.slice(0, 12).map((signal) => (
                    <SignalCard
                      key={signal.mint}
                      signal={signal}
                    />
                  ))}
                </div>
              </section>

              {data.warnings.length > 0 && (
                <section className="rounded-2xl border border-amber-400/15 bg-amber-400/[0.03] p-4">
                  <div className="text-xs font-medium text-amber-200">
                    Partial scan warnings
                  </div>

                  <div className="mt-2 space-y-1 font-mono text-[11px] text-amber-100/60">
                    {data.warnings.map((warning) => (
                      <div key={warning}>{warning}</div>
                    ))}
                  </div>
                </section>
              )}
            </div>
          )}
        </div>
      </section>
    </main>
  );
}
'@

Write-Utf8NoBom "src/app/smart-money/page.tsx" $page

# ---------------------------------------------------------
# 4. Best-effort sidebar integration
#    Duplicate the existing Wallet nav line so no new icon import
#    is needed. If structure differs, leave the sidebar untouched.
# ---------------------------------------------------------

if (Test-Path -LiteralPath $sidebarPath) {
    $sidebar = [System.IO.File]::ReadAllText($sidebarPath)

    if ($sidebar -notmatch '["'']/smart-money["'']') {
        $pattern = '(?m)^(?<line>[ \t]*\{[^\r\n]*href:\s*["'']/wallets["''][^\r\n]*label:\s*["'']Wallets["''][^\r\n]*\},?\s*)$'
        $match = [regex]::Match($sidebar, $pattern)

        if (!$match.Success) {
            # Try reversed property ordering.
            $pattern = '(?m)^(?<line>[ \t]*\{[^\r\n]*label:\s*["'']Wallets["''][^\r\n]*href:\s*["'']/wallets["''][^\r\n]*\},?\s*)$'
            $match = [regex]::Match($sidebar, $pattern)
        }

        if ($match.Success) {
            $walletLine = $match.Groups["line"].Value
            $smartLine = $walletLine.Replace("/wallets", "/smart-money").Replace("Wallets", "Smart Money")

            $sidebar = $sidebar.Replace(
                $walletLine,
                $smartLine + [Environment]::NewLine + $walletLine
            )

            [System.IO.File]::WriteAllText(
                $sidebarPath,
                $sidebar,
                $utf8NoBom
            )

            Write-Host "Sidebar: Smart Money ditambahkan." -ForegroundColor Green
        } else {
            Write-Host "Sidebar tidak dipatch otomatis (struktur berbeda)." -ForegroundColor Yellow
            Write-Host "Page tetap tersedia di /smart-money." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Sidebar: Smart Money sudah ada." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------
# 5. Clear Next cache
# ---------------------------------------------------------

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host " Stage 08 berhasil dipasang" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Fitur:" -ForegroundColor Cyan
Write-Host " - tracked-wallet accumulation detector"
Write-Host " - multi-wallet cluster detection"
Write-Host " - DexScreener market enrichment"
Write-Host " - attention score (NOT probability)"
Write-Host " - event-driven refresh via existing wallet SSE"
Write-Host " - 20s fallback refresh"
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor Cyan
Write-Host "npm run dev" -ForegroundColor White
Write-Host ""
Write-Host "Lalu buka:" -ForegroundColor Cyan
Write-Host "http://localhost:3000/smart-money" -ForegroundColor White
Write-Host ""
