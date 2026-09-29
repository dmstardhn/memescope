import "server-only";
import { getV4Settings, resetV4History, setManualApproval, v4Status } from "./db";
import { approve, getItem, listPending, nextCaption, nextVisual, reject } from "./queue-control";
import { publishNow, scheduleIn, xPublishingConfigured } from "./publisher";

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
  return { inline_keyboard: [
    [
      {text:"Queue",callback_data:"ch4:queue"},
      {text:"Status",callback_data:"ch4:status"},
    ],
    [
      {text:manual?"Manual Approval: ON":"Manual Approval: OFF",callback_data:"ch4:toggle_manual"},
    ],
    [
      {text:"Reset Content History",callback_data:"ch4:reset"},
    ],
  ]};
}

async function sendMenu(chatId: number) {
  const state = await v4Status();
  const s = state.settings;
  await api("sendMessage", {
    chat_id:chatId,
    text:
`MemeScope - Content HQ V4

Mode: ${s.manualApproval ? "MANUAL APPROVAL" : "AUTO APPROVE"}
Queued: ${state.counts.queued}
Approved: ${state.counts.approved}
Published: ${state.counts.published}
Failed: ${state.counts.failed}

History since: ${new Date(s.historyResetAt).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}`,
    reply_markup:menuKeyboard(s.manualApproval),
  });
}

async function sendQueueItem(chatId: number, id: number) {
  const item = await getItem(id);
  if (!item) return;

  const caption =
`Content HQ Preview

Type: ${String(item.content_type)}
Style: ${String(item.visual_style ?? "text_only")}
Reason: ${String(item.reason ?? "-")}

${String(item.caption)}

Status: ${String(item.status)}`;

  const keyboard = {inline_keyboard:[
    [
      {text:"Approve",callback_data:`ch4:approve:${id}`},
      {text:"Reject",callback_data:`ch4:reject:${id}`},
    ],
    [
      {text:"Next Caption",callback_data:`ch4:caption:${id}`},
      {text:"Next Chart Style",callback_data:`ch4:visual:${id}`},
    ],
    [
      {text:"Publish Now",callback_data:`ch4:publish:${id}`},
      {text:"Schedule +1h",callback_data:`ch4:schedule:${id}`},
    ],
    [
      {text:"Back",callback_data:"ch4:queue"},
    ],
  ]};

  if (item.image_base64) {
    await api("sendPhoto", {
      chat_id:chatId,
      photo:`data:${String(item.image_mime ?? "image/webp")};base64,${String(item.image_base64)}`,
      caption,
      reply_markup:keyboard,
    }).catch(async () => {
      await api("sendMessage",{chat_id:chatId,text:caption,reply_markup:keyboard});
    });
  } else {
    await api("sendMessage",{chat_id:chatId,text:caption,reply_markup:keyboard});
  }
}

async function sendQueue(chatId: number) {
  const items = await listPending(5);
  if (!items.length) {
    await api("sendMessage",{chat_id:chatId,text:"Content queue is empty."});
    return;
  }

  for (const item of items) {
    await sendQueueItem(chatId, Number(item.id));
  }
}

export async function tryHandleContentHqAdminRequest(request: Request) {
  const secret = process.env.TELEGRAM_WEBHOOK_SECRET?.trim();
  if (secret) {
    const received = request.headers.get("x-telegram-bot-api-secret-token");
    if (received !== secret) return {handled:false};
  }

  let update: TelegramUpdate;
  try { update = await request.json() as TelegramUpdate; }
  catch { return {handled:false}; }

  const text = update.message?.text?.trim();
  const callback = update.callback_query?.data?.trim();

  if (text !== "/contenthq" && !callback?.startsWith("ch4:")) return {handled:false};

  const userId = update.message?.from?.id ?? update.callback_query?.from?.id ?? null;
  if (!ownerId() || userId !== ownerId()) {
    if (update.callback_query?.id) {
      await api("answerCallbackQuery",{callback_query_id:update.callback_query.id,text:"Owner only.",show_alert:true}).catch(()=>undefined);
    }
    return {handled:true};
  }

  const chatId = update.message?.chat?.id ?? update.callback_query?.message?.chat?.id;
  if (!chatId) return {handled:true};

  if (text === "/contenthq") {
    await sendMenu(chatId);
    return {handled:true};
  }

  if (callback === "ch4:status") {
    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id});
    await sendMenu(chatId);
    return {handled:true};
  }

  if (callback === "ch4:queue") {
    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id});
    await sendQueue(chatId);
    return {handled:true};
  }

  if (callback === "ch4:toggle_manual") {
    const current = await getV4Settings();
    await setManualApproval(!current.manualApproval);
    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`Manual Approval ${!current.manualApproval?"ON":"OFF"}`});
    await sendMenu(chatId);
    return {handled:true};
  }

  const match = callback?.match(/^ch4:(approve|reject|caption|visual|publish|schedule):(\d+)$/);
  if (match) {
    const action = match[1];
    const id = Number(match[2]);

    if (action === "approve") await approve(id);
    if (action === "reject") await reject(id);
    if (action === "caption") await nextCaption(id);
    if (action === "visual") await nextVisual(id);
    if (action === "schedule") {
      const at = await scheduleIn(id,60);
      await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`Scheduled ${new Date(at).toLocaleTimeString("en-GB",{timeZone:"Asia/Jakarta"})}`});
      await sendQueueItem(chatId,id);
      return {handled:true};
    }
    if (action === "publish") {
      if (!xPublishingConfigured()) {
        await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:"X publishing is not configured.",show_alert:true});
        return {handled:true};
      }
      const result = await publishNow(id,true);
      await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`Published: ${result.tweetId}`,show_alert:true});
      await sendQueueItem(chatId,id);
      return {handled:true};
    }

    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:`${action} applied`});
    await sendQueueItem(chatId,id);
    return {handled:true};
  }

  if (callback === "ch4:reset") {
    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id});
    await api("sendMessage",{
      chat_id:chatId,
      text:"RESET CONTENT HISTORY?\n\nOnly Content HQ history/rotation/cooldown context is reset. Calls, signals and market data stay intact.",
      reply_markup:{inline_keyboard:[[
        {text:"CONFIRM RESET",callback_data:"ch4:reset_confirm"},
        {text:"CANCEL",callback_data:"ch4:cancel"},
      ]]},
    });
    return {handled:true};
  }

  if (callback === "ch4:reset_confirm") {
    const at = await resetV4History();
    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:"Content history reset.",show_alert:true});
    await api("sendMessage",{chat_id:chatId,text:`Content history reset.\nNew history starts: ${new Date(at).toLocaleString("en-GB",{timeZone:"Asia/Jakarta"})}`});
    return {handled:true};
  }

  if (callback === "ch4:cancel") {
    await api("answerCallbackQuery",{callback_query_id:update.callback_query!.id,text:"Cancelled."});
    return {handled:true};
  }

  return {handled:true};
}