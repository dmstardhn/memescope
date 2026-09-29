$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "Run from the memecoin-analyst project root."
}

$corePath = Join-Path $root "src\lib\content-hq.ts"
$typesPath = Join-Path $root "src\lib\content-hq-types.ts"

foreach ($path in @($corePath, $typesPath)) {
    if (!(Test-Path -LiteralPath $path)) {
        throw "Missing required file: $path"
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:TEMP "MemeScope-BlueprintV3-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $corePath -Destination (Join-Path $backupDir "content-hq.ts") -Force
Copy-Item -LiteralPath $typesPath -Destination (Join-Path $backupDir "content-hq-types.ts") -Force

$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$RelativePath,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $path = Join-Path $root $RelativePath
    $parent = Split-Path -Parent $path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $Content, $utf8)
    Write-Host "Updated: $RelativePath" -ForegroundColor Green
}

Write-Host ""
Write-Host "Installing MemeScope Content HQ Blueprint V3..." -ForegroundColor Cyan

npm install playwright-core @sparticuz/chromium sharp
if ($LASTEXITCODE -ne 0) {
    throw "npm install failed."
}

# --- Types --------------------------------------------------

$types = [System.IO.File]::ReadAllText($typesPath)

$oldTypes = @'
export type ContentType =
  | "new_discovery"
  | "runner"
  | "big_runner"
  | "moonshot"
  | "before_move"
  | "wallet_activity"
  | "holder_growth"
  | "memescope_detection"
  | "weekly_recap"
  | "text_only";
'@

$newTypes = @'
export type ContentType =
  | "new_discovery"
  | "runner"
  | "big_runner"
  | "moonshot"
  | "before_move"
  | "wallet_activity"
  | "smart_money"
  | "holder_growth"
  | "memescope_detection"
  | "call_journey"
  | "weekly_recap"
  | "hall_of_calls"
  | "text_only";
'@

if ($types.Contains($oldTypes)) {
    $types = $types.Replace($oldTypes, $newTypes)
}
elseif (!$types.Contains('"smart_money"')) {
    throw "ContentType block not found."
}

$types = [regex]::Replace(
    $types,
    '(?s)export type ScreenshotPreset =.*?;\r?\n\r?\nexport type ContentConfig',
    "export type ScreenshotPreset = string;`r`n`r`nexport type ContentConfig",
    1
)

[System.IO.File]::WriteAllText($typesPath, $types, $utf8)

# --- New deterministic multi-template visual engine ---------

$engine = @'
import "server-only";

import { neon } from "@neondatabase/serverless";
import chromium from "@sparticuz/chromium";
import { chromium as playwrightChromium } from "playwright-core";
import sharp from "sharp";

import type {
  ContentCandidate,
  ContentType,
  VisualSource,
} from "@/lib/content-hq-types";

export type VisualTemplate = {
  id: string;
  source: VisualSource;
  contentTypes: ContentType[];
  description: string;
};

export const VISUAL_TEMPLATES: VisualTemplate[] = [
  { id: "dex_discovery_01", source: "dex_screener", contentTypes: ["new_discovery"], description: "Large raw chart plus compact market metrics." },
  { id: "dex_discovery_02", source: "dex_screener", contentTypes: ["new_discovery"], description: "Chart-first discovery layout." },
  { id: "dex_runner_01", source: "dex_screener", contentTypes: ["runner", "big_runner"], description: "First spotted versus current on a raw chart." },
  { id: "dex_runner_02", source: "dex_screener", contentTypes: ["runner", "big_runner"], description: "Split chart and performance metrics." },
  { id: "dex_before_move_01", source: "dex_screener", contentTypes: ["before_move", "moonshot"], description: "Before/now performance comparison." },
  { id: "dex_breakout_01", source: "dex_screener", contentTypes: ["runner", "big_runner", "moonshot"], description: "Breakout-focused chart layout." },

  { id: "gmgn_wallet_01", source: "gmgn", contentTypes: ["wallet_activity"], description: "Wallet activity screenshot layout." },
  { id: "gmgn_wallet_02", source: "gmgn", contentTypes: ["wallet_activity"], description: "Large wallet activity focus." },
  { id: "gmgn_smart_money_01", source: "gmgn", contentTypes: ["smart_money", "wallet_activity"], description: "Smart-money research layout." },
  { id: "gmgn_holder_01", source: "gmgn", contentTypes: ["holder_growth"], description: "Holder growth research layout." },
  { id: "gmgn_holder_02", source: "gmgn", contentTypes: ["holder_growth"], description: "Large holder panel." },
  { id: "gmgn_flow_01", source: "gmgn", contentTypes: ["wallet_activity", "smart_money", "holder_growth", "new_discovery", "runner"], description: "Token activity and flow layout." },

  { id: "ms_new_call_01", source: "memescope", contentTypes: ["new_discovery", "memescope_detection"], description: "First-spotted call card." },
  { id: "ms_new_call_02", source: "memescope", contentTypes: ["new_discovery", "memescope_detection"], description: "Minimal chart-first call card." },
  { id: "ms_before_move_01", source: "memescope", contentTypes: ["before_move"], description: "Split first spotted versus now, based on the existing Before The Move card." },
  { id: "ms_before_move_02", source: "memescope", contentTypes: ["before_move"], description: "Single chart with spotted and current states." },
  { id: "ms_runner_01", source: "memescope", contentTypes: ["runner"], description: "Runner metrics and chart." },
  { id: "ms_runner_02", source: "memescope", contentTypes: ["runner"], description: "Large runner chart." },
  { id: "ms_big_runner_01", source: "memescope", contentTypes: ["big_runner"], description: "Big runner performance view." },
  { id: "ms_moonshot_01", source: "memescope", contentTypes: ["moonshot"], description: "Milestone performance view." },
  { id: "ms_call_journey_01", source: "memescope", contentTypes: ["call_journey", "moonshot"], description: "Detection to milestone journey." },
  { id: "ms_weekly_01", source: "memescope", contentTypes: ["weekly_recap"], description: "Simple weekly grid." },
  { id: "ms_weekly_02", source: "memescope", contentTypes: ["weekly_recap"], description: "Editorial weekly tape." },
  { id: "ms_hall_01", source: "memescope", contentTypes: ["hall_of_calls"], description: "Recent standouts summary." },
];

type DbRow = Record<string, unknown>;

type Market = {
  pairAddress: string | null;
  quote: string;
  marketCap: number | null;
  liquidity: number | null;
  volume24h: number | null;
  buys5m: number | null;
  sells5m: number | null;
};

type Candle = {
  t: number;
  close: number;
};

function db() {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}

function numberValue(value: unknown, fallback = 0) {
  const result = Number(value);
  return Number.isFinite(result) ? result : fallback;
}

function optionalNumber(value: unknown) {
  if (value === null || value === undefined || value === "") return null;
  const result = Number(value);
  return Number.isFinite(result) ? result : null;
}

function esc(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function usd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  if (value >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(0)}K`;
  return `$${value.toFixed(0)}`;
}

function styles() {
  return `
    <style>
      .brand{font-family:Arial,sans-serif;font-size:16px;fill:#78837f;font-weight:700;letter-spacing:2px}
      .ticker{font-family:Arial,sans-serif;font-size:44px;fill:#f1f3f2;font-weight:800}
      .title{font-family:Arial,sans-serif;font-size:27px;fill:#eef2f0;font-weight:700}
      .label{font-family:Arial,sans-serif;font-size:16px;fill:#747d79}
      .value{font-family:Arial,sans-serif;font-size:29px;fill:#edf2ef;font-weight:650}
      .small{font-family:Arial,sans-serif;font-size:15px;fill:#939d99}
      .green{fill:#74d6ad}
      .red{fill:#e67979}
    </style>`;
}

async function webp(svg: string) {
  return sharp(Buffer.from(svg, "utf8")).webp({ quality: 90 }).toBuffer();
}

function candidatesFor(source: VisualSource, contentType: ContentType) {
  const exact = VISUAL_TEMPLATES.filter(
    (item) => item.source === source && item.contentTypes.includes(contentType),
  );
  return exact.length ? exact : VISUAL_TEMPLATES.filter((item) => item.source === source);
}

export async function chooseVisualTemplate(
  source: VisualSource,
  contentType: ContentType,
  forced?: string | null,
) {
  if (forced) {
    const selected = VISUAL_TEMPLATES.find(
      (item) => item.id === forced && item.source === source,
    );
    if (selected) return selected;
  }

  const options = candidatesFor(source, contentType);
  if (!options.length) return null;

  let last = "";
  const sql = db();

  try {
    const rows = await sql`
      SELECT screenshot_preset
      FROM memescope_content_queue
      WHERE visual_source = ${source}
      ORDER BY created_at DESC
      LIMIT 1
    `;
    last = rows.length ? String((rows[0] as DbRow).screenshot_preset ?? "") : "";
  } catch {
    last = "";
  }

  const usage = await Promise.all(
    options.map(async (item) => {
      try {
        const rows = await sql`
          SELECT COUNT(*)::INTEGER AS count
          FROM memescope_content_queue
          WHERE screenshot_preset = ${item.id}
        `;
        return { item, count: numberValue((rows[0] as DbRow | undefined)?.count, 0) };
      } catch {
        return { item, count: 0 };
      }
    }),
  );

  return usage
    .filter((row) => row.item.id !== last || options.length === 1)
    .sort((a, b) => a.count - b.count || a.item.id.localeCompare(b.item.id))[0]?.item ?? options[0];
}

async function market(candidate: ContentCandidate): Promise<Market> {
  try {
    const response = await fetch(
      `https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(candidate.tokenAddress)}`,
      { headers: { Accept: "application/json" }, cache: "no-store" },
    );

    if (!response.ok) throw new Error("DEX API failed.");

    const body = (await response.json()) as {
      pairs?: Array<{
        chainId?: string;
        pairAddress?: string;
        quoteToken?: { symbol?: string };
        marketCap?: number;
        fdv?: number;
        liquidity?: { usd?: number };
        volume?: { h24?: number };
        txns?: { m5?: { buys?: number; sells?: number } };
      }>;
    };

    const pairs = (body.pairs ?? []).filter((pair) => pair.chainId === "solana");
    const pair =
      pairs.find((item) => candidate.pairAddress && item.pairAddress === candidate.pairAddress) ??
      pairs.sort((a, b) => numberValue(b.liquidity?.usd) - numberValue(a.liquidity?.usd))[0];

    if (!pair) throw new Error("No pair.");

    return {
      pairAddress: pair.pairAddress ?? candidate.pairAddress,
      quote: pair.quoteToken?.symbol ?? "SOL",
      marketCap: optionalNumber(pair.marketCap ?? pair.fdv),
      liquidity: optionalNumber(pair.liquidity?.usd),
      volume24h: optionalNumber(pair.volume?.h24),
      buys5m: optionalNumber(pair.txns?.m5?.buys),
      sells5m: optionalNumber(pair.txns?.m5?.sells),
    };
  } catch {
    return {
      pairAddress: candidate.pairAddress,
      quote: "SOL",
      marketCap: candidate.currentMarketCap,
      liquidity: candidate.liquidityUsd,
      volume24h: candidate.volumeUsd,
      buys5m: null,
      sells5m: null,
    };
  }
}

async function candles(pairAddress: string | null) {
  if (!pairAddress) return [] as Candle[];

  try {
    const response = await fetch(
      `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(pairAddress)}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base`,
      { headers: { Accept: "application/json;version=20230203" }, cache: "no-store" },
    );

    if (!response.ok) return [];

    const body = (await response.json()) as {
      data?: { attributes?: { ohlcv_list?: Array<Array<number>> } };
    };

    return (body.data?.attributes?.ohlcv_list ?? [])
      .map((row) => ({ t: numberValue(row[0]) * 1000, close: numberValue(row[4], NaN) }))
      .filter((row) => Number.isFinite(row.close) && row.close > 0)
      .sort((a, b) => a.t - b.t);
  } catch {
    return [];
  }
}

function chart(data: Candle[], x: number, y: number, w: number, h: number, color = "#d7dfdc") {
  if (data.length < 2) {
    return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0c0d0d" stroke="#252927"/>
      <text x="${x + w / 2}" y="${y + h / 2}" text-anchor="middle" class="small">chart data unavailable</text>`;
  }

  const values = data.map((item) => item.close);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = Math.max(max - min, max * 0.02, 1e-12);

  const points = data.map((item, index) => {
    const px = x + 22 + (index / (data.length - 1)) * (w - 44);
    const py = y + h - 24 - ((item.close - min) / range) * (h - 48);
    return `${px.toFixed(1)},${py.toFixed(1)}`;
  });

  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0c0d0d" stroke="#252927"/>
    <line x1="${x + 20}" y1="${y + h * 0.25}" x2="${x + w - 20}" y2="${y + h * 0.25}" stroke="#181b1a"/>
    <line x1="${x + 20}" y1="${y + h * 0.50}" x2="${x + w - 20}" y2="${y + h * 0.50}" stroke="#181b1a"/>
    <line x1="${x + 20}" y1="${y + h * 0.75}" x2="${x + w - 20}" y2="${y + h * 0.75}" stroke="#181b1a"/>
    <polyline points="${points.join(" ")}" fill="none" stroke="${color}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function sourceUrl(source: VisualSource, candidate: ContentCandidate) {
  if (source === "dex_screener") {
    return `https://dexscreener.com/solana/${encodeURIComponent(candidate.pairAddress ?? candidate.tokenAddress)}`;
  }
  if (source === "gmgn") {
    return `https://gmgn.ai/sol/token/${encodeURIComponent(candidate.tokenAddress)}`;
  }
  return null;
}

async function capture(url: string, source: VisualSource) {
  const executablePath = await chromium.executablePath();
  const browser = await playwrightChromium.launch({
    args: chromium.args,
    executablePath,
    headless: true,
  });

  try {
    const page = await browser.newPage({
      viewport: { width: 1600, height: 900 },
      deviceScaleFactor: 1,
    });

    await page.goto(url, { waitUntil: "domcontentloaded", timeout: 35_000 });
    await page.waitForTimeout(source === "gmgn" ? 7_000 : 5_000);

    const blocked = await page.evaluate(() => {
      const body = (document.body?.innerText ?? "").toLowerCase();
      const title = document.title.toLowerCase();
      return (
        body.includes("verify you are human") ||
        body.includes("performing security verification") ||
        body.includes("checking your browser") ||
        body.includes("access denied") ||
        body.includes("captcha") ||
        title.includes("just a moment") ||
        Boolean(document.querySelector('iframe[src*="challenges.cloudflare.com"], [name="cf-turnstile-response"], #challenge-stage'))
      );
    }).catch(() => false);

    return {
      blocked,
      buffer: Buffer.from(await page.screenshot({ type: "png", fullPage: false })),
    };
  } finally {
    await browser.close();
  }
}

async function screenshotLayout(
  screenshot: Buffer,
  templateId: string,
  candidate: ContentCandidate,
  sourceLabel: string,
) {
  const image = await sharp(screenshot)
    .resize(1400, 650, { fit: "cover", position: "top" })
    .webp({ quality: 88 })
    .toBuffer();

  const href = `data:image/webp;base64,${image.toString("base64")}`;
  const split = templateId.endsWith("_02");

  return webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <rect width="1600" height="900" fill="#090a0a"/>
    ${styles()}
    <text x="70" y="62" class="brand">MEMESCOPE / ${esc(sourceLabel)}</text>
    <text x="70" y="116" class="ticker">$${esc(candidate.symbol)}</text>
    <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>
    <image href="${href}" x="70" y="150" width="${split ? 1060 : 1460}" height="640" preserveAspectRatio="xMidYMid slice"/>
    ${split ? `<rect x="1160" y="150" width="370" height="640" rx="10" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="1200" y="220" class="label">first spotted</text>
      <text x="1200" y="262" class="value">${esc(usd(candidate.firstMarketCap))}</text>
      <text x="1200" y="360" class="label">current</text>
      <text x="1200" y="402" class="value">${esc(usd(candidate.currentMarketCap))}</text>
      <text x="1200" y="500" class="label">move</text>
      <text x="1200" y="542" class="value green">${esc(candidate.multiple.toFixed(2) + "x")}</text>` : ""}
    <text x="70" y="852" class="small">raw source capture / minimal annotation / 1600x900</text>
  </svg>`);
}

async function dexVisual(templateId: string, candidate: ContentCandidate) {
  const url = sourceUrl("dex_screener", candidate);

  if (url) {
    try {
      const result = await capture(url, "dex_screener");
      if (!result.blocked) {
        return {
          buffer: await screenshotLayout(result.buffer, templateId, candidate, "DEX SCREENER"),
          mode: "real-screenshot" as const,
        };
      }
    } catch {
      // Deterministic fallback below.
    }
  }

  const m = await market(candidate);
  const series = await candles(m.pairAddress);
  const currentMc = m.marketCap ?? candidate.currentMarketCap;

  return {
    buffer: await webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>
      ${styles()}
      <text x="70" y="62" class="brand">DEX SCREENER / SOLANA</text>
      <text x="70" y="116" class="ticker">$${esc(candidate.symbol)} / ${esc(m.quote)}</text>
      <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>

      ${chart(series, 70, 160, templateId.endsWith("_02") ? 1020 : 1080, 570)}

      <rect x="1180" y="160" width="350" height="570" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="1220" y="220" class="label">first spotted</text>
      <text x="1220" y="262" class="value">${esc(usd(candidate.firstMarketCap))}</text>
      <text x="1220" y="348" class="label">current MC</text>
      <text x="1220" y="390" class="value">${esc(usd(currentMc))}</text>
      <text x="1220" y="476" class="label">liquidity</text>
      <text x="1220" y="518" class="value">${esc(usd(m.liquidity ?? candidate.liquidityUsd))}</text>
      <text x="1220" y="604" class="label">24h volume</text>
      <text x="1220" y="646" class="value">${esc(usd(m.volume24h ?? candidate.volumeUsd))}</text>

      <rect x="70" y="760" width="1460" height="82" rx="10" fill="#101211" stroke="#272c2a"/>
      <text x="102" y="812" class="value green">${esc(candidate.multiple.toFixed(2) + "x since detection")}</text>
      <text x="1498" y="812" text-anchor="end" class="small">DEX market data / MemeScope render fallback</text>
    </svg>`),
    mode: "deterministic-render" as const,
  };
}

async function gmgnVisual(templateId: string, candidate: ContentCandidate) {
  const url = sourceUrl("gmgn", candidate);

  if (url) {
    try {
      const result = await capture(url, "gmgn");
      if (!result.blocked) {
        return {
          buffer: await screenshotLayout(result.buffer, templateId, candidate, "GMGN"),
          mode: "real-screenshot" as const,
        };
      }
    } catch {
      // Truthful deterministic fallback below.
    }
  }

  const title =
    templateId.includes("holder") ? "HOLDER RESEARCH" :
    templateId.includes("smart_money") ? "SMART MONEY RESEARCH" :
    templateId.includes("flow") ? "TOKEN ACTIVITY" :
    "WALLET ACTIVITY";

  return {
    buffer: await webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>
      ${styles()}
      <text x="70" y="62" class="brand">GMGN / RESEARCH VIEW</text>
      <text x="70" y="116" class="ticker">$${esc(candidate.symbol)}</text>
      <text x="70" y="166" class="title">${esc(title)}</text>
      <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>

      <rect x="70" y="220" width="710" height="520" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="110" y="282" class="label">visual source</text>
      <text x="110" y="326" class="value">GMGN</text>
      <text x="110" y="420" class="label">first spotted MC</text>
      <text x="110" y="464" class="value">${esc(usd(candidate.firstMarketCap))}</text>
      <text x="110" y="558" class="label">current MC</text>
      <text x="110" y="602" class="value">${esc(usd(candidate.currentMarketCap))}</text>
      <text x="110" y="686" class="small">GMGN page was not accessible to the server browser.</text>
      <text x="110" y="716" class="small">No wallet or holder values are fabricated.</text>

      <rect x="820" y="220" width="710" height="150" rx="12" fill="#101211" stroke="#272c2a"/>
      <text x="860" y="270" class="label">move since detection</text>
      <text x="860" y="324" class="value green">${esc(candidate.multiple.toFixed(2) + "x")}</text>

      <rect x="820" y="398" width="710" height="150" rx="12" fill="#101211" stroke="#272c2a"/>
      <text x="860" y="448" class="label">content type</text>
      <text x="860" y="502" class="value">${esc(candidate.contentType.replaceAll("_", " "))}</text>

      <rect x="820" y="576" width="710" height="164" rx="12" fill="#101211" stroke="#272c2a"/>
      <text x="860" y="626" class="label">research state</text>
      <text x="860" y="680" class="value">review source activity</text>

      <text x="70" y="850" class="small">Source target: GMGN / fallback render: MemeScope / no fabricated GMGN metrics</text>
    </svg>`),
    mode: "deterministic-render" as const,
  };
}

async function memescopeVisual(templateId: string, candidate: ContentCandidate) {
  const m = await market(candidate);
  const series = await candles(m.pairAddress);
  const currentMc = m.marketCap ?? candidate.currentMarketCap;

  if (templateId === "ms_before_move_01") {
    const cut = Math.max(2, Math.floor(series.length * 0.42));
    return {
      buffer: await webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
        <rect width="1600" height="900" fill="#090a0a"/>
        ${styles()}
        <text x="70" y="62" class="brand">MEMESCOPE / BEFORE THE MOVE</text>
        <text x="70" y="116" class="ticker">$${esc(candidate.symbol)}</text>
        <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>
        <text x="70" y="182" class="title">FIRST SPOTTED</text>
        <text x="818" y="182" class="title">NOW</text>
        ${chart(series.slice(0, cut), 70, 215, 712, 470, "#b5bfbb")}
        ${chart(series, 818, 215, 712, 470, "#74d6ad")}
        <rect x="70" y="718" width="712" height="108" rx="10" fill="#101211" stroke="#272c2a"/>
        <text x="102" y="760" class="label">first MC</text>
        <text x="102" y="806" class="value">${esc(usd(candidate.firstMarketCap))}</text>
        <rect x="818" y="718" width="712" height="108" rx="10" fill="#101211" stroke="#272c2a"/>
        <text x="850" y="760" class="label">current / move</text>
        <text x="850" y="806" class="value green">${esc(usd(currentMc) + " / " + candidate.multiple.toFixed(2) + "x")}</text>
      </svg>`),
      mode: "deterministic-render" as const,
    };
  }

  if (templateId === "ms_call_journey_01" || templateId === "ms_moonshot_01") {
    const call = candidate.firstMarketCap ?? 0;
    return {
      buffer: await webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
        <rect width="1600" height="900" fill="#090a0a"/>
        ${styles()}
        <text x="70" y="62" class="brand">MEMESCOPE / CALL JOURNEY</text>
        <text x="70" y="116" class="ticker">$${esc(candidate.symbol)}</text>
        <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>

        <line x1="210" y1="265" x2="1390" y2="265" stroke="#343a37" stroke-width="3"/>
        <circle cx="210" cy="265" r="13" fill="#d7dfdc"/>
        <circle cx="600" cy="265" r="13" fill="#a4bab1"/>
        <circle cx="990" cy="265" r="13" fill="#82cbaa"/>
        <circle cx="1390" cy="265" r="15" fill="#74d6ad"/>

        <text x="210" y="220" text-anchor="middle" class="label">DETECTION</text>
        <text x="600" y="220" text-anchor="middle" class="label">2X</text>
        <text x="990" y="220" text-anchor="middle" class="label">5X</text>
        <text x="1390" y="220" text-anchor="middle" class="label">PEAK</text>

        <text x="210" y="325" text-anchor="middle" class="value">${esc(usd(call || null))}</text>
        <text x="600" y="325" text-anchor="middle" class="value">${esc(usd(call ? call * 2 : null))}</text>
        <text x="990" y="325" text-anchor="middle" class="value">${esc(usd(call ? call * 5 : null))}</text>
        <text x="1390" y="325" text-anchor="middle" class="value green">${esc(candidate.multiple.toFixed(2) + "x")}</text>

        ${chart(series, 70, 405, 1460, 330, "#74d6ad")}
        <text x="70" y="818" class="small">call MC ${esc(usd(candidate.firstMarketCap))}</text>
        <text x="1530" y="818" text-anchor="end" class="small">current MC ${esc(usd(currentMc))}</text>
      </svg>`),
      mode: "deterministic-render" as const,
    };
  }

  if (templateId === "ms_weekly_01" || templateId === "ms_weekly_02" || templateId === "ms_hall_01") {
    return {
      buffer: await webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
        <rect width="1600" height="900" fill="#090a0a"/>
        ${styles()}
        <text x="70" y="62" class="brand">MEMESCOPE / PERFORMANCE TAPE</text>
        <text x="70" y="120" class="ticker">${esc(templateId === "ms_hall_01" ? "RECENT STANDOUTS" : "THIS WEEK")}</text>
        <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>

        <rect x="70" y="190" width="1460" height="560" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
        <text x="120" y="270" class="title">$${esc(candidate.symbol)}</text>
        <text x="120" y="330" class="label">tracked move</text>
        <text x="120" y="390" class="value green">${esc(candidate.multiple.toFixed(2) + "x")}</text>

        <line x1="520" y1="230" x2="520" y2="700" stroke="#272c2a"/>
        <text x="580" y="285" class="label">first MC</text>
        <text x="580" y="335" class="value">${esc(usd(candidate.firstMarketCap))}</text>
        <text x="580" y="440" class="label">current MC</text>
        <text x="580" y="490" class="value">${esc(usd(currentMc))}</text>

        ${chart(series, 980, 250, 480, 380, "#74d6ad")}
        <text x="70" y="842" class="small">simple editorial summary / no AI poster styling</text>
      </svg>`),
      mode: "deterministic-render" as const,
    };
  }

  const wide = templateId.endsWith("_02");
  return {
    buffer: await webp(`<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>
      ${styles()}
      <text x="70" y="62" class="brand">MEMESCOPE / ${esc(candidate.contentType.replaceAll("_", " ").toUpperCase())}</text>
      <text x="70" y="116" class="ticker">$${esc(candidate.symbol)}</text>
      <text x="1530" y="64" text-anchor="end" class="small">${esc(templateId)}</text>
      ${chart(series, 70, 170, wide ? 1460 : 1030, 550, "#74d6ad")}
      ${wide ? "" : `<rect x="1140" y="170" width="390" height="550" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
        <text x="1180" y="230" class="label">first MC</text>
        <text x="1180" y="274" class="value">${esc(usd(candidate.firstMarketCap))}</text>
        <text x="1180" y="366" class="label">current MC</text>
        <text x="1180" y="410" class="value">${esc(usd(currentMc))}</text>
        <text x="1180" y="502" class="label">move</text>
        <text x="1180" y="546" class="value green">${esc(candidate.multiple.toFixed(2) + "x")}</text>`}
      <rect x="70" y="760" width="1460" height="80" rx="10" fill="#101211" stroke="#272c2a"/>
      <text x="102" y="810" class="small">MemeScope first spotted ${esc(usd(candidate.firstMarketCap))}</text>
      <text x="1498" y="810" text-anchor="end" class="small">current ${esc(usd(currentMc))}</text>
    </svg>`),
    mode: "deterministic-render" as const,
  };
}

export async function renderContentVisual(
  candidate: ContentCandidate,
  source: VisualSource,
  forcedTemplate?: string | null,
) {
  if (source === "text_only") {
    return { buffer: null, mime: null, templateId: "text_only", mode: "text-only" as const };
  }

  const template = await chooseVisualTemplate(source, candidate.contentType, forcedTemplate);
  if (!template) {
    throw new Error(`No visual template for ${source}/${candidate.contentType}.`);
  }

  if (source === "dex_screener") {
    const result = await dexVisual(template.id, candidate);
    return { buffer: result.buffer, mime: "image/webp", templateId: template.id, mode: result.mode };
  }

  if (source === "gmgn") {
    const result = await gmgnVisual(template.id, candidate);
    return { buffer: result.buffer, mime: "image/webp", templateId: template.id, mode: result.mode };
  }

  const result = await memescopeVisual(template.id, candidate);
  return { buffer: result.buffer, mime: "image/webp", templateId: template.id, mode: result.mode };
}
'@

Write-Utf8NoBom "src/lib/content-hq-blueprint-v3.ts" $engine


# ============================================================
# 3. PATCH EXISTING CORE TO USE THE V3 VISUAL ENGINE
# ============================================================

$core = [System.IO.File]::ReadAllText($corePath)

if (!$core.Contains('from "@/lib/content-hq-blueprint-v3"')) {
    $firstImport = $core.IndexOf("import ")
    if ($firstImport -lt 0) {
        throw "Import marker not found in content-hq.ts"
    }

    $v3Import = @'
import {
  renderContentVisual,
} from "@/lib/content-hq-blueprint-v3";

'@

    $core =
      $core.Substring(0, $firstImport) +
      $v3Import +
      $core.Substring($firstImport)
}

$oldPriority = @'
const PRIORITY:
  Record<ContentType, number> = {
    moonshot: 9,
    before_move: 8,
    big_runner: 7,
    wallet_activity: 6,
    runner: 5,
    holder_growth: 4,
    memescope_detection: 4,
    new_discovery: 3,
    weekly_recap: 3,
    text_only: 1,
  };
'@

$newPriority = @'
const PRIORITY:
  Record<ContentType, number> = {
    moonshot: 90,
    before_move: 80,
    big_runner: 70,
    smart_money: 65,
    wallet_activity: 60,
    runner: 50,
    holder_growth: 40,
    memescope_detection: 35,
    new_discovery: 30,
    call_journey: 28,
    weekly_recap: 25,
    hall_of_calls: 25,
    text_only: 10,
  };
'@

if ($core.Contains($oldPriority)) {
    $core = $core.Replace($oldPriority, $newPriority)
}
elseif (!$core.Contains("smart_money: 65")) {
    throw "PRIORITY block not found."
}

$oldSignature = @'
async function createQueueItem(
  candidate:
    ContentCandidate,
  config:
    ContentConfig,
  forcedSource?:
    VisualSource,
) {
'@

$newSignature = @'
async function createQueueItem(
  candidate:
    ContentCandidate,
  config:
    ContentConfig,
  forcedSource?:
    VisualSource,
  forcedVisualTemplate?:
    string,
) {
'@

if ($core.Contains($oldSignature)) {
    $core = $core.Replace($oldSignature, $newSignature)
}
elseif (!$core.Contains("forcedVisualTemplate?:")) {
    throw "createQueueItem signature not found."
}

$shotStart = $core.IndexOf("async function screenshotForCandidate(")
$shotEnd = $core.IndexOf("async function createQueueItem(", $shotStart)

if ($shotStart -lt 0 -or $shotEnd -le $shotStart) {
    throw "screenshotForCandidate block not found."
}

$newShot = @'
async function screenshotForCandidate(
  candidate:
    ContentCandidate,
  source:
    VisualSource,
  forcedVisualTemplate?:
    string,
) {
  const visual =
    await renderContentVisual(
      candidate,
      source,
      forcedVisualTemplate,
    );

  return {
    buffer:
      visual.buffer,
    mime:
      visual.mime,
    preset:
      visual.templateId,
  };
}

'@

$core =
  $core.Substring(0, $shotStart) +
  $newShot +
  $core.Substring($shotEnd)

$oldPresetBlock = @'
  const preset =
    presetFor(
      candidate.contentType,
      source,
    );

'@

if ($core.Contains($oldPresetBlock)) {
    $core = $core.Replace($oldPresetBlock, "")
}

$oldScreenshotCall = @'
  const screenshot =
    await screenshotForCandidate(
      candidate,
      source,
    ).catch(
'@

$newScreenshotCall = @'
  const screenshot =
    await screenshotForCandidate(
      candidate,
      source,
      forcedVisualTemplate,
    ).catch(
'@

if ($core.Contains($oldScreenshotCall)) {
    $core = $core.Replace($oldScreenshotCall, $newScreenshotCall)
}

$catchStart = $core.IndexOf(
    '      () => ({' + "`r`n" + '        buffer: null,' + "`r`n" + '        mime: null,',
    $core.IndexOf("async function createQueueItem(")
)

if ($catchStart -lt 0) {
    $catchStart = $core.IndexOf(
        '      () => ({' + "`n" + '        buffer: null,' + "`n" + '        mime: null,',
        $core.IndexOf("async function createQueueItem(")
    )
}

if ($catchStart -ge 0) {
    $catchEnd = $core.IndexOf("      }),", $catchStart)
    if ($catchEnd -ge 0) {
        $catchEnd += "      }),".Length
        $replacement = @'
      () => ({
        buffer: null,
        mime: null,
        preset:
          source === "text_only"
            ? "text_only"
            : `${source}_failed`,
      }),
'@
        $core =
          $core.Substring(0, $catchStart) +
          $replacement +
          $core.Substring($catchEnd)
    }
}

$core = $core.Replace(
    '      ${preset},' + "`r`n" + '      ${imageBase64},',
    '      ${screenshot.preset},' + "`r`n" + '      ${imageBase64},'
)
$core = $core.Replace(
    '      ${preset},' + "`n" + '      ${imageBase64},',
    '      ${screenshot.preset},' + "`n" + '      ${imageBase64},'
)

$core = [regex]::Replace(
    $core,
    '(?s)screenshot_preset = \$\{presetFor\(\s*item\.contentType,\s*source,\s*\)\},',
    'screenshot_preset = ${screenshot.preset},',
    1
)

$seedMarker = @'
        [
          "text_only_02",
          "text_only",
          "not much worth touching right now.\n\npatience > forcing trades.",
        ],
'@

$seedReplacement = @'
        [
          "text_only_02",
          "text_only",
          "not much worth touching right now.\n\npatience > forcing trades.",
        ],
        [
          "smart_money_01",
          "smart_money",
          "some notable wallet activity around $TOKEN.\n\nwatching whether the flow keeps building.",
        ],
        [
          "smart_money_02",
          "smart_money",
          "$TOKEN is starting to show up in the wallet flow.\n\nstill early. watching the next few transactions.",
        ],
        [
          "call_journey_01",
          "call_journey",
          "$TOKEN journey so far.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE since detection.",
        ],
        [
          "call_journey_02",
          "call_journey",
          "$TOKEN kept developing after the first detection.\n\nfirst seen: $FIRST_MC\ncurrent: $CURRENT_MC",
        ],
        [
          "hall_of_calls_01",
          "hall_of_calls",
          "recent standout: $TOKEN\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE.",
        ],
        [
          "hall_of_calls_02",
          "hall_of_calls",
          "$TOKEN is one of the stronger tracked moves in the recent tape.\n\n$MULTIPLE since detection.",
        ],
        [
          "holder_growth_02",
          "holder_growth",
          "watching the holder side of $TOKEN.\n\nthe distribution is worth keeping an eye on.",
        ],
        [
          "wallet_activity_02",
          "wallet_activity",
          "$TOKEN is showing some interesting wallet flow.\n\nwatching whether it continues.",
        ],
'@

if ($core.Contains($seedMarker)) {
    $core = $core.Replace($seedMarker, $seedReplacement)
}

# ============================================================
# 4. EXPAND LARGE DEMO MATRIX
# ============================================================

$matrixStart = $core.IndexOf("const CONTENT_HQ_DEMO_SCENARIOS:")
$matrixEnd = $core.IndexOf("export async function contentHqDemoScenarioCount()", $matrixStart)

if ($matrixStart -ge 0 -and $matrixEnd -gt $matrixStart) {
    $matrix = @'
const CONTENT_HQ_DEMO_SCENARIOS:
  ContentHqDemoScenario[] = [
    { source: "dex_screener", contentType: "new_discovery", multiple: 1.14, label: "DEX Discovery 01" },
    { source: "dex_screener", contentType: "new_discovery", multiple: 1.29, label: "DEX Discovery 02" },
    { source: "dex_screener", contentType: "runner", multiple: 2.03, label: "DEX Runner 01" },
    { source: "dex_screener", contentType: "runner", multiple: 2.34, label: "DEX Runner 02" },
    { source: "dex_screener", contentType: "runner", multiple: 2.78, label: "DEX Runner 03" },
    { source: "dex_screener", contentType: "big_runner", multiple: 4.06, label: "DEX Big Runner 01" },
    { source: "dex_screener", contentType: "big_runner", multiple: 4.62, label: "DEX Big Runner 02" },
    { source: "dex_screener", contentType: "moonshot", multiple: 5.72, label: "DEX Moonshot 01" },
    { source: "dex_screener", contentType: "moonshot", multiple: 7.31, label: "DEX Moonshot 02" },
    { source: "dex_screener", contentType: "before_move", multiple: 3.18, label: "DEX Before Move 01" },
    { source: "dex_screener", contentType: "before_move", multiple: 5.41, label: "DEX Before Move 02" },
    { source: "dex_screener", contentType: "big_runner", multiple: 3.88, label: "DEX Breakout Research" },

    { source: "gmgn", contentType: "wallet_activity", multiple: 1.18, label: "GMGN Wallet 01" },
    { source: "gmgn", contentType: "wallet_activity", multiple: 1.33, label: "GMGN Wallet 02" },
    { source: "gmgn", contentType: "wallet_activity", multiple: 1.57, label: "GMGN Wallet 03" },
    { source: "gmgn", contentType: "smart_money", multiple: 1.26, label: "GMGN Smart Money 01" },
    { source: "gmgn", contentType: "smart_money", multiple: 1.48, label: "GMGN Smart Money 02" },
    { source: "gmgn", contentType: "holder_growth", multiple: 1.12, label: "GMGN Holder 01" },
    { source: "gmgn", contentType: "holder_growth", multiple: 1.31, label: "GMGN Holder 02" },
    { source: "gmgn", contentType: "holder_growth", multiple: 1.63, label: "GMGN Holder 03" },
    { source: "gmgn", contentType: "new_discovery", multiple: 1.23, label: "GMGN Activity Flow 01" },
    { source: "gmgn", contentType: "runner", multiple: 2.11, label: "GMGN Activity Flow 02" },

    { source: "memescope", contentType: "memescope_detection", multiple: 1.08, label: "MemeScope Detection 01" },
    { source: "memescope", contentType: "memescope_detection", multiple: 1.24, label: "MemeScope Detection 02" },
    { source: "memescope", contentType: "memescope_detection", multiple: 1.51, label: "MemeScope Detection 03" },
    { source: "memescope", contentType: "runner", multiple: 2.06, label: "MemeScope Runner 01" },
    { source: "memescope", contentType: "runner", multiple: 2.39, label: "MemeScope Runner 02" },
    { source: "memescope", contentType: "runner", multiple: 2.81, label: "MemeScope Runner 03" },
    { source: "memescope", contentType: "big_runner", multiple: 4.14, label: "MemeScope Big Runner 01" },
    { source: "memescope", contentType: "big_runner", multiple: 4.77, label: "MemeScope Big Runner 02" },
    { source: "memescope", contentType: "moonshot", multiple: 5.68, label: "MemeScope Moonshot 01" },
    { source: "memescope", contentType: "moonshot", multiple: 7.44, label: "MemeScope Moonshot 02" },
    { source: "memescope", contentType: "before_move", multiple: 3.12, label: "MemeScope Before Move 01" },
    { source: "memescope", contentType: "before_move", multiple: 4.28, label: "MemeScope Before Move 02" },
    { source: "memescope", contentType: "before_move", multiple: 6.03, label: "MemeScope Before Move 03" },
    { source: "memescope", contentType: "call_journey", multiple: 5.37, label: "MemeScope Call Journey 01" },
    { source: "memescope", contentType: "call_journey", multiple: 8.22, label: "MemeScope Call Journey 02" },
    { source: "memescope", contentType: "weekly_recap", multiple: 1, label: "MemeScope Weekly 01" },
    { source: "memescope", contentType: "weekly_recap", multiple: 1, label: "MemeScope Weekly 02" },
    { source: "memescope", contentType: "hall_of_calls", multiple: 5.11, label: "MemeScope Hall 01" },
    { source: "memescope", contentType: "hall_of_calls", multiple: 10.38, label: "MemeScope Hall 02" },

    { source: "text_only", contentType: "text_only", multiple: 1, label: "Text Only 01" },
    { source: "text_only", contentType: "text_only", multiple: 1, label: "Text Only 02" },
    { source: "text_only", contentType: "text_only", multiple: 1, label: "Text Only 03" },
    { source: "text_only", contentType: "text_only", multiple: 1, label: "Text Only 04" },
    { source: "text_only", contentType: "text_only", multiple: 1, label: "Text Only 05" },
    { source: "text_only", contentType: "text_only", multiple: 1, label: "Text Only 06" },
  ];

'@

    $core =
      $core.Substring(0, $matrixStart) +
      $matrix +
      $core.Substring($matrixEnd)
}
else {
    Write-Host "Large matrix block not found. Existing demo matrix left unchanged." -ForegroundColor Yellow
}

[System.IO.File]::WriteAllText($corePath, $core, $utf8)
Write-Host "Patched: src/lib/content-hq.ts" -ForegroundColor Green

# ============================================================
# 5. VISUAL REGISTRY API + PAGE
# ============================================================

$registryRoute = @'
import { NextResponse } from "next/server";
import { VISUAL_TEMPLATES } from "@/lib/content-hq-blueprint-v3";

export async function GET() {
  return NextResponse.json({
    ok: true,
    count: VISUAL_TEMPLATES.length,
    templates: VISUAL_TEMPLATES,
  });
}
'@

Write-Utf8NoBom "src/app/api/content-hq/visual-templates/route.ts" $registryRoute

$visualPage = @'
import { VISUAL_TEMPLATES } from "@/lib/content-hq-blueprint-v3";

export const dynamic = "force-dynamic";

export default function ContentHqVisualsPage() {
  const sources = [
    "dex_screener",
    "gmgn",
    "memescope",
  ] as const;

  return (
    <main className="mx-auto min-h-screen w-full max-w-7xl px-4 py-8 lg:px-8">
      <div className="mb-8">
        <div className="text-xs uppercase tracking-[0.28em] text-zinc-500">
          Content HQ
        </div>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
          Visual Templates
        </h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
          1600x900 deterministic layouts. Source + content type + anti-repeat history select the visual.
        </p>
      </div>

      <div className="space-y-10">
        {sources.map((source) => {
          const templates =
            VISUAL_TEMPLATES.filter(
              (item) =>
                item.source === source,
            );

          return (
            <section key={source}>
              <h2 className="mb-4 text-xl font-medium text-white">
                {source}
              </h2>

              <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                {templates.map(
                  (template) => (
                    <article
                      key={
                        template.id
                      }
                      className="rounded-2xl border border-white/8 bg-white/[0.025] p-5"
                    >
                      <div className="text-sm font-medium text-white">
                        {template.id}
                      </div>

                      <p className="mt-3 text-sm leading-6 text-zinc-500">
                        {template.description}
                      </p>

                      <div className="mt-4 flex flex-wrap gap-2">
                        {template.contentTypes.map(
                          (type) => (
                            <span
                              key={type}
                              className="rounded-full border border-white/10 px-2.5 py-1 text-[11px] text-zinc-400"
                            >
                              {type}
                            </span>
                          ),
                        )}
                      </div>
                    </article>
                  ),
                )}
              </div>
            </section>
          );
        })}
      </div>
    </main>
  );
}
'@

Write-Utf8NoBom "src/app/content-hq/visuals/page.tsx" $visualPage

$readme = @'
# MemeScope Content HQ Blueprint V3

This stage applies the final visual blueprint while preserving the existing queue, preview, scheduler, Telegram and X-publishing foundation.

Implemented:

- 1600x900 output.
- 6 DEX layouts.
- 6 GMGN layouts.
- 12 MemeScope layouts.
- Template rotation based on queue history.
- No consecutive visual reuse when alternatives exist.
- DEX real screenshot first, deterministic fallback when Cloudflare blocks it.
- GMGN real screenshot first.
- GMGN always has an image; if the server browser cannot access GMGN, MemeScope creates a clearly labeled fallback and does not fabricate wallet/holder values.
- MemeScope source now has multiple layouts, including Before The Move, Runner, Call Journey, Weekly and Hall of Calls.
- Added smart_money, call_journey and hall_of_calls content types.
- Existing text-only flow remains unchanged.
- Large multi-platform demo matrix expanded.
- Visual template registry at /content-hq/visuals.

Important limitation:

Production wallet/holder/smart-money events must still come from trustworthy numeric wallet/holder data. This visual stage does not invent those signals. Demo mode may exercise the visual types without publishing them to X.

No AI is used.
'@

Write-Utf8NoBom "README-MEMESCOPE-CONTENT-HQ-BLUEPRINT-V3.md" $readme

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " Blueprint V3 installed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host "DEX templates       : 6" -ForegroundColor Cyan
Write-Host "GMGN templates      : 6" -ForegroundColor Cyan
Write-Host "MemeScope templates : 12" -ForegroundColor Cyan
Write-Host "Backup               : $backupDir" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Run next:" -ForegroundColor Yellow
Write-Host " npm run typecheck"
Write-Host " npm run build"
