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
  | "strict"
  | "balanced"
  | "broad";

const PRESETS: Record<
  SignalPresetName,
  SignalSettings
> = {
  strict: {
    minSignalScore: 90,
    minLiquidityUsd: 100_000,
    maxPairAgeHours: 12,
  },
  balanced: {
    minSignalScore: 80,
    minLiquidityUsd: 50_000,
    maxPairAgeHours: 24,
  },
  broad: {
    minSignalScore: 75,
    minLiquidityUsd: 25_000,
    maxPairAgeHours: 48,
  },
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
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

export async function ensureSignalEngineSettingsSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_engine_settings (
        id INTEGER PRIMARY KEY,
        min_signal_score INTEGER NOT NULL DEFAULT 80,
        min_liquidity_usd DOUBLE PRECISION NOT NULL DEFAULT 50000,
        max_pair_age_hours INTEGER NOT NULL DEFAULT 24,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_signal_engine_settings (
        id,
        min_signal_score,
        min_liquidity_usd,
        max_pair_age_hours
      )
      VALUES (
        1,
        ${DEFAULT_SIGNAL_SETTINGS.minSignalScore},
        ${DEFAULT_SIGNAL_SETTINGS.minLiquidityUsd},
        ${DEFAULT_SIGNAL_SETTINGS.maxPairAgeHours}
      )
      ON CONFLICT (id) DO NOTHING
    `;
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

export async function getSignalEngineSettings(): Promise<SignalSettings> {
  await ensureSignalEngineSettingsSchema();

  const sql = sqlClient();

  const rows = await sql`
    SELECT
      min_signal_score,
      min_liquidity_usd,
      max_pair_age_hours
    FROM memescope_signal_engine_settings
    WHERE id = 1
    LIMIT 1
  `;

  const row =
    rows[0] as
      | Record<string, unknown>
      | undefined;

  if (!row) {
    return DEFAULT_SIGNAL_SETTINGS;
  }

  return normalizeSignalSettings({
    minSignalScore: num(
      row.min_signal_score,
      DEFAULT_SIGNAL_SETTINGS.minSignalScore,
    ),
    minLiquidityUsd: num(
      row.min_liquidity_usd,
      DEFAULT_SIGNAL_SETTINGS.minLiquidityUsd,
    ),
    maxPairAgeHours: num(
      row.max_pair_age_hours,
      DEFAULT_SIGNAL_SETTINGS.maxPairAgeHours,
    ),
  });
}

export async function saveSignalEngineSettings(
  patch: Partial<SignalSettings>,
) {
  await ensureSignalEngineSettingsSchema();

  const current =
    await getSignalEngineSettings();

  const next =
    normalizeSignalSettings({
      ...current,
      ...patch,
    });

  const sql = sqlClient();

  await sql`
    UPDATE memescope_signal_engine_settings
    SET
      min_signal_score = ${next.minSignalScore},
      min_liquidity_usd = ${next.minLiquidityUsd},
      max_pair_age_hours = ${next.maxPairAgeHours},
      updated_at = NOW()
    WHERE id = 1
  `;

  return next;
}

export async function applySignalPreset(
  name: SignalPresetName,
) {
  const preset = PRESETS[name];

  return saveSignalEngineSettings(
    preset,
  );
}

export async function resetSignalEngineSettings() {
  return saveSignalEngineSettings(
    DEFAULT_SIGNAL_SETTINGS,
  );
}

export function signalPresetName(
  settings: SignalSettings,
): SignalPresetName | "custom" {
  for (
    const name of Object.keys(
      PRESETS,
    ) as SignalPresetName[]
  ) {
    const preset =
      PRESETS[name];

    if (
      preset.minSignalScore ===
        settings.minSignalScore &&
      preset.minLiquidityUsd ===
        settings.minLiquidityUsd &&
      preset.maxPairAgeHours ===
        settings.maxPairAgeHours
    ) {
      return name;
    }
  }

  return "custom";
}