import {
  NextResponse,
} from "next/server";

import {
  sendTelegramTestCard,
} from "@/lib/telegram-photo";

function authorized(
  request: Request,
) {
  const secret =
    process.env.CRON_SECRET?.trim();

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
    const result =
      await sendTelegramTestCard();

    return NextResponse.json({
      ok: true,
      delivered: true,
      result,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Telegram photo test failed.",
      },
      {
        status: 500,
      },
    );
  }
}