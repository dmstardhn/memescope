$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Signals - Gain Alerts + History" -ForegroundColor Cyan
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
$backupDir = Join-Path $root ".backup-signal-history-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

Copy-Item `
    -LiteralPath $signalsPage `
    -Destination (Join-Path $backupDir "signals-page.tsx.bak") `
    -Force

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray

# =========================================================
# 1. SIGNAL PERFORMANCE COMPONENT
# =========================================================

$component = @'
"use client";

import {
  Bell,
  BellRing,
  Clock3,
  History,
  Trash2,
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
  "memescope-signal-performance-v1";

const SETTINGS_KEY =
  "memescope-signal-gain-alert-v1";

type PerformanceRecord = {
  recordId: string;
  signalId: string;

  tokenAddress: string;
  symbol: string;
  name: string;
  label: string;

  firstSeenAt: number;
  lastSeenAt: number;
  endedAt: number | null;

  entryPriceUsd: number | null;
  currentPriceUsd: number | null;
  peakPriceUsd: number | null;

  currentGainPercent: number | null;
  peakGainPercent: number | null;

  scoreAtEntry: number;
  lastScore: number;

  active: boolean;

  lastAlertTargetPercent: number | null;
  lastAlertAt: number | null;
};

type AlertSettings = {
  targetPercent: number;
  enabled: boolean;
};

const DEFAULT_ALERT_SETTINGS: AlertSettings = {
  targetPercent: 30,
  enabled: false,
};

function safeNumber(
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

function gainText(
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
  const totalSeconds =
    Math.max(
      0,
      Math.floor(
        (end - start) / 1000,
      ),
    );

  if (totalSeconds < 60) {
    return `${totalSeconds}s`;
  }

  const totalMinutes =
    Math.floor(
      totalSeconds / 60,
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
  value: number,
) {
  return new Date(
    value,
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

function calculateGain(
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

export function SignalPerformancePanel({
  signals,
  tokens,
}: {
  signals: SignalCall[];
  tokens: TerminalToken[];
}) {
  const [history, setHistory] =
    useState<PerformanceRecord[]>(
      [],
    );

  const [settings, setSettings] =
    useState<AlertSettings>(
      DEFAULT_ALERT_SETTINGS,
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
          setHistory(
            parsed as PerformanceRecord[],
          );
        }
      }
    } catch {
      // Ignore malformed local data.
    }

    try {
      const raw =
        localStorage.getItem(
          SETTINGS_KEY,
        );

      if (raw) {
        const parsed =
          JSON.parse(raw) as Partial<AlertSettings>;

        setSettings({
          targetPercent:
            Math.max(
              1,
              safeNumber(
                parsed.targetPercent,
                DEFAULT_ALERT_SETTINGS.targetPercent,
              ),
            ),
          enabled:
            parsed.enabled === true,
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
        history.slice(0, 300),
      ),
    );
  }, [
    hydrated,
    history,
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

    const tokenMap =
      new Map(
        tokens.map(
          (token) => [
            token.address,
            token,
          ],
        ),
      );

    setHistory(
      (current) => {
        let next =
          current.map(
            (record) => ({
              ...record,
            }),
          );

        const currentIds =
          new Set(
            watchSignals.map(
              (signal) =>
                signal.id,
            ),
          );

        next = next.map(
          (record) => {
            if (
              !record.active
            ) {
              return record;
            }

            if (
              currentIds.has(
                record.signalId,
              )
            ) {
              return record;
            }

            const market =
              tokenMap.get(
                record.tokenAddress,
              );

            const latestPrice =
              market?.priceUsd ??
              record.currentPriceUsd;

            const finalGain =
              calculateGain(
                record.entryPriceUsd,
                latestPrice,
              );

            return {
              ...record,
              active: false,
              endedAt:
                currentTime,
              lastSeenAt:
                currentTime,
              currentPriceUsd:
                latestPrice,
              currentGainPercent:
                finalGain,
              peakPriceUsd:
                latestPrice !==
                  null &&
                (
                  record.peakPriceUsd ===
                    null ||
                  latestPrice >
                    record.peakPriceUsd
                )
                  ? latestPrice
                  : record.peakPriceUsd,
              peakGainPercent:
                finalGain !==
                  null &&
                (
                  record.peakGainPercent ===
                    null ||
                  finalGain >
                    record.peakGainPercent
                )
                  ? finalGain
                  : record.peakGainPercent,
            };
          },
        );

        for (
          const signal of watchSignals
        ) {
          const activeIndex =
            next.findIndex(
              (record) =>
                record.active &&
                record.signalId ===
                  signal.id,
            );

          const market =
            tokenMap.get(
              signal.tokenAddress,
            );

          const latestPrice =
            market?.priceUsd ??
            signal.priceUsd ??
            null;

          if (
            activeIndex === -1
          ) {
            next.unshift({
              recordId:
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

              firstSeenAt:
                currentTime,

              lastSeenAt:
                currentTime,

              endedAt:
                null,

              entryPriceUsd:
                latestPrice,

              currentPriceUsd:
                latestPrice,

              peakPriceUsd:
                latestPrice,

              currentGainPercent:
                latestPrice !== null
                  ? 0
                  : null,

              peakGainPercent:
                latestPrice !== null
                  ? 0
                  : null,

              scoreAtEntry:
                signal.signalScore,

              lastScore:
                signal.signalScore,

              active: true,

              lastAlertTargetPercent:
                null,

              lastAlertAt:
                null,
            });

            continue;
          }

          const record =
            next[activeIndex];

          const entryPrice =
            record.entryPriceUsd ??
            latestPrice;

          const currentGain =
            calculateGain(
              entryPrice,
              latestPrice,
            );

          const peakPrice =
            latestPrice !== null &&
            (
              record.peakPriceUsd ===
                null ||
              latestPrice >
                record.peakPriceUsd
            )
              ? latestPrice
              : record.peakPriceUsd;

          const peakGain =
            currentGain !== null &&
            (
              record.peakGainPercent ===
                null ||
              currentGain >
                record.peakGainPercent
            )
              ? currentGain
              : record.peakGainPercent;

          next[activeIndex] = {
            ...record,
            symbol:
              signal.symbol,

            name:
              signal.name,

            label:
              signal.label,

            lastSeenAt:
              currentTime,

            entryPriceUsd:
              entryPrice,

            currentPriceUsd:
              latestPrice,

            peakPriceUsd:
              peakPrice,

            currentGainPercent:
              currentGain,

            peakGainPercent:
              peakGain,

            lastScore:
              signal.signalScore,
          };
        }

        return next
          .sort(
            (a, b) =>
              b.firstSeenAt -
              a.firstSeenAt,
          )
          .slice(0, 300);
      },
    );
  }, [
    hydrated,
    signals,
    tokens,
  ]);

  useEffect(() => {
    if (
      !hydrated ||
      !settings.enabled ||
      typeof Notification ===
        "undefined" ||
      Notification.permission !==
        "granted"
    ) {
      return;
    }

    const hits =
      history.filter(
        (record) =>
          record.active &&
          record.currentGainPercent !==
            null &&
          record.currentGainPercent >=
            settings.targetPercent &&
          (
            record.lastAlertTargetPercent ===
              null ||
            settings.targetPercent >
              record.lastAlertTargetPercent
          ),
      );

    if (hits.length === 0) {
      return;
    }

    for (
      const record of hits.slice(
        0,
        5,
      )
    ) {
      new Notification(
        `MemeScope gain alert: ${record.symbol}`,
        {
          body:
            `${gainText(
              record.currentGainPercent,
            )} since signal. ` +
            `Target: +${settings.targetPercent}%. ` +
            `Hold: ${durationText(
              record.firstSeenAt,
              Date.now(),
            )}.`,
        },
      );
    }

    const hitIds =
      new Set(
        hits.map(
          (record) =>
            record.recordId,
        ),
      );

    setHistory(
      (current) =>
        current.map(
          (record) =>
            hitIds.has(
              record.recordId,
            )
              ? {
                  ...record,
                  lastAlertTargetPercent:
                    settings.targetPercent,
                  lastAlertAt:
                    Date.now(),
                }
              : record,
        ),
    );
  }, [
    hydrated,
    history,
    settings.enabled,
    settings.targetPercent,
  ]);

  async function enableAlerts() {
    if (
      typeof Notification ===
      "undefined"
    ) {
      setMessage(
        "Browser notifications are not supported here.",
      );

      return;
    }

    const permission =
      await Notification.requestPermission();

    if (
      permission === "granted"
    ) {
      setSettings(
        (current) => ({
          ...current,
          enabled: true,
        }),
      );

      setMessage(
        `Gain alerts enabled at +${settings.targetPercent}%.`,
      );

      return;
    }

    setSettings(
      (current) => ({
        ...current,
        enabled: false,
      }),
    );

    setMessage(
      "Notification permission was not granted.",
    );
  }

  function clearHistory() {
    setHistory([]);
    localStorage.removeItem(
      HISTORY_KEY,
    );
  }

  const activeHistory =
    useMemo(
      () =>
        history.filter(
          (item) =>
            item.active,
        ),
      [history],
    );

  const bestPeak =
    useMemo(() => {
      const values =
        history
          .map(
            (item) =>
              item.peakGainPercent,
          )
          .filter(
            (
              value,
            ): value is number =>
              value !== null,
          );

      return values.length > 0
        ? Math.max(
            ...values,
          )
        : null;
    }, [history]);

  return (
    <section className="mt-8 overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
      <div className="flex flex-wrap items-start justify-between gap-4 border-b border-white/5 px-5 py-4">
        <div>
          <div className="flex items-center gap-2">
            <History className="h-4 w-4 text-cyan-300" />

            <h2 className="text-lg font-semibold text-white">
              Signal History & Gain Tracker
            </h2>
          </div>

          <p className="mt-1 max-w-3xl text-xs leading-5 text-zinc-600">
            Tracks performance from the first price MemeScope observes when a BUY-watch signal appears.
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <label className="flex items-center gap-2 rounded-xl border border-white/10 bg-black/20 px-3">
            <span className="text-[10px] uppercase tracking-[0.12em] text-zinc-600">
              Gain alert
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
                        safeNumber(
                          event.target.value,
                          current.targetPercent,
                        ),
                      ),
                  }),
                )
              }
              className="w-16 bg-transparent py-2 text-right text-xs text-white outline-none"
            />

            <span className="text-xs text-zinc-500">
              %
            </span>
          </label>

          <button
            type="button"
            onClick={
              settings.enabled
                ? () =>
                    setSettings(
                      (current) => ({
                        ...current,
                        enabled: false,
                      }),
                    )
                : enableAlerts
            }
            className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
              settings.enabled
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : "border-white/10 text-zinc-400 hover:bg-white/5"
            }`}
          >
            {settings.enabled ? (
              <BellRing className="h-3.5 w-3.5" />
            ) : (
              <Bell className="h-3.5 w-3.5" />
            )}

            {settings.enabled
              ? "Gain alerts on"
              : "Enable gain alerts"}
          </button>

          <button
            type="button"
            onClick={
              clearHistory
            }
            className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-500 hover:bg-white/5 hover:text-white"
          >
            <Trash2 className="h-3.5 w-3.5" />
            Clear
          </button>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-px border-b border-white/5 bg-white/5 lg:grid-cols-4">
        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            Active tracked
          </div>

          <div className="mt-1 text-xl font-semibold text-white">
            {activeHistory.length}
          </div>
        </div>

        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            History records
          </div>

          <div className="mt-1 text-xl font-semibold text-white">
            {history.length}
          </div>
        </div>

        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            Best observed gain
          </div>

          <div className={`mt-1 text-xl font-semibold ${
            bestPeak !== null &&
            bestPeak >= 0
              ? "text-emerald-300"
              : "text-red-300"
          }`}>
            {gainText(
              bestPeak,
            )}
          </div>
        </div>

        <div className="bg-[#0b0e13] p-4">
          <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
            Alert target
          </div>

          <div className="mt-1 text-xl font-semibold text-cyan-300">
            +{settings.targetPercent}%
          </div>
        </div>
      </div>

      {message && (
        <div className="border-b border-white/5 px-5 py-2 text-[10px] text-zinc-500">
          {message}
        </div>
      )}

      <div className="max-h-[620px] overflow-auto">
        <table className="w-full min-w-[1100px] text-left text-xs">
          <thead className="sticky top-0 z-10 bg-[#0d1015] text-[9px] uppercase tracking-[0.12em] text-zinc-700">
            <tr>
              <th className="px-4 py-3">
                Token
              </th>

              <th className="px-3 py-3">
                Signal
              </th>

              <th className="px-3 py-3">
                Entry
              </th>

              <th className="px-3 py-3">
                Current
              </th>

              <th className="px-3 py-3">
                Gain since signal
              </th>

              <th className="px-3 py-3">
                Peak gain
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
                First seen
              </th>
            </tr>
          </thead>

          <tbody>
            {history.map(
              (record) => {
                const end =
                  record.active
                    ? now
                    : record.endedAt ??
                      record.lastSeenAt;

                const gain =
                  record.currentGainPercent;

                return (
                  <tr
                    key={
                      record.recordId
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
                        {record.name}
                      </div>
                    </td>

                    <td className="px-3 py-3">
                      <div className="max-w-[180px] truncate text-zinc-300">
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
                      gain === null
                        ? "text-zinc-600"
                        : gain >= 0
                          ? "text-emerald-300"
                          : "text-red-300"
                    }`}>
                      <span className="inline-flex items-center gap-1">
                        {gain !==
                          null &&
                        gain >= 0 ? (
                          <TrendingUp className="h-3.5 w-3.5" />
                        ) : gain !==
                          null ? (
                          <TrendingDown className="h-3.5 w-3.5" />
                        ) : null}

                        {gainText(
                          gain,
                        )}
                      </span>
                    </td>

                    <td className={`px-3 py-3 font-semibold ${
                      (record.peakGainPercent ??
                        0) >= 0
                        ? "text-cyan-300"
                        : "text-red-300"
                    }`}>
                      {gainText(
                        record.peakGainPercent,
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span className="inline-flex items-center gap-1 text-zinc-300">
                        <Clock3 className="h-3.5 w-3.5 text-zinc-600" />

                        {durationText(
                          record.firstSeenAt,
                          end,
                        )}
                      </span>
                    </td>

                    <td className="px-3 py-3 text-zinc-300">
                      {record.scoreAtEntry}
                      <span className="text-zinc-700">
                        {" -> "}
                      </span>
                      {record.lastScore}
                    </td>

                    <td className="px-3 py-3">
                      <span
                        className={`rounded-md border px-2 py-1 text-[9px] uppercase tracking-[0.1em] ${
                          record.active
                            ? "border-emerald-400/15 bg-emerald-400/[0.05] text-emerald-300"
                            : "border-white/10 text-zinc-600"
                        }`}
                      >
                        {record.active
                          ? "Active"
                          : "Ended"}
                      </span>

                      {record.lastAlertAt && (
                        <div className="mt-1 text-[9px] text-cyan-400/60">
                          alert sent
                        </div>
                      )}
                    </td>

                    <td className="px-3 py-3 text-[10px] text-zinc-600">
                      {dateText(
                        record.firstSeenAt,
                      )}
                    </td>
                  </tr>
                );
              },
            )}
          </tbody>
        </table>

        {history.length === 0 && (
          <div className="p-10 text-center">
            <History className="mx-auto h-5 w-5 text-zinc-700" />

            <p className="mt-3 text-sm text-zinc-600">
              History starts when MemeScope observes the next BUY-watch signal.
            </p>
          </div>
        )}
      </div>

      <div className="border-t border-white/5 px-5 py-3 text-[10px] leading-4 text-zinc-700">
        Gain and peak gain use observed market snapshots from the Signal feed. Current Signal Calls refresh every 15 seconds, so very brief intrainterval spikes can be missed. History is stored locally in this browser in V1.
      </div>
    </section>
  );
}
'@

Write-Utf8NoBom "src/components/signal-performance-panel.tsx" $component

# =========================================================
# 2. PATCH SIGNALS PAGE
# =========================================================

$content = [System.IO.File]::ReadAllText($signalsPage)
$original = $content

# Add component import.
if ($content -notmatch 'signal-performance-panel') {
    $importBlock = @'
import {
  SignalPerformancePanel,
} from "@/components/signal-performance-panel";

'@

    $firstLocalImport = [regex]::Match(
        $content,
        '(?m)^import\s+\{[\s\S]*?\}\s+from\s+"@/lib/signal-engine";\s*\r?\n'
    )

    if ($firstLocalImport.Success) {
        $insertAt =
          $firstLocalImport.Index

        $content =
          $content.Substring(0, $insertAt) +
          $importBlock +
          $content.Substring($insertAt)
    } else {
        $clientMarker = '"use client";'

        $idx =
          $content.IndexOf(
            $clientMarker
          )

        if ($idx -lt 0) {
            throw "Marker use client tidak ditemukan. signals/page.tsx tidak diubah."
        }

        $idx +=
          $clientMarker.Length

        $content =
          $content.Substring(0, $idx) +
          "`r`n`r`n" +
          $importBlock +
          $content.Substring($idx)
    }
}

# Add panel once before final disclaimer.
if ($content -notmatch '<SignalPerformancePanel') {
    $disclaimerPattern =
      '(?s)(\s*<div className="mt-6 rounded-xl border border-white/5 bg-black/20 p-4 text-\[11px\] leading-5 text-zinc-600">)'

    $match =
      [regex]::Match(
        $content,
        $disclaimerPattern
      )

    if (!$match.Success) {
        throw "Posisi untuk Signal History tidak ditemukan. signals/page.tsx tidak diubah."
    }

    $panel = @'

      <SignalPerformancePanel
        signals={allSignals}
        tokens={data?.tokens ?? []}
      />

'@

    $content =
      $content.Substring(
        0,
        $match.Index
      ) +
      $panel +
      $content.Substring(
        $match.Index
      )
}

if ($content -eq $original) {
    Write-Host "Signals page sudah memiliki patch ini." -ForegroundColor Yellow
} else {
    [System.IO.File]::WriteAllText(
        $signalsPage,
        $content,
        $utf8
    )

    Write-Host "Patched: src/app/signals/page.tsx" -ForegroundColor Green
}

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Gain Alerts + Signal History installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Added:" -ForegroundColor Cyan
Write-Host " - configurable gain alert percentage"
Write-Host " - browser notification when target is observed"
Write-Host " - entry price captured when signal first appears"
Write-Host " - current gain since signal"
Write-Host " - peak observed gain"
Write-Host " - hold duration"
Write-Host " - signal score at entry -> latest score"
Write-Host " - active / ended status"
Write-Host " - persistent local history"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
