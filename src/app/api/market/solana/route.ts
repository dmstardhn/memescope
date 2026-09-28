import { NextResponse } from "next/server";
import type {
  DexPair,
  SolanaMarketResponse,
} from "@/lib/dex-types";
import { pairToLiveToken } from "@/lib/market-score";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const DISCOVERY_TTL = 20_000;
const MARKET_TTL = 2_000;
const MAX_TOKENS = 30;

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
  payload: SolanaMarketResponse | null;
} = {
  expiresAt: 0,
  payload: null,
};

async function getJson(url: string) {
  const response = await fetch(url, {
    headers: {
      Accept: "application/json",
      "User-Agent": "MemeScope/0.2",
    },
    cache: "no-store",
  });

  if (!response.ok) {
    throw new Error(
      `Upstream request failed (${response.status})`,
    );
  }

  return response.json();
}

function asArray<T>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[];
  if (value && typeof value === "object") return [value as T];
  return [];
}

async function discoverSolanaAddresses() {
  const now = Date.now();

  if (
    discoveryCache.addresses.length > 0 &&
    now < discoveryCache.expiresAt
  ) {
    return discoveryCache.addresses;
  }

  const settled = await Promise.allSettled([
    getJson("https://api.dexscreener.com/token-profiles/latest/v1"),
    getJson("https://api.dexscreener.com/token-boosts/latest/v1"),
    getJson("https://api.dexscreener.com/token-boosts/top/v1"),
  ]);

  const addresses = new Set<string>();

  for (const result of settled) {
    if (result.status !== "fulfilled") continue;

    for (const item of asArray<DiscoveryItem>(result.value)) {
      if (
        item.chainId?.toLowerCase() === "solana" &&
        item.tokenAddress
      ) {
        addresses.add(item.tokenAddress);
      }

      if (addresses.size >= MAX_TOKENS) break;
    }

    if (addresses.size >= MAX_TOKENS) break;
  }

  const nextAddresses = Array.from(addresses).slice(0, MAX_TOKENS);

  if (nextAddresses.length > 0) {
    discoveryCache = {
      expiresAt: now + DISCOVERY_TTL,
      addresses: nextAddresses,
    };
  }

  return nextAddresses;
}

function chooseBestPairs(pairs: DexPair[]) {
  const best = new Map<string, DexPair>();

  for (const pair of pairs) {
    const address = pair.baseToken?.address;
    if (!address) continue;

    const current = best.get(address);
    const currentLiquidity = Number(current?.liquidity?.usd || 0);
    const nextLiquidity = Number(pair.liquidity?.usd || 0);

    if (!current || nextLiquidity > currentLiquidity) {
      best.set(address, pair);
    }
  }

  return Array.from(best.values());
}

async function fetchMarketPairs(addresses: string[]) {
  if (addresses.length === 0) return [];

  const encoded = addresses
    .map((address) => encodeURIComponent(address))
    .join(",");

  const data = await getJson(
    `https://api.dexscreener.com/tokens/v1/solana/${encoded}`,
  );

  if (Array.isArray(data)) {
    return data as DexPair[];
  }

  if (
    data &&
    typeof data === "object" &&
    Array.isArray((data as { pairs?: DexPair[] }).pairs)
  ) {
    return (data as { pairs: DexPair[] }).pairs;
  }

  return [];
}

export async function GET() {
  const now = Date.now();

  if (
    marketCache.payload &&
    now < marketCache.expiresAt
  ) {
    return NextResponse.json(marketCache.payload, {
      headers: {
        "Cache-Control": "no-store",
      },
    });
  }

  try {
    const addresses = await discoverSolanaAddresses();

    if (addresses.length === 0) {
      throw new Error("No Solana token candidates discovered.");
    }

    const pairs = await fetchMarketPairs(addresses);
    const bestPairs = chooseBestPairs(pairs);

    const tokens = bestPairs
      .map(pairToLiveToken)
      .filter((token) => token !== null)
      .filter((token) => token.liquidity > 0)
      .sort((a, b) => {
        const scoreDiff = b.score - a.score;
        if (scoreDiff !== 0) return scoreDiff;
        return b.volume5m - a.volume5m;
      });

    const payload: SolanaMarketResponse = {
      ok: true,
      source: "DEX Screener",
      mode: "near-real-time REST",
      refreshMs: MARKET_TTL,
      discoveryRefreshMs: DISCOVERY_TTL,
      updatedAt: Date.now(),
      discovered: addresses.length,
      tokens,
    };

    marketCache = {
      expiresAt: Date.now() + MARKET_TTL,
      payload,
    };

    return NextResponse.json(payload, {
      headers: {
        "Cache-Control": "no-store",
      },
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Unknown market error";

    if (marketCache.payload) {
      return NextResponse.json(
        {
          ...marketCache.payload,
          ok: false,
          error: message,
        },
        {
          headers: {
            "Cache-Control": "no-store",
          },
        },
      );
    }

    return NextResponse.json(
      {
        ok: false,
        source: "DEX Screener",
        mode: "near-real-time REST",
        refreshMs: MARKET_TTL,
        discoveryRefreshMs: DISCOVERY_TTL,
        updatedAt: Date.now(),
        discovered: 0,
        tokens: [],
        error: message,
      } satisfies SolanaMarketResponse,
      {
        status: 502,
        headers: {
          "Cache-Control": "no-store",
        },
      },
    );
  }
}
