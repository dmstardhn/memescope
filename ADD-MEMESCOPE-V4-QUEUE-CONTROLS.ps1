$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Full([string]$p) { Join-Path $root $p }
function WriteUtf8([string]$rel, [string]$text) {
  $path = Full $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  [System.IO.File]::WriteAllText($path, $text, $utf8)
  Write-Host "WRITE $rel" -ForegroundColor Green
}

foreach ($rel in @(
  "src\lib\content-hq-v4\db.ts",
  "src\lib\content-hq-v4\render.ts",
  "src\lib\content-hq-v4\telegram-admin.ts"
)) {
  if (!(Test-Path (Full $rel))) { throw "Missing $rel" }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-V4-QueueControls-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item (Full "src\lib\content-hq-v4\telegram-admin.ts") (Join-Path $backup "telegram-admin.ts") -Force

$queueControl = @'
import "server-only";
import { getV4Settings, sqlV4, type ContentType } from "./db";
import { renderContent, type Candle } from "./render";

type Row = Record<string, unknown>;

const CAPTIONS: Record<ContentType, string[]> = {
  market_observation: [
    "small caps getting more active today.\n\nwatching volume before chasing anything.",
    "market activity is picking up a bit.\n\nstill being selective.",
    "not much worth forcing here.\n\nwaiting for cleaner setups.",
  ],
  token_watch: [
    "$TOKEN starting to get interesting here.\n\nwatching the next push.",
    "$TOKEN\n\ninteresting structure developing.\n\nnot there yet.",
  ],
  chart_setup: [
    "$TOKEN\n\nwatching this structure.",
    "$TOKEN starting to look interesting around this area.",
    "$TOKEN\n\nwatching for a clean continuation.",
  ],
  token_update: [
    "$TOKEN update.\n\nnice reaction from the level.",
    "$TOKEN still holding up well.\n\nwatching continuation.",
    "$TOKEN\n\nclean move from the area.",
  ],
  before_move: [
    "$TOKEN\n\nfirst spotted around $FIRST_MC.\nnow sitting near $CURRENT_MC.\n\n$MULTIPLE since detection.",
    "$TOKEN before the move.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE.",
  ],
  call_journey: [
    "$TOKEN journey so far.\n\n$FIRST_MC -> $CURRENT_MC\n\n$MULTIPLE since detection.",
    "$TOKEN kept developing after the first detection.\n\nnow at $MULTIPLE.",
  ],
  daily_recap: [
    "today's tape.\n\n$TOKEN was the standout tracked move at $MULTIPLE.",
  ],
  weekly_recap: [
    "weekly tape.\n\n$TOKEN was one of the stronger tracked moves at $MULTIPLE.",
  ],
};

const STYLES = ["pure_chart","level_setup","first_spotted","minimal_metrics","performance"];

function num(v: unknown): number | null {
  const x = Number(v);
  return Number.isFinite(x) ? x : null;
}
function txt(v: unknown) { return v == null ? "" : String(v); }
function usd(v: number | null) {
  if (v == null || !Number.isFinite(v)) return "N/A";
  if (v >= 1e9) return `$${(v/1e9).toFixed(2)}B`;
  if (v >= 1e6) return `$${(v/1e6).toFixed(2)}M`;
  if (v >= 1e3) return `$${(v/1e3).toFixed(0)}K`;
  return `$${v.toFixed(0)}`;
}
function fill(template: string, symbol: string, firstMc: number | null, currentMc: number | null, multiple: number | null) {
  return template
    .replaceAll("$TOKEN", `$${symbol}`)
    .replaceAll("$FIRST_MC", usd(firstMc))
    .replaceAll("$CURRENT_MC", usd(currentMc))
    .replaceAll("$MULTIPLE", multiple ? `${multiple.toFixed(2)}x` : "N/A");
}

async function candles(pair: string | null) {
  if (!pair) return [] as Candle[];
  try {
    const r = await fetch(
      `https://api.geckoterminal.com/api/v2/networks/solana/pools/${encodeURIComponent(pair)}/ohlcv/minute?aggregate=5&limit=100&currency=usd&token=base`,
      { headers: { Accept: "application/json;version=20230203" }, cache: "no-store" },
    );
    if (!r.ok) return [];
    const body = await r.json() as {data?: {attributes?: {ohlcv_list?: number[][]}}};
    return (body.data?.attributes?.ohlcv_list ?? [])
      .map(row => ({
        timestamp: Number(row[0])*1000,
        open:Number(row[1]), high:Number(row[2]), low:Number(row[3]),
        close:Number(row[4]), volume:Number(row[5]??0),
      }))
      .filter(x => Number.isFinite(x.close) && x.close > 0)
      .sort((a,b)=>a.timestamp-b.timestamp);
  } catch { return []; }
}

export async function listPending(limit = 5) {
  const settings = await getV4Settings();
  const sql = sqlV4();
  return await sql`
    SELECT *
    FROM memescope_content_v4_queue
    WHERE created_at >= ${settings.historyResetAt}::timestamptz
      AND status IN ('queued','approved','scheduled')
    ORDER BY created_at DESC
    LIMIT ${limit}
  ` as Row[];
}

export async function getItem(id: number) {
  const sql = sqlV4();
  const rows = await sql`SELECT * FROM memescope_content_v4_queue WHERE id=${id} LIMIT 1`;
  return rows.length ? rows[0] as Row : null;
}

export async function approve(id: number) {
  const sql = sqlV4();
  await sql`UPDATE memescope_content_v4_queue SET status='approved', approved_at=NOW() WHERE id=${id}`;
}

export async function reject(id: number) {
  const sql = sqlV4();
  await sql`UPDATE memescope_content_v4_queue SET status='rejected' WHERE id=${id}`;
}

export async function nextCaption(id: number) {
  const item = await getItem(id);
  if (!item) throw new Error("Queue item not found.");
  const type = txt(item.content_type) as ContentType;
  const list = CAPTIONS[type] ?? [];
  if (!list.length) return;

  const currentKey = txt(item.caption_template);
  const currentNum = Number(currentKey.split("_").at(-1) ?? 1);
  const nextIndex = Number.isFinite(currentNum) ? currentNum % list.length : 0;
  const key = `${type}_${String(nextIndex+1).padStart(2,"0")}`;
  const caption = fill(
    list[nextIndex],
    txt(item.symbol),
    num(item.first_market_cap),
    num(item.current_market_cap),
    num(item.multiple),
  );

  const sql = sqlV4();
  await sql`
    UPDATE memescope_content_v4_queue
    SET caption_template=${key}, caption=${caption}
    WHERE id=${id}
  `;
}

export async function nextVisual(id: number) {
  const item = await getItem(id);
  if (!item) throw new Error("Queue item not found.");

  const type = txt(item.content_type) as ContentType;
  if (type === "market_observation") return;

  let next = "pure_chart";
  if (type === "before_move") next = "split_before_now";
  else if (type === "call_journey") next = "journey";
  else {
    const current = txt(item.visual_style);
    const idx = STYLES.indexOf(current);
    next = STYLES[(idx + 1) % STYLES.length];
  }

  const liveCandles = await candles(txt(item.pair_address) || null);
  if (liveCandles.length < 2) throw new Error("Chart data unavailable.");

  const rendered = await renderContent({
    symbol: txt(item.symbol),
    contentType: type,
    visualStyle: next,
    firstMarketCap: num(item.first_market_cap),
    currentMarketCap: num(item.current_market_cap),
    multiple: num(item.multiple),
    liquidity: null,
    volume: null,
    candles: liveCandles,
    branded: Boolean(item.branded),
  });

  if (!rendered) throw new Error("Visual could not be rendered.");

  const sql = sqlV4();
  await sql`
    UPDATE memescope_content_v4_queue
    SET visual_style=${next},
        image_base64=${rendered.buffer.toString("base64")},
        image_mime=${rendered.mime}
    WHERE id=${id}
  `;
}
'@
WriteUtf8 "src/lib/content-hq-v4/queue-control.ts" $queueControl

$telegram = @'
import "server-only";
import { getV4Settings, resetV4History, setManualApproval, v4Status } from "./db";
import { approve, getItem, listPending, nextCaption, nextVisual, reject } from "./queue-control";

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

  const match = callback?.match(/^ch4:(approve|reject|caption|visual):(\d+)$/);
  if (match) {
    const action = match[1];
    const id = Number(match[2]);

    if (action === "approve") await approve(id);
    if (action === "reject") await reject(id);
    if (action === "caption") await nextCaption(id);
    if (action === "visual") await nextVisual(id);

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
'@
WriteUtf8 "src/lib/content-hq-v4/telegram-admin.ts" $telegram

Write-Host ""
Write-Host "Queue controls installed." -ForegroundColor Green
Write-Host "Run: npm run typecheck" -ForegroundColor Cyan
Write-Host "Then: npm run build" -ForegroundColor Cyan
