import "server-only";
import { neon } from "@neondatabase/serverless";

export type ContentType =
  | "market_observation"
  | "token_watch"
  | "chart_setup"
  | "token_update"
  | "before_move"
  | "call_journey"
  | "daily_recap"
  | "weekly_recap";

export type V4Settings = {
  manualApproval: boolean;
  historyResetAt: string;
  maxPostsPerDay: number;
  minGapMinutes: number;
  brandingPct: number;
  tokenWatchPct: number;
  mix: Record<ContentType, number>;
};

function client() {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}

export async function ensureV4Schema() {
  const sql = client();

  await sql`
    CREATE TABLE IF NOT EXISTS memescope_content_v4_settings (
      id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
      manual_approval BOOLEAN NOT NULL DEFAULT TRUE,
      history_reset_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      max_posts_per_day INTEGER NOT NULL DEFAULT 5,
      min_gap_minutes INTEGER NOT NULL DEFAULT 40,
      branding_pct INTEGER NOT NULL DEFAULT 20,
      token_watch_pct INTEGER NOT NULL DEFAULT 5,
      mix_json JSONB NOT NULL DEFAULT
        '{"market_observation":25,"token_watch":5,"chart_setup":35,"token_update":20,"before_move":7,"call_journey":3,"daily_recap":2,"weekly_recap":3}'::jsonb,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `;

  await sql`
    INSERT INTO memescope_content_v4_settings (id)
    VALUES (1)
    ON CONFLICT (id) DO NOTHING
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS memescope_content_v4_queue (
      id BIGSERIAL PRIMARY KEY,
      event_key TEXT NOT NULL UNIQUE,
      token_address TEXT,
      pair_address TEXT,
      symbol TEXT,
      content_type TEXT NOT NULL,
      visual_style TEXT,
      caption_template TEXT NOT NULL,
      caption TEXT NOT NULL,
      reason TEXT,
      first_market_cap NUMERIC,
      current_market_cap NUMERIC,
      multiple NUMERIC,
      image_base64 TEXT,
      image_mime TEXT,
      branded BOOLEAN NOT NULL DEFAULT FALSE,
      status TEXT NOT NULL DEFAULT 'queued',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      approved_at TIMESTAMPTZ,
      scheduled_at TIMESTAMPTZ,
      published_at TIMESTAMPTZ,
      x_post_id TEXT
    )
  `;

  await sql`
    CREATE INDEX IF NOT EXISTS memescope_content_v4_queue_created_idx
    ON memescope_content_v4_queue (created_at DESC)
  `;

  await sql`
    CREATE INDEX IF NOT EXISTS memescope_content_v4_queue_token_idx
    ON memescope_content_v4_queue (token_address, created_at DESC)
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS memescope_content_v4_snapshots (
      token_address TEXT PRIMARY KEY,
      pair_address TEXT,
      symbol TEXT,
      first_detected_at TIMESTAMPTZ NOT NULL,
      first_market_cap NUMERIC,
      first_price NUMERIC,
      first_liquidity NUMERIC,
      first_volume NUMERIC,
      source_call_id TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `;
}

export async function getV4Settings(): Promise<V4Settings> {
  await ensureV4Schema();
  const sql = client();
  const rows = await sql`
    SELECT *
    FROM memescope_content_v4_settings
    WHERE id = 1
    LIMIT 1
  `;
  const row = rows[0] as Record<string, unknown>;
  const rawMix = (row.mix_json ?? {}) as Record<string, unknown>;

  const mix: Record<ContentType, number> = {
    market_observation: Number(rawMix.market_observation ?? 25),
    token_watch: Number(rawMix.token_watch ?? 5),
    chart_setup: Number(rawMix.chart_setup ?? 35),
    token_update: Number(rawMix.token_update ?? 20),
    before_move: Number(rawMix.before_move ?? 7),
    call_journey: Number(rawMix.call_journey ?? 3),
    daily_recap: Number(rawMix.daily_recap ?? 2),
    weekly_recap: Number(rawMix.weekly_recap ?? 3),
  };

  return {
    manualApproval: Boolean(row.manual_approval),
    historyResetAt: new Date(String(row.history_reset_at)).toISOString(),
    maxPostsPerDay: Number(row.max_posts_per_day ?? 5),
    minGapMinutes: Number(row.min_gap_minutes ?? 40),
    brandingPct: Number(row.branding_pct ?? 20),
    tokenWatchPct: Number(row.token_watch_pct ?? 5),
    mix,
  };
}

export async function setManualApproval(enabled: boolean) {
  await ensureV4Schema();
  const sql = client();
  await sql`
    UPDATE memescope_content_v4_settings
    SET manual_approval = ${enabled},
        updated_at = NOW()
    WHERE id = 1
  `;
}

export async function resetV4History() {
  await ensureV4Schema();
  const sql = client();
  const rows = await sql`
    UPDATE memescope_content_v4_settings
    SET history_reset_at = NOW(),
        updated_at = NOW()
    WHERE id = 1
    RETURNING history_reset_at
  `;

  await sql`
    UPDATE memescope_content_v4_queue
    SET status = 'archived_before_reset'
    WHERE created_at < (
      SELECT history_reset_at
      FROM memescope_content_v4_settings
      WHERE id = 1
    )
      AND status IN ('queued','draft','approved','scheduled','rejected','failed')
  `;

  return new Date(String(rows[0]?.history_reset_at)).toISOString();
}

export async function v4Status() {
  const settings = await getV4Settings();
  const sql = client();

  const rows = await sql`
    SELECT
      COUNT(*) FILTER (WHERE status = 'queued')::INTEGER AS queued,
      COUNT(*) FILTER (WHERE status = 'approved')::INTEGER AS approved,
      COUNT(*) FILTER (WHERE status = 'published')::INTEGER AS published,
      COUNT(*) FILTER (WHERE status = 'failed')::INTEGER AS failed
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
  `;

  return {
    settings,
    counts: {
      queued: Number(rows[0]?.queued ?? 0),
      approved: Number(rows[0]?.approved ?? 0),
      published: Number(rows[0]?.published ?? 0),
      failed: Number(rows[0]?.failed ?? 0),
    },
  };
}

export function sqlV4() {
  return client();
}