import { NextResponse } from "next/server";
import { neon } from "@neondatabase/serverless";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim() ?? "";
  const header = request.headers.get("x-memescope-cron")?.trim();

  return Boolean(secret && header === secret);
}

export async function GET(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json(
      { ok: false, error: "Unauthorized." },
      { status: 401 },
    );
  }

  const databaseUrl = process.env.DATABASE_URL?.trim();

  if (!databaseUrl) {
    return NextResponse.json(
      { ok: false, error: "DATABASE_URL missing." },
      { status: 500 },
    );
  }

  try {
    const sql = neon(databaseUrl);

  const state = await sql`
    SELECT
      dex_initialized_at,
      dex_paid_v2_initialized_at,
      enabled,
      dex_enabled,
      vip_results_enabled
    FROM memescope_free_channel_state
    WHERE id = 1
  `;

  const events = await sql`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE baseline = FALSE)::int AS live
    FROM memescope_free_dex_events
  `;

  const posts = await sql`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (
        WHERE kind = 'dex_paid'
        AND posted_at IS NOT NULL
      )::int AS dex_posts
    FROM memescope_free_posts
  `;

  const latest = await sql`
    SELECT
      source_label,
      token_address,
      source_at,
      baseline,
      seen_at
    FROM memescope_free_dex_events
    ORDER BY seen_at DESC
    LIMIT 10
  `;

    return NextResponse.json({
      ok: true,
      state: state[0] ?? null,
      events: events[0] ?? null,
      posts: posts[0] ?? null,
      latest,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Unknown debug error.",
      },
      { status: 500 },
    );
  }
}
