import "server-only";
import {
  getV4Settings,
  resetV4History,
  setManualApproval,
  v4Status,
} from "./db";

type TelegramUpdate = {
  callback_query?: {
    id: string;
    data?: string;
    from?: { id?: number };
    message?: { chat?: { id?: number }; message_id?: number };
  };
  message?: {
    text?: string;
    from?: { id?: number };
    chat?: { id?: number };
  };
};

function token() {
  const value = process.env.TELEGRAM_BOT_TOKEN?.trim();
  if (!value) throw new Error("TELEGRAM_BOT_TOKEN missing.");
  return value;
}

function ownerId() {
  const value = Number(process.env.TELEGRAM_OWNER_ID);
  return Number.isFinite(value) ? value : null;
}

async function api(method: string, body: Record<string, unknown>) {
  const response = await fetch(`https://api.telegram.org/bot${token()}/${method}`, {
    method: "POST",
    headers: {"content-type":"application/json"},
    body: JSON.stringify(body),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Telegram ${method} failed: ${response.status}`);
  return response.json();
}

function menuKeyboard(manual: boolean) {
  return {
    inline_keyboard: [
      [
        { text: "Status", callback_data: "ch4:status" },
        { text: manual ? "Manual Approval: ON" : "Manual Approval: OFF", callback_data: "ch4:toggle_manual" },
      ],
      [
        { text: "Reset Content History", callback_data: "ch4:reset" },
      ],
    ],
  };
}

async function sendMenu(chatId: number) {
  const state = await v4Status();
  const s = state.settings;
  const text =
`MemeScope - Content HQ V4

Mode: ${s.manualApproval ? "MANUAL APPROVAL" : "AUTO APPROVE"}
Queued: ${state.counts.queued}
Approved: ${state.counts.approved}
Published: ${state.counts.published}
Failed: ${state.counts.failed}

History since: ${new Date(s.historyResetAt).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}

Content mix:
Text observation 25%
Chart setup 35%
Token update 20%
Token Watch max 5%
Before/Call Journey 10%
Daily/Weekly recap 5%

Explicit MemeScope branding target: 20%`;

  await api("sendMessage", {
    chat_id: chatId,
    text,
    reply_markup: menuKeyboard(s.manualApproval),
  });
}

export async function tryHandleContentHqAdminRequest(request: Request) {
  const secret = process.env.TELEGRAM_WEBHOOK_SECRET?.trim();
  if (secret) {
    const received = request.headers.get("x-telegram-bot-api-secret-token");
    if (received !== secret) return { handled: false };
  }

  let update: TelegramUpdate;
  try {
    update = await request.json() as TelegramUpdate;
  } catch {
    return { handled: false };
  }

  const messageText = update.message?.text?.trim();
  const callback = update.callback_query?.data?.trim();

  if (messageText !== "/contenthq" && !callback?.startsWith("ch4:")) {
    return { handled: false };
  }

  const userId = update.message?.from?.id ?? update.callback_query?.from?.id ?? null;
  const owner = ownerId();

  if (!owner || userId !== owner) {
    if (update.callback_query?.id) {
      await api("answerCallbackQuery", {
        callback_query_id: update.callback_query.id,
        text: "Owner only.",
        show_alert: true,
      }).catch(() => undefined);
    }
    return { handled: true };
  }

  const chatId = update.message?.chat?.id ?? update.callback_query?.message?.chat?.id;
  if (!chatId) return { handled: true };

  if (messageText === "/contenthq") {
    await sendMenu(chatId);
    return { handled: true };
  }

  if (callback === "ch4:status") {
    await api("answerCallbackQuery", { callback_query_id: update.callback_query!.id });
    await sendMenu(chatId);
    return { handled: true };
  }

  if (callback === "ch4:toggle_manual") {
    const current = await getV4Settings();
    await setManualApproval(!current.manualApproval);
    await api("answerCallbackQuery", {
      callback_query_id: update.callback_query!.id,
      text: `Manual Approval ${!current.manualApproval ? "ON" : "OFF"}`,
    });
    await sendMenu(chatId);
    return { handled: true };
  }

  if (callback === "ch4:reset") {
    await api("answerCallbackQuery", { callback_query_id: update.callback_query!.id });
    await api("sendMessage", {
      chat_id: chatId,
      text:
`RESET CONTENT HISTORY?

This resets Content HQ history, rotation counters, cooldown context and recap statistics.

It does NOT delete:
- MemeScope calls
- signal history
- market data
- Telegram configuration
- X configuration
- caption/visual code

Old Content HQ records remain archived for debugging.`,
      reply_markup: {
        inline_keyboard: [[
          { text: "CONFIRM RESET", callback_data: "ch4:reset_confirm" },
          { text: "CANCEL", callback_data: "ch4:cancel" },
        ]],
      },
    });
    return { handled: true };
  }

  if (callback === "ch4:reset_confirm") {
    const resetAt = await resetV4History();
    await api("answerCallbackQuery", {
      callback_query_id: update.callback_query!.id,
      text: "Content history reset.",
      show_alert: true,
    });
    await api("sendMessage", {
      chat_id: chatId,
      text: `Content history reset successfully.\n\nNew production history starts:\n${new Date(resetAt).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}`,
    });
    return { handled: true };
  }

  if (callback === "ch4:cancel") {
    await api("answerCallbackQuery", {
      callback_query_id: update.callback_query!.id,
      text: "Cancelled.",
    });
    return { handled: true };
  }

  return { handled: true };
}