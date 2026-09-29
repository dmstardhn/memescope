$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Full([string]$p) { Join-Path $root $p }
function WriteUtf8([string]$rel, [string]$text) {
  $path = Full $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path, $text, $utf8)
  Write-Host "WRITE $rel" -ForegroundColor Green
}

if (!(Test-Path (Full "package.json"))) { throw "Run this from the memecoin-analyst project root." }

$cronPath = Full "src\app\api\telegram\cron\route.ts"
$webhookPath = Full "src\app\api\telegram\webhook\route.ts"

foreach ($p in @($cronPath, $webhookPath)) {
  if (!(Test-Path $p)) { throw "Missing required file: $p" }
}

$cronText = [System.IO.File]::ReadAllText($cronPath)
$webhookText = [System.IO.File]::ReadAllText($webhookPath)

if (!$cronText.Contains("/api/content-hq/process") -and !$cronText.Contains("/api/content-hq-v4/process")) {
  throw "Preflight stopped: old Content HQ process URL was not found in telegram cron route."
}
if (!$webhookText.Contains("export async function POST")) {
  throw "Preflight stopped: Telegram webhook POST handler was not found."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-ContentHQ-V4-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item $cronPath (Join-Path $backup "telegram-cron-route.ts") -Force
Copy-Item $webhookPath (Join-Path $backup "telegram-webhook-route.ts") -Force

Write-Host ""
Write-Host "MemeScope Content HQ V4" -ForegroundColor Cyan
Write-Host "Content-only replacement. Scanner/signals/calls remain untouched." -ForegroundColor Cyan
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""

npm install sharp @neondatabase/serverless
if ($LASTEXITCODE -ne 0) { throw "npm install failed." }

$dbFile = @'
import "server-only";
import { neon } from "@neondatabase/serverless";

export type ContentType =
  | "market_observation"
  | "token_watch"
  | "chart_setup"
  | "token_update"
  | "before_move"
  | "call_journey"
  | "daily_recap"
  | "weekly_recap";

export type V4Settings = {
  manualApproval: boolean;
  historyResetAt: string;
  maxPostsPerDay: number;
  minGapMinutes: number;
  brandingPct: number;
  tokenWatchPct: number;
  mix: Record<ContentType, number>;
};

function client() {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}

export async function ensureV4Schema() {
  const sql = client();

  await sql`
    CREATE TABLE IF NOT EXISTS memescope_content_v4_settings (
      id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
      manual_approval BOOLEAN NOT NULL DEFAULT TRUE,
      history_reset_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      max_posts_per_day INTEGER NOT NULL DEFAULT 5,
      min_gap_minutes INTEGER NOT NULL DEFAULT 40,
      branding_pct INTEGER NOT NULL DEFAULT 20,
      token_watch_pct INTEGER NOT NULL DEFAULT 5,
      mix_json JSONB NOT NULL DEFAULT
        '{"market_observation":25,"token_watch":5,"chart_setup":35,"token_update":20,"before_move":7,"call_journey":3,"daily_recap":2,"weekly_recap":3}'::jsonb,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `;

  await sql`
    INSERT INTO memescope_content_v4_settings (id)
    VALUES (1)
    ON CONFLICT (id) DO NOTHING
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS memescope_content_v4_queue (
      id BIGSERIAL PRIMARY KEY,
      event_key TEXT NOT NULL UNIQUE,
      token_address TEXT,
      pair_address TEXT,
      symbol TEXT,
      content_type TEXT NOT NULL,
      visual_style TEXT,
      caption_template TEXT NOT NULL,
      caption TEXT NOT NULL,
      reason TEXT,
      first_market_cap NUMERIC,
      current_market_cap NUMERIC,
      multiple NUMERIC,
      image_base64 TEXT,
      image_mime TEXT,
      branded BOOLEAN NOT NULL DEFAULT FALSE,
      status TEXT NOT NULL DEFAULT 'queued',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      approved_at TIMESTAMPTZ,
      scheduled_at TIMESTAMPTZ,
      published_at TIMESTAMPTZ,
      x_post_id TEXT
    )
  `;

  await sql`
    CREATE INDEX IF NOT EXISTS memescope_content_v4_queue_created_idx
    ON memescope_content_v4_queue (created_at DESC)
  `;

  await sql`
    CREATE INDEX IF NOT EXISTS memescope_content_v4_queue_token_idx
    ON memescope_content_v4_queue (token_address, created_at DESC)
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS memescope_content_v4_snapshots (
      token_address TEXT PRIMARY KEY,
      pair_address TEXT,
      symbol TEXT,
      first_detected_at TIMESTAMPTZ NOT NULL,
      first_market_cap NUMERIC,
      first_price NUMERIC,
      first_liquidity NUMERIC,
      first_volume NUMERIC,
      source_call_id TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `;
}

export async function getV4Settings(): Promise<V4Settings> {
  await ensureV4Schema();
  const sql = client();
  const rows = await sql`
    SELECT *
    FROM memescope_content_v4_settings
    WHERE id = 1
    LIMIT 1
  `;
  const row = rows[0] as Record<string, unknown>;
  const rawMix = (row.mix_json ?? {}) as Record<string, unknown>;

  const mix: Record<ContentType, number> = {
    market_observation: Number(rawMix.market_observation ?? 25),
    token_watch: Number(rawMix.token_watch ?? 5),
    chart_setup: Number(rawMix.chart_setup ?? 35),
    token_update: Number(rawMix.token_update ?? 20),
    before_move: Number(rawMix.before_move ?? 7),
    call_journey: Number(rawMix.call_journey ?? 3),
    daily_recap: Number(rawMix.daily_recap ?? 2),
    weekly_recap: Number(rawMix.weekly_recap ?? 3),
  };

  return {
    manualApproval: Boolean(row.manual_approval),
    historyResetAt: new Date(String(row.history_reset_at)).toISOString(),
    maxPostsPerDay: Number(row.max_posts_per_day ?? 5),
    minGapMinutes: Number(row.min_gap_minutes ?? 40),
    brandingPct: Number(row.branding_pct ?? 20),
    tokenWatchPct: Number(row.token_watch_pct ?? 5),
    mix,
  };
}

export async function setManualApproval(enabled: boolean) {
  await ensureV4Schema();
  const sql = client();
  await sql`
    UPDATE memescope_content_v4_settings
    SET manual_approval = ${enabled},
        updated_at = NOW()
    WHERE id = 1
  `;
}

export async function resetV4History() {
  await ensureV4Schema();
  const sql = client();
  const rows = await sql`
    UPDATE memescope_content_v4_settings
    SET history_reset_at = NOW(),
        updated_at = NOW()
    WHERE id = 1
    RETURNING history_reset_at
  `;

  await sql`
    UPDATE memescope_content_v4_queue
    SET status = 'archived_before_reset'
    WHERE created_at < (
      SELECT history_reset_at
      FROM memescope_content_v4_settings
      WHERE id = 1
    )
      AND status IN ('queued','draft','approved','scheduled','rejected','failed')
  `;

  return new Date(String(rows[0]?.history_reset_at)).toISOString();
}

export async function v4Status() {
  const settings = await getV4Settings();
  const sql = client();

  const rows = await sql`
    SELECT
      COUNT(*) FILTER (WHERE status = 'queued')::INTEGER AS queued,
      COUNT(*) FILTER (WHERE status = 'approved')::INTEGER AS approved,
      COUNT(*) FILTER (WHERE status = 'published')::INTEGER AS published,
      COUNT(*) FILTER (WHERE status = 'failed')::INTEGER AS failed
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
  `;

  return {
    settings,
    counts: {
      queued: Number(rows[0]?.queued ?? 0),
      approved: Number(rows[0]?.approved ?? 0),
      published: Number(rows[0]?.published ?? 0),
      failed: Number(rows[0]?.failed ?? 0),
    },
  };
}

export function sqlV4() {
  return client();
}
'@

WriteUtf8 "src/lib/content-hq-v4/db.ts" $dbFile

$rendererFile = @'
import "server-only";
import sharp from "sharp";
import type { ContentType } from "./db";

export type Candle = { timestamp: number; open: number; high: number; low: number; close: number; volume: number };

export type RenderInput = {
  symbol: string;
  contentType: ContentType;
  visualStyle: string;
  firstMarketCap: number | null;
  currentMarketCap: number | null;
  multiple: number | null;
  liquidity: number | null;
  volume: number | null;
  candles: Candle[];
  historicCandles?: Candle[];
  branded: boolean;
};

function esc(value: string) {
  return value.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;");
}

function usd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  if (value >= 1e9) return `$${(value / 1e9).toFixed(2)}B`;
  if (value >= 1e6) return `$${(value / 1e6).toFixed(2)}M`;
  if (value >= 1e3) return `$${(value / 1e3).toFixed(0)}K`;
  return `$${value.toFixed(0)}`;
}

function base() {
  return `<style>
  .brand{font-family:Arial,sans-serif;font-size:15px;fill:#79827f;font-weight:700;letter-spacing:2px}
  .ticker{font-family:Arial,sans-serif;font-size:42px;fill:#f3f5f4;font-weight:800}
  .title{font-family:Arial,sans-serif;font-size:26px;fill:#eef2f0;font-weight:700}
  .label{font-family:Arial,sans-serif;font-size:15px;fill:#7f8985}
  .value{font-family:Arial,sans-serif;font-size:28px;fill:#eef2f0;font-weight:650}
  .small{font-family:Arial,sans-serif;font-size:14px;fill:#8b9591}
  .green{fill:#77d6ad}
  </style>`;
}

function lineChart(data: Candle[], x: number, y: number, w: number, h: number, stroke = "#d7dfdc") {
  if (data.length < 2) {
    return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0d0f0e" stroke="#252a28"/>
      <text x="${x+w/2}" y="${y+h/2}" text-anchor="middle" class="small">chart unavailable</text>`;
  }
  const values = data.map(d => d.close).filter(Number.isFinite);
  const min = Math.min(...values), max = Math.max(...values);
  const range = Math.max(max - min, max * 0.02, 1e-12);
  const pts = data.map((d,i) => {
    const px = x + 24 + (i / (data.length - 1)) * (w - 48);
    const py = y + h - 24 - ((d.close - min) / range) * (h - 48);
    return `${px.toFixed(1)},${py.toFixed(1)}`;
  });
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0d0f0e" stroke="#252a28"/>
    <line x1="${x+20}" y1="${y+h*.25}" x2="${x+w-20}" y2="${y+h*.25}" stroke="#181b1a"/>
    <line x1="${x+20}" y1="${y+h*.50}" x2="${x+w-20}" y2="${y+h*.50}" stroke="#181b1a"/>
    <line x1="${x+20}" y1="${y+h*.75}" x2="${x+w-20}" y2="${y+h*.75}" stroke="#181b1a"/>
    <polyline points="${pts.join(" ")}" fill="none" stroke="${stroke}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
}

async function asWebp(svg: string) {
  return sharp(Buffer.from(svg,"utf8")).webp({quality:90}).toBuffer();
}

export const CHART_STYLES = [
  "pure_chart",
  "level_setup",
  "first_spotted",
  "minimal_metrics",
  "performance",
  "split_before_now",
] as const;

export async function renderContent(input: RenderInput) {
  if (input.contentType === "market_observation") return null;

  const brand = input.branded
    ? `<text x="70" y="58" class="brand">MEMESCOPE</text>`
    : `<text x="1518" y="856" text-anchor="end" class="small">ms</text>`;

  if (input.visualStyle === "split_before_now") {
    if (!input.historicCandles || input.historicCandles.length < 2) return null;
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="118" class="ticker">$${esc(input.symbol)}</text>
      <text x="70" y="176" class="title">FIRST SPOTTED</text>
      <text x="818" y="176" class="title">NOW</text>
      ${lineChart(input.historicCandles,70,210,712,470,"#b7c0bd")}
      ${lineChart(input.candles,818,210,712,470,"#75d4ac")}
      <rect x="70" y="720" width="712" height="104" rx="10" fill="#101211" stroke="#272c2a"/>
      <text x="100" y="758" class="label">first market cap</text>
      <text x="100" y="800" class="value">${esc(usd(input.firstMarketCap))}</text>
      <rect x="818" y="720" width="712" height="104" rx="10" fill="#101211" stroke="#272c2a"/>
      <text x="848" y="758" class="label">current / move</text>
      <text x="848" y="800" class="value green">${esc(usd(input.currentMarketCap))} / ${esc((input.multiple ?? 0).toFixed(2))}x</text>
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.contentType === "call_journey") {
    const call = input.firstMarketCap ?? 0;
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="118" class="ticker">$${esc(input.symbol)}</text>
      <text x="70" y="170" class="title">CALL JOURNEY</text>
      <line x1="210" y1="285" x2="1390" y2="285" stroke="#353b38" stroke-width="3"/>
      <circle cx="210" cy="285" r="13" fill="#d7dfdc"/><circle cx="600" cy="285" r="13" fill="#a9bdb5"/>
      <circle cx="990" cy="285" r="13" fill="#86caaa"/><circle cx="1390" cy="285" r="15" fill="#75d4ac"/>
      <text x="210" y="235" text-anchor="middle" class="label">DETECTED</text>
      <text x="600" y="235" text-anchor="middle" class="label">2X</text>
      <text x="990" y="235" text-anchor="middle" class="label">5X</text>
      <text x="1390" y="235" text-anchor="middle" class="label">CURRENT</text>
      <text x="210" y="345" text-anchor="middle" class="value">${esc(usd(call||null))}</text>
      <text x="600" y="345" text-anchor="middle" class="value">${esc(usd(call?call*2:null))}</text>
      <text x="990" y="345" text-anchor="middle" class="value">${esc(usd(call?call*5:null))}</text>
      <text x="1390" y="345" text-anchor="middle" class="value green">${esc((input.multiple ?? 0).toFixed(2))}x</text>
      ${lineChart(input.candles,70,420,1460,330,"#75d4ac")}
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.contentType === "daily_recap" || input.contentType === "weekly_recap") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="122" class="ticker">${input.contentType === "weekly_recap" ? "WEEKLY TAPE" : "DAILY TAPE"}</text>
      <rect x="70" y="190" width="1460" height="540" rx="14" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="120" y="285" class="label">standout move</text>
      <text x="120" y="342" class="title">$${esc(input.symbol)}</text>
      <text x="120" y="410" class="value green">${esc((input.multiple ?? 0).toFixed(2))}x</text>
      <text x="580" y="285" class="label">first MC</text>
      <text x="580" y="342" class="value">${esc(usd(input.firstMarketCap))}</text>
      <text x="580" y="430" class="label">current MC</text>
      <text x="580" y="487" class="value">${esc(usd(input.currentMarketCap))}</text>
      ${lineChart(input.candles,980,245,480,360,"#75d4ac")}
      <text x="70" y="816" class="small">tracked by MemeScope</text>
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "pure_chart") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="118" class="ticker">$${esc(input.symbol)} / SOL</text>
      ${lineChart(input.candles,70,165,1460,630,"#d8e0dd")}
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "level_setup") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="118" class="ticker">$${esc(input.symbol)}</text>
      ${lineChart(input.candles,70,165,1460,630,"#d8e0dd")}
      <line x1="180" y1="430" x2="1420" y2="430" stroke="#7f8985" stroke-width="2" stroke-dasharray="8 8"/>
      <text x="1420" y="416" text-anchor="end" class="small">watching this area</text>
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "first_spotted") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="118" class="ticker">$${esc(input.symbol)}</text>
      ${lineChart(input.candles,70,165,1460,560,"#d8e0dd")}
      <text x="120" y="775" class="label">first spotted</text>
      <text x="120" y="818" class="value">${esc(usd(input.firstMarketCap))}</text>
      <text x="1480" y="775" text-anchor="end" class="label">current</text>
      <text x="1480" y="818" text-anchor="end" class="value green">${esc(usd(input.currentMarketCap))}</text>
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "minimal_metrics") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="118" class="ticker">$${esc(input.symbol)}</text>
      ${lineChart(input.candles,70,165,1040,620,"#d8e0dd")}
      <rect x="1150" y="165" width="380" height="620" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="1190" y="235" class="label">market cap</text><text x="1190" y="278" class="value">${esc(usd(input.currentMarketCap))}</text>
      <text x="1190" y="385" class="label">liquidity</text><text x="1190" y="428" class="value">${esc(usd(input.liquidity))}</text>
      <text x="1190" y="535" class="label">volume</text><text x="1190" y="578" class="value">${esc(usd(input.volume))}</text>
    </svg>`;
    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
    <text x="70" y="118" class="ticker">$${esc(input.symbol)}</text>
    <text x="70" y="178" class="title">${esc((input.multiple ?? 0).toFixed(2))}x since detection</text>
    ${lineChart(input.candles,70,220,1460,500,"#75d4ac")}
    <rect x="70" y="755" width="1460" height="78" rx="10" fill="#101211" stroke="#272c2a"/>
    <text x="105" y="805" class="small">first ${esc(usd(input.firstMarketCap))}</text>
    <text x="1495" y="805" text-anchor="end" class="small">current ${esc(usd(input.currentMarketCap))}</text>
  </svg>`;
  return { buffer: await asWebp(svg), mime: "image/webp" };
}
'@

WriteUtf8 "src/lib/content-hq-v4/render.ts" $rendererFile

$engineFile = @'
import "server-only";
import {
  ensureV4Schema,
  getV4Settings,
  sqlV4,
  type ContentType,
} from "./db";
import {
  CHART_STYLES,
  renderContent,
  type Candle,
} from "./render";

type RawRow = Record<string, unknown>;

type Market = {
  pairAddress: string | null;
  currentMc: number | null;
  liquidity: number | null;
  volume: number | null;
};

type Candidate = {
  eventKey: string;
  tokenAddress: string | null;
  pairAddress: string | null;
  symbol: string;
  contentType: ContentType;
  visualStyle: string;
  captionTemplate: string;
  caption: string;
  reason: string;
  firstMc: number | null;
  currentMc: number | null;
  multiple: number | null;
  liquidity: number | null;
  volume: number | null;
  branded: boolean;
  candles: Candle[];
  historicCandles?: Candle[];
};

const CAPTIONS: Record<ContentType, string[]> = {
  market_observation: [
    "small caps getting more active today.\n\nwatching volume before chasing anything.",
    "market activity is picking up a bit.\n\nstill being selective.",
    "not much worth forcing here.\n\nwaiting for cleaner setups.",
  ],
  token_watch: [
    "$TOKEN starting to get interesting here.\n\nwatching the next push.",
    "$TOKEN\n\ninteresting structure developing.\n\nnot there yet.",
  ],
  chart_setup: [
    "$TOKEN\n\nwatching this structure.",
    "$TOKEN starting to look interesting around this area.",
    "$TOKEN\n\nwatching for a clean continuation.",
  ],
  token_update: [
    "$TOKEN update.\n\nnice reaction from the level.",
    "$TOKEN still holding up well.\n\nwatching continuation.",
    "$TOKEN\n\nclean move from the area.",
  ],
  before_move: [
    "$TOKEN\n\nfirst spotted around $FIRST_MC.\nnow sitting near $CURRENT_MC.\n\n$MULTIPLE since detection.",
    "$TOKEN before the move.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE.",
  ],
  call_journey: [
    "$TOKEN journey so far.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE since detection.",
    "$TOKEN kept developing after the first detection.\n\nnow at $MULTIPLE.",
  ],
  daily_recap: [
    "today's tape.\n\n$TOKEN was the standout tracked move at $MULTIPLE.",
  ],
  weekly_recap: [
    "weekly tape.\n\n$TOKEN was one of the stronger tracked moves at $MULTIPLE.",
  ],
};

function num(v: unknown): number | null {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function str(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  return s ? s : null;
}

function pick(row: RawRow, keys: string[]) {
  for (const key of keys) if (row[key] !== undefined && row[key] !== null) return row[key];
  return null;
}

function compactUsd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  if (value >= 1e9) return `$${(value/1e9).toFixed(2)}B`;
  if (value >= 1e6) return `$${(value/1e6).toFixed(2)}M`;
  if (value >= 1e3) return `$${(value/1e3).toFixed(0)}K`;
  return `$${value.toFixed(0)}`;
}

function fill(template: string, symbol: string, firstMc: number | null, currentMc: number | null, multiple: number | null) {
  return template
    .replaceAll("$TOKEN", `$${symbol}`)
    .replaceAll("$FIRST_MC", compactUsd(firstMc))
    .replaceAll("$CURRENT_MC", compactUsd(currentMc))
    .replaceAll("$MULTIPLE", multiple ? `${multiple.toFixed(2)}x` : "N/A");
}

async function market(tokenAddress: string, preferredPair: string | null): Promise<Market> {
  try {
    const r = await fetch(`https://api.dexscreener.com/latest/dex/tokens/${encodeURIComponent(tokenAddress)}`, {
      headers: { Accept: "application/json" },
      cache: "no-store",
    });
    if (!r.ok) throw new Error("DEX API failed");
    const body = await r.json() as {pairs?: Array<Record<string, any>>};
    const pairs = (body.pairs ?? []).filter(p => p.chainId === "solana");
    const p = pairs.find(x => preferredPair && x.pairAddress === preferredPair)
      ?? pairs.sort((a,b) => Number(b.liquidity?.usd ?? 0)-Number(a.liquidity?.usd ?? 0))[0];
    if (!p) throw new Error("No Solana pair");
    return {
      pairAddress: str(p.pairAddress),
      currentMc: num(p.marketCap ?? p.fdv),
      liquidity: num(p.liquidity?.usd),
      volume: num(p.volume?.h24),
    };
  } catch {
    return { pairAddress: preferredPair, currentMc: null, liquidity: null, volume: null };
  }
}

async function candleSeries(pair: string | null, beforeTimestamp?: number) {
  if (!pair) return [] as Candle[];
  try {
    const before = beforeTimestamp ? `&before_timestamp=${Math.floor(beforeTimestamp/1000)}` : "";
    const r = await fetch(
      `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(pair)}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base${before}`,
      { headers: { Accept: "application/json;version=20230203" }, cache: "no-store" },
    );
    if (!r.ok) return [];
    const body = await r.json() as {data?: {attributes?: {ohlcv_list?: number[][]}}};
    return (body.data?.attributes?.ohlcv_list ?? [])
      .map(row => ({
        timestamp: Number(row[0]) * 1000,
        open: Number(row[1]),
        high: Number(row[2]),
        low: Number(row[3]),
        close: Number(row[4]),
        volume: Number(row[5] ?? 0),
      }))
      .filter(x => Number.isFinite(x.close) && x.close > 0)
      .sort((a,b) => a.timestamp-b.timestamp);
  } catch {
    return [];
  }
}

async function recentCalls() {
  const sql = sqlV4();
  const rows = await sql`SELECT * FROM memescope_call_story LIMIT 60`;
  return (rows as RawRow[]).sort((a,b) => {
    const ta = new Date(String(pick(a,["created_at","detected_at","called_at","signal_time"]) ?? 0)).getTime();
    const tb = new Date(String(pick(b,["created_at","detected_at","called_at","signal_time"]) ?? 0)).getTime();
    return tb-ta;
  });
}

async function historyShare() {
  const settings = await getV4Settings();
  const sql = sqlV4();
  const rows = await sql`
    SELECT content_type, COUNT(*)::INTEGER AS count
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    GROUP BY content_type
  `;
  const counts = new Map<string, number>();
  let total = 0;
  for (const row of rows) {
    const c = Number(row.count ?? 0);
    counts.set(String(row.content_type), c);
    total += c;
  }
  return { settings, counts, total };
}

async function previouslyPosted(tokenAddress: string) {
  const settings = await getV4Settings();
  const sql = sqlV4();
  const rows = await sql`
    SELECT content_type, created_at
    FROM memescope_content_v4_queue
    WHERE token_address = ${tokenAddress}
      AND created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 5
  `;
  return rows as RawRow[];
}

async function saveFirstSnapshot(row: RawRow, token: string, symbol: string, pair: string | null, firstMc: number | null, detectedAt: Date) {
  const sql = sqlV4();
  await sql`
    INSERT INTO memescope_content_v4_snapshots (
      token_address, pair_address, symbol, first_detected_at,
      first_market_cap, source_call_id
    )
    VALUES (
      ${token}, ${pair}, ${symbol}, ${detectedAt.toISOString()}::timestamptz,
      ${firstMc}, ${str(pick(row,["public_id","call_id","id"]))}
    )
    ON CONFLICT (token_address) DO NOTHING
  `;
}

function chooseCaption(type: ContentType, lastTemplate: string | null) {
  const list = CAPTIONS[type];
  const candidates = list.map((text,index) => ({key:`${type}_${String(index+1).padStart(2,"0")}`,text}));
  return candidates.find(c => c.key !== lastTemplate) ?? candidates[0];
}

function nextChartStyle(lastStyle: string | null) {
  const eligible = ["pure_chart","level_setup","first_spotted","minimal_metrics","performance"];
  const index = Math.max(-1, eligible.indexOf(lastStyle ?? ""));
  return eligible[(index + 1) % eligible.length];
}

async function lastUsed() {
  const settings = await getV4Settings();
  const sql = sqlV4();
  const rows = await sql`
    SELECT visual_style, caption_template
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 1
  `;
  return {
    visualStyle: rows.length ? str(rows[0].visual_style) : null,
    captionTemplate: rows.length ? str(rows[0].caption_template) : null,
  };
}

async function buildTokenCandidates(): Promise<Candidate[]> {
  const calls = await recentCalls();
  const last = await lastUsed();
  const result: Candidate[] = [];

  for (const row of calls.slice(0, 12)) {
    const token = str(pick(row,["token_address","mint_address","mint","address","token"]));
    if (!token) continue;

    const symbol = str(pick(row,["symbol","token_symbol","ticker"])) ?? "TOKEN";
    const preferredPair = str(pick(row,["pair_address","pool_address","pair"]));
    const firstMc = num(pick(row,["first_market_cap","call_market_cap","initial_market_cap","market_cap_at_call","market_cap"]));
    const detectedRaw = pick(row,["created_at","detected_at","called_at","signal_time"]);
    const detectedAt = detectedRaw ? new Date(String(detectedRaw)) : new Date();
    const live = await market(token, preferredPair);
    const pair = live.pairAddress ?? preferredPair;
    await saveFirstSnapshot(row, token, symbol, pair, firstMc, detectedAt);

    const currentMc = live.currentMc;
    const multiple = firstMc && currentMc && firstMc > 0 ? currentMc / firstMc : null;
    const candles = await candleSeries(pair);
    if (candles.length < 2) continue;

    const previous = await previouslyPosted(token);
    const hasStory = previous.length > 0;
    const latestAgeMinutes = previous.length
      ? (Date.now() - new Date(String(previous[0].created_at)).getTime()) / 60000
      : Infinity;

    let type: ContentType = hasStory ? "token_update" : "chart_setup";
    let style = nextChartStyle(last.visualStyle);
    let reason = hasStory ? "tracked token developed after an earlier post" : "fresh chart setup from a MemeScope tracked call";
    let branded = false;
    let historicCandles: Candle[] | undefined;

    if (multiple !== null && multiple >= 5) {
      type = "call_journey";
      style = "journey";
      branded = true;
      reason = "tracked call reached a major journey milestone";
    } else if (multiple !== null && multiple >= 2.5) {
      historicCandles = await candleSeries(pair, detectedAt.getTime() + 10 * 60 * 1000);
      if (historicCandles.length >= 2) {
        type = "before_move";
        style = "split_before_now";
        branded = true;
        reason = "move exceeded the existing Before The Move threshold with a real historical chart";
      }
    } else if (hasStory && latestAgeMinutes < 90) {
      continue;
    } else if (hasStory && multiple !== null && multiple < 1.25) {
      continue;
    }

    const cap = chooseCaption(type, last.captionTemplate);
    result.push({
      eventKey: `v4:${type}:${token}:${Math.floor((currentMc ?? 0)/1000)}:${new Date().toISOString().slice(0,13)}`,
      tokenAddress: token,
      pairAddress: pair,
      symbol,
      contentType: type,
      visualStyle: style,
      captionTemplate: cap.key,
      caption: fill(cap.text, symbol, firstMc, currentMc, multiple),
      reason,
      firstMc,
      currentMc,
      multiple,
      liquidity: live.liquidity,
      volume: live.volume,
      branded,
      candles,
      historicCandles,
    });
  }

  return result;
}

async function maybeObservation(): Promise<Candidate | null> {
  const calls = await recentCalls();
  if (!calls.length) return null;
  const last = await lastUsed();
  const active = Math.min(calls.length, 12);
  const quiet = active <= 2;
  const cap = chooseCaption("market_observation", last.captionTemplate);
  const template = quiet ? CAPTIONS.market_observation[2] : cap.text;
  return {
    eventKey: `v4:market_observation:${new Date().toISOString().slice(0,10)}:${quiet?"quiet":"active"}`,
    tokenAddress: null,
    pairAddress: null,
    symbol: "",
    contentType: "market_observation",
    visualStyle: "text_only",
    captionTemplate: quiet ? "market_observation_03" : cap.key,
    caption: template,
    reason: quiet ? "few tracked calls are active" : "tracked market activity is elevated",
    firstMc: null,
    currentMc: null,
    multiple: null,
    liquidity: null,
    volume: null,
    branded: false,
    candles: [],
  };
}

function targetDeficit(type: ContentType, total: number, count: number, target: number) {
  if (total === 0) return target;
  return target - (count / total) * 100;
}

export async function processContentHqV4() {
  await ensureV4Schema();
  const { settings, counts, total } = await historyShare();
  const sql = sqlV4();

  const todayRows = await sql`
    SELECT COUNT(*)::INTEGER AS count
    FROM memescope_content_v4_queue
    WHERE created_at >= date_trunc('day', NOW() AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'Asia/Jakarta'
      AND status <> 'archived_before_reset'
  `;
  if (Number(todayRows[0]?.count ?? 0) >= settings.maxPostsPerDay) {
    return { ok: true, created: 0, reason: "daily-limit" };
  }

  const lastRows = await sql`
    SELECT created_at
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status <> 'archived_before_reset'
    ORDER BY created_at DESC
    LIMIT 1
  `;
  if (lastRows.length) {
    const gap = (Date.now() - new Date(String(lastRows[0].created_at)).getTime()) / 60000;
    if (gap < settings.minGapMinutes) return { ok: true, created: 0, reason: "minimum-gap" };
  }

  const candidates = await buildTokenCandidates();
  const observation = await maybeObservation();
  if (observation) candidates.push(observation);

  if (!candidates.length) return { ok: true, created: 0, reason: "no-worthy-event" };

  const filtered = candidates.filter(c => {
    if (c.contentType !== "token_watch") return true;
    const share = total ? ((counts.get("token_watch") ?? 0) / total) * 100 : 0;
    return share < settings.tokenWatchPct;
  });

  const ranked = filtered.sort((a,b) => {
    const da = targetDeficit(a.contentType,total,counts.get(a.contentType)??0,settings.mix[a.contentType]??0);
    const db = targetDeficit(b.contentType,total,counts.get(b.contentType)??0,settings.mix[b.contentType]??0);
    const pa = a.contentType === "call_journey" ? 100 :
      a.contentType === "before_move" ? 90 :
      a.contentType === "token_update" ? 75 :
      a.contentType === "chart_setup" ? 65 :
      a.contentType === "token_watch" ? 40 : 25;
    const pb = b.contentType === "call_journey" ? 100 :
      b.contentType === "before_move" ? 90 :
      b.contentType === "token_update" ? 75 :
      b.contentType === "chart_setup" ? 65 :
      b.contentType === "token_watch" ? 40 : 25;
    return (pb + db) - (pa + da);
  });

  const selected = ranked[0];
  const visual = await renderContent({
    symbol: selected.symbol,
    contentType: selected.contentType,
    visualStyle: selected.visualStyle,
    firstMarketCap: selected.firstMc,
    currentMarketCap: selected.currentMc,
    multiple: selected.multiple,
    liquidity: selected.liquidity,
    volume: selected.volume,
    candles: selected.candles,
    historicCandles: selected.historicCandles,
    branded: selected.branded,
  });

  if (selected.contentType !== "market_observation" && !visual) {
    return { ok: true, created: 0, reason: "visual-not-safe-to-publish" };
  }

  const status = settings.manualApproval ? "queued" : "approved";
  try {
    const rows = await sql`
      INSERT INTO memescope_content_v4_queue (
        event_key, token_address, pair_address, symbol,
        content_type, visual_style, caption_template, caption,
        reason, first_market_cap, current_market_cap, multiple,
        image_base64, image_mime, branded, status
      )
      VALUES (
        ${selected.eventKey}, ${selected.tokenAddress}, ${selected.pairAddress}, ${selected.symbol},
        ${selected.contentType}, ${selected.visualStyle}, ${selected.captionTemplate}, ${selected.caption},
        ${selected.reason}, ${selected.firstMc}, ${selected.currentMc}, ${selected.multiple},
        ${visual ? visual.buffer.toString("base64") : null}, ${visual?.mime ?? null},
        ${selected.branded}, ${status}
      )
      RETURNING id, content_type, symbol, visual_style, caption, status
    `;
    return { ok: true, created: 1, item: rows[0] };
  } catch (error) {
    if (String(error).toLowerCase().includes("duplicate")) {
      return { ok: true, created: 0, reason: "duplicate-event" };
    }
    throw error;
  }
}
'@

WriteUtf8 "src/lib/content-hq-v4/engine.ts" $engineFile

$adminFile = @'
import "server-only";
import {
  getV4Settings,
  resetV4History,
  setManualApproval,
  v4Status,
} from "./db";

type TelegramUpdate = {
  callback_query?: {
    id: string;
    data?: string;
    from?: { id?: number };
    message?: { chat?: { id?: number }; message_id?: number };
  };
  message?: {
    text?: string;
    from?: { id?: number };
    chat?: { id?: number };
  };
};

function token() {
  const value = process.env.TELEGRAM_BOT_TOKEN?.trim();
  if (!value) throw new Error("TELEGRAM_BOT_TOKEN missing.");
  return value;
}

function ownerId() {
  const value = Number(process.env.TELEGRAM_OWNER_ID);
  return Number.isFinite(value) ? value : null;
}

async function api(method: string, body: Record<string, unknown>) {
  const response = await fetch(`https://api.telegram.org/bot${token()}/${method}`, {
    method: "POST",
    headers: {"content-type":"application/json"},
    body: JSON.stringify(body),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Telegram ${method} failed: ${response.status}`);
  return response.json();
}

function menuKeyboard(manual: boolean) {
  return {
    inline_keyboard: [
      [
        { text: "Status", callback_data: "ch4:status" },
        { text: manual ? "Manual Approval: ON" : "Manual Approval: OFF", callback_data: "ch4:toggle_manual" },
      ],
      [
        { text: "Reset Content History", callback_data: "ch4:reset" },
      ],
    ],
  };
}

async function sendMenu(chatId: number) {
  const state = await v4Status();
  const s = state.settings;
  const text =
`MemeScope - Content HQ V4

Mode: ${s.manualApproval ? "MANUAL APPROVAL" : "AUTO APPROVE"}
Queued: ${state.counts.queued}
Approved: ${state.counts.approved}
Published: ${state.counts.published}
Failed: ${state.counts.failed}

History since: ${new Date(s.historyResetAt).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}

Content mix:
Text observation 25%
Chart setup 35%
Token update 20%
Token Watch max 5%
Before/Call Journey 10%
Daily/Weekly recap 5%

Explicit MemeScope branding target: 20%`;

  await api("sendMessage", {
    chat_id: chatId,
    text,
    reply_markup: menuKeyboard(s.manualApproval),
  });
}

export async function tryHandleContentHqAdminRequest(request: Request) {
  const secret = process.env.TELEGRAM_WEBHOOK_SECRET?.trim();
  if (secret) {
    const received = request.headers.get("x-telegram-bot-api-secret-token");
    if (received !== secret) return { handled: false };
  }

  let update: TelegramUpdate;
  try {
    update = await request.json() as TelegramUpdate;
  } catch {
    return { handled: false };
  }

  const messageText = update.message?.text?.trim();
  const callback = update.callback_query?.data?.trim();

  if (messageText !== "/contenthq" && !callback?.startsWith("ch4:")) {
    return { handled: false };
  }

  const userId = update.message?.from?.id ?? update.callback_query?.from?.id ?? null;
  const owner = ownerId();

  if (!owner || userId !== owner) {
    if (update.callback_query?.id) {
      await api("answerCallbackQuery", {
        callback_query_id: update.callback_query.id,
        text: "Owner only.",
        show_alert: true,
      }).catch(() => undefined);
    }
    return { handled: true };
  }

  const chatId = update.message?.chat?.id ?? update.callback_query?.message?.chat?.id;
  if (!chatId) return { handled: true };

  if (messageText === "/contenthq") {
    await sendMenu(chatId);
    return { handled: true };
  }

  if (callback === "ch4:status") {
    await api("answerCallbackQuery", { callback_query_id: update.callback_query!.id });
    await sendMenu(chatId);
    return { handled: true };
  }

  if (callback === "ch4:toggle_manual") {
    const current = await getV4Settings();
    await setManualApproval(!current.manualApproval);
    await api("answerCallbackQuery", {
      callback_query_id: update.callback_query!.id,
      text: `Manual Approval ${!current.manualApproval ? "ON" : "OFF"}`,
    });
    await sendMenu(chatId);
    return { handled: true };
  }

  if (callback === "ch4:reset") {
    await api("answerCallbackQuery", { callback_query_id: update.callback_query!.id });
    await api("sendMessage", {
      chat_id: chatId,
      text:
`RESET CONTENT HISTORY?

This resets Content HQ history, rotation counters, cooldown context and recap statistics.

It does NOT delete:
- MemeScope calls
- signal history
- market data
- Telegram configuration
- X configuration
- caption/visual code

Old Content HQ records remain archived for debugging.`,
      reply_markup: {
        inline_keyboard: [[
          { text: "CONFIRM RESET", callback_data: "ch4:reset_confirm" },
          { text: "CANCEL", callback_data: "ch4:cancel" },
        ]],
      },
    });
    return { handled: true };
  }

  if (callback === "ch4:reset_confirm") {
    const resetAt = await resetV4History();
    await api("answerCallbackQuery", {
      callback_query_id: update.callback_query!.id,
      text: "Content history reset.",
      show_alert: true,
    });
    await api("sendMessage", {
      chat_id: chatId,
      text: `Content history reset successfully.\n\nNew production history starts:\n${new Date(resetAt).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}`,
    });
    return { handled: true };
  }

  if (callback === "ch4:cancel") {
    await api("answerCallbackQuery", {
      callback_query_id: update.callback_query!.id,
      text: "Cancelled.",
    });
    return { handled: true };
  }

  return { handled: true };
}
'@

WriteUtf8 "src/lib/content-hq-v4/telegram-admin.ts" $adminFile

$processRoute = @'
import { NextResponse } from "next/server";
import { processContentHqV4 } from "@/lib/content-hq-v4/engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${secret}`;
}

export async function GET(request: Request) {
  if (!authorized(request)) return NextResponse.json({error:"Unauthorized"},{status:401});
  try {
    return NextResponse.json(await processContentHqV4());
  } catch (error) {
    console.error("Content HQ V4 process failed", error);
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}

export async function POST(request: Request) {
  return GET(request);
}
'@

WriteUtf8 "src/app/api/content-hq-v4/process/route.ts" $processRoute

$statusRoute = @'
import { NextResponse } from "next/server";
import { v4Status } from "@/lib/content-hq-v4/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    return NextResponse.json({ok:true, ...(await v4Status())});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}
'@
WriteUtf8 "src/app/api/content-hq-v4/status/route.ts" $statusRoute

$mediaRoute = @'
import { NextResponse } from "next/server";
import { sqlV4 } from "@/lib/content-hq-v4/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(_request: Request, context: {params: Promise<{id:string}>}) {
  const {id} = await context.params;
  const itemId = Number(id);
  if (!Number.isFinite(itemId)) return new NextResponse("Invalid id",{status:400});

  const sql = sqlV4();
  const rows = await sql`
    SELECT image_base64, image_mime
    FROM memescope_content_v4_queue
    WHERE id = ${itemId}
    LIMIT 1
  `;
  if (!rows.length || !rows[0].image_base64) return new NextResponse("No media",{status:404});

  return new NextResponse(Buffer.from(String(rows[0].image_base64),"base64"), {
    headers: {
      "content-type": String(rows[0].image_mime ?? "image/webp"),
      "cache-control": "private, max-age=60",
    },
  });
}
'@
WriteUtf8 "src/app/api/content-hq-v4/media/[id]/route.ts" $mediaRoute

# Patch cron to disable the old engine and use V4.
$cronText = [System.IO.File]::ReadAllText($cronPath)
$cronText = $cronText.Replace("/api/content-hq/process", "/api/content-hq-v4/process")
[System.IO.File]::WriteAllText($cronPath, $cronText, $utf8)
Write-Host "PATCH src/app/api/telegram/cron/route.ts" -ForegroundColor Green

# Minimal Telegram webhook interception using request.clone().
$webhookText = [System.IO.File]::ReadAllText($webhookPath)

if (!$webhookText.Contains('from "@/lib/content-hq-v4/telegram-admin"')) {
  $firstImport = $webhookText.IndexOf("import ")
  if ($firstImport -lt 0) { throw "Could not find import section in webhook." }
  $import = "import { tryHandleContentHqAdminRequest } from ""@/lib/content-hq-v4/telegram-admin"";`r`n"
  $webhookText = $webhookText.Insert($firstImport, $import)
}

if (!$webhookText.Contains("tryHandleContentHqAdminRequest(request.clone())")) {
  $match = [regex]::Match($webhookText, 'export\s+async\s+function\s+POST\s*\(\s*request\s*:\s*Request\s*\)\s*\{')
  if (!$match.Success) {
    throw "Could not safely patch Telegram webhook POST(request: Request). Original file remains backed up at $backup"
  }

  $insertAt = $match.Index + $match.Length
  $snippet = @'

  const contentHqAdmin = await tryHandleContentHqAdminRequest(request.clone());
  if (contentHqAdmin.handled) {
    return Response.json({ ok: true });
  }

'@
  $webhookText = $webhookText.Insert($insertAt, $snippet)
}

[System.IO.File]::WriteAllText($webhookPath, $webhookText, $utf8)
Write-Host "PATCH src/app/api/telegram/webhook/route.ts" -ForegroundColor Green

$readme = @'
# MemeScope Content HQ V4

Scope: content automation only.

This stage intentionally leaves scanner, signal engine, call tracking, public Telegram signal publishing, market terminal and other MemeScope systems untouched.

Active content families:
- Market Observation / text-only
- Token Watch (hard target <= 5%)
- Chart Setup
- Token Update / continuation
- Before The Move
- Call Journey
- Daily Tape
- Weekly Tape

Mix bias:
- Text-only observation: 25%
- Chart Setup: 35%
- Token Update: 20%
- Token Watch: 5% max
- Before The Move + Call Journey: 10%
- Daily + Weekly recap: 5%

Explicit MemeScope branding target: 20%.

Old Content HQ generation is disabled at the scheduler level. The existing legacy files are not deleted yet so rollback is safe; they are no longer called by the Telegram cron after this installer.

The new V4 engine:
- uses DEX Screener as market data, not as a screenshot requirement;
- uses GeckoTerminal candles;
- uses MemeScope call-story data;
- does not use GMGN;
- does not generate wallet/holder/smart-money content;
- does not use AI;
- creates multiple structurally different chart layouts;
- requires a real historical candle series for Before The Move.

Administrator bot:
- /contenthq opens the V4 control menu;
- Status;
- Manual Approval ON/OFF;
- Reset Content History with two-step owner-only confirmation.

Reset uses history_reset_at and archives pre-reset V4 queue state. It does not delete calls, signals or market data.
'@
WriteUtf8 "README-MEMESCOPE-CONTENT-HQ-V4.md" $readme

Write-Host ""
Write-Host "V4 content engine installed." -ForegroundColor Green
Write-Host "Old content generator is disabled in cron, not destructively deleted." -ForegroundColor Yellow
Write-Host "This is deliberate so other systems cannot be damaged." -ForegroundColor Yellow
Write-Host ""
Write-Host "Run:" -ForegroundColor Cyan
Write-Host "  npm run typecheck"
Write-Host "  npm run build"
