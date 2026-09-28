import { NextResponse } from "next/server";
import { generateSignals } from "@/lib/signal-engine";
import {
  recordSignalSnapshot,
  signalDatabaseConfigured,
} from "@/lib/signal-recorder-db";
import type { TerminalResponse } from "@/lib/terminal-types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

async function run(request: Request) {
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
    const terminalUrl = new URL("/api/terminal/solana", request.url);

    const response = await fetch(terminalUrl, {
      cache: "no-store",
      headers: {
        "x-memescope-recorder": "1",
      },
    });

    if (!response.ok) {
      throw new Error(
        `Terminal snapshot failed with HTTP ${response.status}.`,
      );
    }

    const terminal = (await response.json()) as TerminalResponse;
    const signals = generateSignals(terminal.tokens);

    return NextResponse.json({
      configured: true,
      ...(await recordSignalSnapshot(terminal.tokens, signals)),
    });
  } catch (error) {
    return NextResponse.json(
      {
        configured: true,
        error:
          error instanceof Error ? error.message : "Signal recorder failed.",
      },
      { status: 500 },
    );
  }
}

export async function POST(request: Request) {
  return run(request);
}

export async function GET(request: Request) {
  return run(request);
}
