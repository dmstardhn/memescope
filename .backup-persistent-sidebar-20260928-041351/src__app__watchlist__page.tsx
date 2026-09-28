"use client";

import { AppShell } from "@/components/app-shell";
import {
  ArrowUpRight,
  Eye,
  Plus,
  Search,
  Trash2,
} from "lucide-react";
import Link from "next/link";
import {
  FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useState,
} from "react";

const STORAGE_KEY = "memescope-token-watchlist";
const REFRESH_MS = 2_000;

type WatchToken = {
  address: string;
  found: boolean;
  name: string | null;
  symbol: string | null;
  imageUrl: string | null;
  dexId: string | null;
  dexUrl: string | null;
  pairAddress: string | null;
  priceUsd: number;
  marketCap: number;
  liquidity: number;
  volume5m: number;
  buys5m: number;
  sells5m: number;
  priceChange5m: number;
};

function money(value: number) {
  if (!Number.isFinite(value)) return "$0";
  if (value >= 1_000_000_000)
    return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (value >= 1_000_000)
    return `$${(value / 1_000_000).toFixed(2)}M`;
  if (value >= 1_000)
    return `$${(value / 1_000).toFixed(1)}K`;
  if (value >= 1)
    return `$${value.toFixed(2)}`;
  return `$${value.toPrecision(5)}`;
}

function short(address: string) {
  return `${address.slice(0, 6)}â€¦${address.slice(-6)}`;
}

export default function WatchlistPage() {
  const [addresses, setAddresses] = useState<
    string[]
  >([]);
  const [tokens, setTokens] = useState<
    WatchToken[]
  >([]);
  const [input, setInput] = useState("");
  const [query, setQuery] = useState("");
  const [error, setError] = useState("");
  const [updatedAt, setUpdatedAt] =
    useState<number | null>(null);

  useEffect(() => {
    try {
      const saved = JSON.parse(
        localStorage.getItem(STORAGE_KEY) ||
          "[]",
      );

      if (Array.isArray(saved)) {
        const valid = saved.filter(
          (value) =>
            typeof value === "string" &&
            /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
              value,
            ),
        );
        setAddresses(valid);
      }
    } catch {
      setAddresses([]);
    }
  }, []);

  const load = useCallback(async () => {
    if (!addresses.length) {
      setTokens([]);
      return;
    }

    try {
      const response = await fetch(
        `/api/watchlist/solana?addresses=${encodeURIComponent(
          addresses.join(","),
        )}&t=${Date.now()}`,
        { cache: "no-store" },
      );

      const data = await response.json();

      if (!response.ok || !data.ok) {
        throw new Error(
          data.error || "Watchlist refresh failed.",
        );
      }

      setTokens(data.tokens || []);
      setUpdatedAt(data.updatedAt || Date.now());
      setError("");
    } catch (err) {
      setError(
        err instanceof Error
          ? err.message
          : "Watchlist refresh failed.",
      );
    }
  }, [addresses]);

  useEffect(() => {
    load();
    const timer = window.setInterval(
      load,
      REFRESH_MS,
    );
    return () => window.clearInterval(timer);
  }, [load]);

  function persist(next: string[]) {
    setAddresses(next);
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(next),
    );
  }

  function add(event: FormEvent) {
    event.preventDefault();

    const address = input.trim();

    if (
      !/^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
        address,
      )
    ) {
      setError(
        "Invalid Solana token mint address.",
      );
      return;
    }

    if (!addresses.includes(address)) {
      persist([address, ...addresses].slice(0, 30));
    }

    setInput("");
    setError("");
  }

  function remove(address: string) {
    persist(
      addresses.filter((item) => item !== address),
    );
  }

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();

    return tokens.filter((token) => {
      if (!q) return true;

      return (
        token.address.toLowerCase().includes(q) ||
        token.name?.toLowerCase().includes(q) ||
        token.symbol?.toLowerCase().includes(q)
      );
    });
  }, [tokens, query]);

  return (
    <AppShell>
      <div className="border-b border-white/8 px-5 py-5 lg:px-8">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <div className="flex items-center gap-2 text-sm text-emerald-300">
              <Eye className="h-4 w-4" />
              Real Token Watchlist
            </div>
            <h1 className="mt-1 text-3xl font-semibold tracking-tight text-white">
              Watchlist
            </h1>
            <p className="mt-1 text-sm text-zinc-500">
              Real Solana mint addresses only. Market data
              refreshes automatically every 2 seconds.
            </p>
          </div>

          <div className="text-xs text-zinc-600">
            {updatedAt
              ? `Updated ${new Date(
                  updatedAt,
                ).toLocaleTimeString()}`
              : "Waiting for market data"}
          </div>
        </div>
      </div>

      <div className="space-y-5 p-5 lg:p-8">
        <section className="flex flex-col gap-3 rounded-2xl border border-white/8 bg-white/[0.025] p-4 xl:flex-row">
          <form
            onSubmit={add}
            className="flex min-w-0 flex-1 gap-2"
          >
            <input
              value={input}
              onChange={(event) =>
                setInput(event.target.value)
              }
              placeholder="Paste real Solana token mint address"
              className="h-10 min-w-0 flex-1 rounded-xl border border-white/8 bg-black/20 px-3 font-mono text-xs outline-none placeholder:text-zinc-700 focus:border-emerald-400/40"
            />
            <button className="inline-flex h-10 items-center gap-2 rounded-xl bg-white px-4 text-sm font-medium text-black">
              <Plus className="h-4 w-4" />
              Add
            </button>
          </form>

          <div className="relative xl:w-72">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-zinc-600" />
            <input
              value={query}
              onChange={(event) =>
                setQuery(event.target.value)
              }
              placeholder="Filter watchlist"
              className="h-10 w-full rounded-xl border border-white/8 bg-black/20 pl-10 pr-3 text-sm outline-none placeholder:text-zinc-700"
            />
          </div>
        </section>

        {error ? (
          <div className="rounded-2xl border border-rose-400/15 bg-rose-400/5 p-4 text-sm text-rose-200">
            {error}
          </div>
        ) : null}

        {!addresses.length ? (
          <div className="rounded-2xl border border-white/8 bg-white/[0.025] p-10 text-center">
            <Eye className="mx-auto h-7 w-7 text-zinc-700" />
            <div className="mt-3 text-sm text-zinc-400">
              Your real-token watchlist is empty.
            </div>
            <p className="mx-auto mt-2 max-w-md text-xs leading-5 text-zinc-600">
              Paste a real Solana mint address above. The
              old Stage 01 demo addresses are no longer used.
            </p>
          </div>
        ) : (
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
            {visible.map((token) => (
              <div
                key={token.address}
                className="rounded-2xl border border-white/8 bg-white/[0.025] p-5"
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="font-medium text-white">
                      {token.symbol
                        ? `$${token.symbol}`
                        : "Unknown token"}
                    </div>
                    <div className="mt-1 truncate text-xs text-zinc-600">
                      {token.name ||
                        short(token.address)}
                    </div>
                  </div>

                  <button
                    onClick={() =>
                      remove(token.address)
                    }
                    className="text-zinc-700 hover:text-rose-300"
                  >
                    <Trash2 className="h-4 w-4" />
                  </button>
                </div>

                {token.found ? (
                  <>
                    <div className="mt-5 grid grid-cols-2 gap-3">
                      {[
                        [
                          "Price",
                          money(token.priceUsd),
                        ],
                        [
                          "Market Cap",
                          money(token.marketCap),
                        ],
                        [
                          "Liquidity",
                          money(token.liquidity),
                        ],
                        [
                          "5M Volume",
                          money(token.volume5m),
                        ],
                      ].map(([label, value]) => (
                        <div
                          key={label}
                          className="rounded-xl border border-white/5 bg-black/15 p-3"
                        >
                          <div className="text-xs text-zinc-600">
                            {label}
                          </div>
                          <div className="mt-1 text-sm font-medium text-zinc-200">
                            {value}
                          </div>
                        </div>
                      ))}
                    </div>

                    <div className="mt-4 flex items-center justify-between text-xs">
                      <div>
                        <span className="text-emerald-300">
                          {token.buys5m}
                        </span>
                        <span className="px-1 text-zinc-700">
                          /
                        </span>
                        <span className="text-rose-300">
                          {token.sells5m}
                        </span>
                        <span className="ml-2 text-zinc-600">
                          5m B/S
                        </span>
                      </div>

                      <div
                        className={
                          token.priceChange5m >= 0
                            ? "text-emerald-300"
                            : "text-rose-300"
                        }
                      >
                        {token.priceChange5m > 0
                          ? "+"
                          : ""}
                        {token.priceChange5m.toFixed(
                          1,
                        )}
                        %
                      </div>
                    </div>

                    <div className="mt-5 flex items-center gap-4">
                      <Link
                        href={`/token/${token.address}`}
                        className="text-xs font-medium text-emerald-300 hover:text-emerald-200"
                      >
                        Analyze
                      </Link>

                      {token.dexUrl ? (
                        <a
                          href={token.dexUrl}
                          target="_blank"
                          rel="noreferrer"
                          className="inline-flex items-center gap-1 text-xs text-zinc-500 hover:text-white"
                        >
                          DEX
                          <ArrowUpRight className="h-3.5 w-3.5" />
                        </a>
                      ) : null}
                    </div>
                  </>
                ) : (
                  <div className="mt-5 rounded-xl border border-amber-400/10 bg-amber-400/5 p-3 text-xs leading-5 text-amber-200/60">
                    Valid Solana-style address, but no DEX
                    market pair was found yet.
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </AppShell>
  );
}
