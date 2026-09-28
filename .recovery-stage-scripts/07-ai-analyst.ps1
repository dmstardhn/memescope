$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Step($Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

if (-not (Test-Path "package.json")) {
    throw "Jalankan script ini dari root folder memecoin-analyst."
}

if (-not (Test-Path -LiteralPath "src/app/api/risk/solana/[address]/route.ts")) {
    throw "Stage 03 Risk Analyzer belum terdeteksi."
}

Step "Backup Stage 07"
$BackupDir = "backup-stage-07"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
if (Test-Path "src/components/sidebar.tsx") {
    Copy-Item "src/components/sidebar.tsx" "$BackupDir/sidebar.tsx.bak" -Force
}
if (Test-Path ".env.example") {
    Copy-Item ".env.example" "$BackupDir/env.example.bak" -Force
}

Step "Membuat AI analysis types"
@'
export type AIAnalysisResponse = {
  ok: boolean;
  mode: "local" | "openai";
  model: string | null;
  tokenAddress: string;
  symbol: string | null;
  name: string | null;
  headline: string;
  summary: string;
  strengths: string[];
  risks: string[];
  watch: string[];
  verdict: string;
  generatedAt: number;
  disclaimer: string;
  error?: string;
};
'@ | Set-Content -Encoding UTF8 "src/lib/ai-types.ts"

Step "Membuat AI Analyst API"
New-Item -ItemType Directory -Force -Path "src/app/api/ai/analyze" | Out-Null

@'
import { NextRequest, NextResponse } from "next/server";
import type { AIAnalysisResponse } from "@/lib/ai-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RiskReport = {
  ok: boolean;
  tokenAddress: string;
  tokenStandard: string;
  mintAuthorityDisabled: boolean | null;
  freezeAuthorityDisabled: boolean | null;
  top1Percentage: number;
  top10Percentage: number;
  riskScore: number;
  riskLabel: string;
  flags: Array<{
    title: string;
    description: string;
    severity: string;
    points: number;
  }>;
  market: {
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
    pairAgeMinutes: number | null;
  };
};

function validAddress(address: string) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address);
}

function compactMoney(value: number) {
  if (!Number.isFinite(value)) return "$0";
  if (value >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(1)}K`;
  return `$${value.toFixed(2)}`;
}

function localAnalysis(report: RiskReport): AIAnalysisResponse {
  const strengths: string[] = [];
  const risks: string[] = [];
  const watch: string[] = [];
  const market = report.market;

  if (report.mintAuthorityDisabled === true) {
    strengths.push("Mint authority is disabled.");
  } else if (report.mintAuthorityDisabled === false) {
    risks.push("Mint authority is still active.");
  }

  if (report.freezeAuthorityDisabled === true) {
    strengths.push("Freeze authority is disabled.");
  } else if (report.freezeAuthorityDisabled === false) {
    risks.push("Freeze authority is still active.");
  }

  if (report.top10Percentage <= 25) {
    strengths.push(`Observed top-10 concentration is relatively distributed at ${report.top10Percentage.toFixed(1)}%.`);
  } else if (report.top10Percentage >= 40) {
    risks.push(`Observed top-10 concentration is elevated at ${report.top10Percentage.toFixed(1)}%.`);
  } else {
    watch.push(`Top-10 concentration is ${report.top10Percentage.toFixed(1)}%; inspect owner types before drawing conclusions.`);
  }

  if ((market.liquidityToMarketCap ?? 0) >= 0.15) {
    strengths.push("Liquidity is comparatively healthy versus market cap/FDV.");
  } else if (market.liquidityToMarketCap !== null && market.liquidityToMarketCap < 0.08) {
    risks.push("Liquidity is thin relative to market cap/FDV.");
  }

  const total5m = market.buys5m + market.sells5m;
  const buyShare = total5m > 0 ? market.buys5m / total5m : 0.5;

  if (market.buys5m > market.sells5m * 1.5 && total5m >= 10) {
    strengths.push(`Recent order flow is buy-heavy (${market.buys5m} buys vs ${market.sells5m} sells).`);
  } else if (market.sells5m > market.buys5m * 1.5 && total5m >= 10) {
    risks.push(`Recent order flow is sell-heavy (${market.buys5m} buys vs ${market.sells5m} sells).`);
  } else {
    watch.push(`Recent buy share is ${(buyShare * 100).toFixed(0)}%; monitor whether flow accelerates or reverses.`);
  }

  if ((market.pairAgeMinutes ?? 999999) < 120) {
    risks.push("The trading pair is very new, so market structure can change quickly.");
  }

  if (market.volume5m > 0 && market.liquidity > 0) {
    const turnover = market.volume5m / market.liquidity;
    if (turnover > 1) {
      watch.push("5-minute turnover is high relative to liquidity; expect elevated slippage and volatility.");
    }
  }

  for (const flag of report.flags) {
    if ((flag.severity === "danger" || flag.severity === "warning") && risks.length < 6) {
      if (!risks.some((item) => item.toLowerCase().includes(flag.title.toLowerCase()))) {
        risks.push(flag.description);
      }
    }
  }

  const symbol = market.symbol || "TOKEN";
  const headline =
    report.riskScore >= 61
      ? `${symbol}: high technical risk`
      : report.riskScore >= 31
        ? `${symbol}: mixed setup, verify carefully`
        : `${symbol}: lower observed technical risk`;

  const summary = `${symbol} currently shows a risk score of ${report.riskScore}/100, ${compactMoney(market.liquidity)} liquidity, ${compactMoney(market.marketCap || market.fdv)} market cap/FDV, and ${market.buys5m}/${market.sells5m} buys/sells over 5 minutes.`;

  const verdict =
    report.riskScore >= 61
      ? "Several observable risk signals are active. Treat the token as high-risk until the flagged items are independently verified."
      : report.riskScore >= 31
        ? "The token has both positive and cautionary signals. Further wallet, liquidity, and launch-history checks are warranted."
        : "The currently observed checks are comparatively cleaner, but this does not establish legitimacy or future performance.";

  return {
    ok: true,
    mode: "local",
    model: null,
    tokenAddress: report.tokenAddress,
    symbol: market.symbol,
    name: market.name,
    headline,
    summary,
    strengths: strengths.slice(0, 5),
    risks: risks.slice(0, 6),
    watch: watch.slice(0, 5),
    verdict,
    generatedAt: Date.now(),
    disclaimer: "Analytical summary only. Not investment advice and not a prediction of future price."
  };
}

function extractOutputText(data: any): string {
  if (typeof data?.output_text === "string" && data.output_text.trim()) {
    return data.output_text.trim();
  }

  const output = Array.isArray(data?.output) ? data.output : [];
  const chunks: string[] = [];

  for (const item of output) {
    const content = Array.isArray(item?.content) ? item.content : [];
    for (const part of content) {
      if (part?.type === "output_text" && typeof part?.text === "string") {
        chunks.push(part.text);
      }
    }
  }

  return chunks.join("\n").trim();
}

function parseJsonObject(text: string) {
  const cleaned = text
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/```$/i, "")
    .trim();

  return JSON.parse(cleaned);
}

async function openAIAnalysis(
  report: RiskReport,
  apiKey: string,
  model: string,
): Promise<AIAnalysisResponse | null> {
  const prompt = {
    tokenAddress: report.tokenAddress,
    tokenStandard: report.tokenStandard,
    mintAuthorityDisabled: report.mintAuthorityDisabled,
    freezeAuthorityDisabled: report.freezeAuthorityDisabled,
    top1Percentage: report.top1Percentage,
    top10Percentage: report.top10Percentage,
    riskScore: report.riskScore,
    riskLabel: report.riskLabel,
    market: report.market,
    riskFlags: report.flags.map((flag) => ({
      title: flag.title,
      severity: flag.severity,
      points: flag.points,
      description: flag.description,
    })),
  };

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      reasoning: { effort: "low" },
      max_output_tokens: 1200,
      instructions:
        "You are a neutral crypto market-data analyst. Explain only the supplied observable data. Do not predict price, promise returns, tell the user to buy/sell, or invent missing facts. Return strict JSON only with keys headline, summary, strengths, risks, watch, verdict. strengths/risks/watch must be arrays of short strings.",
      input: JSON.stringify(prompt),
    }),
    cache: "no-store",
  });

  if (!response.ok) {
    return null;
  }

  const data = await response.json();
  const text = extractOutputText(data);

  if (!text) return null;

  try {
    const parsed = parseJsonObject(text);

    return {
      ok: true,
      mode: "openai",
      model,
      tokenAddress: report.tokenAddress,
      symbol: report.market.symbol,
      name: report.market.name,
      headline: String(parsed.headline || "Token analysis"),
      summary: String(parsed.summary || ""),
      strengths: Array.isArray(parsed.strengths)
        ? parsed.strengths.map(String).slice(0, 6)
        : [],
      risks: Array.isArray(parsed.risks)
        ? parsed.risks.map(String).slice(0, 7)
        : [],
      watch: Array.isArray(parsed.watch)
        ? parsed.watch.map(String).slice(0, 6)
        : [],
      verdict: String(parsed.verdict || ""),
      generatedAt: Date.now(),
      disclaimer:
        "AI-generated analytical summary of supplied market/on-chain data. Not investment advice or a price prediction.",
    };
  } catch {
    return null;
  }
}

export async function POST(request: NextRequest) {
  let body: { address?: string };

  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { ok: false, error: "Invalid request body." },
      { status: 400 },
    );
  }

  const address = body.address?.trim() || "";

  if (!validAddress(address)) {
    return NextResponse.json(
      { ok: false, error: "Invalid Solana token mint address." },
      { status: 400 },
    );
  }

  try {
    const riskResponse = await fetch(
      `${request.nextUrl.origin}/api/risk/solana/${encodeURIComponent(address)}`,
      { cache: "no-store" },
    );

    const report = (await riskResponse.json()) as RiskReport & {
      error?: string;
    };

    if (!riskResponse.ok || !report.ok) {
      throw new Error(report.error || "Risk data unavailable.");
    }

    const apiKey = process.env.OPENAI_API_KEY?.trim();
    const model =
      process.env.OPENAI_MODEL?.trim() || "gpt-5.6-luna";

    if (apiKey) {
      const ai = await openAIAnalysis(report, apiKey, model);
      if (ai) {
        return NextResponse.json(ai, {
          headers: { "Cache-Control": "no-store" },
        });
      }
    }

    return NextResponse.json(localAnalysis(report), {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Analysis failed.",
      },
      { status: 502 },
    );
  }
}
'@ | Set-Content -Encoding UTF8 "src/app/api/ai/analyze/route.ts"

Step "Membuat AI Analyst page"
New-Item -ItemType Directory -Force -Path "src/app/analyst" | Out-Null

@'
"use client";

import { AppShell } from "@/components/app-shell";
import type { AIAnalysisResponse } from "@/lib/ai-types";
import {
  AlertTriangle,
  BrainCircuit,
  CheckCircle2,
  Eye,
  LoaderCircle,
  Search,
  Sparkles,
} from "lucide-react";
import { FormEvent, useState } from "react";

function ItemGroup({
  title,
  icon,
  items,
}: {
  title: string;
  icon: React.ReactNode;
  items: string[];
}) {
  return (
    <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
      <div className="flex items-center gap-2">
        {icon}
        <h2 className="font-medium text-white">{title}</h2>
      </div>

      <div className="mt-4 space-y-2">
        {items.length ? (
          items.map((item, index) => (
            <div
              key={`${title}-${index}`}
              className="rounded-xl border border-white/5 bg-black/20 p-3 text-sm leading-6 text-zinc-400"
            >
              {item}
            </div>
          ))
        ) : (
          <div className="text-sm text-zinc-600">No item detected.</div>
        )}
      </div>
    </div>
  );
}

export default function AnalystPage() {
  const [address, setAddress] = useState("");
  const [analysis, setAnalysis] =
    useState<AIAnalysisResponse | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  async function analyze(event: FormEvent) {
    event.preventDefault();
    const mint = address.trim();

    if (!/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(mint)) {
      setError("Invalid Solana token mint address.");
      return;
    }

    setLoading(true);
    setError("");

    try {
      const response = await fetch("/api/ai/analyze", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ address: mint }),
      });

      const data = await response.json();

      if (!response.ok || !data.ok) {
        throw new Error(data.error || "Analysis failed.");
      }

      setAnalysis(data as AIAnalysisResponse);
    } catch (err) {
      setAnalysis(null);
      setError(
        err instanceof Error ? err.message : "Analysis failed.",
      );
    } finally {
      setLoading(false);
    }
  }

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="flex items-center gap-2 text-sm text-emerald-300">
          <BrainCircuit className="h-4 w-4" />
          AI Market Analyst
        </div>
        <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
          Token Analyst
        </h1>
        <p className="mt-1 max-w-2xl text-sm text-zinc-500">
          Converts live market and on-chain risk data into a concise,
          neutral research summary.
        </p>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        <form
          onSubmit={analyze}
          className="flex flex-col gap-2 rounded-2xl border border-white/8 bg-white/[0.025] p-4 sm:flex-row"
        >
          <div className="relative min-w-0 flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />
            <input
              value={address}
              onChange={(event) => setAddress(event.target.value)}
              placeholder="Paste Solana token mint address"
              className="h-11 w-full rounded-xl border border-white/8 bg-black/20 pl-10 pr-3 font-mono text-xs outline-none placeholder:text-zinc-700 focus:border-emerald-400/40"
            />
          </div>

          <button
            disabled={loading}
            className="inline-flex h-11 items-center justify-center gap-2 rounded-xl bg-white px-5 text-sm font-medium text-black disabled:opacity-50"
          >
            {loading ? (
              <LoaderCircle className="h-4 w-4 animate-spin" />
            ) : (
              <Sparkles className="h-4 w-4" />
            )}
            {loading ? "Analyzing..." : "Analyze"}
          </button>
        </form>

        {error ? (
          <div className="rounded-2xl border border-rose-400/15 bg-rose-400/5 p-4 text-sm text-rose-200">
            {error}
          </div>
        ) : null}

        {!analysis ? (
          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-10 text-center">
            <BrainCircuit className="mx-auto h-8 w-8 text-zinc-700" />
            <div className="mt-3 text-sm text-zinc-400">
              Paste a real Solana token mint to generate analysis.
            </div>
            <p className="mx-auto mt-2 max-w-xl text-xs leading-5 text-zinc-600">
              Without an OpenAI API key, MemeScope uses its deterministic
              local analyst. With an API key, the same verified data is sent
              to the configured model for a richer explanation.
            </p>
          </div>
        ) : (
          <>
            <section className="rounded-2xl border border-emerald-400/15 bg-emerald-400/[0.035] p-5">
              <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                <div>
                  <div className="text-xs uppercase tracking-[0.12em] text-emerald-300/70">
                    {analysis.name || "Token"}{" "}
                    {analysis.symbol ? `· $${analysis.symbol}` : ""}
                  </div>
                  <h2 className="mt-2 text-2xl font-semibold tracking-tight text-white">
                    {analysis.headline}
                  </h2>
                  <p className="mt-3 max-w-4xl text-sm leading-6 text-zinc-400">
                    {analysis.summary}
                  </p>
                </div>

                <div className="shrink-0 rounded-full border border-white/8 bg-black/20 px-3 py-1.5 text-xs text-zinc-500">
                  {analysis.mode === "openai"
                    ? `AI · ${analysis.model}`
                    : "Local analyst"}
                </div>
              </div>
            </section>

            <section className="grid gap-4 xl:grid-cols-3">
              <ItemGroup
                title="Positive signals"
                icon={<CheckCircle2 className="h-4 w-4 text-emerald-300" />}
                items={analysis.strengths}
              />
              <ItemGroup
                title="Risk signals"
                icon={<AlertTriangle className="h-4 w-4 text-rose-300" />}
                items={analysis.risks}
              />
              <ItemGroup
                title="What to watch"
                icon={<Eye className="h-4 w-4 text-sky-300" />}
                items={analysis.watch}
              />
            </section>

            <section className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
              <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">
                Research conclusion
              </div>
              <p className="mt-3 text-sm leading-6 text-zinc-300">
                {analysis.verdict}
              </p>
            </section>

            <div className="rounded-2xl border border-amber-400/15 bg-amber-400/5 p-4 text-xs leading-5 text-amber-100/60">
              {analysis.disclaimer}
            </div>
          </>
        )}
      </div>
    </AppShell>
  );
}
'@ | Set-Content -Encoding UTF8 "src/app/analyst/page.tsx"

Step "Update sidebar Stage 07"
@'
"use client";

import {
  Bell,
  BrainCircuit,
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
  { href: "/scanner", label: "Scanner", icon: Radar },
  { href: "/discover", label: "Discover", icon: Rocket },
  { href: "/analyst", label: "AI Analyst", icon: BrainCircuit },
  { href: "/wallets", label: "Wallets", icon: WalletCards },
  { href: "/watchlist", label: "Watchlist", icon: Eye },
  { href: "/alerts", label: "Alerts", icon: Bell },
  { href: "/settings", label: "Settings", icon: Settings },
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
          <div className="mb-1 text-xs text-zinc-500">Build</div>
          <div className="flex items-center gap-2 text-sm text-zinc-200">
            <span className="h-2 w-2 rounded-full bg-emerald-400" />
            Stage 07
          </div>
          <p className="mt-2 text-xs leading-5 text-zinc-600">
            AI analyst enabled with deterministic fallback.
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

SOLANA_RPC_URL=
SOLANA_WSS_URL=
PUMPPORTAL_API_KEY=

# Stage 07 AI Analyst
# Optional. If blank, local deterministic analysis is used.
OPENAI_API_KEY=
OPENAI_MODEL=gpt-5.6-luna

# Future
EVM_RPC_URL=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
'@ | Set-Content -Encoding UTF8 ".env.example"

Step "Membersihkan cache"
Remove-Item -Recurse -Force ".next" -ErrorAction SilentlyContinue

Step "Lint"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host " Stage 07 AI Analyst berhasil dipasang." -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Jalankan:" -ForegroundColor White
Write-Host "  npm run dev" -ForegroundColor Yellow
Write-Host ""
Write-Host "Buka:" -ForegroundColor White
Write-Host "  http://localhost:3000/analyst" -ForegroundColor Yellow
