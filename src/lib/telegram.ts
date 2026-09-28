import "server-only";

type TelegramApiResponse<T> = {
  ok: boolean;
  result?: T;
  description?: string;
};

export type TelegramMessageResult = {
  message_id: number;
  chat?: {
    id?: number;
    username?: string;
  };
};

export type TelegramBotIdentity = {
  id: number;
  is_bot: boolean;
  first_name: string;
  username?: string;
};

export function telegramConfig() {
  return {
    botToken:
      process.env.TELEGRAM_BOT_TOKEN?.trim() ??
      "",
    channelId:
      process.env.TELEGRAM_CHANNEL_ID?.trim() ??
      "",
    webhookSecret:
      process.env.TELEGRAM_WEBHOOK_SECRET?.trim() ??
      "",
    channelUrl:
      process.env.TELEGRAM_CHANNEL_URL?.trim() ??
      "",
  };
}

export function telegramConfigured() {
  const config = telegramConfig();

  return Boolean(
    config.botToken &&
      config.channelId,
  );
}

export function telegramSiteUrl() {
  const explicit =
    process.env.NEXT_PUBLIC_SITE_URL?.trim();

  if (explicit) {
    return explicit.replace(/\/+$/, "");
  }

  const production =
    process.env
      .VERCEL_PROJECT_PRODUCTION_URL
      ?.trim();

  if (production) {
    return `https://${production}`.replace(
      /\/+$/,
      "",
    );
  }

  const deployment =
    process.env.VERCEL_URL?.trim();

  if (deployment) {
    return `https://${deployment}`.replace(
      /\/+$/,
      "",
    );
  }

  return "https://memescopes.vercel.app";
}

export function escapeTelegramHtml(
  value: unknown,
) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

async function telegramRequest<T>(
  method: string,
  payload: Record<string, unknown>,
): Promise<T> {
  const { botToken } =
    telegramConfig();

  if (!botToken) {
    throw new Error(
      "TELEGRAM_BOT_TOKEN is not configured.",
    );
  }

  const response = await fetch(
    `https://api.telegram.org/bot${botToken}/${method}`,
    {
      method: "POST",
      headers: {
        "content-type":
          "application/json",
      },
      body: JSON.stringify(payload),
      cache: "no-store",
      signal: AbortSignal.timeout(
        8_000,
      ),
    },
  );

  const body =
    (await response.json()) as
      TelegramApiResponse<T>;

  if (
    !response.ok ||
    !body.ok ||
    body.result === undefined
  ) {
    throw new Error(
      body.description ??
        `Telegram ${method} failed.`,
    );
  }

  return body.result;
}

export async function telegramGetMe() {
  return telegramRequest<TelegramBotIdentity>(
    "getMe",
    {},
  );
}

export async function telegramSendMessage(
  chatId: string | number,
  text: string,
  options?: {
    replyMarkup?: Record<
      string,
      unknown
    >;
    replyToMessageId?: number;
    disableWebPagePreview?: boolean;
  },
) {
  return telegramRequest<TelegramMessageResult>(
    "sendMessage",
    {
      chat_id: chatId,
      text,
      parse_mode: "HTML",
      link_preview_options: {
        is_disabled:
          options
            ?.disableWebPagePreview ??
          true,
      },
      ...(options?.replyMarkup
        ? {
            reply_markup:
              options.replyMarkup,
          }
        : {}),
      ...(options?.replyToMessageId
        ? {
            reply_parameters: {
              message_id:
                options.replyToMessageId,
            },
          }
        : {}),
    },
  );
}

export async function telegramEditMessage(
  chatId: string | number,
  messageId: number,
  text: string,
  replyMarkup?: Record<
    string,
    unknown
  >,
) {
  try {
    return await telegramRequest<TelegramMessageResult>(
      "editMessageText",
      {
        chat_id: chatId,
        message_id: messageId,
        text,
        parse_mode: "HTML",
        link_preview_options: {
          is_disabled: true,
        },
        ...(replyMarkup
          ? {
              reply_markup:
                replyMarkup,
            }
          : {}),
      },
    );
  } catch (error) {
    if (
      error instanceof Error &&
      error.message
        .toLowerCase()
        .includes(
          "message is not modified",
        )
    ) {
      return null;
    }

    throw error;
  }
}

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
export async function telegramSetWebhook(
  origin: string,
) {
  const { webhookSecret } =
    telegramConfig();

  if (!webhookSecret) {
    throw new Error(
      "TELEGRAM_WEBHOOK_SECRET is not configured.",
    );
  }

  return telegramRequest<boolean>(
    "setWebhook",
    {
      url: `${origin.replace(
        /\/+$/,
        "",
      )}/api/telegram/webhook`,
      secret_token:
        webhookSecret,
      allowed_updates: [
        "message",
        "callback_query",
      ],
      drop_pending_updates: true,
    },
  );
}
