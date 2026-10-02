import { NextResponse } from "next/server";

import {
  publishDailyLast72Draft,
  sendLatestResultDraftPreview,
} from "@/lib/content-hq-v5/content";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  return Boolean(
    secret &&
      request.headers.get("authorization") === `Bearer ${secret}`,
  );
}

export async function POST(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({ ok: false, error: "Unauthorized." }, { status: 401 });
  }

  try {
    const result = await sendLatestResultDraftPreview();
    const last72 = await publishDailyLast72Draft(true);
    return NextResponse.json({ ok: true, result, last72 });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      },
      { status: 500 },
    );
  }
}
