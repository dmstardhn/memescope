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