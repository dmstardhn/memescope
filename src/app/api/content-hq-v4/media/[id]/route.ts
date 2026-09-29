import { NextResponse } from "next/server";
import { sqlV4 } from "@/lib/content-hq-v4/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(_request: Request, context: {params: Promise<{id:string}>}) {
  const {id} = await context.params;
  const itemId = Number(id);
  if (!Number.isFinite(itemId)) return new NextResponse("Invalid id",{status:400});

  const sql = sqlV4();
  const rows = await sql`
    SELECT image_base64, image_mime
    FROM memescope_content_v4_queue
    WHERE id = ${itemId}
    LIMIT 1
  `;
  if (!rows.length || !rows[0].image_base64) return new NextResponse("No media",{status:404});

  return new NextResponse(Buffer.from(String(rows[0].image_base64),"base64"), {
    headers: {
      "content-type": String(rows[0].image_mime ?? "image/webp"),
      "cache-control": "private, max-age=60",
    },
  });
}