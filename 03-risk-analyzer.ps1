$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not (Test-Path "package.json")) {
    throw "package.json tidak ditemukan. Jalankan dari folder memecoin-analyst."
}

if (-not (Test-Path "src/app/scanner/page.tsx")) {
    throw "Scanner Stage 02 tidak ditemukan."
}

Step "Membuat backup Stage 03"
$BackupDir = "backup-stage-03"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

if (Test-Path -LiteralPath "src/app/token/[address]/page.tsx") {
    Copy-Item -LiteralPath "src/app/token/[address]/page.tsx" -Destination "$BackupDir/token-page.tsx.bak" -Force
}
Copy-Item "src/app/scanner/page.tsx" "$BackupDir/scanner-page.tsx.bak" -Force

Step "Membuat tipe data risk analyzer"
@'
export type RiskSeverity = "good" | "info" | "warning" | "danger";

export type RiskFlag = {
  id: string;
  title: string;
  description: string;
  severity: RiskSeverity;
  points: number;
};

export type OwnerConcentration = {
  owner: string;
  amount: number;
  percentage: number;
};

export type SolanaRiskReport = {
  ok: boolean;
  tokenAddress: string;
  tokenProgram: string | null;
  tokenStandard: "SPL Token" | "Token-2022" | "Unknown";
  mintAuthority: string | null;
  freezeAuthority: string | null;
  mintAuthorityDisabled: boolean | null;
  freezeAuthorityDisabled: boolean | null;
  decimals: number | null;
  supply: number;
  top1Percentage: number;
  top5Percentage: number;
  top10Percentage: number;
  analyzedOwnerCount: number;
  topOwners: OwnerConcentration[];
  riskScore: number;
  riskLabel: "Low" | "Moderate" | "High";
  flags: RiskFlag[];
  market: {
    pairAddress: string | null;
    dexId: string | null;
    dexUrl: string | null;
    name: string | null;
    symbol: string | null;
    priceUsd: number;
    marketCap: number;
    fdv: number;
    liquidity: number;
    liquidityToMarketCap: number | null;
    volume5m: number;
    buys5m: number;
    sells5m: number;
    pairCreatedAt: number | null;
    pairAgeMinutes: number | null;
  };
  rpcSource: string;
  updatedAt: number;
  limitations: string[];
  error?: string;
};
'@ | Set-Content -Encoding UTF8 "src/lib/risk-types.ts"

Step "Membuat API Solana Risk Analyzer"
New-Item -ItemType Directory -Force -Path "src/app/api/risk/solana/[address]" | Out-Null

@'
import { NextRequest, NextResponse } from "next/server";
import type {
  OwnerConcentration,
  RiskFlag,
  SolanaRiskReport,
} from "@/lib/risk-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PUBLIC_RPC = "https://api.mainnet.solana.com";
const CACHE_MS = 15_000;

const TOKEN_PROGRAM = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
const TOKEN_2022_PROGRAM = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb";

const cache = new Map<
  string,
  { expiresAt: number; report: SolanaRiskReport }
>();

type Json = Record<string, any>;

function number(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

function shortProgram(program: string | null) {
  if (program === TOKEN_PROGRAM) return "SPL Token" as const;
  if (program === TOKEN_2022_PROGRAM) return "Token-2022" as const;
  return "Unknown" as const;
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
    const retryAfter = response.headers.get("retry-after");
    throw new Error(
      `Solana RPC ${response.status}${
        retryAfter ? ` — retry after ${retryAfter}s` : ""
      }`,
    );
  }

  const data = (await response.json()) as Json;

  if (data.error) {
    throw new Error(
      data.error.message || `RPC ${method} returned an error`,
    );
  }

  return data.result;
}

async function fetchDexPairs(address: string) {
  const direct = await fetch(
    `https://api.dexscreener.com/token-pairs/v1/solana/${encodeURIComponent(address)}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "MemeScope/0.3",
      },
      cache: "no-store",
    },
  );

  if (direct.ok) {
    const data = await direct.json();
    if (Array.isArray(data)) return data as Json[];
  }

  const fallback = await fetch(
    `https://api.dexscreener.com/latest/dex/search?q=${encodeURIComponent(address)}`,
    {
      headers: {
        Accept: "application/json",
        "User-Agent": "MemeScope/0.3",
      },
      cache: "no-store",
    },
  );

  if (!fallback.ok) return [];

  const data = (await fallback.json()) as Json;
  return Array.isArray(data.pairs)
    ? data.pairs.filter(
        (pair: Json) =>
          String(pair.chainId).toLowerCase() === "solana" &&
          pair.baseToken?.address === address,
      )
    : [];
}

function marketFromPairs(pairs: Json[], now: number) {
  const best =
    [...pairs].sort(
      (a, b) =>
        number(b?.liquidity?.usd) - number(a?.liquidity?.usd),
    )[0] || null;

  if (!best) {
    return {
      pairAddress: null,
      dexId: null,
      dexUrl: null,
      name: null,
      symbol: null,
      priceUsd: 0,
      marketCap: 0,
      fdv: 0,
      liquidity: 0,
      liquidityToMarketCap: null,
      volume5m: 0,
      buys5m: 0,
      sells5m: 0,
      pairCreatedAt: null,
      pairAgeMinutes: null,
    };
  }

  const marketCap = number(best.marketCap ?? best.fdv);
  const liquidity = number(best?.liquidity?.usd);
  const createdAt =
    typeof best.pairCreatedAt === "number"
      ? best.pairCreatedAt
      : null;

  return {
    pairAddress: best.pairAddress || null,
    dexId: best.dexId || null,
    dexUrl: best.url || null,
    name: best.baseToken?.name || null,
    symbol: best.baseToken?.symbol || null,
    priceUsd: number(best.priceUsd),
    marketCap: number(best.marketCap),
    fdv: number(best.fdv),
    liquidity,
    liquidityToMarketCap:
      marketCap > 0 ? liquidity / marketCap : null,
    volume5m: number(best?.volume?.m5),
    buys5m: number(best?.txns?.m5?.buys),
    sells5m: number(best?.txns?.m5?.sells),
    pairCreatedAt: createdAt,
    pairAgeMinutes: createdAt
      ? Math.max(0, Math.floor((now - createdAt) / 60_000))
      : null,
  };
}

function buildRisk(
  input: {
    mintAuthorityDisabled: boolean | null;
    freezeAuthorityDisabled: boolean | null;
    top1: number;
    top10: number;
    market: ReturnType<typeof marketFromPairs>;
  },
) {
  const flags: RiskFlag[] = [];
  let score = 0;

  if (input.mintAuthorityDisabled === true) {
    flags.push({
      id: "mint-disabled",
      title: "Mint authority disabled",
      description:
        "No active mint authority was reported by the mint account.",
      severity: "good",
      points: 0,
    });
  } else if (input.mintAuthorityDisabled === false) {
    score += 25;
    flags.push({
      id: "mint-active",
      title: "Mint authority active",
      description:
        "The mint account still reports an authority capable of minting additional supply.",
      severity: "danger",
      points: 25,
    });
  } else {
    flags.push({
      id: "mint-unknown",
      title: "Mint authority unknown",
      description:
        "The RPC response could not be parsed well enough to verify mint authority.",
      severity: "warning",
      points: 0,
    });
  }

  if (input.freezeAuthorityDisabled === true) {
    flags.push({
      id: "freeze-disabled",
      title: "Freeze authority disabled",
      description:
        "No active freeze authority was reported by the mint account.",
      severity: "good",
      points: 0,
    });
  } else if (input.freezeAuthorityDisabled === false) {
    score += 20;
    flags.push({
      id: "freeze-active",
      title: "Freeze authority active",
      description:
        "The mint account still reports an authority that may freeze token accounts.",
      severity: "danger",
      points: 20,
    });
  } else {
    flags.push({
      id: "freeze-unknown",
      title: "Freeze authority unknown",
      description:
        "The RPC response could not be parsed well enough to verify freeze authority.",
      severity: "warning",
      points: 0,
    });
  }

  if (input.top1 > 20) {
    score += 20;
    flags.push({
      id: "top1-high",
      title: "Very high largest-owner concentration",
      description: `Largest observed owner controls about ${input.top1.toFixed(1)}% of supply.`,
      severity: "danger",
      points: 20,
    });
  } else if (input.top1 > 10) {
    score += 10;
    flags.push({
      id: "top1-medium",
      title: "Elevated largest-owner concentration",
      description: `Largest observed owner controls about ${input.top1.toFixed(1)}% of supply.`,
      severity: "warning",
      points: 10,
    });
  } else {
    flags.push({
      id: "top1-ok",
      title: "Largest observed owner below 10%",
      description: `Largest observed owner is about ${input.top1.toFixed(1)}% of supply.`,
      severity: "good",
      points: 0,
    });
  }

  if (input.top10 > 60) {
    score += 20;
    flags.push({
      id: "top10-high",
      title: "Very concentrated observed ownership",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "danger",
      points: 20,
    });
  } else if (input.top10 > 40) {
    score += 12;
    flags.push({
      id: "top10-medium",
      title: "Concentrated observed ownership",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "warning",
      points: 12,
    });
  } else if (input.top10 > 25) {
    score += 6;
    flags.push({
      id: "top10-watch",
      title: "Ownership concentration worth checking",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "info",
      points: 6,
    });
  } else {
    flags.push({
      id: "top10-ok",
      title: "Observed ownership relatively distributed",
      description: `Top observed owners account for about ${input.top10.toFixed(1)}% of supply.`,
      severity: "good",
      points: 0,
    });
  }

  const liquidity = input.market.liquidity;
  const ratio = input.market.liquidityToMarketCap;

  if (liquidity > 0 && liquidity < 10_000) {
    score += 15;
    flags.push({
      id: "liquidity-low",
      title: "Low DEX liquidity",
      description: `Best observed pair has only about $${Math.round(liquidity).toLocaleString("en-US")} of liquidity.`,
      severity: "danger",
      points: 15,
    });
  } else if (liquidity > 0 && liquidity < 30_000) {
    score += 7;
    flags.push({
      id: "liquidity-medium",
      title: "Thin DEX liquidity",
      description: `Best observed pair has about $${Math.round(liquidity).toLocaleString("en-US")} of liquidity.`,
      severity: "warning",
      points: 7,
    });
  }

  if (ratio !== null && ratio < 0.05) {
    score += 15;
    flags.push({
      id: "liq-ratio-low",
      title: "Very low liquidity-to-market-cap ratio",
      description: `Liquidity is roughly ${(ratio * 100).toFixed(1)}% of market cap/FDV.`,
      severity: "danger",
      points: 15,
    });
  } else if (ratio !== null && ratio < 0.1) {
    score += 9;
    flags.push({
      id: "liq-ratio-watch",
      title: "Low liquidity-to-market-cap ratio",
      description: `Liquidity is roughly ${(ratio * 100).toFixed(1)}% of market cap/FDV.`,
      severity: "warning",
      points: 9,
    });
  }

  const buys = input.market.buys5m;
  const sells = input.market.sells5m;

  if (sells > 10 && sells > buys * 2) {
    score += 10;
    flags.push({
      id: "sell-pressure",
      title: "Heavy short-term sell pressure",
      description: `5m transactions show ${buys} buys versus ${sells} sells.`,
      severity: "warning",
      points: 10,
    });
  }

  const age = input.market.pairAgeMinutes;

  if (age !== null && age < 30) {
    score += 8;
    flags.push({
      id: "very-new-pair",
      title: "Very new trading pair",
      description: "The best observed pair is less than 30 minutes old.",
      severity: "warning",
      points: 8,
    });
  } else if (age !== null && age < 120) {
    score += 4;
    flags.push({
      id: "new-pair",
      title: "New trading pair",
      description: "The best observed pair is less than two hours old.",
      severity: "info",
      points: 4,
    });
  }

  const finalScore = Math.round(clamp(score));

  return {
    score: finalScore,
    label:
      finalScore >= 61
        ? ("High" as const)
        : finalScore >= 31
          ? ("Moderate" as const)
          : ("Low" as const),
    flags,
  };
}

function sumPct(
  owners: OwnerConcentration[],
  count: number,
) {
  return owners
    .slice(0, count)
    .reduce((sum, item) => sum + item.percentage, 0);
}

export async function GET(
  _request: NextRequest,
  context: { params: Promise<{ address: string }> },
) {
  const { address } = await context.params;

  if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address)) {
    return NextResponse.json(
      { ok: false, error: "Invalid Solana token address." },
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
    const [mintAccount, supplyResult, largestResult, dexPairs] =
      await Promise.all([
        rpc(
          rpcUrl,
          "getAccountInfo",
          [
            address,
            {
              encoding: "jsonParsed",
              commitment: "confirmed",
            },
          ],
          1,
        ),
        rpc(
          rpcUrl,
          "getTokenSupply",
          [address, { commitment: "confirmed" }],
          2,
        ),
        rpc(
          rpcUrl,
          "getTokenLargestAccounts",
          [address, { commitment: "confirmed" }],
          3,
        ),
        fetchDexPairs(address),
      ]);

    if (!mintAccount?.value) {
      throw new Error("Token mint account was not found.");
    }

    const mintValue = mintAccount.value as Json;
    const mintInfo = mintValue?.data?.parsed?.info as Json | undefined;

    const tokenProgram =
      typeof mintValue.owner === "string"
        ? mintValue.owner
        : null;

    const mintAuthority =
      mintInfo && "mintAuthority" in mintInfo
        ? mintInfo.mintAuthority ?? null
        : null;

    const freezeAuthority =
      mintInfo && "freezeAuthority" in mintInfo
        ? mintInfo.freezeAuthority ?? null
        : null;

    const mintAuthorityDisabled =
      mintInfo && "mintAuthority" in mintInfo
        ? mintAuthority === null
        : null;

    const freezeAuthorityDisabled =
      mintInfo && "freezeAuthority" in mintInfo
        ? freezeAuthority === null
        : null;

    const supply = number(
      supplyResult?.value?.uiAmountString ??
        supplyResult?.value?.uiAmount,
    );

    const largestAccounts = Array.isArray(largestResult?.value)
      ? largestResult.value.slice(0, 20)
      : [];

    const accountAddresses = largestAccounts
      .map((item: Json) => item.address)
      .filter(Boolean);

    let accountDetails: Json[] = [];

    if (accountAddresses.length > 0) {
      const multiple = await rpc(
        rpcUrl,
        "getMultipleAccounts",
        [
          accountAddresses,
          {
            encoding: "jsonParsed",
            commitment: "confirmed",
          },
        ],
        4,
      );

      accountDetails = Array.isArray(multiple?.value)
        ? multiple.value
        : [];
    }

    const ownerBalances = new Map<string, number>();

    largestAccounts.forEach((item: Json, index: number) => {
      const parsedOwner =
        accountDetails[index]?.data?.parsed?.info?.owner;
      const owner =
        typeof parsedOwner === "string"
          ? parsedOwner
          : item.address;

      const amount = number(
        item.uiAmountString ?? item.uiAmount,
      );

      ownerBalances.set(
        owner,
        (ownerBalances.get(owner) || 0) + amount,
      );
    });

    const topOwners: OwnerConcentration[] =
      Array.from(ownerBalances.entries())
        .map(([owner, amount]) => ({
          owner,
          amount,
          percentage:
            supply > 0 ? (amount / supply) * 100 : 0,
        }))
        .sort((a, b) => b.amount - a.amount);

    const top1 = sumPct(topOwners, 1);
    const top5 = sumPct(topOwners, 5);
    const top10 = sumPct(topOwners, 10);
    const market = marketFromPairs(dexPairs, now);

    const risk = buildRisk({
      mintAuthorityDisabled,
      freezeAuthorityDisabled,
      top1,
      top10,
      market,
    });

    const report: SolanaRiskReport = {
      ok: true,
      tokenAddress: address,
      tokenProgram,
      tokenStandard: shortProgram(tokenProgram),
      mintAuthority,
      freezeAuthority,
      mintAuthorityDisabled,
      freezeAuthorityDisabled,
      decimals:
        typeof supplyResult?.value?.decimals === "number"
          ? supplyResult.value.decimals
          : null,
      supply,
      top1Percentage: top1,
      top5Percentage: top5,
      top10Percentage: top10,
      analyzedOwnerCount: topOwners.length,
      topOwners: topOwners.slice(0, 10),
      riskScore: risk.score,
      riskLabel: risk.label,
      flags: risk.flags,
      market,
      rpcSource: customRpc
        ? "Custom Solana RPC"
        : "Solana public RPC",
      updatedAt: now,
      limitations: [
        "Largest-account concentration is derived from the 20 largest SPL token accounts returned by RPC and aggregated by parsed owner.",
        "DEX/AMM vaults, bonding-curve accounts, exchanges or program-owned token accounts can appear in concentration figures and should not automatically be interpreted as one human whale.",
        "LP lock/burn status, deployer history, bundled launches and sniper-wallet attribution are not claimed in this stage.",
        customRpc
          ? "Custom RPC is configured."
          : "The public Solana RPC is suitable for development but is rate-limited and is not intended for production traffic.",
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
            : "Risk analysis failed.",
      },
      {
        status: 502,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }
}
'@ | Set-Content -Encoding UTF8 -LiteralPath "src/app/api/risk/solana/[address]/route.ts"

Step "Membuat halaman Analyze live"
New-Item -ItemType Directory -Force -Path "src/app/token/[address]" | Out-Null

@'
"use client";

import { AppShell } from "@/components/app-shell";
import type {
  RiskFlag,
  RiskSeverity,
  SolanaRiskReport,
} from "@/lib/risk-types";
import {
  AlertTriangle,
  ArrowLeft,
  ArrowUpRight,
  CheckCircle2,
  CircleHelp,
  Copy,
  ExternalLink,
  RefreshCw,
  ShieldAlert,
  ShieldCheck,
  Users,
} from "lucide-react";
import Link from "next/link";
import { useParams } from "next/navigation";
import {
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";

function money(value: number) {
  if (!Number.isFinite(value)) return "$0";
  if (value >= 1_000_000_000)
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000)
    return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000)
    return `$${(value / 1_000).toFixed(1)}K`;
  if (value >= 1)
    return `$${value.toLocaleString("en-US", {
      maximumFractionDigits: 2,
    })}`;
  return `$${value.toPrecision(5)}`;
}

function compact(value: number) {
  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value);
}

function short(address: string | null) {
  if (!address) return "Disabled";
  if (address.length < 14) return address;
  return `${address.slice(0, 6)}…${address.slice(-6)}`;
}

function age(minutes: number | null) {
  if (minutes === null) return "—";
  if (minutes < 60) return `${minutes}m`;
  if (minutes < 1440)
    return `${Math.floor(minutes / 60)}h`;
  return `${Math.floor(minutes / 1440)}d`;
}

function severityClasses(severity: RiskSeverity) {
  if (severity === "good")
    return "border-emerald-400/15 bg-emerald-400/5 text-emerald-200";
  if (severity === "danger")
    return "border-rose-400/15 bg-rose-400/5 text-rose-200";
  if (severity === "warning")
    return "border-amber-400/15 bg-amber-400/5 text-amber-200";
  return "border-sky-400/15 bg-sky-400/5 text-sky-200";
}

function FlagIcon({ severity }: { severity: RiskSeverity }) {
  if (severity === "good")
    return <CheckCircle2 className="h-4 w-4" />;
  if (severity === "danger")
    return <ShieldAlert className="h-4 w-4" />;
  if (severity === "warning")
    return <AlertTriangle className="h-4 w-4" />;
  return <CircleHelp className="h-4 w-4" />;
}

function AuthorityCard({
  label,
  authority,
  disabled,
}: {
  label: string;
  authority: string | null;
  disabled: boolean | null;
}) {
  return (
    <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
      <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">
        {label}
      </div>
      <div className="mt-3 flex items-center gap-2">
        {disabled === true ? (
          <CheckCircle2 className="h-4 w-4 text-emerald-300" />
        ) : disabled === false ? (
          <AlertTriangle className="h-4 w-4 text-rose-300" />
        ) : (
          <CircleHelp className="h-4 w-4 text-zinc-500" />
        )}
        <span
          className={
            disabled === true
              ? "font-medium text-emerald-300"
              : disabled === false
                ? "font-medium text-rose-300"
                : "font-medium text-zinc-400"
          }
        >
          {disabled === true
            ? "Disabled"
            : disabled === false
              ? "Active"
              : "Unknown"}
        </span>
      </div>
      {authority ? (
        <div className="mt-2 font-mono text-xs text-zinc-600">
          {short(authority)}
        </div>
      ) : null}
    </div>
  );
}

export default function TokenRiskPage() {
  const params = useParams<{ address: string }>();
  const address = params.address;

  const [report, setReport] =
    useState<SolanaRiskReport | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState("");

  const load = useCallback(
    async (manual = false) => {
      manual ? setRefreshing(true) : setLoading(true);

      try {
        const response = await fetch(
          `/api/risk/solana/${encodeURIComponent(address)}`,
          { cache: "no-store" },
        );
        const data = await response.json();

        if (!response.ok || !data.ok) {
          throw new Error(
            data.error || "Risk analysis failed.",
          );
        }

        setReport(data as SolanaRiskReport);
        setError("");
      } catch (err) {
        setError(
          err instanceof Error
            ? err.message
            : "Risk analysis failed.",
        );
      } finally {
        setLoading(false);
        setRefreshing(false);
      }
    },
    [address],
  );

  useEffect(() => {
    load();
    const timer = window.setInterval(
      () => load(false),
      15_000,
    );
    return () => window.clearInterval(timer);
  }, [load]);

  const dangerousFlags = useMemo(
    () =>
      report?.flags.filter(
        (flag) =>
          flag.severity === "danger" ||
          flag.severity === "warning",
      ).length || 0,
    [report],
  );

  async function copyAddress() {
    await navigator.clipboard.writeText(address);
  }

  if (loading && !report) {
    return (
      <AppShell>
        <div className="grid min-h-[70vh] place-items-center">
          <div className="text-center">
            <RefreshCw className="mx-auto h-6 w-6 animate-spin text-emerald-300" />
            <div className="mt-3 text-sm text-zinc-500">
              Reading Solana mint and holder data…
            </div>
          </div>
        </div>
      </AppShell>
    );
  }

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <Link
          href="/scanner"
          className="mb-4 inline-flex items-center gap-2 text-sm text-zinc-500 hover:text-white"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to scanner
        </Link>

        <div className="flex flex-col gap-5 xl:flex-row xl:items-end xl:justify-between">
          <div className="min-w-0">
            <div className="text-sm text-emerald-300">
              Solana Risk Analyzer
            </div>
            <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
              {report?.market.name || "Token"}{" "}
              {report?.market.symbol ? (
                <span className="text-zinc-600">
                  ${report.market.symbol}
                </span>
              ) : null}
            </h1>

            <button
              onClick={copyAddress}
              className="mt-2 inline-flex max-w-full items-center gap-2 font-mono text-xs text-zinc-600 hover:text-zinc-300"
            >
              <span className="truncate">{address}</span>
              <Copy className="h-3.5 w-3.5 shrink-0" />
            </button>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            {report?.market.dexUrl ? (
              <a
                href={report.market.dexUrl}
                target="_blank"
                rel="noreferrer"
                className="inline-flex h-10 items-center gap-2 rounded-xl border border-white/8 px-3 text-sm text-zinc-300 hover:bg-white/5"
              >
                DEX Screener
                <ExternalLink className="h-4 w-4" />
              </a>
            ) : null}

            <button
              onClick={() => load(true)}
              disabled={refreshing}
              className="inline-flex h-10 items-center gap-2 rounded-xl border border-white/8 px-3 text-sm text-zinc-300 hover:bg-white/5 disabled:opacity-50"
            >
              <RefreshCw
                className={`h-4 w-4 ${
                  refreshing ? "animate-spin" : ""
                }`}
              />
              Refresh
            </button>
          </div>
        </div>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        {error ? (
          <div className="rounded-2xl border border-rose-400/20 bg-rose-400/5 p-4 text-sm text-rose-200">
            {error}
          </div>
        ) : null}

        {report ? (
          <>
            <section className="grid gap-3 lg:grid-cols-[1.2fr_.8fr_.8fr_.8fr]">
              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">
                  On-chain Risk
                </div>
                <div className="mt-3 flex items-end gap-3">
                  <div
                    className={`text-5xl font-semibold tracking-tight ${
                      report.riskLabel === "High"
                        ? "text-rose-300"
                        : report.riskLabel === "Moderate"
                          ? "text-amber-300"
                          : "text-emerald-300"
                    }`}
                  >
                    {report.riskScore}
                  </div>
                  <div className="pb-1 text-sm text-zinc-500">
                    / 100 · {report.riskLabel} risk
                  </div>
                </div>
                <div className="mt-4 h-2 overflow-hidden rounded-full bg-white/5">
                  <div
                    className={`h-full rounded-full ${
                      report.riskLabel === "High"
                        ? "bg-rose-300"
                        : report.riskLabel === "Moderate"
                          ? "bg-amber-300"
                          : "bg-emerald-300"
                    }`}
                    style={{
                      width: `${Math.max(
                        2,
                        report.riskScore,
                      )}%`,
                    }}
                  />
                </div>
                <div className="mt-3 text-xs text-zinc-600">
                  {dangerousFlags} current warning/risk flag(s)
                </div>
              </div>

              <AuthorityCard
                label="Mint Authority"
                authority={report.mintAuthority}
                disabled={report.mintAuthorityDisabled}
              />
              <AuthorityCard
                label="Freeze Authority"
                authority={report.freezeAuthority}
                disabled={report.freezeAuthorityDisabled}
              />

              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
                <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">
                  Token Program
                </div>
                <div className="mt-3 font-medium text-white">
                  {report.tokenStandard}
                </div>
                <div className="mt-2 text-xs text-zinc-600">
                  {report.decimals ?? "—"} decimals
                </div>
              </div>
            </section>

            <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
              {[
                [
                  "Price",
                  money(report.market.priceUsd),
                ],
                [
                  "Market Cap",
                  money(
                    report.market.marketCap ||
                      report.market.fdv,
                  ),
                ],
                [
                  "Liquidity",
                  money(report.market.liquidity),
                ],
                [
                  "5M Volume",
                  money(report.market.volume5m),
                ],
                [
                  "Pair Age",
                  age(report.market.pairAgeMinutes),
                ],
              ].map(([label, value]) => (
                <div
                  key={label}
                  className="rounded-2xl border border-white/8 bg-white/[0.025] p-4"
                >
                  <div className="text-xs uppercase tracking-[0.1em] text-zinc-600">
                    {label}
                  </div>
                  <div className="mt-2 text-xl font-medium text-white">
                    {value}
                  </div>
                </div>
              ))}
            </section>

            <section className="grid gap-4 xl:grid-cols-[.85fr_1.15fr]">
              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="flex items-center gap-2">
                  <Users className="h-4 w-4 text-zinc-400" />
                  <h2 className="font-medium text-white">
                    Observed concentration
                  </h2>
                </div>

                <p className="mt-2 text-xs leading-5 text-zinc-600">
                  Based on the largest SPL token accounts
                  returned by Solana RPC, aggregated by parsed
                  token-account owner.
                </p>

                <div className="mt-5 grid grid-cols-3 gap-3">
                  {[
                    ["Top 1", report.top1Percentage],
                    ["Top 5", report.top5Percentage],
                    ["Top 10", report.top10Percentage],
                  ].map(([label, value]) => (
                    <div
                      key={String(label)}
                      className="rounded-xl border border-white/8 bg-black/20 p-3"
                    >
                      <div className="text-xs text-zinc-600">
                        {label}
                      </div>
                      <div className="mt-1 text-lg font-medium text-white">
                        {(value as number).toFixed(1)}%
                      </div>
                    </div>
                  ))}
                </div>

                <div className="mt-5 space-y-2">
                  {report.topOwners.slice(0, 5).map(
                    (owner, index) => (
                      <div
                        key={owner.owner}
                        className="flex items-center justify-between gap-3 rounded-xl border border-white/5 bg-black/15 px-3 py-2.5"
                      >
                        <div className="min-w-0">
                          <div className="text-xs text-zinc-600">
                            #{index + 1}
                          </div>
                          <div className="truncate font-mono text-xs text-zinc-400">
                            {owner.owner}
                          </div>
                        </div>
                        <div className="shrink-0 text-sm font-medium text-zinc-200">
                          {owner.percentage.toFixed(2)}%
                        </div>
                      </div>
                    ),
                  )}
                </div>

                <div className="mt-4 text-xs text-zinc-600">
                  Supply: {compact(report.supply)}
                </div>
              </div>

              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="flex items-center gap-2">
                  <ShieldCheck className="h-4 w-4 text-zinc-400" />
                  <h2 className="font-medium text-white">
                    Risk checks
                  </h2>
                </div>

                <div className="mt-5 space-y-2.5">
                  {report.flags.map((flag: RiskFlag) => (
                    <div
                      key={flag.id}
                      className={`rounded-xl border p-3 ${severityClasses(
                        flag.severity,
                      )}`}
                    >
                      <div className="flex gap-3">
                        <div className="mt-0.5 shrink-0">
                          <FlagIcon
                            severity={flag.severity}
                          />
                        </div>
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-center justify-between gap-2">
                            <div className="text-sm font-medium">
                              {flag.title}
                            </div>
                            {flag.points > 0 ? (
                              <div className="text-xs opacity-60">
                                +{flag.points} risk
                              </div>
                            ) : null}
                          </div>
                          <p className="mt-1 text-xs leading-5 opacity-60">
                            {flag.description}
                          </p>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </section>

            <section className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
              <h2 className="font-medium text-white">
                Data quality & limitations
              </h2>
              <div className="mt-3 grid gap-2 md:grid-cols-2">
                {report.limitations.map((item) => (
                  <div
                    key={item}
                    className="rounded-xl border border-white/5 bg-black/15 p-3 text-xs leading-5 text-zinc-600"
                  >
                    {item}
                  </div>
                ))}
              </div>
              <div className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-xs text-zinc-700">
                <span>RPC: {report.rpcSource}</span>
                <span>
                  Updated:{" "}
                  {new Date(
                    report.updatedAt,
                  ).toLocaleTimeString()}
                </span>
              </div>
            </section>

            <div className="rounded-2xl border border-amber-400/15 bg-amber-400/5 p-4 text-xs leading-5 text-amber-100/60">
              This analyzer reports observable technical and
              market risk signals. A low score does not mean a
              token is safe, legitimate, or likely to rise in
              price.
            </div>
          </>
        ) : null}
      </div>
    </AppShell>
  );
}
'@ | Set-Content -Encoding UTF8 -LiteralPath "src/app/token/[address]/page.tsx"

Step "Menambahkan tombol Analyze ke live scanner"
$scannerPath = "src/app/scanner/page.tsx"
$scanner = Get-Content $scannerPath -Raw

$oldDexBlock = @'
                        <a
                          href={token.dexUrl}
                          target="_blank"
                          rel="noreferrer"
                          className="inline-flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
                        >
                          DEX
                          <ArrowUpRight className="h-3.5 w-3.5" />
                        </a>
'@

$newDexBlock = @'
                        <div className="flex items-center gap-3">
                          <a
                            href={`/token/${token.tokenAddress}`}
                            className="text-xs font-medium text-emerald-300 hover:text-emerald-200"
                          >
                            Analyze
                          </a>
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
'@

if ($scanner.Contains($oldDexBlock)) {
    $scanner = $scanner.Replace($oldDexBlock, $newDexBlock)
    Set-Content -Encoding UTF8 $scannerPath $scanner
    Write-Host "Scanner Analyze button ditambahkan." -ForegroundColor Green
} elseif ($scanner.Contains('href={`/token/${token.tokenAddress}`}')) {
    Write-Host "Scanner sudah memiliki Analyze button." -ForegroundColor Yellow
} else {
    Write-Host "WARNING: Tombol Analyze tidak bisa dipatch otomatis. Risk page tetap dibuat." -ForegroundColor Yellow
}

Step "Memperbarui .env.example"
$envExample = @'
# DEX Screener public endpoints do not require an API key.

# Stage 03:
# Leave blank during local development to use Solana's public mainnet RPC.
# For production / high traffic, use a dedicated RPC provider.
SOLANA_RPC_URL=

# Future integrations:
# SOLANA_WSS_URL=
# EVM_RPC_URL=
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_CHAT_ID=
# AI_API_KEY=
'@
Set-Content -Encoding UTF8 ".env.example" $envExample

Step "Membersihkan cache Next.js"
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue

Step "Type-check / lint"
npm run lint

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Stage 03 Risk Analyzer berhasil dipasang." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor White
Write-Host "  npm run dev" -ForegroundColor Yellow
Write-Host ""
Write-Host "Buka scanner:" -ForegroundColor White
Write-Host "  http://localhost:3000/scanner" -ForegroundColor Yellow
Write-Host ""
Write-Host "Klik Analyze pada token mana pun." -ForegroundColor White
Write-Host ""
Write-Host "Catatan: Stage ini boleh jalan tanpa SOLANA_RPC_URL," -ForegroundColor DarkGray
Write-Host "tetapi public RPC hanya cocok untuk development." -ForegroundColor DarkGray
