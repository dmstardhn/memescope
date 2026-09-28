"use client";

import {
  BarChart3,
  Clock3,
  Database,
  RefreshCw,
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

function recordHold(
  record: StoredSignalRecord,
  now: number,
) {
  return hold(
    ((record.closedAt ?? now) -
      record.openedAt) /
      60_000,
  );
}

function kindLabel(value: string) {
  return value
    .split("-")
    .map(
      (part) =>
        part.charAt(0).toUpperCase() +
        part.slice(1),
    )
    .join(" ");
}

function statusLabel(
  status: StoredSignalRecord["status"],
) {
  if (status === "target_hit") {
    return "TARGET HIT";
  }

  if (status === "stop_loss") {
    return "LEGACY CLOSED";
  }

  return "ACTIVE";
}

export function SignalPerformancePanel({
  signals,
  tokens,
}: {
  signals: SignalCall[];
  tokens: TerminalToken[];
}) {
  const [
    configured,
    setConfigured,
  ] = useState<boolean | null>(
    null,
  );

  const [
    analytics,
    setAnalytics,
  ] = useState<SignalAnalytics | null>(
    null,
  );

  const [history, setHistory] =
    useState<StoredSignalRecord[]>(
      [],
    );

  const [
    periodDays,
    setPeriodDays,
  ] = useState(30);

  const [loading, setLoading] =
    useState(true);

  const [
    recording,
    setRecording,
  ] = useState(false);

  const [message, setMessage] =
    useState("");

  const [now, setNow] =
    useState(Date.now());

  const loadData =
    useCallback(async () => {
      try {
        const [
          analyticsResponse,
          historyResponse,
        ] =
          await Promise.all([
            fetch(
              `/api/signals/analytics?days=${periodDays}`,
              {
                cache: "no-store",
              },
            ),
            fetch(
              "/api/signals/history?limit=150",
              {
                cache: "no-store",
              },
            ),
          ]);

        const analyticsBody =
          (await analyticsResponse.json()) as {
            configured?: boolean;
            analytics?: SignalAnalytics;
            error?: string;
          };

        const historyBody =
          (await historyResponse.json()) as {
            configured?: boolean;
            records?: StoredSignalRecord[];
            error?: string;
          };

        if (
          analyticsBody.configured ===
            false ||
          historyBody.configured ===
            false
        ) {
          setConfigured(false);
          setAnalytics(null);
          setHistory([]);
          return;
        }

        if (
          !analyticsResponse.ok ||
          !historyResponse.ok
        ) {
          throw new Error(
            analyticsBody.error ??
              historyBody.error ??
              "Failed to load signal history.",
          );
        }

        setConfigured(true);
        setAnalytics(
          analyticsBody.analytics ??
            null,
        );
        setHistory(
          historyBody.records ?? [],
        );
      } catch (error) {
        setMessage(
          error instanceof Error
            ? error.message
            : "Failed to load signal history.",
        );
      } finally {
        setLoading(false);
      }
    }, [periodDays]);

  const runRecorder =
    useCallback(
      async (quiet = false) => {
        if (
          configured === false
        ) {
          return;
        }

        if (!quiet) {
          setRecording(true);
          setMessage("");
        }

        try {
          const response =
            await fetch(
              "/api/signals/record",
              {
                method: "POST",
                cache: "no-store",
              },
            );

          const body =
            (await response.json()) as {
              configured?: boolean;
              opened?: number;
              updated?: number;
              closed?: number;
              error?: string;
            };

          if (
            body.configured ===
            false
          ) {
            setConfigured(false);
            return;
          }

          if (!response.ok) {
            throw new Error(
              body.error ??
                "Recorder failed.",
            );
          }

          setConfigured(true);

          if (!quiet) {
            setMessage(
              `Recorder: ${
                body.opened ?? 0
              } opened, ${
                body.updated ?? 0
              } updated, ${
                body.closed ?? 0
              } target hits.`,
            );
          }

          await loadData();
        } catch (error) {
          if (!quiet) {
            setMessage(
              error instanceof Error
                ? error.message
                : "Recorder failed.",
            );
          }
        } finally {
          if (!quiet) {
            setRecording(false);
          }
        }
      },
      [
        configured,
        loadData,
      ],
    );

  useEffect(() => {
    void loadData();
  }, [loadData]);

  useEffect(() => {
    if (
      configured === false
    ) {
      return;
    }

    void runRecorder(true);
    // The terminal feed changes as the market refreshes.
    // This also gives the server recorder an immediate heartbeat.
  }, [
    signals,
    tokens,
    configured,
    runRecorder,
  ]);

  useEffect(() => {
    if (
      configured !== true
    ) {
      return;
    }

    const timer =
      window.setInterval(
        () => {
          void runRecorder(true);
        },
        10_000,
      );

    return () =>
      window.clearInterval(
        timer,
      );
  }, [
    configured,
    runRecorder,
  ]);

  useEffect(() => {
    const timer =
      window.setInterval(
        () =>
          setNow(Date.now()),
        1_000,
      );

    return () =>
      window.clearInterval(
        timer,
      );
  }, []);

  const activeRecords =
    useMemo(
      () =>
        history.filter(
          (record) =>
            record.status ===
            "active",
        ),
      [history],
    );

  if (
    configured === false
  ) {
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
      <section className="overflow-hidden rounded-2xl border border-emerald-400/15 bg-emerald-400/[0.025]">
        <div className="flex flex-wrap items-start justify-between gap-4 px-5 py-4">
          <div>
            <div className="flex items-center gap-2">
              <Target className="h-4 w-4 text-emerald-300" />
              <h2 className="text-lg font-semibold text-white">
                Potential TP Engine
              </h2>
            </div>
            <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-500">
              Stage 16 uses one analysis-based upside target locked at signal
              entry. There is no automatic stop loss. Maximum gain and maximum
              drawdown continue to be recorded for each token until the target
              is observed.
            </p>
            <div className="mt-3 text-[10px] text-zinc-600">
              Feed: {signals.length} confirmed HQ signal{signals.length === 1 ? "" : "s"} /{" "}
              {tokens.length} tracked token{tokens.length === 1 ? "" : "s"}.
            </div>
          </div>

          <button
            type="button"
            onClick={() =>
              void runRecorder()
            }
            disabled={recording}
            className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5 disabled:opacity-50"
          >
            <RefreshCw
              className={`h-3.5 w-3.5 ${
                recording
                  ? "animate-spin"
                  : ""
              }`}
            />
            Record now
          </button>
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
              Descriptive history for confirmed Stage 16 signals. Maximum gain
              and drawdown describe observed movement after the recorded entry.
            </p>
          </div>

          <div className="flex gap-1">
            {[
              [7, "7D"],
              [30, "30D"],
              [90, "90D"],
              [0, "ALL"],
            ].map(
              ([days, label]) => (
                <button
                  key={days}
                  type="button"
                  onClick={() =>
                    setPeriodDays(
                      Number(days),
                    )
                  }
                  className={`rounded-lg px-2.5 py-1.5 text-[10px] ${
                    periodDays ===
                    days
                      ? "bg-white text-black"
                      : "text-zinc-600 hover:bg-white/5 hover:text-white"
                  }`}
                >
                  {label}
                </button>
              ),
            )}
          </div>
        </div>

        {loading &&
        !analytics ? (
          <div className="p-10 text-center text-sm text-zinc-600">
            Loading analytics...
          </div>
        ) : (
          <>
            <div className="grid grid-cols-2 gap-px bg-white/5 lg:grid-cols-3 xl:grid-cols-6">
              {[
                [
                  "Signals",
                  analytics?.total ??
                    0,
                ],
                [
                  "Active",
                  analytics?.active ??
                    0,
                ],
                [
                  "TP Hit",
                  analytics?.targetHits ??
                    0,
                ],
                [
                  "Avg Gain",
                  pct(
                    analytics?.averageCurrentGain ??
                      null,
                  ),
                ],
                [
                  "Avg Max Gain",
                  pct(
                    analytics?.averagePeakGain ??
                      null,
                  ),
                ],
                [
                  "Avg Max DD",
                  pct(
                    analytics?.averageDrawdown ??
                      null,
                  ),
                ],
              ].map(
                ([label, value]) => (
                  <div
                    key={String(
                      label,
                    )}
                    className="bg-[#0b0e13] p-4"
                  >
                    <div className="text-[9px] uppercase tracking-[0.12em] text-zinc-700">
                      {label}
                    </div>
                    <div className="mt-1 text-lg font-semibold text-zinc-100">
                      {value}
                    </div>
                  </div>
                ),
              )}
            </div>

            <div className="border-t border-white/5 p-5">
              <div className="mb-3 text-xs font-medium text-zinc-300">
                By signal type
              </div>

              <div className="overflow-hidden rounded-xl border border-white/5">
                <table className="w-full text-left text-xs">
                  <thead className="bg-black/20 text-[9px] uppercase text-zinc-700">
                    <tr>
                      <th className="px-3 py-2">
                        Signal
                      </th>
                      <th className="px-3 py-2">
                        Total
                      </th>
                      <th className="px-3 py-2">
                        TP Hit
                      </th>
                      <th className="px-3 py-2">
                        Avg Max Gain
                      </th>
                      <th className="px-3 py-2">
                        Avg Drawdown
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {(
                      analytics?.byKind ??
                      []
                    ).map(
                      (item) => (
                        <tr
                          key={
                            item.key
                          }
                          className="border-t border-white/5"
                        >
                          <td className="px-3 py-2.5 text-zinc-300">
                            {kindLabel(
                              item.key,
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-zinc-500">
                            {item.total}
                          </td>
                          <td className="px-3 py-2.5 text-emerald-300">
                            {
                              item.targetHits
                            }
                          </td>
                          <td className="px-3 py-2.5 text-cyan-300">
                            {pct(
                              item.averagePeakGain,
                            )}
                          </td>
                          <td className="px-3 py-2.5 text-red-300">
                            {pct(
                              item.averageDrawdown,
                            )}
                          </td>
                        </tr>
                      ),
                    )}
                  </tbody>
                </table>
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
              PostgreSQL history refreshed from tracked market prices. No
              automatic stop-loss closure is used for new Stage 16 records.
            </p>
          </div>

          <div className="text-[10px] text-zinc-700">
            {activeRecords.length} active
          </div>
        </div>

        <div className="max-h-[680px] overflow-auto">
          <table className="w-full min-w-[1160px] text-left text-xs">
            <thead className="sticky top-0 z-10 bg-[#0d1015] text-[9px] uppercase text-zinc-700">
              <tr>
                <th className="px-4 py-3">
                  Token
                </th>
                <th className="px-3 py-3">
                  Entry
                </th>
                <th className="px-3 py-3">
                  Current
                </th>
                <th className="px-3 py-3">
                  Gain
                </th>
                <th className="px-3 py-3">
                  Potential TP
                </th>
                <th className="px-3 py-3">
                  Max Gain
                </th>
                <th className="px-3 py-3">
                  Max Drawdown
                </th>
                <th className="px-3 py-3">
                  Hold
                </th>
                <th className="px-3 py-3">
                  Score
                </th>
                <th className="px-3 py-3">
                  Status
                </th>
                <th className="px-3 py-3">
                  Live Setup
                </th>
              </tr>
            </thead>

            <tbody>
              {history.map(
                (record) => (
                  <tr
                    key={record.id}
                    className="border-t border-white/5 hover:bg-white/[0.02]"
                    title={
                      record.planReason
                    }
                  >
                    <td className="px-4 py-3">
                      <a
                        href={`/token/${record.tokenAddress}`}
                        className="font-medium text-white hover:text-emerald-300"
                      >
                        {record.symbol}
                      </a>
                      <div className="mt-1 max-w-[180px] truncate text-[10px] text-zinc-700">
                        {
                          record.label
                        }
                      </div>
                    </td>

                    <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                      {priceText(
                        record.entryPriceUsd,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                      {priceText(
                        record.currentPriceUsd,
                      )}
                    </td>

                    <td
                      className={`px-3 py-3 font-semibold ${
                        (
                          record.currentGainPercent ??
                          0
                        ) >= 0
                          ? "text-emerald-300"
                          : "text-red-300"
                      }`}
                    >
                      <span className="inline-flex items-center gap-1">
                        {(
                          record.currentGainPercent ??
                          0
                        ) >= 0 ? (
                          <TrendingUp className="h-3.5 w-3.5" />
                        ) : (
                          <TrendingDown className="h-3.5 w-3.5" />
                        )}
                        {pct(
                          record.currentGainPercent,
                        )}
                      </span>
                    </td>

                    <td className="px-3 py-3">
                      <div className="text-emerald-300">
                        +
                        {record.targetPercent.toFixed(
                          1,
                        )}
                        %
                      </div>
                      <div className="mt-1 font-mono text-[9px] text-zinc-700">
                        {priceText(
                          record.targetPriceUsd,
                        )}
                      </div>
                    </td>

                    <td className="px-3 py-3 font-semibold text-cyan-300">
                      {pct(
                        record.peakGainPercent,
                      )}
                    </td>

                    <td className="px-3 py-3 font-semibold text-red-300">
                      {pct(
                        record.maxDrawdownPercent,
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span className="inline-flex items-center gap-1 text-zinc-300">
                        <Clock3 className="h-3.5 w-3.5 text-zinc-600" />
                        {recordHold(
                          record,
                          now,
                        )}
                      </span>
                    </td>

                    <td className="px-3 py-3">
                      <div className="font-semibold text-zinc-200">
                        {
                          record.scoreAtEntry
                        }
                      </div>
                      <div className="mt-1 text-[9px] text-zinc-700">
                        latest{" "}
                        {
                          record.lastScore
                        }
                      </div>
                    </td>

                    <td className="px-3 py-3">
                      <span
                        className={`rounded-md border px-2 py-1 text-[9px] ${
                          record.status ===
                          "target_hit"
                            ? "border-emerald-400/20 bg-emerald-400/[0.06] text-emerald-300"
                            : record.status ===
                                "stop_loss"
                              ? "border-zinc-500/20 bg-zinc-500/[0.06] text-zinc-500"
                              : "border-cyan-400/20 bg-cyan-400/[0.05] text-cyan-300"
                        }`}
                      >
                        {statusLabel(
                          record.status,
                        )}
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
                ),
              )}
            </tbody>
          </table>

          {history.length === 0 && (
            <div className="p-10 text-center text-sm text-zinc-600">
              No server records yet. A new record opens only after a setup
              passes the Stage 16 filters in two consecutive recorder scans.
            </div>
          )}
        </div>

        <div className="border-t border-white/5 px-5 py-3 text-[10px] leading-5 text-zinc-700">
          Potential TP is an analysis-based heuristic target, not a prediction.
          Max Gain and Max Drawdown are historical observations after the
          recorded entry. Legacy records closed by the old stop-loss engine are
          preserved but no new Stage 16 record is closed by stop loss.
        </div>
      </section>
    </section>
  );
}
