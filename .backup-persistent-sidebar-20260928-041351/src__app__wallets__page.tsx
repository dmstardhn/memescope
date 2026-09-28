"use client";

import { AppShell } from "@/components/app-shell";
import type { WalletReport } from "@/lib/wallet-types";
import {
  Activity,
  ArrowDownRight,
  ArrowUpRight,
  Copy,
  ExternalLink,
  Plus,
  Radio,
  RefreshCw,
  Search,
  Trash2,
  WalletCards,
  Waves,
  Wifi,
  WifiOff,
} from "lucide-react";
import {
  FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { useSearchParams } from "next/navigation";

const STORAGE_KEY = "memescope-tracked-wallets";
const FALLBACK_REFRESH_MS = 5_000;

function short(address: string) {
  if (address.length < 16) return address;
  return `${address.slice(0, 7)}â€¦${address.slice(-7)}`;
}

function money(value: number) {
  if (!Number.isFinite(value)) return "$0";
  if (value >= 1_000_000)
    return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000)
    return `$${(value / 1_000).toFixed(1)}K`;
  if (value >= 1)
    return `$${value.toFixed(2)}`;
  return `$${value.toPrecision(4)}`;
}

function amount(value: number) {
  return new Intl.NumberFormat("en-US", {
    notation: "compact",
    maximumFractionDigits: 2,
  }).format(value);
}

function time(blockTime: number | null) {
  if (!blockTime) return "â€”";
  return new Date(
    blockTime * 1000,
  ).toLocaleString();
}

export default function WalletsPage() {
  const searchParams = useSearchParams();
  const initial =
    searchParams.get("address") || "";

  const [input, setInput] = useState(initial);
  const [selected, setSelected] =
    useState(initial);
  const [tracked, setTracked] = useState<
    string[]
  >([]);
  const [report, setReport] =
    useState<WalletReport | null>(null);
  const [loading, setLoading] =
    useState(false);
  const [error, setError] = useState("");
  const [streamState, setStreamState] =
    useState<
      "idle" | "connecting" | "live" | "degraded"
    >("idle");
  const [lastEventAt, setLastEventAt] =
    useState<number | null>(null);
  const [liveSignature, setLiveSignature] =
    useState<string | null>(null);

  const fetching = useRef(false);
  const refreshTimers = useRef<number[]>([]);

  useEffect(() => {
    try {
      const parsed = JSON.parse(
        localStorage.getItem(STORAGE_KEY) ||
          "[]",
      );
      if (Array.isArray(parsed)) {
        setTracked(parsed);
      }
    } catch {
      setTracked([]);
    }
  }, []);

  const load = useCallback(
    async (
      address: string,
      forceFresh = false,
      silent = false,
    ) => {
      if (!address || fetching.current) return;

      fetching.current = true;

      if (!silent && !report) {
        setLoading(true);
      }

      try {
        const suffix = forceFresh
          ? `?fresh=1&t=${Date.now()}`
          : `?t=${Date.now()}`;

        const response = await fetch(
          `/api/wallet/solana/${encodeURIComponent(
            address,
          )}${suffix}`,
          { cache: "no-store" },
        );

        const data = await response.json();

        if (!response.ok || !data.ok) {
          throw new Error(
            data.error || "Wallet analysis failed.",
          );
        }

        setReport(data as WalletReport);
        setError("");
      } catch (err) {
        setError(
          err instanceof Error
            ? err.message
            : "Wallet analysis failed.",
        );
      } finally {
        setLoading(false);
        fetching.current = false;
      }
    },
    [report],
  );

  useEffect(() => {
    if (!selected) {
      setStreamState("idle");
      return;
    }

    setReport(null);
    setLoading(true);
    setStreamState("connecting");
    setLiveSignature(null);
    setLastEventAt(null);

    load(selected, true);

    const fallback = window.setInterval(() => {
      load(selected, false, true);
    }, FALLBACK_REFRESH_MS);

    const source = new EventSource(
      `/api/wallet/stream/${encodeURIComponent(
        selected,
      )}`,
    );

    source.addEventListener("status", (event) => {
      try {
        const payload = JSON.parse(
          (event as MessageEvent).data,
        ) as { state?: string };

        if (payload.state === "live") {
          setStreamState("live");
        } else if (
          payload.state === "degraded" ||
          payload.state === "closed"
        ) {
          setStreamState("degraded");
        } else {
          setStreamState("connecting");
        }
      } catch {
        setStreamState("degraded");
      }
    });

    source.addEventListener("wallet", (event) => {
      try {
        const payload = JSON.parse(
          (event as MessageEvent).data,
        ) as {
          receivedAt?: number;
          signature?: string | null;
        };

        setLastEventAt(
          payload.receivedAt || Date.now(),
        );
        setLiveSignature(
          payload.signature || null,
        );

        // Immediate refresh, then two short follow-ups.
        // The first update reacts to the processed event;
        // follow-ups catch confirmed balance/index changes.
        load(selected, true, true);

        refreshTimers.current.forEach(
          (timer) => window.clearTimeout(timer),
        );

        refreshTimers.current = [
          window.setTimeout(
            () => load(selected, true, true),
            500,
          ),
          window.setTimeout(
            () => load(selected, true, true),
            1_500,
          ),
        ];
      } catch {
        // Ignore malformed event.
      }
    });

    source.onerror = () => {
      setStreamState("degraded");
    };

    return () => {
      source.close();
      window.clearInterval(fallback);
      refreshTimers.current.forEach(
        (timer) => window.clearTimeout(timer),
      );
      refreshTimers.current = [];
    };
  }, [selected, load]);

  const visibleHoldings = useMemo(
    () => report?.holdings || [],
    [report],
  );

  function persist(next: string[]) {
    setTracked(next);
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(next),
    );
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    const value = input.trim();

    if (
      !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
        value,
      )
    ) {
      setError("Invalid Solana wallet address.");
      return;
    }

    setError("");
    setSelected(value);
  }

  function addTracked() {
    if (!selected) return;
    if (tracked.includes(selected)) return;
    persist([selected, ...tracked].slice(0, 20));
  }

  function removeTracked(address: string) {
    persist(
      tracked.filter((item) => item !== address),
    );
  }

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <div className="flex items-center gap-2 text-sm text-emerald-300">
              <WalletCards className="h-4 w-4" />
              Solana Wallet Intelligence
            </div>
            <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
              Wallet & Whale Tracker
            </h1>
            <p className="mt-1 max-w-2xl text-sm text-zinc-500">
              Event-driven wallet monitoring with Solana
              WebSocket notifications and fast market
              refresh.
            </p>
          </div>

          <div
            className={`inline-flex items-center gap-2 rounded-full border px-3 py-2 text-xs ${
              streamState === "live"
                ? "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"
                : streamState === "degraded"
                  ? "border-amber-400/20 bg-amber-400/10 text-amber-300"
                  : "border-white/8 text-zinc-500"
            }`}
          >
            {streamState === "live" ? (
              <Wifi className="h-3.5 w-3.5" />
            ) : streamState === "degraded" ? (
              <WifiOff className="h-3.5 w-3.5" />
            ) : (
              <Radio className="h-3.5 w-3.5" />
            )}
            {streamState === "live"
              ? "Live WebSocket"
              : streamState === "degraded"
                ? "Fallback refresh"
                : streamState === "connecting"
                  ? "Connecting"
                  : "No wallet selected"}
          </div>
        </div>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        <section className="grid gap-4 xl:grid-cols-[.7fr_1.3fr]">
          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-4">
            <form
              onSubmit={submit}
              className="flex gap-2"
            >
              <div className="relative min-w-0 flex-1">
                <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />
                <input
                  value={input}
                  onChange={(event) =>
                    setInput(event.target.value)
                  }
                  placeholder="Paste Solana wallet address"
                  className="h-10 w-full rounded-xl border border-white/8 bg-black/20 pl-10 pr-3 text-sm outline-none placeholder:text-zinc-700 focus:border-emerald-400/40"
                />
              </div>
              <button className="rounded-xl bg-white px-4 text-sm font-medium text-black">
                Inspect
              </button>
            </form>

            <div className="mt-5 flex items-center justify-between">
              <div>
                <div className="text-sm font-medium text-white">
                  Tracked wallets
                </div>
                <div className="text-xs text-zinc-600">
                  Saved locally in this browser
                </div>
              </div>

              {selected ? (
                <button
                  onClick={addTracked}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-white/8 px-2.5 py-1.5 text-xs text-zinc-400 hover:text-white"
                >
                  <Plus className="h-3.5 w-3.5" />
                  Track
                </button>
              ) : null}
            </div>

            <div className="mt-3 space-y-2">
              {tracked.length ? (
                tracked.map((address) => (
                  <div
                    key={address}
                    className={`flex items-center justify-between gap-2 rounded-xl border p-3 ${
                      address === selected
                        ? "border-emerald-400/20 bg-emerald-400/5"
                        : "border-white/5 bg-black/15"
                    }`}
                  >
                    <button
                      onClick={() => {
                        setInput(address);
                        setSelected(address);
                      }}
                      className="min-w-0 flex-1 truncate text-left font-mono text-xs text-zinc-400 hover:text-white"
                    >
                      {short(address)}
                    </button>

                    <button
                      onClick={() =>
                        removeTracked(address)
                      }
                      className="text-zinc-700 hover:text-rose-300"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>
                ))
              ) : (
                <div className="rounded-xl border border-white/5 bg-black/15 p-4 text-xs leading-5 text-zinc-600">
                  Inspect a wallet, then click Track to
                  keep it here.
                </div>
              )}
            </div>
          </div>

          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
            {!selected ? (
              <div className="grid min-h-48 place-items-center text-center">
                <div>
                  <Waves className="mx-auto h-7 w-7 text-zinc-700" />
                  <div className="mt-3 text-sm text-zinc-500">
                    Enter a Solana wallet to begin.
                  </div>
                </div>
              </div>
            ) : loading && !report ? (
              <div className="grid min-h-48 place-items-center text-center">
                <div>
                  <RefreshCw className="mx-auto h-6 w-6 animate-spin text-emerald-300" />
                  <div className="mt-3 text-sm text-zinc-500">
                    Reading wallet activityâ€¦
                  </div>
                </div>
              </div>
            ) : report ? (
              <>
                <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                  <div className="min-w-0">
                    <div className="text-xs uppercase tracking-[0.12em] text-zinc-600">
                      Wallet
                    </div>
                    <button
                      onClick={() =>
                        navigator.clipboard.writeText(
                          report.address,
                        )
                      }
                      className="mt-1 inline-flex max-w-full items-center gap-2 font-mono text-sm text-zinc-300 hover:text-white"
                    >
                      <span className="truncate">
                        {short(report.address)}
                      </span>
                      <Copy className="h-3.5 w-3.5 shrink-0" />
                    </button>
                  </div>

                  <div className="text-right">
                    <div className="rounded-full border border-white/8 px-3 py-1.5 text-xs text-zinc-400">
                      {report.positionTier} visible position
                    </div>
                    {lastEventAt ? (
                      <div className="mt-2 text-[11px] text-emerald-300">
                        live tx detected{" "}
                        {new Date(
                          lastEventAt,
                        ).toLocaleTimeString()}
                      </div>
                    ) : null}
                  </div>
                </div>

                {liveSignature ? (
                  <div className="mt-4 rounded-xl border border-emerald-400/15 bg-emerald-400/5 px-3 py-2 text-xs text-emerald-200/70">
                    Latest live signature:{" "}
                    <span className="font-mono">
                      {short(liveSignature)}
                    </span>
                  </div>
                ) : null}

                <div className="mt-6 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                  {[
                    [
                      "SOL balance",
                      `${report.solBalance.toFixed(
                        3,
                      )} SOL`,
                    ],
                    [
                      "Visible token value",
                      money(
                        report.visibleTokenValueUsd,
                      ),
                    ],
                    [
                      "Activity score",
                      `${report.activityScore}/100`,
                    ],
                    [
                      "Recent signatures",
                      String(
                        report.recentSignatureCount,
                      ),
                    ],
                  ].map(([label, value]) => (
                    <div
                      key={label}
                      className="rounded-xl border border-white/8 bg-black/20 p-3"
                    >
                      <div className="text-xs text-zinc-600">
                        {label}
                      </div>
                      <div className="mt-1 text-lg font-medium text-white">
                        {value}
                      </div>
                    </div>
                  ))}
                </div>
              </>
            ) : (
              <div className="grid min-h-48 place-items-center text-sm text-zinc-600">
                No wallet report.
              </div>
            )}
          </div>
        </section>

        {error ? (
          <div className="rounded-2xl border border-rose-400/15 bg-rose-400/5 p-4 text-sm text-rose-200">
            {error}
          </div>
        ) : null}

        {report ? (
          <>
            <section className="grid gap-4 xl:grid-cols-[1fr_1fr]">
              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="flex items-center gap-2">
                  <WalletCards className="h-4 w-4 text-zinc-400" />
                  <h2 className="font-medium text-white">
                    Visible holdings
                  </h2>
                </div>

                <div className="mt-4 space-y-2">
                  {visibleHoldings.length ? (
                    visibleHoldings.map(
                      (holding) => (
                        <div
                          key={holding.mint}
                          className="grid grid-cols-[1fr_auto] gap-3 rounded-xl border border-white/5 bg-black/15 p-3"
                        >
                          <div className="min-w-0">
                            <div className="font-medium text-zinc-200">
                              {holding.symbol
                                ? `$${holding.symbol}`
                                : short(
                                    holding.mint,
                                  )}
                            </div>
                            <div className="mt-1 truncate text-xs text-zinc-600">
                              {holding.name ||
                                holding.mint}
                            </div>
                            <div className="mt-2 text-xs text-zinc-500">
                              {amount(
                                holding.amount,
                              )}{" "}
                              tokens
                            </div>
                          </div>

                          <div className="text-right">
                            <div className="font-medium text-white">
                              {money(
                                holding.valueUsd,
                              )}
                            </div>
                            <div className="mt-1 text-xs text-zinc-600">
                              MC{" "}
                              {money(
                                holding.marketCap,
                              )}
                            </div>
                            {holding.dexUrl ? (
                              <a
                                href={
                                  holding.dexUrl
                                }
                                target="_blank"
                                rel="noreferrer"
                                className="mt-2 inline-flex items-center gap-1 text-xs text-emerald-300"
                              >
                                DEX
                                <ExternalLink className="h-3 w-3" />
                              </a>
                            ) : null}
                          </div>
                        </div>
                      ),
                    )
                  ) : (
                    <div className="rounded-xl border border-white/5 p-4 text-xs text-zinc-600">
                      No priced SPL holdings were found.
                    </div>
                  )}
                </div>
              </div>

              <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
                <div className="flex items-center gap-2">
                  <Activity className="h-4 w-4 text-zinc-400" />
                  <h2 className="font-medium text-white">
                    Recent token activity
                  </h2>
                </div>

                <div className="mt-4 space-y-2">
                  {report.recentActivity.length ? (
                    report.recentActivity.map(
                      (activity, index) => (
                        <div
                          key={`${activity.signature}-${index}`}
                          className="rounded-xl border border-white/5 bg-black/15 p-3"
                        >
                          <div className="flex items-start justify-between gap-3">
                            <div className="flex min-w-0 gap-2">
                              {activity.direction ===
                              "acquired" ? (
                                <ArrowDownRight className="mt-0.5 h-4 w-4 shrink-0 text-emerald-300" />
                              ) : activity.direction ===
                                "disposed" ? (
                                <ArrowUpRight className="mt-0.5 h-4 w-4 shrink-0 text-rose-300" />
                              ) : (
                                <Activity className="mt-0.5 h-4 w-4 shrink-0 text-zinc-600" />
                              )}

                              <div className="min-w-0">
                                <div className="text-sm text-zinc-300">
                                  {activity.direction ===
                                  "acquired"
                                    ? "Token balance increased"
                                    : activity.direction ===
                                        "disposed"
                                      ? "Token balance decreased"
                                      : "Wallet transaction"}
                                </div>

                                <div className="mt-1 truncate font-mono text-xs text-zinc-600">
                                  {activity.mint ||
                                    activity.signature}
                                </div>
                              </div>
                            </div>

                            {activity.mint ? (
                              <div className="shrink-0 text-right">
                                <div
                                  className={`text-sm ${
                                    activity.delta >= 0
                                      ? "text-emerald-300"
                                      : "text-rose-300"
                                  }`}
                                >
                                  {activity.delta >=
                                  0
                                    ? "+"
                                    : ""}
                                  {amount(
                                    activity.delta,
                                  )}
                                </div>
                                <div className="mt-1 text-xs text-zinc-600">
                                  current â‰ˆ{" "}
                                  {money(
                                    activity.currentDeltaValueUsd,
                                  )}
                                </div>
                              </div>
                            ) : null}
                          </div>

                          <div className="mt-2 text-[11px] text-zinc-700">
                            {time(
                              activity.blockTime,
                            )}
                          </div>
                        </div>
                      ),
                    )
                  ) : (
                    <div className="rounded-xl border border-white/5 p-4 text-xs text-zinc-600">
                      Recent token balance changes were not
                      available from the inspected transactions.
                    </div>
                  )}
                </div>
              </div>
            </section>

            <section className="rounded-2xl border border-white/8 bg-white/[0.025] p-5">
              <h2 className="font-medium text-white">
                Live update mode
              </h2>
              <p className="mt-2 text-xs leading-5 text-zinc-600">
                The page listens to Solana transaction log
                notifications for the selected wallet. When a
                transaction is detected, the wallet report is
                refreshed immediately, then checked again
                shortly afterward as indexed/confirmed state
                catches up. A 5-second refresh remains only as
                fallback.
              </p>
              <div className="mt-4 text-xs text-zinc-700">
                RPC: {report.rpcSource} Â· report updated{" "}
                {new Date(
                  report.updatedAt,
                ).toLocaleTimeString()}
              </div>
            </section>
          </>
        ) : null}
      </div>
    </AppShell>
  );
}
