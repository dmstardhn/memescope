$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 14.1 - Direct Token Terminal" -ForegroundColor Cyan
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

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "package.json tidak ditemukan. Jalankan script dari root memecoin-analyst."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $root ".backup-stage14-1-$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

foreach ($file in @(
    "src/components/token-market-terminal.tsx",
    "src/components/token-quick-view.tsx",
    "src/components/memescope-live-chart.tsx",
    "src/components/app-shell.tsx",
    "src/app/token/[address]/page.tsx",
    "package.json"
)) {
    $full = Join-Path $root $file

    if (Test-Path -LiteralPath $full) {
        $safe = ($file -replace '[\\/]', '__') + ".bak"
        Copy-Item -LiteralPath $full -Destination (Join-Path $backupDir $safe) -Force
    }
}

Write-Host "Backup: $backupDir" -ForegroundColor DarkGray

# ---------------------------------------------------------
# 1. Replace token terminal with live transactions-first UI.
#    No chart, no candle controls, no timeframe, no metric/quote chart mode.
# ---------------------------------------------------------

$terminal = @'
"use client";

import Link from "next/link";
import {
  Bookmark,
  BookmarkCheck,
  Copy,
  ExternalLink,
  RefreshCw,
  ShieldCheck,
  Wifi,
  WifiOff,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

import type {
  MemeScopeLiveSnapshot,
  MemeScopeLiveTrade,
  MemeScopeStreamMode,
} from "@/lib/memescope-market-types";

import type {
  TokenTerminalResponse,
} from "@/lib/token-terminal-types";

const WATCHLIST_KEY =
  "memescope-token-watchlist";

function money(
  value: number | null | undefined,
) {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (Math.abs(value) >= 1_000_000_000) {
    return `$${(
      value / 1_000_000_000
    ).toFixed(2)}B`;
  }

  if (Math.abs(value) >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (Math.abs(value) >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(1)}K`;
  }

  if (Math.abs(value) >= 1) {
    return `$${value.toFixed(3)}`;
  }

  return `$${value.toPrecision(5)}`;
}

function solText(
  value: number | null | undefined,
) {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (Math.abs(value) >= 1_000) {
    return `${(
      value / 1_000
    ).toFixed(2)}K SOL`;
  }

  if (Math.abs(value) >= 1) {
    return `${value.toFixed(3)} SOL`;
  }

  return `${value.toPrecision(5)} SOL`;
}

function tokenAmount(
  value: number | null | undefined,
) {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (Math.abs(value) >= 1_000_000_000) {
    return `${(
      value / 1_000_000_000
    ).toFixed(2)}B`;
  }

  if (Math.abs(value) >= 1_000_000) {
    return `${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (Math.abs(value) >= 1_000) {
    return `${(
      value / 1_000
    ).toFixed(2)}K`;
  }

  return value.toFixed(3);
}

function percent(
  value: number | null | undefined,
) {
  if (
    value === null ||
    value === undefined ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  return `${value > 0 ? "+" : ""}${value.toFixed(
    2,
  )}%`;
}

function short(
  value: string,
) {
  if (value.length <= 13) {
    return value;
  }

  return `${value.slice(
    0,
    5,
  )}...${value.slice(-4)}`;
}

function clock(
  timestamp: number,
) {
  return new Date(
    timestamp,
  ).toLocaleTimeString("en-US", {
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function age(
  timestamp: number | null,
) {
  if (!timestamp) {
    return "N/A";
  }

  const minutes =
    Math.max(
      0,
      Math.floor(
        (Date.now() - timestamp) /
          60_000,
      ),
    );

  if (minutes < 60) {
    return `${minutes}m`;
  }

  if (minutes < 1440) {
    return `${Math.floor(
      minutes / 60,
    )}h`;
  }

  return `${Math.floor(
    minutes / 1440,
  )}d`;
}

function streamLabel(
  mode: MemeScopeStreamMode,
) {
  if (mode === "enhanced") {
    return "LIVE";
  }

  if (mode === "logs-rpc") {
    return "LIVE RPC";
  }

  if (mode === "reconnecting") {
    return "RECONNECTING";
  }

  if (mode === "offline") {
    return "OFFLINE";
  }

  return "CONNECTING";
}

export function TokenMarketTerminal({
  address,
}: {
  address: string;
}) {
  const [data, setData] =
    useState<TokenTerminalResponse | null>(
      null,
    );

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  const [streamMode, setStreamMode] =
    useState<MemeScopeStreamMode>(
      "connecting",
    );

  const [streamMessage, setStreamMessage] =
    useState(
      "Connecting real-time stream",
    );

  const [snapshot, setSnapshot] =
    useState<MemeScopeLiveSnapshot | null>(
      null,
    );

  const [liveTrades, setLiveTrades] =
    useState<MemeScopeLiveTrade[]>(
      [],
    );

  const [saved, setSaved] =
    useState(false);

  async function load() {
    setLoading(true);

    try {
      const response = await fetch(
        `/api/token-terminal/solana/${address}?tf=5m`,
        {
          cache: "no-store",
        },
      );

      const result =
        (await response.json()) as
          | TokenTerminalResponse
          | {
              error?: string;
            };

      if (!response.ok) {
        throw new Error(
          "error" in result
            ? result.error
            : "Token market data failed.",
        );
      }

      setData(
        result as TokenTerminalResponse,
      );

      setError("");
    } catch (loadError) {
      setError(
        loadError instanceof Error
          ? loadError.message
          : "Token market data failed.",
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    setData(null);
    setSnapshot(null);
    setLiveTrades([]);
    setStreamMode(
      "connecting",
    );

    void load();
  }, [address]);

  useEffect(() => {
    try {
      const raw =
        localStorage.getItem(
          WATCHLIST_KEY,
        );

      const parsed = raw
        ? (JSON.parse(raw) as unknown)
        : [];

      setSaved(
        Array.isArray(parsed) &&
          parsed.includes(address),
      );
    } catch {
      setSaved(false);
    }
  }, [address]);

  useEffect(() => {
    const poolAddress =
      data?.selectedPool.address;

    if (!poolAddress) {
      return;
    }

    setLiveTrades([]);
    setSnapshot(null);
    setStreamMode(
      "connecting",
    );

    const source =
      new EventSource(
        `/api/live-market/solana/${address}?pool=${encodeURIComponent(
          poolAddress,
        )}`,
      );

    const onStatus = (
      event: MessageEvent,
    ) => {
      try {
        const parsed =
          JSON.parse(
            event.data,
          ) as {
            mode: MemeScopeStreamMode;
            message: string;
          };

        setStreamMode(
          parsed.mode,
        );

        setStreamMessage(
          parsed.message,
        );
      } catch {
        // Ignore malformed event.
      }
    };

    const onSnapshot = (
      event: MessageEvent,
    ) => {
      try {
        const parsed =
          JSON.parse(
            event.data,
          ) as {
            snapshot: MemeScopeLiveSnapshot;
          };

        setSnapshot(
          parsed.snapshot,
        );
      } catch {
        // Ignore malformed event.
      }
    };

    const onTrade = (
      event: MessageEvent,
    ) => {
      try {
        const parsed =
          JSON.parse(
            event.data,
          ) as {
            trade: MemeScopeLiveTrade;
          };

        const trade =
          parsed.trade;

        setLiveTrades(
          (current) => {
            if (
              trade.signature &&
              current.some(
                (item) =>
                  item.signature ===
                  trade.signature,
              )
            ) {
              return current;
            }

            return [
              trade,
              ...current,
            ].slice(0, 400);
          },
        );

        setSnapshot(
          (current) => {
            if (!current) {
              return current;
            }

            const next = {
              ...current,
              updatedAt: Date.now(),
            };

            if (
              trade.priceUsd
            ) {
              next.priceUsd =
                trade.priceUsd;
            }

            if (
              trade.priceSol
            ) {
              next.priceSol =
                trade.priceSol;
            }

            if (
              trade.priceUsd &&
              trade.priceSol &&
              trade.priceSol > 0
            ) {
              next.solUsd =
                trade.priceUsd /
                trade.priceSol;
            }

            return next;
          },
        );
      } catch {
        // Ignore malformed event.
      }
    };

    source.addEventListener(
      "status",
      onStatus as EventListener,
    );

    source.addEventListener(
      "snapshot",
      onSnapshot as EventListener,
    );

    source.addEventListener(
      "trade",
      onTrade as EventListener,
    );

    source.onerror = () => {
      setStreamMode(
        "reconnecting",
      );

      setStreamMessage(
        "Browser stream reconnecting",
      );
    };

    return () => {
      source.close();
    };
  }, [
    address,
    data?.selectedPool.address,
  ]);

  const selected =
    data?.selectedPool;

  const priceUsd =
    snapshot?.priceUsd ??
    selected?.priceUsd ??
    null;

  const solUsd =
    snapshot?.solUsd ??
    null;

  const priceSol =
    snapshot?.priceSol ??
    (priceUsd &&
    solUsd &&
    solUsd > 0
      ? priceUsd / solUsd
      : null);

  const marketCap =
    selected?.marketCapUsd ??
    selected?.fdvUsd ??
    null;

  const buys5m =
    selected?.txns.m5.buys ??
    0;

  const sells5m =
    selected?.txns.m5.sells ??
    0;

  const buyShare =
    buys5m + sells5m > 0
      ? Math.round(
          (buys5m /
            (buys5m +
              sells5m)) *
            100,
        )
      : null;

  const displayedTrades =
    useMemo(
      () =>
        liveTrades.slice(
          0,
          300,
        ),
      [liveTrades],
    );

  function toggleWatchlist() {
    let values: string[] = [];

    try {
      const raw =
        localStorage.getItem(
          WATCHLIST_KEY,
        );

      const parsed = raw
        ? (JSON.parse(raw) as unknown)
        : [];

      if (
        Array.isArray(parsed)
      ) {
        values =
          parsed.filter(
            (
              item,
            ): item is string =>
              typeof item ===
              "string",
          );
      }
    } catch {
      values = [];
    }

    const exists =
      values.includes(address);

    const next = exists
      ? values.filter(
          (item) =>
            item !== address,
        )
      : Array.from(
          new Set([
            ...values,
            address,
          ]),
        );

    localStorage.setItem(
      WATCHLIST_KEY,
      JSON.stringify(next),
    );

    setSaved(!exists);
  }

  if (
    loading &&
    !data
  ) {
    return (
      <main className="flex min-h-[65vh] items-center justify-center">
        <div className="text-center">
          <RefreshCw className="mx-auto h-5 w-5 animate-spin text-emerald-300" />

          <div className="mt-3 text-sm text-zinc-500">
            Loading token terminal...
          </div>
        </div>
      </main>
    );
  }

  if (
    !data ||
    !selected
  ) {
    return (
      <main className="mx-auto w-full max-w-5xl px-4 py-8">
        <div className="rounded-2xl border border-red-400/20 bg-red-400/[0.05] p-5 text-sm text-red-200">
          {error ||
            "Token market data unavailable."}
        </div>
      </main>
    );
  }

  return (
    <main className="mx-auto w-full max-w-[1500px] px-4 py-5 lg:px-6">
      <header className="mb-5 flex flex-wrap items-start justify-between gap-4">
        <div className="flex min-w-0 items-center gap-3">
          {data.token.imageUrl ? (
            <img
              src={
                data.token.imageUrl
              }
              alt=""
              className="h-12 w-12 rounded-full border border-white/10 object-cover"
            />
          ) : (
            <div className="flex h-12 w-12 items-center justify-center rounded-full border border-white/10 bg-white/5 text-sm font-semibold text-zinc-500">
              {data.token.symbol.slice(
                0,
                2,
              )}
            </div>
          )}

          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <h1 className="text-xl font-semibold text-white">
                {
                  data.token
                    .symbol
                }
              </h1>

              <span className="text-sm text-zinc-600">
                {
                  data.token
                    .name
                }
              </span>

              <span className="rounded-md border border-white/10 px-1.5 py-0.5 text-[9px] uppercase text-zinc-600">
                Solana
              </span>
            </div>

            <div className="mt-1 flex flex-wrap items-center gap-2 text-[11px] text-zinc-600">
              <button
                type="button"
                onClick={() =>
                  navigator.clipboard.writeText(
                    address,
                  )
                }
                className="flex items-center gap-1 hover:text-zinc-300"
              >
                {short(address)}
                <Copy className="h-3 w-3" />
              </button>

              <span>|</span>

              <span>
                {selected.dexName}
              </span>

              <span>|</span>

              <span>
                age{" "}
                {age(
                  selected.createdAt,
                )}
              </span>
            </div>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <div
            title={
              streamMessage
            }
            className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
              streamMode ===
                "enhanced" ||
              streamMode ===
                "logs-rpc"
                ? "border-emerald-400/20 bg-emerald-400/[0.06] text-emerald-300"
                : "border-white/10 text-zinc-500"
            }`}
          >
            {streamMode ===
              "enhanced" ||
            streamMode ===
              "logs-rpc" ? (
              <Wifi className="h-3.5 w-3.5" />
            ) : (
              <WifiOff className="h-3.5 w-3.5" />
            )}

            {streamLabel(
              streamMode,
            )}
          </div>

          <button
            type="button"
            onClick={
              toggleWatchlist
            }
            className={`flex items-center gap-2 rounded-xl border px-3 py-2 text-xs ${
              saved
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : "border-white/10 text-zinc-400 hover:bg-white/5"
            }`}
          >
            {saved ? (
              <BookmarkCheck className="h-3.5 w-3.5" />
            ) : (
              <Bookmark className="h-3.5 w-3.5" />
            )}

            {saved
              ? "Watching"
              : "Watch"}
          </button>

          <Link
            href={`/analyst?address=${address}`}
            className="rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-400 hover:bg-white/5"
          >
            AI Analyst
          </Link>

          <button
            type="button"
            onClick={() =>
              void load()
            }
            className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-400 hover:bg-white/5"
          >
            <RefreshCw className="h-3.5 w-3.5" />
            Refresh
          </button>
        </div>
      </header>

      <section className="mb-5 grid grid-cols-2 gap-2 md:grid-cols-4 xl:grid-cols-8">
        {[
          [
            "Price USD",
            money(priceUsd),
          ],
          [
            "Price SOL",
            solText(
              priceSol,
            ),
          ],
          [
            "5m",
            percent(
              selected
                .priceChange.m5,
            ),
          ],
          [
            "1h",
            percent(
              selected
                .priceChange.h1,
            ),
          ],
          [
            "Market Cap",
            money(marketCap),
          ],
          [
            "Liquidity",
            money(
              selected
                .liquidityUsd,
            ),
          ],
          [
            "Volume 24h",
            money(
              selected
                .volume.h24,
            ),
          ],
          [
            "Buy Share 5m",
            buyShare !== null
              ? `${buyShare}%`
              : "N/A",
          ],
        ].map(
          ([label, value]) => (
            <div
              key={
                String(label)
              }
              className="rounded-xl border border-white/10 bg-white/[0.025] p-3"
            >
              <div className="text-[9px] uppercase tracking-[0.13em] text-zinc-700">
                {label}
              </div>

              <div className="mt-1 text-sm font-semibold text-zinc-100">
                {value}
              </div>
            </div>
          ),
        )}
      </section>

      <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_320px]">
        <section className="overflow-hidden rounded-2xl border border-white/10 bg-white/[0.02]">
          <div className="flex flex-wrap items-center justify-between gap-3 border-b border-white/5 px-4 py-3">
            <div>
              <h2 className="text-sm font-semibold text-white">
                Live Transactions
              </h2>

              <p className="mt-1 text-[10px] text-zinc-700">
                New swaps appear here from the MemeScope live stream.
              </p>
            </div>

            <div className="text-[10px] text-zinc-600">
              {
                displayedTrades.length
              }{" "}
              live rows
            </div>
          </div>

          <div className="max-h-[680px] overflow-auto">
            <table className="w-full min-w-[900px] text-left text-xs">
              <thead className="sticky top-0 z-10 bg-[#0d1015] text-[9px] uppercase tracking-[0.12em] text-zinc-700">
                <tr>
                  <th className="px-4 py-3">
                    Time
                  </th>
                  <th className="px-3 py-3">
                    Type
                  </th>
                  <th className="px-3 py-3">
                    USD
                  </th>
                  <th className="px-3 py-3">
                    SOL
                  </th>
                  <th className="px-3 py-3">
                    Token
                  </th>
                  <th className="px-3 py-3">
                    Price USD
                  </th>
                  <th className="px-3 py-3">
                    Price SOL
                  </th>
                  <th className="px-3 py-3">
                    Maker
                  </th>
                  <th className="px-3 py-3">
                    Tx
                  </th>
                </tr>
              </thead>

              <tbody>
                {displayedTrades.map(
                  (trade) => (
                    <tr
                      key={`${trade.signature}-${trade.timestamp}`}
                      className="border-t border-white/5"
                    >
                      <td className="px-4 py-3 font-mono text-[10px] text-zinc-600">
                        {clock(
                          trade.timestamp,
                        )}
                      </td>

                      <td
                        className={`px-3 py-3 font-semibold ${
                          trade.side ===
                          "buy"
                            ? "text-emerald-300"
                            : "text-red-300"
                        }`}
                      >
                        {trade.side.toUpperCase()}
                      </td>

                      <td className="px-3 py-3 text-zinc-200">
                        {money(
                          trade.usdAmount,
                        )}

                        {trade.estimated && (
                          <span className="ml-1 text-[8px] text-amber-400/70">
                            EST
                          </span>
                        )}
                      </td>

                      <td className="px-3 py-3 text-zinc-300">
                        {solText(
                          trade.solAmount,
                        )}
                      </td>

                      <td className="px-3 py-3 text-zinc-400">
                        {tokenAmount(
                          trade.tokenAmount,
                        )}
                      </td>

                      <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                        {money(
                          trade.priceUsd,
                        )}
                      </td>

                      <td className="px-3 py-3 font-mono text-[10px] text-zinc-400">
                        {trade.priceSol !==
                        null
                          ? trade.priceSol.toPrecision(
                              5,
                            )
                          : "N/A"}
                      </td>

                      <td className="px-3 py-3 font-mono text-[10px] text-zinc-600">
                        {trade.maker
                          ? short(
                              trade.maker,
                            )
                          : "N/A"}
                      </td>

                      <td className="px-3 py-3">
                        {trade.signature ? (
                          <a
                            href={`https://solscan.io/tx/${trade.signature}`}
                            target="_blank"
                            rel="noreferrer"
                            className="text-zinc-600 hover:text-white"
                          >
                            <ExternalLink className="h-3.5 w-3.5" />
                          </a>
                        ) : (
                          <span className="text-zinc-700">
                            N/A
                          </span>
                        )}
                      </td>
                    </tr>
                  ),
                )}
              </tbody>
            </table>

            {displayedTrades.length ===
              0 && (
              <div className="flex min-h-[260px] items-center justify-center p-8 text-center">
                <div>
                  <div className="text-sm text-zinc-500">
                    Waiting for the next swap...
                  </div>

                  <div className="mt-2 text-[10px] text-zinc-700">
                    {streamMessage}
                  </div>
                </div>
              </div>
            )}
          </div>
        </section>

        <aside className="space-y-4">
          <section className="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
            <div className="flex items-center gap-2 text-sm font-semibold text-white">
              <ShieldCheck className="h-4 w-4 text-emerald-300" />
              Market Snapshot
            </div>

            <div className="mt-4 space-y-2 text-xs">
              {[
                [
                  "Pool",
                  selected.name,
                ],
                [
                  "DEX",
                  selected.dexName,
                ],
                [
                  "5m buys",
                  selected.txns.m5.buys,
                ],
                [
                  "5m sells",
                  selected.txns.m5.sells,
                ],
                [
                  "1h volume",
                  money(
                    selected.volume.h1,
                  ),
                ],
                [
                  "24h volume",
                  money(
                    selected.volume.h24,
                  ),
                ],
              ].map(
                ([label, value]) => (
                  <div
                    key={
                      String(label)
                    }
                    className="flex items-center justify-between gap-3 rounded-lg bg-black/20 px-3 py-2"
                  >
                    <span className="text-zinc-600">
                      {label}
                    </span>

                    <span className="max-w-[170px] truncate text-right text-zinc-300">
                      {value}
                    </span>
                  </div>
                ),
              )}
            </div>
          </section>

          <section className="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
            <div className="text-sm font-semibold text-white">
              Liquidity Pools
            </div>

            <div className="mt-3 space-y-2">
              {data.pools
                .slice(0, 6)
                .map(
                  (pool) => (
                    <div
                      key={
                        pool.address
                      }
                      className={`rounded-lg border px-3 py-2 ${
                        pool.address ===
                        selected.address
                          ? "border-emerald-400/15 bg-emerald-400/[0.04]"
                          : "border-white/5 bg-black/20"
                      }`}
                    >
                      <div className="truncate text-xs text-zinc-300">
                        {pool.name}
                      </div>

                      <div className="mt-1 flex justify-between gap-2 text-[10px] text-zinc-700">
                        <span>
                          {pool.dexName}
                        </span>

                        <span>
                          {money(
                            pool.liquidityUsd,
                          )}
                        </span>
                      </div>
                    </div>
                  ),
                )}
            </div>
          </section>
        </aside>
      </div>

      <div className="mt-4 text-[9px] leading-4 text-zinc-700">
        Live transaction rows use the configured MemeScope Solana stream. EST means the USD side was estimated from the latest available market snapshot.
      </div>

      {error && (
        <div className="mt-4 rounded-xl border border-amber-400/15 bg-amber-400/[0.04] p-3 text-xs text-amber-100/70">
          {error}
        </div>
      )}
    </main>
  );
}
'@

Write-Utf8NoBom "src/components/token-market-terminal.tsx" $terminal

# ---------------------------------------------------------
# 2. Token page remains a real route.
# ---------------------------------------------------------

$tokenPage = @'
"use client";

import {
  useParams,
} from "next/navigation";

import {
  TokenMarketTerminal,
} from "@/components/token-market-terminal";

export default function TokenPage() {
  const params =
    useParams<{
      address: string;
    }>();

  return (
    <TokenMarketTerminal
      address={
        params.address
      }
    />
  );
}
'@

Write-Utf8NoBom "src/app/token/[address]/page.tsx" $tokenPage

# ---------------------------------------------------------
# 3. Remove the global quick-view modal interception.
#    Internal /token/... links now navigate normally.
# ---------------------------------------------------------

$appShellPath = Join-Path $root "src/components/app-shell.tsx"

if (Test-Path -LiteralPath $appShellPath) {
    $shell = [System.IO.File]::ReadAllText($appShellPath)

    $shell = [regex]::Replace(
        $shell,
        '(?m)^[ \t]*import\s*\{\s*TokenQuickView\s*\}\s*from\s*["'']@/components/token-quick-view["''];?[ \t]*\r?\n',
        ''
    )

    $shell = [regex]::Replace(
        $shell,
        '(?m)^[ \t]*<TokenQuickView\s*/>[ \t]*\r?\n?',
        ''
    )

    [System.IO.File]::WriteAllText(
        $appShellPath,
        $shell,
        $utf8
    )

    Write-Host "Removed global token modal interception." -ForegroundColor Green
}

# ---------------------------------------------------------
# 4. Remove chart-only files.
# ---------------------------------------------------------

foreach ($file in @(
    "src/components/token-quick-view.tsx",
    "src/components/memescope-live-chart.tsx"
)) {
    $full = Join-Path $root $file

    if (Test-Path -LiteralPath $full) {
        Remove-Item -LiteralPath $full -Force
        Write-Host "Removed: $file" -ForegroundColor Green
    }
}

# ---------------------------------------------------------
# 5. Remove Lightweight Charts package if installed.
# ---------------------------------------------------------

$packagePath = Join-Path $root "package.json"

if (Test-Path -LiteralPath $packagePath) {
    $package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json

    $hasChart = $false

    if (
        $package.dependencies -and
        $package.dependencies.PSObject.Properties.Name -contains "lightweight-charts"
    ) {
        $hasChart = $true
    }

    if (
        $package.devDependencies -and
        $package.devDependencies.PSObject.Properties.Name -contains "lightweight-charts"
    ) {
        $hasChart = $true
    }

    if ($hasChart) {
        Write-Host "Removing lightweight-charts..." -ForegroundColor Cyan
        npm uninstall lightweight-charts

        if ($LASTEXITCODE -ne 0) {
            throw "npm uninstall lightweight-charts failed."
        }
    } else {
        Write-Host "lightweight-charts is not installed." -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------
# 6. Check that known pages contain /token links.
#    Do not apply dangerous global regex rewrites.
# ---------------------------------------------------------

Write-Host ""
Write-Host "Checking token navigation..." -ForegroundColor Cyan

foreach ($page in @(
    "src/app/scanner/page.tsx",
    "src/app/discover/page.tsx",
    "src/app/signals/page.tsx",
    "src/app/watchlist/page.tsx",
    "src/app/workspace/page.tsx",
    "src/app/smart-money/page.tsx"
)) {
    $full = Join-Path $root $page

    if (!(Test-Path -LiteralPath $full)) {
        continue
    }

    $content = [System.IO.File]::ReadAllText($full)

    if ($content -match '/token/') {
        Write-Host "OK direct token route: $page" -ForegroundColor Green
    } else {
        Write-Host "WARNING no /token/ link detected: $page" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------
# 7. Clear cache.
# ---------------------------------------------------------

Remove-Item -Recurse -Force (Join-Path $root ".next") -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 14.1 complete" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Result:" -ForegroundColor Cyan
Write-Host " - Candlestick chart removed"
Write-Host " - Chart timeframe controls removed"
Write-Host " - Price/MCAP chart mode removed"
Write-Host " - USD/SOL chart selector removed"
Write-Host " - Token quick-view modal removed"
Write-Host " - Every existing /token/... link navigates directly to the token page"
Write-Host " - Live BUY/SELL transaction terminal kept"
Write-Host " - USD, SOL, token amount, price and maker kept"
Write-Host " - Sidebar remains persistent through Root Layout"
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host "npm run typecheck"
Write-Host "npm run dev"
Write-Host ""
