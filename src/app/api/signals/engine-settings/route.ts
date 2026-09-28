import {
  NextResponse,
} from "next/server";

import {
  getSignalEngineSettings,
} from "@/lib/signal-engine-settings";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    const settings =
      await getSignalEngineSettings();

    return NextResponse.json({
      ok: true,
      settings,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Unable to load signal settings.",
      },
      {
        status: 500,
      },
    );
  }
}