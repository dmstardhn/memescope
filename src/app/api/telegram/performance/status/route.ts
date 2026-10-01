import {
  NextResponse,
} from "next/server";

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

function targetKind(
  value: string,
) {
  if (!value) {
    return "missing";
  }

  if (
    /^-?\d+$/.test(
      value,
    )
  ) {
    return "numeric";
  }

  if (
    value.startsWith("@")
  ) {
    return "username";
  }

  if (
    /^https?:\/\//i.test(
      value,
    )
  ) {
    return "url";
  }

  return "other";
}

async function telegramCall(
  token: string,
  method: string,
  query?: Record<
    string,
    string
  >,
) {
  const params =
    new URLSearchParams(
      query ?? {},
    );

  const url =
    `https://api.telegram.org/bot${token}/${method}${params.size ? `?${params.toString()}` : ""}`;

  const response =
    await fetch(
      url,
      {
        cache: "no-store",
      },
    );

  let body:
    | Record<string, unknown>
    | null = null;

  try {
    body =
      (await response.json()) as
        Record<string, unknown>;
  } catch {
    body = null;
  }

  return {
    httpStatus:
      response.status,
    ok:
      Boolean(
        body?.ok,
      ),
    description:
      typeof body?.description ===
      "string"
        ? body.description
        : null,
    result:
      body?.result,
  };
}

async function inspectChat(
  token: string,
  label: "vip" | "free",
  rawValue: string,
) {
  const value =
    rawValue.trim();

  if (!value) {
    return {
      label,
      configured: false,
      targetKind:
        "missing",
      ok: false,
      description:
        "Environment variable is missing or empty.",
    };
  }

  const result =
    await telegramCall(
      token,
      "getChat",
      {
        chat_id: value,
      },
    );

  const chat =
    result.result &&
    typeof result.result ===
      "object"
      ? result.result as
          Record<
            string,
            unknown
          >
      : null;

  return {
    label,
    configured: true,
    targetKind:
      targetKind(value),
    targetLength:
      value.length,
    ok:
      result.ok,
    httpStatus:
      result.httpStatus,
    description:
      result.description,
    chat:
      result.ok
        ? {
            id:
              chat?.id ?? null,
            type:
              chat?.type ?? null,
            title:
              chat?.title ?? null,
            username:
              chat?.username ?? null,
          }
        : null,
  };
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

  const token =
    process.env
      .TELEGRAM_BOT_TOKEN
      ?.trim() ?? "";

  if (!token) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "TELEGRAM_BOT_TOKEN is missing in the production environment.",
      },
      {
        status: 500,
      },
    );
  }

  const bot =
    await telegramCall(
      token,
      "getMe",
    );

  if (!bot.ok) {
    return NextResponse.json(
      {
        ok: false,
        bot: {
          ok: false,
          httpStatus:
            bot.httpStatus,
          description:
            bot.description,
        },
      },
      {
        status: 500,
      },
    );
  }

  const vip =
    await inspectChat(
      token,
      "vip",
      process.env
        .TELEGRAM_CHANNEL_ID ??
        "",
    );

  const free =
    await inspectChat(
      token,
      "free",
      process.env
        .TELEGRAM_FREE_CHANNEL_ID ??
        "",
    );

  return NextResponse.json({
    ok:
      vip.ok &&
      free.ok,
    bot: {
      ok: true,
    },
    vip,
    free,
  });
}
