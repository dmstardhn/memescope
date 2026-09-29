import {
  NextResponse,
} from "next/server";

import {
  getContentConfig,
  updateContentConfig,
} from "@/lib/content-hq";
import type {
  ContentConfig,
} from "@/lib/content-hq-types";

function authorized(
  request: Request,
) {
  const expected =
    process.env
      .CONTENT_HQ_ADMIN_KEY
      ?.trim() ||
    process.env
      .CRON_SECRET
      ?.trim();

  return Boolean(
    expected &&
      request.headers.get(
        "x-content-hq-key",
      ) === expected,
  );
}

export async function GET(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
      },
      {
        status: 401,
      },
    );
  }

  return NextResponse.json({
    ok: true,
    config:
      await getContentConfig(),
  });
}

export async function POST(
  request: Request,
) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
      },
      {
        status: 401,
      },
    );
  }

  const patch =
    (await request.json()) as
      Partial<ContentConfig>;

  return NextResponse.json({
    ok: true,
    config:
      await updateContentConfig(
        patch,
      ),
  });
}