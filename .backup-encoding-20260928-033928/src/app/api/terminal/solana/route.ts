import { NextResponse } from "next/server";

import type {
  TerminalResponse,
  TerminalSourceFlags,
  TerminalToken,
} from "@/lib/terminal-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type ProfileItem = {
  chainId?: string;
  tokenAddress?: string;
};

type BoostItem = {
  chainId?: string;
  tokenAddress?: string;
  amount?: number;
  totalAmount?: number;
};

type Pair = {
  chainId?: string;
  dexId?: string;
  url?: string;
  pairAddress?: string;

  baseToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };

  quoteToken?: {
    address?: string;
    name?: string;
    symbol?: string;
  };

  priceNative?: string;
  priceUsd?: string | null;

  txns?: Record<
    string,
    {
      buys?: number;
      sells?: number;
    }
  >;

  volume?: Record<string, number>;
  priceChange?: Record<string, number>;

  liquidity?: {
    usd?: number | null;
  };

  fdv?: number | null;
  marketCap?: number | null;
  pairCreatedAt?: number | null;

  info?: {
    imageUrl?: string | null;

    websites?: Array<{
      url?: string;
    }> | null;

    socials?: Array<{
      platform?: string;
      handle?: string;
    }> | null;
  };

  boosts?: {
    active?: number;
  };
};

type Candidate = {
  address: string;
  sources: TerminalSourceFlags;
  boostAmount: number;
  boostTotalAmount: number;
};

let cache:
  | {
      expiresAt: number;
      payload: TerminalResponse;
    }
  | null = null;

const BASE = "https://api.dexscreener.com";

function blankSources(): TerminalSourceFlags {
  return {
    latestProfile: false,
    recentUpdate: false,
    boostedLatest: false,
    boostedTop: false,
    communityTakeover: false,
    advertised: false,
  };
}

function safeNumber(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function nullableNumber(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function tx(
  pair: Pair,
  period: "m5" | "h1" | "h6" | "h24",
) {
  return {
    buys: safeNumber(pair.txns?.[period]?.buys),
    sells: safeNumber(pair.txns?.[period]?.sells),
  };
}

function vol(
  pair: Pair,
  period: "m5" | "h1" | "h6" | "h24",
) {
  return safeNumber(pair.volume?.[period]);
}

function pct(
  pair: Pair,
  period: "m5" | "h1" | "h6" | "h24",
) {
  const value = pair.priceChange?.[period];

  return typeof value === "number" &&
    Number.isFinite(value)
    ? value
    : null;
}

function chooseBestPair(
  address: string,
  pairs: Pair[],
) {
  const candidates = pairs
    .filter(
      (pair) =>
        pair.chainId === "solana" &&
        pair.baseToken?.address === address,
    )
    .sort(
      (a, b) =>
        safeNumber(b.liquidity?.usd) -
        safeNumber(a.liquidity?.usd),
    );

  return candidates[0] ?? null;
}

function computeActivityScore(
  pair: Pair,
  volumeSpike5m: number | null,
  buyShare5m: number | null,
  pairAgeMinutes: number | null,
) {
  const liquidity = safeNumber(pair.liquidity?.usd);
  const volume5m = vol(pair, "m5");

  let score = 0;

  if (liquidity >= 500_000) score += 20;
  else if (liquidity >= 150_000) score += 17;
  else if (liquidity >= 50_000) score += 13;
  else if (liquidity >= 20_000) score += 8;
  else if (liquidity >= 5_000) score += 3;

  if (volume5m >= 250_000) score += 20;
  else if (volume5m >= 100_000) score += 17;
  else if (volume5m >= 25_000) score += 13;
  else if (volume5m >= 5_000) score += 8;
  else if (volume5m > 0) score += 3;

  if (volumeSpike5m !== null) {
    score += clamp(volumeSpike5m * 4, 0, 20);
  }

  if (buyShare5m !== null) {
    score += clamp((buyShare5m - 0.45) * 50, 0, 15);
  }

  const change5m = pct(pair, "m5") ?? 0;
  score += clamp(change5m / 2, 0, 10);

  if (pairAgeMinutes !== null) {
    if (pairAgeMinutes <= 30) score += 10;
    else if (pairAgeMinutes <= 120) score += 7;
    else if (pairAgeMinutes <= 1_440) score += 4;
  }

  const boosts = safeNumber(pair.boosts?.active);
  score += clamp(boosts, 0, 5);

  return Math.round(clamp(score, 0, 100));
}

async function getJson<T>(
  path: string,
  warnings: string[],
): Promise<T | null> {
  try {
    const response = await fetch(`${BASE}${path}`, {
      headers: {
        Accept: "application/json",
      },
      cache: "no-store",
    });

    if (!response.ok) {
      warnings.push(`${path}: HTTP ${response.status}`);
      return null;
    }

    return (await response.json()) as T;
  } catch (error) {
    warnings.push(
      `${path}: ${
        error instanceof Error
          ? error.message
          : "request failed"
      }`,
    );

    return null;
  }
}

function addCandidates(
  map: Map<string, Candidate>,
  items: Array<ProfileItem | BoostItem> | null,
  flag: keyof TerminalSourceFlags,
) {
  for (const item of items ?? []) {
    if (
      item.chainId !== "solana" ||
      !item.tokenAddress
    ) {
      continue;
    }

    const existing = map.get(item.tokenAddress) ?? {
      address: item.tokenAddress,
      sources: blankSources(),
      boostAmount: 0,
      boostTotalAmount: 0,
    };

    existing.sources[flag] = true;

    const boost = item as BoostItem;

    existing.boostAmount = Math.max(
      existing.boostAmount,
      safeNumber(boost.amount),
    );

    existing.boostTotalAmount = Math.max(
      existing.boostTotalAmount,
      safeNumber(boost.totalAmount),
    );

    map.set(item.tokenAddress, existing);
  }
}

export async function GET() {
  if (
    cache &&
    cache.expiresAt > Date.now()
  ) {
    return NextResponse.json(cache.payload);
  }

  const warnings: string[] = [];

  const [
    latestProfiles,
    recentProfiles,
    latestBoosts,
    topBoosts,
    takeovers,
    ads,
  ] = await Promise.all([
    getJson<ProfileItem[]>(
      "/token-profiles/latest/v1",
      warnings,
    ),
    getJson<ProfileItem[]>(
      "/token-profiles/recent-updates/v1",
      warnings,
    ),
    getJson<BoostItem[]>(
      "/token-boosts/latest/v1",
      warnings,
    ),
    getJson<BoostItem[]>(
      "/token-boosts/top/v1",
      warnings,
    ),
    getJson<ProfileItem[]>(
      "/community-takeovers/latest/v1",
      warnings,
    ),
    getJson<ProfileItem[]>(
      "/ads/latest/v1",
      warnings,
    ),
  ]);

  const candidates = new Map<string, Candidate>();

  addCandidates(
    candidates,
    latestProfiles,
    "latestProfile",
  );

  addCandidates(
    candidates,
    recentProfiles,
    "recentUpdate",
  );

  addCandidates(
    candidates,
    latestBoosts,
    "boostedLatest",
  );

  addCandidates(
    candidates,
    topBoosts,
    "boostedTop",
  );

  addCandidates(
    candidates,
    takeovers,
    "communityTakeover",
  );

  addCandidates(
    candidates,
    ads,
    "advertised",
  );

  const addresses = Array.from(
    candidates.keys(),
  ).slice(0, 180);

  const allPairs: Pair[] = [];

  for (
    let index = 0;
    index < addresses.length;
    index += 30
  ) {
    const chunk = addresses.slice(
      index,
      index + 30,
    );

    const pairs = await getJson<Pair[]>(
      `/tokens/v1/solana/${chunk.join(",")}`,
      warnings,
    );

    if (Array.isArray(pairs)) {
      allPairs.push(...pairs);
    }
  }

  const now = Date.now();
  const tokens: TerminalToken[] = [];

  for (const address of addresses) {
    const candidate = candidates.get(address);

    if (!candidate) continue;

    const pair = chooseBestPair(
      address,
      allPairs,
    );

    if (!pair || !pair.baseToken?.address) {
      continue;
    }

    const m5 = tx(pair, "m5");
    const total5m = m5.buys + m5.sells;

    const buyShare5m =
      total5m > 0
        ? m5.buys / total5m
        : null;

    const volume5m = vol(pair, "m5");
    const volume1h = vol(pair, "h1");

    const expected5m =
      volume1h > 0
        ? volume1h / 12
        : 0;

    const volumeSpike5m =
      expected5m > 0
        ? volume5m / expected5m
        : null;

    const pairCreatedAt =
      typeof pair.pairCreatedAt === "number"
        ? pair.pairCreatedAt
        : null;

    const pairAgeMinutes =
      pairCreatedAt !== null
        ? Math.max(
            0,
            (now - pairCreatedAt) / 60_000,
          )
        : null;

    const liquidityUsd = safeNumber(
      pair.liquidity?.usd,
    );

    const marketCap =
      typeof pair.marketCap === "number"
        ? pair.marketCap
        : null;

    const liquidityToMcap =
      marketCap && marketCap > 0
        ? liquidityUsd / marketCap
        : null;

    const activityScore =
      computeActivityScore(
        pair,
        volumeSpike5m,
        buyShare5m,
        pairAgeMinutes,
      );

    tokens.push({
      address,
      pairAddress: pair.pairAddress ?? "",
      dexId: pair.dexId ?? "unknown",
      dexUrl: pair.url ?? null,

      symbol:
        pair.baseToken.symbol ?? "UNKNOWN",

      name:
        pair.baseToken.name ?? "Unknown token",

      imageUrl:
        pair.info?.imageUrl ?? null,

      priceUsd:
        pair.priceUsd
          ? nullableNumber(pair.priceUsd)
          : null,

      priceNative:
        pair.priceNative
          ? nullableNumber(pair.priceNative)
          : null,

      priceChange: {
        m5: pct(pair, "m5"),
        h1: pct(pair, "h1"),
        h6: pct(pair, "h6"),
        h24: pct(pair, "h24"),
      },

      volume: {
        m5: volume5m,
        h1: volume1h,
        h6: vol(pair, "h6"),
        h24: vol(pair, "h24"),
      },

      txns: {
        m5,
        h1: tx(pair, "h1"),
        h6: tx(pair, "h6"),
        h24: tx(pair, "h24"),
      },

      liquidityUsd,

      marketCap,

      fdv:
        typeof pair.fdv === "number"
          ? pair.fdv
          : null,

      pairCreatedAt,
      pairAgeMinutes,

      boostsActive:
        safeNumber(pair.boosts?.active),

      boostAmount:
        candidate.boostAmount,

      boostTotalAmount:
        candidate.boostTotalAmount,

      websites:
        (pair.info?.websites ?? [])
          .map((item) => item.url)
          .filter(
            (value): value is string =>
              Boolean(value),
          ),

      socials:
        (pair.info?.socials ?? [])
          .map((item) => ({
            platform:
              item.platform ?? "social",
            handle:
              item.handle ?? "",
          }))
          .filter(
            (item) =>
              item.platform.length > 0,
          ),

      sources: candidate.sources,

      volumeSpike5m,
      buyShare5m,
      liquidityToMcap,

      activityScore,
    });
  }

  tokens.sort(
    (a, b) =>
      b.activityScore -
      a.activityScore,
  );

  const payload: TerminalResponse = {
    generatedAt: Date.now(),
    tokenCount: tokens.length,
    sourceCount: addresses.length,
    tokens,
    warnings,
  };

  cache = {
    expiresAt: Date.now() + 15_000,
    payload,
  };

  return NextResponse.json(payload);
}