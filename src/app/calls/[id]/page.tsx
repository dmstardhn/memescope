import Link from "next/link";
import { notFound } from "next/navigation";

import {
  compactUsd,
  getCallByPublicId,
  multipleText,
} from "@/lib/call-story";

export const dynamic = "force-dynamic";

function pct(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  return `${value > 0 ? "+" : ""}${value.toFixed(1)}%`;
}

function duration(from: number, to: number | null) {
  if (to === null) return "—";
  const minutes = Math.max(0, (to - from) / 60_000);
  if (minutes < 60) return `${Math.round(minutes)}m`;
  const hours = minutes / 60;
  if (hours < 24) return `${hours.toFixed(1)}h`;
  return `${(hours / 24).toFixed(1)}d`;
}

export default async function CallDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const call = await getCallByPublicId(decodeURIComponent(id));
  if (!call) notFound();

  const journey = [
    { label: "CALL", at: call.calledAt, value: compactUsd(call.callMarketCapUsd) },
    { label: "2X RUNNER", at: call.milestone2xAt, value: call.milestone2xAt ? "2X" : null },
    { label: "5X MAJOR CALL", at: call.milestone5xAt, value: call.milestone5xAt ? "5X" : null },
    { label: "10X EXCEPTIONAL", at: call.milestone10xAt, value: call.milestone10xAt ? "10X" : null },
  ].filter((item) => item.at !== null);

  return (
    <main className="mx-auto w-full max-w-6xl px-4 py-6 lg:px-8 lg:py-8">
      <Link href="/calls" className="text-xs text-zinc-500 hover:text-white">← Hall of Calls</Link>

      <div className="mt-5 flex flex-col justify-between gap-6 lg:flex-row lg:items-end">
        <div>
          <div className="text-xs uppercase tracking-[0.22em] text-emerald-300/70">MemeScope Call Journey</div>
          <h1 className="mt-2 text-4xl font-semibold tracking-tight text-white">${call.symbol}</h1>
          <div className="mt-2 font-mono text-xs text-zinc-600">{call.publicId}</div>
        </div>
        <div className="text-left lg:text-right">
          <div className="text-[10px] uppercase tracking-[0.16em] text-zinc-600">Peak Since Call</div>
          <div className="mt-1 text-4xl font-semibold text-emerald-300">{multipleText(call.peakMultiple)}</div>
        </div>
      </div>

      <section className="mt-7 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {[
          ["Call MC", compactUsd(call.callMarketCapUsd)],
          ["Peak MC", compactUsd(call.peakMarketCapUsd)],
          ["Current", multipleText(call.currentMultiple)],
          ["Max Drawdown", pct(call.maxDrawdownPct)],
          ["Signal Score", `${Math.round(call.signalScore)}/100`],
          ["Buy Pressure", call.buyPressurePct === null ? "N/A" : `${call.buyPressurePct.toFixed(0)}%`],
          ["Volume Expansion", call.volumeSpike === null ? "N/A" : `${call.volumeSpike.toFixed(1)}X`],
          ["Liquidity", compactUsd(call.liquidityUsd)],
        ].map(([label, value]) => (
          <div key={String(label)} className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
            <div className="text-[10px] uppercase tracking-[0.14em] text-zinc-600">{label}</div>
            <div className="mt-2 text-lg font-semibold text-white">{value}</div>
          </div>
        ))}
      </section>

      <section className="mt-8 grid gap-5 lg:grid-cols-[1.1fr_0.9fr]">
        <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
          <div className="text-xs uppercase tracking-[0.16em] text-zinc-600">Call Journey</div>
          <div className="mt-5 space-y-1">
            {journey.map((item, index) => (
              <div key={item.label} className="grid grid-cols-[20px_1fr_auto] gap-3">
                <div className="flex flex-col items-center">
                  <span className="mt-1 h-2.5 w-2.5 rounded-full bg-emerald-300" />
                  {index < journey.length - 1 && <span className="min-h-12 w-px flex-1 bg-white/10" />}
                </div>
                <div className="pb-5">
                  <div className="text-sm font-medium text-white">{item.label}</div>
                  <div className="mt-1 text-xs text-zinc-600">
                    {new Date(item.at as number).toLocaleString("en-US", { timeZone: "UTC", month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false })} UTC
                  </div>
                </div>
                <div className="text-right text-sm font-semibold text-zinc-300">{item.value}</div>
              </div>
            ))}
          </div>
          <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
            <div className="rounded-xl bg-black/20 p-3"><div className="text-zinc-600">Time to 2X</div><div className="mt-1 text-zinc-300">{duration(call.calledAt, call.milestone2xAt)}</div></div>
            <div className="rounded-xl bg-black/20 p-3"><div className="text-zinc-600">Time to 5X</div><div className="mt-1 text-zinc-300">{duration(call.calledAt, call.milestone5xAt)}</div></div>
            <div className="rounded-xl bg-black/20 p-3"><div className="text-zinc-600">Time to 10X</div><div className="mt-1 text-zinc-300">{duration(call.calledAt, call.milestone10xAt)}</div></div>
          </div>
        </div>

        <div className="space-y-5">
          <section className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            <div className="text-xs uppercase tracking-[0.16em] text-zinc-600">Why it triggered</div>
            <div className="mt-4 space-y-2 text-sm leading-6 text-zinc-400">
              {call.reasons.length > 0 ? call.reasons.map((reason) => <div key={reason}>• {reason}</div>) : <div>No stored rationale for this historical call.</div>}
            </div>
          </section>

          <section className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            <div className="text-xs uppercase tracking-[0.16em] text-zinc-600">Content Cards</div>
            <div className="mt-4 grid gap-2">
              <a href={`/api/calls/${encodeURIComponent(call.publicId)}/card?mode=journey`} target="_blank" rel="noreferrer" className="rounded-xl border border-white/8 px-3 py-2.5 text-sm text-zinc-300 hover:border-emerald-400/20 hover:text-white">Open Journey Card</a>
              <a href={`/api/calls/${encodeURIComponent(call.publicId)}/card?mode=before`} target="_blank" rel="noreferrer" className="rounded-xl border border-white/8 px-3 py-2.5 text-sm text-zinc-300 hover:border-emerald-400/20 hover:text-white">Open Before The Move Card</a>
              <a href={`https://dexscreener.com/solana/${encodeURIComponent(call.tokenAddress)}`} target="_blank" rel="noreferrer" className="rounded-xl border border-white/8 px-3 py-2.5 text-sm text-zinc-300 hover:border-emerald-400/20 hover:text-white">Live Chart</a>
            </div>
          </section>
        </div>
      </section>

      <div className="mt-6 text-[10px] leading-5 text-zinc-700">
        Original call data is retained for public history. Peak and drawdown values are historical observations, not forecasts or guaranteed returns.
      </div>
    </main>
  );
}
