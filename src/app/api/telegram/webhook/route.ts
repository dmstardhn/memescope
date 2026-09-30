import {
  getFreeChannelAdminSettings,
  sendFreeChannelTest,
  updateFreeChannelAdminSettings,
  type FreeChannelAdminSettings,
} from "@/lib/free-channel";
// MEMESCOPE FREE ADMIN V2
import { getCallDashboard } from "@/lib/call-story";
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
    preset === "strict"
  ) {
    return "SAFE";
  }

  if (
    preset === "balanced"
  ) {
    return "BALANCED";
  }

  if (
    preset === "aggressive"
  ) {
    return "AGGRESSIVE";
  }

  if (
    preset === "ultra"
  ) {
    return "ULTRA";
  }

  return "CUSTOM";
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
    "<b>Signal sensitivity</b>",
    "",
    "🛡 <b>SAFE</b> - tightest filtering",
    "Score >= 88 | Liq >= $100K | Vol 5m >= $12K | Momentum >= +2.5% | Confirm 2",
    "",
    "⚖️ <b>BALANCED</b> - standard mode",
    "Score >= 80 | Liq >= $50K | Vol 5m >= $10K | Momentum >= +2.0% | Confirm 1",
    "",
    "🔥 <b>AGGRESSIVE</b> - earlier and more frequent",
    "Score >= 62 | Liq >= $25K | Vol 5m >= $7K | Momentum >= +1.0% | Confirm 1",
    "",
    "⚡ <b>ULTRA</b> - most sensitive early-move preset",
    "Score >= 52 | Liq >= $15K | Vol 5m >= $4K | Momentum >= +0.4% | Confirm 1",
    "",
    "<b>Current values</b>",
    `Score >= ${settings.minSignalScore}`,
    `Liquidity >= ${money(
      settings.minLiquidityUsd,
    )}`,
    `Age = ${settings.minPairAgeMinutes}m - ${settings.maxPairAgeHours}h`,
    `Volume 5m >= ${money(
      settings.minVolume5mUsd,
    )}`,
    `Transactions 5m >= ${settings.minTransactions5m}`,
    `Buy pressure = ${(settings.minBuyShare * 100).toFixed(
      0,
    )}% - ${(settings.maxBuyShare * 100).toFixed(
      0,
    )}%`,
    `Volume expansion = ${settings.minVolumeSpike.toFixed(
      2,
    )}x - ${settings.maxVolumeSpike.toFixed(
      2,
    )}x`,
    `5m momentum = ${settings.minMomentum5m >= 0 ? "+" : ""}${settings.minMomentum5m.toFixed(
      1,
    )}% to +${settings.maxMomentum5m.toFixed(
      1,
    )}%`,
    `Liquidity / valuation >= ${(settings.minLiquidityValuationRatio * 100).toFixed(
      1,
    )}%`,
    `Confirmation = ${settings.confirmationScans} scan${
      settings.confirmationScans === 1
        ? ""
        : "s"
    }`,
    "",
    "<i>ULTRA relaxes soft gates but still rejects invalid/stale market structures and limited-confidence data.</i>",
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
      ? `✅ ${text}`
      : text;

  return {
    inline_keyboard: [
      [
        {
          text:
            label(
              "strict",
              "🛡 Safe",
            ),
          callback_data:
            "preset:strict",
        },
        {
          text:
            label(
              "balanced",
              "⚖️ Balanced",
            ),
          callback_data:
            "preset:balanced",
        },
      ],
      [
        {
          text:
            label(
              "aggressive",
              "🔥 Aggressive",
            ),
          callback_data:
            "preset:aggressive",
        },
        {
          text:
            label(
              "ultra",
              "⚡ Ultra",
            ),
          callback_data:
            "preset:ultra",
        },
      ],
      [
        {
          text:
            "🔄 Refresh",
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

function freeAdminText(settings: FreeChannelAdminSettings) {
  const state = (value: boolean) => (value ? "🟢 ON" : "🔴 OFF");

  return [
    "<b>🆓 MemeScope FREE Channel</b>",
    "",
    `Channel: <b>${settings.configured ? "CONNECTED" : "NOT CONFIGURED"}</b>`,
    `FREE System: <b>${state(settings.enabled)}</b>`,
    `DEX Paid Alerts: <b>${state(settings.dexEnabled)}</b>`,
    `VIP Results: <b>${state(settings.vipResultsEnabled)}</b>`,
    `Minimum VIP Result: <b>${settings.minVipResultMultiple}X</b>`,
    "",
    "<i>VIP entries are never published to the FREE channel.</i>",
  ].join("\n");
}

function freeAdminKeyboard(settings: FreeChannelAdminSettings) {
  const checked = (value: number) =>
    settings.minVipResultMultiple === value ? " ✅" : "";

  return {
    inline_keyboard: [
      [
        {
          text: settings.enabled ? "🟢 FREE ON" : "🔴 FREE OFF",
          callback_data: "free:toggle",
        },
      ],
      [
        {
          text: settings.dexEnabled ? "DEX Alerts: ON" : "DEX Alerts: OFF",
          callback_data: "free:dex",
        },
        {
          text: settings.vipResultsEnabled ? "VIP Results: ON" : "VIP Results: OFF",
          callback_data: "free:vip",
        },
      ],
      [
        { text: `3X${checked(3)}`, callback_data: "free:min:3" },
        { text: `5X${checked(5)}`, callback_data: "free:min:5" },
        { text: `10X${checked(10)}`, callback_data: "free:min:10" },
      ],
      [
        { text: "🧪 Test DEX", callback_data: "free:test:dex" },
        { text: "🧪 Test VIP", callback_data: "free:test:vip" },
      ],
      [
        { text: "🔄 Refresh", callback_data: "free:refresh" },
      ],
    ],
  };
}

async function showFreeAdmin(
  chatId: number,
  messageId?: number,
) {
  const settings = await getFreeChannelAdminSettings();
  const keyboard =
    freeAdminKeyboard(settings) as unknown as Record<string, unknown>;

  if (messageId) {
    await telegramEditMessage(
      chatId,
      messageId,
      freeAdminText(settings),
      keyboard,
    );
    return;
  }

  await telegramSendMessage(
    chatId,
    freeAdminText(settings),
    { replyMarkup: keyboard },
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

  if (data.startsWith("free:")) {
    try {
      const parts = data.split(":");
      const action = parts[1] ?? "";

      if (action === "test") {
        const kind = parts[2] === "vip" ? "vip" : "dex";
        await sendFreeChannelTest(kind);

        await telegramAnswerCallbackQuery(
          callbackId,
          {
            text: `FREE ${kind.toUpperCase()} test sent.`,
          },
        );
        return;
      }

      const current =
        await getFreeChannelAdminSettings();

      if (action === "toggle") {
        await updateFreeChannelAdminSettings({
          enabled: !current.enabled,
        });
      } else if (action === "dex") {
        await updateFreeChannelAdminSettings({
          dexEnabled: !current.dexEnabled,
        });
      } else if (action === "vip") {
        await updateFreeChannelAdminSettings({
          vipResultsEnabled: !current.vipResultsEnabled,
        });
      } else if (action === "min") {
        const raw = Number(parts[2]);
        const minVipResultMultiple: 3 | 5 | 10 =
          raw >= 10 ? 10 : raw >= 5 ? 5 : 3;

        await updateFreeChannelAdminSettings({
          minVipResultMultiple,
        });
      } else if (action !== "refresh") {
        throw new Error("Unknown FREE Channel action.");
      }

      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            action === "refresh"
              ? "Refreshed."
              : "FREE Channel updated.",
        },
      );

      await showFreeAdmin(
        chatId,
        messageId,
      );
    } catch (error) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            error instanceof Error
              ? error.message.slice(0, 180)
              : "FREE Channel action failed.",
          showAlert: true,
        },
      );
    }

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
    "/free - FREE channel control panel",
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
      command === "/free"
    ) {
      await showFreeAdmin(
        chatId,
        message.message_id,
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
      const dashboard =
        await getCallDashboard(
          30,
        );

      const best =
        dashboard.topCalls[0] ??
        null;

      const performanceText = (
        value:
          | number
          | null,
      ) => {
        if (
          value === null ||
          !Number.isFinite(
            value,
          )
        ) {
          return "N/A";
        }

        if (value >= 2) {
          return `${value.toFixed(
            value >= 10
              ? 1
              : 2,
          )}X`;
        }

        return `+${Math.max(
          0,
          (value - 1) * 100,
        ).toFixed(0)}%`;
      };

      const text = [
        "<b>MemeScope Calls — 30D</b>",
        "",
        `Calls: <b>${dashboard.totalCalls}</b>`,
        `Running: <b>${dashboard.runningCalls}</b>`,
        `2X+: <b>${dashboard.reached2x}</b>`,
        `5X+: <b>${dashboard.reached5x}</b>`,
        `10X+: <b>${dashboard.reached10x}</b>`,
        `Best Runner: <b>${
          best
            ? `${escapeTelegramHtml(
                best.symbol,
              )} ${performanceText(
                best.peakMultiple,
              )}`
            : "N/A"
        }</b>`,
        `Median Peak: <b>${performanceText(
          dashboard.medianPeakMultiple,
        )}</b>`,
        "",
        "<i>Based on timestamped MemeScope calls and actual post-call peaks.</i>",
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