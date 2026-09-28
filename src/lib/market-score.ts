import type { DexPair, LiveToken } from "@/lib/dex-types";

function clamp(value: number, min = 0, max = 100) {
  return Math.min(max, Math.max(min, value));
}

function n(value: unknown) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function timeframe(
  source: Record<string, number> | null | undefined,
  key: string,
) {
  return n(source?.[key]);
}

function txn(
  source: DexPair["txns"],
  frame: string,
  side: "buys" | "sells",
) {
  return n(source?.[frame]?.[side]);
}

export function scorePair(pair: DexPair): number {
  const liquidity = n(pair.liquidity?.usd);
  const marketCap = n(pair.marketCap ?? pair.fdv);
  const volume5m = timeframe(pair.volume, "m5");
  const volume1h = timeframe(pair.volume, "h1");
  const change5m = timeframe(pair.priceChange ?? undefined, "m5");
  const buys5m = txn(pair.txns, "m5", "buys");
  const sells5m = txn(pair.txns, "m5", "sells");
  const trades5m = buys5m + sells5m;

  const liquidityScore = clamp(
    18 * Math.log10(Math.max(liquidity, 1)) - 35,
  );

  const liquidityRatio =
    marketCap > 0 ? clamp((liquidity / marketCap) * 260) : 20;

  const activityScore = clamp(
    Math.log10(Math.max(volume5m, 1)) * 18 +
      Math.log10(Math.max(volume1h, 1)) * 8 -
      44,
  );

  const buyRatio =
    trades5m > 0 ? buys5m / Math.max(trades5m, 1) : 0.5;
  const flowScore = clamp(50 + (buyRatio - 0.5) * 90);

  const momentumScore = clamp(50 + change5m * 1.6);

  const score =
    liquidityScore * 0.28 +
    liquidityRatio * 0.22 +
    activityScore * 0.25 +
    flowScore * 0.15 +
    momentumScore * 0.1;

  return Math.round(clamp(score));
}

export function riskFromPair(
  pair: DexPair,
): LiveToken["riskLabel"] {
  const liquidity = n(pair.liquidity?.usd);
  const marketCap = n(pair.marketCap ?? pair.fdv);
  const ratio = marketCap > 0 ? liquidity / marketCap : 0;
  const sells = txn(pair.txns, "m5", "sells");
  const buys = txn(pair.txns, "m5", "buys");

  if (
    liquidity < 10_000 ||
    (marketCap > 0 && ratio < 0.05) ||
    (sells > buys * 2 && sells > 10)
  ) {
    return "Higher";
  }

  if (liquidity < 30_000 || (marketCap > 0 && ratio < 0.12)) {
    return "Medium";
  }

  return "Lower";
}

export function pairToLiveToken(pair: DexPair): LiveToken | null {
  const tokenAddress = pair.baseToken?.address;
  const pairAddress = pair.pairAddress;

  if (!tokenAddress || !pairAddress) return null;

  const now = Date.now();
  const createdAt =
    typeof pair.pairCreatedAt === "number" ? pair.pairCreatedAt : null;

  return {
    chainId: "solana",
    dexId: pair.dexId || "unknown",
    pairAddress,
    tokenAddress,
    name: pair.baseToken?.name || "Unknown Token",
    symbol: pair.baseToken?.symbol || "UNKNOWN",
    quoteSymbol: pair.quoteToken?.symbol || "",
    imageUrl: pair.info?.imageUrl || null,
    dexUrl:
      pair.url ||
      `https://dexscreener.com/solana/${encodeURIComponent(pairAddress)}`,
    priceUsd: n(pair.priceUsd),
    marketCap: n(pair.marketCap),
    fdv: n(pair.fdv),
    liquidity: n(pair.liquidity?.usd),
    volume5m: timeframe(pair.volume, "m5"),
    volume1h: timeframe(pair.volume, "h1"),
    volume6h: timeframe(pair.volume, "h6"),
    volume24h: timeframe(pair.volume, "h24"),
    buys5m: txn(pair.txns, "m5", "buys"),
    sells5m: txn(pair.txns, "m5", "sells"),
    buys1h: txn(pair.txns, "h1", "buys"),
    sells1h: txn(pair.txns, "h1", "sells"),
    priceChange5m: timeframe(pair.priceChange ?? undefined, "m5"),
    priceChange1h: timeframe(pair.priceChange ?? undefined, "h1"),
    priceChange6h: timeframe(pair.priceChange ?? undefined, "h6"),
    priceChange24h: timeframe(pair.priceChange ?? undefined, "h24"),
    pairCreatedAt: createdAt,
    ageMinutes: createdAt
      ? Math.max(0, Math.floor((now - createdAt) / 60_000))
      : null,
    boosts: n(pair.boosts?.active),
    score: scorePair(pair),
    riskLabel: riskFromPair(pair),
  };
}
