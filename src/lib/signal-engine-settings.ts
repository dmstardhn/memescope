import "server-only";

import {
  neon,
} from "@neondatabase/serverless";

import {
  DEFAULT_SIGNAL_SETTINGS,
  normalizeSignalSettings,
} from "@/lib/signal-engine";
import type {
  SignalSettings,
} from "@/lib/signal-types";

export type SignalPresetName =
  | "aggressive"
  | "balanced"
  | "strict"
  | "ultra"
  | "moonshot";

export type SignalEngineSettings =
  Required<SignalSettings> & {
    confirmationScans: number;
  };

function profile(
  values: SignalEngineSettings,
) {
  return values;
}

export const SIGNAL_PRESETS: Record<
  SignalPresetName,
  SignalEngineSettings
> = {
  // "strict" is retained internally for backwards compatibility.
  // The Telegram UI presents it as SAFE.
  strict: profile({
    minSignalScore: 88,
    minLiquidityUsd: 100_000,
    minPairAgeMinutes: 10,
    maxPairAgeHours: 12,
    minVolume5mUsd: 12_000,
    minTransactions5m: 50,
    minBuyShare: 0.62,
    maxBuyShare: 0.86,
    minVolumeSpike: 1.40,
    maxVolumeSpike: 3.20,
    minMomentum5m: 2.5,
    maxMomentum5m: 12,
    minMomentum1h: -3,
    maxMomentum1h: 100,
    minLiquidityValuationRatio: 0.10,
    confirmationScans: 2,
  }),
  balanced: profile({
    minSignalScore: 80,
    minLiquidityUsd: 50_000,
    minPairAgeMinutes: 10,
    maxPairAgeHours: 24,
    minVolume5mUsd: 10_000,
    minTransactions5m: 40,
    minBuyShare: 0.60,
    maxBuyShare: 0.88,
    minVolumeSpike: 1.30,
    maxVolumeSpike: 3.50,
    minMomentum5m: 2,
    maxMomentum5m: 15,
    minMomentum1h: -5,
    maxMomentum1h: 120,
    minLiquidityValuationRatio: 0.08,
    confirmationScans: 1,
  }),
  aggressive: profile({
    minSignalScore: 62,
    minLiquidityUsd: 25_000,
    minPairAgeMinutes: 5,
    maxPairAgeHours: 48,
    minVolume5mUsd: 7_000,
    minTransactions5m: 28,
    minBuyShare: 0.57,
    maxBuyShare: 0.91,
    minVolumeSpike: 1.18,
    maxVolumeSpike: 4.20,
    minMomentum5m: 1.0,
    maxMomentum5m: 18,
    minMomentum1h: -8,
    maxMomentum1h: 150,
    minLiquidityValuationRatio: 0.055,
    confirmationScans: 1,
  }),
  ultra: profile({
    minSignalScore: 52,
    minLiquidityUsd: 15_000,
    minPairAgeMinutes: 3,
    maxPairAgeHours: 72,
    minVolume5mUsd: 4_000,
    minTransactions5m: 18,
    minBuyShare: 0.54,
    maxBuyShare: 0.94,
    minVolumeSpike: 1.08,
    maxVolumeSpike: 5.00,
    minMomentum5m: 0.4,
    maxMomentum5m: 24,
    minMomentum1h: -12,
    maxMomentum1h: 200,
    minLiquidityValuationRatio: 0.035,
    confirmationScans: 1,
  }),
  moonshot: profile({
    minSignalScore: 40,
    minLiquidityUsd: 5_000,
    minPairAgeMinutes: 1,
    maxPairAgeHours: 24,
    minVolume5mUsd: 1_000,
    minTransactions5m: 5,
    minBuyShare: 0.50,
    maxBuyShare: 0.98,
    minVolumeSpike: 0.80,
    maxVolumeSpike: 8.00,
    minMomentum5m: -0.5,
    maxMomentum5m: 40,
    minMomentum1h: -25,
    maxMomentum1h: 350,
    minLiquidityValuationRatio: 0.01,
    confirmationScans: 1,
  }),
};

export const DEFAULT_SIGNAL_ENGINE_SETTINGS:
  SignalEngineSettings = {
    ...DEFAULT_SIGNAL_SETTINGS,
    confirmationScans: 1,
  };

let schemaPromise:
  | Promise<void>
  | null = null;

function sqlClient() {
  const databaseUrl =
    process.env.DATABASE_URL?.trim();

  if (!databaseUrl) {
    throw new Error(
      "DATABASE_URL is not configured.",
    );
  }

  return neon(databaseUrl);
}

function num(
  value: unknown,
  fallback: number,
) {
  const parsed =
    Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

function normalizeEngineSettings(
  input?: Partial<
    SignalEngineSettings
  >,
): SignalEngineSettings {
  const base =
    normalizeSignalSettings(
      input,
    );

  const confirmationScans =
    Math.max(
      1,
      Math.min(
        4,
        Math.round(
          Number(
            input?.confirmationScans,
          ) ||
            DEFAULT_SIGNAL_ENGINE_SETTINGS
              .confirmationScans,
        ),
      ),
    );

  return {
    ...base,
    confirmationScans,
  };
}

export async function ensureSignalEngineSettingsSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise = (async () => {
    const sql =
      sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_engine_settings (
        id INTEGER PRIMARY KEY,
        min_signal_score INTEGER NOT NULL DEFAULT 80,
        min_liquidity_usd DOUBLE PRECISION NOT NULL DEFAULT 50000,
        min_pair_age_minutes INTEGER NOT NULL DEFAULT 10,
        max_pair_age_hours INTEGER NOT NULL DEFAULT 24,
        min_volume_5m_usd DOUBLE PRECISION NOT NULL DEFAULT 10000,
        min_transactions_5m INTEGER NOT NULL DEFAULT 40,
        min_buy_share DOUBLE PRECISION NOT NULL DEFAULT 0.60,
        max_buy_share DOUBLE PRECISION NOT NULL DEFAULT 0.88,
        min_volume_spike DOUBLE PRECISION NOT NULL DEFAULT 1.30,
        max_volume_spike DOUBLE PRECISION NOT NULL DEFAULT 3.50,
        min_momentum_5m DOUBLE PRECISION NOT NULL DEFAULT 2,
        max_momentum_5m DOUBLE PRECISION NOT NULL DEFAULT 15,
        min_momentum_1h DOUBLE PRECISION NOT NULL DEFAULT -5,
        max_momentum_1h DOUBLE PRECISION NOT NULL DEFAULT 120,
        min_liquidity_valuation_ratio DOUBLE PRECISION NOT NULL DEFAULT 0.08,
        confirmation_scans INTEGER NOT NULL DEFAULT 1,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_pair_age_minutes INTEGER NOT NULL DEFAULT 10
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_volume_5m_usd DOUBLE PRECISION NOT NULL DEFAULT 10000
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_transactions_5m INTEGER NOT NULL DEFAULT 40
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_buy_share DOUBLE PRECISION NOT NULL DEFAULT 0.60
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS max_buy_share DOUBLE PRECISION NOT NULL DEFAULT 0.88
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_volume_spike DOUBLE PRECISION NOT NULL DEFAULT 1.30
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS max_volume_spike DOUBLE PRECISION NOT NULL DEFAULT 3.50
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_momentum_5m DOUBLE PRECISION NOT NULL DEFAULT 2
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS max_momentum_5m DOUBLE PRECISION NOT NULL DEFAULT 15
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_momentum_1h DOUBLE PRECISION NOT NULL DEFAULT -5
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS max_momentum_1h DOUBLE PRECISION NOT NULL DEFAULT 120
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS min_liquidity_valuation_ratio DOUBLE PRECISION NOT NULL DEFAULT 0.08
    `;
    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS confirmation_scans INTEGER NOT NULL DEFAULT 1
    `;

    await sql`
      INSERT INTO memescope_signal_engine_settings (
        id,
        min_signal_score,
        min_liquidity_usd,
        min_pair_age_minutes,
        max_pair_age_hours,
        min_volume_5m_usd,
        min_transactions_5m,
        min_buy_share,
        max_buy_share,
        min_volume_spike,
        max_volume_spike,
        min_momentum_5m,
        max_momentum_5m,
        min_momentum_1h,
        max_momentum_1h,
        min_liquidity_valuation_ratio,
        confirmation_scans
      )
      VALUES (
        1,
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minSignalScore},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minLiquidityUsd},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minPairAgeMinutes},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxPairAgeHours},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minVolume5mUsd},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minTransactions5m},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minBuyShare},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxBuyShare},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minVolumeSpike},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxVolumeSpike},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minMomentum5m},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxMomentum5m},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minMomentum1h},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxMomentum1h},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minLiquidityValuationRatio},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.confirmationScans}
      )
      ON CONFLICT (id) DO NOTHING
    `;
  })().catch(
    (error) => {
      schemaPromise = null;
      throw error;
    },
  );

  return schemaPromise;
}

export async function getSignalEngineSettings():
Promise<SignalEngineSettings> {
  await ensureSignalEngineSettingsSchema();

  const sql =
    sqlClient();

  const rows = await sql`
    SELECT
      min_signal_score,
      min_liquidity_usd,
      min_pair_age_minutes,
      max_pair_age_hours,
      min_volume_5m_usd,
      min_transactions_5m,
      min_buy_share,
      max_buy_share,
      min_volume_spike,
      max_volume_spike,
      min_momentum_5m,
      max_momentum_5m,
      min_momentum_1h,
      max_momentum_1h,
      min_liquidity_valuation_ratio,
      confirmation_scans
    FROM memescope_signal_engine_settings
    WHERE id = 1
    LIMIT 1
  `;

  const row =
    rows[0] as
      | Record<string, unknown>
      | undefined;

  if (!row) {
    return DEFAULT_SIGNAL_ENGINE_SETTINGS;
  }

  return normalizeEngineSettings({
    minSignalScore:
      num(
        row.min_signal_score,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minSignalScore,
      ),
    minLiquidityUsd:
      num(
        row.min_liquidity_usd,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minLiquidityUsd,
      ),
    minPairAgeMinutes:
      num(
        row.min_pair_age_minutes,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minPairAgeMinutes,
      ),
    maxPairAgeHours:
      num(
        row.max_pair_age_hours,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxPairAgeHours,
      ),
    minVolume5mUsd:
      num(
        row.min_volume_5m_usd,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minVolume5mUsd,
      ),
    minTransactions5m:
      num(
        row.min_transactions_5m,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minTransactions5m,
      ),
    minBuyShare:
      num(
        row.min_buy_share,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minBuyShare,
      ),
    maxBuyShare:
      num(
        row.max_buy_share,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxBuyShare,
      ),
    minVolumeSpike:
      num(
        row.min_volume_spike,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minVolumeSpike,
      ),
    maxVolumeSpike:
      num(
        row.max_volume_spike,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxVolumeSpike,
      ),
    minMomentum5m:
      num(
        row.min_momentum_5m,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minMomentum5m,
      ),
    maxMomentum5m:
      num(
        row.max_momentum_5m,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxMomentum5m,
      ),
    minMomentum1h:
      num(
        row.min_momentum_1h,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minMomentum1h,
      ),
    maxMomentum1h:
      num(
        row.max_momentum_1h,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxMomentum1h,
      ),
    minLiquidityValuationRatio:
      num(
        row.min_liquidity_valuation_ratio,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .minLiquidityValuationRatio,
      ),
    confirmationScans:
      num(
        row.confirmation_scans,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .confirmationScans,
      ),
  });
}

export async function saveSignalEngineSettings(
  patch: Partial<
    SignalEngineSettings
  >,
) {
  await ensureSignalEngineSettingsSchema();

  const current =
    await getSignalEngineSettings();

  const next =
    normalizeEngineSettings({
      ...current,
      ...patch,
    });

  const sql =
    sqlClient();

  await sql`
    UPDATE memescope_signal_engine_settings
    SET
      min_signal_score = ${next.minSignalScore},
      min_liquidity_usd = ${next.minLiquidityUsd},
      min_pair_age_minutes = ${next.minPairAgeMinutes},
      max_pair_age_hours = ${next.maxPairAgeHours},
      min_volume_5m_usd = ${next.minVolume5mUsd},
      min_transactions_5m = ${next.minTransactions5m},
      min_buy_share = ${next.minBuyShare},
      max_buy_share = ${next.maxBuyShare},
      min_volume_spike = ${next.minVolumeSpike},
      max_volume_spike = ${next.maxVolumeSpike},
      min_momentum_5m = ${next.minMomentum5m},
      max_momentum_5m = ${next.maxMomentum5m},
      min_momentum_1h = ${next.minMomentum1h},
      max_momentum_1h = ${next.maxMomentum1h},
      min_liquidity_valuation_ratio = ${next.minLiquidityValuationRatio},
      confirmation_scans = ${next.confirmationScans},
      updated_at = NOW()
    WHERE id = 1
  `;

  return next;
}

export async function applySignalPreset(
  name: SignalPresetName,
) {
  return saveSignalEngineSettings(
    SIGNAL_PRESETS[name],
  );
}

export async function resetSignalEngineSettings() {
  return applySignalPreset(
    "balanced",
  );
}

export function signalPresetName(
  settings: SignalEngineSettings,
): SignalPresetName | "custom" {
  for (
    const name of Object.keys(
      SIGNAL_PRESETS,
    ) as SignalPresetName[]
  ) {
    const preset =
      SIGNAL_PRESETS[name];

    if (
      preset.minSignalScore ===
        settings.minSignalScore &&
      preset.minLiquidityUsd ===
        settings.minLiquidityUsd &&
      preset.minPairAgeMinutes ===
        settings.minPairAgeMinutes &&
      preset.maxPairAgeHours ===
        settings.maxPairAgeHours &&
      preset.minVolume5mUsd ===
        settings.minVolume5mUsd &&
      preset.minTransactions5m ===
        settings.minTransactions5m &&
      preset.minBuyShare ===
        settings.minBuyShare &&
      preset.maxBuyShare ===
        settings.maxBuyShare &&
      preset.minVolumeSpike ===
        settings.minVolumeSpike &&
      preset.maxVolumeSpike ===
        settings.maxVolumeSpike &&
      preset.minMomentum5m ===
        settings.minMomentum5m &&
      preset.maxMomentum5m ===
        settings.maxMomentum5m &&
      preset.minMomentum1h ===
        settings.minMomentum1h &&
      preset.maxMomentum1h ===
        settings.maxMomentum1h &&
      preset.minLiquidityValuationRatio ===
        settings.minLiquidityValuationRatio &&
      preset.confirmationScans ===
        settings.confirmationScans
    ) {
      return name;
    }
  }

  return "custom";
}
