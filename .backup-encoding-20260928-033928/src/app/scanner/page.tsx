"use client";

import Link from "next/link";
import {
  ExternalLink,
  Filter,
  RefreshCw,
  Search,
  SlidersHorizontal,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

import type {
  TerminalResponse,
  TerminalToken,
} from "@/lib/terminal-types";

type Tab =
  | "trending"
  | "new"
  | "gainers"
  | "volume"
  | "liquidity"
  | "boosted";

function money(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "â€”";
  }

  if (Math.abs(value) >= 1_000_000_000) {
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  }

  if (Math.abs(value) >= 1_000_000) {
    return `$${(value / 1_000_000).toFixed(2)}M`;
  }

  if (Math.abs(value) >= 1_000) {
    return `$${(value / 1_000).toFixed(1)}K`;
  }

  if (Math.abs(value) >= 1) {
    return `$${value.toFixed(2)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function price(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "â€”";
  }

  if (value >= 1) {
    return `$${value.toLocaleString(
      "en-US",
      {
        maximumFractionDigits: 6,
      },
    )}`;
  }

  if (value >= 0.01) {
    return `$${value.toFixed(5)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function percent(value: number | null) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return (
      <span className="text-zinc-600">
        â€”
      </span>
    );
  }

  const tone =
    value > 0
      ? "text-emerald-300"
      : value < 0
        ? "text-red-300"
        : "text-zinc-400";

  return (
    <span className={tone}>
      {value > 0 ? "+" : ""}
      {value.toFixed(2)}%
    </span>
  );
}

function age(minutes: number | null) {
  if (
    minutes === null ||
    !Number.isFinite(minutes)
  ) {
    return "â€”";
  }

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

function rowSort(
  tab: Tab,
  a: TerminalToken,
  b: TerminalToken,
) {
  if (tab === "new") {
    return (
      (a.pairAgeMinutes ??
        Number.POSITIVE_INFINITY) -
      (b.pairAgeMinutes ??
        Number.POSITIVE_INFINITY)
    );
  }

  if (tab === "gainers") {
    return (
      (b.priceChange.m5 ?? -99999) -
      (a.priceChange.m5 ?? -99999)
    );
  }

  if (tab === "volume") {
    return b.volume.m5 - a.volume.m5;
  }

  if (tab === "liquidity") {
    return (
      b.liquidityUsd -
      a.liquidityUsd
    );
  }

  if (tab === "boosted") {
    return (
      b.boostsActive -
        a.boostsActive ||
      b.boostTotalAmount -
        a.boostTotalAmount
    );
  }

  return (
    b.activityScore -
    a.activityScore
  );
}

function TokenIdentity({
  token,
}: {
  token: TerminalToken;
}) {
  return (
    <div className="flex min-w-[210px] items-center gap-3">
      {token.imageUrl ? (
        <img
          src={token.imageUrl}
          alt=""
          className="h-9 w-9 rounded-full border border-white/10 object-cover"
        />
      ) : (
        <div className="flex h-9 w-9 items-center justify-center rounded-full border border-white/10 bg-white/5 text-xs font-bold text-zinc-500">
          {token.symbol.slice(0, 2)}
        </div>
      )}

      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="max-w-[120px] truncate font-semibold text-white">
            {token.symbol}
          </span>

          {token.boostsActive > 0 && (
            <span className="rounded bg-amber-400/10 px-1.5 py-0.5 text-[9px] font-semibold text-amber-300">
              BOOST
            </span>
          )}
        </div>

        <div className="max-w-[165px] truncate text-[11px] text-zinc-600">
          {token.name}
        </div>
      </div>
    </div>
  );
}

export default function ScannerPage() {
  const [data, setData] =
    useState<TerminalResponse | null>(
      null,
    );

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  const [tab, setTab] =
    useState<Tab>("trending");

  const [query, setQuery] =
    useState("");

  const [minLiquidity, setMinLiquidity] =
    useState(0);

  const [maxAgeHours, setMaxAgeHours] =
    useState(0);

  async function load(
    silent = false,
  ) {
    if (!silent) setLoading(true);

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
            : "Scanner failed.",
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
          : "Scanner failed.",
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
      15_000,
    );

    return () =>
      window.clearInterval(timer);
  }, []);

  const filtered = useMemo(() => {
    const needle =
      query.trim().toLowerCase();

    return [...(data?.tokens ?? [])]
      .filter((token) => {
        if (
          needle &&
          !token.symbol
            .toLowerCase()
            .includes(needle) &&
          !token.name
            .toLowerCase()
            .includes(needle) &&
          !token.address
            .toLowerCase()
            .includes(needle)
        ) {
          return false;
        }

        if (
          token.liquidityUsd <
          minLiquidity
        ) {
          return false;
        }

        if (
          maxAgeHours > 0 &&
          token.pairAgeMinutes !==
            null &&
          token.pairAgeMinutes >
            maxAgeHours * 60
        ) {
          return false;
        }

        if (
          tab === "boosted" &&
          token.boostsActive <= 0 &&
          token.boostTotalAmount <= 0
        ) {
          return false;
        }

        return true;
      })
      .sort((a, b) =>
        rowSort(tab, a, b),
      );
  }, [
    data,
    query,
    minLiquidity,
    maxAgeHours,
    tab,
  ]);

  const totals = useMemo(() => {
    const tokens = data?.tokens ?? [];

    return {
      volume5m: tokens.reduce(
        (sum, token) =>
          sum + token.volume.m5,
        0,
      ),

      liquidity: tokens.reduce(
        (sum, token) =>
          sum +
          token.liquidityUsd,
        0,
      ),

      newPairs: tokens.filter(
        (token) =>
          token.pairAgeMinutes !==
            null &&
          token.pairAgeMinutes <= 60,
      ).length,

      boosted: tokens.filter(
        (token) =>
          token.boostsActive > 0,
      ).length,
    };
  }, [data]);

  const tabs: Array<{
    id: Tab;
    label: string;
  }> = [
    {
      id: "trending",
      label: "Trending",
    },
    {
      id: "new",
      label: "New",
    },
    {
      id: "gainers",
      label: "Gainers 5m",
    },
    {
      id: "volume",
      label: "Volume 5m",
    },
    {
      id: "liquidity",
      label: "Liquidity",
    },
    {
      id: "boosted",
      label: "Boosted",
    },
  ];

  return (
    <main className="mx-auto w-full max-w-[1900px] px-3 py-5 lg:px-6">
      <div className="mb-5 flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="text-[10px] uppercase tracking-[0.22em] text-emerald-300">
            Solana market terminal
          </div>

          <h1 className="mt-1 text-2xl font-semibold tracking-tight text-white">
            Scanner
          </h1>

          <p className="mt-1 text-sm text-zinc-500">
            Dense market view for recent,
            active and boosted Solana tokens.
          </p>
        </div>

        <button
          onClick={() =>
            void load()
          }
          disabled={loading}
          className="flex items-center gap-2 rounded-xl border border-white/10 px-3 py-2 text-xs text-zinc-300 hover:bg-white/5 disabled:opacity-50"
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

      <section className="mb-4 grid grid-cols-2 gap-2 md:grid-cols-4">
        {[
          [
            "Pairs loaded",
            data?.tokenCount ?? 0,
          ],
          [
            "5m volume",
            money(totals.volume5m),
          ],
          [
            "Liquidity",
            money(totals.liquidity),
          ],
          [
            "New <1h",
            totals.newPairs,
          ],
        ].map(([label, value]) => (
          <div
            key={String(label)}
            className="rounded-xl border border-white/10 bg-white/[0.025] px-4 py-3"
          >
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              {label}
            </div>
            <div className="mt-1 text-lg font-semibold text-white">
              {value}
            </div>
          </div>
        ))}
      </section>

      <section className="mb-3 rounded-xl border border-white/10 bg-white/[0.02] p-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-[230px] flex-1">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />

            <input
              value={query}
              onChange={(event) =>
                setQuery(
                  event.target.value,
                )
              }
              placeholder="Search name, symbol or mint"
              className="w-full rounded-lg border border-white/10 bg-black/30 py-2.5 pl-9 pr-3 text-sm text-white outline-none placeholder:text-zinc-700 focus:border-emerald-400/30"
            />
          </div>

          <div className="flex items-center gap-2 rounded-lg border border-white/10 bg-black/20 px-3 py-2">
            <Filter className="h-3.5 w-3.5 text-zinc-600" />

            <select
              value={minLiquidity}
              onChange={(event) =>
                setMinLiquidity(
                  Number(
                    event.target.value,
                  ),
                )
              }
              className="bg-transparent text-xs text-zinc-300 outline-none"
            >
              <option value={0}>
                Any liquidity
              </option>
              <option value={5000}>
                Liq â‰¥ $5K
              </option>
              <option value={20000}>
                Liq â‰¥ $20K
              </option>
              <option value={50000}>
                Liq â‰¥ $50K
              </option>
              <option value={100000}>
                Liq â‰¥ $100K
              </option>
            </select>
          </div>

          <div className="flex items-center gap-2 rounded-lg border border-white/10 bg-black/20 px-3 py-2">
            <SlidersHorizontal className="h-3.5 w-3.5 text-zinc-600" />

            <select
              value={maxAgeHours}
              onChange={(event) =>
                setMaxAgeHours(
                  Number(
                    event.target.value,
                  ),
                )
              }
              className="bg-transparent text-xs text-zinc-300 outline-none"
            >
              <option value={0}>
                Any age
              </option>
              <option value={1}>
                Age â‰¤ 1h
              </option>
              <option value={6}>
                Age â‰¤ 6h
              </option>
              <option value={24}>
                Age â‰¤ 24h
              </option>
              <option value={168}>
                Age â‰¤ 7d
              </option>
            </select>
          </div>
        </div>

        <div className="mt-3 flex gap-1 overflow-x-auto">
          {tabs.map((item) => (
            <button
              key={item.id}
              onClick={() =>
                setTab(item.id)
              }
              className={`whitespace-nowrap rounded-lg px-3 py-2 text-xs transition ${
                tab === item.id
                  ? "bg-white text-black"
                  : "text-zinc-500 hover:bg-white/5 hover:text-zinc-200"
              }`}
            >
              {item.label}
            </button>
          ))}
        </div>
      </section>

      {error && (
        <div className="mb-3 rounded-xl border border-red-400/20 bg-red-400/[0.05] p-3 text-sm text-red-200">
          {error}
        </div>
      )}

      <section className="overflow-hidden rounded-xl border border-white/10 bg-[#090b0f]">
        <div className="overflow-x-auto">
          <table className="w-full min-w-[1720px] border-collapse text-left">
            <thead className="sticky top-0 z-10 bg-[#0d1015] text-[10px] uppercase tracking-[0.12em] text-zinc-600">
              <tr>
                <th className="px-4 py-3">
                  Token
                </th>
                <th className="px-3 py-3">
                  Age
                </th>
                <th className="px-3 py-3">
                  Price
                </th>
                <th className="px-3 py-3">
                  5m
                </th>
                <th className="px-3 py-3">
                  1h
                </th>
                <th className="px-3 py-3">
                  6h
                </th>
                <th className="px-3 py-3">
                  24h
                </th>
                <th className="px-3 py-3">
                  Txns 5m
                </th>
                <th className="px-3 py-3">
                  Vol 5m
                </th>
                <th className="px-3 py-3">
                  Vol 1h
                </th>
                <th className="px-3 py-3">
                  Liquidity
                </th>
                <th className="px-3 py-3">
                  Market Cap
                </th>
                <th className="px-3 py-3">
                  FDV
                </th>
                <th className="px-3 py-3">
                  Spike
                </th>
                <th className="px-3 py-3">
                  Score
                </th>
                <th className="px-3 py-3">
                  DEX
                </th>
                <th className="px-3 py-3">
                  Action
                </th>
              </tr>
            </thead>

            <tbody>
              {filtered.map(
                (token, index) => (
                  <tr
                    key={token.address}
                    className="border-t border-white/[0.055] text-xs transition hover:bg-white/[0.025]"
                  >
                    <td className="px-4 py-3">
                      <div className="flex items-center gap-3">
                        <span className="w-5 text-[10px] text-zinc-700">
                          {index + 1}
                        </span>
                        <TokenIdentity
                          token={token}
                        />
                      </div>
                    </td>

                    <td className="px-3 py-3 text-zinc-400">
                      {age(
                        token.pairAgeMinutes,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono text-zinc-200">
                      {price(
                        token.priceUsd,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.m5,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.h1,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.h6,
                      )}
                    </td>

                    <td className="px-3 py-3 font-mono">
                      {percent(
                        token.priceChange.h24,
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span className="text-emerald-300">
                        {
                          token.txns.m5
                            .buys
                        }
                      </span>
                      <span className="mx-1 text-zinc-700">
                        /
                      </span>
                      <span className="text-red-300">
                        {
                          token.txns.m5
                            .sells
                        }
                      </span>
                    </td>

                    <td className="px-3 py-3 text-zinc-300">
                      {money(
                        token.volume.m5,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-400">
                      {money(
                        token.volume.h1,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-200">
                      {money(
                        token.liquidityUsd,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-300">
                      {money(
                        token.marketCap,
                      )}
                    </td>

                    <td className="px-3 py-3 text-zinc-500">
                      {money(token.fdv)}
                    </td>

                    <td className="px-3 py-3">
                      {token.volumeSpike5m !==
                      null ? (
                        <span
                          className={
                            token.volumeSpike5m >=
                            2
                              ? "text-amber-300"
                              : "text-zinc-400"
                          }
                        >
                          {token.volumeSpike5m.toFixed(
                            2,
                          )}
                          x
                        </span>
                      ) : (
                        "â€”"
                      )}
                    </td>

                    <td className="px-3 py-3">
                      <span
                        className={`font-semibold ${
                          token.activityScore >=
                          70
                            ? "text-emerald-300"
                            : token.activityScore >=
                                45
                              ? "text-amber-300"
                              : "text-zinc-400"
                        }`}
                      >
                        {
                          token.activityScore
                        }
                      </span>
                    </td>

                    <td className="px-3 py-3 text-zinc-500">
                      {token.dexId}
                    </td>

                    <td className="px-3 py-3">
                      <div className="flex items-center gap-2">
                        <Link
                          href={`/token/${token.address}`}
                          className="rounded-lg border border-emerald-400/15 bg-emerald-400/[0.06] px-2.5 py-1.5 text-[11px] text-emerald-300 hover:bg-emerald-400/10"
                        >
                          Analyze
                        </Link>

                        {token.dexUrl && (
                          <a
                            href={
                              token.dexUrl
                            }
                            target="_blank"
                            rel="noreferrer"
                            className="rounded-lg border border-white/10 p-1.5 text-zinc-500 hover:text-white"
                          >
                            <ExternalLink className="h-3.5 w-3.5" />
                          </a>
                        )}
                      </div>
                    </td>
                  </tr>
                ),
              )}
            </tbody>
          </table>
        </div>

        {!loading &&
          filtered.length === 0 && (
            <div className="p-10 text-center text-sm text-zinc-600">
              No tokens match the current
              filters.
            </div>
          )}

        {loading && !data && (
          <div className="flex items-center justify-center gap-2 p-12 text-sm text-zinc-500">
            <RefreshCw className="h-4 w-4 animate-spin" />
            Loading terminal dataâ€¦
          </div>
        )}
      </section>

      <div className="mt-3 flex flex-wrap justify-between gap-2 text-[10px] text-zinc-700">
        <span>
          Showing {filtered.length} of{" "}
          {data?.tokenCount ?? 0} loaded
          Solana tokens
        </span>

        <span>
          Activity Score is a ranking
          heuristic, not a probability or
          trade recommendation.
        </span>
      </div>
    </main>
  );
}