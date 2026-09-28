"use client";

import Link from "next/link";
import {
  Activity,
  AlertTriangle,
  ExternalLink,
  Radio,
  RefreshCw,
  Save,
  Users,
  WalletCards,
  Zap,
} from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import type {
  SmartMoneyResponse,
  SmartMoneySignal,
} from "@/lib/smart-money-types";

const STORAGE_KEY = "memescope-smart-money-wallets";

function short(value: string) {
  return `${value.slice(0, 5)}â€¦${value.slice(-4)}`;
}

function money(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "â€”";

  if (value >= 1_000_000_000) {
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  }

  if (value >= 1_000_000) {
    return `$${(value / 1_000_000).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(value / 1_000).toFixed(1)}K`;
  }

  if (value >= 1) {
    return `$${value.toFixed(2)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function tokenAmount(value: number) {
  if (!Number.isFinite(value)) return "â€”";

  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value);
}

function age(timestamp: number) {
  const seconds = Math.max(
    0,
    Math.floor((Date.now() - timestamp) / 1000),
  );

  if (seconds < 60) return `${seconds}s ago`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;

  return `${Math.floor(minutes / 60)}h ago`;
}

function scoreTone(score: number) {
  if (score >= 75) return "text-emerald-300";
  if (score >= 50) return "text-amber-300";
  return "text-zinc-300";
}

function SignalCard({
  signal,
}: {
  signal: SmartMoneySignal;
}) {
  const totalTrades =
    (signal.buys5m ?? 0) +
    (signal.sells5m ?? 0);

  const buyShare =
    totalTrades > 0
      ? Math.round(
          ((signal.buys5m ?? 0) / totalTrades) * 100,
        )
      : null;

  return (
    <article className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2">
            <h3 className="text-xl font-semibold text-white">
              {signal.symbol}
            </h3>

            {signal.classification === "cluster" && (
              <span className="rounded-full border border-emerald-400/20 bg-emerald-400/10 px-2 py-1 text-[10px] font-semibold uppercase tracking-[0.16em] text-emerald-300">
                wallet cluster
              </span>
            )}
          </div>

          <p className="mt-1 text-sm text-zinc-500">
            {signal.name}
          </p>

          <p className="mt-2 font-mono text-xs text-zinc-600">
            {short(signal.mint)}
          </p>
        </div>

        <div className="text-right">
          <div
            className={`text-3xl font-semibold ${scoreTone(
              signal.attentionScore,
            )}`}
          >
            {signal.attentionScore}
          </div>
          <div className="text-[10px] uppercase tracking-[0.18em] text-zinc-600">
            attention
          </div>
        </div>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Tracked wallets
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {signal.walletCount}
          </div>
        </div>

        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Inflow events
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {signal.eventCount}
          </div>
        </div>

        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Liquidity
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {money(signal.liquidityUsd)}
          </div>
        </div>

        <div className="rounded-xl border border-white/5 bg-black/20 p-3">
          <div className="text-xs text-zinc-500">
            Market cap
          </div>
          <div className="mt-1 text-lg font-semibold text-white">
            {money(signal.marketCap ?? signal.fdv)}
          </div>
        </div>
      </div>

      <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2 text-xs text-zinc-400">
        <span>
          Last inflow:{" "}
          <strong className="text-zinc-200">
            {age(signal.latestTimestamp)}
          </strong>
        </span>

        <span>
          Observed token inflow:{" "}
          <strong className="text-zinc-200">
            {tokenAmount(signal.totalTokenInflow)}
          </strong>
        </span>

        <span>
          5m volume:{" "}
          <strong className="text-zinc-200">
            {money(signal.volume5m)}
          </strong>
        </span>

        <span>
          5m buy share:{" "}
          <strong className="text-zinc-200">
            {buyShare === null ? "â€”" : `${buyShare}%`}
          </strong>
        </span>
      </div>

      <div className="mt-4">
        <div className="mb-2 text-[10px] uppercase tracking-[0.16em] text-zinc-600">
          wallets observed
        </div>

        <div className="flex flex-wrap gap-2">
          {signal.wallets.map((wallet) => (
            <span
              key={wallet}
              className="rounded-lg border border-white/5 bg-black/20 px-2 py-1 font-mono text-[11px] text-zinc-400"
            >
              {short(wallet)}
            </span>
          ))}
        </div>
      </div>

      <div className="mt-5 flex flex-wrap gap-3">
        <Link
          href={`/token/${signal.mint}`}
          className="inline-flex items-center gap-2 rounded-xl border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-xs font-medium text-emerald-300 transition hover:bg-emerald-400/15"
        >
          Analyze token
          <ExternalLink className="h-3.5 w-3.5" />
        </Link>

        {signal.dexUrl && (
          <a
            href={signal.dexUrl}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 transition hover:bg-white/5"
          >
            DexScreener
            <ExternalLink className="h-3.5 w-3.5" />
          </a>
        )}
      </div>
    </article>
  );
}

export default function SmartMoneyPage() {
  const [walletText, setWalletText] = useState("");
  const [wallets, setWallets] = useState<string[]>([]);
  const [data, setData] =
    useState<SmartMoneyResponse | null>(null);

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [lastEventAt, setLastEventAt] =
    useState<number | null>(null);

  const runningRef = useRef(false);
  const refreshTimerRef =
    useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    const saved = localStorage.getItem(STORAGE_KEY);

    if (!saved) return;

    try {
      const parsed = JSON.parse(saved) as unknown;

      if (Array.isArray(parsed)) {
        const values = parsed.filter(
          (value): value is string =>
            typeof value === "string",
        );

        setWallets(values);
        setWalletText(values.join("\n"));
      }
    } catch {
      // Ignore malformed local storage.
    }
  }, []);

  const parsedWallets = useMemo(() => {
    return Array.from(
      new Set(
        walletText
          .split(/[\n,\s]+/)
          .map((value) => value.trim())
          .filter(Boolean),
      ),
    ).slice(0, 12);
  }, [walletText]);

  const analyze = useCallback(
    async (
      addresses: string[] = wallets,
      silent = false,
    ) => {
      if (addresses.length === 0 || runningRef.current) {
        return;
      }

      runningRef.current = true;

      if (!silent) setLoading(true);
      setError("");

      try {
        const response = await fetch(
          "/api/smart-money/solana",
          {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              wallets: addresses,
              windowMinutes: 30,
              signatureLimit: 8,
            }),
          },
        );

        const result = await response.json();

        if (!response.ok) {
          throw new Error(
            result.error || "Smart Money scan failed.",
          );
        }

        setData(result as SmartMoneyResponse);
      } catch (scanError) {
        setError(
          scanError instanceof Error
            ? scanError.message
            : "Smart Money scan failed.",
        );
      } finally {
        runningRef.current = false;
        setLoading(false);
      }
    },
    [wallets],
  );

  const saveAndAnalyze = async () => {
    if (parsedWallets.length === 0) {
      setError("Masukkan minimal satu wallet Solana.");
      return;
    }

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(parsedWallets),
    );

    setWallets(parsedWallets);
    await analyze(parsedWallets);
  };

  // Reuse the Stage 05.1 wallet SSE stream.
  // On free RPC plans, keep live streams to the first five wallets.
  useEffect(() => {
    if (wallets.length === 0) return;

    const liveWallets = wallets.slice(0, 5);
    const sources: EventSource[] = [];

    const scheduleRefresh = () => {
      setLastEventAt(Date.now());

      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current);
      }

      refreshTimerRef.current = setTimeout(() => {
        void analyze(wallets, true);
      }, 650);
    };

    for (const wallet of liveWallets) {
      const source = new EventSource(
        `/api/wallet/stream/${encodeURIComponent(wallet)}`,
      );

      source.onmessage = scheduleRefresh;
      sources.push(source);
    }

    const fallback = window.setInterval(() => {
      void analyze(wallets, true);
    }, 20_000);

    return () => {
      sources.forEach((source) => source.close());
      window.clearInterval(fallback);

      if (refreshTimerRef.current) {
        clearTimeout(refreshTimerRef.current);
      }
    };
  }, [wallets, analyze]);

  useEffect(() => {
    if (wallets.length > 0 && !data) {
      void analyze(wallets, true);
    }
  }, [wallets, data, analyze]);

  const clusters =
    data?.signals.filter(
      (signal) => signal.walletCount >= 2,
    ) ?? [];

  const singles =
    data?.signals.filter(
      (signal) => signal.walletCount === 1,
    ) ?? [];

  return (
    <main className="mx-auto w-full max-w-[1500px] px-4 py-6 lg:px-8">
      <section className="mb-7 flex flex-wrap items-start justify-between gap-5">
        <div>
          <div className="mb-2 flex items-center gap-2 text-xs uppercase tracking-[0.2em] text-emerald-300">
            <Radio className="h-4 w-4" />
            Stage 08
          </div>

          <h1 className="text-3xl font-semibold tracking-tight text-white">
            Smart Money Radar
          </h1>

          <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-400">
            Detect the same token flowing into multiple tracked
            Solana wallets. Wallet events trigger an event-driven
            refresh; a polling fallback keeps the board current.
          </p>
        </div>

        <div className="flex items-center gap-2 rounded-full border border-emerald-400/20 bg-emerald-400/10 px-3 py-2 text-xs text-emerald-300">
          <span className="h-2 w-2 animate-pulse rounded-full bg-emerald-300" />
          {wallets.length > 0
            ? `Live watch Â· ${Math.min(wallets.length, 5)} wallets`
            : "Waiting for wallets"}
        </div>
      </section>

      <section className="grid gap-5 xl:grid-cols-[380px_minmax(0,1fr)]">
        <aside className="space-y-5">
          <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
            <div className="flex items-center gap-2 text-sm font-medium text-white">
              <WalletCards className="h-4 w-4 text-emerald-300" />
              Tracked wallets
            </div>

            <p className="mt-2 text-xs leading-5 text-zinc-500">
              One wallet per line. Maximum 12. The first five
              use the live wallet stream; all wallets are covered
              by fallback refresh.
            </p>

            <textarea
              value={walletText}
              onChange={(event) =>
                setWalletText(event.target.value)
              }
              placeholder={"WalletAddress1\nWalletAddress2\nWalletAddress3"}
              className="mt-4 min-h-44 w-full resize-y rounded-xl border border-white/10 bg-black/30 p-3 font-mono text-xs text-zinc-200 outline-none transition placeholder:text-zinc-700 focus:border-emerald-400/30"
            />

            <button
              onClick={saveAndAnalyze}
              disabled={loading}
              className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl bg-white px-4 py-3 text-sm font-semibold text-black transition hover:bg-zinc-200 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {loading ? (
                <RefreshCw className="h-4 w-4 animate-spin" />
              ) : (
                <Save className="h-4 w-4" />
              )}
              Save & analyze
            </button>

            {wallets.length > 0 && (
              <button
                onClick={() => void analyze(wallets)}
                disabled={loading}
                className="mt-2 flex w-full items-center justify-center gap-2 rounded-xl border border-white/10 px-4 py-3 text-sm text-zinc-300 transition hover:bg-white/5 disabled:opacity-50"
              >
                <RefreshCw className="h-4 w-4" />
                Refresh now
              </button>
            )}
          </div>

          <div className="rounded-2xl border border-amber-400/15 bg-amber-400/[0.04] p-4">
            <div className="flex gap-3">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-300" />

              <p className="text-xs leading-5 text-amber-100/70">
                â€œSmart moneyâ€ here means wallets you choose to
                track. Stage 08 detects accumulation clusters; it
                does not yet claim those wallets are profitable.
                Historical PnL / win-rate scoring comes later.
              </p>
            </div>
          </div>

          {data && (
            <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-5">
              <div className="text-[10px] uppercase tracking-[0.18em] text-zinc-600">
                Scan diagnostics
              </div>

              <div className="mt-4 grid grid-cols-2 gap-3 text-sm">
                <div>
                  <div className="text-zinc-500">
                    Wallets
                  </div>
                  <div className="mt-1 text-white">
                    {data.walletsAnalyzed}/{data.walletsRequested}
                  </div>
                </div>

                <div>
                  <div className="text-zinc-500">
                    Transactions
                  </div>
                  <div className="mt-1 text-white">
                    {data.transactionsInspected}
                  </div>
                </div>

                <div>
                  <div className="text-zinc-500">
                    Window
                  </div>
                  <div className="mt-1 text-white">
                    {data.windowMinutes}m
                  </div>
                </div>

                <div>
                  <div className="text-zinc-500">
                    Last event
                  </div>
                  <div className="mt-1 text-white">
                    {lastEventAt
                      ? age(lastEventAt)
                      : "â€”"}
                  </div>
                </div>
              </div>
            </div>
          )}
        </aside>

        <div className="min-w-0">
          {error && (
            <div className="mb-5 rounded-2xl border border-red-400/20 bg-red-400/[0.05] p-4 text-sm text-red-200">
              {error}
            </div>
          )}

          {!data && !loading && (
            <div className="flex min-h-[420px] flex-col items-center justify-center rounded-2xl border border-dashed border-white/10 bg-white/[0.015] p-8 text-center">
              <Zap className="h-8 w-8 text-emerald-300" />
              <h2 className="mt-4 text-lg font-semibold text-white">
                Add wallets to start the radar
              </h2>
              <p className="mt-2 max-w-md text-sm leading-6 text-zinc-500">
                MemeScope will look for recent token inflows and
                highlight tokens appearing across multiple tracked
                wallets.
              </p>
            </div>
          )}

          {loading && !data && (
            <div className="flex min-h-[420px] items-center justify-center rounded-2xl border border-white/10 bg-white/[0.015]">
              <div className="text-center">
                <RefreshCw className="mx-auto h-6 w-6 animate-spin text-emerald-300" />
                <div className="mt-3 text-sm text-zinc-400">
                  Scanning tracked walletsâ€¦
                </div>
              </div>
            </div>
          )}

          {data && (
            <div className="space-y-7">
              <section>
                <div className="mb-3 flex items-end justify-between gap-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <Users className="h-4 w-4 text-emerald-300" />
                      <h2 className="text-lg font-semibold text-white">
                        Accumulation clusters
                      </h2>
                    </div>
                    <p className="mt-1 text-xs text-zinc-500">
                      Same token observed flowing into 2+ tracked wallets.
                    </p>
                  </div>

                  <div className="text-xs text-zinc-600">
                    {clusters.length} detected
                  </div>
                </div>

                {clusters.length > 0 ? (
                  <div className="grid gap-4 2xl:grid-cols-2">
                    {clusters.map((signal) => (
                      <SignalCard
                        key={signal.mint}
                        signal={signal}
                      />
                    ))}
                  </div>
                ) : (
                  <div className="rounded-2xl border border-white/10 bg-white/[0.015] p-6 text-sm text-zinc-500">
                    No multi-wallet accumulation cluster was
                    observed in the current window.
                  </div>
                )}
              </section>

              <section>
                <div className="mb-3 flex items-end justify-between gap-4">
                  <div>
                    <div className="flex items-center gap-2">
                      <Activity className="h-4 w-4 text-zinc-400" />
                      <h2 className="text-lg font-semibold text-white">
                        Single-wallet inflows
                      </h2>
                    </div>
                    <p className="mt-1 text-xs text-zinc-500">
                      Useful context, but weaker than a wallet cluster.
                    </p>
                  </div>

                  <div className="text-xs text-zinc-600">
                    {singles.length} tokens
                  </div>
                </div>

                <div className="grid gap-4 2xl:grid-cols-2">
                  {singles.slice(0, 12).map((signal) => (
                    <SignalCard
                      key={signal.mint}
                      signal={signal}
                    />
                  ))}
                </div>
              </section>

              {data.warnings.length > 0 && (
                <section className="rounded-2xl border border-amber-400/15 bg-amber-400/[0.03] p-4">
                  <div className="text-xs font-medium text-amber-200">
                    Partial scan warnings
                  </div>

                  <div className="mt-2 space-y-1 font-mono text-[11px] text-amber-100/60">
                    {data.warnings.map((warning) => (
                      <div key={warning}>{warning}</div>
                    ))}
                  </div>
                </section>
              )}
            </div>
          )}
        </div>
      </section>
    </main>
  );
}