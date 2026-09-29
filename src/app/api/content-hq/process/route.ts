import {
  NextResponse,
} from "next/server";

import {
  processContentHq,
} from "@/lib/content-hq";

function authorized(
  request: Request,
) {
  const secret =
    process.env
      .CRON_SECRET
      ?.trim();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) === `Bearer ${secret}`,
  );
}

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Unauthorized.",
      },
      {
        status: 401,
      },
    );
  }

  try {
    return NextResponse.json({
      ok: true,
      result:
        await processContentHq(),
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Content HQ process failed.",
      },
      {
        status: 500,
      },
    );
  }
}