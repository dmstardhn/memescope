$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 19.1 - Telegram Visual Control" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$telegramPath = Join-Path $root "src/lib/telegram.ts"
$webhookPath = Join-Path $root "src/app/api/telegram/webhook/route.ts"

foreach ($path in @($telegramPath, $webhookPath)) {
    if (!(Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

$webhookCurrent = [System.IO.File]::ReadAllText($webhookPath)

if (
    !$webhookCurrent.Contains("TELEGRAM_OWNER_ID") -or
    !$webhookCurrent.Contains("MEMESCOPE OWNER CONTROL")
) {
    throw "Stage 19 owner webhook belum terdeteksi. Jalankan FIX-STAGE19-TELEGRAM.ps1 terlebih dahulu."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-Stage19.1-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath $telegramPath -Destination (Join-Path $backup "telegram.ts.bak") -Force
Copy-Item -LiteralPath $webhookPath -Destination (Join-Path $backup "webhook-route.ts.bak") -Force

Write-Host "Backup created: $backup" -ForegroundColor DarkGray

# ============================================================
# 1. TELEGRAM HELPER: callback answer + callback webhook updates
# ============================================================

$telegram = [System.IO.File]::ReadAllText($telegramPath)
$telegramOriginal = $telegram

if (!$telegram.Contains("telegramAnswerCallbackQuery")) {
    $marker = "export async function telegramSetCommands()"

    $index = $telegram.IndexOf($marker)

    if ($index -lt 0) {
        throw "telegramSetCommands marker tidak ditemukan."
    }

$helper = @'
export async function telegramAnswerCallbackQuery(
  callbackQueryId: string,
  options?: {
    text?: string;
    showAlert?: boolean;
  },
) {
  return telegramRequest<boolean>(
    "answerCallbackQuery",
    {
      callback_query_id:
        callbackQueryId,
      ...(options?.text
        ? {
            text:
              options.text,
          }
        : {}),
      show_alert:
        options?.showAlert ??
        false,
    },
  );
}

'@

    $telegram =
        $telegram.Substring(0, $index) +
        $helper +
        $telegram.Substring($index)
}

$oldAllowed = @'
      allowed_updates: [
        "message",
      ],
'@

$newAllowed = @'
      allowed_updates: [
        "message",
        "callback_query",
      ],
'@

if ($telegram.Contains($oldAllowed)) {
    $telegram =
        $telegram.Replace(
            $oldAllowed,
            $newAllowed
        )
}
elseif (!$telegram.Contains('"callback_query"')) {
    throw "allowed_updates marker tidak ditemukan."
}

if (
    !$telegram.Contains("telegramAnswerCallbackQuery") -or
    !$telegram.Contains('"callback_query"')
) {
    throw "Telegram helper validation failed."
}

if ($telegram -ne $telegramOriginal) {
    [System.IO.File]::WriteAllText(
        $telegramPath,
        $telegram,
        $utf8
    )

    Write-Host "Updated: src/lib/telegram.ts" -ForegroundColor Green
} else {
    Write-Host "Telegram helper already patched." -ForegroundColor Yellow
}

# ============================================================
# 2. STAGE 19.1 VISUAL OWNER WEBHOOK
# ============================================================

$webhook = @'
import {
  NextResponse,
} from "next/server";

import {
  applySignalPreset,
  getSignalEngineSettings,
  resetSignalEngineSettings,
  saveSignalEngineSettings,
  signalPresetName,
  type SignalPresetName,
} from "@/lib/signal-engine-settings";
import type {
  SignalSettings,
} from "@/lib/signal-types";
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
  };
  from?: {
    id?: number;
    username?: string;
    first_name?: string;
  };
};

type TelegramCallbackQuery = {
  id?: string;
  data?: string;
  from?: {
    id?: number;
    username?: string;
    first_name?: string;
  };
  message?: TelegramMessage;
};

type TelegramUpdate = {
  message?: TelegramMessage;
  callback_query?: TelegramCallbackQuery;
};

type InlineButton = {
  text: string;
  callback_data?: string;
  url?: string;
};

type InlineKeyboard = {
  inline_keyboard: InlineButton[][];
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

function compactUsd(
  value: number,
) {
  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(0)}K`;
  }

  return `$${value.toFixed(0)}`;
}

function currentMark(
  active: boolean,
) {
  return active
    ? " [CURRENT]"
    : "";
}

function mainSettingsText(
  settings: SignalSettings,
) {
  const preset =
    signalPresetName(
      settings,
    );

  return [
    "<b>MEMESCOPE ENGINE CONTROL</b>",
    "",
    "Engine: <b>ACTIVE</b>",
    `Preset: <b>${escapeTelegramHtml(
      preset.toUpperCase(),
    )}</b>`,
    "",
    "<b>Owner-adjustable filters</b>",
    `Signal Score        &gt;= <b>${settings.minSignalScore}</b>`,
    `Liquidity           &gt;= <b>${compactUsd(
      settings.minLiquidityUsd,
    )}</b>`,
    `Maximum Pair Age    <b>${settings.maxPairAgeHours}h</b>`,
    "",
    "<b>Stage 16 HQ filters</b>",
    "Volume 5m           &gt;= $10K",
    "Transactions 5m     &gt;= 40",
    "Buy Pressure        60% - 88%",
    "Volume Spike        1.30x - 3.50x",
    "Momentum 5m         +2% - +15%",
    "Momentum 1h         -5% - +120%",
    "Liquidity / MC      &gt;= 8%",
    "Confirmation        2 scans",
    "Potential TP        Dynamic",
    "",
    "<i>Tap a button below. Changes are stored server-side and apply to new detections.</i>",
  ].join("\n");
}

function mainKeyboard(): InlineKeyboard {
  return {
    inline_keyboard: [
      [
        {
          text:
            "\u2699\uFE0F Preset",
          callback_data:
            "ms:preset",
        },
        {
          text:
            "\u2B50 Score",
          callback_data:
            "ms:score",
        },
      ],
      [
        {
          text:
            "\uD83D\uDCA7 Liquidity",
          callback_data:
            "ms:liq",
        },
        {
          text:
            "\u23F1 Pair Age",
          callback_data:
            "ms:age",
        },
      ],
      [
        {
          text:
            "\uD83D\uDD27 Advanced",
          callback_data:
            "ms:advanced",
        },
        {
          text:
            "\uD83D\uDD04 Refresh",
          callback_data:
            "ms:refresh",
        },
      ],
      [
        {
          text:
            "\u21BA Reset Default",
          callback_data:
            "ms:reset",
        },
      ],
    ],
  };
}

function backKeyboard(): InlineKeyboard {
  return {
    inline_keyboard: [
      [
        {
          text:
            "\u2190 Back",
          callback_data:
            "ms:menu",
        },
      ],
    ],
  };
}

function presetText(
  settings: SignalSettings,
) {
  const preset =
    signalPresetName(
      settings,
    );

  return [
    "<b>ENGINE PRESET</b>",
    "",
    `Current: <b>${escapeTelegramHtml(
      preset.toUpperCase(),
    )}</b>`,
    "",
    "<b>STRICT</b>",
    "Score >= 90 | Liquidity >= $100K | Age <= 12h",
    "",
    "<b>BALANCED HQ</b>",
    "Score >= 80 | Liquidity >= $50K | Age <= 24h",
    "",
    "<b>BROAD</b>",
    "Score >= 75 | Liquidity >= $25K | Age <= 48h",
    "",
    "<i>Choose one preset. You can still customize individual values afterwards.</i>",
  ].join("\n");
}

function presetKeyboard(
  settings: SignalSettings,
): InlineKeyboard {
  const current =
    signalPresetName(
      settings,
    );

  return {
    inline_keyboard: [
      [
        {
          text:
            `Strict${currentMark(
              current === "strict",
            )}`,
          callback_data:
            "ms:preset:strict",
        },
      ],
      [
        {
          text:
            `Balanced HQ${currentMark(
              current === "balanced",
            )}`,
          callback_data:
            "ms:preset:balanced",
        },
      ],
      [
        {
          text:
            `Broad${currentMark(
              current === "broad",
            )}`,
          callback_data:
            "ms:preset:broad",
        },
      ],
      [
        {
          text:
            "\u2190 Back",
          callback_data:
            "ms:menu",
        },
      ],
    ],
  };
}

function scoreText(
  settings: SignalSettings,
) {
  return [
    "<b>MINIMUM SIGNAL SCORE</b>",
    "",
    `Current: <b>${settings.minSignalScore}</b>`,
    "",
    "Higher values are more selective.",
    "",
    "<i>Tap a value to save it immediately.</i>",
  ].join("\n");
}

function scoreKeyboard(
  settings: SignalSettings,
): InlineKeyboard {
  const values = [
    60,
    70,
    75,
    80,
    85,
    90,
    95,
  ];

  const buttons =
    values.map(
      (value) => ({
        text:
          `${value}${currentMark(
            settings.minSignalScore ===
              value,
          )}`,
        callback_data:
          `ms:score:${value}`,
      }),
    );

  return {
    inline_keyboard: [
      buttons.slice(0, 3),
      buttons.slice(3, 6),
      buttons.slice(6),
      [
        {
          text:
            "\u2190 Back",
          callback_data:
            "ms:menu",
        },
      ],
    ],
  };
}

function liquidityText(
  settings: SignalSettings,
) {
  return [
    "<b>MINIMUM LIQUIDITY</b>",
    "",
    `Current: <b>${compactUsd(
      settings.minLiquidityUsd,
    )}</b>`,
    "",
    "Higher values require deeper pools.",
    "",
    "<i>Tap a value to save it immediately.</i>",
  ].join("\n");
}

function liquidityKeyboard(
  settings: SignalSettings,
): InlineKeyboard {
  const values = [
    10_000,
    25_000,
    50_000,
    75_000,
    100_000,
    150_000,
    250_000,
    500_000,
  ];

  const buttons =
    values.map(
      (value) => ({
        text:
          `${compactUsd(
            value,
          )}${currentMark(
            settings.minLiquidityUsd ===
              value,
          )}`,
        callback_data:
          `ms:liq:${value}`,
      }),
    );

  return {
    inline_keyboard: [
      buttons.slice(0, 2),
      buttons.slice(2, 4),
      buttons.slice(4, 6),
      buttons.slice(6, 8),
      [
        {
          text:
            "\u2190 Back",
          callback_data:
            "ms:menu",
        },
      ],
    ],
  };
}

function ageText(
  settings: SignalSettings,
) {
  return [
    "<b>MAXIMUM PAIR AGE</b>",
    "",
    `Current: <b>${settings.maxPairAgeHours}h</b>`,
    "",
    "Tokens older than this limit are excluded from new HQ detections.",
    "",
    "<i>Tap a value to save it immediately.</i>",
  ].join("\n");
}

function ageKeyboard(
  settings: SignalSettings,
): InlineKeyboard {
  const values = [
    6,
    12,
    18,
    24,
    48,
    72,
    168,
  ];

  const buttons =
    values.map(
      (value) => ({
        text:
          `${
            value === 168
              ? "7d"
              : `${value}h`
          }${currentMark(
            settings.maxPairAgeHours ===
              value,
          )}`,
        callback_data:
          `ms:age:${value}`,
      }),
    );

  return {
    inline_keyboard: [
      buttons.slice(0, 3),
      buttons.slice(3, 6),
      buttons.slice(6),
      [
        {
          text:
            "\u2190 Back",
          callback_data:
            "ms:menu",
        },
      ],
    ],
  };
}

function advancedText() {
  return [
    "<b>STAGE 16 ADVANCED FILTERS</b>",
    "",
    "<b>These remain fixed in Stage 19.1:</b>",
    "",
    "Volume 5m           >= $10K",
    "Transactions 5m     >= 40",
    "Buy Pressure        60% - 88%",
    "Volume Spike        1.30x - 3.50x",
    "Momentum 5m         +2% - +15%",
    "Momentum 1h         -5% - +120%",
    "Liquidity / MC      >= 8%",
    "Confirmation        2 consecutive scans",
    "Potential TP        Dynamic analysis",
    "",
    "<i>Score, Liquidity and Pair Age can be changed from the main control panel.</i>",
  ].join("\n");
}

function helpText() {
  return [
    "<b>MemeScope Owner Bot</b>",
    "",
    "/settings - visual signal control panel",
    "/signals - active HQ signals",
    "/history - recent signal history",
    "/stats - 30-day signal statistics",
    "/token &lt;CA&gt; - open token",
    "/risk &lt;CA&gt; - open risk analysis",
    "/channel - signal channel",
    "/whoami - show Telegram user ID",
    "/help - commands",
    "",
    "<i>Use /settings for the easiest configuration.</i>",
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

async function reply(
  chatId: number,
  messageId: number | undefined,
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

async function editPanel(
  chatId: number,
  messageId: number,
  text: string,
  keyboard: InlineKeyboard,
) {
  return telegramEditMessage(
    chatId,
    messageId,
    text,
    keyboard as unknown as Record<
      string,
      unknown
    >,
  );
}

function oneNumber(
  value: string,
) {
  const number =
    Number(
      value.trim(),
    );

  return Number.isFinite(
    number,
  )
    ? number
    : null;
}

async function handleCallback(
  callback: TelegramCallbackQuery,
) {
  const callbackId =
    callback.id;

  const data =
    callback.data ??
    "";

  const userId =
    callback.from?.id;

  const chatId =
    callback.message?.chat?.id;

  const messageId =
    callback.message?.message_id;

  if (!callbackId) {
    return;
  }

  if (
    !isOwner(
      userId,
    )
  ) {
    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          "Unauthorized. Owner only.",
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
          "This control message is unavailable.",
        showAlert: true,
      },
    );

    return;
  }

  await telegramAnswerCallbackQuery(
    callbackId,
  );

  const parts =
    data.split(":");

  const action =
    parts[1] ??
    "menu";

  const value =
    parts[2] ??
    "";

  if (
    data === "ms:menu" ||
    data === "ms:refresh"
  ) {
    const settings =
      await getSignalEngineSettings();

    await editPanel(
      chatId,
      messageId,
      mainSettingsText(
        settings,
      ),
      mainKeyboard(),
    );

    return;
  }

  if (
    data === "ms:preset"
  ) {
    const settings =
      await getSignalEngineSettings();

    await editPanel(
      chatId,
      messageId,
      presetText(
        settings,
      ),
      presetKeyboard(
        settings,
      ),
    );

    return;
  }

  if (
    action === "preset" &&
    (
      value === "strict" ||
      value === "balanced" ||
      value === "broad"
    )
  ) {
    const settings =
      await applySignalPreset(
        value as SignalPresetName,
      );

    await editPanel(
      chatId,
      messageId,
      mainSettingsText(
        settings,
      ),
      mainKeyboard(),
    );

    return;
  }

  if (
    data === "ms:score"
  ) {
    const settings =
      await getSignalEngineSettings();

    await editPanel(
      chatId,
      messageId,
      scoreText(
        settings,
      ),
      scoreKeyboard(
        settings,
      ),
    );

    return;
  }

  if (
    action === "score"
  ) {
    const number =
      oneNumber(
        value,
      );

    if (
      number === null ||
      number < 60 ||
      number > 95
    ) {
      return;
    }

    const settings =
      await saveSignalEngineSettings({
        minSignalScore:
          Math.round(
            number,
          ),
      });

    await editPanel(
      chatId,
      messageId,
      mainSettingsText(
        settings,
      ),
      mainKeyboard(),
    );

    return;
  }

  if (
    data === "ms:liq"
  ) {
    const settings =
      await getSignalEngineSettings();

    await editPanel(
      chatId,
      messageId,
      liquidityText(
        settings,
      ),
      liquidityKeyboard(
        settings,
      ),
    );

    return;
  }

  if (
    action === "liq"
  ) {
    const number =
      oneNumber(
        value,
      );

    if (
      number === null ||
      number < 10_000 ||
      number > 1_000_000
    ) {
      return;
    }

    const settings =
      await saveSignalEngineSettings({
        minLiquidityUsd:
          Math.round(
            number,
          ),
      });

    await editPanel(
      chatId,
      messageId,
      mainSettingsText(
        settings,
      ),
      mainKeyboard(),
    );

    return;
  }

  if (
    data === "ms:age"
  ) {
    const settings =
      await getSignalEngineSettings();

    await editPanel(
      chatId,
      messageId,
      ageText(
        settings,
      ),
      ageKeyboard(
        settings,
      ),
    );

    return;
  }

  if (
    action === "age"
  ) {
    const number =
      oneNumber(
        value,
      );

    if (
      number === null ||
      number < 1 ||
      number > 168
    ) {
      return;
    }

    const settings =
      await saveSignalEngineSettings({
        maxPairAgeHours:
          Math.round(
            number,
          ),
      });

    await editPanel(
      chatId,
      messageId,
      mainSettingsText(
        settings,
      ),
      mainKeyboard(),
    );

    return;
  }

  if (
    data === "ms:advanced"
  ) {
    await editPanel(
      chatId,
      messageId,
      advancedText(),
      backKeyboard(),
    );

    return;
  }

  if (
    data === "ms:reset"
  ) {
    const settings =
      await resetSignalEngineSettings();

    await editPanel(
      chatId,
      messageId,
      mainSettingsText(
        settings,
      ),
      mainKeyboard(),
    );

    return;
  }

  const settings =
    await getSignalEngineSettings();

  await editPanel(
    chatId,
    messageId,
    mainSettingsText(
      settings,
    ),
    mainKeyboard(),
  );
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

  if (
    update.callback_query
  ) {
    try {
      await handleCallback(
        update.callback_query,
      );
    } catch (error) {
      const id =
        update.callback_query.id;

      if (id) {
        await telegramAnswerCallbackQuery(
          id,
          {
            text:
              error instanceof Error
                ? error.message.slice(
                    0,
                    180,
                  )
                : "MemeScope callback failed.",
            showAlert: true,
          },
        ).catch(
          () => undefined,
        );
      }
    }

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
  ] = rawText.split(/\s+/);

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

  if (
    !isOwner(
      userId,
    )
  ) {
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
        mainSettingsText(
          settings,
        ),
        mainKeyboard(),
      );
    } else if (
      command === "/preset"
    ) {
      const preset =
        argument.toLowerCase();

      if (!preset) {
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
        preset === "strict" ||
        preset === "balanced" ||
        preset === "broad"
      ) {
        const settings =
          await applySignalPreset(
            preset as SignalPresetName,
          );

        await reply(
          chatId,
          message.message_id,
          mainSettingsText(
            settings,
          ),
          mainKeyboard(),
        );
      } else {
        await reply(
          chatId,
          message.message_id,
          "Usage: /preset strict, /preset balanced, or /preset broad.",
        );
      }
    } else if (
      command === "/setscore"
    ) {
      const value =
        oneNumber(
          argument,
        );

      if (
        value === null ||
        value < 60 ||
        value > 95
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: /setscore 85 (allowed 60-95).",
        );
      } else {
        const settings =
          await saveSignalEngineSettings({
            minSignalScore:
              Math.round(
                value,
              ),
          });

        await reply(
          chatId,
          message.message_id,
          mainSettingsText(
            settings,
          ),
          mainKeyboard(),
        );
      }
    } else if (
      command === "/setliq"
    ) {
      const value =
        oneNumber(
          argument,
        );

      if (
        value === null ||
        value < 10_000 ||
        value > 1_000_000
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: /setliq 75000 (allowed 10000-1000000 USD).",
        );
      } else {
        const settings =
          await saveSignalEngineSettings({
            minLiquidityUsd:
              Math.round(
                value,
              ),
          });

        await reply(
          chatId,
          message.message_id,
          mainSettingsText(
            settings,
          ),
          mainKeyboard(),
        );
      }
    } else if (
      command === "/setage"
    ) {
      const value =
        oneNumber(
          argument,
        );

      if (
        value === null ||
        value < 1 ||
        value > 168
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: /setage 24 (allowed 1-168 hours).",
        );
      } else {
        const settings =
          await saveSignalEngineSettings({
            maxPairAgeHours:
              Math.round(
                value,
              ),
          });

        await reply(
          chatId,
          message.message_id,
          mainSettingsText(
            settings,
          ),
          mainKeyboard(),
        );
      }
    } else if (
      command ===
      "/resetsettings"
    ) {
      const settings =
        await resetSignalEngineSettings();

      await reply(
        chatId,
        message.message_id,
        mainSettingsText(
          settings,
        ),
        mainKeyboard(),
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
'@

[System.IO.File]::WriteAllText(
    $webhookPath,
    $webhook,
    $utf8
)

Write-Host "Updated: visual Telegram owner control panel" -ForegroundColor Green

# ============================================================
# 3. VALIDATE
# ============================================================

$telegramCheck =
    [System.IO.File]::ReadAllText(
        $telegramPath
    )

$webhookCheck =
    [System.IO.File]::ReadAllText(
        $webhookPath
    )

$checks = @(
    $telegramCheck.Contains("telegramAnswerCallbackQuery"),
    $telegramCheck.Contains('"callback_query"'),
    $webhookCheck.Contains("handleCallback"),
    $webhookCheck.Contains("ms:preset"),
    $webhookCheck.Contains("ms:score"),
    $webhookCheck.Contains("ms:liq"),
    $webhookCheck.Contains("ms:age"),
    $webhookCheck.Contains("mainKeyboard")
)

if ($checks -contains $false) {
    throw "Stage 19.1 validation failed."
}

Remove-Item `
  (Join-Path $root ".next") `
  -Recurse -Force `
  -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host " Stage 19.1 installed" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Telegram /settings now has buttons for:" -ForegroundColor Cyan
Write-Host " - Preset"
Write-Host " - Signal score"
Write-Host " - Liquidity"
Write-Host " - Pair age"
Write-Host " - Advanced filter overview"
Write-Host " - Refresh"
Write-Host " - Reset default"
Write-Host ""
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
Write-Host ""
