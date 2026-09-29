import {
  NextResponse,
} from "next/server";

import {
  createContentHqDemo,
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

  const body =
    (await request.json()
      .catch(
        () => ({}),
      )) as {
      kind?: string;
    };

  const kind =
    body.kind;

  if (
    kind !== "runner" &&
    kind !== "big_runner" &&
    kind !== "moonshot" &&
    kind !== "before_move"
  ) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "kind must be runner, big_runner, moonshot, or before_move.",
      },
      {
        status: 400,
      },
    );
  }

  try {
    const result =
      await createContentHqDemo(
        kind,
      );

    return NextResponse.json({
      ok: true,
      demo: true,
      ...result,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Content HQ demo failed.",
      },
      {
        status: 500,
      },
    );
  }
}