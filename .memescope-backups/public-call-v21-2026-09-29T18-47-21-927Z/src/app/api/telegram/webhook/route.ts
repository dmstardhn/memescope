import { tryHandleContentHqAdminRequest } from "@/lib/content-hq-v4/telegram-admin";
import {
  handleContentHqTelegramAction,
} from "@/lib/content-hq";
import {
  NextResponse,
} from "next/server";

import {
  bindContentHq,
  getContentHqStatus,
  setContentOpportunityStatus,
} from "@/lib/call-story";
import {
  applySignalPreset,
  getSignalEngineSettings,
  signalPresetName,
  type SignalEngineSettings,
  type SignalPresetName,
} from "@/lib/signal-engine-settings";
import {
  escapeTelegramHtml,
  telegramAnswerCallbackQuery,
  telegramConfig,
  telegramEditMessage,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

type TelegramMessage = {
  message_id?: number;
  text?: string;
  chat?: {
    id?: number;
    type?: string;
    title?: string;
  };
  from?: {
    id?: number;
  };
};

type TelegramCallbackQuery = {
  id?: string;
  data?: string;
  from?: {
    id?: number;
  };
  message?: TelegramMessage;
};

type TelegramUpdate = {
  message?: TelegramMessage;
  callback_query?: TelegramCallbackQuery;
};

type InlineKeyboard = {
  inline_keyboard: Array<
    Array<{
      text: string;
      callback_data?: string;
      url?: string;
    }>
  >;
};

function ownerId() {
  return (
    process.env
      .TELEGRAM_OWNER_ID
      ?.trim() ??
    ""
  );
}

function isOwner(
  userId: number | undefined,
) {
  const expected =
    ownerId();

  return Boolean(
    expected &&
      userId &&
      String(userId) ===
        expected,
  );
}

function validSolanaAddress(
  value: string,
) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(
    value,
  );
}

function money(
  value: number,
) {
  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(1)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(0)}K`;
  }

  return `$${value.toFixed(0)}`;
}

function presetTitle(
  preset:
    | SignalPresetName
    | "custom",
) {
  if (
    preset === "aggressive"
  ) {
    return "AGGRESSIVE";
  }

  if (
    preset === "balanced"
  ) {
    return "BALANCED";
  }

  if (
    preset === "strict"
  ) {
    return "STRICT";
  }

  if (
    preset === "ultra"
  ) {
    return "ULTRA STRICT";
  }

  return "CUSTOM (LEGACY)";
}

function presetText(
  settings:
    SignalEngineSettings,
) {
  const current =
    signalPresetName(
      settings,
    );

  return [
    "<b>MEMESCOPE PRESET CONTROL</b>",
    "",
    `Active preset: <b>${presetTitle(
      current,
    )}</b>`,
    "",
    "<b>Choose how selective the engine should be:</b>",
    "",
    "\uD83D\uDD25 <b>AGGRESSIVE</b> - more signals",
    "Score >= 65 | Liquidity >= $25K | Age &lt;= 48h | Confirm 1 scan",
    "",
    "\u2696\uFE0F <b>BALANCED</b> - standard HQ mode",
    "Score >= 80 | Liquidity >= $50K | Age &lt;= 24h | Confirm 1 scan",
    "",
    "\uD83D\uDEE1\uFE0F <b>STRICT</b> - fewer, tighter signals",
    "Score >= 88 | Liquidity >= $100K | Age &lt;= 12h | Confirm 1 scan",
    "",
    "\uD83D\uDD12 <b>ULTRA STRICT</b> - rarest signals",
    "Score >= 92 | Liquidity >= $150K | Age &lt;= 6h | Confirm 2 scans",
    "",
    "<b>Current values</b>",
    `Score >= ${settings.minSignalScore}`,
    `Liquidity >= ${money(
      settings.minLiquidityUsd,
    )}`,
    `Max age &lt;= ${settings.maxPairAgeHours}h`,
    `Confirmation = ${settings.confirmationScans} consecutive scan${
      settings.confirmationScans === 1
        ? ""
        : "s"
    }`,
    "",
    "<i>Stage 16 HQ volume, transaction, buy-pressure, spike, momentum and liquidity/valuation gates remain active in every preset.</i>",
    "<i>Preset strictness changes detection frequency; it does not guarantee future performance.</i>",
  ].join("\n");
}

function presetKeyboard(
  settings:
    SignalEngineSettings,
): InlineKeyboard {
  const current =
    signalPresetName(
      settings,
    );

  const label = (
    name: SignalPresetName,
    text: string,
  ) =>
    current === name
      ? `\u2705 ${text}`
      : text;

  return {
    inline_keyboard: [
      [
        {
          text:
            label(
              "aggressive",
              "\uD83D\uDD25 Aggressive",
            ),
          callback_data:
            "preset:aggressive",
        },
        {
          text:
            label(
              "balanced",
              "\u2696\uFE0F Balanced",
            ),
          callback_data:
            "preset:balanced",
        },
      ],
      [
        {
          text:
            label(
              "strict",
              "\uD83D\uDEE1\uFE0F Strict",
            ),
          callback_data:
            "preset:strict",
        },
        {
          text:
            label(
              "ultra",
              "\uD83D\uDD12 Ultra Strict",
            ),
          callback_data:
            "preset:ultra",
        },
      ],
      [
        {
          text:
            "\uD83D\uDD04 Refresh",
          callback_data:
            "preset:refresh",
        },
      ],
    ],
  };
}

async function reply(
  chatId: number,
  messageId:
    number | undefined,
  text: string,
  keyboard?: InlineKeyboard,
) {
  return telegramSendMessage(
    chatId,
    text,
    {
      replyToMessageId:
        messageId,
      ...(keyboard
        ? {
            replyMarkup:
              keyboard as unknown as Record<
                string,
                unknown
              >,
          }
        : {}),
    },
  );
}

async function showSettings(
  chatId: number,
  messageId?:
    number,
) {
  const settings =
    await getSignalEngineSettings();

  if (messageId) {
    await telegramEditMessage(
      chatId,
      messageId,
      presetText(
        settings,
      ),
      presetKeyboard(
        settings,
      ) as unknown as Record<
        string,
        unknown
      >,
    );
    return;
  }

  await telegramSendMessage(
    chatId,
    presetText(
      settings,
    ),
    {
      replyMarkup:
        presetKeyboard(
          settings,
        ) as unknown as Record<
          string,
          unknown
        >,
    },
  );
}

async function handleCallback(
  callback:
    TelegramCallbackQuery,
) {
  const callbackId =
    callback.id;

  const userId =
    callback.from?.id;

  const chatId =
    callback.message?.chat?.id;

  const messageId =
    callback.message?.message_id;

  const data =
    callback.data ??
    "";

  if (!callbackId) {
    return;
  }

  if (!isOwner(userId)) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Owner only.",
        showAlert: true,
      },
    );
    return;
  }

  if (
    !chatId ||
    !messageId
  ) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Control message unavailable.",
        showAlert: true,
      },
    );
    return;
  }

  if (
    data.startsWith(
      "hq2:",
    )
  ) {
    const [
      ,
      action,
      rawId,
    ] = data.split(":");

    const contentId =
      Number(rawId);

    if (
      !Number.isInteger(
        contentId,
      ) ||
      contentId <= 0 ||
      ![
        "approve",
        "reject",
        "regenerate",
        "caption",
        "publish",
      ].includes(action)
    ) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            "Unknown Content HQ action.",
          showAlert: true,
        },
      );
      return;
    }

    try {
      const result =
        await handleContentHqTelegramAction(
          action,
          contentId,
        );

      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            result.message.slice(
              0,
              180,
            ),
        },
      );
    } catch (error) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            error instanceof Error
              ? error.message.slice(
                  0,
                  180,
                )
              : "Content HQ action failed.",
          showAlert: true,
        },
      );
    }

    return;
  }

  if (
    data.startsWith(
      "content:",
    )
  ) {
    const [
      ,
      action,
      rawId,
    ] = data.split(":");

    const opportunityId =
      Number(rawId);

    if (
      !Number.isInteger(
        opportunityId,
      ) ||
      opportunityId <= 0 ||
      (action !== "used" &&
        action !== "skip")
    ) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            "Unknown content action.",
          showAlert: true,
        },
      );
      return;
    }

    await setContentOpportunityStatus(
      opportunityId,
      action === "used"
        ? "used"
        : "skipped",
    );

    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          action === "used"
            ? "Marked as used."
            : "Content skipped.",
      },
    );

    return;
  }

  if (
    data ===
    "preset:refresh"
  ) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Refreshing settings...",
      },
    );

    await showSettings(
      chatId,
      messageId,
    );

    return;
  }

  const rawPreset =
    data.startsWith(
      "preset:",
    )
      ? data.slice(
          "preset:".length,
        )
      : "";

  const valid =
    rawPreset ===
      "aggressive" ||
    rawPreset ===
      "balanced" ||
    rawPreset ===
      "strict" ||
    rawPreset ===
      "ultra";

  if (!valid) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Unknown preset.",
        showAlert: true,
      },
    );
    return;
  }

  const preset =
    rawPreset as
      SignalPresetName;

  await telegramAnswerCallbackQuery(
    callbackId,
    {
      text:
        `Applying ${presetTitle(
          preset,
        )}...`,
    },
  );

  try {
    const settings =
      await applySignalPreset(
        preset,
      );

    await telegramEditMessage(
      chatId,
      messageId,
      presetText(
        settings,
      ),
      presetKeyboard(
        settings,
      ) as unknown as Record<
        string,
        unknown
      >,
    );
  } catch (error) {
    await telegramSendMessage(
      chatId,
      `<b>Preset update failed</b>\n${escapeTelegramHtml(
        error instanceof Error
          ? error.message
          : "Unknown error.",
      )}`,
    );
  }
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
    number > 0
      ? "+"
      : ""
  }${number.toFixed(2)}%`;
}

function helpText() {
  return [
    "<b>MemeScope Owner Bot</b>",
    "",
    "/settings - preset control panel",
    "/contenthq - Content HQ status",
    "/bindcontenthq - bind this private group as Content HQ",
    "/signals - active HQ signals",
    "/history - recent signal history",
    "/stats - 30-day signal statistics",
    "/token &lt;CA&gt; - open token",
    "/risk &lt;CA&gt; - open risk analysis",
    "/channel - signal channel",
    "/whoami - show Telegram user ID",
    "/help - commands",
    "",
    "<i>Signal configuration is preset-only. Open /settings and tap one button.</i>",
  ].join("\n");
}

export async function POST(
  request: Request,
) {
  const contentHqAdmin = await tryHandleContentHqAdminRequest(request.clone());
  if (contentHqAdmin.handled) {
    return Response.json({ ok: true });
  }

  const {
    webhookSecret,
    channelUrl,
  } =
    telegramConfig();

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

  if (
    update.callback_query
  ) {
    await handleCallback(
      update.callback_query,
    ).catch(
      async (error) => {
        const chatId =
          update.callback_query
            ?.message
            ?.chat
            ?.id;

        if (chatId) {
          await telegramSendMessage(
            chatId,
            `<b>Button action failed</b>\n${escapeTelegramHtml(
              error instanceof Error
                ? error.message
                : "Unknown callback error.",
            )}`,
          ).catch(
            () => undefined,
          );
        }
      },
    );

    return NextResponse.json({
      ok: true,
    });
  }

  const message =
    update.message;

  const chatId =
    message?.chat?.id;

  const userId =
    message?.from?.id;

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
  ] =
    rawText.split(/\s+/);

  const command =
    rawCommand
      .toLowerCase()
      .split("@")[0];

  const argument =
    args.join(" ").trim();

  if (
    command === "/whoami"
  ) {
    await reply(
      chatId,
      message.message_id,
      [
        "<b>Telegram User ID</b>",
        "",
        `<code>${escapeTelegramHtml(
          userId ??
            "unknown",
        )}</code>`,
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  if (!ownerId()) {
    await reply(
      chatId,
      message.message_id,
      [
        "<b>Owner access is not configured.</b>",
        "",
        `Your Telegram User ID: <code>${escapeTelegramHtml(
          userId ??
            "unknown",
        )}</code>`,
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  if (!isOwner(userId)) {
    await reply(
      chatId,
      message.message_id,
      "Unauthorized. This MemeScope bot is owner-only.",
    );

    return NextResponse.json({
      ok: true,
    });
  }

  const origin =
    new URL(
      request.url,
    ).origin;

  const site =
    telegramSiteUrl();

  try {
    if (
      command ===
      "/bindcontenthq"
    ) {
      const chatType =
        message.chat?.type ??
        "";

      if (
        chatType !== "group" &&
        chatType !==
          "supergroup"
      ) {
        await reply(
          chatId,
          message.message_id,
          [
            "<b>Content HQ binding</b>",
            "",
            "Create a private Telegram group, add this bot, then run <code>/bindcontenthq</code> inside that group.",
          ].join("\n"),
        );
      } else {
        await bindContentHq(
          chatId,
        );

        await reply(
          chatId,
          message.message_id,
          [
            "... <b>MEMESCOPE CONTENT HQ CONNECTED</b>",
            "",
            `Group: <b>${escapeTelegramHtml(
              message.chat?.title ??
                "Private group",
            )}</b>`,
            "",
            "High-value call stories, content hooks and share-card links will be delivered here for admin review.",
            "",
            "<i>No X post is sent automatically.</i>",
          ].join("\n"),
        );
      }
    } else if (
      command === "/contenthq"
    ) {
      const hq =
        await getContentHqStatus();

      await reply(
        chatId,
        message.message_id,
        hq.configured
          ? [
              "<b>MemeScope Content HQ</b>",
              "",
              "Status: <b>CONNECTED</b>",
              `Chat ID: <code>${escapeTelegramHtml(
                hq.chatId ??
                  "unknown",
              )}</code>`,
              "",
              "Content opportunities are generated automatically. X publishing remains manual.",
            ].join("\n")
          : [
              "<b>MemeScope Content HQ</b>",
              "",
              "Status: <b>NOT CONNECTED</b>",
              "",
              "Create a private group, add this bot, and run <code>/bindcontenthq</code> there.",
            ].join("\n"),
      );
    } else if (
      command === "/start" ||
      command === "/help"
    ) {
      await reply(
        chatId,
        message.message_id,
        helpText(),
      );
    } else if (
      command === "/settings"
    ) {
      const settings =
        await getSignalEngineSettings();

      await reply(
        chatId,
        message.message_id,
        presetText(
          settings,
        ),
        presetKeyboard(
          settings,
        ),
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
              "<b>Active HQ Signals</b>",
              "",
              "No active confirmed HQ signal right now.",
            ].join("\n")
          : [
              "<b>Active HQ Signals</b>",
              "",
              ...active.map(
                (
                  record,
                  index,
                ) =>
                  `${index + 1}. <b>$${escapeTelegramHtml(
                    record.symbol,
                  )}</b> - score ${Math.round(
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

      await reply(
        chatId,
        message.message_id,
        text,
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
        "<b>Recent Signal History</b>",
        "",
        ...(records.length
          ? records.map(
              (
                record,
                index,
              ) =>
                `${index + 1}. <b>$${escapeTelegramHtml(
                  record.symbol,
                )}</b> - ${escapeTelegramHtml(
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

      await reply(
        chatId,
        message.message_id,
        text,
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
        "<b>MemeScope - 30D Stats</b>",
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

      await reply(
        chatId,
        message.message_id,
        text,
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
        await reply(
          chatId,
          message.message_id,
          `Usage: ${command} &lt;Solana CA&gt;`,
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
              ? "<b>MemeScope Risk Analyzer</b>"
              : "<b>MemeScope Token</b>",
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
      await reply(
        chatId,
        message.message_id,
        channelUrl
          ? `<a href="${escapeTelegramHtml(
              channelUrl,
            )}">Open MemeScope Signal Channel</a>`
          : "Signal channel URL is not configured yet.",
      );
    } else {
      await reply(
        chatId,
        message.message_id,
        helpText(),
      );
    }
  } catch (error) {
    await reply(
      chatId,
      message.message_id,
      `MemeScope bot error: ${escapeTelegramHtml(
        error instanceof Error
          ? error.message
          : "Unknown error.",
      )}`,
    ).catch(
      () => undefined,
    );
  }

  return NextResponse.json({
    ok: true,
  });
}