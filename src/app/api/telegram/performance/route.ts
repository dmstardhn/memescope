import {
  NextResponse,
} from "next/server";

import {
  updatePerformanceBoards,
} from "@/lib/performance-board";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(
  request: Request,
) {
  const secret =
    process.env.CRON_SECRET?.trim();

  if (!secret) {
    return false;
  }

  const authorization =
    request.headers
      .get("authorization")
      ?.trim();

  const headerSecret =
    request.headers
      .get("x-memescope-cron")
      ?.trim();

  return (
    authorization ===
      `Bearer ${secret}` ||
    headerSecret === secret
  );
}

export async function GET(
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
    const result =
      await updatePerformanceBoards({
        force: true,
      });

    return NextResponse.json({
      ok: true,
      performance: result,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Performance board force update failed.",
      },
      {
        status: 500,
      },
    );
  }
}
