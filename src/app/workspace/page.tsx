"use client";

import Link from "next/link";
import {
  Activity,
  Bell,
  Bookmark,
  ChevronRight,
  LayoutDashboard,
  RefreshCw,
  Search,
  Settings2,
  Signal,
  Sparkles,
  Users,
  WalletCards,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

import {
  generateSignals,
} from "@/lib/signal-engine";
import type {
  SignalCall,
} from "@/lib/signal-types";
import type {
  SmartMoneyResponse,
} from "@/lib/smart-money-types";
import type {
  TerminalResponse,
  TerminalToken,
} from "@/lib/terminal-types";

const WORKSPACE_KEY =
  "memescope-workspace-v1";

const TOKEN_WATCHLIST_KEY =
  "memescope-token-watchlist";

const SMART_WALLET_KEY =
  "memescope-smart-money-wallets";

type WidgetKey =
  | "overview"
  | "signals"
  | "watchlist"
  | "smart-money"
  | "quick-links";

type WorkspaceConfig = {
  name: string;
  widgets: WidgetKey[];
  minSignalScore: number;
};

const DEFAULT_CONFIG: WorkspaceConfig = {
  name: "My Workspace",
  widgets: [
    "overview",
    "signals",
    "watchlist",
    "smart-money",
    "quick-links",
  ],
  minSignalScore: 55,
};

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

  if (value >= 1_000_000_000) {
    return `$${(
      value / 1_000_000_000
    ).toFixed(2)}B`;
  }

  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(1)}K`;
  }

  if (value >= 1) {
    return `$${value.toFixed(2)}`;
  }

  return `$${value.toPrecision(4)}`;
}

function short(value: string) {
  if (value.length <= 12) {
    return value;
  }

  return `${value.slice(0, 5)}...${value.slice(-4)}`;
}

function WidgetShell({
  title,
  subtitle,
  action,
  children,
}: {
  title: string;
  subtitle?: string;
  action?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-2xl border border-white/10 bg-white/[0.025]">
      <div className="flex items-start justify-between gap-4 border-b border-white/5 px-5 py-4">
        <div>
          <h2 className="text-sm font-semibold text-white">
            {title}
          </h2>

          {subtitle && (
            <p className="mt-1 text-xs text-zinc-600">
              {subtitle}
            </p>
          )}
        </div>

        {action}
      </div>

      <div className="p-5">
        {children}
      </div>
    </section>
  );
}

export default function WorkspacePage() {
  const [config, setConfig] =
    useState<WorkspaceConfig>(
      DEFAULT_CONFIG,
    );

  const [terminal, setTerminal] =
    useState<TerminalResponse | null>(
      null,
    );

  const [smartMoney, setSmartMoney] =
    useState<SmartMoneyResponse | null>(
      null,
    );

  const [watchlistAddresses, setWatchlistAddresses] =
    useState<string[]>([]);

  const [trackedWallets, setTrackedWallets] =
    useState<string[]>([]);

  const [loading, setLoading] =
    useState(true);

  const [error, setError] =
    useState("");

  const [editing, setEditing] =
    useState(false);

  useEffect(() => {
    try {
      const rawConfig =
        localStorage.getItem(
          WORKSPACE_KEY,
        );

      if (rawConfig) {
        setConfig({
          ...DEFAULT_CONFIG,
          ...(JSON.parse(
            rawConfig,
          ) as Partial<WorkspaceConfig>),
        });
      }
    } catch {
      // Keep defaults.
    }

    try {
      const rawWatchlist =
        localStorage.getItem(
          TOKEN_WATCHLIST_KEY,
        );

      if (rawWatchlist) {
        const parsed = JSON.parse(
          rawWatchlist,
        ) as unknown;

        if (Array.isArray(parsed)) {
          setWatchlistAddresses(
            parsed.filter(
              (item): item is string =>
                typeof item === "string",
            ),
          );
        }
      }
    } catch {
      // Ignore malformed watchlist.
    }

    try {
      const rawWallets =
        localStorage.getItem(
          SMART_WALLET_KEY,
        );

      if (rawWallets) {
        const parsed = JSON.parse(
          rawWallets,
        ) as unknown;

        if (Array.isArray(parsed)) {
          setTrackedWallets(
            parsed.filter(
              (item): item is string =>
                typeof item === "string",
            ),
          );
        }
      }
    } catch {
      // Ignore malformed wallets.
    }
  }, []);

  useEffect(() => {
    localStorage.setItem(
      WORKSPACE_KEY,
      JSON.stringify(config),
    );
  }, [config]);

  async function loadTerminal() {
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
          : "Terminal data failed.",
      );
    }

    setTerminal(
      result as TerminalResponse,
    );
  }

  async function loadSmartMoney(
    wallets: string[],
  ) {
    if (wallets.length === 0) {
      setSmartMoney(null);
      return;
    }

    const response = await fetch(
      "/api/smart-money/solana",
      {
        method: "POST",
        headers: {
          "Content-Type":
            "application/json",
        },
        body: JSON.stringify({
          wallets,
          windowMinutes: 30,
          signatureLimit: 6,
        }),
      },
    );

    const result =
      (await response.json()) as
        | SmartMoneyResponse
        | { error?: string };

    if (!response.ok) {
      throw new Error(
        "error" in result
          ? result.error
          : "Smart Money data failed.",
      );
    }

    setSmartMoney(
      result as SmartMoneyResponse,
    );
  }

  async function refresh() {
    setLoading(true);
    setError("");

    try {
      await loadTerminal();

      try {
        await loadSmartMoney(
          trackedWallets,
        );
      } catch (smartError) {
        console.warn(
          "Smart Money widget:",
          smartError,
        );
      }
    } catch (loadError) {
      setError(
        loadError instanceof Error
          ? loadError.message
          : "Workspace refresh failed.",
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void refresh();

    const timer = window.setInterval(
      () => {
        void loadTerminal();
      },
      20_000,
    );

    return () =>
      window.clearInterval(timer);
  }, [trackedWallets]);

  const signals = useMemo(() => {
    return generateSignals(
      terminal?.tokens ?? [],
    ).filter(
      (signal) =>
        signal.direction === "watch" &&
        signal.signalScore >=
          config.minSignalScore,
    );
  }, [
    terminal,
    config.minSignalScore,
  ]);

  const watchlistTokens =
    useMemo(() => {
      const addresses =
        new Set(
          watchlistAddresses,
        );

      return (
        terminal?.tokens.filter(
          (token) =>
            addresses.has(
              token.address,
            ),
        ) ?? []
      );
    }, [
      terminal,
      watchlistAddresses,
    ]);

  const topMover =
    terminal?.tokens
      .filter(
        (token) =>
          token.priceChange.m5 !==
          null,
      )
      .sort(
        (a, b) =>
          (b.priceChange.m5 ?? 0) -
          (a.priceChange.m5 ?? 0),
      )[0] ?? null;

  const volumeLeader =
    terminal?.tokens
      .slice()
      .sort(
        (a, b) =>
          b.volume.m5 -
          a.volume.m5,
      )[0] ?? null;

  const clusters =
    smartMoney?.signals.filter(
      (item) =>
        item.walletCount >= 2,
    ) ?? [];

  function widgetEnabled(
    widget: WidgetKey,
  ) {
    return config.widgets.includes(
      widget,
    );
  }

  function toggleWidget(
    widget: WidgetKey,
  ) {
    setConfig((current) => ({
      ...current,
      widgets:
        current.widgets.includes(
          widget,
        )
          ? current.widgets.filter(
              (item) =>
                item !== widget,
            )
          : [
              ...current.widgets,
              widget,
            ],
    }));
  }

  return (
    <main className="mx-auto w-full max-w-[1700px] px-4 py-6 lg:px-7">
      <header className="mb-6 flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2 text-[10px] uppercase tracking-[0.2em] text-emerald-300">
            <LayoutDashboard className="h-3.5 w-3.5" />
            Personal terminal
          </div>

          <div className="mt-2 flex flex-wrap items-center gap-3">
            <h1 className="text-3xl font-semibold tracking-tight text-white">
              {config.name}
            </h1>

            <button
              type="button"
              onClick={() =>
                setEditing(
                  (current) => !current,
                )
              }
              className="rounded-lg border border-white/10 p-2 text-zinc-500 hover:bg-white/5 hover:text-white"
              aria-label="Workspace settings"
            >
              <Settings2 className="h-4 w-4" />
            </button>
          </div>

          <p className="mt-2 max-w-2xl text-sm leading-6 text-zinc-500">
            Your watchlist, signals, tracked wallets and market shortcuts in one dashboard.
          </p>
        </div>

        <button
          type="button"
          onClick={() =>
            void refresh()
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
      </header>

      {editing && (
        <section className="mb-5 rounded-2xl border border-emerald-400/15 bg-emerald-400/[0.025] p-5">
          <div className="grid gap-5 xl:grid-cols-[1fr_auto]">
            <div>
              <label className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
                Workspace name
              </label>

              <input
                value={config.name}
                onChange={(event) =>
                  setConfig(
                    (current) => ({
                      ...current,
                      name:
                        event.target.value,
                    }),
                  )
                }
                className="mt-2 w-full max-w-md rounded-xl border border-white/10 bg-black/25 px-3 py-2.5 text-sm text-white outline-none focus:border-emerald-400/30"
              />
            </div>

            <div>
              <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
                Minimum signal score
              </div>

              <div className="mt-2 flex flex-wrap gap-2">
                {[45, 55, 65, 75].map(
                  (score) => (
                    <button
                      key={score}
                      type="button"
                      onClick={() =>
                        setConfig(
                          (current) => ({
                            ...current,
                            minSignalScore:
                              score,
                          }),
                        )
                      }
                      className={`rounded-lg border px-3 py-2 text-xs ${
                        config.minSignalScore ===
                        score
                          ? "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"
                          : "border-white/10 text-zinc-500"
                      }`}
                    >
                      {score}+
                    </button>
                  ),
                )}
              </div>
            </div>
          </div>

          <div className="mt-5">
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              Visible widgets
            </div>

            <div className="mt-2 flex flex-wrap gap-2">
              {(
                [
                  [
                    "overview",
                    "Market Overview",
                  ],
                  [
                    "signals",
                    "Signals",
                  ],
                  [
                    "watchlist",
                    "Watchlist",
                  ],
                  [
                    "smart-money",
                    "Smart Money",
                  ],
                  [
                    "quick-links",
                    "Quick Links",
                  ],
                ] as Array<
                  [WidgetKey, string]
                >
              ).map(
                ([key, label]) => (
                  <button
                    key={key}
                    type="button"
                    onClick={() =>
                      toggleWidget(
                        key,
                      )
                    }
                    className={`rounded-lg border px-3 py-2 text-xs ${
                      widgetEnabled(key)
                        ? "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"
                        : "border-white/10 text-zinc-600"
                    }`}
                  >
                    {label}
                  </button>
                ),
              )}
            </div>
          </div>
        </section>
      )}

      {error && (
        <div className="mb-5 rounded-xl border border-red-400/20 bg-red-400/[0.05] p-3 text-sm text-red-200">
          {error}
        </div>
      )}

      {widgetEnabled(
        "overview",
      ) && (
        <section className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
          <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              Tokens loaded
            </div>
            <div className="mt-1 text-2xl font-semibold text-white">
              {terminal?.tokenCount ??
                "N/A"}
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              Active signals
            </div>
            <div className="mt-1 text-2xl font-semibold text-emerald-300">
              {signals.length}
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              Watchlist
            </div>
            <div className="mt-1 text-2xl font-semibold text-white">
              {
                watchlistAddresses.length
              }
            </div>
          </div>

          <div className="rounded-2xl border border-white/10 bg-white/[0.025] p-4">
            <div className="text-[10px] uppercase tracking-[0.15em] text-zinc-600">
              Tracked wallets
            </div>
            <div className="mt-1 text-2xl font-semibold text-white">
              {trackedWallets.length}
            </div>
          </div>
        </section>
      )}

      <div className="grid gap-5 xl:grid-cols-2">
        {widgetEnabled(
          "signals",
        ) && (
          <WidgetShell
            title="Signal Calls"
            subtitle={`Score ${config.minSignalScore}+`}
            action={
              <Link
                href="/signals"
                className="flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
              >
                Open
                <ChevronRight className="h-3.5 w-3.5" />
              </Link>
            }
          >
            {signals.length > 0 ? (
              <div className="space-y-2">
                {signals
                  .slice(0, 5)
                  .map(
                    (
                      signal: SignalCall,
                    ) => (
                      <Link
                        key={signal.id}
                        href={`/token/${signal.tokenAddress}`}
                        className="flex items-center justify-between gap-4 rounded-xl border border-white/5 bg-black/20 px-3 py-3 hover:bg-white/[0.025]"
                      >
                        <div className="min-w-0">
                          <div className="flex items-center gap-2">
                            <Signal className="h-3.5 w-3.5 text-emerald-300" />
                            <span className="font-medium text-white">
                              {signal.symbol}
                            </span>
                          </div>

                          <div className="mt-1 truncate text-[11px] text-zinc-600">
                            {signal.label}
                          </div>
                        </div>

                        <div className="text-xl font-semibold text-emerald-300">
                          {
                            signal.signalScore
                          }
                        </div>
                      </Link>
                    ),
                  )}
              </div>
            ) : (
              <div className="py-8 text-center text-sm text-zinc-600">
                No current signals meet your threshold.
              </div>
            )}
          </WidgetShell>
        )}

        {widgetEnabled(
          "watchlist",
        ) && (
          <WidgetShell
            title="Watchlist"
            subtitle={`${watchlistAddresses.length} saved tokens`}
            action={
              <Link
                href="/watchlist"
                className="flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
              >
                Open
                <ChevronRight className="h-3.5 w-3.5" />
              </Link>
            }
          >
            {watchlistTokens.length > 0 ? (
              <div className="space-y-2">
                {watchlistTokens
                  .slice(0, 5)
                  .map(
                    (
                      token: TerminalToken,
                    ) => (
                      <Link
                        key={token.address}
                        href={`/token/${token.address}`}
                        className="grid grid-cols-[1fr_auto_auto] items-center gap-4 rounded-xl border border-white/5 bg-black/20 px-3 py-3 hover:bg-white/[0.025]"
                      >
                        <div>
                          <div className="font-medium text-white">
                            {token.symbol}
                          </div>

                          <div className="mt-1 text-[10px] text-zinc-700">
                            {short(
                              token.address,
                            )}
                          </div>
                        </div>

                        <div className="text-right text-xs text-zinc-400">
                          {money(
                            token.liquidityUsd,
                          )}
                        </div>

                        <div
                          className={`text-right text-xs ${
                            (
                              token
                                .priceChange
                                .m5 ?? 0
                            ) >= 0
                              ? "text-emerald-300"
                              : "text-red-300"
                          }`}
                        >
                          {token
                            .priceChange
                            .m5 !== null
                            ? `${token.priceChange.m5 > 0 ? "+" : ""}${token.priceChange.m5.toFixed(1)}%`
                            : "N/A"}
                        </div>
                      </Link>
                    ),
                  )}
              </div>
            ) : (
              <div className="py-8 text-center">
                <Bookmark className="mx-auto h-5 w-5 text-zinc-700" />

                <p className="mt-3 text-sm text-zinc-600">
                  Your saved tokens will appear here.
                </p>

                <Link
                  href="/scanner"
                  className="mt-3 inline-flex text-xs text-emerald-300"
                >
                  Find tokens
                </Link>
              </div>
            )}
          </WidgetShell>
        )}

        {widgetEnabled(
          "smart-money",
        ) && (
          <WidgetShell
            title="Smart Money"
            subtitle={`${trackedWallets.length} tracked wallets`}
            action={
              <Link
                href="/smart-money"
                className="flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
              >
                Open
                <ChevronRight className="h-3.5 w-3.5" />
              </Link>
            }
          >
            {clusters.length > 0 ? (
              <div className="space-y-2">
                {clusters
                  .slice(0, 5)
                  .map((item) => (
                    <Link
                      key={item.mint}
                      href={`/token/${item.mint}`}
                      className="flex items-center justify-between gap-4 rounded-xl border border-white/5 bg-black/20 px-3 py-3 hover:bg-white/[0.025]"
                    >
                      <div>
                        <div className="flex items-center gap-2">
                          <Users className="h-3.5 w-3.5 text-cyan-300" />
                          <span className="font-medium text-white">
                            {item.symbol}
                          </span>
                        </div>

                        <div className="mt-1 text-[11px] text-zinc-600">
                          {item.walletCount} wallets observed
                        </div>
                      </div>

                      <div className="text-xl font-semibold text-cyan-300">
                        {
                          item.attentionScore
                        }
                      </div>
                    </Link>
                  ))}
              </div>
            ) : trackedWallets.length >
              0 ? (
              <div className="py-8 text-center text-sm text-zinc-600">
                No multi-wallet cluster in the current window.
              </div>
            ) : (
              <div className="py-8 text-center">
                <WalletCards className="mx-auto h-5 w-5 text-zinc-700" />

                <p className="mt-3 text-sm text-zinc-600">
                  Add tracked wallets to populate this widget.
                </p>

                <Link
                  href="/smart-money"
                  className="mt-3 inline-flex text-xs text-cyan-300"
                >
                  Add wallets
                </Link>
              </div>
            )}
          </WidgetShell>
        )}

        {widgetEnabled(
          "quick-links",
        ) && (
          <WidgetShell
            title="Market Shortcuts"
            subtitle="Jump directly into your research flow"
          >
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              {[
                {
                  href: "/scanner",
                  label: "Scanner",
                  icon: Search,
                },
                {
                  href: "/discover",
                  label: "Discover",
                  icon: Sparkles,
                },
                {
                  href: "/signals",
                  label: "Signals",
                  icon: Signal,
                },
                {
                  href: "/smart-money",
                  label: "Smart Money",
                  icon: Users,
                },
                {
                  href: "/watchlist",
                  label: "Watchlist",
                  icon: Bookmark,
                },
                {
                  href: "/alerts",
                  label: "Alerts",
                  icon: Bell,
                },
              ].map((item) => {
                const Icon =
                  item.icon;

                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    className="rounded-xl border border-white/5 bg-black/20 p-4 transition hover:border-white/10 hover:bg-white/[0.025]"
                  >
                    <Icon className="h-4 w-4 text-zinc-500" />

                    <div className="mt-3 text-xs font-medium text-zinc-200">
                      {item.label}
                    </div>
                  </Link>
                );
              })}
            </div>

            <div className="mt-4 grid gap-2 sm:grid-cols-2">
              <div className="rounded-xl border border-white/5 bg-black/20 p-3">
                <div className="text-[10px] uppercase tracking-[0.13em] text-zinc-700">
                  Top 5m mover
                </div>

                <div className="mt-2 flex items-center justify-between gap-3">
                  <span className="text-sm font-medium text-white">
                    {topMover?.symbol ??
                      "N/A"}
                  </span>

                  <span className="text-xs text-emerald-300">
                    {topMover
                      ?.priceChange.m5 !==
                    null &&
                    topMover
                      ?.priceChange.m5 !==
                      undefined
                      ? `${topMover.priceChange.m5 > 0 ? "+" : ""}${topMover.priceChange.m5.toFixed(1)}%`
                      : "N/A"}
                  </span>
                </div>
              </div>

              <div className="rounded-xl border border-white/5 bg-black/20 p-3">
                <div className="text-[10px] uppercase tracking-[0.13em] text-zinc-700">
                  5m volume leader
                </div>

                <div className="mt-2 flex items-center justify-between gap-3">
                  <span className="text-sm font-medium text-white">
                    {volumeLeader?.symbol ??
                      "N/A"}
                  </span>

                  <span className="text-xs text-zinc-300">
                    {money(
                      volumeLeader?.volume
                        .m5,
                    )}
                  </span>
                </div>
              </div>
            </div>
          </WidgetShell>
        )}
      </div>

      <div className="mt-5 text-[10px] text-zinc-700">
        Workspace preferences are currently stored locally in this browser.
      </div>
    </main>
  );
}