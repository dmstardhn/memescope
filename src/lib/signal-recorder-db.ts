import { neon } from "@neondatabase/serverless";
import { randomUUID } from "node:crypto";

import {
  buildSignalExitPlan,
  DEFAULT_SIGNAL_EXIT_SETTINGS,
  normalizeSignalExitSettings,
  type SignalExitSettings,
} from "@/lib/signal-exit-plan";
import type { SignalCall } from "@/lib/signal-types";
import type { TerminalToken } from "@/lib/terminal-types";

type DbRow = Record<string, unknown>;

export type StoredSignalRecord = {
  id: string;
  signalId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  kind: string;
  label: string;
  openedAt: number;
  lastUpdatedAt: number;
  closedAt: number | null;
  entryPriceUsd: number | null;
  currentPriceUsd: number | null;
  exitPriceUsd: number | null;
  targetPercent: number;
  stopLossPercent: number;
  targetPriceUsd: number | null;
  stopPriceUsd: number | null;
  mode: string;
  style: string;
  planReason: string;
  scoreAtEntry: number;
  lastScore: number;
  signalVisible: boolean;
  status: "active" | "target_hit" | "stop_loss";
  currentGainPercent: number | null;
  peakGainPercent: number | null;
  maxDrawdownPercent: number | null;
};

let schemaPromise: Promise<void> | null = null;

// A token must leave the qualifying set and re-enter before another call can
// be opened. If it re-enters too quickly, it is kept armed until this cooldown
// expires. This prevents one noisy token from being called every minute while
// still allowing a genuinely fresh setup later.
const SIGNAL_REENTRY_COOLDOWN_MS =
  30 * 60 * 1000;

function databaseUrl() {
  return process.env.DATABASE_URL ?? "";
}

export function signalDatabaseConfigured() {
  return Boolean(databaseUrl());
}

function sqlClient() {
  const url = databaseUrl();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}

function num(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function numOrNull(value: unknown) {
  if (value === null || value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function toMillis(value: unknown) {
  if (value instanceof Date) return value.getTime();
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return Date.now();
}

function toNullableMillis(value: unknown) {
  if (value === null || value === undefined) return null;
  return toMillis(value);
}

function gainPercent(entry: number | null, current: number | null) {
  if (entry === null || current === null || entry <= 0) return null;
  return ((current - entry) / entry) * 100;
}

function targetPrice(entry: number, pct: number) {
  return entry * (1 + pct / 100);
}


function normalizeRecord(row: DbRow): StoredSignalRecord {
  const rawStatus = String(row.status ?? "active");
  const status: StoredSignalRecord["status"] =
    rawStatus === "target_hit" || rawStatus === "stop_loss"
      ? rawStatus
      : "active";

  return {
    id: String(row.id),
    signalId: String(row.signal_id),
    tokenAddress: String(row.token_address),
    symbol: String(row.symbol),
    name: String(row.name),
    kind: String(row.kind),
    label: String(row.label),
    openedAt: toMillis(row.opened_at),
    lastUpdatedAt: toMillis(row.last_updated_at),
    closedAt: toNullableMillis(row.closed_at),
    entryPriceUsd: numOrNull(row.entry_price_usd),
    currentPriceUsd: numOrNull(row.current_price_usd),
    exitPriceUsd: numOrNull(row.exit_price_usd),
    targetPercent: num(row.target_pct),
    stopLossPercent: num(row.stop_loss_pct),
    targetPriceUsd: numOrNull(row.target_price_usd),
    stopPriceUsd: numOrNull(row.stop_price_usd),
    mode: String(row.tp_sl_mode ?? "dynamic"),
    style: String(row.style ?? "balanced"),
    planReason: String(row.plan_reason ?? ""),
    scoreAtEntry: num(row.score_at_entry),
    lastScore: num(row.last_score),
    signalVisible: row.signal_visible === true,
    status,
    currentGainPercent: numOrNull(row.current_gain_pct),
    peakGainPercent: numOrNull(row.peak_gain_pct),
    maxDrawdownPercent: numOrNull(row.max_drawdown_pct),
  };
}

export async function ensureSignalRecorderSchema() {
  if (schemaPromise) return schemaPromise;

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_settings (
        id INTEGER PRIMARY KEY,
        mode TEXT NOT NULL DEFAULT 'dynamic',
        style TEXT NOT NULL DEFAULT 'balanced',
        fixed_target_pct DOUBLE PRECISION NOT NULL DEFAULT 30,
        fixed_stop_pct DOUBLE PRECISION NOT NULL DEFAULT 15,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_signal_settings (
        id, mode, style, fixed_target_pct, fixed_stop_pct
      )
      VALUES (1, 'dynamic', 'balanced', 30, 15)
      ON CONFLICT (id) DO NOTHING
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_records (
        id TEXT PRIMARY KEY,
        signal_id TEXT NOT NULL,
        token_address TEXT NOT NULL,
        symbol TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        label TEXT NOT NULL,

        opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        last_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        closed_at TIMESTAMPTZ,

        entry_price_usd DOUBLE PRECISION,
        current_price_usd DOUBLE PRECISION,
        exit_price_usd DOUBLE PRECISION,
        peak_price_usd DOUBLE PRECISION,
        trough_price_usd DOUBLE PRECISION,

        target_pct DOUBLE PRECISION NOT NULL,
        stop_loss_pct DOUBLE PRECISION NOT NULL,
        target_price_usd DOUBLE PRECISION,
        stop_price_usd DOUBLE PRECISION,

        tp_sl_mode TEXT NOT NULL,
        style TEXT NOT NULL,
        plan_reason TEXT NOT NULL,

        score_at_entry INTEGER NOT NULL,
        last_score INTEGER NOT NULL,

        signal_visible BOOLEAN NOT NULL DEFAULT TRUE,
        status TEXT NOT NULL DEFAULT 'active',

        current_gain_pct DOUBLE PRECISION,
        peak_gain_pct DOUBLE PRECISION,
        max_drawdown_pct DOUBLE PRECISION,

        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE UNIQUE INDEX IF NOT EXISTS memescope_signal_one_active_idx
      ON memescope_signal_records (signal_id)
      WHERE status = 'active'
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_signal_opened_idx
      ON memescope_signal_records (opened_at DESC)
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_signal_status_idx
      ON memescope_signal_records (status)
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_signal_state (
        signal_id TEXT PRIMARY KEY,
        visible BOOLEAN NOT NULL DEFAULT FALSE,
        armed BOOLEAN NOT NULL DEFAULT TRUE,
        confirmation_count INTEGER NOT NULL DEFAULT 0,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      ALTER TABLE memescope_signal_state
      ADD COLUMN IF NOT EXISTS confirmation_count INTEGER NOT NULL DEFAULT 0
    `;

    // MEMESCOPE_SIGNAL_LIFECYCLE_V2
    // One-time state migration. Existing state rows may have been left
    // visible/unarmed by the old lifecycle while their call record stayed
    // active forever. Reset those rows once so a genuinely qualifying setup
    // can enter the new re-entry lifecycle.
    await sql`
      ALTER TABLE memescope_signal_state
      ADD COLUMN IF NOT EXISTS lifecycle_version INTEGER NOT NULL DEFAULT 1
    `;

    await sql`
      ALTER TABLE memescope_signal_state
      ALTER COLUMN lifecycle_version SET DEFAULT 2
    `;

    await sql`
      UPDATE memescope_signal_state
      SET
        visible = FALSE,
        armed = TRUE,
        confirmation_count = 0,
        lifecycle_version = 2,
        updated_at = NOW()
      WHERE lifecycle_version < 2
    `;
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

export async function getSignalExitSettings(): Promise<SignalExitSettings> {
  await ensureSignalRecorderSchema();
  const sql = sqlClient();

  const rows = await sql`
    SELECT mode, style, fixed_target_pct, fixed_stop_pct
    FROM memescope_signal_settings
    WHERE id = 1
    LIMIT 1
  `;

  const row = rows[0] as DbRow | undefined;
  if (!row) return DEFAULT_SIGNAL_EXIT_SETTINGS;

  return normalizeSignalExitSettings({
    mode: String(row.mode) === "fixed" ? "fixed" : "dynamic",
    style:
      String(row.style) === "conservative"
        ? "conservative"
        : String(row.style) === "aggressive"
          ? "aggressive"
          : "balanced",
    fixedTargetPercent: num(row.fixed_target_pct, 30),
    fixedStopLossPercent: num(row.fixed_stop_pct, 15),
  });
}

export async function saveSignalExitSettings(
  input: Partial<SignalExitSettings>,
) {
  await ensureSignalRecorderSchema();
  const sql = sqlClient();
  const settings = normalizeSignalExitSettings(input);

  await sql`
    UPDATE memescope_signal_settings
    SET
      mode = ${settings.mode},
      style = ${settings.style},
      fixed_target_pct = ${settings.fixedTargetPercent},
      fixed_stop_pct = ${settings.fixedStopLossPercent},
      updated_at = NOW()
    WHERE id = 1
  `;

  return settings;
}

export async function getSignalHistory(limit = 100) {
  await ensureSignalRecorderSchema();
  const sql = sqlClient();
  const safeLimit = Math.max(1, Math.min(500, Math.round(limit)));

  const rows = await sql`
    SELECT *
    FROM memescope_signal_records
    ORDER BY opened_at DESC
    LIMIT ${safeLimit}
  `;

  return rows.map((row) => normalizeRecord(row as DbRow));
}


type DexPricePair = {
  chainId?: string;
  priceUsd?: string;
  baseToken?: {
    address?: string;
  };
  liquidity?: {
    usd?: number;
  };
};

async function fetchTrackedTokenPrices(
  addresses: string[],
) {
  const unique = Array.from(
    new Set(
      addresses.filter(Boolean),
    ),
  );

  const prices = new Map<
    string,
    number
  >();

  for (
    let index = 0;
    index < unique.length;
    index += 30
  ) {
    const batch =
      unique.slice(
        index,
        index + 30,
      );

    if (
      batch.length === 0
    ) {
      continue;
    }

    try {
      const url =
        `https://api.dexscreener.com/tokens/v1/solana/${batch.join(
          ",",
        )}`;

      const response =
        await fetch(
          url,
          {
            cache: "no-store",
            headers: {
              accept:
                "application/json",
            },
          },
        );

      if (!response.ok) {
        continue;
      }

      const pairs =
        (await response.json()) as DexPricePair[];

      const bestLiquidity =
        new Map<
          string,
          number
        >();

      for (
        const pair of pairs
      ) {
        const address =
          pair.baseToken?.address;

        const parsedPrice =
          Number(
            pair.priceUsd,
          );

        if (
          !address ||
          !Number.isFinite(
            parsedPrice,
          ) ||
          parsedPrice <= 0
        ) {
          continue;
        }

        const liquidity =
          Number(
            pair.liquidity?.usd ??
              0,
          );

        const previousLiquidity =
          bestLiquidity.get(
            address,
          ) ?? -1;

        if (
          liquidity >=
          previousLiquidity
        ) {
          prices.set(
            address,
            parsedPrice,
          );

          bestLiquidity.set(
            address,
            liquidity,
          );
        }
      }
    } catch {
      // Keep existing stored price if DexScreener temporarily fails.
    }
  }

  return prices;
}
export async function recordSignalSnapshot(
  tokens: TerminalToken[],
  signals: SignalCall[],
  confirmationScans = 1,
) {
  await ensureSignalRecorderSchema();
  const sql = sqlClient();
  const settings = await getSignalExitSettings();

  const watchSignals = signals.filter((signal) => signal.direction === "watch");
  const visibleIds = new Set(watchSignals.map((signal) => signal.id));
  const signalMap = new Map(watchSignals.map((signal) => [signal.id, signal]));
  const tokenMap = new Map(tokens.map((token) => [token.address, token]));

  const activeRows = await sql`
    SELECT *
    FROM memescope_signal_records
    WHERE status = 'active'
  `;

  const activeRecords = activeRows.map((row) =>
    normalizeRecord(row as DbRow),
  );
  const trackedPrices =
    await fetchTrackedTokenPrices(
      activeRecords.map(
        (record) =>
          record.tokenAddress,
      ),
    );

  // Re-entry cooldown is token-based rather than signal-id-based. This also
  // protects against the same mint receiving a slightly different engine ID.
  const recentCallRows = await sql`
    SELECT
      token_address,
      MAX(opened_at) AS last_opened_at
    FROM memescope_signal_records
    WHERE opened_at >= NOW() - INTERVAL '1 day'
    GROUP BY token_address
  `;

  const lastOpenedByToken = new Map(
    recentCallRows.map((raw) => {
      const row = raw as DbRow;
      return [
        String(row.token_address),
        toMillis(row.last_opened_at),
      ] as [string, number];
    }),
  );

  let updated = 0;
  let closed = 0;

  for (const record of activeRecords) {
    const token = tokenMap.get(record.tokenAddress);
    const signal = signalMap.get(record.signalId);

    const currentPrice =
      trackedPrices.get(
        record.tokenAddress,
      ) ??
      token?.priceUsd ??
      signal?.priceUsd ??
      record.currentPriceUsd;

    const gain = gainPercent(record.entryPriceUsd, currentPrice);

    const peakGain =
      gain === null
        ? record.peakGainPercent
        : record.peakGainPercent === null
          ? gain
          : Math.max(record.peakGainPercent, gain);

    const maxDrawdown =
      gain === null
        ? record.maxDrawdownPercent
        : record.maxDrawdownPercent === null
          ? gain
          : Math.min(record.maxDrawdownPercent, gain);

    let status: StoredSignalRecord["status"] = "active";

    if (gain !== null && gain >= record.targetPercent) {
      status = "target_hit";
    }

    const visible = visibleIds.has(record.signalId);
    const lastScore = signal?.signalScore ?? record.lastScore;

    if (status === "active") {
      await sql`
        UPDATE memescope_signal_records
        SET
          last_updated_at = NOW(),
          current_price_usd = ${currentPrice},
          peak_price_usd = CASE
            WHEN CAST(${currentPrice} AS DOUBLE PRECISION) IS NULL THEN peak_price_usd
            WHEN peak_price_usd IS NULL THEN ${currentPrice}
            ELSE GREATEST(peak_price_usd, ${currentPrice})
          END,
          trough_price_usd = CASE
            WHEN CAST(${currentPrice} AS DOUBLE PRECISION) IS NULL THEN trough_price_usd
            WHEN trough_price_usd IS NULL THEN ${currentPrice}
            ELSE LEAST(trough_price_usd, ${currentPrice})
          END,
          current_gain_pct = ${gain},
          peak_gain_pct = ${peakGain},
          max_drawdown_pct = ${maxDrawdown},
          last_score = ${lastScore},
          signal_visible = ${visible}
        WHERE id = ${record.id}
      `;
      updated += 1;
    } else {
      await sql`
        UPDATE memescope_signal_records
        SET
          last_updated_at = NOW(),
          closed_at = NOW(),
          current_price_usd = ${currentPrice},
          exit_price_usd = ${currentPrice},
          peak_price_usd = CASE
            WHEN CAST(${currentPrice} AS DOUBLE PRECISION) IS NULL THEN peak_price_usd
            WHEN peak_price_usd IS NULL THEN ${currentPrice}
            ELSE GREATEST(peak_price_usd, ${currentPrice})
          END,
          trough_price_usd = CASE
            WHEN CAST(${currentPrice} AS DOUBLE PRECISION) IS NULL THEN trough_price_usd
            WHEN trough_price_usd IS NULL THEN ${currentPrice}
            ELSE LEAST(trough_price_usd, ${currentPrice})
          END,
          current_gain_pct = ${gain},
          peak_gain_pct = ${peakGain},
          max_drawdown_pct = ${maxDrawdown},
          last_score = ${lastScore},
          signal_visible = ${visible},
          status = ${status}
        WHERE id = ${record.id}
      `;
      closed += 1;
    }
  }

  const stateRows = await sql`
    SELECT signal_id, visible, armed, confirmation_count
    FROM memescope_signal_state
  `;

  const states = new Map(
    stateRows.map((raw) => {
      const row = raw as DbRow;
      return [
        String(row.signal_id),
        {
          visible: row.visible === true,
          armed: row.armed === true,
        },
      ] as [string, {
        visible: boolean;
        armed: boolean;
      }];
    }),
  );

  const confirmationCounts = new Map(
    stateRows.map((raw) => {
      const row = raw as DbRow;
      return [
        String(row.signal_id),
        Math.max(
          0,
          Math.round(
            Number(
              row.confirmation_count ??
                0,
            ),
          ),
        ),
      ] as [string, number];
    }),
  );
  // Disappearance re-arms the same signal for a future fresh occurrence.
  for (const [signalId, state] of states) {
    if (state.visible && !visibleIds.has(signalId)) {
      await sql`
        UPDATE memescope_signal_state
        SET
          visible = FALSE,
          armed = TRUE,
          confirmation_count = 0,
          updated_at = NOW()
        WHERE signal_id = ${signalId}
      `;
      state.visible = false;
      state.armed = true;
      confirmationCounts.set(
        signalId,
        0,
      );
    }
  }

  let opened = 0;
  let blockedByState = 0;
  let blockedByCooldown = 0;
  let rekeyedActive = 0;
  let deduped = 0;

  // Stage 19.2: preset-driven consecutive confirmation.
  // A more aggressive preset can open on the first qualifying scan,
  // while stricter presets require the setup to remain valid across
  // multiple consecutive recorder scans.
  const requiredConfirmations =
    Math.max(
      1,
      Math.min(
        4,
        Math.round(
          confirmationScans,
        ),
      ),
    );

  for (const signal of watchSignals) {
    let state = states.get(signal.id);
    let mayOpen = false;
    let count =
      confirmationCounts.get(
        signal.id,
      ) ?? 0;

    if (!state) {
      count = 1;
      mayOpen =
        count >=
        requiredConfirmations;

      state = {
        visible: true,
        armed: !mayOpen,
      };
      states.set(
        signal.id,
        state,
      );
      confirmationCounts.set(
        signal.id,
        count,
      );

      await sql`
        INSERT INTO memescope_signal_state (
          signal_id,
          visible,
          armed,
          confirmation_count,
          updated_at
        )
        VALUES (
          ${signal.id},
          TRUE,
          ${!mayOpen},
          ${count},
          NOW()
        )
        ON CONFLICT (signal_id)
        DO UPDATE SET
          visible = TRUE,
          armed = ${!mayOpen},
          confirmation_count = ${count},
          updated_at = NOW()
      `;
    } else if (!state.visible) {
      count = 1;
      mayOpen =
        count >=
        requiredConfirmations;

      state.visible = true;
      state.armed = !mayOpen;
      confirmationCounts.set(
        signal.id,
        count,
      );

      await sql`
        UPDATE memescope_signal_state
        SET
          visible = TRUE,
          armed = ${!mayOpen},
          confirmation_count = ${count},
          updated_at = NOW()
        WHERE signal_id = ${signal.id}
      `;
    } else if (state.armed) {
      count += 1;
      mayOpen =
        count >=
        requiredConfirmations;

      state.armed = !mayOpen;
      confirmationCounts.set(
        signal.id,
        count,
      );

      await sql`
        UPDATE memescope_signal_state
        SET
          visible = TRUE,
          armed = ${!mayOpen},
          confirmation_count = ${count},
          updated_at = NOW()
        WHERE signal_id = ${signal.id}
      `;
    }

    if (!mayOpen) {
      blockedByState += 1;
      continue;
    }

    const nowMs = Date.now();
    const lastOpenedAt =
      lastOpenedByToken.get(
        signal.tokenAddress,
      );

    if (
      lastOpenedAt !== undefined &&
      nowMs - lastOpenedAt <
        SIGNAL_REENTRY_COOLDOWN_MS
    ) {
      blockedByCooldown += 1;

      // The setup did leave and re-enter, but it is still inside the
      // anti-spam window. Keep it armed so the recorder retries on a later
      // scan instead of requiring another disappearance.
      state.armed = true;
      confirmationCounts.set(
        signal.id,
        0,
      );

      await sql`
        UPDATE memescope_signal_state
        SET
          armed = TRUE,
          confirmation_count = 0,
          updated_at = NOW()
        WHERE signal_id = ${signal.id}
      `;

      continue;
    }

    // Legacy lifecycle kept a single canonical signal_id active forever.
    // When a fresh setup is allowed after cooldown, detach only OLD active
    // rows from the canonical engine id. Their record id, entry, gain/peak,
    // Telegram post and Call Story remain untouched and continue tracking.
    const reentryCutoff =
      new Date(
        nowMs -
          SIGNAL_REENTRY_COOLDOWN_MS,
      ).toISOString();

    const previousActiveRows =
      await sql`
        SELECT id
        FROM memescope_signal_records
        WHERE signal_id = ${signal.id}
          AND status = 'active'
          AND opened_at <= ${reentryCutoff}
      `;

    for (const raw of previousActiveRows) {
      const previousId =
        String(
          (raw as DbRow).id ??
            "",
        );

      if (!previousId) {
        continue;
      }

      const historicalSignalId =
        `${signal.id}::prior::${previousId}`;

      const moved = await sql`
        UPDATE memescope_signal_records
        SET
          signal_id = ${historicalSignalId},
          signal_visible = FALSE,
          last_updated_at = NOW()
        WHERE id = ${previousId}
          AND signal_id = ${signal.id}
          AND status = 'active'
          AND opened_at <= ${reentryCutoff}
        RETURNING id
      `;

      rekeyedActive += moved.length;
    }

    const token = tokenMap.get(signal.tokenAddress);
    const entry = token?.priceUsd ?? signal.priceUsd;

    if (entry === null || entry <= 0) continue;

    const plan = buildSignalExitPlan(signal, settings);
    const id = randomUUID();

    const insertedRows = await sql`
      INSERT INTO memescope_signal_records (
        id,
        signal_id,
        token_address,
        symbol,
        name,
        kind,
        label,
        opened_at,
        last_updated_at,
        entry_price_usd,
        current_price_usd,
        peak_price_usd,
        trough_price_usd,
        target_pct,
        stop_loss_pct,
        target_price_usd,
        stop_price_usd,
        tp_sl_mode,
        style,
        plan_reason,
        score_at_entry,
        last_score,
        signal_visible,
        status,
        current_gain_pct,
        peak_gain_pct,
        max_drawdown_pct
      )
      VALUES (
        ${id},
        ${signal.id},
        ${signal.tokenAddress},
        ${signal.symbol},
        ${signal.name},
        ${signal.kind},
        ${signal.label},
        NOW(),
        NOW(),
        ${entry},
        ${entry},
        ${entry},
        ${entry},
        ${plan.targetPercent},
        ${plan.stopLossPercent},
        ${targetPrice(entry, plan.targetPercent)},
        NULL,
        ${plan.mode},
        ${plan.style},
        ${plan.reason},
        ${signal.signalScore},
        ${signal.signalScore},
        TRUE,
        'active',
        0,
        0,
        0
      )
      ON CONFLICT DO NOTHING
      RETURNING id
    `;

    if (insertedRows.length > 0) {
      opened += 1;
      lastOpenedByToken.set(
        signal.tokenAddress,
        nowMs,
      );
    } else {
      // The unique active-signal index remains in place and is our final
      // concurrency guard if two serverless recorder runs overlap.
      deduped += 1;
    }
  }

  // Stage 20 Call Story cycle.
  // Tracks every call independently of the legacy TP lifecycle.
  try {
    const {
      runCallStoryCycle,
    } = await import(
      "@/lib/call-story"
    );

    await runCallStoryCycle(
      tokens,
      signals,
    );
  } catch (error) {
    console.error(
      "MemeScope Call Story cycle failed:",
      error,
    );
  }

  // Stage 17 Telegram publisher.
  // Telegram failures must never break the signal recorder itself.
  try {
    const {
      publishPendingTelegramSignals,
    } =
      await import(
        "@/lib/telegram-publisher"
      );

    await publishPendingTelegramSignals();
  } catch (error) {
    console.error(
      "Telegram signal publisher failed:",
      error,
    );
  }
  return {
    generatedAt: Date.now(),
    tokenCount: tokens.length,
    watchSignalCount: watchSignals.length,
    opened,
    updated,
    closed,
    blockedByState,
    blockedByCooldown,
    rekeyedActive,
    deduped,
    reentryCooldownMinutes:
      SIGNAL_REENTRY_COOLDOWN_MS /
      60_000,
    settings,
  };
}

function average(values: Array<number | null>) {
  const valid = values.filter(
    (value): value is number =>
      value !== null && Number.isFinite(value),
  );

  if (valid.length === 0) return null;
  return valid.reduce((sum, value) => sum + value, 0) / valid.length;
}

export async function getSignalAnalytics(days = 30) {
  await ensureSignalRecorderSchema();
  const sql = sqlClient();
  const safeDays = Math.max(0, Math.min(3650, Math.round(days)));

  let rows;

  if (safeDays === 0) {
    rows = await sql`
      SELECT *
      FROM memescope_signal_records
      ORDER BY opened_at DESC
      LIMIT 5000
    `;
  } else {
    const cutoff = new Date(
      Date.now() - safeDays * 86_400_000,
    ).toISOString();

    rows = await sql`
      SELECT *
      FROM memescope_signal_records
      WHERE opened_at >= ${cutoff}
      ORDER BY opened_at DESC
      LIMIT 5000
    `;
  }

  const records = rows.map((row) => normalizeRecord(row as DbRow));
  const active = records.filter((record) => record.status === "active");
  const targetHits = records.filter(
    (record) => record.status === "target_hit",
  );
  const stopLosses = records.filter(
    (record) => record.status === "stop_loss",
  );
  const closed = [...targetHits, ...stopLosses];

  const byKindMap = new Map<string, StoredSignalRecord[]>();
  const byPlanMap = new Map<string, StoredSignalRecord[]>();

  for (const record of records) {
    const kindItems = byKindMap.get(record.kind) ?? [];
    kindItems.push(record);
    byKindMap.set(record.kind, kindItems);

    const planKey = `${record.mode}:${record.style}`;
    const planItems = byPlanMap.get(planKey) ?? [];
    planItems.push(record);
    byPlanMap.set(planKey, planItems);
  }

  function groupStats(key: string, items: StoredSignalRecord[]) {
    const finished = items.filter((record) => record.status !== "active");
    const wins = finished.filter((record) => record.status === "target_hit");

    return {
      key,
      total: items.length,
      active: items.length - finished.length,
      closed: finished.length,
      targetHits: wins.length,
      stopLosses: finished.length - wins.length,
      targetHitRate:
        finished.length > 0 ? (wins.length / finished.length) * 100 : null,
      averagePeakGain: average(
        items.map((record) => record.peakGainPercent),
      ),
      averageDrawdown: average(
        items.map((record) => record.maxDrawdownPercent),
      ),
    };
  }

  const best =
    records
      .filter((record) => record.peakGainPercent !== null)
      .sort(
        (a, b) =>
          (b.peakGainPercent ?? -Infinity) -
          (a.peakGainPercent ?? -Infinity),
      )[0] ?? null;

  const worst =
    records
      .filter((record) => record.maxDrawdownPercent !== null)
      .sort(
        (a, b) =>
          (a.maxDrawdownPercent ?? Infinity) -
          (b.maxDrawdownPercent ?? Infinity),
      )[0] ?? null;

  return {
    periodDays: safeDays,
    total: records.length,
    active: active.length,
    closed: closed.length,
    targetHits: targetHits.length,
    stopLosses: stopLosses.length,
    targetHitRate:
      closed.length > 0 ? (targetHits.length / closed.length) * 100 : null,
    averageCurrentGain: average(
      records.map((record) => record.currentGainPercent),
    ),
    averagePeakGain: average(
      records.map((record) => record.peakGainPercent),
    ),
    averageDrawdown: average(
      records.map((record) => record.maxDrawdownPercent),
    ),
    averageHoldMinutes: average(
      closed.map((record) =>
        record.closedAt === null
          ? null
          : (record.closedAt - record.openedAt) / 60_000,
      ),
    ),
    byKind: Array.from(byKindMap.entries())
      .map(([key, items]) => groupStats(key, items))
      .sort((a, b) => b.total - a.total),
    byPlan: Array.from(byPlanMap.entries())
      .map(([key, items]) => groupStats(key, items))
      .sort((a, b) => b.total - a.total),
    best,
    worst,
    recent: records.slice(0, 25),
  };
}
