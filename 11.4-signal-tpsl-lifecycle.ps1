$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Signals - TP / SL Lifecycle" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )

    $full = Join-Path $root $Path
    $dir = Split-Path -Parent $full

    if ($dir -and !(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    [System.IO.File]::WriteAllText($full, $Content, $utf8)
    Write-Host "Updated: $Path" -ForegroundColor Green
}

$signalsPage = Join-Path $root "src/app/signals/page.tsx"

if (!(Test-Path -LiteralPath $signalsPage)) {
    throw "src/app/signals/page.tsx tidak ditemukan."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-signal-tpsl-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in @(
    "src/components/signal-performance-panel.tsx",
    "src/app/signals/page.tsx"
)) {
    $full = Join-Path $root $file

    if (Test-Path -LiteralPath $full) {
        $safe = ($file -replace '[\\/]', '__') + ".bak"
        Copy-Item -LiteralPath $full -Destination (Join-Path $backupDir $safe) -Force
    }
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray

$component = @'
"use client";

import {
  Bell,
  BellRing,
  Clock3,
  History,
  RefreshCw,
  Target,
  TrendingDown,
  TrendingUp,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

import type {
  SignalCall,
} from "@/lib/signal-types";

import type {
  TerminalToken,
} from "@/lib/terminal-types";

const HISTORY_KEY =
  "memescope-signal-position-history-v2";

const SETTINGS_KEY =
  "memescope-signal-tpsl-settings-v2";

type SignalExitStatus =
  | "active"
  | "target_hit"
  | "stop_loss";

type PositionRecord = {
  id: string;
  signalId: string;

  tokenAddress: string;
  symbol: string;
  name: string;
  label: string;

  openedAt: number;
  lastUpdatedAt: number;
  endedAt: number | null;

  entryPriceUsd: number | null;
  currentPriceUsd: number | null;
  exitPriceUsd: number | null;

  targetPercent: number;
  stopLossPercent: number;

  targetPriceUsd: number | null;
  stopPriceUsd: number | null;

  currentGainPercent: number | null;
  peakGainPercent: number | null;
  maxDrawdownPercent: number | null;

  scoreAtEntry: number;
  lastScore: number;

  signalStillVisible: boolean;
  status: SignalExitStatus;

  notificationSent: boolean;
};

type TpSlSettings = {
  targetPercent: number;
  stopLossPercent: number;
  notificationsEnabled: boolean;
};

const DEFAULT_SETTINGS: TpSlSettings = {
  targetPercent: 30,
  stopLossPercent: 15,
  notificationsEnabled: false,
};

function finiteNumber(
  value: unknown,
  fallback: number,
) {
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

function priceText(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1) {
    return `$${value.toFixed(4)}`;
  }

  return `$${value.toPrecision(5)}`;
}

function percentText(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  return `${value > 0 ? "+" : ""}${value.toFixed(
    2,
  )}%`;
}

function durationText(
  start: number,
  end: number,
) {
  const totalMinutes =
    Math.max(
      0,
      Math.floor(
        (end - start) /
          60_000,
      ),
    );

  if (totalMinutes < 60) {
    return `${totalMinutes}m`;
  }

  const totalHours =
    Math.floor(
      totalMinutes / 60,
    );

  const minutes =
    totalMinutes % 60;

  if (totalHours < 24) {
    return `${totalHours}h ${minutes}m`;
  }

  const days =
    Math.floor(
      totalHours / 24,
    );

  const hours =
    totalHours % 24;

  return `${days}d ${hours}h`;
}

function dateText(
  timestamp: number,
) {
  return new Date(
    timestamp,
  ).toLocaleString(
    "en-US",
    {
      month: "short",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    },
  );
}

function gainPercent(
  entry: number | null,
  current: number | null,
) {
  if (
    entry === null ||
    current === null ||
    entry <= 0
  ) {
    return null;
  }

  return (
    ((current - entry) /
      entry) *
    100
  );
}

function targetPrice(
  entry: number | null,
  targetPercent: number,
) {
  if (
    entry === null ||
    entry <= 0
  ) {
    return null;
  }

  return (
    entry *
    (1 + targetPercent / 100)
  );
}

function stopPrice(
  entry: number | null,
  stopLossPercent: number,
) {
  if (
    entry === null ||
    entry <= 0
  ) {
    return null;
  }

  return (
    entry *
    (1 - stopLossPercent / 100)
  );
}

function statusLabel(
  status: SignalExitStatus,
) {
  if (
    status === "target_hit"
  ) {
    return "TARGET HIT";
  }

  if (
    status === "stop_loss"
  ) {
    return "STOP LOSS";
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
  const [records, setRecords] =
    useState<PositionRecord[]>(
      [],
    );

  const [settings, setSettings] =
    useState<TpSlSettings>(
      DEFAULT_SETTINGS,
    );

  const [hydrated, setHydrated] =
    useState(false);

  const [now, setNow] =
    useState(Date.now());

  const [message, setMessage] =
    useState("");

  useEffect(() => {
    try {
      const raw =
        localStorage.getItem(
          HISTORY_KEY,
        );

      if (raw) {
        const parsed =
          JSON.parse(raw) as unknown;

        if (
          Array.isArray(parsed)
        ) {
          setRecords(
            parsed as PositionRecord[],
          );
        }
      }
    } catch {
      // Ignore malformed browser history.
    }

    try {
      const raw =
        localStorage.getItem(
          SETTINGS_KEY,
        );

      if (raw) {
        const parsed =
          JSON.parse(raw) as Partial<TpSlSettings>;

        setSettings({
          targetPercent:
            Math.max(
              1,
              finiteNumber(
                parsed.targetPercent,
                DEFAULT_SETTINGS.targetPercent,
              ),
            ),

          stopLossPercent:
            Math.max(
              1,
              finiteNumber(
                parsed.stopLossPercent,
                DEFAULT_SETTINGS.stopLossPercent,
              ),
            ),

          notificationsEnabled:
            parsed.notificationsEnabled ===
            true,
        });
      }
    } catch {
      // Keep defaults.
    }

    setHydrated(true);
  }, []);

  useEffect(() => {
    const timer =
      window.setInterval(
        () => {
          setNow(Date.now());
        },
        1_000,
      );

    return () =>
      window.clearInterval(timer);
  }, []);

  useEffect(() => {
    if (!hydrated) {
      return;
    }

    localStorage.setItem(
      SETTINGS_KEY,
      JSON.stringify(settings),
    );
  }, [
    hydrated,
    settings,
  ]);

  useEffect(() => {
    if (!hydrated) {
      return;
    }

    localStorage.setItem(
      HISTORY_KEY,
      JSON.stringify(
        records.slice(0, 500),
      ),
    );
  }, [
    hydrated,
    records,
  ]);

  useEffect(() => {
    if (!hydrated) {
      return;
    }

    const currentTime =
      Date.now();

    const watchSignals =
      signals.filter(
        (signal) =>
          signal.direction === "watch",
      );

    const visibleSignalIds =
      new Set(
        watchSignals.map(
          (signal) =>
            signal.id,
        ),
      );

    const tokenMap =
      new Map(
        tokens.map(
          (token) => [
            token.address,
            token,
          ],
        ),
      );

    setRecords(
      (current) => {
        let next =
          current.map(
            (record) => ({
              ...record,
            }),
          );

        for (
          const signal of watchSignals
        ) {
          const existing =
            next.findIndex(
              (record) =>
                record.status ===
                  "active" &&
                record.signalId ===
                  signal.id,
            );

          const token =
            tokenMap.get(
              signal.tokenAddress,
            );

          const observedPrice =
            token?.priceUsd ??
            signal.priceUsd ??
            null;

          if (
            existing === -1
          ) {
            const tp =
              settings.targetPercent;

            const sl =
              settings.stopLossPercent;

            next.unshift({
              id:
                `${signal.id}-${currentTime}`,

              signalId:
                signal.id,

              tokenAddress:
                signal.tokenAddress,

              symbol:
                signal.symbol,

              name:
                signal.name,

              label:
                signal.label,

              openedAt:
                currentTime,

              lastUpdatedAt:
                currentTime,

              endedAt:
                null,

              entryPriceUsd:
                observedPrice,

              currentPriceUsd:
                observedPrice,

              exitPriceUsd:
                null,

              targetPercent:
                tp,

              stopLossPercent:
                sl,

              targetPriceUsd:
                targetPrice(
                  observedPrice,
                  tp,
                ),

              stopPriceUsd:
                stopPrice(
                  observedPrice,
                  sl,
                ),

              currentGainPercent:
                observedPrice !==
                null
                  ? 0
                  : null,

              peakGainPercent:
                observedPrice !==
                null
                  ? 0
                  : null,

              maxDrawdownPercent:
                observedPrice !==
                null
                  ? 0
                  : null,

              scoreAtEntry:
                signal.signalScore,

              lastScore:
                signal.signalScore,

              signalStillVisible:
                true,

              status:
                "active",

              notificationSent:
                false,
            });

            continue;
          }

          next[existing] = {
            ...next[existing],
            symbol:
              signal.symbol,
            name:
              signal.name,
            label:
              signal.label,
            lastScore:
              signal.signalScore,
            signalStillVisible:
              true,
          };
        }

        next =
          next.map(
            (record) => {
              if (
                record.status !==
                "active"
              ) {
                return record;
              }

              const token =
                tokenMap.get(
                  record.tokenAddress,
                );

              const visibleSignal =
                watchSignals.find(
                  (signal) =>
                    signal.id ===
                    record.signalId,
                );

              const observedPrice =
                token?.priceUsd ??
                visibleSignal?.priceUsd ??
                record.currentPriceUsd;

              const gain =
                gainPercent(
                  record.entryPriceUsd,
                  observedPrice,
                );

              const peak =
                gain !== null
                  ? Math.max(
                      record.peakGainPercent ??
                        gain,
                      gain,
                    )
                  : record.peakGainPercent;

              const drawdown =
                gain !== null
                  ? Math.min(
                      record.maxDrawdownPercent ??
                        gain,
                      gain,
                    )
                  : record.maxDrawdownPercent;

              let status:
                SignalExitStatus =
                  "active";

              let endedAt:
                number | null =
                  null;

              let exitPrice:
                number | null =
                  null;

              if (
                gain !== null &&
                gain >=
                  record.targetPercent
              ) {
                status =
                  "target_hit";

                endedAt =
                  currentTime;

                exitPrice =
                  observedPrice;
              } else if (
                gain !== null &&
                gain <=
                  -record.stopLossPercent
              ) {
                status =
                  "stop_loss";

                endedAt =
                  currentTime;

                exitPrice =
                  observedPrice;
              }

              return {
                ...record,

                lastUpdatedAt:
                  currentTime,

                currentPriceUsd:
                  observedPrice,

                currentGainPercent:
                  gain,

                peakGainPercent:
                  peak,

                maxDrawdownPercent:
                  drawdown,

                signalStillVisible:
                  visibleSignalIds.has(
                    record.signalId,
                  ),

                status,

                endedAt,

                exitPriceUsd:
                  exitPrice,
              };
            },
          );

        return next
          .sort(
            (a, b) =>
              b.openedAt -
              a.openedAt,
          )
          .slice(0, 500);
      },
    );
  }, [
    hydrated,
    signals,
    tokens,
    settings.targetPercent,
    settings.stopLossPercent,
  ]);

  useEffect(() => {
    if (
      !hydrated ||
      !settings.notificationsEnabled ||
      typeof Notification ===
        "undefined" ||
      Notification.permission !==
        "granted"
    ) {
      return;
    }

    const completed =
      records.filter(
        (record) =>
          record.status !==
            "active" &&
          !record.notificationSent,
      );

    if (
      completed.length === 0
    ) {
      return;
    }

    for (
      const record of completed.slice(
        0,
        5,
      )
    ) {
      const title =
        record.status ===
        "target_hit"
          ? `Target hit: ${record.symbol}`
          : `Stop loss hit: ${record.symbol}`;

      new Notification(
        title,
        {
          body:
            `${percentText(
              record.currentGainPercent,
            )} from signal entry. ` +
            `Hold: ${durationText(
              record.openedAt,
              record.endedAt ??
                Date.now(),
            )}.`,
        },
      );
    }

    const ids =
      new Set(
        completed.map(
          (record) =>
            record.id,
        ),
      );

    setRecords(
      (current) =>
        current.map(
          (record) =>
            ids.has(record.id)
              ? {
                  ...record,
                  notificationSent:
                    true,
                }
              : record,
        ),
    );
  }, [
    hydrated,
    records,
    settings.notificationsEnabled,
  ]);

  async function toggleNotifications() {
    if (
      settings.notificationsEnabled
    ) {
      setSettings(
        (current) => ({
          ...current,
          notificationsEnabled:
            false,
        }),
      );

      return;
    }

    if (
      typeof Notification ===
      "undefined"
    ) {
      setMessage(
        "Browser notifications are not supported.",
      );

      return;
    }

    const permission =
      await Notification.requestPermission();

    if (
      permission !== "granted"
    ) {
      setMessage(
        "Notification permission was not granted.",
      );

      return;
    }

    setSettings(
      (current) => ({
        ...current,
        notificationsEnabled:
          true,
      }),
    );

    setMessage(
      "Target and stop notifications enabled.",
    );
  }

  function applyToActive() {
    setRecords(
      (current) =>
        current.map(
          (record) => {
            if (
              record.status !==
              "active"
            ) {
              return record;
            }

            return {
              ...record,

              targetPercent:
                settings.targetPercent,

              stopLossPercent:
                settings.stopLossPercent,

              targetPriceUsd:
                targetPrice(
                  record.entryPriceUsd,
                  settings.targetPercent,
                ),

              stopPriceUsd:
                stopPrice(
                  record.entryPriceUsd,
                  settings.stopLossPercent,
                ),
            };
          },
        ),
    );

    setMessage(
      "Current TP / SL applied to all active signals.",
    );
  }

  const activeCount =
    useMemo(
      () =>
        records.filter(
          (record) =>
            record.status ===
            "active",
        ).length,
      [records],
    );

  const targetHits =
    useMemo(
      () =>
        records.filter(
          (record) =>
            record.status ===
            "target_hit",
        ).length,
      [records],
    );

  const stopHits =
    useMemo(
      () =>
        records.filter(
          (record) =>
            record.status ===
            "stop_loss",
        ).length,
      [records],
    );

  return (
    <section className="mt-8 overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
      <div className="flex flex-wrap items-start justify-between gap-4 border-b border-white/5 px-5 py-4">
        <div>
          <div className="flex items-center gap-2">
            <Target className="h-4 w-4 text-emerald-300" />

            <h2 className="text-lg font-semibold text-white">
              Signal TP / SL Tracker
            </h2>
          </div>

          <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-600">
            A signal no longer ends just because it disappears from the live setup list. Once opened, it stays active until its target or stop loss is observed.
          </p>
        </div>

        <button
          type="button"
          onClick={
            toggleNotifications
          }
          className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
            settings.notificationsEnabled
              ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
              : "border-white/10 text-zinc-400 hover:bg-white/5"
          }`}
        >
          {settings.notificationsEnabled ? (
            <BellRing className="h-3.5 w-3.5" />
          ) : (
            <Bell className="h-3.5 w-3.5" />
          )}

          {settings.notificationsEnabled
            ? "TP / SL alerts on"
            : "Enable TP / SL alerts"}
        </button>
      </div>

      <div className="grid gap-3 border-b border-white/5 p-5 lg:grid-cols-[1fr_1fr_auto]">
        <label>
          <div className="text-[10px] uppercase tracking-[0.13em] text-zinc-600">
            Target gain
          </div>

          <div className="mt-2 flex items-center rounded-xl border border-emerald-400/15 bg-emerald-400/[0.03] px-3">
            <span className="text-xs text-emerald-400">
              +
            </span>

            <input
              type="number"
              min={1}
              step={1}
              value={
                settings.targetPercent
              }
              onChange={(event) =>
                setSettings(
                  (current) => ({
                    ...current,
                    targetPercent:
                      Math.max(
                        1,
                        finiteNumber(
                          event.target.value,
                          current.targetPercent,
                        ),
                      ),
                  }),
                )
              }
              className="w-full bg-transparent py-2.5 text-sm text-white outline-none"
            />

            <span className="text-xs text-zinc-500">
              %
            </span>
          </div>
        </label>

        <label>
          <div className="text-[10px] uppercase tracking-[0.13em] text-zinc-600">
            Stop loss
          </div>

          <div className="mt-2 flex items-center rounded-xl border border-red-400/15 bg-red-400/[0.03] px-3">
            <span className="text-xs text-red-400">
              -
            </span>

            <input
              type="number"
              min={1}
              step={1}
              value={
                settings.stopLossPercent
              }
              onChange={(event) =>
                setSettings(
                  (current) => ({
                    ...current,
                    stopLossPercent:
                      Math.max(
                        1,
                        finiteNumber(
                          event.target.value,
                          current.stopLossPercent,
                        ),
                      ),
                  }),
                )
              }
              className="w-full bg-transparent py-2.5 text-sm text-white outline-none"
            />

            <span className="text-xs text-zinc-500">
              %
            </span>
          </div>
        </label>

        <div className="flex items-end">
          <button
            type="button"
            onClick={
              applyToActive
            }
            className="flex w-full items-center justify-center gap-2 rounded-xl border border-white/10 px-4 py-2.5 text-xs text-zinc-300 hover:bg-white/5 lg:w-auto"
          >
            <RefreshCw className="h-3.5 w-3.5" />
            Apply to active
          </button>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-px border-b border-white/5 bg-white/5 lg:grid-cols-4">
        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            Active
          </div>

          <div className="mt-1 text-xl font-semibold text-white">
            {activeCount}
          </div>
        </div>

        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            Target hit
          </div>

          <div className="mt-1 text-xl font-semibold text-emerald-300">
            {targetHits}
          </div>
        </div>

        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            Stop loss
          </div>

          <div className="mt-1 text-xl font-semibold text-red-300">
            {stopHits}
          </div>
        </div>

        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            New signal setup
          </div>

          <div className="mt-1 text-sm font-semibold text-zinc-200">
            +{settings.targetPercent}% / -{settings.stopLossPercent}%
          </div>
        </div>
      </div>

      {message && (
        <div className="border-b border-white/5 px-5 py-2 text-[10px] text-zinc-500">
          {message}
        </div>
      )}

      <div className="max-h-[650px] overflow-auto">
        <table className="w-full min-w-[1280px] text-left text-xs">
          <thead className="sticky top-0 z-10 bg-[#0d1015] text-[9px] uppercase tracking-[0.12em] text-zinc-700">
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
                Target
              </th>

              <th className="px-3 py-3">
                Stop
              </th>

              <th className="px-3 py-3">
                Peak
              </th>

              <th className="px-3 py-3">
                Drawdown
              </th>

              <th className="px-3 py-3">
                Hold
              </th>

              <th className="px-3 py-3">
                Status
              </th>

              <th className="px-3 py-3">
                Live setup
              </th>

              <th className="px-3 py-3">
                Opened
              </th>
            </tr>
          </thead>

          <tbody>
            {records.map(
              (record) => {
                const end =
                  record.status ===
                  "active"
                    ? now
                    : record.endedAt ??
                      record.lastUpdatedAt;

                return (
                  <tr
                    key={
                      record.id
                    }
                    className="border-t border-white/5 hover:bg-white/[0.02]"
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
                      {priceText(
                        record.entryPriceUsd,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                      {priceText(
                        record.currentPriceUsd,
                      )}
                    </td>

                    <td className={`px-3 py-3 font-semibold ${
                      (record.currentGainPercent ??
                        0) >= 0
                        ? "text-emerald-300"
                        : "text-red-300"
                    }`}>
                      <span className="inline-flex items-center gap-1">
                        {(record.currentGainPercent ??
                          0) >= 0 ? (
                          <TrendingUp className="h-3.5 w-3.5" />
                        ) : (
                          <TrendingDown className="h-3.5 w-3.5" />
                        )}

                        {percentText(
                          record.currentGainPercent,
                        )}
                      </span>
                    </td>

                    <td className="px-3 py-3">
                      <div className="font-semibold text-emerald-300">
                        +{record.targetPercent}%
                      </div>

                      <div className="mt-1 font-mono text-[9px] text-zinc-700">
                        {priceText(
                          record.targetPriceUsd,
                        )}
                      </div>
                    </td>

                    <td className="px-3 py-3">
                      <div className="font-semibold text-red-300">
                        -{record.stopLossPercent}%
                      </div>

                      <div className="mt-1 font-mono text-[9px] text-zinc-700">
                        {priceText(
                          record.stopPriceUsd,
                        )}
                      </div>
                    </td>

                    <td className="px-3 py-3 text-cyan-300">
                      {percentText(
                        record.peakGainPercent,
                      )}
                    </td>

                    <td className="px-3 py-3 text-red-300">
                      {percentText(
                        record.maxDrawdownPercent,
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span className="inline-flex items-center gap-1 text-zinc-300">
                        <Clock3 className="h-3.5 w-3.5 text-zinc-600" />

                        {durationText(
                          record.openedAt,
                          end,
                        )}
                      </span>
                    </td>

                    <td className="px-3 py-3">
                      <span className={`rounded-md border px-2 py-1 text-[9px] font-medium tracking-[0.08em] ${
                        record.status ===
                        "target_hit"
                          ? "border-emerald-400/20 bg-emerald-400/[0.06] text-emerald-300"
                          : record.status ===
                              "stop_loss"
                            ? "border-red-400/20 bg-red-400/[0.06] text-red-300"
                            : "border-cyan-400/20 bg-cyan-400/[0.05] text-cyan-300"
                      }`}>
                        {statusLabel(
                          record.status,
                        )}
                      </span>
                    </td>

                    <td className="px-3 py-3">
                      <span className={`text-[10px] ${
                        record.signalStillVisible
                          ? "text-emerald-300"
                          : "text-zinc-700"
                      }`}>
                        {record.signalStillVisible
                          ? "Still detected"
                          : "No longer detected"}
                      </span>
                    </td>

                    <td className="px-3 py-3 text-[10px] text-zinc-600">
                      {dateText(
                        record.openedAt,
                      )}
                    </td>
                  </tr>
                );
              },
            )}
          </tbody>
        </table>

        {records.length ===
          0 && (
          <div className="p-10 text-center">
            <History className="mx-auto h-5 w-5 text-zinc-700" />

            <p className="mt-3 text-sm text-zinc-600">
              The next BUY-watch signal will start a TP / SL record.
            </p>
          </div>
        )}
      </div>

      <div className="border-t border-white/5 px-5 py-3 text-[10px] leading-4 text-zinc-700">
        Default values are +30% target and -15% stop loss and are fully configurable. These are software defaults, not trading recommendations. TP / SL status uses prices observed by the Signal feed, which currently refreshes periodically rather than tick-by-tick.
      </div>
    </section>
  );
}
'@

Write-Utf8NoBom "src/components/signal-performance-panel.tsx" $component

# If Stage 11.2 was not installed, attach the component to Signals page.
$page = [System.IO.File]::ReadAllText($signalsPage)
$original = $page

if ($page -notmatch 'signal-performance-panel') {
    $marker = '"use client";'
    $index = $page.IndexOf($marker)

    if ($index -lt 0) {
        throw "Marker use client tidak ditemukan."
    }

    $index += $marker.Length

    $import = @'

import {
  SignalPerformancePanel,
} from "@/components/signal-performance-panel";
'@

    $page =
      $page.Substring(0, $index) +
      $import +
      $page.Substring($index)
}

if ($page -notmatch '<SignalPerformancePanel') {
    $marker = '      {error && ('
    $index = $page.IndexOf($marker)

    if ($index -lt 0) {
        throw "Posisi SignalPerformancePanel tidak ditemukan."
    }

    $panel = @'
      <SignalPerformancePanel
        signals={allSignals}
        tokens={data?.tokens ?? []}
      />

'@

    $page =
      $page.Substring(0, $index) +
      $panel +
      $page.Substring($index)
}

if ($page -ne $original) {
    [System.IO.File]::WriteAllText(
        $signalsPage,
        $page,
        $utf8
    )

    Write-Host "Patched: src/app/signals/page.tsx" -ForegroundColor Green
}

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " TP / SL lifecycle installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "New lifecycle:" -ForegroundColor Cyan
Write-Host " Signal appears -> ACTIVE"
Write-Host " Signal disappears from live rules -> remains ACTIVE"
Write-Host " Price reaches target -> TARGET HIT"
Write-Host " Price reaches stop loss -> STOP LOSS"
Write-Host ""
Write-Host "Defaults:" -ForegroundColor Cyan
Write-Host " Target: +30%"
Write-Host " Stop Loss: -15%"
Write-Host " Both are configurable in the Signal page."
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
