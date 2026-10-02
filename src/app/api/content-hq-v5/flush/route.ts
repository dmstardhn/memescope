import {
  NextResponse,
} from "next/server";

import {
  publishDailyLast72Draft,
  sendLatestRealTierPreview,
} from "@/lib/content-hq-v5/content";

import {
  CONTENT_TIERS,
  type ContentTier,
} from "@/lib/content-hq-v5/backgrounds";

export const runtime =
  "nodejs";

export const dynamic =
  "force-dynamic";

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
    const url =
      new URL(
        request.url,
      );

    const requestedTier =
      (
        url.searchParams.get(
          "tier",
        ) ??
        "apex"
      ).toLowerCase();

    const tier:
      ContentTier =
      CONTENT_TIERS.includes(
        requestedTier as ContentTier,
      )
        ? requestedTier as ContentTier
        : "apex";

    const result =
      await sendLatestRealTierPreview(
        tier,
      );

    const last72 =
      await publishDailyLast72Draft(
        true,
      );

    return NextResponse.json({
      ok: true,
      tier,
      result,
      last72,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : String(error),
      },
      {
        status: 500,
      },
    );
  }
}