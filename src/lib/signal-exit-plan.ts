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

export function normalizeSignalExitSettings(
  input: Partial<SignalExitSettings>,
): SignalExitSettings {
  const style: SignalTradingStyle =
    input.style === "conservative" ||
    input.style === "aggressive"
      ? input.style
      : "balanced";

  return {
    // Stage 16 always uses analysis-based dynamic TP.
    mode: "dynamic",
    style,
    fixedTargetPercent: half(
      clamp(
        Number(input.fixedTargetPercent) ||
          DEFAULT_SIGNAL_EXIT_SETTINGS.fixedTargetPercent,
        1,
        500,
      ),
    ),
    // Kept only for backward compatibility with the existing settings API/schema.
    // It is ignored by the Stage 16 recorder lifecycle.
    fixedStopLossPercent:
      DEFAULT_SIGNAL_EXIT_SETTINGS.fixedStopLossPercent,
  };
}

export function buildSignalExitPlan(
  signal: SignalCall,
  rawSettings: SignalExitSettings,
): SignalExitPlan {
  const settings =
    normalizeSignalExitSettings(
      rawSettings,
    );

  const target =
    half(
      clamp(
        Number(
          signal.potentialTargetPercent,
        ) || 25,
        10,
        100,
      ),
    );

  return {
    mode: "dynamic",
    style: settings.style,
    targetPercent: target,
    // Database column remains for backward compatibility only.
    // New Stage 16 records are never closed by this value.
    stopLossPercent: 0,
    reason:
      signal.potentialTargetReason ||
      `Stage 16 analysis-based potential TP: +${target.toFixed(1)}%.`,
  };
}
