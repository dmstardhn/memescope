import {
  NextResponse,
} from "next/server";

import {
  handleContentHqAction,
} from "@/lib/content-hq";

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

  const body =
    (await request.json()) as {
      action?: string;
      id?: number;
      value?: string | null;
    };

  if (
    !body.action ||
    !Number.isInteger(
      body.id,
    ) ||
    Number(
      body.id,
    ) <= 0
  ) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Invalid action request.",
      },
      {
        status: 400,
      },
    );
  }

  try {
    const result =
      await handleContentHqAction(
        body.action,
        Number(
          body.id,
        ),
        body.value,
      );

    return NextResponse.json({
      ok: true,
      ...result,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Content action failed.",
      },
      {
        status: 500,
      },
    );
  }
}