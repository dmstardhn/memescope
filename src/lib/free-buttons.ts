import "server-only";

import { neon } from "@neondatabase/serverless";
import { telegramConfig } from "@/lib/telegram";

type DbRow = Record<string, unknown>;
type FreeButton = {
  id: number;
  label: string;
  url: string;
  enabled: boolean;
  sortOrder: number;
};
type TelegramButton = {
  text: string;
  url?: string;
  callback_data?: string;
};
type TelegramKeyboard = {
  inline_keyboard: TelegramButton[][];
};
type TelegramUpdate = {
  message?: {
    message_id?: number;
    text?: string;
    chat?: { id?: number; type?: string };
    from?: { id?: number };
  };
  callback_query?: {
    id?: string;
    data?: string;
    from?: { id?: number };
    message?: {
      message_id?: number;
      chat?: { id?: number };
    };
  };
};

let schemaPromise: Promise<void> | null = null;

function sqlClient() {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}
function botToken() {
  return process.env.TELEGRAM_BOT_TOKEN?.trim() ?? "";
}
function ownerId() {
  return process.env.TELEGRAM_OWNER_ID?.trim() ?? "";
}
function isOwner(userId: number | undefined) {
  return Boolean(userId && ownerId() && String(userId) === ownerId());
}
function html(value: unknown) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
function defaultVipUrl() {
  return (
    process.env.TELEGRAM_VIP_JOIN_URL?.trim() ||
    "https://t.me/+lw2feXsKtQZkOTA9"
  );
}
function validUrl(raw: string) {
  const value = raw.trim();
  return (
    (/^https?:\/\/\S+$/i.test(value) || /^tg:\/\/\S+$/i.test(value)) &&
    value.length <= 2048
  );
}

async function telegramApi(method: string, payload: Record<string, unknown>) {
  const token = botToken();
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN is not configured.");

  const response = await fetch(
    `https://api.telegram.org/bot${token}/${method}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
      cache: "no-store",
    },
  );

  const body = (await response.json()) as {
    ok?: boolean;
    description?: string;
    result?: unknown;
  };

  if (!response.ok || !body.ok) {
    throw new Error(body.description ?? `Telegram ${method} failed.`);
  }

  return body.result;
}

async function sendMessage(
  chatId: number,
  text: string,
  replyMarkup?: TelegramKeyboard,
) {
  return telegramApi("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
    ...(replyMarkup ? { reply_markup: replyMarkup } : {}),
  });
}

async function editMessage(
  chatId: number,
  messageId: number,
  text: string,
  replyMarkup?: TelegramKeyboard,
) {
  try {
    return await telegramApi("editMessageText", {
      chat_id: chatId,
      message_id: messageId,
      text,
      parse_mode: "HTML",
      disable_web_page_preview: true,
      ...(replyMarkup ? { reply_markup: replyMarkup } : {}),
    });
  } catch {
    return sendMessage(chatId, text, replyMarkup);
  }
}

async function answerCallback(
  callbackId: string | undefined,
  text?: string,
  showAlert = false,
) {
  if (!callbackId) return;
  await telegramApi("answerCallbackQuery", {
    callback_query_id: callbackId,
    ...(text ? { text } : {}),
    show_alert: showAlert,
  }).catch(() => undefined);
}

export async function ensureFreeButtonsSchema() {
  if (schemaPromise) return schemaPromise;

  schemaPromise = (async () => {
    const sql = sqlClient();

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_free_buttons (
        id BIGSERIAL PRIMARY KEY,
        label TEXT NOT NULL,
        url TEXT NOT NULL,
        enabled BOOLEAN NOT NULL DEFAULT TRUE,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    await sql`
      CREATE INDEX IF NOT EXISTS memescope_free_buttons_order_idx
      ON memescope_free_buttons (sort_order ASC, id ASC)
    `;

    await sql`
      CREATE TABLE IF NOT EXISTS memescope_free_button_admin_state (
        user_id TEXT PRIMARY KEY,
        action TEXT NOT NULL,
        button_id BIGINT,
        pending_label TEXT,
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `;

    const rows = await sql`
      SELECT COUNT(*)::integer AS count
      FROM memescope_free_buttons
    `;

    const count = Number((rows[0] as DbRow | undefined)?.count ?? 0);
    if (count === 0) {
      await sql`
        SELECT 1
      `;
    }
  })().catch((error) => {
    schemaPromise = null;
    throw error;
  });

  return schemaPromise;
}

function normalizeButton(row: DbRow): FreeButton {
  return {
    id: Number(row.id),
    label: String(row.label ?? ""),
    url: String(row.url ?? ""),
    enabled: Boolean(row.enabled),
    sortOrder: Number(row.sort_order ?? 0),
  };
}

export async function getFreeButtons(enabledOnly = false) {
  await ensureFreeButtonsSchema();
  const sql = sqlClient();

  const rows = enabledOnly
    ? await sql`
        SELECT *
        FROM memescope_free_buttons
        WHERE enabled = TRUE
        ORDER BY sort_order ASC, id ASC
        LIMIT 8
      `
    : await sql`
        SELECT *
        FROM memescope_free_buttons
        ORDER BY sort_order ASC, id ASC
        LIMIT 8
      `;

  return rows.map((row: unknown) => normalizeButton(row as DbRow));
}

function rowsOfTwo(buttons: TelegramButton[]) {
  const rows: TelegramButton[][] = [];
  for (let index = 0; index < buttons.length; index += 2) {
    rows.push(buttons.slice(index, index + 2));
  }
  return rows;
}

export async function getFreeChannelPostKeyboard():
  Promise<TelegramKeyboard | undefined> {
  // FREE channel intentionally has no inline buttons.
  // VIP upsell/button has been retired.
  return undefined;
}

function listText(buttons: FreeButton[]) {
  const lines = [
    "<b>MEMESCOPE FREE BUTTON MANAGER</b>",
    "",
    "Buttons used on new FREE channel posts:",
    "",
  ];

  if (buttons.length === 0) {
    lines.push("<i>No buttons configured.</i>");
  } else {
    for (let index = 0; index < buttons.length; index += 1) {
      const button = buttons[index];
      lines.push(
        `${index + 1}. ${button.enabled ? "✅" : "❌"} <b>${html(
          button.label,
        )}</b>`,
      );
    }
  }

  lines.push(
    "",
    "Tap a button below to edit it.",
    "Maximum: <b>8 buttons</b>.",
    "Active buttons are placed 2 per row.",
  );
  return lines.join("\\n");
}

function listKeyboard(buttons: FreeButton[]): TelegramKeyboard {
  const rows: TelegramButton[][] = buttons.map((button) => [
    {
      text: `${button.enabled ? "✅" : "❌"} ${button.label}`.slice(0, 55),
      callback_data: `fb:item:${button.id}`,
    },
  ]);

  rows.push([
    { text: "➕ Add Button", callback_data: "fb:add" },
    { text: "👁 Preview", callback_data: "fb:preview" },
  ]);
  rows.push([{ text: "🔄 Refresh", callback_data: "fb:list" }]);

  return { inline_keyboard: rows };
}

function detailText(button: FreeButton) {
  return [
    "<b>FREE BUTTON</b>",
    "",
    `Text: <b>${html(button.label)}</b>`,
    `URL: <code>${html(button.url)}</code>`,
    `Status: <b>${button.enabled ? "ACTIVE" : "OFF"}</b>`,
    `Order: <b>${button.sortOrder}</b>`,
  ].join("\\n");
}

function detailKeyboard(button: FreeButton): TelegramKeyboard {
  return {
    inline_keyboard: [
      [
        { text: "✏️ Edit Text", callback_data: `fb:label:${button.id}` },
        { text: "🔗 Edit URL", callback_data: `fb:url:${button.id}` },
      ],
      [
        {
          text: button.enabled ? "❌ Turn OFF" : "✅ Turn ON",
          callback_data: `fb:toggle:${button.id}`,
        },
      ],
      [
        { text: "⬆️ Move Up", callback_data: `fb:up:${button.id}` },
        { text: "⬇️ Move Down", callback_data: `fb:down:${button.id}` },
      ],
      [{ text: "🗑 Delete", callback_data: `fb:delete:${button.id}` }],
      [{ text: "◀️ Back", callback_data: "fb:list" }],
    ],
  };
}

async function buttonById(id: number) {
  await ensureFreeButtonsSchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT *
    FROM memescope_free_buttons
    WHERE id = ${id}
    LIMIT 1
  `;
  return rows[0] ? normalizeButton(rows[0] as DbRow) : null;
}

async function showList(chatId: number, messageId?: number) {
  const buttons = await getFreeButtons(false);
  if (messageId) {
    await editMessage(chatId, messageId, listText(buttons), listKeyboard(buttons));
  } else {
    await sendMessage(chatId, listText(buttons), listKeyboard(buttons));
  }
}

async function showDetail(chatId: number, messageId: number, id: number) {
  const button = await buttonById(id);
  if (!button) {
    await showList(chatId, messageId);
    return;
  }
  await editMessage(chatId, messageId, detailText(button), detailKeyboard(button));
}

async function setState(
  userId: number,
  action: string,
  buttonId: number | null = null,
  pendingLabel: string | null = null,
) {
  await ensureFreeButtonsSchema();
  const sql = sqlClient();

  await sql`
    INSERT INTO memescope_free_button_admin_state (
      user_id, action, button_id, pending_label, updated_at
    ) VALUES (
      ${String(userId)},
      ${action},
      ${buttonId},
      ${pendingLabel},
      NOW()
    )
    ON CONFLICT (user_id)
    DO UPDATE SET
      action = EXCLUDED.action,
      button_id = EXCLUDED.button_id,
      pending_label = EXCLUDED.pending_label,
      updated_at = NOW()
  `;
}

async function clearState(userId: number) {
  const sql = sqlClient();
  await sql`
    DELETE FROM memescope_free_button_admin_state
    WHERE user_id = ${String(userId)}
  `;
}

async function getState(userId: number) {
  await ensureFreeButtonsSchema();
  const sql = sqlClient();
  const rows = await sql`
    SELECT *
    FROM memescope_free_button_admin_state
    WHERE user_id = ${String(userId)}
    LIMIT 1
  `;
  return rows[0] ? (rows[0] as DbRow) : null;
}

async function moveButton(id: number, direction: "up" | "down") {
  const buttons = await getFreeButtons(false);
  const index = buttons.findIndex((button) => button.id === id);
  if (index < 0) return;

  const targetIndex = direction === "up" ? index - 1 : index + 1;
  if (targetIndex < 0 || targetIndex >= buttons.length) return;

  const current = buttons[index];
  const target = buttons[targetIndex];
  const sql = sqlClient();

  await sql`
    UPDATE memescope_free_buttons
    SET sort_order = ${target.sortOrder}, updated_at = NOW()
    WHERE id = ${current.id}
  `;
  await sql`
    UPDATE memescope_free_buttons
    SET sort_order = ${current.sortOrder}, updated_at = NOW()
    WHERE id = ${target.id}
  `;
}

async function handlePendingText(
  chatId: number,
  userId: number,
  rawText: string,
) {
  const state = await getState(userId);
  if (!state) return false;

  const action = String(state.action ?? "");
  const buttonId = Number(state.button_id ?? 0);

  if (rawText.startsWith("/")) {
    await clearState(userId);
    return false;
  }

  const sql = sqlClient();

  if (action === "add_label") {
    const label = rawText.trim();
    if (!label || label.length > 64) {
      await sendMessage(chatId, "Button text must be 1-64 characters. Send it again.");
      return true;
    }

    await setState(userId, "add_url", null, label);
    await sendMessage(
      chatId,
      [
        "<b>New button text saved.</b>",
        "",
        `Text: <b>${html(label)}</b>`,
        "",
        "Now send its URL.",
        "Example: <code>https://t.me/+xxxx</code>",
      ].join("\\n"),
    );
    return true;
  }

  if (action === "add_url") {
    const url = rawText.trim();
    if (!validUrl(url)) {
      await sendMessage(chatId, "Invalid URL. Send an https://, http://, or tg:// URL.");
      return true;
    }

    const label = String(state.pending_label ?? "Open");
    const countRows = await sql`
      SELECT COUNT(*)::integer AS count
      FROM memescope_free_buttons
    `;

    if (Number((countRows[0] as DbRow).count ?? 0) >= 8) {
      await clearState(userId);
      await sendMessage(chatId, "Maximum 8 FREE channel buttons reached.");
      return true;
    }

    const orderRows = await sql`
      SELECT COALESCE(MAX(sort_order), 0)::integer AS max_order
      FROM memescope_free_buttons
    `;
    const nextOrder = Number((orderRows[0] as DbRow).max_order ?? 0) + 1;

    await sql`
      INSERT INTO memescope_free_buttons (
        label, url, enabled, sort_order
      ) VALUES (
        ${label}, ${url}, TRUE, ${nextOrder}
      )
    `;

    await clearState(userId);
    await sendMessage(chatId, "✅ Button added.");
    await showList(chatId);
    return true;
  }

  if (action === "edit_label" && buttonId > 0) {
    const label = rawText.trim();
    if (!label || label.length > 64) {
      await sendMessage(chatId, "Button text must be 1-64 characters. Send it again.");
      return true;
    }

    await sql`
      UPDATE memescope_free_buttons
      SET label = ${label}, updated_at = NOW()
      WHERE id = ${buttonId}
    `;
    await clearState(userId);
    await sendMessage(chatId, "✅ Button text updated.");
    await showList(chatId);
    return true;
  }

  if (action === "edit_url" && buttonId > 0) {
    const url = rawText.trim();
    if (!validUrl(url)) {
      await sendMessage(chatId, "Invalid URL. Send an https://, http://, or tg:// URL.");
      return true;
    }

    await sql`
      UPDATE memescope_free_buttons
      SET url = ${url}, updated_at = NOW()
      WHERE id = ${buttonId}
    `;
    await clearState(userId);
    await sendMessage(chatId, "✅ Button URL updated.");
    await showList(chatId);
    return true;
  }

  await clearState(userId);
  return false;
}

async function handleCallback(
  update: NonNullable<TelegramUpdate["callback_query"]>,
) {
  const data = update.data ?? "";
  if (!data.startsWith("fb:")) return false;

  const userId = update.from?.id;
  const chatId = update.message?.chat?.id;
  const messageId = update.message?.message_id;

  if (!isOwner(userId)) {
    await answerCallback(update.id, "Owner only.", true);
    return true;
  }

  if (!chatId || !messageId) {
    await answerCallback(update.id, "Missing Telegram message.", true);
    return true;
  }

  const [, action, rawId] = data.split(":");
  const id = Number(rawId ?? 0);

  if (action === "list") {
    await answerCallback(update.id);
    await showList(chatId, messageId);
    return true;
  }

  if (action === "preview") {
    await answerCallback(update.id);
    const keyboard = await getFreeChannelPostKeyboard();
    await sendMessage(
      chatId,
      [
        "<b>FREE CHANNEL BUTTON PREVIEW</b>",
        "",
        "This is how active buttons will appear on new FREE posts.",
      ].join("\\n"),
      keyboard,
    );
    return true;
  }

  if (action === "add") {
    const buttons = await getFreeButtons(false);
    if (buttons.length >= 8) {
      await answerCallback(update.id, "Maximum 8 buttons.", true);
      return true;
    }
    if (!userId) return true;

    await setState(userId, "add_label");
    await answerCallback(update.id, "Send button text.");
    await sendMessage(
      chatId,
      [
        "<b>Add FREE Button</b>",
        "",
        "Send the button text.",
        "Example: <code>🔒 GET VIP ACCESS</code>",
      ].join("\\n"),
    );
    return true;
  }

  if (action === "item" && id > 0) {
    await answerCallback(update.id);
    await showDetail(chatId, messageId, id);
    return true;
  }

  const button = id > 0 ? await buttonById(id) : null;
  if (!button) {
    await answerCallback(update.id, "Button not found.", true);
    await showList(chatId, messageId);
    return true;
  }

  if (action === "toggle") {
    const sql = sqlClient();
    await sql`
      UPDATE memescope_free_buttons
      SET enabled = NOT enabled, updated_at = NOW()
      WHERE id = ${id}
    `;
    await answerCallback(update.id, "Status updated.");
    await showDetail(chatId, messageId, id);
    return true;
  }

  if (action === "label") {
    if (!userId) return true;
    await setState(userId, "edit_label", id);
    await answerCallback(update.id, "Send new text.");
    await sendMessage(
      chatId,
      [
        "<b>Edit Button Text</b>",
        "",
        `Current: <b>${html(button.label)}</b>`,
        "",
        "Send the new button text.",
      ].join("\\n"),
    );
    return true;
  }

  if (action === "url") {
    if (!userId) return true;
    await setState(userId, "edit_url", id);
    await answerCallback(update.id, "Send new URL.");
    await sendMessage(
      chatId,
      [
        "<b>Edit Button URL</b>",
        "",
        `Current: <code>${html(button.url)}</code>`,
        "",
        "Send the new URL.",
      ].join("\\n"),
    );
    return true;
  }

  if (action === "up" || action === "down") {
    await moveButton(id, action);
    await answerCallback(update.id, "Order updated.");
    await showList(chatId, messageId);
    return true;
  }

  if (action === "delete") {
    await answerCallback(update.id);
    await editMessage(
      chatId,
      messageId,
      [
        "<b>Delete FREE button?</b>",
        "",
        `<b>${html(button.label)}</b>`,
      ].join("\\n"),
      {
        inline_keyboard: [
          [{ text: "🗑 Yes, Delete", callback_data: `fb:deleteyes:${id}` }],
          [{ text: "◀️ Cancel", callback_data: `fb:item:${id}` }],
        ],
      },
    );
    return true;
  }

  if (action === "deleteyes") {
    const sql = sqlClient();
    await sql`
      DELETE FROM memescope_free_buttons
      WHERE id = ${id}
    `;
    await answerCallback(update.id, "Button deleted.");
    await showList(chatId, messageId);
    return true;
  }

  await answerCallback(update.id, "Unknown button action.", true);
  return true;
}

export async function tryHandleFreeButtonsAdminRequest(request: Request) {
  const config = telegramConfig();
  const supplied = request.headers.get("x-telegram-bot-api-secret-token");

  if (!config.webhookSecret || supplied !== config.webhookSecret) {
    return { handled: false };
  }

  let update: TelegramUpdate;
  try {
    update = (await request.json()) as TelegramUpdate;
  } catch {
    return { handled: false };
  }

  if (update.callback_query) {
    const handled = await handleCallback(update.callback_query);
    return { handled };
  }

  const message = update.message;
  const chatId = message?.chat?.id;
  const userId = message?.from?.id;
  const rawText = message?.text?.trim() ?? "";

  if (!chatId || !userId || !rawText || !isOwner(userId)) {
    return { handled: false };
  }

  const command =
    rawText.split(/\s+/)[0]?.toLowerCase().split("@")[0] ?? "";

  if (command === "/freebuttons" || command === "/buttons") {
    await clearState(userId).catch(() => undefined);
    await showList(chatId);
    return { handled: true };
  }

  const handled = await handlePendingText(chatId, userId, rawText);
  return { handled };
}
