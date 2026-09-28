import "server-only";

function baseUrl() {
  const prod =
    process.env.VERCEL_PROJECT_PRODUCTION_URL?.trim();

  if (prod) {
    return `https://${prod}`;
  }

  return "https://memescopes.vercel.app";
}

export async function sendTelegramTestCard() {
  const token =
    process.env.TELEGRAM_BOT_TOKEN?.trim();

  const channel =
    process.env.TELEGRAM_CHANNEL_ID?.trim();

  if (!token) {
    throw new Error(
      "TELEGRAM_BOT_TOKEN is not configured.",
    );
  }

  if (!channel) {
    throw new Error(
      "TELEGRAM_CHANNEL_ID is not configured.",
    );
  }

  const photo =
    `${baseUrl()}/api/telegram/card/test`;

  const response = await fetch(
    `https://api.telegram.org/bot${token}/sendPhoto`,
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
      },
      body: JSON.stringify({
        chat_id: channel,
        photo,
        caption: [
          "🔥 <b>MEMESCOPE HQ SIGNAL</b>",
          "",
          "<b>$MSCOPE</b> — MemeScope Test Signal",
          "",
          "Quality Score: <b>87/100</b>",
          "Entry: <b>$0.000124</b>",
          "Potential TP: <b>+31.5%</b>",
          "",
          "<i>This is a Stage 18 image-card test, not a live trading signal.</i>",
        ].join("\n"),
        parse_mode: "HTML",
        reply_markup: {
          inline_keyboard: [
            [
              {
                text: "🌐 MemeScope",
                url: baseUrl(),
              },
            ],
          ],
        },
      }),
      cache: "no-store",
    },
  );

  const body = await response.json();

  if (
    !response.ok ||
    !body.ok
  ) {
    throw new Error(
      body.description ??
        "Telegram sendPhoto failed.",
    );
  }

  return body.result;
}