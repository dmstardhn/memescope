import { NextResponse } from "next/server";
import { getV4Settings, sqlV4 } from "@/lib/content-hq-v4/db";
import { xPublishingConfigured } from "@/lib/content-hq-v4/publisher";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const settings = await getV4Settings();
    const sql = sqlV4();
    const rows = await sql`
      SELECT id, token_address, pair_address, symbol, content_type, visual_style,
             caption_template, caption, reason, first_market_cap, current_market_cap,
             multiple, image_mime, branded, status, created_at, approved_at,
             scheduled_at, published_at, x_post_id,
             CASE WHEN image_base64 IS NOT NULL THEN TRUE ELSE FALSE END AS has_image
      FROM memescope_content_v4_queue
      WHERE created_at >= ${settings.historyResetAt}::timestamptz
        AND status <> 'archived_before_reset'
      ORDER BY created_at DESC
      LIMIT 100
    `;
    return NextResponse.json({ok:true,settings,xConfigured:xPublishingConfigured(),items:rows});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}