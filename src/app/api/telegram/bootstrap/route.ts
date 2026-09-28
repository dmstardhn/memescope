import {
  NextResponse,
} from "next/server";

import {
  telegramConfig,
  telegramGetMe,
  telegramSetCommands,
  telegramSetWebhook,
} from "@/lib/telegram";
import {
  initializeTelegramBaseline,
} from "@/lib/telegram-publisher";

function authorized(
  request: Request,
) {
  const secret =
    process.env.CRON_SECRET?.trim();

  if (!secret) {
    return false;
  }

  return (
    request.headers.get(
      "authorization",
    ) ===
    `Bearer ${secret}`
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

  const config =
    telegramConfig();

  if (
    !config.botToken ||
    !config.channelId ||
    !config.webhookSecret
  ) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Configure TELEGRAM_BOT_TOKEN, TELEGRAM_CHANNEL_ID and TELEGRAM_WEBHOOK_SECRET first.",
      },
      {
        status: 503,
      },
    );
  }

  const origin =
    new URL(
      request.url,
    ).origin;

  const [
    bot,
    ,
    ,
    baseline,
  ] =
    await Promise.all([
      telegramGetMe(),
      telegramSetCommands(),
      telegramSetWebhook(
        origin,
      ),
      initializeTelegramBaseline(),
    ]);

  return NextResponse.json({
    ok: true,
    bot: {
      id: bot.id,
      username:
        bot.username ?? null,
      firstName:
        bot.first_name,
    },
    webhook:
      `${origin}/api/telegram/webhook`,
    baseline,
  });
}
