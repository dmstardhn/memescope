import type {
  SignalCall,
  SignalConfidence,
  SignalKind,
} from "@/lib/signal-types";
import type { TerminalToken } from "@/lib/terminal-types";

function clamp(
  value: number,
  min: number,
  max: number,
) {
  return Math.max(min, Math.min(max, value));
}

function getBuyShare(token: TerminalToken) {
  const buys = token.txns.m5.buys;
  const sells = token.txns.m5.sells;
  const total = buys + sells;

  return total > 0 ? buys / total : null;
}

function confidenceFor(
  token: TerminalToken,
): SignalConfidence {
  let complete = 0;

  if (token.priceUsd !== null) complete += 1;
  if (token.marketCap !== null || token.fdv !== null) {
    complete += 1;
  }
  if (token.liquidityUsd > 0) complete += 1;
  if (token.volume.m5 > 0) complete += 1;
  if (token.pairAgeMinutes !== null) complete += 1;
  if (token.volumeSpike5m !== null) complete += 1;

  if (complete >= 6) return "high";
  if (complete >= 4) return "medium";
  return "limited";
}

function baseScore(token: TerminalToken) {
  const buyShare = getBuyShare(token);
  const spike = token.volumeSpike5m ?? 0;
  const change5m = token.priceChange.m5 ?? 0;
  const txns5m =
    token.txns.m5.buys +
    token.txns.m5.sells;

  let score = token.activityScore * 0.38;

  if (token.liquidityUsd >= 100_000) score += 12;
  else if (token.liquidityUsd >= 50_000) score += 10;
  else if (token.liquidityUsd >= 20_000) score += 7;
  else if (token.liquidityUsd >= 5_000) score += 3;

  score += clamp(spike * 5, 0, 18);

  if (buyShare !== null) {
    score += clamp(
      (buyShare - 0.5) * 50,
      0,
      12,
    );
  }

  if (txns5m >= 100) score += 8;
  else if (txns5m >= 50) score += 6;
  else if (txns5m >= 20) score += 4;
  else if (txns5m >= 8) score += 2;

  if (change5m > 0 && change5m <= 20) {
    score += clamp(change5m / 3, 0, 7);
  }

  return Math.round(clamp(score, 0, 100));
}

function buildCall(
  token: TerminalToken,
  kind: SignalKind,
  label: string,
  score: number,
  reasons: string[],
  caution: string[],
  direction: "watch" | "caution" = "watch",
): SignalCall {
  return {
    id: `${token.address}-${kind}`,
    tokenAddress: token.address,
    symbol: token.symbol,
    name: token.name,
    imageUrl: token.imageUrl,

    kind,
    direction,
    label,

    signalScore: Math.round(
      clamp(score, 0, 100),
    ),

    confidence: confidenceFor(token),

    detectedAt: Date.now(),

    priceUsd: token.priceUsd,
    priceChange5m: token.priceChange.m5,
    priceChange1h: token.priceChange.h1,

    liquidityUsd: token.liquidityUsd,
    marketCap:
      token.marketCap ?? token.fdv,

    volume5m: token.volume.m5,
    volume1h: token.volume.h1,

    buys5m: token.txns.m5.buys,
    sells5m: token.txns.m5.sells,
    buyShare5m: getBuyShare(token),
    volumeSpike5m: token.volumeSpike5m,
    pairAgeMinutes: token.pairAgeMinutes,

    activityScore: token.activityScore,

    reasons,
    caution,
    dexUrl: token.dexUrl,
  };
}

export function generateSignals(
  tokens: TerminalToken[],
): SignalCall[] {
  const calls: SignalCall[] = [];

  for (const token of tokens) {
    const buyShare = getBuyShare(token);
    const spike = token.volumeSpike5m ?? 0;
    const change5m = token.priceChange.m5 ?? 0;
    const change1h = token.priceChange.h1 ?? 0;
    const ageMinutes =
      token.pairAgeMinutes ??
      Number.POSITIVE_INFINITY;

    const txns5m =
      token.txns.m5.buys +
      token.txns.m5.sells;

    const base = baseScore(token);

    if (
      ageMinutes <= 360 &&
      token.liquidityUsd >= 20_000 &&
      token.volume.m5 >= 8_000 &&
      spike >= 1.5 &&
      (buyShare ?? 0) >= 0.56 &&
      change5m > -5 &&
      change5m <= 22
    ) {
      const reasons = [
        `Pair age is ${Math.max(
          1,
          Math.round(ageMinutes),
        )} minutes.`,
        `5m volume is $${Math.round(
          token.volume.m5,
        ).toLocaleString("en-US")}.`,
        `5m activity is ${spike.toFixed(
          2,
        )}x the 1h average 5m pace.`,
        `Buy share is ${Math.round(
          (buyShare ?? 0) * 100,
        )}%.`,
      ];

      const caution: string[] = [];

      if (token.liquidityUsd < 50_000) {
        caution.push(
          "Liquidity is still relatively thin.",
        );
      }

      if (change5m >= 15) {
        caution.push(
          "Price has already moved quickly in the last 5 minutes.",
        );
      }

      calls.push(
        buildCall(
          token,
          "early-momentum",
          "Early Momentum Watch",
          base + 8,
          reasons,
          caution,
        ),
      );

      continue;
    }

    if (
      token.liquidityUsd >= 50_000 &&
      token.volume.m5 >= 15_000 &&
      spike >= 1.2 &&
      (buyShare ?? 0) >= 0.58 &&
      txns5m >= 20 &&
      change5m > 0 &&
      change5m <= 18
    ) {
      calls.push(
        buildCall(
          token,
          "momentum",
          "Momentum Watch",
          base + 5,
          [
            `Liquidity is $${Math.round(
              token.liquidityUsd,
            ).toLocaleString("en-US")}.`,
            `Buy share is ${Math.round(
              (buyShare ?? 0) * 100,
            )}% across ${txns5m} recent 5m transactions.`,
            `5m price change is ${change5m.toFixed(
              1,
            )}%.`,
          ],
          change1h >= 40
            ? [
                "The 1h move is already extended; continuation is less certain.",
              ]
            : [],
        ),
      );

      continue;
    }

    if (
      spike >= 2.5 &&
      token.volume.m5 >= 10_000 &&
      token.liquidityUsd >= 15_000 &&
      txns5m >= 15
    ) {
      calls.push(
        buildCall(
          token,
          "volume-spike",
          "Volume Spike Watch",
          base + 2,
          [
            `5m volume is ${spike.toFixed(
              2,
            )}x the recent 1h average pace.`,
            `${txns5m} transactions were observed in the 5m window.`,
            `Liquidity is $${Math.round(
              token.liquidityUsd,
            ).toLocaleString("en-US")}.`,
          ],
          (buyShare ?? 0.5) < 0.5
            ? [
                "The spike is not currently dominated by buys.",
              ]
            : [],
        ),
      );

      continue;
    }

    if (
      change5m >= 25 &&
      spike >= 2 &&
      token.volume.m5 >= 10_000
    ) {
      calls.push(
        buildCall(
          token,
          "overheated",
          "Overheated Move",
          clamp(base - 4, 0, 100),
          [
            `Price is up ${change5m.toFixed(
              1,
            )}% in 5 minutes.`,
            `Volume is ${spike.toFixed(
              2,
            )}x the recent average pace.`,
          ],
          [
            "Rapid short-window appreciation can reverse sharply.",
            "This setup is flagged for caution rather than continuation.",
          ],
          "caution",
        ),
      );

      continue;
    }

    if (
      token.activityScore >= 60 &&
      token.liquidityUsd < 10_000
    ) {
      calls.push(
        buildCall(
          token,
          "thin-liquidity",
          "Thin Liquidity Activity",
          clamp(base - 10, 0, 100),
          [
            `Activity score is ${token.activityScore}.`,
            `5m volume is $${Math.round(
              token.volume.m5,
            ).toLocaleString("en-US")}.`,
          ],
          [
            `Liquidity is only $${Math.round(
              token.liquidityUsd,
            ).toLocaleString("en-US")}.`,
            "Thin liquidity can amplify slippage and abrupt price moves.",
          ],
          "caution",
        ),
      );
    }
  }

  return calls.sort((a, b) => {
    if (a.direction !== b.direction) {
      return a.direction === "watch" ? -1 : 1;
    }

    return b.signalScore - a.signalScore;
  });
}