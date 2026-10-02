import { neon } from "@neondatabase/serverless";
import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  return Boolean(secret && request.headers.get("authorization") === `Bearer ${secret}`);
}

export async function POST(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({ ok: false, error: "Unauthorized." }, { status: 401 });
  }
  try {
    const { runPersistedPerformanceCycle } = await import("@/lib/call-story");
    return NextResponse.json({ ok: true, ...(await runPersistedPerformanceCycle()) });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}

export async function GET(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({ ok: false, error: "Unauthorized." }, { status: 401 });
  }
  const databaseUrl = process.env.DATABASE_URL?.trim();
  if (!databaseUrl) {
    return NextResponse.json({ ok: false, error: "DATABASE_URL is not configured." }, { status: 500 });
  }
  try {
    const sql = neon(databaseUrl);
    const [rows, state] = await Promise.all([
      sql`
        SELECT
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL) AS published_calls,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.signal_record_id IS NOT NULL) AS persisted_calls,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.last_tracked_at >= NOW() - INTERVAL '24 hours') AS active_tracker_calls,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.peak_multiple >= 3) AS reached_3x,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.peak_multiple >= 5) AS reached_5x,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.peak_multiple >= 10) AS reached_10x,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.peak_multiple >= 3 AND c.last_public_milestone < CASE
              WHEN c.peak_multiple >= 100 THEN 100 WHEN c.peak_multiple >= 50 THEN 50
              WHEN c.peak_multiple >= 20 THEN 20 WHEN c.peak_multiple >= 10 THEN 10
              WHEN c.peak_multiple >= 5 THEN 5 ELSE 3 END) AS pending_milestones,
          COUNT(*) FILTER (WHERE p.baseline = FALSE AND p.first_sent_at IS NOT NULL
            AND c.last_tracked_at IS NOT NULL AND c.current_price_usd IS NULL
            AND c.current_market_cap_usd IS NULL) AS missing_market_data,
          COUNT(*) FILTER (WHERE c.signal_record_id IS NOT NULL
            AND (p.signal_record_id IS NULL OR p.baseline = TRUE OR p.first_sent_at IS NULL))
            AS missing_publication_evidence,
          MAX(c.last_tracked_at) AS latest_call_tracked_at
        FROM memescope_telegram_posts p
        FULL OUTER JOIN memescope_call_story c ON c.signal_record_id = p.signal_record_id
      `,
      sql`SELECT latest_tracking_run_at, tracking_diagnostics
        FROM memescope_call_story_state WHERE id = 1 LIMIT 1`,
    ]);
    return NextResponse.json({ ok: true, totals: rows[0], latestTrackingRunAt: state[0]?.latest_tracking_run_at ?? null,
      latestCycle: state[0]?.tracking_diagnostics ?? null });
  } catch (error) {
    return NextResponse.json({ ok: false, error: error instanceof Error ? error.message : String(error) }, { status: 500 });
  }
}
