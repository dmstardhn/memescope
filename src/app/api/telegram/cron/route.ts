import {
  NextResponse,
} from "next/server";

function secretValue() {
  return (
    process.env
      .CRON_SECRET
      ?.trim() ??
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

async function protectedPost(
  origin: string,
  path: string,
  secret: string,
) {
  const response =
    await fetch(
      `${origin}${path}`,
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

  return {
    ok:
      response.ok,
    status:
      response.status,
    body,
  };
}

export async function GET(
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

  const secret =
    secretValue();

  const origin =
    new URL(
      request.url,
    ).origin;

  const recorder =
    await protectedPost(
      origin,
      "/api/signals/record",
      secret,
    );

  let contentHq:
    Record<string, unknown> =
    {};

  try {
    const content =
      await protectedPost(
        origin,
        "/api/content-hq-v4/process",
        secret,
      );

    contentHq =
      content.body;
  } catch (error) {
    contentHq = {
      ok: false,
      error:
        error instanceof Error
          ? error.message
          : "Content HQ cycle failed.",
    };
  }

    try {
    const baseUrl =
      process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/+$/, "") ||
      process.env.VERCEL_PROJECT_PRODUCTION_URL
        ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
        : "https://memescopes.vercel.app";

    const cronSecret = process.env.CRON_SECRET?.trim();
    if (cronSecret) {
      await fetch(`${baseUrl}/api/content-hq-v4/publish`, {
        method: "POST",
        headers: { Authorization: `Bearer ${cronSecret}` },
        cache: "no-store",
      }).catch(() => undefined);
    }
  } catch {
    // Content publishing must never break the signal/public Telegram cron.
  }
return NextResponse.json(
    {
      ok:
        recorder.ok,
      recorder:
        recorder.body,
      contentHq,
    },
    {
      status:
        recorder.ok
          ? 200
          : recorder.status,
    },
  );
}