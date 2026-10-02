import "server-only";

import {
  CONTENT_TIERS,
  clearPendingBackgroundTier,
  ensureContentBackgroundSchema,
  listContentBackgrounds,
  pendingBackgroundTier,
  resetContentBackground,
  setContentBackground,
  setPendingBackgroundTier,
  tierTitle,
  type ContentTier,
} from "./backgrounds";
import { renderResultCard } from "./content";

type TelegramUpdate = {
  callback_query?: {
    id?: string;
    data?: string;
    from?: { id?: number };
    message?: { chat?: { id?: number }; message_id?: number };
  };
  message?: {
    text?: string;
    from?: { id?: number };
    chat?: { id?: number };
    photo?: Array<{
      file_id?: string;
      file_unique_id?: string;
      width?: number;
      height?: number;
      file_size?: number;
    }>;
    document?: {
      file_id?: string;
      file_unique_id?: string;
      mime_type?: string;
      file_name?: string;
    };
  };
};

function botToken() {
  const value = process.env.TELEGRAM_BOT_TOKEN?.trim();
  if (!value) throw new Error("TELEGRAM_BOT_TOKEN is not configured.");
  return value;
}

function ownerId() {
  const value = Number(process.env.TELEGRAM_OWNER_ID);
  return Number.isFinite(value) ? value : null;
}

async function api(method: string, body: Record<string, unknown>) {
  const response = await fetch(
    `https://api.telegram.org/bot${botToken()}/${method}`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      cache: "no-store",
    },
  );
  const payload = (await response.json()) as {
    ok?: boolean;
    result?: unknown;
    description?: string;
  };
  if (!response.ok || !payload.ok) {
    throw new Error(payload.description ?? `Telegram ${method} failed.`);
  }
  return payload.result;
}

async function sendPhoto(chatId: number, buffer: Buffer, caption: string) {
  const form = new FormData();
  form.append("chat_id", String(chatId));
  form.append("parse_mode", "HTML");
  form.append("caption", caption);
  form.append(
    "photo",
    new Blob([buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength) as ArrayBuffer], { type: "image/webp" }),
    "content-background-preview.webp",
  );
  const response = await fetch(
    `https://api.telegram.org/bot${botToken()}/sendPhoto`,
    { method: "POST", body: form, cache: "no-store" },
  );
  const payload = (await response.json()) as {
    ok?: boolean;
    description?: string;
  };
  if (!response.ok || !payload.ok) {
    throw new Error(payload.description ?? "Telegram preview send failed.");
  }
}

function validTier(value: string | undefined): value is ContentTier {
  return CONTENT_TIERS.includes(value as ContentTier);
}

function sampleMultiple(tier: ContentTier) {
  const values: Record<ContentTier, number> = {
    momentum: 2.4,
    breakout: 3.8,
    surge: 7.2,
    apex: 14.5,
    legend: 28.2,
    titan: 64,
    century: 128,
  };
  return values[tier];
}

async function sendMenu(chatId: number) {
  const rows = await listContentBackgrounds();
  const status = new Map(rows.map((row: { tier: ContentTier; configured: boolean }) => [row.tier, row.configured]));
  const button = (tier: ContentTier) => ({
    text: `${status.get(tier) ? "✅" : "◻️"} ${tierTitle(tier)}`,
    callback_data: `cbg:tier:${tier}`,
  });

  await api("sendMessage", {
    chat_id: chatId,
    text: [
      "<b>MEMESCOPE CONTENT BACKGROUNDS</b>",
      "",
      "Choose a result tier.",
      "",
      "✅ custom background",
      "◻️ default background",
    ].join("\n"),
    parse_mode: "HTML",
    reply_markup: {
      inline_keyboard: [
        [button("momentum"), button("breakout")],
        [button("surge"), button("apex")],
        [button("legend"), button("titan")],
        [button("century")],
        [{ text: "Refresh", callback_data: "cbg:menu" }],
      ],
    },
  });
}

async function sendTierMenu(chatId: number, owner: number, tier: ContentTier) {
  await setPendingBackgroundTier(owner, chatId, tier);
  await api("sendMessage", {
    chat_id: chatId,
    text: [
      `<b>${tierTitle(tier)} BACKGROUND</b>`,
      "",
      "Send a JPG, PNG or WEBP image now to replace this background.",
      "Recommended: 1600×900 / 16:9.",
    ].join("\n"),
    parse_mode: "HTML",
    reply_markup: {
      inline_keyboard: [
        [
          { text: "Preview", callback_data: `cbg:preview:${tier}` },
          { text: "Reset Default", callback_data: `cbg:reset:${tier}` },
        ],
        [{ text: "Back", callback_data: "cbg:menu" }],
      ],
    },
  });
}

async function sendPreview(chatId: number, tier: ContentTier) {
  const multiple = sampleMultiple(tier);
  const result = await renderResultCard({
    signalRecordId: "preview",
    publicId: "MS-1001-437",
    symbol: "AGENCY",
    calledAt: new Date(Date.now() - 6 * 60 * 60 * 1000).toISOString(),
    callMarketCapUsd: 43_400,
    peakMarketCapUsd: 43_400 * multiple,
    peakMultiple: multiple,
    opportunityId: null,
  });
  await sendPhoto(
    chatId,
    result.buffer,
    `<b>${tierTitle(tier)} CONTENT BACKGROUND PREVIEW</b>`,
  );
}

export async function tryHandleContentV5AdminRequest(request: Request) {
  const secret = process.env.TELEGRAM_WEBHOOK_SECRET?.trim();
  if (secret) {
    const received = request.headers.get("x-telegram-bot-api-secret-token");
    if (received !== secret) return { handled: false };
  }

  let update: TelegramUpdate;
  try {
    update = (await request.json()) as TelegramUpdate;
  } catch {
    return { handled: false };
  }

  const message = update.message;
  const callback = update.callback_query;
  const userId = message?.from?.id ?? callback?.from?.id ?? null;
  const owner = ownerId();
  const command = message?.text?.trim().toLowerCase().split("@")[0] ?? "";
  const callbackData = callback?.data?.trim() ?? "";

  const isCommand = command === "/contentbg" || command === "/contentbackgrounds";
  const isCallback = callbackData.startsWith("cbg:");

  let pending: Awaited<ReturnType<typeof pendingBackgroundTier>> = null;
  if (
    owner &&
    userId === owner &&
    message &&
    (message.photo?.length || message.document)
  ) {
    pending = await pendingBackgroundTier(owner);
  }
  const isPendingUpload = Boolean(pending);

  if (!isCommand && !isCallback && !isPendingUpload) return { handled: false };

  if (!owner || userId !== owner) {
    if (callback?.id) {
      await api("answerCallbackQuery", {
        callback_query_id: callback.id,
        text: "Owner only.",
        show_alert: true,
      }).catch(() => undefined);
    }
    return { handled: true };
  }

  const chatId = message?.chat?.id ?? callback?.message?.chat?.id ?? pending?.chatId;
  if (!chatId) return { handled: true };
  await ensureContentBackgroundSchema();

  if (isPendingUpload && message && pending) {
    let fileId: string | null = null;
    let uniqueId: string | null = null;

    if (message.photo?.length) {
      const photo = message.photo[message.photo.length - 1];
      fileId = photo.file_id ?? null;
      uniqueId = photo.file_unique_id ?? null;
    } else if (message.document) {
      const mime = message.document.mime_type ?? "";
      if (mime.startsWith("image/")) {
        fileId = message.document.file_id ?? null;
        uniqueId = message.document.file_unique_id ?? null;
      }
    }

    if (!fileId) {
      await api("sendMessage", {
        chat_id: chatId,
        text: "Please send a JPG, PNG or WEBP image.",
      });
      return { handled: true };
    }

    await setContentBackground(pending.tier, fileId, uniqueId);
    await clearPendingBackgroundTier(owner);
    await api("sendMessage", {
      chat_id: chatId,
      text: `${tierTitle(pending.tier)} background updated.`,
    });
    await sendPreview(chatId, pending.tier);
    return { handled: true };
  }

  if (isCommand || callbackData === "cbg:menu") {
    if (callback?.id) {
      await api("answerCallbackQuery", { callback_query_id: callback.id });
    }
    await clearPendingBackgroundTier(owner);
    await sendMenu(chatId);
    return { handled: true };
  }

  const [, action, rawTier] = callbackData.split(":");
  if (!validTier(rawTier)) {
    if (callback?.id) {
      await api("answerCallbackQuery", {
        callback_query_id: callback.id,
        text: "Unknown tier.",
        show_alert: true,
      });
    }
    return { handled: true };
  }

  if (callback?.id) {
    await api("answerCallbackQuery", { callback_query_id: callback.id });
  }

  if (action === "tier") {
    await sendTierMenu(chatId, owner, rawTier);
  } else if (action === "preview") {
    await sendPreview(chatId, rawTier);
  } else if (action === "reset") {
    await resetContentBackground(rawTier);
    await clearPendingBackgroundTier(owner);
    await api("sendMessage", {
      chat_id: chatId,
      text: `${tierTitle(rawTier)} background reset to default.`,
    });
    await sendPreview(chatId, rawTier);
  }

  return { handled: true };
}
