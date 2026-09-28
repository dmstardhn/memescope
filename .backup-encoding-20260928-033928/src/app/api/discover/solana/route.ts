import { NextResponse } from "next/server";
import type { DexPair } from "@/lib/dex-types";
import type { DiscoverResponse } from "@/lib/discover-types";
import { enrichDiscoverPair } from "@/lib/discover-engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const DISCOVERY_TTL = 15_000;
const MARKET_TTL = 3_000;
const MAX_ADDRESSES = 30;

type DiscoveryItem = {
  chainId?: string;
  tokenAddress?: string;
};

let discoveryCache: {
  expiresAt: number;
  addresses: string[];
} = {
  expiresAt: 0,
  addresses: [],
};

let marketCache: {
  expiresAt: number;
  payload: DiscoverResponse | null;
} = {
  expiresAt: 0,
  payload: null,
};

async function json(url: string) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "MemeScope/0.4",
    },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `DEX Screener upstream returned ${response.status}`,
    );
  }

  return response.json();
}

function toArray<T>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[];
  if (value && typeof value === "object")
    return [value as T];
  return [];
}

async function discoverAddresses() {
  const now = Date.now();

  if (
    discoveryCache.addresses.length &&
    now < discoveryCache.expiresAt
  ) {
    return discoveryCache.addresses;
  }

  const endpoints = [
    "https://api.dexscreener.com/token-profiles/latest/v1",
    "https://api.dexscreener.com/token-profiles/recent-updates/v1",
    "https://api.dexscreener.com/token-boosts/latest/v1",
    "https://api.dexscreener.com/token-boosts/top/v1",
  ];

  const settled = await Promise.allSettled(
    endpoints.map((endpoint) => json(endpoint)),
  );

  const ordered: string[] = [];
  const seen = new Set<string>();

  for (const result of settled) {
    if (result.status !== "fulfilled") continue;

    for (const item of toArray<DiscoveryItem>(
      result.value,
    )) {
      const address = item.tokenAddress;

      if (
        item.chainId?.toLowerCase() !== "solana" ||
        !address ||
        seen.has(address)
      ) {
        continue;
      }

      seen.add(address);
      ordered.push(address);

      if (ordered.length >= MAX_ADDRESSES) break;
    }

    if (ordered.length >= MAX_ADDRESSES) break;
  }

  if (ordered.length) {
    discoveryCache = {
      expiresAt: now + DISCOVERY_TTL,
      addresses: ordered,
    };
  }

  return ordered;
}

async function fetchPairs(addresses: string[]) {
  if (!addresses.length) return [];

  const joined = addresses
    .map((address) => encodeURIComponent(address))
    .join(",");

  const data = await json(
    `https://api.dexscreener.com/tokens/v1/solana/${joined}`,
  );

  if (Array.isArray(data)) return data as DexPair[];

  if (
    data &&
    typeof data === "object" &&
    Array.isArray(
      (data as { pairs?: DexPair[] }).pairs,
    )
  ) {
    return (data as { pairs: DexPair[] }).pairs;
  }

  return [];
}

function bestPairPerToken(pairs: DexPair[]) {
  const map = new Map<string, DexPair>();

  for (const pair of pairs) {
    const address = pair.baseToken?.address;
    if (!address) continue;

    const existing = map.get(address);
    const oldLiquidity = Number(
      existing?.liquidity?.usd || 0,
    );
    const newLiquidity = Number(
      pair.liquidity?.usd || 0,
    );

    if (!existing || newLiquidity > oldLiquidity) {
      map.set(address, pair);
    }
  }

  return Array.from(map.values());
}

export async function GET() {
  const now = Date.now();

  if (
    marketCache.payload &&
    now < marketCache.expiresAt
  ) {
    return NextResponse.json(marketCache.payload, {
      headers: { "Cache-Control": "no-store" },
    });
  }

  try {
    const addresses = await discoverAddresses();
    const pairs = await fetchPairs(addresses);
    const best = bestPairPerToken(pairs);

    const tokens = best
      .map(enrichDiscoverPair)
      .filter((token) => token !== null)
      .filter(
        (token) =>
          token.liquidity > 0 ||
          token.volume5m > 0,
      )
      .sort((a, b) => {
        if (
          a.ageMinutes !== null &&
          b.ageMinutes !== null &&
          a.ageMinutes !== b.ageMinutes
        ) {
          return a.ageMinutes - b.ageMinutes;
        }

        return b.trendScore - a.trendScore;
      });

    const payload: DiscoverResponse = {
      ok: true,
      source: "DEX Screener discovery + market data",
      updatedAt: Date.now(),
      refreshMs: MARKET_TTL,
      discoveryRefreshMs: DISCOVERY_TTL,
      candidates: addresses.length,
      tokens,
    };

    marketCache = {
      expiresAt: Date.now() + MARKET_TTL,
      payload,
    };

    return NextResponse.json(payload, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Discovery failed.";

    if (marketCache.payload) {
      return NextResponse.json(
        {
          ...marketCache.payload,
          ok: false,
          error: message,
        },
        {
          headers: { "Cache-Control": "no-store" },
        },
      );
    }

    return NextResponse.json(
      {
        ok: false,
        source: "DEX Screener discovery + market data",
        updatedAt: Date.now(),
        refreshMs: MARKET_TTL,
        discoveryRefreshMs: DISCOVERY_TTL,
        candidates: 0,
        tokens: [],
        error: message,
      } satisfies DiscoverResponse,
      {
        status: 502,
        headers: { "Cache-Control": "no-store" },
      },
    );
  }
}
