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
  | "ultra";

export type SignalEngineSettings =
  SignalSettings & {
    confirmationScans: number;
  };

export const SIGNAL_PRESETS: Record<
  SignalPresetName,
  SignalEngineSettings
> = {
  aggressive: {
    minSignalScore: 65,
    minLiquidityUsd: 25_000,
    maxPairAgeHours: 48,
    confirmationScans: 1,
  },
  balanced: {
    minSignalScore: 80,
    minLiquidityUsd: 50_000,
    maxPairAgeHours: 24,
    confirmationScans: 1,
  },
  strict: {
    minSignalScore: 88,
    minLiquidityUsd: 100_000,
    maxPairAgeHours: 12,
    confirmationScans: 1,
  },
  ultra: {
    minSignalScore: 92,
    minLiquidityUsd: 150_000,
    maxPairAgeHours: 6,
    confirmationScans: 2,
  },
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
        max_pair_age_hours INTEGER NOT NULL DEFAULT 24,
        confirmation_scans INTEGER NOT NULL DEFAULT 1,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ADD COLUMN IF NOT EXISTS confirmation_scans INTEGER NOT NULL DEFAULT 1
    `;

    await sql`
      ALTER TABLE memescope_signal_engine_settings
      ALTER COLUMN confirmation_scans SET DEFAULT 1
    `;

    await sql`
      INSERT INTO memescope_signal_engine_settings (
        id,
        min_signal_score,
        min_liquidity_usd,
        max_pair_age_hours,
        confirmation_scans
      )
      VALUES (
        1,
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minSignalScore},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.minLiquidityUsd},
        ${DEFAULT_SIGNAL_ENGINE_SETTINGS.maxPairAgeHours},
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
      max_pair_age_hours,
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
    maxPairAgeHours:
      num(
        row.max_pair_age_hours,
        DEFAULT_SIGNAL_ENGINE_SETTINGS
          .maxPairAgeHours,
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
      max_pair_age_hours = ${next.maxPairAgeHours},
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
      preset.maxPairAgeHours ===
        settings.maxPairAgeHours &&
      preset.confirmationScans ===
        settings.confirmationScans
    ) {
      return name;
    }
  }

  return "custom";
}