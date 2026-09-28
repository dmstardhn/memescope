import { NextResponse } from "next/server";
import {
  getSignalExitSettings,
  saveSignalExitSettings,
  signalDatabaseConfigured,
} from "@/lib/signal-recorder-db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  if (!signalDatabaseConfigured()) {
    return NextResponse.json({
      configured: false,
      error: "DATABASE_URL is not configured.",
    });
  }

  try {
    return NextResponse.json({
      configured: true,
      settings: await getSignalExitSettings(),
    });
  } catch (error) {
    return NextResponse.json(
      {
        configured: true,
        error:
          error instanceof Error
            ? error.message
            : "Failed to load settings.",
      },
      { status: 500 },
    );
  }
}

export async function PUT(request: Request) {
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
    const body = (await request.json()) as Record<string, unknown>;

    return NextResponse.json({
      configured: true,
      settings: await saveSignalExitSettings(body),
    });
  } catch (error) {
    return NextResponse.json(
      {
        configured: true,
        error:
          error instanceof Error
            ? error.message
            : "Failed to save settings.",
      },
      { status: 500 },
    );
  }
}
