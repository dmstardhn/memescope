"use client";

import {
  Activity,
  BarChart3,
  Clock3,
  Database,
  RefreshCw,
  Save,
  ShieldAlert,
  Target,
  TrendingDown,
  TrendingUp,
} from "lucide-react";
import {
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";

import {
  DEFAULT_SIGNAL_EXIT_SETTINGS,
  type SignalExitSettings,
  type SignalTradingStyle,
} from "@/lib/signal-exit-plan";
import type { SignalCall } from "@/lib/signal-types";
import type { TerminalToken } from "@/lib/terminal-types";

type StoredSignalRecord = {
  id: string;
  signalId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  kind: string;
  label: string;
  openedAt: number;
  lastUpdatedAt: number;
  closedAt: number | null;
  entryPriceUsd: number | null;
  currentPriceUsd: number | null;
  exitPriceUsd: number | null;
  targetPercent: number;
  stopLossPercent: number;
  targetPriceUsd: number | null;
  stopPriceUsd: number | null;
  mode: string;
  style: string;
  planReason: string;
  scoreAtEntry: number;
  lastScore: number;
  signalVisible: boolean;
  status: "active" | "target_hit" | "stop_loss";
  currentGainPercent: number | null;
  peakGainPercent: number | null;
  maxDrawdownPercent: number | null;
};

type GroupStats = {
  key: string;
  total: number;
  active: number;
  closed: number;
  targetHits: number;
  stopLosses: number;
  targetHitRate: number | null;
  averagePeakGain: number | null;
  averageDrawdown: number | null;
};

type SignalAnalytics = {
  periodDays: number;
  total: number;
  active: number;
  closed: number;
  targetHits: number;
  stopLosses: number;
  targetHitRate: number | null;
  averageCurrentGain: number | null;
  averagePeakGain: number | null;
  averageDrawdown: number | null;
  averageHoldMinutes: number | null;
  byKind: GroupStats[];
  byPlan: GroupStats[];
  best: StoredSignalRecord | null;
  worst: StoredSignalRecord | null;
  recent: StoredSignalRecord[];
};

function priceText(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  if (value >= 1) return `$${value.toFixed(4)}`;
  return `$${value.toPrecision(5)}`;
}

function pct(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  return `${value > 0 ? "+" : ""}${value.toFixed(2)}%`;
}

function hold(minutes: number | null) {
  if (minutes === null || !Number.isFinite(minutes)) return "N/A";
  if (minutes < 60) return `${Math.round(minutes)}m`;
  const hours = minutes / 60;
  if (hours < 24) return `${hours.toFixed(1)}h`;
  return `${(hours / 24).toFixed(1)}d`;
}

function recordHold(record: StoredSignalRecord, now: number) {
  return hold(((record.closedAt ?? now) - record.openedAt) / 60_000);
}

function kindLabel(value: string) {
  return value
    .split("-")
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}

function statusLabel(status: StoredSignalRecord["status"]) {
  if (status === "target_hit") return "TARGET HIT";
  if (status === "stop_loss") return "STOP LOSS";
  return "ACTIVE";
}

export function SignalPerformancePanel({
  signals,
  tokens,
}: {
  signals: SignalCall[];
  tokens: TerminalToken[];
}) {
  const [settings, setSettings] = useState<SignalExitSettings>(
    DEFAULT_SIGNAL_EXIT_SETTINGS,
  );
  const [configured, setConfigured] = useState<boolean | null>(null);
  const [analytics, setAnalytics] = useState<SignalAnalytics | null>(null);
  const [history, setHistory] = useState<StoredSignalRecord[]>([]);
  const [periodDays, setPeriodDays] = useState(30);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [recording, setRecording] = useState(false);
  const [message, setMessage] = useState("");
  const [now, setNow] = useState(Date.now());

  const loadSettings = useCallback(async () => {
    try {
      const response = await fetch("/api/signals/settings", {
        cache: "no-store",
      });
      const body = (await response.json()) as {
        configured?: boolean;
        settings?: SignalExitSettings;
        error?: string;
      };

      if (body.configured === false) {
        setConfigured(false);
        return;
      }

      setConfigured(true);
      if (body.settings) setSettings(body.settings);
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : "Failed to load settings.",
      );
    }
  }, []);

  const loadData = useCallback(async () => {
    try {
      const [analyticsResponse, historyResponse] = await Promise.all([
        fetch(`/api/signals/analytics?days=${periodDays}`, {
          cache: "no-store",
        }),
        fetch("/api/signals/history?limit=150", {
          cache: "no-store",
        }),
      ]);

      const analyticsBody = (await analyticsResponse.json()) as {
        configured?: boolean;
        analytics?: SignalAnalytics;
      };

      const historyBody = (await historyResponse.json()) as {
        configured?: boolean;
        records?: StoredSignalRecord[];
      };

      if (
        analyticsBody.configured === false ||
        historyBody.configured === false
      ) {
        setConfigured(false);
        setAnalytics(null);
        setHistory([]);
        return;
      }

      setConfigured(true);
      setAnalytics(analyticsBody.analytics ?? null);
      setHistory(historyBody.records ?? []);
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : "Failed to load analytics.",
      );
    } finally {
      setLoading(false);
    }
  }, [periodDays]);

  const runRecorder = useCallback(
    async (quiet = false) => {
      if (configured === false) return;

      if (!quiet) setRecording(true);

      try {
        const response = await fetch("/api/signals/record", {
          method: "POST",
          cache: "no-store",
        });

        const body = (await response.json()) as {
          configured?: boolean;
          opened?: number;
          updated?: number;
          closed?: number;
          error?: string;
        };

        if (body.configured === false) {
          setConfigured(false);
          return;
        }

        if (!response.ok) {
          throw new Error(body.error ?? "Recorder failed.");
        }

        if (!quiet) {
          setMessage(
            `Recorder: ${body.opened ?? 0} opened, ` +
              `${body.updated ?? 0} updated, ${body.closed ?? 0} closed.`,
          );
        }

        await loadData();
      } catch (error) {
        if (!quiet) {
          setMessage(
            error instanceof Error ? error.message : "Recorder failed.",
          );
        }
      } finally {
        if (!quiet) setRecording(false);
      }
    },
    [configured, loadData],
  );

  useEffect(() => {
    void Promise.all([loadSettings(), loadData()]);
  }, [loadSettings, loadData]);

  // The current Signal feed acts as a heartbeat while this page is open.
  // The recorder itself fetches and evaluates market data on the server.
  useEffect(() => {
    if (configured === false) return;
    void runRecorder(true);
  }, [signals, tokens, configured, runRecorder]);

  useEffect(() => {
    if (configured !== true) return;

    const timer = window.setInterval(() => {
      void loadData();
    }, 20_000);

    return () => window.clearInterval(timer);
  }, [configured, loadData]);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  async function saveSettings() {
    setSaving(true);
    setMessage("");

    try {
      const response = await fetch("/api/signals/settings", {
        method: "PUT",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify(settings),
      });

      const body = (await response.json()) as {
        configured?: boolean;
        settings?: SignalExitSettings;
        error?: string;
      };

      if (body.configured === false) {
        setConfigured(false);
        return;
      }

      if (!response.ok) {
        throw new Error(body.error ?? "Failed to save TP / SL settings.");
      }

      if (body.settings) setSettings(body.settings);

      setMessage(
        "TP / SL settings saved. Existing records keep their original plan; new signals use the new settings.",
      );
    } catch (error) {
      setMessage(
        error instanceof Error ? error.message : "Failed to save settings.",
      );
    } finally {
      setSaving(false);
    }
  }

  const activeRecords = useMemo(
    () => history.filter((record) => record.status === "active"),
    [history],
  );

  if (configured === false) {
    return (
      <section className="mt-8 rounded-2xl border border-amber-400/15 bg-amber-400/[0.035] p-5">
        <div className="flex items-start gap-3">
          <Database className="mt-0.5 h-5 w-5 shrink-0 text-amber-300" />
          <div>
            <h2 className="text-sm font-semibold text-white">
              Server Signal Recorder is installed, but PostgreSQL is not connected
            </h2>
            <p className="mt-2 max-w-3xl text-xs leading-5 text-zinc-500">
              Add DATABASE_URL to .env.local and your Vercel Environment
              Variables. MemeScope creates the recorder tables automatically.
            </p>
          </div>
        </div>
      </section>
    );
  }

  return (
    <section className="mt-8 space-y-5">
      <section className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
        <div className="flex flex-wrap items-start justify-between gap-4 border-b border-white/5 px-5 py-4">
          <div>
            <div className="flex items-center gap-2">
              <Target className="h-4 w-4 text-emerald-300" />
              <h2 className="text-lg font-semibold text-white">
                TP / SL Engine
              </h2>
            </div>
            <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-600">
              Dynamic adapts TP / SL to each signal. Fixed uses your exact
              percentages.
            </p>
          </div>

          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => void runRecorder()}
              disabled={recording}
              className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5 disabled:opacity-50"
            >
              <RefreshCw
                className={`h-3.5 w-3.5 ${
                  recording ? "animate-spin" : ""
                }`}
              />
              Record now
            </button>

            <button
              type="button"
              onClick={() => void saveSettings()}
              disabled={saving}
              className="flex items-center gap-2 rounded-xl border border-emerald-400/20 bg-emerald-400/[0.06] px-3 py-2 text-xs text-emerald-300 hover:bg-emerald-400/10 disabled:opacity-50"
            >
              <Save className="h-3.5 w-3.5" />
              Save
            </button>
          </div>
        </div>

        <div className="grid gap-5 p-5 xl:grid-cols-[340px_1fr]">
          <div>
            <div className="text-[10px] uppercase tracking-[0.14em] text-zinc-600">
              Mode
            </div>

            <div className="mt-2 grid grid-cols-2 gap-2">
              {(["dynamic", "fixed"] as const).map((mode) => (
                <button
                  key={mode}
                  type="button"
                  onClick={() =>
                    setSettings((current) => ({
                      ...current,
                      mode,
                    }))
                  }
                  className={`rounded-xl border px-3 py-2.5 text-xs font-medium ${
                    settings.mode === mode
                      ? "border-emerald-400/20 bg-emerald-400/[0.07] text-emerald-300"
                      : "border-white/10 text-zinc-500 hover:bg-white/5 hover:text-white"
                  }`}
                >
                  {mode === "dynamic" ? "Dynamic" : "Fixed"}
                </button>
              ))}
            </div>

            {settings.mode === "dynamic" ? (
              <div className="mt-5">
                <div className="text-[10px] uppercase tracking-[0.14em] text-zinc-600">
                  Style
                </div>

                <div className="mt-2 space-y-2">
                  {(
                    [
                      ["conservative", "Conservative", "Tighter risk bands"],
                      ["balanced", "Balanced", "Middle ground"],
                      ["aggressive", "Aggressive", "Wider risk bands"],
                    ] as Array<[SignalTradingStyle, string, string]>
                  ).map(([style, label, description]) => (
                    <button
                      key={style}
                      type="button"
                      onClick={() =>
                        setSettings((current) => ({
                          ...current,
                          style,
                        }))
                      }
                      className={`w-full rounded-xl border p-3 text-left ${
                        settings.style === style
                          ? "border-cyan-400/20 bg-cyan-400/[0.05]"
                          : "border-white/5 bg-black/20"
                      }`}
                    >
                      <div className="text-xs font-medium text-zinc-200">
                        {label}
                      </div>
                      <div className="mt-1 text-[10px] text-zinc-600">
                        {description}
                      </div>
                    </button>
                  ))}
                </div>
              </div>
            ) : (
              <div className="mt-5 grid grid-cols-2 gap-3">
                <label>
                  <div className="text-[10px] uppercase tracking-[0.12em] text-zinc-600">
                    Target
                  </div>
                  <div className="mt-2 flex items-center rounded-xl border border-emerald-400/15 bg-emerald-400/[0.03] px-3">
                    <span className="text-xs text-emerald-300">+</span>
                    <input
                      type="number"
                      min={1}
                      value={settings.fixedTargetPercent}
                      onChange={(event) =>
                        setSettings((current) => ({
                          ...current,
                          fixedTargetPercent:
                            Math.max(1, Number(event.target.value)) ||
                            current.fixedTargetPercent,
                        }))
                      }
                      className="w-full bg-transparent py-2.5 text-center text-sm text-white outline-none"
                    />
                    <span className="text-xs text-zinc-500">%</span>
                  </div>
                </label>

                <label>
                  <div className="text-[10px] uppercase tracking-[0.12em] text-zinc-600">
                    Stop
                  </div>
                  <div className="mt-2 flex items-center rounded-xl border border-red-400/15 bg-red-400/[0.03] px-3">
                    <span className="text-xs text-red-300">-</span>
                    <input
                      type="number"
                      min={1}
                      value={settings.fixedStopLossPercent}
                      onChange={(event) =>
                        setSettings((current) => ({
                          ...current,
                          fixedStopLossPercent:
                            Math.max(1, Number(event.target.value)) ||
                            current.fixedStopLossPercent,
                        }))
                      }
                      className="w-full bg-transparent py-2.5 text-center text-sm text-white outline-none"
                    />
                    <span className="text-xs text-zinc-500">%</span>
                  </div>
                </label>
              </div>
            )}
          </div>

          <div className="rounded-xl border border-white/5 bg-black/20 p-4">
            {settings.mode === "dynamic" ? (
              <>
                <div className="flex items-center gap-2 text-xs font-medium text-zinc-200">
                  <Activity className="h-3.5 w-3.5 text-cyan-300" />
                  Dynamic TP / SL is based on
                </div>

                <div className="mt-4 grid gap-2 sm:grid-cols-2">
                  {[
                    ["5m + 1h movement", "Current volatility proxy"],
                    ["Volume spike", "Expanding activity can widen target"],
                    ["Buy pressure", "Recent buy/sell imbalance"],
                    ["Liquidity", "Thin pools receive more risk penalty"],
                    ["Pair age", "Very young pairs receive wider bands"],
                    ["Signal score", "Stronger rule alignment adds target room"],
                  ].map(([title, description]) => (
                    <div
                      key={title}
                      className="rounded-lg border border-white/5 bg-white/[0.015] p-3"
                    >
                      <div className="text-[11px] font-medium text-zinc-300">
                        {title}
                      </div>
                      <div className="mt-1 text-[10px] leading-4 text-zinc-600">
                        {description}
                      </div>
                    </div>
                  ))}
                </div>

                <div className="mt-4 text-[10px] leading-5 text-zinc-700">
                  These are heuristic risk bands, not price predictions.
                </div>
              </>
            ) : (
              <>
                <div className="flex items-center gap-2 text-xs font-medium text-zinc-200">
                  <ShieldAlert className="h-3.5 w-3.5 text-amber-300" />
                  Fixed user style
                </div>
                <p className="mt-3 text-xs leading-5 text-zinc-600">
                  New signals use exactly +{settings.fixedTargetPercent}% TP
                  and -{settings.fixedStopLossPercent}% SL.
                </p>
              </>
            )}
          </div>
        </div>

        {message && (
          <div className="border-t border-white/5 px-5 py-3 text-[10px] text-zinc-500">
            {message}
          </div>
        )}
      </section>

      <section className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-white/5 px-5 py-4">
          <div>
            <div className="flex items-center gap-2">
              <BarChart3 className="h-4 w-4 text-cyan-300" />
              <h2 className="text-lg font-semibold text-white">
                Signal Performance Analytics
              </h2>
            </div>
            <p className="mt-1 text-xs text-zinc-600">
              Historical results under the stored TP / SL rules.
            </p>
          </div>

          <div className="flex gap-1">
            {[
              [7, "7D"],
              [30, "30D"],
              [90, "90D"],
              [0, "ALL"],
            ].map(([days, label]) => (
              <button
                key={days}
                type="button"
                onClick={() => setPeriodDays(Number(days))}
                className={`rounded-lg px-2.5 py-1.5 text-[10px] ${
                  periodDays === days
                    ? "bg-white text-black"
                    : "text-zinc-600 hover:bg-white/5 hover:text-white"
                }`}
              >
                {label}
              </button>
            ))}
          </div>
        </div>

        {loading && !analytics ? (
          <div className="p-10 text-center text-sm text-zinc-600">
            Loading analytics...
          </div>
        ) : (
          <>
            <div className="grid grid-cols-2 gap-px bg-white/5 lg:grid-cols-4 xl:grid-cols-8">
              {[
                ["Signals", analytics?.total ?? 0],
                ["Active", analytics?.active ?? 0],
                ["TP Hit", analytics?.targetHits ?? 0],
                ["Stop Loss", analytics?.stopLosses ?? 0],
                ["TP Hit Rate", pct(analytics?.targetHitRate ?? null)],
                ["Avg Peak", pct(analytics?.averagePeakGain ?? null)],
                ["Avg Drawdown", pct(analytics?.averageDrawdown ?? null)],
                ["Avg Hold", hold(analytics?.averageHoldMinutes ?? null)],
              ].map(([label, value]) => (
                <div key={String(label)} className="bg-[#0b0e13] p-4">
                  <div className="text-[9px] uppercase tracking-[0.12em] text-zinc-700">
                    {label}
                  </div>
                  <div className="mt-1 text-lg font-semibold text-zinc-100">
                    {value}
                  </div>
                </div>
              ))}
            </div>

            <div className="grid gap-5 border-t border-white/5 p-5 xl:grid-cols-2">
              <div>
                <div className="mb-3 text-xs font-medium text-zinc-300">
                  By signal type
                </div>
                <div className="overflow-hidden rounded-xl border border-white/5">
                  <table className="w-full text-left text-xs">
                    <thead className="bg-black/20 text-[9px] uppercase text-zinc-700">
                      <tr>
                        <th className="px-3 py-2">Signal</th>
                        <th className="px-3 py-2">Total</th>
                        <th className="px-3 py-2">TP</th>
                        <th className="px-3 py-2">SL</th>
                        <th className="px-3 py-2">TP Rate</th>
                      </tr>
                    </thead>
                    <tbody>
                      {(analytics?.byKind ?? []).map((item) => (
                        <tr key={item.key} className="border-t border-white/5">
                          <td className="px-3 py-2.5 text-zinc-300">
                            {kindLabel(item.key)}
                          </td>
                          <td className="px-3 py-2.5 text-zinc-500">
                            {item.total}
                          </td>
                          <td className="px-3 py-2.5 text-emerald-300">
                            {item.targetHits}
                          </td>
                          <td className="px-3 py-2.5 text-red-300">
                            {item.stopLosses}
                          </td>
                          <td className="px-3 py-2.5 text-cyan-300">
                            {pct(item.targetHitRate)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>

              <div>
                <div className="mb-3 text-xs font-medium text-zinc-300">
                  By TP / SL plan
                </div>
                <div className="overflow-hidden rounded-xl border border-white/5">
                  <table className="w-full text-left text-xs">
                    <thead className="bg-black/20 text-[9px] uppercase text-zinc-700">
                      <tr>
                        <th className="px-3 py-2">Plan</th>
                        <th className="px-3 py-2">Total</th>
                        <th className="px-3 py-2">TP Rate</th>
                        <th className="px-3 py-2">Avg Peak</th>
                      </tr>
                    </thead>
                    <tbody>
                      {(analytics?.byPlan ?? []).map((item) => (
                        <tr key={item.key} className="border-t border-white/5">
                          <td className="px-3 py-2.5 text-zinc-300">
                            {item.key.replace(":", " / ")}
                          </td>
                          <td className="px-3 py-2.5 text-zinc-500">
                            {item.total}
                          </td>
                          <td className="px-3 py-2.5 text-cyan-300">
                            {pct(item.targetHitRate)}
                          </td>
                          <td className="px-3 py-2.5 text-zinc-300">
                            {pct(item.averagePeakGain)}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            </div>
          </>
        )}
      </section>

      <section className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
        <div className="flex items-center justify-between gap-3 border-b border-white/5 px-5 py-4">
          <div>
            <div className="flex items-center gap-2">
              <Database className="h-4 w-4 text-emerald-300" />
              <h2 className="text-lg font-semibold text-white">
                Server Signal History
              </h2>
            </div>
            <p className="mt-1 text-xs text-zinc-600">
              Stored in PostgreSQL, not browser localStorage.
            </p>
          </div>
          <div className="text-[10px] text-zinc-700">
            {activeRecords.length} active
          </div>
        </div>

        <div className="max-h-[680px] overflow-auto">
          <table className="w-full min-w-[1320px] text-left text-xs">
            <thead className="sticky top-0 z-10 bg-[#0d1015] text-[9px] uppercase text-zinc-700">
              <tr>
                <th className="px-4 py-3">Token</th>
                <th className="px-3 py-3">Entry</th>
                <th className="px-3 py-3">Current</th>
                <th className="px-3 py-3">Gain</th>
                <th className="px-3 py-3">TP</th>
                <th className="px-3 py-3">SL</th>
                <th className="px-3 py-3">Peak</th>
                <th className="px-3 py-3">Drawdown</th>
                <th className="px-3 py-3">Hold</th>
                <th className="px-3 py-3">Plan</th>
                <th className="px-3 py-3">Status</th>
                <th className="px-3 py-3">Live Setup</th>
              </tr>
            </thead>

            <tbody>
              {history.map((record) => (
                <tr
                  key={record.id}
                  className="border-t border-white/5 hover:bg-white/[0.02]"
                  title={record.planReason}
                >
                  <td className="px-4 py-3">
                    <a
                      href={`/token/${record.tokenAddress}`}
                      className="font-medium text-white hover:text-emerald-300"
                    >
                      {record.symbol}
                    </a>
                    <div className="mt-1 max-w-[180px] truncate text-[10px] text-zinc-700">
                      {record.label}
                    </div>
                  </td>

                  <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                    {priceText(record.entryPriceUsd)}
                  </td>

                  <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                    {priceText(record.currentPriceUsd)}
                  </td>

                  <td
                    className={`px-3 py-3 font-semibold ${
                      (record.currentGainPercent ?? 0) >= 0
                        ? "text-emerald-300"
                        : "text-red-300"
                    }`}
                  >
                    <span className="inline-flex items-center gap-1">
                      {(record.currentGainPercent ?? 0) >= 0 ? (
                        <TrendingUp className="h-3.5 w-3.5" />
                      ) : (
                        <TrendingDown className="h-3.5 w-3.5" />
                      )}
                      {pct(record.currentGainPercent)}
                    </span>
                  </td>

                  <td className="px-3 py-3">
                    <div className="text-emerald-300">
                      +{record.targetPercent.toFixed(1)}%
                    </div>
                    <div className="mt-1 font-mono text-[9px] text-zinc-700">
                      {priceText(record.targetPriceUsd)}
                    </div>
                  </td>

                  <td className="px-3 py-3">
                    <div className="text-red-300">
                      -{record.stopLossPercent.toFixed(1)}%
                    </div>
                    <div className="mt-1 font-mono text-[9px] text-zinc-700">
                      {priceText(record.stopPriceUsd)}
                    </div>
                  </td>

                  <td className="px-3 py-3 text-cyan-300">
                    {pct(record.peakGainPercent)}
                  </td>

                  <td className="px-3 py-3 text-red-300">
                    {pct(record.maxDrawdownPercent)}
                  </td>

                  <td className="px-3 py-3">
                    <span className="inline-flex items-center gap-1 text-zinc-300">
                      <Clock3 className="h-3.5 w-3.5 text-zinc-600" />
                      {recordHold(record, now)}
                    </span>
                  </td>

                  <td className="px-3 py-3">
                    <div className="text-zinc-300">{record.mode}</div>
                    <div className="mt-1 text-[9px] text-zinc-700">
                      {record.style}
                    </div>
                  </td>

                  <td className="px-3 py-3">
                    <span
                      className={`rounded-md border px-2 py-1 text-[9px] ${
                        record.status === "target_hit"
                          ? "border-emerald-400/20 bg-emerald-400/[0.06] text-emerald-300"
                          : record.status === "stop_loss"
                            ? "border-red-400/20 bg-red-400/[0.06] text-red-300"
                            : "border-cyan-400/20 bg-cyan-400/[0.05] text-cyan-300"
                      }`}
                    >
                      {statusLabel(record.status)}
                    </span>
                  </td>

                  <td className="px-3 py-3">
                    <span
                      className={`text-[10px] ${
                        record.signalVisible
                          ? "text-emerald-300"
                          : "text-zinc-700"
                      }`}
                    >
                      {record.signalVisible
                        ? "Still detected"
                        : "No longer detected"}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {history.length === 0 && (
            <div className="p-10 text-center text-sm text-zinc-600">
              No server records yet. Press Record now or wait for a Signal feed
              refresh.
            </div>
          )}
        </div>

        <div className="border-t border-white/5 px-5 py-3 text-[10px] leading-5 text-zinc-700">
          TP hit rate is historical performance under stored exit rules. It is
          not a probability that future signals will hit their target.
        </div>
      </section>
    </section>
  );
}
