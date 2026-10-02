import {
  getXAutoPostEnabled,
  setXAutoPostEnabled,
  toggleXAutoPostEnabled,
} from "@/lib/x-auto";

function ownerId() {
  return (
    process.env
      .TELEGRAM_OWNER_ID
      ?.trim() ??
    ""
  );
}

function assertOwner(
  userId:
    | string
    | number
    | null
    | undefined,
) {
  const configured =
    ownerId();

  if (
    !configured ||
    String(
      userId ?? "",
    ) !== configured
  ) {
    throw new Error(
      "Owner only.",
    );
  }
}

function telegramToken() {
  const token =
    process.env
      .TELEGRAM_BOT_TOKEN
      ?.trim();

  if (!token) {
    throw new Error(
      "TELEGRAM_BOT_TOKEN is not configured.",
    );
  }

  return token;
}

function keyboard(
  enabled: boolean,
) {
  return {
    inline_keyboard: [
      [
        {
          text:
            enabled
              ? "TURN AUTO POST OFF"
              : "TURN AUTO POST ON",
          callback_data:
            "xauto:toggle",
        },
      ],
      [
        {
          text:
            "Force ON",
          callback_data:
            "xauto:on",
        },
        {
          text:
            "Force OFF",
          callback_data:
            "xauto:off",
        },
      ],
      [
        {
          text:
            "Refresh",
          callback_data:
            "xauto:refresh",
        },
      ],
    ],
  };
}

function menuText(
  enabled: boolean,
) {
  return [
    "MemeScope - X Auto Post",
    "",
    `Status: ${
      enabled
        ? "ON"
        : "OFF"
    }`,
    "",
    "09:00 WIB - Text Only",
    "14:00 WIB - Best Unposted Result",
    "20:00 WIB - Last 72 Hours",
    "",
    enabled
      ? "Scheduled X publishing is active."
      : "Scheduled X publishing is paused.",
    "",
    enabled
      ? "The next scheduled slot can publish automatically."
      : "Scheduler requests will be skipped before calling the X API.",
  ].join(
    "\n",
  );
}

async function telegramApi(
  method: string,
  payload: unknown,
) {
  const response =
    await fetch(
      `https://api.telegram.org/bot${telegramToken()}/${method}`,
      {
        method:
          "POST",
        headers: {
          "content-type":
            "application/json",
        },
        body:
          JSON.stringify(
            payload,
          ),
      },
    );

  const body =
    (await response.json()) as {
      ok?: boolean;
      description?: string;
    };

  return {
    response,
    body,
  };
}

async function sendMenu(
  chatId:
    | string
    | number,
  enabled:
    boolean,
) {
  const result =
    await telegramApi(
      "sendMessage",
      {
        chat_id:
          chatId,
        text:
          menuText(
            enabled,
          ),
        reply_markup:
          keyboard(
            enabled,
          ),
      },
    );

  if (
    !result.body.ok
  ) {
    throw new Error(
      result.body
        .description ??
        "Telegram X Auto Post menu failed.",
    );
  }
}

async function editMenu(
  chatId:
    | string
    | number,
  messageId:
    number,
  enabled:
    boolean,
) {
  const result =
    await telegramApi(
      "editMessageText",
      {
        chat_id:
          chatId,
        message_id:
          messageId,
        text:
          menuText(
            enabled,
          ),
        reply_markup:
          keyboard(
            enabled,
          ),
      },
    );

  if (
    !result.body.ok &&
    !String(
      result.body
        .description ??
        "",
    ).includes(
      "message is not modified",
    )
  ) {
    throw new Error(
      result.body
        .description ??
        "Telegram X Auto Post menu update failed.",
    );
  }
}

export async function sendXAutoPostAdminMenu(
  chatId:
    | string
    | number,
  userId:
    | string
    | number
    | null
    | undefined,
) {
  assertOwner(
    userId,
  );

  const enabled =
    await getXAutoPostEnabled();

  await sendMenu(
    chatId,
    enabled,
  );
}

export async function handleXAutoPostAdminCallback(
  args: {
    action: string;
    chatId:
      | string
      | number;
    messageId:
      number;
    userId:
      | string
      | number
      | null
      | undefined;
  },
) {
  assertOwner(
    args.userId,
  );

  let enabled:
    boolean;

  if (
    args.action ===
    "toggle"
  ) {
    enabled =
      await toggleXAutoPostEnabled();
  }
  else if (
    args.action ===
    "on"
  ) {
    enabled =
      await setXAutoPostEnabled(
        true,
      );
  }
  else if (
    args.action ===
    "off"
  ) {
    enabled =
      await setXAutoPostEnabled(
        false,
      );
  }
  else if (
    args.action ===
    "refresh"
  ) {
    enabled =
      await getXAutoPostEnabled();
  }
  else {
    throw new Error(
      "Unknown X Auto Post action.",
    );
  }

  await editMenu(
    args.chatId,
    args.messageId,
    enabled,
  );

  return {
    enabled,
    message:
      args.action ===
      "refresh"
        ? `X Auto Post: ${
            enabled
              ? "ON"
              : "OFF"
          }`
        : `X Auto Post turned ${
            enabled
              ? "ON"
              : "OFF"
          }.`,
  };
}