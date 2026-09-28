import {
  NextResponse,
} from "next/server";

function secretValue() {
  return (
    process.env.CRON_SECRET?.trim() ??
    ""
  );
}

function authorized(
  request: Request,
) {
  const secret =
    secretValue();

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

  const secret =
    secretValue();

  const origin =
    new URL(
      request.url,
    ).origin;

  const response =
    await fetch(
      `${origin}/api/signals/record`,
      {
        method: "POST",
        headers: {
          authorization:
            `Bearer ${secret}`,
        },
        cache: "no-store",
      },
    );

  const body =
    (await response.json()) as
      Record<string, unknown>;

  return NextResponse.json(
    {
      ok: response.ok,
      recorder: body,
    },
    {
      status:
        response.ok
          ? 200
          : response.status,
    },
  );
}