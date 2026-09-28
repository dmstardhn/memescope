import {
  NextResponse,
} from "next/server";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

type TelegramUpdate = {
  message?: {
    message_id?: number;
    text?: string;
    chat?: {
      id?: number;
    };
  };
};

function validSolanaAddress(
  value: string,
) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
    value,
  );
}

function helpText() {
  return [
    "<b>MemeScope Bot</b>",
    "",
    "/signals - active HQ signals",
    "/history - recent signal history",
    "/stats - 30-day signal statistics",
    "/token &lt;CA&gt; - open token",
    "/risk &lt;CA&gt; - open risk analysis",
    "/channel - signal channel",
    "/help - commands",
    "",
    "<i>Signal scores and Potential TP are analytical heuristics, not guaranteed returns.</i>",
  ].join("\n");
}

async function fetchJson(
  origin: string,
  path: string,
) {
  const response =
    await fetch(
      `${origin}${path}`,
      {
        cache: "no-store",
      },
    );

  const body =
    (await response.json()) as
      Record<string, unknown>;

  if (!response.ok) {
    throw new Error(
      String(
        body.error ??
          "MemeScope API request failed.",
      ),
    );
  }

  return body;
}

function pct(
  value: unknown,
) {
  const number =
    Number(value);

  if (!Number.isFinite(number)) {
    return "N/A";
  }

  return `${
    number > 0 ? "+" : ""
  }${number.toFixed(2)}%`;
}

export async function POST(
  request: Request,
) {
  const {
    webhookSecret,
    channelUrl,
  } = telegramConfig();

  if (!webhookSecret) {
    return NextResponse.json(
      {
        ok: false,
        error:
          "Telegram webhook is not configured.",
      },
      {
        status: 503,
      },
    );
  }

  const supplied =
    request.headers.get(
      "x-telegram-bot-api-secret-token",
    );

  if (
    supplied !==
    webhookSecret
  ) {
    return NextResponse.json(
      {
        ok: false,
      },
      {
        status: 401,
      },
    );
  }

  const update =
    (await request.json()) as
      TelegramUpdate;

  const message =
    update.message;

  const chatId =
    message?.chat?.id;

  const rawText =
    message?.text?.trim() ??
    "";

  if (
    !chatId ||
    !rawText
  ) {
    return NextResponse.json({
      ok: true,
    });
  }

  const [
    rawCommand,
    ...args
  ] = rawText.split(/\s+/);

  const command =
    rawCommand
      .toLowerCase()
      .split("@")[0];

  const argument =
    args.join(" ").trim();

  const origin =
    new URL(
      request.url,
    ).origin;

  const site =
    telegramSiteUrl();

  try {
    if (
      command === "/start" ||
      command === "/help"
    ) {
      await telegramSendMessage(
        chatId,
        helpText(),
        {
          replyToMessageId:
            message.message_id,
        },
      );
    } else if (
      command === "/signals"
    ) {
      const body =
        await fetchJson(
          origin,
          "/api/signals/history?limit=50",
        );

      const records =
        Array.isArray(
          body.records,
        )
          ? body.records
          : [];

      const active =
        records
          .filter(
            (item) =>
              typeof item ===
                "object" &&
              item !== null &&
              (
                item as Record<
                  string,
                  unknown
                >
              ).status ===
                "active",
          )
          .slice(0, 8) as Array<
          Record<
            string,
            unknown
          >
        >;

      const text =
        active.length === 0
          ? [
              "🔥 <b>Active HQ Signals</b>",
              "",
              "No active confirmed HQ signal right now.",
            ].join("\n")
          : [
              "🔥 <b>Active HQ Signals</b>",
              "",
              ...active.map(
                (
                  record,
                  index,
                ) =>
                  `${index + 1}. <b>$${escapeTelegramHtml(
                    record.symbol,
                  )}</b> — score ${Math.round(
                    Number(
                      record.scoreAtEntry ??
                        0,
                    ),
                  )}\nGain ${pct(
                    record.currentGainPercent,
                  )} | TP +${Number(
                    record.targetPercent ??
                      0,
                  ).toFixed(
                    1,
                  )}%\n<code>${escapeTelegramHtml(
                    record.tokenAddress,
                  )}</code>`,
              ),
            ].join(
              "\n\n",
            );

      await telegramSendMessage(
        chatId,
        text,
        {
          replyToMessageId:
            message.message_id,
        },
      );
    } else if (
      command === "/history"
    ) {
      const body =
        await fetchJson(
          origin,
          "/api/signals/history?limit=8",
        );

      const records =
        Array.isArray(
          body.records,
        )
          ? (
              body.records as Array<
                Record<
                  string,
                  unknown
                >
              >
            )
          : [];

      const text = [
        "🗂 <b>Recent Signal History</b>",
        "",
        ...(records.length
          ? records.map(
              (
                record,
                index,
              ) =>
                `${index + 1}. <b>$${escapeTelegramHtml(
                  record.symbol,
                )}</b> — ${escapeTelegramHtml(
                  String(
                    record.status ??
                      "active",
                  ).toUpperCase(),
                )}\nCurrent ${pct(
                  record.currentGainPercent,
                )} | Max ${pct(
                  record.peakGainPercent,
                )} | DD ${pct(
                  record.maxDrawdownPercent,
                )}`,
            )
          : [
              "No signal history yet.",
            ]),
      ].join(
        "\n\n",
      );

      await telegramSendMessage(
        chatId,
        text,
        {
          replyToMessageId:
            message.message_id,
        },
      );
    } else if (
      command === "/stats"
    ) {
      const body =
        await fetchJson(
          origin,
          "/api/signals/analytics?days=30",
        );

      const analytics =
        (body.analytics ??
          {}) as Record<
          string,
          unknown
        >;

      const text = [
        "📊 <b>MemeScope — 30D Stats</b>",
        "",
        `Signals: <b>${Number(
          analytics.total ?? 0,
        )}</b>`,
        `Active: <b>${Number(
          analytics.active ?? 0,
        )}</b>`,
        `TP Hit: <b>${Number(
          analytics.targetHits ??
            0,
        )}</b>`,
        `Avg Current Gain: <b>${pct(
          analytics.averageCurrentGain,
        )}</b>`,
        `Avg Max Gain: <b>${pct(
          analytics.averagePeakGain,
        )}</b>`,
        `Avg Max Drawdown: <b>${pct(
          analytics.averageDrawdown,
        )}</b>`,
        "",
        "<i>Historical descriptive statistics are not future probabilities.</i>",
      ].join("\n");

      await telegramSendMessage(
        chatId,
        text,
        {
          replyToMessageId:
            message.message_id,
        },
      );
    } else if (
      command === "/token" ||
      command === "/risk"
    ) {
      if (
        !validSolanaAddress(
          argument,
        )
      ) {
        await telegramSendMessage(
          chatId,
          `Usage: <code>${command} &lt;Solana CA&gt;</code>`,
          {
            replyToMessageId:
              message.message_id,
          },
        );
      } else {
        const encoded =
          encodeURIComponent(
            argument,
          );

        await telegramSendMessage(
          chatId,
          [
            command ===
            "/risk"
              ? "🛡 <b>MemeScope Risk Analyzer</b>"
              : "🔎 <b>MemeScope Token</b>",
            "",
            `<code>${escapeTelegramHtml(
              argument,
            )}</code>`,
          ].join("\n"),
          {
            replyToMessageId:
              message.message_id,
            replyMarkup: {
              inline_keyboard: [
                [
                  {
                    text:
                      "Open MemeScope",
                    url:
                      `${site}/token/${encoded}`,
                  },
                  {
                    text:
                      "Solscan",
                    url:
                      `https://solscan.io/token/${encoded}`,
                  },
                ],
              ],
            },
          },
        );
      }
    } else if (
      command === "/channel"
    ) {
      await telegramSendMessage(
        chatId,
        channelUrl
          ? `📢 <a href="${escapeTelegramHtml(
              channelUrl,
            )}">Open MemeScope Signal Channel</a>`
          : "Signal channel URL is not configured yet.",
        {
          replyToMessageId:
            message.message_id,
        },
      );
    } else {
      await telegramSendMessage(
        chatId,
        helpText(),
        {
          replyToMessageId:
            message.message_id,
        },
      );
    }
  } catch (error) {
    await telegramSendMessage(
      chatId,
      `MemeScope bot error: ${escapeTelegramHtml(
        error instanceof Error
          ? error.message
          : "Unknown error.",
      )}`,
      {
        replyToMessageId:
          message.message_id,
      },
    ).catch(
      () => undefined,
    );
  }

  return NextResponse.json({
    ok: true,
  });
}
