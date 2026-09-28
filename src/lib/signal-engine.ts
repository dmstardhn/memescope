import type {
  SignalCall,
  SignalConfidence,
  SignalKind,
} from "@/lib/signal-types";
import type { TerminalToken } from "@/lib/terminal-types";

const HIGH_QUALITY_MIN_SCORE = 80;

function clamp(
  value: number,
  min: number,
  max: number,
) {
  return Math.max(min, Math.min(max, value));
}

function half(value: number) {
  return Math.round(value * 2) / 2;
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
  if (token.marketCap !== null || token.fdv !== null) complete += 1;
  if (token.liquidityUsd > 0) complete += 1;
  if (token.volume.m5 > 0) complete += 1;
  if (token.pairAgeMinutes !== null) complete += 1;
  if (token.volumeSpike5m !== null) complete += 1;
  if (token.priceChange.h1 !== null) complete += 1;

  if (complete >= 7) return "high";
  if (complete >= 5) return "medium";
  return "limited";
}

function liquidityToMarketCap(token: TerminalToken) {
  const marketCap = token.marketCap ?? token.fdv;

  if (
    marketCap === null ||
    marketCap <= 0
  ) {
    return null;
  }

  return token.liquidityUsd / marketCap;
}

function qualityScore(
  token: TerminalToken,
  buyShare: number,
  spike: number,
  change5m: number,
  change1h: number,
) {
  const txns5m =
    token.txns.m5.buys +
    token.txns.m5.sells;

  const liqRatio =
    liquidityToMarketCap(token) ?? 0;

  const ageMinutes =
    token.pairAgeMinutes ??
    Number.POSITIVE_INFINITY;

  let score = 0;

  // Liquidity depth: max 15.
  if (token.liquidityUsd >= 250_000) score += 15;
  else if (token.liquidityUsd >= 150_000) score += 13;
  else if (token.liquidityUsd >= 100_000) score += 11;
  else if (token.liquidityUsd >= 75_000) score += 9;
  else score += 7;

  // Current volume: max 10.
  if (token.volume.m5 >= 75_000) score += 10;
  else if (token.volume.m5 >= 40_000) score += 9;
  else if (token.volume.m5 >= 25_000) score += 8;
  else if (token.volume.m5 >= 15_000) score += 7;
  else score += 5;

  // Transaction participation: max 10.
  if (txns5m >= 250) score += 10;
  else if (txns5m >= 150) score += 9;
  else if (txns5m >= 100) score += 8;
  else if (txns5m >= 70) score += 7;
  else score += 5;

  // Buy pressure: max 15. Extremely one-sided flow gets no extra bonus.
  if (buyShare >= 0.68 && buyShare <= 0.80) score += 15;
  else if (buyShare >= 0.64 && buyShare <= 0.84) score += 13;
  else if (buyShare >= 0.60 && buyShare <= 0.88) score += 10;

  // Volume acceleration: max 15. Extreme spikes are intentionally not rewarded.
  if (spike >= 1.7 && spike <= 2.5) score += 15;
  else if (spike >= 1.45 && spike <= 3.0) score += 13;
  else if (spike >= 1.3 && spike <= 3.5) score += 10;

  // 5m price structure: max 15. Best zone is constructive, not parabolic.
  if (change5m >= 4 && change5m <= 9) score += 15;
  else if (change5m >= 2 && change5m <= 12) score += 12;
  else if (change5m > 12 && change5m <= 15) score += 8;

  // 1h structure: max 8. Already-parabolic moves receive less credit.
  if (change1h >= 0 && change1h <= 40) score += 8;
  else if (change1h > 40 && change1h <= 80) score += 6;
  else if (change1h > 80 && change1h <= 120) score += 3;
  else if (change1h >= -5 && change1h < 0) score += 4;

  // Pool depth relative to valuation: max 7.
  if (liqRatio >= 0.20) score += 7;
  else if (liqRatio >= 0.15) score += 6;
  else if (liqRatio >= 0.10) score += 5;
  else if (liqRatio >= 0.08) score += 4;

  // Pair age: max 3.
  if (ageMinutes >= 20 && ageMinutes <= 360) score += 3;
  else if (ageMinutes >= 10 && ageMinutes <= 720) score += 2;
  else score += 1;

  // Existing activity score contributes only a small final weight.
  score += clamp(token.activityScore / 35, 0, 2);

  return Math.round(clamp(score, 0, 100));
}

function potentialTarget(
  token: TerminalToken,
  score: number,
  buyShare: number,
  spike: number,
  change5m: number,
  change1h: number,
) {
  const ageMinutes =
    token.pairAgeMinutes ?? 1_440;

  let target = 15;

  target += clamp(
    (score - HIGH_QUALITY_MIN_SCORE) * 0.7,
    0,
    14,
  );

  target += clamp(
    change5m * 0.7,
    0,
    10.5,
  );

  target += clamp(
    Math.max(0, change1h) * 0.12,
    0,
    7.2,
  );

  target += clamp(
    (spike - 1.3) * 5,
    0,
    11,
  );

  target += clamp(
    (buyShare - 0.60) * 40,
    0,
    10,
  );

  if (token.liquidityUsd >= 250_000) target += 6;
  else if (token.liquidityUsd >= 100_000) target += 3;

  if (ageMinutes < 120) target += 5;
  else if (ageMinutes < 360) target += 3;

  // Do not extrapolate an already-extended move into a huge target.
  if (change1h > 80) target -= 8;
  if (change5m > 12) target -= 5;

  return half(
    clamp(target, 18, 70),
  );
}

function buildCall(
  token: TerminalToken,
  kind: SignalKind,
  label: string,
  score: number,
  buyShare: number,
  spike: number,
  change5m: number,
  change1h: number,
  reasons: string[],
): SignalCall {
  const target =
    potentialTarget(
      token,
      score,
      buyShare,
      spike,
      change5m,
      change1h,
    );

  return {
    id: `${token.address}-${kind}-hq16`,
    tokenAddress: token.address,
    symbol: token.symbol,
    name: token.name,
    imageUrl: token.imageUrl,

    kind,
    direction: "watch",
    label,

    signalScore: score,
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
    buyShare5m: buyShare,
    volumeSpike5m: token.volumeSpike5m,
    pairAgeMinutes: token.pairAgeMinutes,

    activityScore: token.activityScore,

    potentialTargetPercent: target,
    potentialTargetReason:
      `Estimated upside potential +${target.toFixed(1)}% from the confirmed entry snapshot, ` +
      `based on quality score ${score}, ${Math.round(buyShare * 100)}% buy share, ` +
      `${spike.toFixed(2)}x volume acceleration, liquidity depth, pair age, and 5m/1h structure.`,

    reasons,
    caution: [
      "Potential TP is a heuristic estimate from the entry snapshot, not a guaranteed price objective.",
      "High-quality market structure does not by itself verify mint authority, holder concentration, or other on-chain contract risks.",
    ],
    dexUrl: token.dexUrl,
  };
}

export function generateSignals(
  tokens: TerminalToken[],
): SignalCall[] {
  const calls: SignalCall[] = [];

  for (const token of tokens) {
    const buyShare = getBuyShare(token);
    const spike = token.volumeSpike5m;
    const change5m = token.priceChange.m5;
    const change1h = token.priceChange.h1;
    const ageMinutes = token.pairAgeMinutes;
    const marketCap = token.marketCap ?? token.fdv;
    const liqRatio = liquidityToMarketCap(token);

    const txns5m =
      token.txns.m5.buys +
      token.txns.m5.sells;

    // Stage 16 hard-quality gate.
    // Volume spikes alone never create a signal.
    if (
      token.priceUsd === null ||
      token.priceUsd <= 0 ||
      marketCap === null ||
      marketCap <= 0 ||
      ageMinutes === null ||
      ageMinutes < 10 ||
      ageMinutes > 1_440 ||
      token.liquidityUsd < 50_000 ||
      token.volume.m5 < 10_000 ||
      txns5m < 40 ||
      buyShare === null ||
      buyShare < 0.60 ||
      buyShare > 0.88 ||
      spike === null ||
      spike < 1.3 ||
      spike > 3.5 ||
      change5m === null ||
      change5m < 2 ||
      change5m > 15 ||
      change1h === null ||
      change1h < -5 ||
      change1h > 120 ||
      liqRatio === null ||
      liqRatio < 0.08 ||
      confidenceFor(token) === "limited"
    ) {
      continue;
    }

    const score =
      qualityScore(
        token,
        buyShare,
        spike,
        change5m,
        change1h,
      );

    if (
      score <
      HIGH_QUALITY_MIN_SCORE
    ) {
      continue;
    }

    const kind: SignalKind =
      ageMinutes <= 180
        ? "early-momentum"
        : "momentum";

    const label =
      ageMinutes <= 180
        ? "High Quality Early Momentum"
        : "High Quality Momentum";

    calls.push(
      buildCall(
        token,
        kind,
        label,
        score,
        buyShare,
        spike,
        change5m,
        change1h,
        [
          `Quality score is ${score}/100 after hard filtering.`,
          `Buy share is ${Math.round(
            buyShare * 100,
          )}% across ${txns5m} transactions in 5m.`,
          `5m volume is $${Math.round(
            token.volume.m5,
          ).toLocaleString("en-US")} at ${spike.toFixed(
            2,
          )}x the recent 1h average 5m pace.`,
          `Liquidity is $${Math.round(
            token.liquidityUsd,
          ).toLocaleString("en-US")} and liquidity/valuation is ${(
            liqRatio * 100
          ).toFixed(1)}%.`,
          `Momentum is +${change5m.toFixed(
            1,
          )}% over 5m and ${change1h >= 0 ? "+" : ""}${change1h.toFixed(
            1,
          )}% over 1h.`,
          "The setup must also remain present for two consecutive scans before the UI confirms it.",
        ],
      ),
    );
  }

  return calls.sort(
    (a, b) =>
      b.signalScore -
      a.signalScore,
  );
}
