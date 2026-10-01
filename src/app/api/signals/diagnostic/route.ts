import {
  NextResponse,
} from "next/server";

import {
  generateSignals,
} from "@/lib/signal-engine";
import {
  getSignalEngineSettings,
} from "@/lib/signal-engine-settings";
import type {
  SignalSettings,
} from "@/lib/signal-types";
import type {
  TerminalToken,
} from "@/lib/terminal-types";

type FailureKey =
  | "price"
  | "marketCap"
  | "pairAgeMissing"
  | "pairAgeTooYoung"
  | "pairAgeTooOld"
  | "liquidity"
  | "volume5m"
  | "transactions5m"
  | "buyShareMissing"
  | "buyShareLow"
  | "buyShareHigh"
  | "volumeSpikeMissing"
  | "volumeSpikeLow"
  | "volumeSpikeHigh"
  | "momentum5mMissing"
  | "momentum5mLow"
  | "momentum5mHigh"
  | "momentum1hMissing"
  | "momentum1hLow"
  | "momentum1hHigh"
  | "liquidityValuationMissing"
  | "liquidityValuationLow"
  | "limitedConfidence"
  | "score";

type FailureDetail = {
  key: FailureKey;
  actual: number | string | null;
  required: string;
};

function secretValue() {
  return process.env.CRON_SECRET?.trim() ?? "";
}

function authorized(request: Request) {
  const secret = secretValue();
  const authorization = request.headers.get("authorization")?.trim();
  const memeScopeCron = request.headers.get("x-memescope-cron")?.trim();

  return Boolean(
    secret &&
      (
        authorization === `Bearer ${secret}` ||
        memeScopeCron === secret
      ),
  );
}

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function buyShareFor(token: TerminalToken) {
  const buys = token.txns.m5.buys;
  const sells = token.txns.m5.sells;
  const total = buys + sells;
  return total > 0 ? buys / total : null;
}

function confidenceFor(token: TerminalToken) {
  let complete = 0;
  if (token.priceUsd !== null) complete += 1;
  if (token.marketCap !== null || token.fdv !== null) complete += 1;
  if (token.liquidityUsd > 0) complete += 1;
  if (token.volume.m5 > 0) complete += 1;
  if (token.pairAgeMinutes !== null) complete += 1;
  if (token.volumeSpike5m !== null) complete += 1;
  if (token.priceChange.h1 !== null) complete += 1;

  if (complete >= 7) return "high" as const;
  if (complete >= 5) return "medium" as const;
  return "limited" as const;
}

function liquidityRatioFor(token: TerminalToken) {
  const marketCap = token.marketCap ?? token.fdv;
  if (marketCap === null || marketCap <= 0) return null;
  return token.liquidityUsd / marketCap;
}

function qualityScore(
  token: TerminalToken,
  buyShare: number,
  spike: number,
  change5m: number,
  change1h: number,
) {
  const txns5m = token.txns.m5.buys + token.txns.m5.sells;
  const liqRatio = liquidityRatioFor(token) ?? 0;
  const ageMinutes = token.pairAgeMinutes ?? Number.POSITIVE_INFINITY;
  let score = 0;

  if (token.liquidityUsd >= 250_000) score += 15;
  else if (token.liquidityUsd >= 150_000) score += 13;
  else if (token.liquidityUsd >= 100_000) score += 11;
  else if (token.liquidityUsd >= 75_000) score += 9;
  else score += 7;

  if (token.volume.m5 >= 75_000) score += 10;
  else if (token.volume.m5 >= 40_000) score += 9;
  else if (token.volume.m5 >= 25_000) score += 8;
  else if (token.volume.m5 >= 15_000) score += 7;
  else score += 5;

  if (txns5m >= 250) score += 10;
  else if (txns5m >= 150) score += 9;
  else if (txns5m >= 100) score += 8;
  else if (txns5m >= 70) score += 7;
  else score += 5;

  if (buyShare >= 0.68 && buyShare <= 0.80) score += 15;
  else if (buyShare >= 0.64 && buyShare <= 0.84) score += 13;
  else if (buyShare >= 0.60 && buyShare <= 0.88) score += 10;

  if (spike >= 1.7 && spike <= 2.5) score += 15;
  else if (spike >= 1.45 && spike <= 3.0) score += 13;
  else if (spike >= 1.3 && spike <= 3.5) score += 10;

  if (change5m >= 4 && change5m <= 9) score += 15;
  else if (change5m >= 2 && change5m <= 12) score += 12;
  else if (change5m > 12 && change5m <= 15) score += 8;

  if (change1h >= 0 && change1h <= 40) score += 8;
  else if (change1h > 40 && change1h <= 80) score += 6;
  else if (change1h > 80 && change1h <= 120) score += 3;
  else if (change1h >= -5 && change1h < 0) score += 4;

  if (liqRatio >= 0.20) score += 7;
  else if (liqRatio >= 0.15) score += 6;
  else if (liqRatio >= 0.10) score += 5;
  else if (liqRatio >= 0.08) score += 4;

  if (ageMinutes >= 20 && ageMinutes <= 360) score += 3;
  else if (ageMinutes >= 10 && ageMinutes <= 720) score += 2;
  else score += 1;

  score += clamp(token.activityScore / 35, 0, 2);
  return Math.round(clamp(score, 0, 100));
}

function evaluate(
  token: TerminalToken,
  settings: Required<SignalSettings>,
) {
  const failures: FailureDetail[] = [];
  const marketCap = token.marketCap ?? token.fdv;
  const age = token.pairAgeMinutes;
  const txns5m = token.txns.m5.buys + token.txns.m5.sells;
  const buyShare = buyShareFor(token);
  const spike = token.volumeSpike5m;
  const change5m = token.priceChange.m5;
  const change1h = token.priceChange.h1;
  const liqRatio = liquidityRatioFor(token);
  const confidence = confidenceFor(token);

  if (token.priceUsd === null || token.priceUsd <= 0) {
    failures.push({ key: "price", actual: token.priceUsd, required: "> 0" });
  }
  if (marketCap === null || marketCap <= 0) {
    failures.push({ key: "marketCap", actual: marketCap, required: "> 0" });
  }
  if (age === null) {
    failures.push({ key: "pairAgeMissing", actual: null, required: "known" });
  } else {
    if (age < settings.minPairAgeMinutes) {
      failures.push({ key: "pairAgeTooYoung", actual: age, required: `>= ${settings.minPairAgeMinutes}m` });
    }
    if (age > settings.maxPairAgeHours * 60) {
      failures.push({ key: "pairAgeTooOld", actual: age, required: `<= ${settings.maxPairAgeHours}h` });
    }
  }
  if (token.liquidityUsd < settings.minLiquidityUsd) {
    failures.push({ key: "liquidity", actual: token.liquidityUsd, required: `>= ${settings.minLiquidityUsd}` });
  }
  if (token.volume.m5 < settings.minVolume5mUsd) {
    failures.push({ key: "volume5m", actual: token.volume.m5, required: `>= ${settings.minVolume5mUsd}` });
  }
  if (txns5m < settings.minTransactions5m) {
    failures.push({ key: "transactions5m", actual: txns5m, required: `>= ${settings.minTransactions5m}` });
  }
  if (buyShare === null) {
    failures.push({ key: "buyShareMissing", actual: null, required: "known" });
  } else {
    if (buyShare < settings.minBuyShare) {
      failures.push({ key: "buyShareLow", actual: Number(buyShare.toFixed(4)), required: `>= ${settings.minBuyShare}` });
    }
    if (buyShare > settings.maxBuyShare) {
      failures.push({ key: "buyShareHigh", actual: Number(buyShare.toFixed(4)), required: `<= ${settings.maxBuyShare}` });
    }
  }
  if (spike === null) {
    failures.push({ key: "volumeSpikeMissing", actual: null, required: "known" });
  } else {
    if (spike < settings.minVolumeSpike) {
      failures.push({ key: "volumeSpikeLow", actual: spike, required: `>= ${settings.minVolumeSpike}` });
    }
    if (spike > settings.maxVolumeSpike) {
      failures.push({ key: "volumeSpikeHigh", actual: spike, required: `<= ${settings.maxVolumeSpike}` });
    }
  }
  if (change5m === null) {
    failures.push({ key: "momentum5mMissing", actual: null, required: "known" });
  } else {
    if (change5m < settings.minMomentum5m) {
      failures.push({ key: "momentum5mLow", actual: change5m, required: `>= ${settings.minMomentum5m}%` });
    }
    if (change5m > settings.maxMomentum5m) {
      failures.push({ key: "momentum5mHigh", actual: change5m, required: `<= ${settings.maxMomentum5m}%` });
    }
  }
  if (change1h === null) {
    failures.push({ key: "momentum1hMissing", actual: null, required: "known" });
  } else {
    if (change1h < settings.minMomentum1h) {
      failures.push({ key: "momentum1hLow", actual: change1h, required: `>= ${settings.minMomentum1h}%` });
    }
    if (change1h > settings.maxMomentum1h) {
      failures.push({ key: "momentum1hHigh", actual: change1h, required: `<= ${settings.maxMomentum1h}%` });
    }
  }
  if (liqRatio === null) {
    failures.push({ key: "liquidityValuationMissing", actual: null, required: "known" });
  } else if (liqRatio < settings.minLiquidityValuationRatio) {
    failures.push({ key: "liquidityValuationLow", actual: Number(liqRatio.toFixed(5)), required: `>= ${settings.minLiquidityValuationRatio}` });
  }
  if (confidence === "limited") {
    failures.push({ key: "limitedConfidence", actual: confidence, required: "medium/high" });
  }

  let score: number | null = null;
  if (
    buyShare !== null &&
    spike !== null &&
    change5m !== null &&
    change1h !== null
  ) {
    score = qualityScore(token, buyShare, spike, change5m, change1h);
    if (score < settings.minSignalScore) {
      failures.push({ key: "score", actual: score, required: `>= ${settings.minSignalScore}` });
    }
  }

  return {
    failures,
    score,
    marketCap,
    age,
    txns5m,
    buyShare,
    spike,
    change5m,
    change1h,
    liqRatio,
    confidence,
  };
}

const CORE_FAILURES = new Set<FailureKey>([
  "price",
  "marketCap",
  "pairAgeMissing",
  "pairAgeTooYoung",
  "pairAgeTooOld",
  "liquidity",
  "volume5m",
  "transactions5m",
]);

export async function GET(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({ ok: false, error: "Unauthorized." }, { status: 401 });
  }

  try {
    const origin = new URL(request.url).origin;
    const response = await fetch(`${origin}/api/terminal/solana`, {
      cache: "no-store",
    });
    const body = (await response.json()) as {
      tokens?: TerminalToken[];
      error?: string;
    };

    if (!response.ok || !Array.isArray(body.tokens)) {
      throw new Error(body.error ?? "Terminal feed failed.");
    }

    const settings = await getSignalEngineSettings();
    const tokens = body.tokens;
    const signals = generateSignals(tokens, settings);
    const passedAddresses = new Set(signals.map((signal) => signal.tokenAddress));

    const allFailureCounts: Record<string, number> = {};
    const firstFailureCounts: Record<string, number> = {};
    let corePassCount = 0;
    let softOnlyRejectedCount = 0;

    const rows = tokens.map((token) => {
      const result = evaluate(token, settings);
      for (const failure of result.failures) {
        allFailureCounts[failure.key] = (allFailureCounts[failure.key] ?? 0) + 1;
      }
      const first = result.failures[0]?.key;
      if (first) firstFailureCounts[first] = (firstFailureCounts[first] ?? 0) + 1;

      const coreFailures = result.failures.filter((failure) => CORE_FAILURES.has(failure.key));
      if (coreFailures.length === 0) corePassCount += 1;
      if (
        coreFailures.length === 0 &&
        result.failures.length > 0 &&
        !passedAddresses.has(token.address)
      ) {
        softOnlyRejectedCount += 1;
      }

      return {
        symbol: token.symbol,
        address: token.address,
        enginePass: passedAddresses.has(token.address),
        failureCount: result.failures.length,
        failures: result.failures,
        score: result.score,
        metrics: {
          ageMinutes: result.age,
          liquidityUsd: token.liquidityUsd,
          marketCap: result.marketCap,
          volume5mUsd: token.volume.m5,
          transactions5m: result.txns5m,
          buyShare: result.buyShare === null ? null : Number(result.buyShare.toFixed(4)),
          volumeSpike: result.spike,
          momentum5m: result.change5m,
          momentum1h: result.change1h,
          liquidityValuationRatio:
            result.liqRatio === null ? null : Number(result.liqRatio.toFixed(5)),
          confidence: result.confidence,
        },
      };
    });

    const nearMisses = rows
      .filter((row) => !row.enginePass && row.failureCount > 0)
      .sort((a, b) => {
        if (a.failureCount !== b.failureCount) return a.failureCount - b.failureCount;
        return (b.score ?? -1) - (a.score ?? -1);
      })
      .slice(0, 15);

    const passing = rows
      .filter((row) => row.enginePass)
      .sort((a, b) => (b.score ?? -1) - (a.score ?? -1))
      .slice(0, 15);

    return NextResponse.json({
      ok: true,
      diagnosticOnly: true,
      generatedAt: Date.now(),
      scanned: tokens.length,
      passedByEngine: signals.length,
      rejectedByEngine: Math.max(0, tokens.length - signals.length),
      corePassCount,
      softOnlyRejectedCount,
      settings,
      firstFailureCounts,
      allFailureCounts,
      passing,
      nearMisses,
      note:
        "Read-only diagnostic. Failure counts can overlap because one token may fail multiple gates. firstFailureCounts follows the engine hard-gate order.",
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        diagnosticOnly: true,
        error: error instanceof Error ? error.message : "Signal diagnostic failed.",
      },
      { status: 500 },
    );
  }
}
