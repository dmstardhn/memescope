import { NextRequest, NextResponse } from "next/server";
import {
  getSignalAnalytics,
  signalDatabaseConfigured,
} from "@/lib/signal-recorder-db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  if (!signalDatabaseConfigured()) {
    return NextResponse.json(
      {
        configured: false,
        error: "DATABASE_URL is not configured.",
      },
      { status: 503 },
    );
  }

  try {
    const days = Number(
      request.nextUrl.searchParams.get("days") ?? 30,
    );

    return NextResponse.json({
      configured: true,
      analytics: await getSignalAnalytics(days),
    });
  } catch (error) {
    return NextResponse.json(
      {
        configured: true,
        error:
          error instanceof Error ? error.message : "Analytics request failed.",
      },
      { status: 500 },
    );
  }
}
