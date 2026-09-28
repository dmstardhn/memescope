"use client";
import {
  SignalPresetManager,
} from "@/components/signal-preset-manager";

import Link from "next/link";
import {
  SignalPerformancePanel,
} from "@/components/signal-performance-panel";
import {
  Bell,
  BellRing,
  ExternalLink,
  RefreshCw,
  Search,
  ShieldAlert,
  Signal,
  SlidersHorizontal,
  Sparkles,
  Zap,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import {
  generateSignals,
} from "@/lib/signal-engine";
import type {
  SignalCall,
  SignalSettings,
} from "@/lib/signal-types";
import type {
  TerminalResponse,
} from "@/lib/terminal-types";

const SETTINGS_KEY =
  "memescope-signal-settings";

const SEEN_KEY =
  "memescope-seen-signals-v1";

const DEFAULT_SETTINGS: SignalSettings = {
  minSignalScore: 80,
  minLiquidityUsd: 50_000,
  maxPairAgeHours: 24,
};

function money(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

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

function percent(value: number | null) {
  if (value === null) return "N/A";

  return `${value > 0 ? "+" : ""}${value.toFixed(
    2,
  )}%`;
}

function age(minutes: number | null) {
  if (minutes === null) return "N/A";

  if (minutes < 60) {
    return `${Math.floor(minutes)}m`;
  }

  if (minutes < 1_440) {
    return `${Math.floor(
      minutes / 60,
    )}h`;
  }

  return `${Math.floor(
    minutes / 1_440,
  )}d`;
}

function scoreTone(
  signal: SignalCall,
) {
  if (signal.direction === "caution") {
    return "text-amber-300";
  }

  if (signal.signalScore >= 90) {
    return "text-emerald-300";
  }

  return "text-cyan-300";
}

function buyRationale(
  signal: SignalCall,
) {
  if (signal.direction === "caution") {
    return {
      summary:
        "This is not a BUY setup yet. MemeScope is flagging elevated activity, but the current conditions also carry material reversal or liquidity risk.",
      points:
        signal.caution.length > 0
          ? signal.caution
          : [
              "The current market structure does not meet the rule set for a watch-side setup.",
            ],
    };
  }

  const points: string[] = [];

  if (signal.buyShare5m !== null) {
    const buyPercent = Math.round(
      signal.buyShare5m * 100,
    );

    const sellPercent =
      100 - buyPercent;

    if (buyPercent >= 65) {
      points.push(
        `Buy pressure is dominant: ${buyPercent}% buys versus ${sellPercent}% sells in the latest 5m window.`,
      );
    } else if (buyPercent >= 60) {
      points.push(
        `Buy pressure has an edge: ${buyPercent}% buys versus ${sellPercent}% sells in the latest 5m window.`,
      );
    }
  }

  if (
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 1.3
  ) {
    points.push(
      `Volume is expanding: the latest 5m pace is ${signal.volumeSpike5m.toFixed(
        2,
      )}x the recent 1h average 5m pace.`,
    );
  }

  if (signal.liquidityUsd >= 50_000) {
    points.push(
      `Liquidity is relatively deeper for this screen at about ${money(
        signal.liquidityUsd,
      )}.`,
    );
  } else if (signal.liquidityUsd >= 20_000) {
    points.push(
      `Liquidity passes the setup threshold at about ${money(
        signal.liquidityUsd,
      )}, although execution risk remains higher than in deeper pools.`,
    );
  }

  if (
    signal.priceChange5m !== null &&
    signal.priceChange5m > 0 &&
    signal.priceChange5m <= 15
  ) {
    points.push(
      `Short-term momentum is positive at ${percent(
        signal.priceChange5m,
      )} over 5m without crossing the engine's main overheated threshold.`,
    );
  }

  if (
    signal.pairAgeMinutes !== null &&
    signal.pairAgeMinutes <= 360
  ) {
    points.push(
      `The pair is still early at roughly ${age(
        signal.pairAgeMinutes,
      )} old, so the setup is being detected during an early activity window.`,
    );
  }

  if (points.length === 0) {
    points.push(...signal.reasons);
  }

  let summary =
    "MemeScope confirmed a high-quality momentum setup after strict market filters and repeated detection.";

  if (
    signal.buyShare5m !== null &&
    signal.buyShare5m >= 0.65 &&
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 1.7
  ) {
    summary =
      "Main thesis: buyer pressure, controlled volume acceleration, liquidity depth, and momentum structure are aligned.";
  } else if (
    signal.volumeSpike5m !== null &&
    signal.volumeSpike5m >= 2.5
  ) {
    summary =
      "Main thesis: activity is accelerating inside the engine's preferred non-extreme range.";
  } else if (
    signal.buyShare5m !== null &&
    signal.buyShare5m >= 0.60
  ) {
    summary =
      "Main thesis: recent transaction flow favors buyers while the hard quality gates remain satisfied.";
  }

  return {
    summary,
    points,
  };
}
function SignalCard({
  signal,
}: {
  signal: SignalCall;
}) {
  const rationale = buyRationale(signal);

  return (
    <article
      className={`rounded-2xl border p-5 ${
        signal.direction === "caution"
          ? "border-amber-400/15 bg-amber-400/[0.025]"
          : "border-white/10 bg-white/[0.025]"
      }`}
    >
      <div className="flex items-start justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          {signal.imageUrl ? (
            <img
              src={signal.imageUrl}
              alt=""
              className="h-11 w-11 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full border border-white/10 bg-black/20 text-xs font-bold text-zinc-500">
              {signal.symbol.slice(0, 2)}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="text-lg font-semibold text-white">
                {signal.symbol}
              </h3>

              <span
                className={`rounded-full border px-2 py-1 text-[9px] font-semibold uppercase tracking-[0.12em] ${
                  signal.direction === "caution"
                    ? "border-amber-400/20 bg-amber-400/10 text-amber-300"
                    : "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                }`}
              >
                {signal.label}
              </span>
            </div>

            <div className="mt-1 truncate text-xs text-zinc-600">
              {signal.name}
            </div>
          </div>
        </div>

        <div className="text-right">
          <div
            className={`text-3xl font-semibold ${scoreTone(
              signal,
            )}`}
          >
            {signal.signalScore}
          </div>

          <div className="text-[9px] uppercase tracking-[0.15em] text-zinc-700">
            signal score
          </div>
        </div>
      </div>

      <div className="mt-5 grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-7">
        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Price
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {money(signal.priceUsd)}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            5m
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {percent(
              signal.priceChange5m,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Age
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {age(
              signal.pairAgeMinutes,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Liquidity
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {money(
              signal.liquidityUsd,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Vol 5m
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {money(
              signal.volume5m,
            )}
          </div>
        </div>

        <div className="rounded-xl bg-black/20 p-3">
          <div className="text-[10px] text-zinc-600">
            Buy share
          </div>
          <div className="mt-1 text-xs font-medium text-white">
            {signal.buyShare5m !== null
              ? `${Math.round(
                  signal.buyShare5m * 100,
                )}%`
              : "N/A"}
          </div>
        </div>

        <div className="rounded-xl border border-emerald-400/10 bg-emerald-400/[0.035] p-3">
          <div className="text-[10px] text-zinc-600">
            Potential TP
          </div>
          <div className="mt-1 text-xs font-semibold text-emerald-300">
            +{signal.potentialTargetPercent.toFixed(1)}%
          </div>
        </div>
      </div>

      <div className="mt-5 grid gap-4 lg:grid-cols-2">

        <div>
          <div className="mb-2 text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            {signal.direction === "watch"
              ? "Why this BUY setup appeared"
              : "Why this is NOT a BUY yet"}
          </div>

          <div
            className={`mb-3 rounded-xl border p-3 text-xs leading-5 ${
              signal.direction === "watch"
                ? "border-emerald-400/15 bg-emerald-400/[0.04] text-emerald-100/80"
                : "border-amber-400/15 bg-amber-400/[0.04] text-amber-100/80"
            }`}
          >
            {rationale.summary}
          </div>

          <div className="space-y-2">
            {rationale.points.map(
              (reason) => (
                <div
                  key={reason}
                  className="flex gap-2 text-xs leading-5 text-zinc-300"
                >
                  <span
                    className={`mt-2 h-1 w-1 shrink-0 rounded-full ${
                      signal.direction === "watch"
                        ? "bg-emerald-300"
                        : "bg-amber-300"
                    }`}
                  />
                  {reason}
                </div>
              ),
            )}
          </div>

          {signal.direction === "watch" && (
            <div className="mt-3 text-[10px] leading-4 text-zinc-700">
              High-quality classification requires strict market filters plus two consecutive detections. Score is not a win probability and Potential TP is not guaranteed.
            </div>
          )}
        </div>
<div>
          <div className="mb-2 text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Caution
          </div>

          {signal.caution.length > 0 ? (
            <div className="space-y-2">
              {signal.caution.map(
                (item) => (
                  <div
                    key={item}
                    className="flex gap-2 text-xs leading-5 text-amber-100/70"
                  >
                    <ShieldAlert className="mt-0.5 h-3.5 w-3.5 shrink-0 text-amber-300" />
                    {item}
                  </div>
                ),
              )}
            </div>
          ) : (
            <div className="text-xs text-zinc-600">
              No additional caution flag from
              the current market snapshot.
            </div>
          )}
        </div>
      </div>

      <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-white/5 pt-4">
        <div className="flex flex-wrap gap-2 text-[10px] text-zinc-600">
          <span>
            Confidence:{" "}
            <strong className="text-zinc-300">
              {signal.confidence}
            </strong>
          </span>

          <span>|</span>

          <span>
            Activity:{" "}
            <strong className="text-zinc-300">
              {signal.activityScore}
            </strong>
          </span>

          <span>|</span>

          <span>
            Spike:{" "}
            <strong className="text-zinc-300">
              {signal.volumeSpike5m !== null
                ? `${signal.volumeSpike5m.toFixed(
                    2,
                  )}x`
                : "N/A"}
            </strong>
          </span>
        </div>

        <div className="flex gap-2">
          <Link
            href={`/token/${signal.tokenAddress}`}
            className="rounded-lg border border-emerald-400/15 bg-emerald-400/[0.06] px-3 py-2 text-[11px] text-emerald-300"
          >
            Analyze risk
          </Link>

          {signal.dexUrl && (
            <a
              href={signal.dexUrl}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-1.5 rounded-lg border border-white/10 px-3 py-2 text-[11px] text-zinc-400 hover:text-white"
            >
              Dex
              <ExternalLink className="h-3 w-3" />
            </a>
          )}
        </div>
      </div>
    </article>
  );
}

export default function SignalsPage() {
  const [data, setData] =
    useState<TerminalResponse | null>(
      null,
    );

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  const [query, setQuery] =
    useState("");

  const [settings, setSettings] =
    useState<SignalSettings>(
      DEFAULT_SETTINGS,
    );

  const [browserAlerts, setBrowserAlerts] =
    useState(false);

  const initialLoadRef =
    useRef(true);

  const confirmationRef =
    useRef<Map<string, number>>(
      new Map(),
    );

  const [confirmedIds, setConfirmedIds] =
    useState<Set<string>>(
      new Set(),
    );

  useEffect(() => {
    const raw =
      localStorage.getItem(
        SETTINGS_KEY,
      );

    if (!raw) return;

    try {
      setSettings({
        ...DEFAULT_SETTINGS,
        ...(JSON.parse(
          raw,
        ) as Partial<SignalSettings>),
      });
    } catch {
      // Ignore malformed saved settings.
    }
  }, []);

  async function load(
    silent = false,
  ) {
    if (!silent) {
      setLoading(true);
    }

    try {
      const response = await fetch(
        "/api/terminal/solana",
        {
          cache: "no-store",
        },
      );

      const result =
        (await response.json()) as
          | TerminalResponse
          | { error?: string };

      if (!response.ok) {
        throw new Error(
          "error" in result
            ? result.error
            : "Signal feed failed.",
        );
      }

      setData(
        result as TerminalResponse,
      );

      setError("");
    } catch (loadError) {
      setError(
        loadError instanceof Error
          ? loadError.message
          : "Signal feed failed.",
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();

    const timer = window.setInterval(
      () => {
        void load(true);
      },
      10_000,
    );

    return () =>
      window.clearInterval(timer);
  }, []);

  const allSignals = useMemo(() => {
    return generateSignals(
      data?.tokens ?? [],
    );
  }, [data]);

  useEffect(() => {
    const liveIds = new Set(
      allSignals.map(
        (signal) => signal.id,
      ),
    );

    for (
      const id of Array.from(
        confirmationRef.current.keys(),
      )
    ) {
      if (!liveIds.has(id)) {
        confirmationRef.current.delete(id);
      }
    }

    for (const signal of allSignals) {
      const previous =
        confirmationRef.current.get(
          signal.id,
        ) ?? 0;

      confirmationRef.current.set(
        signal.id,
        Math.min(2, previous + 1),
      );
    }

    setConfirmedIds(
      new Set(
        Array.from(
          confirmationRef.current.entries(),
        )
          .filter(
            ([, count]) =>
              count >= 2,
          )
          .map(([id]) => id),
      ),
    );
  }, [allSignals]);

  const confirmedSignals =
    useMemo(
      () =>
        allSignals.filter(
          (signal) =>
            confirmedIds.has(
              signal.id,
            ),
        ),
      [
        allSignals,
        confirmedIds,
      ],
    );

  const visibleSignals = useMemo(() => {
    const needle =
      query.trim().toLowerCase();

    return confirmedSignals.filter(
      (signal) => {
        if (
          signal.signalScore <
          settings.minSignalScore
        ) {
          return false;
        }

        if (
          signal.liquidityUsd <
          settings.minLiquidityUsd
        ) {
          return false;
        }

        if (
          settings.maxPairAgeHours > 0 &&
          signal.pairAgeMinutes !==
            null &&
          signal.pairAgeMinutes >
            settings.maxPairAgeHours *
              60
        ) {
          return false;
        }

        if (
          needle &&
          !signal.symbol
            .toLowerCase()
            .includes(needle) &&
          !signal.name
            .toLowerCase()
            .includes(needle) &&
          !signal.tokenAddress
            .toLowerCase()
            .includes(needle)
        ) {
          return false;
        }

        return true;
      },
    );
  }, [
    confirmedSignals,
    query,
    settings,
  ]);

  useEffect(() => {
    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify(settings),
    );
  }, [settings]);

  useEffect(() => {
    if (
      initialLoadRef.current
    ) {
      initialLoadRef.current = false;

      localStorage.setItem(
        SEEN_KEY,
        JSON.stringify(
          visibleSignals.map(
            (signal) => signal.id,
          ),
        ),
      );

      return;
    }

    if (
      !browserAlerts ||
      typeof Notification ===
        "undefined" ||
      Notification.permission !==
        "granted"
    ) {
      return;
    }

    let seen: string[] = [];

    try {
      seen = JSON.parse(
        localStorage.getItem(
          SEEN_KEY,
        ) ?? "[]",
      ) as string[];
    } catch {
      seen = [];
    }

    const seenSet = new Set(seen);

    const fresh = visibleSignals.filter(
      (signal) =>
        signal.direction === "watch" &&
        !seenSet.has(signal.id),
    );

    for (const signal of fresh.slice(
      0,
      3,
    )) {
      new Notification(
        `MemeScope - ${signal.label}`,
        {
          body: `${signal.symbol} - score ${signal.signalScore} - liq ${money(
            signal.liquidityUsd,
          )}`,
        },
      );
    }

    localStorage.setItem(
      SEEN_KEY,
      JSON.stringify(
        visibleSignals
          .map(
            (signal) => signal.id,
          )
          .slice(0, 200),
      ),
    );
  }, [
    visibleSignals,
    browserAlerts,
  ]);

  async function enableAlerts() {
    if (
      typeof Notification ===
      "undefined"
    ) {
      setError(
        "Browser notifications are not supported here.",
      );
      return;
    }

    const permission =
      await Notification.requestPermission();

    setBrowserAlerts(
      permission === "granted",
    );
  }

  const watchSignals =
    visibleSignals.filter(
      (signal) =>
        signal.direction === "watch",
    );

  const cautionSignals =
    visibleSignals.filter(
      (signal) =>
        signal.direction === "caution",
    );

  return (
    <main className="mx-auto w-full max-w-[1600px] px-4 py-6 lg:px-7">
      <section className="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.2em] text-emerald-300">
            <Signal className="h-3.5 w-3.5" />
            MemeScope Signal Engine
          </div>

          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-white">
            Signal Calls
          </h1>

          <p className="mt-2 max-w-3xl text-sm leading-6 text-zinc-500">
            High-quality market setups filtered by liquidity, transaction
            participation, controlled volume acceleration, buy pressure,
            valuation depth, pair age and 5m/1h momentum. A setup must persist
            across two consecutive scans before it is confirmed.
          </p>
        </div>

        <div className="flex flex-wrap gap-2">
          <button
            onClick={enableAlerts}
            className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
              browserAlerts
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : "border-white/10 text-zinc-400 hover:bg-white/5"
            }`}
          >
            {browserAlerts ? (
              <BellRing className="h-3.5 w-3.5" />
            ) : (
              <Bell className="h-3.5 w-3.5" />
            )}
            {browserAlerts
              ? "Browser alerts on"
              : "Enable alerts"}
          </button>

          <button
            onClick={() =>
              void load()
            }
            disabled={loading}
            className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5"
          >
            <RefreshCw
              className={`h-3.5 w-3.5 ${
                loading
                  ? "animate-spin"
                  : ""
              }`}
            />
            Refresh
          </button>
        </div>
      </section>

      <section className="mb-5 grid grid-cols-2 gap-2 lg:grid-cols-4">
        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Confirmed HQ signals
          </div>
          <div className="mt-1 text-2xl font-semibold text-emerald-300">
            {watchSignals.length}
          </div>
        </div>

        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Confirmation
          </div>
          <div className="mt-1 text-2xl font-semibold text-cyan-300">
            2x
          </div>
        </div>

        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Highest score
          </div>
          <div className="mt-1 text-2xl font-semibold text-white">
            {visibleSignals[0]?.signalScore ?? "N/A"}
          </div>
        </div>

        <div className="rounded-xl border border-white/10 bg-white/[0.025] p-4">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
            Refresh
          </div>
          <div className="mt-1 text-2xl font-semibold text-white">
            10s
          </div>
        </div>
      </section>

      <section className="mb-5 rounded-2xl border border-white/10 bg-white/[0.02] p-4">
        <div className="relative">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />

          <input
            value={query}
            onChange={(event) =>
              setQuery(event.target.value)
            }
            placeholder="Search token, symbol or mint"
            className="w-full rounded-xl border border-white/10 bg-black/25 py-3 pl-10 pr-3 text-sm text-white outline-none placeholder:text-zinc-700 focus:border-emerald-400/30"
          />
        </div>

        <div className="mt-4 grid gap-4 xl:grid-cols-3">

          <div>
            <div className="mb-2 text-[10px] font-medium uppercase tracking-[0.15em] text-zinc-600">
              Minimum Signal Score
            </div>

            <div className="flex flex-wrap gap-2">
              {[80, 85, 90, 95].map((value) => (
                <button
                  key={value}
                  type="button"
                  onClick={() =>
                    setSettings((current) => ({
                      ...current,
                      minSignalScore: value,
                    }))
                  }
                  className={`rounded-lg border px-3 py-2 text-xs transition ${
                    settings.minSignalScore === value
                      ? "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"
                      : "border-white/10 bg-black/20 text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
                  }`}
                >
                  {value}+
                </button>
              ))}
            </div>
          </div>

          <div>
            <div className="mb-2 text-[10px] font-medium uppercase tracking-[0.15em] text-zinc-600">
              Minimum Liquidity
            </div>

            <div className="flex flex-wrap gap-2">
              {[
                { value: 50000, label: "$50K+" },
                { value: 75000, label: "$75K+" },
                { value: 100000, label: "$100K+" },
                { value: 250000, label: "$250K+" },
              ].map((item) => (
                <button
                  key={item.value}
                  type="button"
                  onClick={() =>
                    setSettings((current) => ({
                      ...current,
                      minLiquidityUsd: item.value,
                    }))
                  }
                  className={`rounded-lg border px-3 py-2 text-xs transition ${
                    settings.minLiquidityUsd === item.value
                      ? "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"
                      : "border-white/10 bg-black/20 text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
                  }`}
                >
                  {item.label}
                </button>
              ))}
            </div>
          </div>

          <div>
            <div className="mb-2 text-[10px] font-medium uppercase tracking-[0.15em] text-zinc-600">
              Maximum Pair Age
            </div>

            <div className="flex flex-wrap gap-2">
              {[
                { value: 6, label: "6h max" },
                { value: 12, label: "12h max" },
                { value: 24, label: "24h max" },
              ].map((item) => (
                <button
                  key={item.value}
                  type="button"
                  onClick={() =>
                    setSettings((current) => ({
                      ...current,
                      maxPairAgeHours: item.value,
                    }))
                  }
                  className={`rounded-lg border px-3 py-2 text-xs transition ${
                    settings.maxPairAgeHours === item.value
                      ? "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"
                      : "border-white/10 bg-black/20 text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
                  }`}
                >
                  {item.label}
                </button>
              ))}
            </div>
          </div>

        </div>
      </section>

      <SignalPresetManager
        settings={{
          minSignalScore:
            settings.minSignalScore,
          minLiquidityUsd:
            settings.minLiquidityUsd,
          maxPairAgeHours:
            settings.maxPairAgeHours,
        }}
        onApply={(preset) =>
          setSettings(
            (current) => ({
              ...current,
              ...preset,
            }),
          )
        }
      />
      {error && (
        <div className="mb-5 rounded-xl border border-red-400/20 bg-red-400/[0.05] p-3 text-sm text-red-200">
          {error}
        </div>
      )}

      {loading && !data ? (
        <div className="flex min-h-[400px] items-center justify-center gap-2 rounded-2xl border border-white/10 text-sm text-zinc-500">
          <RefreshCw className="h-4 w-4 animate-spin" />
          Building signal feed...
        </div>
      ) : (
        <div className="space-y-8">
          <section>
            <div className="mb-3 flex items-end justify-between gap-3">
              <div>
                <div className="flex items-center gap-2">
                  <Zap className="h-4 w-4 text-emerald-300" />
                  <h2 className="text-lg font-semibold text-white">
                    High Quality Signals
                  </h2>
                </div>

                <p className="mt-1 text-xs text-zinc-600">
                  Strict-filter setups confirmed in two consecutive scans.
                </p>
              </div>

              <span className="text-xs text-zinc-700">
                {watchSignals.length} HQ calls
              </span>
            </div>

            {watchSignals.length > 0 ? (
              <div className="grid gap-4 2xl:grid-cols-2">
                {watchSignals.map(
                  (signal) => (
                    <SignalCard
                      key={signal.id}
                      signal={signal}
                    />
                  ),
                )}
              </div>
            ) : (
              <div className="rounded-2xl border border-dashed border-white/10 p-10 text-center">
                <Sparkles className="mx-auto h-6 w-6 text-zinc-700" />

                <p className="mt-3 text-sm text-zinc-600">
                  No setup currently passes the high-quality filters and two-scan confirmation.
                </p>
              </div>
            )}
          </section>

          {cautionSignals.length > 0 && (
            <section>
              <div className="mb-3 flex items-center gap-2">
                <ShieldAlert className="h-4 w-4 text-amber-300" />
                <h2 className="text-lg font-semibold text-white">
                  Caution Calls
                </h2>
              </div>

              <div className="grid gap-4 2xl:grid-cols-2">
                {cautionSignals.map(
                  (signal) => (
                    <SignalCard
                      key={signal.id}
                      signal={signal}
                    />
                  ),
                )}
              </div>
            </section>
          )}
        </div>
      )}
      <SignalPerformancePanel
        signals={confirmedSignals}
        tokens={data?.tokens ?? []}
      />


      <div className="mt-6 rounded-xl border border-white/5 bg-black/20 p-4 text-[11px] leading-5 text-zinc-600">
        Signal Score measures alignment with the Stage 16 quality rules.
        Potential TP is a heuristic upside estimate from the confirmed entry
        snapshot, not a guaranteed future price. Contract and holder risk should
        still be verified separately with Analyze Risk.
      </div>
    </main>
  );
}