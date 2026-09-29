import {
  compactUsd,
  getCallByPublicId,
  multipleText,
} from "@/lib/call-story";

export const dynamic = "force-dynamic";

function xml(value: unknown) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function pct(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  return `${value > 0 ? "+" : ""}${value.toFixed(1)}%`;
}

function duration(from: number, to: number | null) {
  if (to === null) return "-";
  const minutes = Math.max(0, (to - from) / 60_000);
  if (minutes < 60) return `${Math.round(minutes)}m`;
  const hours = minutes / 60;
  if (hours < 24) return `${hours.toFixed(1)}h`;
  return `${(hours / 24).toFixed(1)}d`;
}

export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
) {
  const { id } = await context.params;
  const call = await getCallByPublicId(decodeURIComponent(id));
  if (!call) return new Response("Call not found", { status: 404 });

  const mode = new URL(request.url).searchParams.get("mode") === "before" ? "before" : "journey";
  const accent = mode === "before" ? "#60a5fa" : "#6ee7b7";
  const title = mode === "before" ? "BEFORE THE MOVE" : "CALL JOURNEY";

  const body = mode === "before"
    ? `
      <text x="72" y="270" fill="#71717a" font-size="20">CALLED AT</text>
      <text x="72" y="315" fill="#ffffff" font-size="46" font-weight="700">${xml(compactUsd(call.callMarketCapUsd))} MC</text>
      <text x="72" y="390" fill="#71717a" font-size="18">BUY PRESSURE</text>
      <text x="72" y="425" fill="#ffffff" font-size="30" font-weight="600">${xml(call.buyPressurePct === null ? "N/A" : `${call.buyPressurePct.toFixed(0)}%`)}</text>
      <text x="360" y="390" fill="#71717a" font-size="18">VOLUME EXPANSION</text>
      <text x="360" y="425" fill="#ffffff" font-size="30" font-weight="600">${xml(call.volumeSpike === null ? "N/A" : `${call.volumeSpike.toFixed(1)}X`)}</text>
      <text x="720" y="390" fill="#71717a" font-size="18">SIGNAL SCORE</text>
      <text x="720" y="425" fill="#ffffff" font-size="30" font-weight="600">${Math.round(call.signalScore)}/100</text>
      <text x="72" y="520" fill="#71717a" font-size="20">IT LATER REACHED</text>
      <text x="72" y="570" fill="${accent}" font-size="48" font-weight="700">${xml(compactUsd(call.peakMarketCapUsd))} MC  ${xml(multipleText(call.peakMultiple))}</text>
    `
    : `
      <text x="72" y="280" fill="#71717a" font-size="20">CALL MC</text>
      <text x="72" y="325" fill="#ffffff" font-size="42" font-weight="700">${xml(compactUsd(call.callMarketCapUsd))}</text>
      <text x="420" y="280" fill="#71717a" font-size="20">PEAK MC</text>
      <text x="420" y="325" fill="#ffffff" font-size="42" font-weight="700">${xml(compactUsd(call.peakMarketCapUsd))}</text>
      <text x="830" y="280" fill="#71717a" font-size="20">PEAK</text>
      <text x="830" y="325" fill="${accent}" font-size="48" font-weight="700">${xml(multipleText(call.peakMultiple))}</text>
      <text x="72" y="425" fill="#71717a" font-size="18">CALL</text>
      <text x="72" y="458" fill="#ffffff" font-size="26">${new Date(call.calledAt).toISOString().slice(11, 16)} UTC</text>
      <text x="330" y="425" fill="#71717a" font-size="18">2X</text>
      <text x="330" y="458" fill="#ffffff" font-size="26">${xml(duration(call.calledAt, call.milestone2xAt))}</text>
      <text x="560" y="425" fill="#71717a" font-size="18">5X</text>
      <text x="560" y="458" fill="#ffffff" font-size="26">${xml(duration(call.calledAt, call.milestone5xAt))}</text>
      <text x="790" y="425" fill="#71717a" font-size="18">10X</text>
      <text x="790" y="458" fill="#ffffff" font-size="26">${xml(duration(call.calledAt, call.milestone10xAt))}</text>
      <text x="72" y="560" fill="#71717a" font-size="18">MAX DRAWDOWN</text>
      <text x="72" y="595" fill="#ffffff" font-size="28">${xml(pct(call.maxDrawdownPct))}</text>
      <text x="360" y="560" fill="#71717a" font-size="18">SIGNAL SCORE</text>
      <text x="360" y="595" fill="#ffffff" font-size="28">${Math.round(call.signalScore)}/100</text>
    `;

  const svg = `<?xml version="1.0" encoding="UTF-8"?>
  <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675">
    <rect width="1200" height="675" fill="#080a0f"/>
    <circle cx="1080" cy="80" r="260" fill="${accent}" opacity="0.07"/>
    <rect x="42" y="42" width="1116" height="591" rx="30" fill="#0d1016" stroke="#27272a"/>
    <text x="72" y="100" fill="${accent}" font-family="Arial, sans-serif" font-size="18" letter-spacing="4">MEMESCOPE</text>
    <text x="72" y="145" fill="#ffffff" font-family="Arial, sans-serif" font-size="28" font-weight="700">${title}</text>
    <text x="72" y="215" fill="#ffffff" font-family="Arial, sans-serif" font-size="56" font-weight="700">$${xml(call.symbol)}</text>
    <text x="1080" y="212" text-anchor="end" fill="#71717a" font-family="Arial, sans-serif" font-size="20">${xml(call.publicId)}</text>
    <g font-family="Arial, sans-serif">${body}</g>
    <text x="1080" y="605" text-anchor="end" fill="#52525b" font-family="Arial, sans-serif" font-size="16">Original call remains in public history</text>
  </svg>`;

  return new Response(svg, {
    headers: {
      "content-type": "image/svg+xml; charset=utf-8",
      "cache-control": "public, max-age=60, stale-while-revalidate=300",
    },
  });
}
