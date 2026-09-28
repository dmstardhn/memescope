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

  try {
    const { channelId } =
      telegramConfig();

    if (!channelId) {
      throw new Error(
        "TELEGRAM_CHANNEL_ID is not configured.",
      );
    }

    const site =
      telegramSiteUrl();

    const result =
      await telegramSendMessage(
        channelId,
        [
          "\u26A1 <b>MEMESCOPE SIGNAL</b>",
          "",
          "\uD83D\uDFE2 <b>HIGH QUALITY SETUP</b>",
          "",
          "<b>$MSCOPE</b> | MemeScope Test",
          "",
          "\u256D\u2500 <b>MARKET SNAPSHOT</b>",
          "\u251C \uD83D\uDCB0 Market Cap     <b>$410K</b>",
          "\u251C \uD83D\uDCA7 Liquidity      <b>$92K</b>",
          "\u251C \uD83D\uDCCA Volume 5m      <b>$28.7K</b>",
          "\u251C \uD83D\uDD25 Volume Spike   <b>1.82x</b>",
          "\u251C \uD83D\uDFE2 Buy Pressure   <b>67%</b>",
          "\u2570 \u23F1 Age            <b>47m</b>",
          "",
          "\u256D\u2500 <b>SIGNAL</b>",
          "\u251C \uD83C\uDFAF Quality Score  <b>87 / 100</b>",
          "\u251C \uD83D\uDCB5 Entry          <b>$0.000124</b>",
          "\u2570 \uD83D\uDE80 Potential TP   <b>+31.5%</b>",
          "",
          "\uD83D\uDCCC <b>Why MemeScope detected it</b>",
          "\u2022 Strong recent buy pressure",
          "\u2022 Healthy liquidity depth",
          "\u2022 Volume expanding above baseline",
          "\u2022 Momentum remains inside HQ range",
          "",
          "\uD83D\uDCCB <b>Contract</b>",
          "<code>TEST_STAGE18</code>",
          "",
          "\u26A0\uFE0F <i>This is a formatting test, not a live trading signal.</i>",
          "",
          "<b>MemeScope | MaxScalpLab</b>",
        ].join("\n"),
        {
          replyMarkup: {
            inline_keyboard: [
              [
                {
                  text:
                    "\uD83D\uDCCA DexScreener",
                  url:
                    "https://dexscreener.com/",
                },
                {
                  text:
                    "\uD83D\uDEE1 Risk Check",
                  url:
                    `${site}/scanner`,
                },
              ],
              [
                {
                  text:
                    "\uD83C\uDF10 MemeScope",
                  url: site,
                },
              ],
            ],
          },
        },
      );

    return NextResponse.json({
      ok: true,
      delivered: true,
      messageId:
        result.message_id,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "Telegram test failed.",
      },
      {
        status: 500,
      },
    );
  }
}