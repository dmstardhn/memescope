import type { DexPair } from "@/lib/dex-types";
import type {
  DiscoverCategory,
  DiscoverToken,
} from "@/lib/discover-types";
import {
  pairToLiveToken,
  scorePair,
} from "@/lib/market-score";

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

function logScore(value: number, scale: number) {
  if (value <= 0) return 0;
  return clamp(Math.log10(value + 1) * scale);
}

export function enrichDiscoverPair(
  pair: DexPair,
): DiscoverToken | null {
  const base = pairToLiveToken(pair);
  if (!base) return null;

  const buys = base.buys5m;
  const sells = base.sells5m;
  const totalTrades = buys + sells;

  const buySellRatio =
    sells > 0 ? buys / sells : buys > 0 ? buys : 0;

  // Compare current 5m activity against the expected 5m slice
  // of the current 1h aggregate. Ratio > 1 means acceleration.
  const expected5m =
    base.volume1h > 0 ? base.volume1h / 12 : 0;

  const volumeSpikeRatio =
    expected5m > 0
      ? base.volume5m / expected5m
      : base.volume5m > 0
        ? 1
        : 0;

  const flow =
    totalTrades > 0 ? buys / totalTrades : 0.5;

  const trendScore = Math.round(
    clamp(
      logScore(base.volume5m, 18) * 0.28 +
        clamp(volumeSpikeRatio * 22) * 0.26 +
        clamp(50 + base.priceChange5m * 1.8) * 0.18 +
        clamp(50 + (flow - 0.5) * 110) * 0.18 +
        clamp(base.boosts * 10) * 0.1,
    ),
  );

  const categories: DiscoverCategory[] = [];

  if (
    base.ageMinutes !== null &&
    base.ageMinutes <= 360
  ) {
    categories.push("new");
  }

  if (
    trendScore >= 62 &&
    base.volume5m >= 2_000
  ) {
    categories.push("trending");
  }

  if (
    volumeSpikeRatio >= 1.8 &&
    base.volume5m >= 1_000
  ) {
    categories.push("volume-spike");
  }

  if (scorePair(pair) >= 70) {
    categories.push("high-score");
  }

  return {
    chainId: "solana",
    tokenAddress: base.tokenAddress,
    pairAddress: base.pairAddress,
    name: base.name,
    symbol: base.symbol,
    imageUrl: base.imageUrl,
    dexId: base.dexId,
    dexUrl: base.dexUrl,
    priceUsd: base.priceUsd,
    marketCap: base.marketCap,
    fdv: base.fdv,
    liquidity: base.liquidity,
    volume5m: base.volume5m,
    volume1h: base.volume1h,
    volume24h: base.volume24h,
    buys5m: base.buys5m,
    sells5m: base.sells5m,
    priceChange5m: base.priceChange5m,
    priceChange1h: base.priceChange1h,
    pairCreatedAt: base.pairCreatedAt,
    ageMinutes: base.ageMinutes,
    score: base.score,
    trendScore,
    volumeSpikeRatio: n(volumeSpikeRatio),
    buySellRatio: n(buySellRatio),
    boosts: base.boosts,
    categories,
  };
}
