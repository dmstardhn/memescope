import {
  NextResponse,
} from "next/server";

import {
  generateSignals,
} from "@/lib/signal-engine";
import {
  getSignalEngineSettings,
} from "@/lib/signal-engine-settings";
import {
  recordSignalSnapshot,
} from "@/lib/signal-recorder-db";
import type {
  TerminalResponse,
} from "@/lib/terminal-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(
  request: Request,
) {
  const secret =
    process.env.CRON_SECRET?.trim();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) ===
        `Bearer ${secret}`,
  );
}

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        error: "Unauthorized.",
      },
      {
        status: 401,
      },
    );
  }

  try {
    const origin =
      new URL(
        request.url,
      ).origin;

    const response =
      await fetch(
        `${origin}/api/terminal/solana`,
        {
          cache: "no-store",
        },
      );

    const body =
      (await response.json()) as
        | TerminalResponse
        | {
            error?: string;
          };

    if (!response.ok) {
      throw new Error(
        "error" in body
          ? body.error ??
              "Terminal feed failed."
          : "Terminal feed failed.",
      );
    }

    const terminal =
      body as TerminalResponse;

    const settings =
      await getSignalEngineSettings();

    const signals =
      generateSignals(
        terminal.tokens,
        settings,
      );

    const result =
      await recordSignalSnapshot(
        terminal.tokens,
        signals,
        settings.confirmationScans,
      );

    return NextResponse.json({
      ok: true,
      configured: true,
      ...result,
      engineSettings:
        settings,
    });
  } catch (error) {
    const message =
      error instanceof Error
        ? error.message
        : "Signal recorder failed.";

    return NextResponse.json(
      {
        ok: false,
        configured:
          !message.includes(
            "DATABASE_URL",
          ),
        error: message,
      },
      {
        status: 500,
      },
    );
  }
}