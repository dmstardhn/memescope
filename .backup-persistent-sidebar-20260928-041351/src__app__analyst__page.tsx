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
                    {analysis.symbol ? `Â· $${analysis.symbol}` : ""}
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
                    ? `AI Â· ${analysis.model}`
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
