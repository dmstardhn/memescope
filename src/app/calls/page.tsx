import Link from "next/link";

import {
  compactUsd,
  getCallDashboard,
  multipleText,
} from "@/lib/call-story";

function pct(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  return `${value > 0 ? "+" : ""}${value.toFixed(1)}%`;
}

export const dynamic = "force-dynamic";

export default async function CallsPage() {
  const dashboard = await getCallDashboard(30);

  return (
    <main className="mx-auto w-full max-w-7xl px-4 py-6 lg:px-8 lg:py-8">
      <div className="mb-8">
        <div className="text-xs uppercase tracking-[0.22em] text-emerald-300/70">
          MemeScope Live Call Intelligence
        </div>
        <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
          Calls & Public Performance
        </h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
          Calls are tracked from their original entry. Public signal posts remain unchanged while MemeScope records the journey, peak performance and drawdown.
        </p>
      </div>

      <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
        {[
          ["30D Calls", dashboard.totalCalls],
          ["Reached 2X", dashboard.reached2x],
          ["Reached 5X", dashboard.reached5x],
          ["Reached 10X", dashboard.reached10x],
          ["Median Peak", multipleText(dashboard.medianPeakMultiple)],
          ["Median Drawdown", pct(dashboard.medianMaxDrawdownPct)],
        ].map(([label, value]) => (
          <div key={String(label)} className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
            <div className="text-[10px] uppercase tracking-[0.16em] text-zinc-600">{label}</div>
            <div className="mt-2 text-xl font-semibold text-white">{value}</div>
          </div>
        ))}
      </section>

      <section className="mt-8">
        <div className="mb-3 flex items-end justify-between gap-4">
          <div>
            <div className="text-xs uppercase tracking-[0.16em] text-zinc-600">Hall of Calls</div>
            <h2 className="mt-1 text-xl font-semibold text-white">Top recorded calls</h2>
          </div>
          <div className="text-xs text-zinc-600">Ranked by observed peak since call</div>
        </div>

        <div className="grid gap-3 lg:grid-cols-2">
          {dashboard.topCalls.slice(0, 10).map((call, index) => (
            <Link
              key={call.signalRecordId}
              href={`/calls/${encodeURIComponent(call.publicId)}`}
              className="group rounded-2xl border border-white/8 bg-white/[0.025] p-5 transition hover:border-emerald-400/20 hover:bg-white/[0.04]"
            >
              <div className="flex items-start justify-between gap-4">
                <div>
                  <div className="text-[10px] text-zinc-600">#{index + 1}  {call.publicId}</div>
                  <div className="mt-1 text-lg font-semibold text-white">${call.symbol}</div>
                  <div className="mt-1 text-xs text-zinc-600">{compactUsd(call.callMarketCapUsd)}{" -> "}{compactUsd(call.peakMarketCapUsd)}</div>
                </div>
                <div className="text-right">
                  <div className="text-2xl font-semibold text-emerald-300">{multipleText(call.peakMultiple)}</div>
                  <div className="text-[10px] uppercase tracking-[0.12em] text-zinc-600">peak</div>
                </div>
              </div>
              <div className="mt-4 grid grid-cols-3 gap-2 text-xs">
                <div className="rounded-xl bg-black/20 p-2.5"><div className="text-zinc-600">Score</div><div className="mt-1 text-zinc-300">{Math.round(call.signalScore)}/100</div></div>
                <div className="rounded-xl bg-black/20 p-2.5"><div className="text-zinc-600">Current</div><div className="mt-1 text-zinc-300">{multipleText(call.currentMultiple)}</div></div>
                <div className="rounded-xl bg-black/20 p-2.5"><div className="text-zinc-600">Drawdown</div><div className="mt-1 text-zinc-300">{pct(call.maxDrawdownPct)}</div></div>
              </div>
            </Link>
          ))}
        </div>
      </section>

      <section className="mt-8">
        <div className="mb-3">
          <div className="text-xs uppercase tracking-[0.16em] text-zinc-600">Recent Calls</div>
          <h2 className="mt-1 text-xl font-semibold text-white">Public call history</h2>
        </div>
        <div className="overflow-hidden rounded-2xl border border-white/8 bg-white/[0.02]">
          <div className="divide-y divide-white/5">
            {dashboard.recentCalls.map((call) => (
              <Link key={call.signalRecordId} href={`/calls/${encodeURIComponent(call.publicId)}`} className="grid grid-cols-[1fr_auto] gap-4 p-4 transition hover:bg-white/[0.03] sm:grid-cols-[1.2fr_1fr_1fr_auto]">
                <div><div className="font-medium text-white">${call.symbol}</div><div className="text-[10px] text-zinc-600">{call.publicId}</div></div>
                <div className="hidden sm:block"><div className="text-[10px] text-zinc-600">Call MC</div><div className="mt-1 text-xs text-zinc-300">{compactUsd(call.callMarketCapUsd)}</div></div>
                <div className="hidden sm:block"><div className="text-[10px] text-zinc-600">Peak MC</div><div className="mt-1 text-xs text-zinc-300">{compactUsd(call.peakMarketCapUsd)}</div></div>
                <div className="text-right"><div className="font-semibold text-emerald-300">{multipleText(call.peakMultiple)}</div><div className="text-[10px] text-zinc-600">peak</div></div>
              </Link>
            ))}
          </div>
        </div>
      </section>

      <div className="mt-6 text-[10px] leading-5 text-zinc-700">
        Performance shown here is historical and descriptive. Peak values are observed after the original call and are not guarantees of future results.
      </div>
    </main>
  );
}
