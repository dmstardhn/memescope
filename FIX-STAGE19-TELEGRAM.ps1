$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " MemeScope Stage 19 FIX - Telegram Owner Control" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

$telegramPath = Join-Path $root "src/lib/telegram.ts"
$webhookPath = Join-Path $root "src/app/api/telegram/webhook/route.ts"
$settingsLib = Join-Path $root "src/lib/signal-engine-settings.ts"

foreach ($path in @($telegramPath, $webhookPath, $settingsLib)) {
    if (!(Test-Path -LiteralPath $path)) {
        throw "Required file not found: $path"
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-Stage19-BotFix-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item -LiteralPath $telegramPath -Destination (Join-Path $backup "telegram.ts.bak") -Force
Copy-Item -LiteralPath $webhookPath -Destination (Join-Path $backup "webhook-route.ts.bak") -Force

Write-Host "Backup: $backup" -ForegroundColor DarkGray

# ============================================================
# 1. OWNER-ONLY WEBHOOK + SETTINGS COMMANDS
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
    from?: {
      id?: number;
      username?: string;
      first_name?: string;
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

function settingsText(
  settings: SignalSettings,
) {
  const preset =
    signalPresetName(
      settings,
    );

  return [
    "<b>MEMESCOPE OWNER CONTROL</b>",
    "",
    `Preset: <b>${escapeTelegramHtml(
      preset.toUpperCase(),
    )}</b>`,
    "",
    "<b>Owner-adjustable filters</b>",
    `Minimum score: <b>${settings.minSignalScore}</b>`,
    `Minimum liquidity: <b>${compactUsd(
      settings.minLiquidityUsd,
    )}</b>`,
    `Maximum pair age: <b>${settings.maxPairAgeHours}h</b>`,
    "",
    "<b>Fixed Stage 16 HQ gates</b>",
    "5m volume >= $10K",
    "5m transactions >= 40",
    "Buy pressure 60% - 88%",
    "Volume spike 1.30x - 3.50x",
    "5m momentum +2% - +15%",
    "1h momentum -5% - +120%",
    "Liquidity / valuation >= 8%",
    "Confirmation: 2 consecutive scans",
    "Potential TP: dynamic analysis-based",
    "",
    "<b>Commands</b>",
    "/preset strict",
    "/preset balanced",
    "/preset broad",
    "/setscore 85",
    "/setliq 75000",
    "/setage 18",
    "/resetsettings",
    "",
    "<i>Changes apply to new signal detection. Existing records keep their original entry snapshot and target.</i>",
  ].join("\n");
}

function helpText() {
  return [
    "<b>MemeScope Owner Bot</b>",
    "",
    "<b>Engine control</b>",
    "/settings - current live signal settings",
    "/preset &lt;strict|balanced|broad&gt;",
    "/setscore &lt;60-95&gt;",
    "/setliq &lt;10000-1000000&gt;",
    "/setage &lt;1-168 hours&gt;",
    "/resetsettings - restore defaults",
    "",
    "<b>Monitoring</b>",
    "/signals - active HQ signals",
    "/history - recent signal history",
    "/stats - 30-day signal statistics",
    "/token &lt;CA&gt; - open token",
    "/risk &lt;CA&gt; - open risk analysis",
    "/channel - signal channel",
    "/whoami - show your Telegram user ID",
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

async function reply(
  chatId: number,
  messageId: number | undefined,
  text: string,
) {
  return telegramSendMessage(
    chatId,
    text,
    {
      replyToMessageId:
        messageId,
    },
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
        "",
        "Use this value as TELEGRAM_OWNER_ID in Vercel Production.",
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  const ownerId =
    process.env
      .TELEGRAM_OWNER_ID
      ?.trim() ??
    "";

  if (!ownerId) {
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
        "",
        "Set this as TELEGRAM_OWNER_ID in Vercel Production, redeploy, then bootstrap Telegram.",
      ].join("\n"),
    );

    return NextResponse.json({
      ok: true,
    });
  }

  if (
    !userId ||
    String(userId) !==
      ownerId
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
        settingsText(
          settings,
        ),
      );
    } else if (
      command === "/preset"
    ) {
      const preset =
        argument.toLowerCase();

      if (
        preset !== "strict" &&
        preset !== "balanced" &&
        preset !== "broad"
      ) {
        await reply(
          chatId,
          message.message_id,
          "Usage: <code>/preset strict</code>, <code>/preset balanced</code>, or <code>/preset broad</code>.",
        );
      } else {
        const settings =
          await applySignalPreset(
            preset as SignalPresetName,
          );

        await reply(
          chatId,
          message.message_id,
          [
            `<b>Preset updated: ${escapeTelegramHtml(
              preset.toUpperCase(),
            )}</b>`,
            "",
            settingsText(
              settings,
            ),
          ].join("\n"),
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
          "Usage: <code>/setscore 85</code> (allowed 60-95).",
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
          settingsText(
            settings,
          ),
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
          "Usage: <code>/setliq 75000</code> (allowed 10000-1000000 USD).",
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
          settingsText(
            settings,
          ),
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
          "Usage: <code>/setage 24</code> (allowed 1-168 hours).",
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
          settingsText(
            settings,
          ),
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
        [
          "<b>Default settings restored.</b>",
          "",
          settingsText(
            settings,
          ),
        ].join("\n"),
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
          `Usage: <code>${command} &lt;Solana CA&gt;</code>`,
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
Write-Host "Updated: Telegram owner-only webhook" -ForegroundColor Green

# ============================================================
# 2. PATCH TELEGRAM COMMAND MENU
# ============================================================

$telegram =
  [System.IO.File]::ReadAllText(
    $telegramPath
  )

$start =
  $telegram.IndexOf(
    "export async function telegramSetCommands()"
  )

$end =
  $telegram.IndexOf(
    "export async function telegramSetWebhook("
  )

if (
  $start -lt 0 -or
  $end -le $start
) {
    throw "telegramSetCommands markers not found."
}

$commands = @'
export async function telegramSetCommands() {
  return telegramRequest<boolean>(
    "setMyCommands",
    {
      commands: [
        {
          command: "settings",
          description:
            "Owner signal settings",
        },
        {
          command: "preset",
          description:
            "Apply signal preset",
        },
        {
          command: "setscore",
          description:
            "Set minimum signal score",
        },
        {
          command: "setliq",
          description:
            "Set minimum liquidity",
        },
        {
          command: "setage",
          description:
            "Set maximum pair age",
        },
        {
          command: "signals",
          description:
            "Active HQ signals",
        },
        {
          command: "history",
          description:
            "Recent signal history",
        },
        {
          command: "stats",
          description:
            "30-day signal statistics",
        },
        {
          command: "token",
          description:
            "Open token by contract",
        },
        {
          command: "risk",
          description:
            "Open risk analysis",
        },
        {
          command: "channel",
          description:
            "Open signal channel",
        },
        {
          command: "whoami",
          description:
            "Show Telegram user ID",
        },
        {
          command: "help",
          description:
            "Show bot commands",
        },
      ],
    },
  );
}

'@

$telegram =
  $telegram.Substring(
    0,
    $start
  ) +
  $commands +
  $telegram.Substring(
    $end
  )

[System.IO.File]::WriteAllText(
    $telegramPath,
    $telegram,
    $utf8
)

Write-Host "Updated: Telegram command menu" -ForegroundColor Green

Remove-Item `
  (Join-Path $root ".next") `
  -Recurse -Force `
  -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Stage 19 Telegram bot fix installed." -ForegroundColor Green
Write-Host "Next: npm run typecheck" -ForegroundColor Cyan
