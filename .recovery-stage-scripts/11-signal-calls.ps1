$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 11 - Signal Calls" -ForegroundColor Cyan
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
    throw "package.json tidak ditemukan. Jalankan script ini dari root project memecoin-analyst."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-stage11-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$sidebarPath = Join-Path $root "src/components/sidebar.tsx"
if (Test-Path -LiteralPath $sidebarPath) {
    Copy-Item -LiteralPath $sidebarPath -Destination (Join-Path $backupDir "sidebar.tsx.bak") -Force
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray
Write-Host ""

# =========================================================
# 1. TYPES
# =========================================================

$types = @'
export type SignalKind =
  | "early-momentum"
  | "momentum"
  | "volume-spike"
  | "overheated"
  | "thin-liquidity";

export type SignalDirection =
  | "watch"
  | "caution";

export type SignalConfidence =
  | "high"
  | "medium"
  | "limited";

export type SignalCall = {
  id: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  imageUrl: string | null;

  kind: SignalKind;
  direction: SignalDirection;
  label: string;

  signalScore: number;
  confidence: SignalConfidence;

  detectedAt: number;

  priceUsd: number | null;
  priceChange5m: number | null;
  priceChange1h: number | null;

  liquidityUsd: number;
  marketCap: number | null;
  volume5m: number;
  volume1h: number;

  buys5m: number;
  sells5m: number;
  buyShare5m: number | null;
  volumeSpike5m: number | null;
  pairAgeMinutes: number | null;

  activityScore: number;

  reasons: string[];
  caution: string[];
  dexUrl: string | null;
};

export type SignalSettings = {
  minSignalScore: number;
  minLiquidityUsd: number;
  maxPairAgeHours: number;
};
'@

Write-Utf8NoBom "src/lib/signal-types.ts" $types

# =========================================================
# 2. SIGNAL ENGINE
# =========================================================

$engine = @'
import type {
  SignalCall,
  SignalConfidence,
  SignalKind,
} from "@/lib/signal-types";
import type { TerminalToken } from "@/lib/terminal-types";

function clamp(
  value: number,
  min: number,
  max: number,
) {
  return Math.max(min, Math.min(max, value));
}

function getBuyShare(token: TerminalToken) {
  const buys = token.txns.m5.buys;
  const sells = token.txns.m5.sells;
  const total = buys + sells;

  return total > 0 ? buys / total : null;
}

function confidenceFor(
  token: TerminalToken,
): SignalConfidence {
  let complete = 0;

  if (token.priceUsd !== null) complete += 1;
  if (token.marketCap !== null || token.fdv !== null) {
    complete += 1;
  }
  if (token.liquidityUsd > 0) complete += 1;
  if (token.volume.m5 > 0) complete += 1;
  if (token.pairAgeMinutes !== null) complete += 1;
  if (token.volumeSpike5m !== null) complete += 1;

  if (complete >= 6) return "high";
  if (complete >= 4) return "medium";
  return "limited";
}

function baseScore(token: TerminalToken) {
  const buyShare = getBuyShare(token);
  const spike = token.volumeSpike5m ?? 0;
  const change5m = token.priceChange.m5 ?? 0;
  const txns5m =
    token.txns.m5.buys +
    token.txns.m5.sells;

  let score = token.activityScore * 0.38;

  if (token.liquidityUsd >= 100_000) score += 12;
  else if (token.liquidityUsd >= 50_000) score += 10;
  else if (token.liquidityUsd >= 20_000) score += 7;
  else if (token.liquidityUsd >= 5_000) score += 3;

  score += clamp(spike * 5, 0, 18);

  if (buyShare !== null) {
    score += clamp(
      (buyShare - 0.5) * 50,
      0,
      12,
    );
  }

  if (txns5m >= 100) score += 8;
  else if (txns5m >= 50) score += 6;
  else if (txns5m >= 20) score += 4;
  else if (txns5m >= 8) score += 2;

  if (change5m > 0 && change5m <= 20) {
    score += clamp(change5m / 3, 0, 7);
  }

  return Math.round(clamp(score, 0, 100));
}

function buildCall(
  token: TerminalToken,
  kind: SignalKind,
  label: string,
  score: number,
  reasons: string[],
  caution: string[],
  direction: "watch" | "caution" = "watch",
): SignalCall {
  return {
    id: `${token.address}-${kind}`,
    tokenAddress: token.address,
    symbol: token.symbol,
    name: token.name,
    imageUrl: token.imageUrl,

    kind,
    direction,
    label,

    signalScore: Math.round(
      clamp(score, 0, 100),
    ),

    confidence: confidenceFor(token),

    detectedAt: Date.now(),

    priceUsd: token.priceUsd,
    priceChange5m: token.priceChange.m5,
    priceChange1h: token.priceChange.h1,

    liquidityUsd: token.liquidityUsd,
    marketCap:
      token.marketCap ?? token.fdv,

    volume5m: token.volume.m5,
    volume1h: token.volume.h1,

    buys5m: token.txns.m5.buys,
    sells5m: token.txns.m5.sells,
    buyShare5m: getBuyShare(token),
    volumeSpike5m: token.volumeSpike5m,
    pairAgeMinutes: token.pairAgeMinutes,

    activityScore: token.activityScore,

    reasons,
    caution,
    dexUrl: token.dexUrl,
  };
}

export function generateSignals(
  tokens: TerminalToken[],
): SignalCall[] {
  const calls: SignalCall[] = [];

  for (const token of tokens) {
    const buyShare = getBuyShare(token);
    const spike = token.volumeSpike5m ?? 0;
    const change5m = token.priceChange.m5 ?? 0;
    const change1h = token.priceChange.h1 ?? 0;
    const ageMinutes =
      token.pairAgeMinutes ??
      Number.POSITIVE_INFINITY;

    const txns5m =
      token.txns.m5.buys +
      token.txns.m5.sells;

    const base = baseScore(token);

    if (
      ageMinutes <= 360 &&
      token.liquidityUsd >= 20_000 &&
      token.volume.m5 >= 8_000 &&
      spike >= 1.5 &&
      (buyShare ?? 0) >= 0.56 &&
      change5m > -5 &&
      change5m <= 22
    ) {
      const reasons = [
        `Pair age is ${Math.max(
          1,
          Math.round(ageMinutes),
        )} minutes.`,
        `5m volume is $${Math.round(
          token.volume.m5,
        ).toLocaleString("en-US")}.`,
        `5m activity is ${spike.toFixed(
          2,
        )}x the 1h average 5m pace.`,
        `Buy share is ${Math.round(
          (buyShare ?? 0) * 100,
        )}%.`,
      ];

      const caution: string[] = [];

      if (token.liquidityUsd < 50_000) {
        caution.push(
          "Liquidity is still relatively thin.",
        );
      }

      if (change5m >= 15) {
        caution.push(
          "Price has already moved quickly in the last 5 minutes.",
        );
      }

      calls.push(
        buildCall(
          token,
          "early-momentum",
          "Early Momentum Watch",
          base + 8,
          reasons,
          caution,
        ),
      );

      continue;
    }

    if (
      token.liquidityUsd >= 50_000 &&
      token.volume.m5 >= 15_000 &&
      spike >= 1.2 &&
      (buyShare ?? 0) >= 0.58 &&
      txns5m >= 20 &&
      change5m > 0 &&
      change5m <= 18
    ) {
      calls.push(
        buildCall(
          token,
          "momentum",
          "Momentum Watch",
          base + 5,
          [
            `Liquidity is $${Math.round(
              token.liquidityUsd,
            ).toLocaleString("en-US")}.`,
            `Buy share is ${Math.round(
              (buyShare ?? 0) * 100,
            )}% across ${txns5m} recent 5m transactions.`,
            `5m price change is ${change5m.toFixed(
              1,
            )}%.`,
          ],
          change1h >= 40
            ? [
                "The 1h move is already extended; continuation is less certain.",
              ]
            : [],
        ),
      );

      continue;
    }

    if (
      spike >= 2.5 &&
      token.volume.m5 >= 10_000 &&
      token.liquidityUsd >= 15_000 &&
      txns5m >= 15
    ) {
      calls.push(
        buildCall(
          token,
          "volume-spike",
          "Volume Spike Watch",
          base + 2,
          [
            `5m volume is ${spike.toFixed(
              2,
            )}x the recent 1h average pace.`,
            `${txns5m} transactions were observed in the 5m window.`,
            `Liquidity is $${Math.round(
              token.liquidityUsd,
            ).toLocaleString("en-US")}.`,
          ],
          (buyShare ?? 0.5) < 0.5
            ? [
                "The spike is not currently dominated by buys.",
              ]
            : [],
        ),
      );

      continue;
    }

    if (
      change5m >= 25 &&
      spike >= 2 &&
      token.volume.m5 >= 10_000
    ) {
      calls.push(
        buildCall(
          token,
          "overheated",
          "Overheated Move",
          clamp(base - 4, 0, 100),
          [
            `Price is up ${change5m.toFixed(
              1,
            )}% in 5 minutes.`,
            `Volume is ${spike.toFixed(
              2,
            )}x the recent average pace.`,
          ],
          [
            "Rapid short-window appreciation can reverse sharply.",
            "This setup is flagged for caution rather than continuation.",
          ],
          "caution",
        ),
      );

      continue;
    }

    if (
      token.activityScore >= 60 &&
      token.liquidityUsd < 10_000
    ) {
      calls.push(
        buildCall(
          token,
          "thin-liquidity",
          "Thin Liquidity Activity",
          clamp(base - 10, 0, 100),
          [
            `Activity score is ${token.activityScore}.`,
            `5m volume is $${Math.round(
              token.volume.m5,
            ).toLocaleString("en-US")}.`,
          ],
          [
            `Liquidity is only $${Math.round(
              token.liquidityUsd,
            ).toLocaleString("en-US")}.`,
            "Thin liquidity can amplify slippage and abrupt price moves.",
          ],
          "caution",
        ),
      );
    }
  }

  return calls.sort((a, b) => {
    if (a.direction !== b.direction) {
      return a.direction === "watch" ? -1 : 1;
    }

    return b.signalScore - a.signalScore;
  });
}
'@

Write-Utf8NoBom "src/lib/signal-engine.ts" $engine

# =========================================================
# 3. SIGNAL CALLS PAGE
# =========================================================

$page = @'
"use client";

import Link from "next/link";
import {
  Bell,
  BellRing,
  ExternalLink,
  RefreshCw,
  Search,
  ShieldAlert,
  Signal,
  SlidersHorizontal,
  Sparkles,
  Zap,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import {
  generateSignals,
} from "@/lib/signal-engine";
import type {
  SignalCall,
  SignalSettings,
} from "@/lib/signal-types";
import type {
  TerminalResponse,
} from "@/lib/terminal-types";

const SETTINGS_KEY =
  "memescope-signal-settings";

const SEEN_KEY =
  "memescope-seen-signals-v1";

const DEFAULT_SETTINGS: SignalSettings = {
  minSignalScore: 55,
  minLiquidityUsd: 20_000,
  maxPairAgeHours: 72,
};

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

  if (value >= 1) {
    return `$${value.toFixed(2)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function percent(value: number | null) {
  if (value === null) return "—";

  return `${value > 0 ? "+" : ""}${value.toFixed(
    2,
  )}%`;
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

function scoreTone(
  signal: SignalCall,
) {
  if (signal.direction === "caution") {
    return "text-amber-300";
  }

  if (signal.signalScore >= 75) {
    return "text-emerald-300";
  }

  return "text-cyan-300";
}

function SignalCard({
  signal,
}: {
  signal: SignalCall;
}) {
  return (
    <article
      className={`rounded-2xl border p-5 ${
        signal.direction === "caution"
          ? "border-amber-400/15 bg-amber-400/[0.025]"
          : "border-white/10 bg-white/[0.025]"
      }`}
    >
      <div className="flex items-start justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          {signal.imageUrl ? (
            <img
              src={signal.imageUrl}
              alt=""
              className="h-11 w-11 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-white/10 bg-black/20 text-xs font-bold text-zinc-500">
              {signal.symbol.slice(0, 2)}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="text-lg font-semibold text-white">
                {signal.symbol}
              </h3>

              <span
                className={`rounded-full border px-2 py-1 text-[9px] font-semibold uppercase tracking-[0.12em] ${
                  signal.direction === "caution"
                    ? "border-amber-400/20 bg-amber-400/10 text-amber-300"
                    : "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                }`}
              >
                {signal.label}
              </span>
            </div>

            <div className="mt-1 truncate text-xs text-zinc-600">
              {signal.name}
            </div>
          </div>
        </div>

        <div className="text-right">
          <div
            className={`text-3xl font-semibold ${scoreTone(
              signal,
            )}`}
          >
            {signal.signalScore}
          </div>

          <div className="text-[9px] uppercase tracking-[0.15em] text-zinc-700">
            signal score
          </div>
        </div>
      </div>

      <div className="mt-5 grid grid-cols-3 gap-2 lg:grid-cols-6">
        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Price
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {money(signal.priceUsd)}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            5m
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {percent(
              signal.priceChange5m,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Age
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {age(
              signal.pairAgeMinutes,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Liquidity
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {money(
              signal.liquidityUsd,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Vol 5m
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {money(
              signal.volume5m,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Buy share
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {signal.buyShare5m !== null
              ? `${Math.round(
                  signal.buyShare5m * 100,
                )}%`
              : "—"}
          </div>
        </div>
      </div>

      <div className="mt-5 grid gap-4 lg:grid-cols-2">
        <div>
          <div className="mb-2 text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Why it was called
          </div>

          <div className="space-y-2">
            {signal.reasons.map(
              (reason) => (
                <div
                  key={reason}
                  className="flex gap-2 text-xs leading-5 text-zinc-300"
                >
                  <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-emerald-300" />
                  {reason}
                </div>
              ),
            )}
          </div>
        </div>

        <div>
          <div className="mb-2 text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Caution
          </div>

          {signal.caution.length > 0 ? (
            <div className="space-y-2">
              {signal.caution.map(
                (item) => (
                  <div
                    key={item}
                    className="flex gap-2 text-xs leading-5 text-amber-100/70"
                  >
                    <ShieldAlert className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-300" />
                    {item}
                  </div>
                ),
              )}
            </div>
          ) : (
            <div className="text-xs text-zinc-600">
              No additional caution flag from
              the current market snapshot.
            </div>
          )}
        </div>
      </div>

      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-white/5 pt-4">
        <div className="flex flex-wrap gap-2 text-[10px] text-zinc-600">
          <span>
            Confidence:{" "}
            <strong className="text-zinc-300">
              {signal.confidence}
            </strong>
          </span>

          <span>•</span>

          <span>
            Activity:{" "}
            <strong className="text-zinc-300">
              {signal.activityScore}
            </strong>
          </span>

          <span>•</span>

          <span>
            Spike:{" "}
            <strong className="text-zinc-300">
              {signal.volumeSpike5m !== null
                ? `${signal.volumeSpike5m.toFixed(
                    2,
                  )}x`
                : "—"}
            </strong>
          </span>
        </div>

        <div className="flex gap-2">
          <Link
            href={`/token/${signal.tokenAddress}`}
            className="rounded-lg border border-emerald-400/15 bg-emerald-400/[0.06] px-3 py-2 text-[11px] text-emerald-300"
          >
            Analyze risk
          </Link>

          {signal.dexUrl && (
            <a
              href={signal.dexUrl}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-1.5 rounded-lg border border-white/10 px-3 py-2 text-[11px] text-zinc-400 hover:text-white"
            >
              Dex
              <ExternalLink className="h-3 w-3" />
            </a>
          )}
        </div>
      </div>
    </article>
  );
}

export default function SignalsPage() {
  const [data, setData] =
    useState<TerminalResponse | null>(
      null,
    );

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  const [query, setQuery] =
    useState("");

  const [settings, setSettings] =
    useState<SignalSettings>(
      DEFAULT_SETTINGS,
    );

  const [browserAlerts, setBrowserAlerts] =
    useState(false);

  const initialLoadRef =
    useRef(true);

  useEffect(() => {
    const raw =
      localStorage.getItem(
        SETTINGS_KEY,
      );

    if (!raw) return;

    try {
      setSettings({
        ...DEFAULT_SETTINGS,
        ...(JSON.parse(
          raw,
        ) as Partial<SignalSettings>),
      });
    } catch {
      // Ignore malformed saved settings.
    }
  }, []);

  async function load(
    silent = false,
  ) {
    if (!silent) {
      setLoading(true);
    }

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
            : "Signal feed failed.",
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
          : "Signal feed failed.",
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

  const allSignals = useMemo(() => {
    return generateSignals(
      data?.tokens ?? [],
    );
  }, [data]);

  const visibleSignals = useMemo(() => {
    const needle =
      query.trim().toLowerCase();

    return allSignals.filter(
      (signal) => {
        if (
          signal.signalScore <
          settings.minSignalScore
        ) {
          return false;
        }

        if (
          signal.liquidityUsd <
          settings.minLiquidityUsd
        ) {
          return false;
        }

        if (
          settings.maxPairAgeHours > 0 &&
          signal.pairAgeMinutes !==
            null &&
          signal.pairAgeMinutes >
            settings.maxPairAgeHours *
              60
        ) {
          return false;
        }

        if (
          needle &&
          !signal.symbol
            .toLowerCase()
            .includes(needle) &&
          !signal.name
            .toLowerCase()
            .includes(needle) &&
          !signal.tokenAddress
            .toLowerCase()
            .includes(needle)
        ) {
          return false;
        }

        return true;
      },
    );
  }, [
    allSignals,
    query,
    settings,
  ]);

  useEffect(() => {
    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify(settings),
    );
  }, [settings]);

  useEffect(() => {
    if (
      initialLoadRef.current
    ) {
      initialLoadRef.current = false;

      localStorage.setItem(
        SEEN_KEY,
        JSON.stringify(
          visibleSignals.map(
            (signal) => signal.id,
          ),
        ),
      );

      return;
    }

    if (
      !browserAlerts ||
      typeof Notification ===
        "undefined" ||
      Notification.permission !==
        "granted"
    ) {
      return;
    }

    let seen: string[] = [];

    try {
      seen = JSON.parse(
        localStorage.getItem(
          SEEN_KEY,
        ) ?? "[]",
      ) as string[];
    } catch {
      seen = [];
    }

    const seenSet = new Set(seen);

    const fresh = visibleSignals.filter(
      (signal) =>
        signal.direction === "watch" &&
        !seenSet.has(signal.id),
    );

    for (const signal of fresh.slice(
      0,
      3,
    )) {
      new Notification(
        `MemeScope · ${signal.label}`,
        {
          body: `${signal.symbol} · score ${signal.signalScore} · liq ${money(
            signal.liquidityUsd,
          )}`,
        },
      );
    }

    localStorage.setItem(
      SEEN_KEY,
      JSON.stringify(
        visibleSignals
          .map(
            (signal) => signal.id,
          )
          .slice(0, 200),
      ),
    );
  }, [
    visibleSignals,
    browserAlerts,
  ]);

  async function enableAlerts() {
    if (
      typeof Notification ===
      "undefined"
    ) {
      setError(
        "Browser notifications are not supported here.",
      );
      return;
    }

    const permission =
      await Notification.requestPermission();

    setBrowserAlerts(
      permission === "granted",
    );
  }

  const watchSignals =
    visibleSignals.filter(
      (signal) =>
        signal.direction === "watch",
    );

  const cautionSignals =
    visibleSignals.filter(
      (signal) =>
        signal.direction === "caution",
    );

  return (
    <main className="mx-auto w-full max-w-[1600px] px-4 py-6 lg:px-7">
      <section className="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.2em] text-emerald-300">
            <Signal className="h-3.5 w-3.5" />
            MemeScope Signal Engine
          </div>

          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
            Signal Calls
          </h1>

          <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
            Evidence-based market setups from
            liquidity, transaction flow, volume
            acceleration, pair age and short-window
            momentum. These are market alerts, not
            guaranteed outcomes or personalized
            investment recommendations.
          </p>
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            onClick={enableAlerts}
            className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
              browserAlerts
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : "border-white/10 text-zinc-400 hover:bg-white/5"
            }`}
          >
            {browserAlerts ? (
              <BellRing className="h-3.5 w-3.5" />
            ) : (
              <Bell className="h-3.5 w-3.5" />
            )}
            {browserAlerts
              ? "Browser alerts on"
              : "Enable alerts"}
          </button>

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
        </div>
      </section>

      <section className="mb-5 grid grid-cols-2 gap-2 lg:grid-cols-4">
        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Active watch calls
          </div>
          <div className="mt-1 text-2xl font-semibold text-emerald-300">
            {watchSignals.length}
          </div>
        </div>

        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Caution flags
          </div>
          <div className="mt-1 text-2xl font-semibold text-amber-300">
            {cautionSignals.length}
          </div>
        </div>

        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Highest score
          </div>
          <div className="mt-1 text-2xl font-semibold text-white">
            {visibleSignals[0]?.signalScore ??
              "—"}
          </div>
        </div>

        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Refresh
          </div>
          <div className="mt-1 text-2xl font-semibold text-white">
            15s
          </div>
        </div>
      </section>

      <section className="mb-5 rounded-2xl border border-white/10 bg-white/[0.02] p-3">
        <div className="grid gap-3 xl:grid-cols-[1fr_auto_auto_auto]">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />

            <input
              value={query}
              onChange={(event) =>
                setQuery(
                  event.target.value,
                )
              }
              placeholder="Search signal by token"
              className="w-full rounded-xl border border-white/10 bg-black/25 py-3 pl-10 pr-3 text-sm text-white outline-none placeholder:text-zinc-700 focus:border-emerald-400/30"
            />
          </div>

          <label className="flex items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-3">
            <SlidersHorizontal className="h-3.5 w-3.5 text-zinc-600" />
            <span className="text-[10px] text-zinc-600">
              Score
            </span>
            <select
              value={settings.minSignalScore}
              onChange={(event) =>
                setSettings(
                  (current) => ({
                    ...current,
                    minSignalScore:
                      Number(
                        event.target
                          .value,
                      ),
                  }),
                )
              }
              className="bg-transparent py-3 text-xs text-zinc-300 outline-none"
            >
              <option value={45}>
                ≥ 45
              </option>
              <option value={55}>
                ≥ 55
              </option>
              <option value={65}>
                ≥ 65
              </option>
              <option value={75}>
                ≥ 75
              </option>
            </select>
          </label>

          <label className="flex items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-3">
            <span className="text-[10px] text-zinc-600">
              Liq
            </span>
            <select
              value={settings.minLiquidityUsd}
              onChange={(event) =>
                setSettings(
                  (current) => ({
                    ...current,
                    minLiquidityUsd:
                      Number(
                        event.target
                          .value,
                      ),
                  }),
                )
              }
              className="bg-transparent py-3 text-xs text-zinc-300 outline-none"
            >
              <option value={0}>
                Any
              </option>
              <option value={5000}>
                ≥ $5K
              </option>
              <option value={20000}>
                ≥ $20K
              </option>
              <option value={50000}>
                ≥ $50K
              </option>
              <option value={100000}>
                ≥ $100K
              </option>
            </select>
          </label>

          <label className="flex items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-3">
            <span className="text-[10px] text-zinc-600">
              Age
            </span>
            <select
              value={settings.maxPairAgeHours}
              onChange={(event) =>
                setSettings(
                  (current) => ({
                    ...current,
                    maxPairAgeHours:
                      Number(
                        event.target
                          .value,
                      ),
                  }),
                )
              }
              className="bg-transparent py-3 text-xs text-zinc-300 outline-none"
            >
              <option value={0}>
                Any
              </option>
              <option value={6}>
                ≤ 6h
              </option>
              <option value={24}>
                ≤ 24h
              </option>
              <option value={72}>
                ≤ 3d
              </option>
              <option value={168}>
                ≤ 7d
              </option>
            </select>
          </label>
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
          Building signal feed…
        </div>
      ) : (
        <div className="space-y-8">
          <section>
            <div className="mb-3 flex items-end justify-between gap-3">
              <div>
                <div className="flex items-center gap-2">
                  <Zap className="h-4 w-4 text-emerald-300" />
                  <h2 className="text-lg font-semibold text-white">
                    Market Calls
                  </h2>
                </div>

                <p className="mt-1 text-xs text-zinc-600">
                  Current setups meeting your
                  minimum filters.
                </p>
              </div>

              <span className="text-xs text-zinc-700">
                {watchSignals.length} calls
              </span>
            </div>

            {watchSignals.length > 0 ? (
              <div className="grid gap-4 2xl:grid-cols-2">
                {watchSignals.map(
                  (signal) => (
                    <SignalCard
                      key={signal.id}
                      signal={signal}
                    />
                  ),
                )}
              </div>
            ) : (
              <div className="rounded-2xl border border-dashed border-white/10 p-10 text-center">
                <Sparkles className="mx-auto h-6 w-6 text-zinc-700" />

                <p className="mt-3 text-sm text-zinc-600">
                  No current market setup meets the
                  selected thresholds.
                </p>
              </div>
            )}
          </section>

          {cautionSignals.length > 0 && (
            <section>
              <div className="mb-3 flex items-center gap-2">
                <ShieldAlert className="h-4 w-4 text-amber-300" />
                <h2 className="text-lg font-semibold text-white">
                  Caution Calls
                </h2>
              </div>

              <div className="grid gap-4 2xl:grid-cols-2">
                {cautionSignals.map(
                  (signal) => (
                    <SignalCard
                      key={signal.id}
                      signal={signal}
                    />
                  ),
                )}
              </div>
            </section>
          )}
        </div>
      )}

      <div className="mt-6 rounded-xl border border-white/5 bg-black/20 p-4 text-[11px] leading-5 text-zinc-600">
        Signal Score ranks how strongly a token
        matches the current rule set. It is not a
        probability of profit, price target, or
        guarantee. Always verify token risk,
        liquidity and on-chain context separately.
      </div>
    </main>
  );
}
'@

Write-Utf8NoBom "src/app/signals/page.tsx" $page

# =========================================================
# 4. BEST-EFFORT SIDEBAR LINK
# =========================================================

if (Test-Path -LiteralPath $sidebarPath) {
    $sidebar = [System.IO.File]::ReadAllText($sidebarPath)

    if ($sidebar -notmatch '["'']/signals["'']') {
        $patterns = @(
            '(?m)^(?<line>[ \t]*\{[^\r\n]*href:\s*["'']/discover["''][^\r\n]*label:\s*["'']Discover["''][^\r\n]*\},?\s*)$',
            '(?m)^(?<line>[ \t]*\{[^\r\n]*label:\s*["'']Discover["''][^\r\n]*href:\s*["'']/discover["''][^\r\n]*\},?\s*)$'
        )

        $match = $null

        foreach ($pattern in $patterns) {
            $candidate = [regex]::Match($sidebar, $pattern)
            if ($candidate.Success) {
                $match = $candidate
                break
            }
        }

        if ($null -ne $match -and $match.Success) {
            $discoverLine = $match.Groups["line"].Value
            $signalLine = $discoverLine.Replace("/discover", "/signals").Replace("Discover", "Signal Calls")

            $sidebar = $sidebar.Replace(
                $discoverLine,
                $discoverLine + [Environment]::NewLine + $signalLine
            )

            [System.IO.File]::WriteAllText(
                $sidebarPath,
                $sidebar,
                $utf8NoBom
            )

            Write-Host "Sidebar: Signal Calls ditambahkan." -ForegroundColor Green
        } else {
            Write-Host "Sidebar tidak dipatch otomatis (struktur berbeda)." -ForegroundColor Yellow
            Write-Host "Page tetap tersedia di /signals." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Sidebar: Signal Calls sudah ada." -ForegroundColor DarkGray
    }
}

# =========================================================
# 5. CLEAR NEXT CACHE
# =========================================================

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 11 Signal Calls berhasil dipasang" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Fitur:" -ForegroundColor Cyan
Write-Host " - Early Momentum Watch"
Write-Host " - Momentum Watch"
Write-Host " - Volume Spike Watch"
Write-Host " - Overheated Move caution"
Write-Host " - Thin Liquidity caution"
Write-Host " - Signal score 0-100"
Write-Host " - Evidence/reason list per call"
Write-Host " - Confidence from data completeness"
Write-Host " - Browser notifications for NEW watch calls"
Write-Host " - Score, liquidity and age filters"
Write-Host " - Analyze Risk shortcut"
Write-Host " - 15s refresh from Market Terminal"
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor Cyan
Write-Host "npm run dev" -ForegroundColor White
Write-Host ""
Write-Host "Buka:" -ForegroundColor Cyan
Write-Host "http://localhost:3000/signals" -ForegroundColor White
Write-Host ""
