import type { SignalCall } from "@/lib/signal-types";

export type SignalExitMode = "dynamic" | "fixed";
export type SignalTradingStyle =
  | "conservative"
  | "balanced"
  | "aggressive";

export type SignalExitSettings = {
  mode: SignalExitMode;
  style: SignalTradingStyle;
  fixedTargetPercent: number;
  fixedStopLossPercent: number;
};

export type SignalExitPlan = {
  mode: SignalExitMode;
  style: SignalTradingStyle;
  targetPercent: number;
  stopLossPercent: number;
  reason: string;
};

export const DEFAULT_SIGNAL_EXIT_SETTINGS: SignalExitSettings = {
  mode: "dynamic",
  style: "balanced",
  fixedTargetPercent: 30,
  fixedStopLossPercent: 15,
};

function clamp(value: number, min: number, max: number) {
  return Math.max(min, Math.min(max, value));
}

function half(value: number) {
  return Math.round(value * 2) / 2;
}

function liquidityLabel(value: number) {
  if (value >= 1_000_000) return `$${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `$${(value / 1_000).toFixed(0)}K`;
  return `$${value.toFixed(0)}`;
}

function ageLabel(minutes: number | null) {
  if (minutes === null) return "unknown age";
  if (minutes < 60) return `${Math.max(1, Math.round(minutes))}m old`;
  if (minutes < 1440) return `${(minutes / 60).toFixed(1)}h old`;
  return `${(minutes / 1440).toFixed(1)}d old`;
}

export function normalizeSignalExitSettings(
  input: Partial<SignalExitSettings>,
): SignalExitSettings {
  const mode: SignalExitMode =
    input.mode === "fixed" ? "fixed" : "dynamic";

  const style: SignalTradingStyle =
    input.style === "conservative" || input.style === "aggressive"
      ? input.style
      : "balanced";

  return {
    mode,
    style,
    fixedTargetPercent: half(
      clamp(
        Number(input.fixedTargetPercent) ||
          DEFAULT_SIGNAL_EXIT_SETTINGS.fixedTargetPercent,
        1,
        500,
      ),
    ),
    fixedStopLossPercent: half(
      clamp(
        Number(input.fixedStopLossPercent) ||
          DEFAULT_SIGNAL_EXIT_SETTINGS.fixedStopLossPercent,
        1,
        95,
      ),
    ),
  };
}

export function buildSignalExitPlan(
  signal: SignalCall,
  rawSettings: SignalExitSettings,
): SignalExitPlan {
  const settings = normalizeSignalExitSettings(rawSettings);

  if (settings.mode === "fixed") {
    return {
      mode: "fixed",
      style: settings.style,
      targetPercent: settings.fixedTargetPercent,
      stopLossPercent: settings.fixedStopLossPercent,
      reason:
        `Fixed user plan: +${settings.fixedTargetPercent}% TP and ` +
        `-${settings.fixedStopLossPercent}% SL.`,
    };
  }

  const profiles = {
    conservative: {
      tpBase: 18,
      slBase: 9,
      tpMin: 12,
      tpMax: 42,
      slMin: 7,
      slMax: 15,
    },
    balanced: {
      tpBase: 28,
      slBase: 13,
      tpMin: 18,
      tpMax: 70,
      slMin: 9,
      slMax: 22,
    },
    aggressive: {
      tpBase: 42,
      slBase: 18,
      tpMin: 28,
      tpMax: 120,
      slMin: 12,
      slMax: 35,
    },
  } as const;

  const p = profiles[settings.style];

  const move5m = Math.abs(signal.priceChange5m ?? 0);
  const normalized1h = Math.abs(signal.priceChange1h ?? 0) / 4;
  const volatility = clamp(Math.max(move5m, normalized1h), 0, 30);

  const spike = clamp(signal.volumeSpike5m ?? 1, 0.5, 5);
  const spikeBoost = Math.max(0, spike - 1);

  const scoreBoost = clamp((signal.signalScore - 55) / 20, 0, 1.5);

  const buyShare = signal.buyShare5m ?? 0.5;
  const buyBoost = clamp((buyShare - 0.5) * 10, 0, 1.5);

  let earlyTp = 0;
  let earlySl = 0;

  if (signal.pairAgeMinutes !== null && signal.pairAgeMinutes < 60) {
    earlyTp = 6;
    earlySl = 2.5;
  } else if (
    signal.pairAgeMinutes !== null &&
    signal.pairAgeMinutes < 360
  ) {
    earlyTp = 3;
    earlySl = 1.5;
  }

  let liqSl = 0;
  let liqTpPenalty = 0;

  if (signal.liquidityUsd < 10_000) {
    liqSl = 5;
    liqTpPenalty = 5;
  } else if (signal.liquidityUsd < 20_000) {
    liqSl = 3;
    liqTpPenalty = 3;
  } else if (signal.liquidityUsd < 50_000) {
    liqSl = 1.5;
  }

  const confidencePenalty =
    signal.confidence === "limited"
      ? 4
      : signal.confidence === "medium"
        ? 1.5
        : 0;

  let tp =
    p.tpBase +
    volatility * 0.7 +
    spikeBoost * 5 +
    scoreBoost * 4 +
    buyBoost * 4 +
    earlyTp -
    liqTpPenalty -
    confidencePenalty;

  let sl =
    p.slBase +
    volatility * 0.28 +
    liqSl +
    earlySl +
    (signal.confidence === "limited" ? 2 : 0);

  sl = clamp(sl, p.slMin, p.slMax);
  tp = clamp(tp, p.tpMin, p.tpMax);

  // Keep a minimum reward/risk separation in the heuristic.
  tp = Math.max(tp, sl * 1.5);
  tp = clamp(tp, p.tpMin, p.tpMax);

  tp = half(tp);
  sl = half(sl);

  return {
    mode: "dynamic",
    style: settings.style,
    targetPercent: tp,
    stopLossPercent: sl,
    reason:
      `${settings.style} dynamic plan: volatility ${volatility.toFixed(1)}%, ` +
      `volume spike ${spike.toFixed(2)}x, score ${signal.signalScore}, ` +
      `buy share ${Math.round(buyShare * 100)}%, liquidity ` +
      `${liquidityLabel(signal.liquidityUsd)}, ${ageLabel(signal.pairAgeMinutes)}, ` +
      `confidence ${signal.confidence}.`,
  };
}
