import {
  NextResponse,
} from "next/server";

import {
  telegramConfig,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

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

  const { channelId } =
    telegramConfig();

  if (!channelId) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "TELEGRAM_CHANNEL_ID is not configured.",
      },
      {
        status: 503,
      },
    );
  }

  const site =
    telegramSiteUrl();

  const message =
    await telegramSendMessage(
      channelId,
      [
        "✅ <b>MemeScope Telegram Connected</b>",
        "",
        "HQ signals can now be published to this channel.",
        "Signal posts include entry, Potential TP, Current Gain, Maximum Gain, Maximum Drawdown and status updates.",
        "",
        "<i>This is a connection test, not a trading signal.</i>",
      ].join("\n"),
      {
        replyMarkup: {
          inline_keyboard: [
            [
              {
                text:
                  "🌐 Open MemeScope",
                url: site,
              },
            ],
          ],
        },
      },
    );

  return NextResponse.json({
    ok: true,
    messageId:
      message.message_id,
  });
}
