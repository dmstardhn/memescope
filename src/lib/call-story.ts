import "server-only";

import { neon } from "@neondatabase/serverless";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramConfigured,
  telegramSendMessage,
  telegramSendPhotoUpload,
  telegramSiteUrl,
} from "@/lib/telegram";
import { renderSignalResultCard } from "@/lib/signal-result-card";
import { evaluatePersistedCall, nextPublicMilestone } from "@/lib/performance-milestones";
import type { SignalCall } from "@/lib/signal-types";
import type { TerminalToken } from "@/lib/terminal-types";

type DbRow = Record<string, unknown>;

type SignalRecordRow = {
  id: string;
  signalId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  openedAt: number;
  entryPriceUsd: number | null;
  peakGainPercent: number | null;
  maxDrawdownPercent: number | null;
  scoreAtEntry: number;
};

type MarketSnapshot = {
  priceUsd: number | null;
  marketCapUsd: number | null;
  liquidityUsd: number | null;
};

export type CallStory = {
  signalRecordId: string;
  callNo: number;
  publicId: string;
  signalId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  calledAt: number;
  entryPriceUsd: number | null;
  callMarketCapUsd: number | null;
  currentPriceUsd: number | null;
  currentMarketCapUsd: number | null;
  peakPriceUsd: number | null;
  peakMarketCapUsd: number | null;
  currentMultiple: number | null;
  peakMultiple: number | null;
  maxDrawdownPct: number | null;
  signalScore: number;
  buyPressurePct: number | null;
  volumeSpike: number | null;
  liquidityUsd: number | null;
  volume5mUsd: number | null;
  transactions5m: number | null;
  priceChange5m: number | null;
  pairAgeMinutes: number | null;
  reasons: string[];
  baseline: boolean;
  lastPublicMilestone: number;
  lastPublicStage: number;
  lastPublicPostAt: number | null;
  milestone2xAt: number | null;
  milestone5xAt: number | null;
  milestone10xAt: number | null;
  milestone20xAt: number | null;
  milestone50xAt: number | null;
  milestone100xAt: number | null;
};

export type CallDashboard = {
  days: number;
  totalCalls: number;
  runningCalls: number;
  reached2x: number;
  reached5x: number;
  reached10x: number;
  medianPeakMultiple: number | null;
  medianMaxDrawdownPct: number | null;
  topCalls: CallStory[];
  recentCalls: CallStory[];
};

let schemaPromise: Promise<void> | null = null;

function sqlClient() {
  const databaseUrl = process.env.DATABASE_URL?.trim();
  if (!databaseUrl) {
    throw new Error("DATABASE_URL is not configured.");
  }
  return neon(databaseUrl);
}

function numOrNull(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function num(value: unknown, fallback = 0) {
  return numOrNull(value) ?? fallback;
}

function millis(value: unknown): number {
  if (value instanceof Date) return value.getTime();
  const parsed = Date.parse(String(value));
  return Number.isFinite(parsed) ? parsed : Date.now();
}

function nullableMillis(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  return millis(value);
}

function safeJsonArray(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.map((item) => String(item)).filter(Boolean);
  }
  if (typeof value !== "string" || !value.trim()) return [];
  try {
    const parsed = JSON.parse(value) as unknown;
    return Array.isArray(parsed)
      ? parsed.map((item) => String(item)).filter(Boolean)
      : [];
  } catch {
    return [];
  }
}

function normalizeCall(row: DbRow): CallStory {
  return {
    signalRecordId: String(row.signal_record_id),
    callNo: num(row.call_no),
    publicId: String(row.public_id ?? ""),
    signalId: String(row.signal_id),
    tokenAddress: String(row.token_address),
    symbol: String(row.symbol),
    name: String(row.name),
    calledAt: millis(row.called_at),
    entryPriceUsd: numOrNull(row.entry_price_usd),
    callMarketCapUsd: numOrNull(row.call_market_cap_usd),
    currentPriceUsd: numOrNull(row.current_price_usd),
    currentMarketCapUsd: numOrNull(row.current_market_cap_usd),
    peakPriceUsd: numOrNull(row.peak_price_usd),
    peakMarketCapUsd: numOrNull(row.peak_market_cap_usd),
    currentMultiple: numOrNull(row.current_multiple),
    peakMultiple: numOrNull(row.peak_multiple),
    maxDrawdownPct: numOrNull(row.max_drawdown_pct),
    signalScore: num(row.signal_score),
    buyPressurePct: numOrNull(row.buy_pressure_pct),
    volumeSpike: numOrNull(row.volume_spike),
    liquidityUsd: numOrNull(row.liquidity_usd),
    volume5mUsd: numOrNull(row.volume_5m_usd),
    transactions5m: numOrNull(row.transactions_5m),
    priceChange5m: numOrNull(row.price_change_5m),
    pairAgeMinutes: numOrNull(row.pair_age_minutes),
    reasons: safeJsonArray(row.reasons_json),
    baseline: row.baseline === true,
    lastPublicMilestone: num(row.last_public_milestone),
    lastPublicStage: num(row.last_public_stage),
    lastPublicPostAt: nullableMillis(row.last_public_post_at),
    milestone2xAt: nullableMillis(row.milestone_2x_at),
    milestone5xAt: nullableMillis(row.milestone_5x_at),
    milestone10xAt: nullableMillis(row.milestone_10x_at),
    milestone20xAt: nullableMillis(row.milestone_20x_at),
    milestone50xAt: nullableMillis(row.milestone_50x_at),
    milestone100xAt: nullableMillis(row.milestone_100x_at),
  };
}

function normalizeSignalRecord(row: DbRow): SignalRecordRow {
  return {
    id: String(row.id),
    signalId: String(row.signal_id),
    tokenAddress: String(row.token_address),
    symbol: String(row.symbol),
    name: String(row.name),
    openedAt: millis(row.opened_at),
    entryPriceUsd: numOrNull(row.entry_price_usd),
    peakGainPercent: numOrNull(row.peak_gain_pct),
    maxDrawdownPercent: numOrNull(row.max_drawdown_pct),
    scoreAtEntry: num(row.score_at_entry),
  };
}

export function compactUsd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  const absolute = Math.abs(value);
  if (absolute >= 1_000_000_000) return `$${(value / 1_000_000_000).toFixed(2)}B`;
  if (absolute >= 1_000_000) return `$${(value / 1_000_000).toFixed(2)}M`;
  if (absolute >= 1_000) return `$${(value / 1_000).toFixed(0)}K`;
  return `$${value.toFixed(0)}`;
}

export function multipleText(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  return `${value.toFixed(value >= 10 ? 1 : 2)}X`;
}

function pct(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  return `${value > 0 ? "+" : ""}${value.toFixed(1)}%`;
}

function priceText(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  if (value >= 1) return `$${value.toFixed(4)}`;
  return `$${value.toPrecision(6)}`;
}

function durationText(from: number, to: number | null) {
  if (to === null) return "N/A";
  const minutes = Math.max(0, (to - from) / 60_000);
  if (minutes < 60) return `${Math.round(minutes)}m`;
  const hours = minutes / 60;
  if (hours < 24) return `${hours.toFixed(1)}h`;
  return `${(hours / 24).toFixed(1)}d`;
}

function publicIdFor(callNo: number, calledAt: number) {
  const date = new Date(calledAt);
  const month = String(date.getUTCMonth() + 1).padStart(2, "0");
  const day = String(date.getUTCDate()).padStart(2, "0");
  return `MS-${month}${day}-${String(callNo).padStart(3, "0")}`;
}

const PUBLIC_PERFORMANCE_STAGES = [
  { stage: 4, multiple: 3 },
  { stage: 5, multiple: 5 },
  { stage: 6, multiple: 10 },
  { stage: 7, multiple: 20 },
  { stage: 8, multiple: 50 },
  { stage: 9, multiple: 100 },
] as const;

function highestPublicStage(value: number | null) {
  if (value === null || !Number.isFinite(value)) return 0;

  let result = 0;
  for (const item of PUBLIC_PERFORMANCE_STAGES) {
    if (value >= item.multiple) {
      result = item.stage;
    }
  }
  return result;
}

function milestoneColumn(milestone: number) {
  if (milestone === 2) return "milestone_2x_at";
  if (milestone === 5) return "milestone_5x_at";
  if (milestone === 10) return "milestone_10x_at";
  if (milestone === 20) return "milestone_20x_at";
  if (milestone === 50) return "milestone_50x_at";
  return "milestone_100x_at";
}

function median(values: number[]) {
  const clean = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (clean.length === 0) return null;
  const middle = Math.floor(clean.length / 2);
  return clean.length % 2 === 0
    ? (clean[middle - 1] + clean[middle]) / 2
    : clean[middle];
}

export async function ensureCallStorySchema() {
  if (schemaPromise) return schemaPromise;

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_call_story_state (
        id INTEGER PRIMARY KEY,
        initialized_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;
    await sql`INSERT INTO memescope_call_story_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING`;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_call_story (
        signal_record_id TEXT PRIMARY KEY,
        call_no BIGSERIAL UNIQUE,
        public_id TEXT UNIQUE,
        signal_id TEXT NOT NULL,
        token_address TEXT NOT NULL,
        symbol TEXT NOT NULL,
        name TEXT NOT NULL,
        called_at TIMESTAMPTZ NOT NULL,
        entry_price_usd DOUBLE PRECISION,
        call_market_cap_usd DOUBLE PRECISION,
        current_price_usd DOUBLE PRECISION,
        current_market_cap_usd DOUBLE PRECISION,
        peak_price_usd DOUBLE PRECISION,
        peak_market_cap_usd DOUBLE PRECISION,
        current_multiple DOUBLE PRECISION,
        peak_multiple DOUBLE PRECISION,
        max_drawdown_pct DOUBLE PRECISION,
        signal_score INTEGER NOT NULL DEFAULT 0,
        buy_pressure_pct DOUBLE PRECISION,
        volume_spike DOUBLE PRECISION,
        liquidity_usd DOUBLE PRECISION,
        volume_5m_usd DOUBLE PRECISION,
        transactions_5m INTEGER,
        price_change_5m DOUBLE PRECISION,
        pair_age_minutes DOUBLE PRECISION,
        reasons_json TEXT NOT NULL DEFAULT '[]',
        baseline BOOLEAN NOT NULL DEFAULT FALSE,
        last_public_milestone INTEGER NOT NULL DEFAULT 0,
        last_public_stage INTEGER NOT NULL DEFAULT 0,
        last_public_post_at TIMESTAMPTZ,
        milestone_2x_at TIMESTAMPTZ,
        milestone_5x_at TIMESTAMPTZ,
        milestone_10x_at TIMESTAMPTZ,
        milestone_20x_at TIMESTAMPTZ,
        milestone_50x_at TIMESTAMPTZ,
        milestone_100x_at TIMESTAMPTZ,
        telegram_2x_message_id BIGINT,
        telegram_5x_message_id BIGINT,
        telegram_10x_message_id BIGINT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      ALTER TABLE memescope_call_story
      ADD COLUMN IF NOT EXISTS volume_5m_usd DOUBLE PRECISION
    `;

    await sql`
      ALTER TABLE memescope_call_story
      ADD COLUMN IF NOT EXISTS transactions_5m INTEGER
    `;

    await sql`
      ALTER TABLE memescope_call_story
      ADD COLUMN IF NOT EXISTS last_public_stage INTEGER NOT NULL DEFAULT 0
    `;

    await sql`
      ALTER TABLE memescope_call_story
      ADD COLUMN IF NOT EXISTS last_public_post_at TIMESTAMPTZ
    `;

    await sql`ALTER TABLE memescope_call_story ADD COLUMN IF NOT EXISTS last_tracked_at TIMESTAMPTZ`;
    await sql`ALTER TABLE memescope_call_story ADD COLUMN IF NOT EXISTS milestone_claimed_at TIMESTAMPTZ`;
    await sql`ALTER TABLE memescope_call_story ADD COLUMN IF NOT EXISTS milestone_claimed_value INTEGER`;
    await sql`ALTER TABLE memescope_call_story_state ADD COLUMN IF NOT EXISTS latest_tracking_run_at TIMESTAMPTZ`;
    await sql`ALTER TABLE memescope_call_story_state ADD COLUMN IF NOT EXISTS tracking_diagnostics JSONB`;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_call_update_state (
        id INTEGER PRIMARY KEY,
        version INTEGER NOT NULL DEFAULT 0,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_call_update_state (id, version)
      VALUES (1, 0)
      ON CONFLICT (id) DO NOTHING
    `;

    // Earlier schema initialization marked observed peaks as "published" even
    // when no result was sent. Restore eligibility only where no post evidence exists.
    await sql`
      UPDATE memescope_call_story c
      SET last_public_milestone = 0, last_public_stage = 0
      WHERE c.last_public_post_at IS NULL
        AND c.telegram_2x_message_id IS NULL
        AND c.telegram_5x_message_id IS NULL
        AND c.telegram_10x_message_id IS NULL
        AND (SELECT version FROM memescope_call_update_state WHERE id = 1) < 3
    `;
    await sql`
      UPDATE memescope_call_story c
      SET last_public_milestone = GREATEST(last_public_milestone,
        CASE
          WHEN last_public_stage >= 9 THEN 100
          WHEN last_public_stage >= 8 THEN 50
          WHEN last_public_stage >= 7 THEN 20
          WHEN last_public_stage >= 6 THEN 10
          WHEN last_public_stage >= 5 THEN 5
          WHEN last_public_stage >= 4 THEN 3
          ELSE 0
        END)
      WHERE c.last_public_post_at IS NOT NULL
        AND (SELECT version FROM memescope_call_update_state WHERE id = 1) < 3
    `;

    await sql`
      UPDATE memescope_call_update_state
      SET version = 3, updated_at = NOW()
      WHERE id = 1 AND version < 3
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_call_story_called_idx
      ON memescope_call_story (called_at DESC)
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_call_story_peak_idx
      ON memescope_call_story (peak_multiple DESC NULLS LAST)
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_settings (
        id INTEGER PRIMARY KEY,
        content_hq_chat_id TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      INSERT INTO memescope_content_settings (id)
      VALUES (1)
      ON CONFLICT (id) DO NOTHING
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_content_opportunities (
        id BIGSERIAL PRIMARY KEY,
        signal_record_id TEXT,
        public_id TEXT,
        opportunity_type TEXT NOT NULL,
        priority TEXT NOT NULL,
        milestone_multiple DOUBLE PRECISION,
        draft_text TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        telegram_message_id BIGINT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        sent_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (signal_record_id, opportunity_type)
      )
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_public_reports (
        report_key TEXT PRIMARY KEY,
        report_type TEXT NOT NULL,
        report_date TEXT NOT NULL,
        public_message_id BIGINT,
        content_hq_message_id BIGINT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

type DexPair = {
  chainId?: string;
  priceUsd?: string;
  marketCap?: number;
  fdv?: number;
  baseToken?: { address?: string };
  liquidity?: { usd?: number };
};

async function fetchMarketSnapshots(addresses: string[]) {
  const unique = Array.from(new Set(addresses.filter(Boolean)));
  const result = new Map<string, MarketSnapshot>();
  const pending: string[][] = [];
  for (let index = 0; index < unique.length; index += 30) {
    pending.push(unique.slice(index, index + 30));
  }
  while (pending.length > 0) {
    const batch = pending.shift()!;
    if (batch.length === 0) continue;

    try {
      const response = await fetch(
        `https://api.dexscreener.com/tokens/v1/solana/${batch.join(",")}`,
        { cache: "no-store", headers: { accept: "application/json" }, signal: AbortSignal.timeout(10_000) },
      );
      if (!response.ok) {
        if (response.status !== 429 && batch.length > 1) {
          const middle = Math.ceil(batch.length / 2);
          pending.push(batch.slice(0, middle), batch.slice(middle));
        }
        continue;
      }

      const pairs = (await response.json()) as DexPair[];
      if (!Array.isArray(pairs)) continue;
      const bestLiquidity = new Map<string, number>();

      for (const pair of pairs) {
        const address = pair.baseToken?.address;
        if (!address) continue;
        const liquidity = Number(pair.liquidity?.usd ?? 0);
        if (liquidity < (bestLiquidity.get(address) ?? -1)) continue;

        const parsedPrice = Number(pair.priceUsd);
        const marketCap = Number(pair.marketCap ?? pair.fdv);
        result.set(address, {
          priceUsd: Number.isFinite(parsedPrice) && parsedPrice > 0 ? parsedPrice : null,
          marketCapUsd: Number.isFinite(marketCap) && marketCap > 0 ? marketCap : null,
          liquidityUsd: Number.isFinite(liquidity) && liquidity > 0 ? liquidity : null,
        });
        bestLiquidity.set(address, liquidity);
      }
    } catch (error) {
      // Keep the last stored snapshot when DexScreener is temporarily unavailable.
      if (error instanceof SyntaxError && batch.length > 1) {
        const middle = Math.ceil(batch.length / 2);
        pending.push(batch.slice(0, middle), batch.slice(middle));
      }
    }
  }

  return result;
}

async function recoverPublishedCallRows() {
  const sql = sqlClient();
  const rows = await sql`
    SELECT r.id, r.signal_id, r.token_address, r.symbol, r.name,
      r.opened_at, r.entry_price_usd, r.current_price_usd,
      r.peak_price_usd, r.peak_gain_pct, r.score_at_entry
    FROM memescope_signal_records r
    JOIN memescope_telegram_posts p ON p.signal_record_id = r.id
    LEFT JOIN memescope_call_story c ON c.signal_record_id = r.id
    WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
      AND c.signal_record_id IS NULL
    ORDER BY r.opened_at ASC
    LIMIT 100
  `;
  let recovered = 0;
  for (const raw of rows) {
    const row = raw as DbRow;
    const entry = numOrNull(row.entry_price_usd);
    const storedPeak = numOrNull(row.peak_price_usd);
    const peak = entry && entry > 0 && storedPeak && storedPeak > 0
      ? Math.max(1, storedPeak / entry) : 1;
    const inserted = await sql`
      INSERT INTO memescope_call_story (
        signal_record_id, signal_id, token_address, symbol, name,
        called_at, entry_price_usd, current_price_usd, peak_price_usd,
        peak_multiple, signal_score, baseline
      ) VALUES (
        ${String(row.id)}, ${String(row.signal_id)}, ${String(row.token_address)},
        ${String(row.symbol)}, ${String(row.name)}, ${new Date(millis(row.opened_at)).toISOString()},
        ${entry}, ${numOrNull(row.current_price_usd)}, ${storedPeak},
        ${peak}, ${num(row.score_at_entry)}, FALSE
      ) ON CONFLICT (signal_record_id) DO NOTHING
      RETURNING signal_record_id
    `;
    if (inserted[0]) recovered++;
    await ensurePublicId(String(row.id));
  }
  return recovered;
}

export async function trackPersistedCallPerformance() {
  await ensureCallStorySchema();
  const sql = sqlClient();
  const recoveredCalls = await recoverPublishedCallRows();
  const batchSize = Math.max(1, Math.min(300, Number(process.env.PERFORMANCE_TRACK_BATCH_SIZE) || 150));
  const rows = await sql`
    SELECT c.* FROM memescope_call_story c
    JOIN memescope_telegram_posts p ON p.signal_record_id = c.signal_record_id
    WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
    ORDER BY c.last_tracked_at ASC NULLS FIRST, c.called_at ASC
    LIMIT ${batchSize}
  `;
  const calls = rows.map((row) => normalizeCall(row as DbRow));
  const markets = await fetchMarketSnapshots(calls.map((call) => call.tokenAddress));
  const performanceMarkets = new Map(Array.from(markets, ([address, market]) => [address, {
    priceUsd: market.priceUsd, marketCapUsd: market.marketCapUsd,
  }]));
  const diagnostics: Record<string, number | string> = {
    trackedCalls: calls.length, recoveredCalls, marketFetchSuccess: 0,
    marketFetchFailed: 0, updatedCalls: 0, peakBelow3x: 0,
    reached3x: 0, reached5x: 0, reached10x: 0,
    reached20x: 0, reached50x: 0, reached100x: 0,
    pendingMilestones: 0, publishedMilestones: 0,
    missingMarketData: 0, missingPublicationEvidence: 0, staleCalls: 0,
    latestTrackingRunAt: new Date().toISOString(),
  };
  const missingEvidenceRows = await sql`
    SELECT COUNT(*) AS count FROM memescope_call_story c
    LEFT JOIN memescope_telegram_posts p ON p.signal_record_id = c.signal_record_id
    WHERE p.signal_record_id IS NULL OR p.baseline = TRUE OR p.first_sent_at IS NULL
  `;
  diagnostics.missingPublicationEvidence = num((missingEvidenceRows[0] as DbRow).count);
  for (const call of calls) {
    try {
      const observed = evaluatePersistedCall(call, performanceMarkets);
      if (!observed) {
        diagnostics.marketFetchFailed = Number(diagnostics.marketFetchFailed) + 1;
        diagnostics.missingMarketData = Number(diagnostics.missingMarketData) + 1;
        await sql`UPDATE memescope_call_story SET last_tracked_at = NOW()
          WHERE signal_record_id = ${call.signalRecordId}`;
        continue;
      }
      diagnostics.marketFetchSuccess = Number(diagnostics.marketFetchSuccess) + 1;
      const { price, cap, callCap: inferredCallCap } = observed;
      await sql`
        UPDATE memescope_call_story SET
          call_market_cap_usd = COALESCE(call_market_cap_usd, ${inferredCallCap}),
          current_price_usd = COALESCE(${price}, current_price_usd),
          current_market_cap_usd = COALESCE(${cap}, current_market_cap_usd),
          current_multiple = COALESCE(${observed.current}, current_multiple),
          peak_price_usd = GREATEST(COALESCE(peak_price_usd, 0), COALESCE(CAST(${price} AS DOUBLE PRECISION), 0)),
          peak_market_cap_usd = GREATEST(COALESCE(peak_market_cap_usd, 0), COALESCE(CAST(${cap} AS DOUBLE PRECISION), 0)),
          peak_multiple = GREATEST(COALESCE(peak_multiple, 1), ${observed.peak}),
          last_tracked_at = NOW(), updated_at = NOW()
        WHERE signal_record_id = ${call.signalRecordId}
      `;
      diagnostics.updatedCalls = Number(diagnostics.updatedCalls) + 1;
      const peak = observed.peak;
      if (peak < 3) diagnostics.peakBelow3x = Number(diagnostics.peakBelow3x) + 1;
      for (const milestone of [3, 5, 10, 20, 50, 100]) {
        if (peak >= milestone) diagnostics[`reached${milestone}x`] = Number(diagnostics[`reached${milestone}x`]) + 1;
      }
      if (nextPublicMilestone(peak, call.lastPublicMilestone)) {
        diagnostics.pendingMilestones = Number(diagnostics.pendingMilestones) + 1;
      }
      if (Date.now() - call.calledAt > 48 * 60 * 60_000) {
        diagnostics.staleCalls = Number(diagnostics.staleCalls) + 1;
      }
    } catch (error) {
      diagnostics.marketFetchFailed = Number(diagnostics.marketFetchFailed) + 1;
      console.error("MemeScope persisted call tracking failed:", call.signalRecordId, error);
    }
  }
  await sql`UPDATE memescope_call_story_state
    SET latest_tracking_run_at = NOW(), tracking_diagnostics = ${JSON.stringify(diagnostics)}::jsonb
    WHERE id = 1`;
  return diagnostics;
}

async function initializeCallStoryBaseline() {
  await ensureCallStorySchema();
  const sql = sqlClient();

  const existing = await sql`
    SELECT initialized_at
    FROM memescope_call_story_state
    WHERE id = 1
    LIMIT 1
  `;

  if (existing[0]) {
    return { initialized: false, initializedAt: millis((existing[0] as DbRow).initialized_at) };
  }

  const now = new Date();
  await sql`
    INSERT INTO memescope_call_story_state (id, initialized_at)
    VALUES (1, ${now.toISOString()})
    ON CONFLICT (id) DO NOTHING
  `;

  return { initialized: true, initializedAt: now.getTime() };
}

async function ensurePublicId(signalRecordId: string) {
  const sql = sqlClient();
  const rows = await sql`
    SELECT call_no, public_id, called_at
    FROM memescope_call_story
    WHERE signal_record_id = ${signalRecordId}
    LIMIT 1
  `;
  const row = rows[0] as DbRow | undefined;
  if (!row) return "";
  if (row.public_id) return String(row.public_id);

  const publicId = publicIdFor(num(row.call_no), millis(row.called_at));
  await sql`
    UPDATE memescope_call_story
    SET public_id = ${publicId}, updated_at = NOW()
    WHERE signal_record_id = ${signalRecordId}
  `;
  return publicId;
}

async function setMilestoneTimes(
  signalRecordId: string,
  peakMultiple: number | null,
) {
  if (peakMultiple === null) return;
  const sql = sqlClient();
  const thresholds = [2, 5, 10, 20, 50, 100];
  for (const threshold of thresholds) {
    if (peakMultiple < threshold) continue;
    const column = milestoneColumn(threshold);
    if (column === "milestone_2x_at") {
      await sql`UPDATE memescope_call_story SET milestone_2x_at = COALESCE(milestone_2x_at, NOW()) WHERE signal_record_id = ${signalRecordId}`;
    } else if (column === "milestone_5x_at") {
      await sql`UPDATE memescope_call_story SET milestone_5x_at = COALESCE(milestone_5x_at, NOW()) WHERE signal_record_id = ${signalRecordId}`;
    } else if (column === "milestone_10x_at") {
      await sql`UPDATE memescope_call_story SET milestone_10x_at = COALESCE(milestone_10x_at, NOW()) WHERE signal_record_id = ${signalRecordId}`;
    } else if (column === "milestone_20x_at") {
      await sql`UPDATE memescope_call_story SET milestone_20x_at = COALESCE(milestone_20x_at, NOW()) WHERE signal_record_id = ${signalRecordId}`;
    } else if (column === "milestone_50x_at") {
      await sql`UPDATE memescope_call_story SET milestone_50x_at = COALESCE(milestone_50x_at, NOW()) WHERE signal_record_id = ${signalRecordId}`;
    } else {
      await sql`UPDATE memescope_call_story SET milestone_100x_at = COALESCE(milestone_100x_at, NOW()) WHERE signal_record_id = ${signalRecordId}`;
    }
  }
}

async function syncCallRows(tokens: TerminalToken[], signals: SignalCall[]) {
  const state = await initializeCallStoryBaseline();
  const sql = sqlClient();

  const recordRows = await sql`
    SELECT *
    FROM memescope_signal_records
    WHERE opened_at >= NOW() - INTERVAL '60 days'
      AND NOT EXISTS (
        SELECT 1 FROM memescope_telegram_posts p
        WHERE p.signal_record_id = memescope_signal_records.id
          AND p.baseline = FALSE AND p.first_sent_at IS NOT NULL
      )
    ORDER BY opened_at ASC
    LIMIT 1000
  `;

  const records: SignalRecordRow[] = recordRows.map((row: unknown) => normalizeSignalRecord(row as DbRow));
  const tokenMap = new Map(tokens.map((token) => [token.address, token]));
  const signalMap = new Map(signals.map((signal) => [signal.id, signal]));
  const marketSnapshots = await fetchMarketSnapshots(records.map((record: SignalRecordRow) => record.tokenAddress));

  // MEMESCOPE CALL STORY RECORD ISOLATION
  // One stale/broken historical record must never prevent newer
  // calls from receiving their Call Story/public ID/market snapshot.
  for (const record of records) {
    try {
    const token = tokenMap.get(record.tokenAddress);
    const signal = signalMap.get(record.signalId);
    const market = marketSnapshots.get(record.tokenAddress);

    const currentPrice = token?.priceUsd ?? market?.priceUsd ?? null;
    const currentMarketCap = token?.marketCap ?? market?.marketCapUsd ?? null;
    const entry = record.entryPriceUsd;

    const inferredCallMarketCap =
      currentMarketCap !== null && currentPrice !== null && currentPrice > 0 && entry !== null && entry > 0
        ? currentMarketCap * (entry / currentPrice)
        : signal?.marketCap ?? null;

    const currentMultiple =
      entry !== null && entry > 0 && currentPrice !== null && currentPrice > 0
        ? currentPrice / entry
        : null;

    const recordPeakMultiple =
      record.peakGainPercent !== null
        ? Math.max(0, 1 + record.peakGainPercent / 100)
        : null;

    const existingRows = await sql`
      SELECT *
      FROM memescope_call_story
      WHERE signal_record_id = ${record.id}
      LIMIT 1
    `;
    const existing = existingRows[0] ? normalizeCall(existingRows[0] as DbRow) : null;

    const callMarketCap = existing?.callMarketCapUsd ?? signal?.marketCap ?? inferredCallMarketCap;
    const peakMultiple = Math.max(
      existing?.peakMultiple ?? 0,
      currentMultiple ?? 0,
      recordPeakMultiple ?? 0,
      1,
    );
    const peakPrice = Math.max(existing?.peakPriceUsd ?? 0, currentPrice ?? 0, entry ?? 0) || null;
    const derivedPeakMc = callMarketCap !== null ? callMarketCap * peakMultiple : null;
    const peakMarketCap = Math.max(existing?.peakMarketCapUsd ?? 0, currentMarketCap ?? 0, derivedPeakMc ?? 0) || null;
    const maxDrawdown = Math.min(
      existing?.maxDrawdownPct ?? 0,
      record.maxDrawdownPercent ?? 0,
      currentMultiple !== null ? (currentMultiple - 1) * 100 : 0,
    );

    const baseline = record.openedAt <= state.initializedAt;
    const initialPublicMilestone = 0;
    const initialPublicStage = 0;
    const reasons = signal?.reasons ?? existing?.reasons ?? [];
    const buyPressurePct = signal?.buyShare5m !== null && signal?.buyShare5m !== undefined
      ? signal.buyShare5m * 100
      : existing?.buyPressurePct ?? null;

    if (!existing) {
      await sql`
        INSERT INTO memescope_call_story (
          signal_record_id,
          signal_id,
          token_address,
          symbol,
          name,
          called_at,
          entry_price_usd,
          call_market_cap_usd,
          current_price_usd,
          current_market_cap_usd,
          peak_price_usd,
          peak_market_cap_usd,
          current_multiple,
          peak_multiple,
          max_drawdown_pct,
          signal_score,
          buy_pressure_pct,
          volume_spike,
          liquidity_usd,
          volume_5m_usd,
          transactions_5m,
          price_change_5m,
          pair_age_minutes,
          reasons_json,
          baseline,
          last_public_milestone,
          last_public_stage,
          updated_at
        ) VALUES (
          ${record.id},
          ${record.signalId},
          ${record.tokenAddress},
          ${record.symbol},
          ${record.name},
          ${new Date(record.openedAt).toISOString()},
          ${entry},
          ${callMarketCap},
          ${currentPrice},
          ${currentMarketCap},
          ${peakPrice},
          ${peakMarketCap},
          ${currentMultiple},
          ${peakMultiple},
          ${maxDrawdown},
          ${signal?.signalScore ?? record.scoreAtEntry},
          ${buyPressurePct},
          ${signal?.volumeSpike5m ?? null},
          ${signal?.liquidityUsd ?? token?.liquidityUsd ?? market?.liquidityUsd ?? null},
          ${signal?.volume5m ?? token?.volume.m5 ?? null},
          ${
            signal
              ? signal.buys5m + signal.sells5m
              : token
                ? token.txns.m5.buys + token.txns.m5.sells
                : null
          },
          ${signal?.priceChange5m ?? token?.priceChange.m5 ?? null},
          ${signal?.pairAgeMinutes ?? token?.pairAgeMinutes ?? null},
          ${JSON.stringify(reasons)},
          ${baseline},
          ${initialPublicMilestone},
          ${initialPublicStage},
          NOW()
        )
        ON CONFLICT (signal_record_id) DO NOTHING
      `;
    } else {
      await sql`
        UPDATE memescope_call_story
        SET
          current_price_usd = COALESCE(${currentPrice}, current_price_usd),
          current_market_cap_usd = COALESCE(${currentMarketCap}, current_market_cap_usd),
          call_market_cap_usd = COALESCE(call_market_cap_usd, ${callMarketCap}),
          peak_price_usd = GREATEST(COALESCE(peak_price_usd, 0), COALESCE(CAST(${peakPrice} AS DOUBLE PRECISION), 0)),
          peak_market_cap_usd = GREATEST(COALESCE(peak_market_cap_usd, 0), COALESCE(CAST(${peakMarketCap} AS DOUBLE PRECISION), 0)),
          current_multiple = COALESCE(${currentMultiple}, current_multiple),
          peak_multiple = GREATEST(COALESCE(peak_multiple, 1), COALESCE(CAST(${peakMultiple} AS DOUBLE PRECISION), 1)),
          max_drawdown_pct = LEAST(COALESCE(max_drawdown_pct, 0), COALESCE(CAST(${maxDrawdown} AS DOUBLE PRECISION), 0)),
          signal_score = GREATEST(signal_score, ${signal?.signalScore ?? record.scoreAtEntry}),
          buy_pressure_pct = COALESCE(buy_pressure_pct, ${buyPressurePct}),
          volume_spike = COALESCE(volume_spike, ${signal?.volumeSpike5m ?? existing.volumeSpike ?? null}),
          liquidity_usd = COALESCE(${signal?.liquidityUsd ?? token?.liquidityUsd ?? market?.liquidityUsd ?? null}, liquidity_usd),
          volume_5m_usd = COALESCE(
            ${signal?.volume5m ?? token?.volume.m5 ?? null},
            volume_5m_usd
          ),
          transactions_5m = COALESCE(
            ${
              signal
                ? signal.buys5m + signal.sells5m
                : token
                  ? token.txns.m5.buys + token.txns.m5.sells
                  : null
            },
            transactions_5m
          ),
          price_change_5m = COALESCE(price_change_5m, ${signal?.priceChange5m ?? token?.priceChange.m5 ?? null}),
          pair_age_minutes = COALESCE(pair_age_minutes, ${signal?.pairAgeMinutes ?? token?.pairAgeMinutes ?? null}),
          reasons_json = CASE
            WHEN reasons_json = '[]' THEN ${JSON.stringify(reasons)}
            ELSE reasons_json
          END,
          updated_at = NOW()
        WHERE signal_record_id = ${record.id}
      `;
    }

    await ensurePublicId(record.id);
    await setMilestoneTimes(record.id, peakMultiple);
    } catch (error) {
      console.error(
        "MemeScope Call Story record sync failed:",
        {
          signalRecordId: record.id,
          signalId: record.signalId,
          tokenAddress: record.tokenAddress,
          error:
            error instanceof Error
              ? error.message
              : String(error),
        },
      );

      // Continue with the next signal record instead of aborting
      // the entire Call Story cycle.
      continue;
    }
  }

  return { baselineInitialized: state.initialized, tracked: records.length };
}

export async function getCallStoryForSignalRecord(signalRecordId: string) {
  await ensureCallStorySchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE signal_record_id = ${signalRecordId}
    LIMIT 1
  `;
  return rows[0] ? normalizeCall(rows[0] as DbRow) : null;
}

export async function getCallByPublicId(publicId: string) {
  await ensureCallStorySchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE UPPER(public_id) = UPPER(${publicId})
    LIMIT 1
  `;
  return rows[0] ? normalizeCall(rows[0] as DbRow) : null;
}

export async function getCallDashboard(days = 30): Promise<CallDashboard> {
  await ensureCallStorySchema();
  const sql = sqlClient();
  const safeDays = Math.max(1, Math.min(3650, Math.round(days)));
  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE called_at >= NOW() - (${safeDays} * INTERVAL '1 day')
    ORDER BY called_at DESC
    LIMIT 1000
  `;
  const calls: CallStory[] = rows.map((row: unknown) => normalizeCall(row as DbRow));
  const topCalls = [...calls]
    .sort((a: CallStory, b: CallStory) => (b.peakMultiple ?? 0) - (a.peakMultiple ?? 0))
    .slice(0, 20);

  return {
    days: safeDays,
    totalCalls: calls.length,
    runningCalls: calls.filter((call: CallStory) => {
      const ageMs = Date.now() - call.calledAt;
      return (
        ageMs <= 48 * 60 * 60 * 1000 &&
        (call.currentMultiple ?? 0) >= 1.05
      );
    }).length,
    reached2x: calls.filter((call: CallStory) => (call.peakMultiple ?? 0) >= 2).length,
    reached5x: calls.filter((call: CallStory) => (call.peakMultiple ?? 0) >= 5).length,
    reached10x: calls.filter((call: CallStory) => (call.peakMultiple ?? 0) >= 10).length,
    medianPeakMultiple: median(calls.map((call: CallStory) => call.peakMultiple).filter((value: number | null): value is number => value !== null)),
    medianMaxDrawdownPct: median(calls.map((call: CallStory) => call.maxDrawdownPct).filter((value: number | null): value is number => value !== null)),
    topCalls,
    recentCalls: calls.slice(0, 30),
  };
}

export async function bindContentHq(chatId: string | number) {
  await ensureCallStorySchema();
  const sql = sqlClient();
  await sql`
    UPDATE memescope_content_settings
    SET content_hq_chat_id = ${String(chatId)}, updated_at = NOW()
    WHERE id = 1
  `;
  return String(chatId);
}

export async function getContentHqStatus() {
  await ensureCallStorySchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT content_hq_chat_id, updated_at
    FROM memescope_content_settings
    WHERE id = 1
    LIMIT 1
  `;
  const row = rows[0] as DbRow | undefined;
  return {
    configured: Boolean(row?.content_hq_chat_id),
    chatId: row?.content_hq_chat_id ? String(row.content_hq_chat_id) : null,
    updatedAt: row?.updated_at ? millis(row.updated_at) : null,
  };
}

export async function setContentOpportunityStatus(
  id: number,
  status: "used" | "skipped" | "pending",
) {
  await ensureCallStorySchema();
  const sql = sqlClient();
  await sql`
    UPDATE memescope_content_opportunities
    SET status = ${status}, updated_at = NOW()
    WHERE id = ${id}
  `;
}

async function originalTelegramMessageId(signalRecordId: string) {
  const sql = sqlClient();
  try {
    const rows = await sql`
      SELECT message_id
      FROM memescope_telegram_posts
      WHERE signal_record_id = ${signalRecordId}
      LIMIT 1
    `;
    return rows[0] ? numOrNull((rows[0] as DbRow).message_id) : null;
  } catch {
    return null;
  }
}

function channelMessageUrl(messageId: number | null) {
  const { channelUrl } = telegramConfig();
  if (!messageId || !channelUrl) return null;
  return `${channelUrl.replace(/\/+$/, "")}/${messageId}`;
}

function milestoneButtons(
  call: CallStory,
  originalMessageIdValue: number | null,
) {
  const site = telegramSiteUrl();
  const originalUrl = channelMessageUrl(originalMessageIdValue);
  const firstRow: Array<{ text: string; url: string }> = [];

  if (originalUrl) {
    firstRow.push({
      text: "📌 Original Call",
      url: originalUrl,
    });
  }

  firstRow.push({
    text: "🧭 Call Journey",
    url:
      `${site}/calls/${encodeURIComponent(
        call.publicId,
      )}`,
  });

  return {
    inline_keyboard: [
      firstRow,
      [
        {
          text: "📊 Live Chart",
          url:
            `https://dexscreener.com/solana/${encodeURIComponent(
              call.tokenAddress,
            )}`,
        },
        {
          text: "🌐 MemeScope",
          url: site,
        },
      ],
    ],
  };
}

function performanceTelegramText(
  call: CallStory,
  milestone: number,
) {
  const peak =
    call.peakMultiple ??
    call.currentMultiple ??
    1;
  const gain =
    Math.max(
      0,
      (peak - 1) * 100,
    );
  const peakMc =
    call.peakMarketCapUsd ??
    call.currentMarketCapUsd;

  return [
    `<b>\u{1F680} $${escapeTelegramHtml(
      call.symbol,
    )} \u{1F4B0} +${gain.toFixed(
      gain >= 100 ? 0 : 1,
    )}% SINCE MEMESCOPE CALL</b>`,
    "",
    `\u{1F4CA} Call MC: <b>${compactUsd(
      call.callMarketCapUsd,
    )}</b> \u2192 Peak MC: <b>${compactUsd(
      peakMc,
    )}</b>`,
     `\u{1F4C8} Peak: <b>${multipleText(
      peak,
     )}</b>`,
     `Elapsed: <b>${durationText(call.calledAt, Date.now())}</b> · Call ID: <b>${escapeTelegramHtml(call.publicId)}</b>`,
    "",
    `CA: <code>${escapeTelegramHtml(
      call.tokenAddress,
    )}</code>`,
    "",
    "<i>Tracked from the original timestamped MemeScope call.</i>",
  ].join("\n");
}

async function publishPendingPublicMilestones() {
  if (!telegramConfigured()) {
    return { sent: 0 };
  }

  const sql = sqlClient();
  const { channelId } =
    telegramConfig();

  const rows = await sql`
    SELECT c.*
    FROM memescope_call_story c
    JOIN memescope_telegram_posts p ON p.signal_record_id = c.signal_record_id
    WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
      AND c.peak_multiple >= 3
      AND c.last_public_milestone < 100
      AND c.last_public_milestone < CASE
        WHEN c.peak_multiple >= 100 THEN 100
        WHEN c.peak_multiple >= 50 THEN 50
        WHEN c.peak_multiple >= 20 THEN 20
        WHEN c.peak_multiple >= 10 THEN 10
        WHEN c.peak_multiple >= 5 THEN 5
        ELSE 3 END
    ORDER BY c.last_public_post_at ASC NULLS FIRST, c.called_at ASC
    LIMIT 40
  `;

  let sent = 0;

  for (const raw of rows) {
    const call =
      normalizeCall(
        raw as DbRow,
      );

    const threshold = nextPublicMilestone(call.peakMultiple, call.lastPublicMilestone);
    const stage = highestPublicStage(call.peakMultiple);

    if (
      threshold === 0 || sent >= 3
    ) {
      continue;
    }

    const claimed = await sql`
      UPDATE memescope_call_story
      SET milestone_claimed_at = NOW(), milestone_claimed_value = ${threshold}
      WHERE signal_record_id = ${call.signalRecordId}
        AND last_public_milestone < ${threshold}
        AND (milestone_claimed_at IS NULL OR milestone_claimed_at < NOW() - INTERVAL '20 minutes')
      RETURNING signal_record_id
    `;
    if (!claimed[0]) continue;

    try {

    const originalMessageIdValue =
      await originalTelegramMessageId(
        call.signalRecordId,
      );

    const caption =
      performanceTelegramText(
        call,
         threshold,
      );
    const replyMarkup =
      milestoneButtons(
        call,
        originalMessageIdValue,
      );
    const peakMc =
      call.peakMarketCapUsd ??
      call.currentMarketCapUsd;

    let message;

    try {
      const card =
        await renderSignalResultCard(
          {
            symbol:
              call.symbol,
            callMarketCapUsd:
              call.callMarketCapUsd,
            peakMarketCapUsd:
              peakMc,
             peakMultiple:
               call.peakMultiple,
            calledAt:
              call.calledAt,
            tokenAddress:
              call.tokenAddress,
            publicId:
              call.publicId,
          },
        );

      message =
        await telegramSendPhotoUpload(
          channelId,
          card,
          {
            caption,
            replyMarkup,
          },
        );
    } catch (cardError) {
      console.error(
        "MemeScope VIP result card failed; using text fallback:",
        cardError,
      );

      message =
        await telegramSendMessage(
          channelId,
          caption,
          {
            replyMarkup,
          },
        );
    }

    await sql`
      UPDATE memescope_call_story
      SET
        last_public_stage = ${stage},
        last_public_milestone = ${threshold},
        last_public_post_at = NOW(),
        milestone_claimed_at = NULL,
        milestone_claimed_value = NULL,
        updated_at = NOW()
      WHERE signal_record_id = ${call.signalRecordId}
    `;

    if (threshold === 5) {
      await sql`
        UPDATE memescope_call_story
        SET telegram_5x_message_id = ${message.message_id}
        WHERE signal_record_id = ${call.signalRecordId}
      `;
    } else if (threshold === 10) {
      await sql`
        UPDATE memescope_call_story
        SET telegram_10x_message_id = ${message.message_id}
        WHERE signal_record_id = ${call.signalRecordId}
      `;
    }

    sent += 1;
    } catch (error) {
      await sql`UPDATE memescope_call_story
        SET milestone_claimed_at = NULL, milestone_claimed_value = NULL
        WHERE signal_record_id = ${call.signalRecordId} AND milestone_claimed_value = ${threshold}`;
      console.error("MemeScope VIP milestone publish failed:", call.signalRecordId, error);
    }
  }

  return { sent };
}

function resultDraft(call: CallStory) {
  return [
    `MemeScope flagged $${call.symbol} at ${compactUsd(call.callMarketCapUsd)} MC. It later reached ${compactUsd(call.peakMarketCapUsd)}.`,
    "",
    `${multipleText(call.peakMultiple)} from the original call.`,
    `Original call: ${call.publicId}.`,
  ].join("\n");
}

function beforeMoveDraft(call: CallStory) {
  return [
    `What MemeScope saw before $${call.symbol} moved from ${compactUsd(call.callMarketCapUsd)} to ${compactUsd(call.peakMarketCapUsd)}:`,
    "",
    `Buy pressure: ${call.buyPressurePct === null ? "N/A" : `${call.buyPressurePct.toFixed(0)}%`}`,
    `Volume expansion: ${call.volumeSpike === null ? "N/A" : `${call.volumeSpike.toFixed(1)}X`}`,
    `Liquidity: ${compactUsd(call.liquidityUsd)}`,
    `Signal score: ${Math.round(call.signalScore)}/100`,
    "",
    `Peak since call: ${multipleText(call.peakMultiple)}.`,
  ].join("\n");
}

async function createOpportunity(
  call: CallStory,
  type: string,
  priority: string,
  milestone: number,
  draft: string,
) {
  const sql = sqlClient();
  await sql`
    INSERT INTO memescope_content_opportunities (
      signal_record_id,
      public_id,
      opportunity_type,
      priority,
      milestone_multiple,
      draft_text
    ) VALUES (
      ${call.signalRecordId},
      ${call.publicId},
      ${type},
      ${priority},
      ${milestone},
      ${draft}
    )
    ON CONFLICT (signal_record_id, opportunity_type)
    DO UPDATE SET
      priority = EXCLUDED.priority,
      milestone_multiple = GREATEST(COALESCE(memescope_content_opportunities.milestone_multiple, 0), EXCLUDED.milestone_multiple),
      draft_text = EXCLUDED.draft_text,
      updated_at = NOW()
  `;
}

async function discoverContentOpportunities() {
  const sql = sqlClient();
  const rows = await sql`
    SELECT *
    FROM memescope_call_story
    WHERE baseline = FALSE
      AND peak_multiple >= 2
    ORDER BY called_at DESC
    LIMIT 300
  `;

  for (const raw of rows) {
    const call = normalizeCall(raw as DbRow);
    const time2xMinutes = call.milestone2xAt === null ? null : (call.milestone2xAt - call.calledAt) / 60_000;

    const peak = call.peakMultiple ?? 0;

    if (peak >= 10) {
      await createOpportunity(call, "exceptional_10x", "FEATURED", 10, resultDraft(call));
    } else if (peak >= 5) {
      await createOpportunity(call, "major_5x", "HIGH", 5, resultDraft(call));
    } else if (peak >= 2 && time2xMinutes !== null && time2xMinutes <= 60) {
      await createOpportunity(call, "fast_2x", "MEDIUM", 2, resultDraft(call));
    }

    if (peak >= 100) {
      await createOpportunity(call, "special_100x", "SPECIAL", 100, resultDraft(call));
    } else if (peak >= 50) {
      await createOpportunity(call, "special_50x", "SPECIAL", 50, resultDraft(call));
    } else if (peak >= 20) {
      await createOpportunity(call, "special_20x", "SPECIAL", 20, resultDraft(call));
    }
  }
}

async function publishPendingContentOpportunities() {
  const status = await getContentHqStatus();
  if (!status.configured || !status.chatId) return { sent: 0 };
  const sql = sqlClient();
  const site = telegramSiteUrl();
  const rows = await sql`
    SELECT *
    FROM memescope_content_opportunities
    WHERE status = 'pending'
      AND sent_at IS NULL
    ORDER BY
      CASE priority
        WHEN 'SPECIAL' THEN 1
        WHEN 'FEATURED' THEN 2
        WHEN 'HIGH' THEN 3
        ELSE 4
      END,
      created_at ASC
    LIMIT 12
  `;

  let sent = 0;
  for (const raw of rows) {
    const row = raw as DbRow;
    const id = num(row.id);
    const publicId = String(row.public_id ?? "");
    const call = publicId ? await getCallByPublicId(publicId) : null;
    if (!call) continue;

    const draft = String(row.draft_text ?? "");
    const text = [
      "🎬 <b>MEMESCOPE CONTENT OPPORTUNITY</b>",
      "",
      `<b>$${escapeTelegramHtml(call.symbol)}</b> — ${escapeTelegramHtml(String(row.priority ?? "MEDIUM"))} PRIORITY`,
      `<code>${escapeTelegramHtml(call.publicId)}</code>`,
      "",
      `Call MC: <b>${compactUsd(call.callMarketCapUsd)}</b>`,
      `Peak MC: <b>${compactUsd(call.peakMarketCapUsd)}</b>`,
      `Peak: <b>${multipleText(call.peakMultiple)}</b>`,
      `Signal Score: <b>${Math.round(call.signalScore)}/100</b>`,
      "",
      "<b>Suggested X hook</b>",
      escapeTelegramHtml(draft),
      "",
      "<b>Before The Move angle</b>",
      escapeTelegramHtml(beforeMoveDraft(call)),
      "",
      "<i>No X post is sent automatically. This is an admin content inbox.</i>",
    ].join("\n");

    const message = await telegramSendMessage(status.chatId, text, {
      replyMarkup: {
        inline_keyboard: [
          [
            { text: "🧭 Open Call", url: `${site}/calls/${encodeURIComponent(call.publicId)}` },
            { text: "🖼 Journey Card", url: `${site}/api/calls/${encodeURIComponent(call.publicId)}/card?mode=journey` },
          ],
          [
            { text: "🔎 Before The Move", url: `${site}/api/calls/${encodeURIComponent(call.publicId)}/card?mode=before` },
          ],
          [
            { text: "✅ Mark Used", callback_data: `content:used:${id}` },
            { text: "🗑 Skip", callback_data: `content:skip:${id}` },
          ],
        ],
      },
    });

    await sql`
      UPDATE memescope_content_opportunities
      SET telegram_message_id = ${message.message_id}, sent_at = NOW(), updated_at = NOW()
      WHERE id = ${id}
    `;
    sent += 1;
  }

  return { sent };
}

function localClock() {
  const timeZone = process.env.MEMESCOPE_REPORT_TIMEZONE?.trim() || "Asia/Jakarta";
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    weekday: "short",
    hour: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date());
  const values = new Map(parts.map((part) => [part.type, part.value]));
  return {
    timeZone,
    date: `${values.get("year")}-${values.get("month")}-${values.get("day")}`,
    weekday: values.get("weekday") ?? "",
    hour: Number(values.get("hour") ?? "0"),
  };
}

async function reportStats(days: number) {
  const dashboard = await getCallDashboard(days);
  const top = dashboard.topCalls[0] ?? null;
  const fastest2x = dashboard.recentCalls
    .filter((call) => call.milestone2xAt !== null)
    .sort((a, b) =>
      ((a.milestone2xAt ?? Number.MAX_SAFE_INTEGER) - a.calledAt) -
      ((b.milestone2xAt ?? Number.MAX_SAFE_INTEGER) - b.calledAt),
    )[0] ?? null;

  return { dashboard, top, fastest2x };
}

async function sendReport(type: "daily" | "weekly", reportDate: string) {
  if (!telegramConfigured()) return false;
  const sql = sqlClient();
  const key = `${type}:${reportDate}`;
  const existing = await sql`SELECT report_key FROM memescope_public_reports WHERE report_key = ${key} LIMIT 1`;
  if (existing[0]) return false;

  const { dashboard, top, fastest2x } = await reportStats(type === "daily" ? 1 : 7);
  if (dashboard.totalCalls === 0) return false;

  const title = type === "daily" ? "📊 MEMESCOPE DAILY TAPE" : "📈 MEMESCOPE WEEKLY INTELLIGENCE";
  const lines = [
    `<b>${title}</b>`,
    reportDate,
    "",
    `Calls: <b>${dashboard.totalCalls}</b>`,
    `Reached 2X: <b>${dashboard.reached2x}</b>`,
    `Reached 5X: <b>${dashboard.reached5x}</b>`,
    `Reached 10X: <b>${dashboard.reached10x}</b>`,
    "",
    top ? `Top Recorded Call: <b>$${escapeTelegramHtml(top.symbol)} — ${multipleText(top.peakMultiple)}</b>` : null,
    fastest2x ? `Fastest 2X: <b>$${escapeTelegramHtml(fastest2x.symbol)} — ${durationText(fastest2x.calledAt, fastest2x.milestone2xAt)}</b>` : null,
    dashboard.medianPeakMultiple !== null ? `Median Peak: <b>${multipleText(dashboard.medianPeakMultiple)}</b>` : null,
    dashboard.medianMaxDrawdownPct !== null ? `Median Max Drawdown: <b>${pct(dashboard.medianMaxDrawdownPct)}</b>` : null,
    "",
    "<i>Historical observations only; not future probabilities.</i>",
  ].filter((value): value is string => value !== null);

  const { channelId } = telegramConfig();
  const publicMessage = await telegramSendMessage(channelId, lines.join("\n"), {
    replyMarkup: {
      inline_keyboard: [[{ text: "🏆 Hall of Calls", url: `${telegramSiteUrl()}/calls` }]],
    },
  });

  const hq = await getContentHqStatus();
  let hqMessageId: number | null = null;
  if (hq.configured && hq.chatId) {
    const hqText = [
      `📝 <b>${type === "daily" ? "DAILY TAPE" : "WEEKLY INTELLIGENCE"} CONTENT READY</b>`,
      "",
      ...lines.slice(1, -2),
      "",
      top
        ? `<b>Suggested hook</b>\nMemeScope flagged $${escapeTelegramHtml(top.symbol)} at ${compactUsd(top.callMarketCapUsd)} MC. It later reached ${compactUsd(top.peakMarketCapUsd)}.`
        : "",
      "",
      "<i>Review before publishing outside Telegram.</i>",
    ].filter(Boolean).join("\n");
    const hqMessage = await telegramSendMessage(hq.chatId, hqText, {
      replyMarkup: { inline_keyboard: [[{ text: "🏆 Open Hall of Calls", url: `${telegramSiteUrl()}/calls` }]] },
    });
    hqMessageId = hqMessage.message_id;
  }

  await sql`
    INSERT INTO memescope_public_reports (
      report_key, report_type, report_date, public_message_id, content_hq_message_id
    ) VALUES (
      ${key}, ${type}, ${reportDate}, ${publicMessage.message_id}, ${hqMessageId}
    )
    ON CONFLICT (report_key) DO NOTHING
  `;
  return true;
}

async function publishScheduledReports() {
  const clock = localClock();
  if (clock.hour < 23) return { daily: false, weekly: false };
  const daily = await sendReport("daily", clock.date);
  const weekly = clock.weekday === "Sun" ? await sendReport("weekly", clock.date) : false;
  return { daily, weekly };
}

export async function runPersistedPerformanceCycle() {
  await ensureCallStorySchema();
  const tracking = await trackPersistedCallPerformance();
  const milestones = await publishPendingPublicMilestones();
  tracking.publishedMilestones = milestones.sent;
  const sql = sqlClient();
  await sql`UPDATE memescope_call_story_state
    SET tracking_diagnostics = ${JSON.stringify(tracking)}::jsonb WHERE id = 1`;
  return { tracking, milestones };
}

export async function runCallStoryCycle() {
  const { tracking, milestones } = await runPersistedPerformanceCycle();
  await discoverContentOpportunities();
  const content = await publishPendingContentOpportunities();
  const reports = await publishScheduledReports();

  let freeChannel = {
    configured: false,
    initialized: false,
    dexPaidSent: 0,
    vipResultsSent: 0,
  };

  // FREE channel cycle is executed directly by /api/telegram/cron.
  // Keep this placeholder for the existing Call Story return shape.

  return { tracking, milestones, content, reports, freeChannel };
}

export async function prepareCallStoryRows(tokens: TerminalToken[], signals: SignalCall[]) {
  const { ensureTelegramPublisherSchema } = await import("@/lib/telegram-publisher");
  await ensureTelegramPublisherSchema();
  return syncCallRows(tokens, signals);
}
