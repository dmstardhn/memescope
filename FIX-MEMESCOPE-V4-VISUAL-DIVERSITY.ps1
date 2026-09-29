$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Full([string]$p) { Join-Path $root $p }
function WriteUtf8([string]$rel,[string]$text) {
  $path = Full $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path,$text,$utf8)
  Write-Host "WRITE $rel" -ForegroundColor Green
}

$renderPath = Full "src\lib\content-hq-v4\render.ts"
$enginePath = Full "src\lib\content-hq-v4\engine.ts"

foreach ($p in @($renderPath,$enginePath)) {
  if (!(Test-Path -LiteralPath $p)) { throw "Missing required V4 file: $p" }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-V4-Visual-Diversity-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath $renderPath -Destination (Join-Path $backup "render.ts") -Force
Copy-Item -LiteralPath $enginePath -Destination (Join-Path $backup "engine.ts") -Force

$renderer = @'
import "server-only";
import sharp from "sharp";
import type { ContentType } from "./db";

export type Candle = {
  timestamp: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
};

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
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
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
  .brand{font-family:Arial,sans-serif;font-size:15px;fill:#737b78;font-weight:700;letter-spacing:2px}
  .ticker{font-family:Arial,sans-serif;font-size:42px;fill:#f3f5f4;font-weight:800}
  .title{font-family:Arial,sans-serif;font-size:25px;fill:#e8eeeb;font-weight:700}
  .label{font-family:Arial,sans-serif;font-size:14px;fill:#7f8985}
  .value{font-family:Arial,sans-serif;font-size:28px;fill:#eef2f0;font-weight:650}
  .small{font-family:Arial,sans-serif;font-size:13px;fill:#7c8582}
  .up{fill:#73cfa8;stroke:#73cfa8}
  .down{fill:#8e9794;stroke:#8e9794}
  </style>`;
}

function chartRange(data: Candle[]) {
  const valid = data.filter(
    d =>
      Number.isFinite(d.high) &&
      Number.isFinite(d.low) &&
      Number.isFinite(d.close) &&
      d.high > 0 &&
      d.low > 0,
  );

  if (!valid.length) return null;

  const min = Math.min(...valid.map(d => d.low));
  const max = Math.max(...valid.map(d => d.high));
  const raw = Math.max(max - min, max * 0.015, 1e-12);

  return {
    min: min - raw * 0.08,
    max: max + raw * 0.08,
  };
}

function candleChart(
  data: Candle[],
  x: number,
  y: number,
  w: number,
  h: number,
  levels?: Array<{ price: number; label: string; dash?: boolean }>,
) {
  if (data.length < 2) {
    return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0d0f0e" stroke="#252a28"/>
      <text x="${x + w / 2}" y="${y + h / 2}" text-anchor="middle" class="small">chart unavailable</text>`;
  }

  const series = data.slice(-72);
  const range = chartRange(series);
  if (!range) return "";

  const innerX = x + 26;
  const innerY = y + 22;
  const innerW = w - 52;
  const innerH = h - 44;
  const priceY = (price: number) =>
    innerY + ((range.max - price) / (range.max - range.min)) * innerH;

  const slot = innerW / series.length;
  const bodyW = Math.max(2, Math.min(9, slot * 0.58));

  const grid = [0.25, 0.5, 0.75]
    .map(
      f =>
        `<line x1="${innerX}" y1="${(innerY + innerH * f).toFixed(1)}" x2="${(
          innerX + innerW
        ).toFixed(1)}" y2="${(innerY + innerH * f).toFixed(
          1,
        )}" stroke="#181b1a"/>`,
    )
    .join("");

  const candles = series
    .map((d, i) => {
      const cx = innerX + slot * i + slot / 2;
      const openY = priceY(d.open);
      const closeY = priceY(d.close);
      const highY = priceY(d.high);
      const lowY = priceY(d.low);
      const isUp = d.close >= d.open;
      const top = Math.min(openY, closeY);
      const bodyH = Math.max(2, Math.abs(closeY - openY));
      const cls = isUp ? "up" : "down";

      return `<line x1="${cx.toFixed(1)}" y1="${highY.toFixed(
        1,
      )}" x2="${cx.toFixed(1)}" y2="${lowY.toFixed(
        1,
      )}" class="${cls}" stroke-width="1.4"/>
      <rect x="${(cx - bodyW / 2).toFixed(1)}" y="${top.toFixed(
        1,
      )}" width="${bodyW.toFixed(1)}" height="${bodyH.toFixed(
        1,
      )}" class="${cls}" rx="1"/>`;
    })
    .join("");

  const levelSvg = (levels ?? [])
    .filter(level => Number.isFinite(level.price))
    .map(level => {
      const ly = priceY(level.price);
      if (ly < innerY || ly > innerY + innerH) return "";
      return `<line x1="${innerX}" y1="${ly.toFixed(
        1,
      )}" x2="${innerX + innerW}" y2="${ly.toFixed(
        1,
      )}" stroke="#727c78" stroke-width="1.5" ${
        level.dash ? 'stroke-dasharray="8 8"' : ""
      }/>
      <rect x="${x + w - 185}" y="${(ly - 14).toFixed(
        1,
      )}" width="155" height="27" rx="6" fill="#111413"/>
      <text x="${x + w - 42}" y="${(ly + 5).toFixed(
        1,
      )}" text-anchor="end" class="small">${esc(level.label)}</text>`;
    })
    .join("");

  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0d0f0e" stroke="#252a28"/>
    ${grid}${candles}${levelSvg}`;
}

function lineChart(
  data: Candle[],
  x: number,
  y: number,
  w: number,
  h: number,
  stroke = "#d7dfdc",
) {
  if (data.length < 2) {
    return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0d0f0e" stroke="#252a28"/>
      <text x="${x + w / 2}" y="${y + h / 2}" text-anchor="middle" class="small">chart unavailable</text>`;
  }

  const series = data.slice(-100);
  const values = series.map(d => d.close).filter(Number.isFinite);
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = Math.max(max - min, max * 0.02, 1e-12);

  const pts = series.map((d, i) => {
    const px = x + 24 + (i / (series.length - 1)) * (w - 48);
    const py = y + h - 24 - ((d.close - min) / range) * (h - 48);
    return `${px.toFixed(1)},${py.toFixed(1)}`;
  });

  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="10" fill="#0d0f0e" stroke="#252a28"/>
    <line x1="${x + 20}" y1="${y + h * 0.25}" x2="${x + w - 20}" y2="${y + h * 0.25}" stroke="#181b1a"/>
    <line x1="${x + 20}" y1="${y + h * 0.5}" x2="${x + w - 20}" y2="${y + h * 0.5}" stroke="#181b1a"/>
    <line x1="${x + 20}" y1="${y + h * 0.75}" x2="${x + w - 20}" y2="${y + h * 0.75}" stroke="#181b1a"/>
    <polyline points="${pts.join(
      " ",
    )}" fill="none" stroke="${stroke}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>`;
}

function recentLevels(data: Candle[]) {
  const recent = data.slice(-30);
  if (!recent.length) return null;

  const support = Math.min(...recent.map(d => d.low).filter(Number.isFinite));
  const high = Math.max(...recent.map(d => d.high).filter(Number.isFinite));

  if (!Number.isFinite(support) || !Number.isFinite(high)) return null;
  return { support, high };
}

async function asWebp(svg: string) {
  return sharp(Buffer.from(svg, "utf8")).webp({ quality: 90 }).toBuffer();
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
      ${candleChart(input.historicCandles, 70, 210, 712, 470)}
      ${candleChart(input.candles, 818, 210, 712, 470)}
      <rect x="70" y="720" width="712" height="104" rx="10" fill="#101211" stroke="#272c2a"/>
      <text x="100" y="758" class="label">first market cap</text>
      <text x="100" y="800" class="value">${esc(usd(input.firstMarketCap))}</text>
      <rect x="818" y="720" width="712" height="104" rx="10" fill="#101211" stroke="#272c2a"/>
      <text x="848" y="758" class="label">current / move</text>
      <text x="848" y="800" class="value">${esc(
        usd(input.currentMarketCap),
      )} / ${esc((input.multiple ?? 0).toFixed(2))}x</text>
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
      <circle cx="210" cy="285" r="13" fill="#d7dfdc"/>
      <circle cx="600" cy="285" r="13" fill="#a9bdb5"/>
      <circle cx="990" cy="285" r="13" fill="#86caaa"/>
      <circle cx="1390" cy="285" r="15" fill="#75d4ac"/>
      <text x="210" y="235" text-anchor="middle" class="label">DETECTED</text>
      <text x="600" y="235" text-anchor="middle" class="label">2X</text>
      <text x="990" y="235" text-anchor="middle" class="label">5X</text>
      <text x="1390" y="235" text-anchor="middle" class="label">CURRENT</text>
      <text x="210" y="345" text-anchor="middle" class="value">${esc(usd(call || null))}</text>
      <text x="600" y="345" text-anchor="middle" class="value">${esc(
        usd(call ? call * 2 : null),
      )}</text>
      <text x="990" y="345" text-anchor="middle" class="value">${esc(
        usd(call ? call * 5 : null),
      )}</text>
      <text x="1390" y="345" text-anchor="middle" class="value green">${esc(
        (input.multiple ?? 0).toFixed(2),
      )}x</text>
      ${candleChart(input.candles, 70, 420, 1460, 330)}
    </svg>`;

    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.contentType === "daily_recap" || input.contentType === "weekly_recap") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="122" class="ticker">${
        input.contentType === "weekly_recap" ? "WEEKLY TAPE" : "DAILY TAPE"
      }</text>
      <rect x="70" y="190" width="1460" height="540" rx="14" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="120" y="285" class="label">standout move</text>
      <text x="120" y="342" class="title">$${esc(input.symbol)}</text>
      <text x="120" y="410" class="value green">${esc(
        (input.multiple ?? 0).toFixed(2),
      )}x</text>
      <text x="580" y="285" class="label">first MC</text>
      <text x="580" y="342" class="value">${esc(usd(input.firstMarketCap))}</text>
      <text x="580" y="430" class="label">current MC</text>
      <text x="580" y="487" class="value">${esc(usd(input.currentMarketCap))}</text>
      ${lineChart(input.candles, 980, 245, 480, 360, "#75d4ac")}
      <text x="70" y="816" class="small">tracked by MemeScope</text>
    </svg>`;

    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "pure_chart") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="112" class="ticker">$${esc(input.symbol)} / SOL</text>
      <text x="70" y="148" class="small">5m candles / raw setup</text>
      ${candleChart(input.candles, 70, 178, 1460, 620)}
    </svg>`;

    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "level_setup") {
    const levels = recentLevels(input.candles);
    const overlays = levels
      ? [
          { price: levels.support, label: "recent support", dash: true },
          { price: levels.high, label: "recent high", dash: true },
        ]
      : [];

    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="112" class="ticker">$${esc(input.symbol)}</text>
      <text x="70" y="148" class="small">recent range / key areas</text>
      ${candleChart(input.candles, 70, 178, 1460, 620, overlays)}
    </svg>`;

    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "first_spotted") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="112" class="ticker">$${esc(input.symbol)}</text>
      <rect x="70" y="165" width="410" height="630" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="110" y="235" class="label">FIRST SPOTTED</text>
      <text x="110" y="294" class="value">${esc(usd(input.firstMarketCap))}</text>
      <text x="110" y="390" class="label">CURRENT</text>
      <text x="110" y="449" class="value">${esc(usd(input.currentMarketCap))}</text>
      <text x="110" y="548" class="label">MOVE</text>
      <text x="110" y="607" class="value">${esc(
        input.multiple ? `${input.multiple.toFixed(2)}x` : "N/A",
      )}</text>
      ${candleChart(input.candles, 520, 165, 1010, 630)}
    </svg>`;

    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  if (input.visualStyle === "minimal_metrics") {
    const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
      <text x="70" y="112" class="ticker">$${esc(input.symbol)}</text>
      ${lineChart(input.candles, 70, 165, 1010, 620, "#d8e0dd")}
      <rect x="1120" y="165" width="410" height="620" rx="12" fill="#0d0f0e" stroke="#272c2a"/>
      <text x="1160" y="235" class="label">MARKET CAP</text>
      <text x="1160" y="280" class="value">${esc(usd(input.currentMarketCap))}</text>
      <text x="1160" y="395" class="label">LIQUIDITY</text>
      <text x="1160" y="440" class="value">${esc(usd(input.liquidity))}</text>
      <text x="1160" y="555" class="label">24H VOLUME</text>
      <text x="1160" y="600" class="value">${esc(usd(input.volume))}</text>
    </svg>`;

    return { buffer: await asWebp(svg), mime: "image/webp" };
  }

  const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <rect width="1600" height="900" fill="#090a0a"/>${base()}${brand}
    <text x="70" y="112" class="ticker">$${esc(input.symbol)}</text>
    <text x="70" y="184" class="value">${esc(
      (input.multiple ?? 0).toFixed(2),
    )}x</text>
    <text x="70" y="222" class="small">since MemeScope detection</text>
    ${candleChart(input.candles, 70, 275, 1460, 430)}
    <rect x="70" y="744" width="700" height="84" rx="10" fill="#101211" stroke="#272c2a"/>
    <text x="105" y="778" class="label">FIRST MC</text>
    <text x="105" y="810" class="title">${esc(usd(input.firstMarketCap))}</text>
    <rect x="830" y="744" width="700" height="84" rx="10" fill="#101211" stroke="#272c2a"/>
    <text x="865" y="778" class="label">CURRENT MC</text>
    <text x="865" y="810" class="title">${esc(usd(input.currentMarketCap))}</text>
  </svg>`;

  return { buffer: await asWebp(svg), mime: "image/webp" };
}
'@

WriteUtf8 "src/lib/content-hq-v4/render.ts" $renderer

$engine = [System.IO.File]::ReadAllText($enginePath)

$pattern = '(?s)export async function contentHqV4TestBatch\(limit = 6\) \{.*\}\s*$'
$match = [regex]::Match($engine,$pattern)

if (!$match.Success) {
  throw "Could not safely find contentHqV4TestBatch() at the end of engine.ts. Nothing was changed in engine.ts."
}

$replacement = @'
export async function contentHqV4TestBatch(limit = 6) {
  await ensureV4Schema();
  const sql = sqlV4();
  const candidates = await buildTokenCandidates();
  const observation = await maybeObservation();
  if (observation) candidates.push(observation);

  const unique = new Map<string, Candidate>();
  for (const candidate of candidates) {
    const key = `${candidate.contentType}:${candidate.tokenAddress ?? "text"}`;
    if (!unique.has(key)) unique.set(key, candidate);
  }

  const picked = [...unique.values()].slice(0, Math.max(1, Math.min(limit, 8)));
  const testStyles = [
    "pure_chart",
    "level_setup",
    "first_spotted",
    "minimal_metrics",
    "performance",
  ];
  const created: Array<Record<string, unknown>> = [];

  for (let index = 0; index < picked.length; index++) {
    const selected = picked[index];

    const testStyle =
      selected.contentType === "chart_setup" ||
      selected.contentType === "token_update" ||
      selected.contentType === "token_watch"
        ? testStyles[index % testStyles.length]
        : selected.visualStyle;

    const visual = await renderContent({
      symbol: selected.symbol,
      contentType: selected.contentType,
      visualStyle: testStyle,
      firstMarketCap: selected.firstMc,
      currentMarketCap: selected.currentMc,
      multiple: selected.multiple,
      liquidity: selected.liquidity,
      volume: selected.volume,
      candles: selected.candles,
      historicCandles: selected.historicCandles,
      branded: selected.branded,
    });

    if (selected.contentType !== "market_observation" && !visual) continue;

    const testKey = `v4test:${Date.now()}:${index}:${selected.tokenAddress ?? "text"}`;

    const rows = await sql`
      INSERT INTO memescope_content_v4_queue (
        event_key, token_address, pair_address, symbol,
        content_type, visual_style, caption_template, caption,
        reason, first_market_cap, current_market_cap, multiple,
        image_base64, image_mime, branded, status
      )
      VALUES (
        ${testKey}, ${selected.tokenAddress}, ${selected.pairAddress}, ${selected.symbol},
        ${selected.contentType}, ${testStyle}, ${selected.captionTemplate}, ${selected.caption},
        ${`TEST LAB: ${selected.reason}`}, ${selected.firstMc}, ${selected.currentMc}, ${selected.multiple},
        ${visual ? visual.buffer.toString("base64") : null}, ${visual?.mime ?? null},
        ${selected.branded}, 'queued'
      )
      RETURNING id, content_type, symbol, visual_style, caption, status
    `;

    if (rows.length) created.push(rows[0] as Record<string, unknown>);
  }

  return {
    ok: true,
    requested: limit,
    availableCandidates: candidates.length,
    created: created.length,
    items: created,
  };
}
'@

$engine = [regex]::Replace($engine,$pattern,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement },1)
[System.IO.File]::WriteAllText($enginePath,$engine,$utf8)
Write-Host "PATCH engine.ts -> diversified Test Lab styles" -ForegroundColor Green

Write-Host ""
Write-Host "Visual diversity V2 installed." -ForegroundColor Green
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "This changes Content HQ V4 visuals only." -ForegroundColor Cyan
Write-Host "Run:" -ForegroundColor Cyan
Write-Host "  npm run typecheck"
Write-Host "  npm run build"
