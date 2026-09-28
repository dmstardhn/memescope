import { NextRequest, NextResponse } from "next/server";
import {
  getSignalHistory,
  signalDatabaseConfigured,
} from "@/lib/signal-recorder-db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  if (!signalDatabaseConfigured()) {
    return NextResponse.json(
      {
        configured: false,
        records: [],
        error: "DATABASE_URL is not configured.",
      },
      { status: 503 },
    );
  }

  try {
    const limit = Number(
      request.nextUrl.searchParams.get("limit") ?? 100,
    );

    return NextResponse.json({
      configured: true,
      records: await getSignalHistory(limit),
    });
  } catch (error) {
    return NextResponse.json(
      {
        configured: true,
        records: [],
        error:
          error instanceof Error ? error.message : "History request failed.",
      },
      { status: 500 },
    );
  }
}
