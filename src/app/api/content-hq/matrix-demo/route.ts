import {
  NextResponse,
} from "next/server";

import {
  contentHqDemoScenarioCount,
  createContentHqMatrixDemo,
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
      ) ===
        `Bearer ${secret}`,
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

  return NextResponse.json({
    ok: true,
    count:
      await contentHqDemoScenarioCount(),
  });
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

  const body =
    (await request
      .json()
      .catch(
        () => ({}),
      )) as {
      index?: number;
    };

  const index =
    Number(
      body.index,
    );

  try {
    const result =
      await createContentHqMatrixDemo(
        index,
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
            : "Matrix demo failed.",
      },
      {
        status: 500,
      },
    );
  }
}