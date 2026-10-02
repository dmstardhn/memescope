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

type VectorTextOptions = {
  scale: number;
  fill: string;
  spacing?: number;
  align?: "left" | "right" | "center";
};

const GLYPHS: Record<string, string[]> = {
  " ": ["00000","00000","00000","00000","00000","00000","00000"],
  "A": ["01110","10001","10001","11111","10001","10001","10001"],
  "B": ["11110","10001","10001","11110","10001","10001","11110"],
  "C": ["01111","10000","10000","10000","10000","10000","01111"],
  "D": ["11110","10001","10001","10001","10001","10001","11110"],
  "E": ["11111","10000","10000","11110","10000","10000","11111"],
  "F": ["11111","10000","10000","11110","10000","10000","10000"],
  "G": ["01111","10000","10000","10111","10001","10001","01111"],
  "H": ["10001","10001","10001","11111","10001","10001","10001"],
  "I": ["11111","00100","00100","00100","00100","00100","11111"],
  "J": ["00111","00010","00010","00010","10010","10010","01100"],
  "K": ["10001","10010","10100","11000","10100","10010","10001"],
  "L": ["10000","10000","10000","10000","10000","10000","11111"],
  "M": ["10001","11011","10101","10101","10001","10001","10001"],
  "N": ["10001","11001","10101","10011","10001","10001","10001"],
  "O": ["01110","10001","10001","10001","10001","10001","01110"],
  "P": ["11110","10001","10001","11110","10000","10000","10000"],
  "Q": ["01110","10001","10001","10001","10101","10010","01101"],
  "R": ["11110","10001","10001","11110","10100","10010","10001"],
  "S": ["01111","10000","10000","01110","00001","00001","11110"],
  "T": ["11111","00100","00100","00100","00100","00100","00100"],
  "U": ["10001","10001","10001","10001","10001","10001","01110"],
  "V": ["10001","10001","10001","10001","10001","01010","00100"],
  "W": ["10001","10001","10001","10101","10101","11011","10001"],
  "X": ["10001","10001","01010","00100","01010","10001","10001"],
  "Y": ["10001","10001","01010","00100","00100","00100","00100"],
  "Z": ["11111","00001","00010","00100","01000","10000","11111"],
  "0": ["01110","10001","10011","10101","11001","10001","01110"],
  "1": ["00100","01100","00100","00100","00100","00100","01110"],
  "2": ["01110","10001","00001","00010","00100","01000","11111"],
  "3": ["11110","00001","00001","01110","00001","00001","11110"],
  "4": ["00010","00110","01010","10010","11111","00010","00010"],
  "5": ["11111","10000","10000","11110","00001","00001","11110"],
  "6": ["01110","10000","10000","11110","10001","10001","01110"],
  "7": ["11111","00001","00010","00100","01000","01000","01000"],
  "8": ["01110","10001","10001","01110","10001","10001","01110"],
  "9": ["01110","10001","10001","01111","00001","00001","01110"],
  "$": ["00100","01111","10100","01110","00101","11110","00100"],
  "%": ["11001","11010","00100","01000","10110","00110","00000"],
  "+": ["00000","00100","00100","11111","00100","00100","00000"],
  "-": ["00000","00000","00000","11111","00000","00000","00000"],
  ".": ["00000","00000","00000","00000","00000","00110","00110"],
  "/": ["00001","00010","00100","01000","10000","00000","00000"],
  ":": ["00000","00110","00110","00000","00110","00110","00000"],
  "_": ["00000","00000","00000","00000","00000","00000","11111"],
  "?": ["01110","10001","00001","00010","00100","00000","00100"],
};

function tierFor(multiple: number): Tier {
  if (multiple >= 100) return { key: "100x", badge: "CENTURY", accent: "#FFF1A6", accent2: "#EAB308" };
  if (multiple >= 50) return { key: "50x", badge: "TITAN", accent: "#FFD166", accent2: "#F97316" };
  if (multiple >= 20) return { key: "20x", badge: "LEGEND", accent: "#D8B4FE", accent2: "#8B5CF6" };
  if (multiple >= 10) return { key: "10x", badge: "APEX", accent: "#FDE68A", accent2: "#F59E0B" };
  if (multiple >= 5) return { key: "5x", badge: "SURGE", accent: "#67E8F9", accent2: "#0891B2" };
  if (multiple >= 3) return { key: "3x", badge: "BREAKOUT", accent: "#62F59A", accent2: "#16A34A" };
  return { key: "momentum", badge: "MOMENTUM", accent: "#25E6C8", accent2: "#0EA5A4" };
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
  if (minutes < 60) return minutes + "M";
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  if (hours < 24) return hours + "H " + remainingMinutes + "M";
  const days = Math.floor(hours / 24);
  return days + "D " + (hours % 24) + "H";
}

function cleanText(value: unknown, max = 64) {
  return String(value ?? "")
    .toUpperCase()
    .replace(/[^A-Z0-9 $%+\-./:_?]/g, "?")
    .slice(0, max);
}

function stripSvgText(svg: string) {
  return svg.replace(/<text\b[\s\S]*?<\/text>/gi, "");
}

function glyphWidth(scale: number) {
  return 5 * scale;
}

function vectorTextWidth(text: string, scale: number, spacing: number) {
  if (!text.length) return 0;
  return text.length * glyphWidth(scale) + (text.length - 1) * spacing;
}

function vectorText(
  raw: string,
  x: number,
  y: number,
  options: VectorTextOptions,
) {
  const text = cleanText(raw);
  const spacing = options.spacing ?? Math.max(2, Math.round(options.scale * 0.8));
  const totalWidth = vectorTextWidth(text, options.scale, spacing);
  let startX = x;

  if (options.align === "right") startX -= totalWidth;
  if (options.align === "center") startX -= totalWidth / 2;

  const commands: string[] = [];

  for (let index = 0; index < text.length; index++) {
    const char = text[index];
    const rows = GLYPHS[char] ?? GLYPHS["?"];
    const charX = startX + index * (glyphWidth(options.scale) + spacing);

    for (let row = 0; row < rows.length; row++) {
      for (let col = 0; col < 5; col++) {
        if (rows[row][col] !== "1") continue;
        const px = charX + col * options.scale;
        const py = y + row * options.scale;
        commands.push(
          `M${px} ${py}h${options.scale}v${options.scale}h-${options.scale}Z`,
        );
      }
    }
  }

  return `<path d="${commands.join("")}" fill="${options.fill}" shape-rendering="crispEdges"/>`;
}

function safeSymbol(value: string) {
  const cleaned = cleanText(value, 14).replaceAll("?", "");
  return cleaned || "TOKEN";
}

function safeCallId(value: string | null | undefined) {
  const cleaned = cleanText(value || "MEMESCOPE", 22);
  return cleaned || "MEMESCOPE";
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
  const background = stripSvgText(SIGNAL_RESULT_TEMPLATES[tier.key]);

  const gain = Math.max(0, (multiple - 1) * 100);
  const gainText = "+" + gain.toFixed(gain >= 100 ? 0 : 1) + "%";
  const symbol = "$" + safeSymbol(input.symbol);
  const callId = safeCallId(input.publicId);

  const overlay = `<svg width="1600" height="900" viewBox="0 0 1600 900" xmlns="http://www.w3.org/2000/svg">
    <defs>
      <linearGradient id="resultAccent" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0%" stop-color="${tier.accent}"/>
        <stop offset="100%" stop-color="${tier.accent2}"/>
      </linearGradient>
    </defs>

    ${vectorText("MEMESCOPE", 108, 92, { scale: 4, fill: tier.accent, spacing: 5 })}
    ${vectorText(tier.badge, 650, 105, { scale: 4, fill: tier.accent, spacing: 4 })}
    ${vectorText("TRACKED PERFORMANCE", 1450, 105, { scale: 3, fill: "#819087", spacing: 4, align: "right" })}

    ${vectorText(symbol, 650, 245, { scale: 10, fill: "#F4F8F6", spacing: 8 })}
    ${vectorText(gainText, 650, 350, { scale: 15, fill: tier.accent, spacing: 10 })}
    ${vectorText("PEAK MOVE SINCE CALL", 655, 473, { scale: 4, fill: "#87978F", spacing: 5 })}

    <g transform="translate(650 555)">
      <rect width="245" height="145" rx="18" fill="#07100D" stroke="#274137"/>
      ${vectorText("CALL MC", 26, 27, { scale: 3, fill: "#718178", spacing: 4 })}
      ${vectorText(compactUsd(input.callMarketCapUsd), 26, 69, { scale: 6, fill: "#F1F6F3", spacing: 5 })}
      <rect x="26" y="116" width="84" height="4" rx="2" fill="${tier.accent}"/>
    </g>

    <g transform="translate(920 555)">
      <rect width="245" height="145" rx="18" fill="#07100D" stroke="#274137"/>
      ${vectorText("PEAK MC", 26, 27, { scale: 3, fill: "#718178", spacing: 4 })}
      ${vectorText(compactUsd(input.peakMarketCapUsd), 26, 69, { scale: 6, fill: tier.accent, spacing: 5 })}
      <rect x="26" y="116" width="84" height="4" rx="2" fill="${tier.accent2}"/>
    </g>

    <g transform="translate(1190 555)">
      <rect width="280" height="145" rx="18" fill="#07100D" stroke="#274137"/>
      ${vectorText("ELAPSED", 26, 27, { scale: 3, fill: "#718178", spacing: 4 })}
      ${vectorText(elapsedText(input.calledAt), 26, 69, { scale: 5, fill: "#F1F6F3", spacing: 5 })}
      <rect x="26" y="116" width="84" height="4" rx="2" fill="${tier.accent}"/>
    </g>

    ${vectorText("CALL ID", 110, 747, { scale: 3, fill: "#718178", spacing: 4 })}
    ${vectorText(callId, 110, 785, { scale: 4, fill: "#E8F2ED", spacing: 4 })}

    ${vectorText("MEMESCOPE RESULT ENGINE", 1455, 790, { scale: 3, fill: tier.accent, spacing: 3, align: "right" })}
  </svg>`;

  const output = await sharp(Buffer.from(background))
    .composite([{ input: Buffer.from(overlay), top: 0, left: 0 }])
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();

  return new Blob([new Uint8Array(output)], { type: "image/png" });
}
