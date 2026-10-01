import "server-only";

import sharp from "sharp";

import {
  SIGNAL_RESULT_TEMPLATES,
  type SignalResultTemplateKey,
} from "@/lib/signal-result-card-templates";

export type SignalResultCardInput = {
  symbol: string;
  callMarketCapUsd: number | null;
  peakMarketCapUsd: number | null;
  peakMultiple: number | null;
  calledAt: number;
  tokenAddress: string;
  publicId?: string | null;
};

type Tier = {
  key: SignalResultTemplateKey;
  badge: string;
  accent: string;
  accent2: string;
};

function tierFor(multiple: number): Tier {
  if (multiple >= 100) return { key: "100x", badge: "100X+ / CENTURY", accent: "#FFF1A6", accent2: "#EAB308" };
  if (multiple >= 50) return { key: "50x", badge: "50X+ / TITAN", accent: "#FFD166", accent2: "#F97316" };
  if (multiple >= 20) return { key: "20x", badge: "20X+ / LEGEND", accent: "#D8B4FE", accent2: "#8B5CF6" };
  if (multiple >= 10) return { key: "10x", badge: "10X+ / APEX", accent: "#FDE68A", accent2: "#F59E0B" };
  if (multiple >= 5) return { key: "5x", badge: "5X+ / SURGE", accent: "#67E8F9", accent2: "#0891B2" };
  if (multiple >= 3) return { key: "3x", badge: "3X+ / BREAKOUT", accent: "#62F59A", accent2: "#16A34A" };
  return { key: "momentum", badge: "LIVE / MOMENTUM", accent: "#25E6C8", accent2: "#0EA5A4" };
}

function esc(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function compactUsd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  const a = Math.abs(value);
  if (a >= 1_000_000_000) return "$" + (value / 1_000_000_000).toFixed(2) + "B";
  if (a >= 1_000_000) return "$" + (value / 1_000_000).toFixed(2) + "M";
  if (a >= 1_000) return "$" + (value / 1_000).toFixed(value >= 100_000 ? 0 : 1) + "K";
  return "$" + value.toFixed(0);
}

function elapsedText(calledAt: number) {
  const ms = Math.max(0, Date.now() - calledAt);
  const minutes = Math.floor(ms / 60_000);
  if (minutes < 60) return minutes + "m";
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours < 24) return hours + "h " + remainingMinutes + "m";
  const days = Math.floor(hours / 24);
  return days + "d " + (hours % 24) + "h";
}

function shortAddress(value: string) {
  if (value.length <= 24) return value;
  return value.slice(0, 10) + "..." + value.slice(-8);
}

export function signalResultTemplateKey(peakMultiple: number | null) {
  const multiple =
    peakMultiple !== null && Number.isFinite(peakMultiple)
      ? Math.max(1, peakMultiple)
      : 1;
  return tierFor(multiple).key;
}

export async function renderSignalResultCard(input: SignalResultCardInput) {
  const multiple =
    input.peakMultiple !== null && Number.isFinite(input.peakMultiple)
      ? Math.max(1, input.peakMultiple)
      : 1;
  const tier = tierFor(multiple);
  const background = SIGNAL_RESULT_TEMPLATES[tier.key];
  const gain = Math.max(0, (multiple - 1) * 100);
  const gainText = "+" + gain.toFixed(gain >= 100 ? 0 : 1) + "%";
  const symbol = esc(input.symbol.toUpperCase().slice(0, 18));
  const callId = esc((input.publicId || "MEMESCOPE").slice(0, 24));
  const address = esc(shortAddress(input.tokenAddress));

  const overlay = String.raw`<svg width="1600" height="900" viewBox="0 0 1600 900" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="resultAccent" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0%" stop-color="${tier.accent}"/>
        <stop offset="100%" stop-color="${tier.accent2}"/>
      </linearGradient>
    </defs>

    <text x="650" y="127" font-family="Arial,Helvetica,sans-serif" font-size="20" font-weight="800" letter-spacing="4" fill="${tier.accent}">${esc(tier.badge)}</text>
    <text x="1450" y="127" text-anchor="end" font-family="Arial,Helvetica,sans-serif" font-size="18" font-weight="600" fill="#819087">TRACKED PERFORMANCE</text>

    <text x="650" y="286" font-family="Arial,Helvetica,sans-serif" font-size="60" font-weight="900" fill="#F4F8F6">$${symbol}</text>
    <text x="650" y="425" font-family="Arial,Helvetica,sans-serif" font-size="108" font-weight="900" fill="url(#resultAccent)">${gainText}</text>
    <text x="655" y="468" font-family="Arial,Helvetica,sans-serif" font-size="22" font-weight="700" letter-spacing="3" fill="#87978F">PEAK MOVE SINCE CALL</text>

    <g transform="translate(650 555)">
      <rect width="245" height="145" rx="18" fill="#07100D" stroke="#274137"/>
      <text x="26" y="39" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="700" fill="#718178">CALL MC</text>
      <text x="26" y="89" font-family="Arial,Helvetica,sans-serif" font-size="31" font-weight="900" fill="#F1F6F3">${esc(compactUsd(input.callMarketCapUsd))}</text>
      <rect x="26" y="116" width="84" height="4" rx="2" fill="${tier.accent}"/>
    </g>

    <g transform="translate(920 555)">
      <rect width="245" height="145" rx="18" fill="#07100D" stroke="#274137"/>
      <text x="26" y="39" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="700" fill="#718178">PEAK MC</text>
      <text x="26" y="89" font-family="Arial,Helvetica,sans-serif" font-size="31" font-weight="900" fill="${tier.accent}">${esc(compactUsd(input.peakMarketCapUsd))}</text>
      <rect x="26" y="116" width="84" height="4" rx="2" fill="${tier.accent2}"/>
    </g>

    <g transform="translate(1190 555)">
      <rect width="280" height="145" rx="18" fill="#07100D" stroke="#274137"/>
      <text x="26" y="39" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="700" fill="#718178">ELAPSED</text>
      <text x="26" y="89" font-family="Arial,Helvetica,sans-serif" font-size="29" font-weight="900" fill="#F1F6F3">${esc(elapsedText(input.calledAt))}</text>
      <rect x="26" y="116" width="84" height="4" rx="2" fill="${tier.accent}"/>
    </g>

    <text x="110" y="757" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="700" fill="#718178">CALL ID</text>
    <text x="110" y="796" font-family="Arial,Helvetica,sans-serif" font-size="26" font-weight="900" fill="#E8F2ED">${callId}</text>
    <text x="500" y="796" text-anchor="end" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="600" fill="#65756D">${address}</text>

    <text x="650" y="797" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="600" fill="#65756D">Historical peak tracked after the timestamped call.</text>
    <text x="1455" y="797" text-anchor="end" font-family="Arial,Helvetica,sans-serif" font-size="17" font-weight="700" letter-spacing="3" fill="${tier.accent}">MEMESCOPE RESULT ENGINE</text>
  </svg>`;

  const output = await sharp(Buffer.from(background))
    .composite([{ input: Buffer.from(overlay), top: 0, left: 0 }])
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();

  return new Blob([new Uint8Array(output)], { type: "image/png" });
}