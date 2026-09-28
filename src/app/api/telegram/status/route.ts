import {
  NextResponse,
} from "next/server";

import {
  telegramConfig,
  telegramGetMe,
} from "@/lib/telegram";

export async function GET() {
  const config =
    telegramConfig();

  const configured =
    Boolean(
      config.botToken &&
        config.channelId &&
        config.webhookSecret,
    );

  if (!configured) {
    return NextResponse.json({
      configured: false,
      bot: null,
      channelConfigured:
        Boolean(
          config.channelId,
        ),
      webhookSecretConfigured:
        Boolean(
          config.webhookSecret,
        ),
    });
  }

  try {
    const bot =
      await telegramGetMe();

    return NextResponse.json({
      configured: true,
      bot: {
        username:
          bot.username ?? null,
        firstName:
          bot.first_name,
      },
      channelConfigured: true,
      channelUrl:
        config.channelUrl ||
        null,
    });
  } catch (error) {
    return NextResponse.json(
      {
        configured: true,
        bot: null,
        error:
          error instanceof Error
            ? error.message
            : "Telegram status failed.",
      },
      {
        status: 502,
      },
    );
  }
}
