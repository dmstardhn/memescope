import "server-only";

import sharp from "sharp";
import { neon } from "@neondatabase/serverless";
import {
  ensureContentBackgroundSchema,
  getBackgroundFileId,
  telegramFileBuffer,
  tierFromMultiple,
  tierTitle,
  type ContentTier,
} from "./backgrounds";

type DbRow = Record<string, unknown>;

export type CallRow = {
  signalRecordId: string;
  publicId: string;
  symbol: string;
  calledAt: string;
  callMarketCapUsd: number | null;
  peakMarketCapUsd: number | null;
  peakMultiple: number;
  opportunityId: number | null;
};

function sqlClient() {
  const url = process.env.DATABASE_URL?.trim();
  if (!url) throw new Error("DATABASE_URL is not configured.");
  return neon(url);
}

function botToken() {
  const token = process.env.TELEGRAM_BOT_TOKEN?.trim();
  if (!token) throw new Error("TELEGRAM_BOT_TOKEN is not configured.");
  return token;
}

function n(value: unknown, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function maybe(value: unknown) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function esc(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function usd(value: number | null) {
  if (value === null || !Number.isFinite(value)) return "N/A";
  const abs = Math.abs(value);
  if (abs >= 1e9) return `$${(value / 1e9).toFixed(2)}B`;
  if (abs >= 1e6) return `$${(value / 1e6).toFixed(2)}M`;
  if (abs >= 1e3) return `$${(value / 1e3).toFixed(1)}K`;
  return `$${value.toFixed(0)}`;
}

function elapsed(value: string) {
  const start = new Date(value).getTime();
  if (!Number.isFinite(start)) return "N/A";
  const minutes = Math.max(0, Date.now() - start) / 60000;
  if (minutes < 60) return `${Math.max(1, Math.round(minutes))}m`;
  const hours = minutes / 60;
  if (hours < 24) return `${hours.toFixed(1)}h`;
  return `${(hours / 24).toFixed(1)}d`;
}

function accent(tier: ContentTier) {
  const colors: Record<ContentTier, string> = {
    momentum: "#64d7ff",
    breakout: "#75efad",
    surge: "#ffd167",
    apex: "#ff9d6c",
    legend: "#cfa1ff",
    titan: "#ff78c6",
    century: "#fff09a",
  };
  return colors[tier];
}

function normalizeCall(row: DbRow): CallRow {
  return {
    signalRecordId: String(row.signal_record_id ?? ""),
    publicId: String(row.public_id ?? ""),
    symbol: String(row.symbol ?? "TOKEN").replace(/^\$/, ""),
    calledAt: String(row.called_at ?? new Date().toISOString()),
    callMarketCapUsd: maybe(row.call_market_cap_usd),
    peakMarketCapUsd: maybe(row.peak_market_cap_usd),
    peakMultiple: Math.max(1, n(row.peak_multiple, 1)),
    opportunityId:
      row.opportunity_id === null || row.opportunity_id === undefined
        ? null
        : n(row.opportunity_id),
  };
}

async function background(tier: ContentTier) {
  const fileId = await getBackgroundFileId(tier);
  if (fileId) {
    try {
      const source = await telegramFileBuffer(fileId);
      return sharp(source).resize(1600, 900, { fit: "cover" }).png().toBuffer();
    } catch (error) {
      console.error(`Content background ${tier} failed; using default.`, error);
    }
  }

  const a = accent(tier);
  const grid = Array.from({ length: 17 }, (_, i) =>
    `<line x1="${i * 100}" y1="0" x2="${i * 100}" y2="900" stroke="#17302a" opacity=".28"/>`,
  ).join("") + Array.from({ length: 10 }, (_, i) =>
    `<line x1="0" y1="${i * 100}" x2="1600" y2="${i * 100}" stroke="#17302a" opacity=".28"/>`,
  ).join("");

  const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <rect width="1600" height="900" fill="#050807"/>
    ${grid}
    <circle cx="1180" cy="190" r="430" fill="${a}" opacity=".055"/>
    <path d="M84 560 L84 292 L320 156 L556 292 L556 560 L320 696 Z" fill="none" stroke="${a}" stroke-width="4" opacity=".12"/>
    <path d="M145 524 L145 330 L320 228 L495 330 L495 524 L320 626 Z" fill="none" stroke="${a}" stroke-width="2" opacity=".14"/>
    <path d="M145 330 L495 524 M495 330 L145 524" stroke="${a}" stroke-width="2" opacity=".07"/>
    <rect x="30" y="30" width="1540" height="840" rx="30" fill="none" stroke="${a}" stroke-width="2" opacity=".28"/>
    <rect x="56" y="56" width="1488" height="788" rx="24" fill="none" stroke="#42554f" opacity=".45"/>
  </svg>`;
  return sharp(Buffer.from(svg)).png().toBuffer();
}

export async function renderResultCard(call: CallRow) {
  const tier = tierFromMultiple(call.peakMultiple);
  const a = accent(tier);
  const gain = Math.max(0, (call.peakMultiple - 1) * 100);
  const base = await background(tier);
  const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <style>
      .mono{font-family:monospace;font-weight:700;letter-spacing:2px}
      .label{font-family:monospace;font-weight:600;letter-spacing:2px;fill:#8c9a95}
      .value{font-family:monospace;font-weight:700;fill:#f3f7f5}
    </style>
    <rect width="1600" height="900" fill="#010302" opacity=".25"/>
    <rect x="615" y="74" width="870" height="86" rx="22" fill="#07100d" opacity=".82" stroke="${a}" stroke-width="2"/>
    <text x="105" y="120" class="mono" font-size="38" fill="#edf4f1">MEMESCOPE</text>
    <text x="650" y="130" class="mono" font-size="46" fill="${a}">${esc(tierTitle(tier))}</text>
    <text x="1450" y="125" text-anchor="end" class="label" font-size="25">TRACKED PERFORMANCE</text>
    <text x="650" y="320" class="mono" font-size="92" fill="#f4f7f6">$${esc(call.symbol.toUpperCase().slice(0, 14))}</text>
    <text x="650" y="455" class="mono" font-size="122" fill="${a}">+${gain.toFixed(0)}%</text>
    <text x="650" y="505" class="label" font-size="30">PEAK MOVE SINCE CALL</text>
    <rect x="650" y="555" width="245" height="146" rx="18" fill="#06100c" opacity=".86" stroke="#52635d"/>
    <rect x="920" y="555" width="245" height="146" rx="18" fill="#06100c" opacity=".86" stroke="#52635d"/>
    <rect x="1190" y="555" width="280" height="146" rx="18" fill="#06100c" opacity=".86" stroke="#52635d"/>
    <text x="675" y="602" class="label" font-size="24">CALL MC</text>
    <text x="675" y="665" class="value" font-size="48">${esc(usd(call.callMarketCapUsd))}</text>
    <text x="945" y="602" class="label" font-size="24">PEAK MC</text>
    <text x="945" y="665" class="mono" font-size="48" fill="${a}">${esc(usd(call.peakMarketCapUsd))}</text>
    <text x="1215" y="602" class="label" font-size="24">ELAPSED</text>
    <text x="1215" y="665" class="value" font-size="48">${esc(elapsed(call.calledAt))}</text>
    <rect x="82" y="712" width="455" height="120" rx="18" fill="#06100c" opacity=".86" stroke="#52635d"/>
    <text x="108" y="758" class="label" font-size="23">CALL ID</text>
    <text x="108" y="807" class="value" font-size="38">${esc(call.publicId.toUpperCase().slice(0, 22))}</text>
    <text x="1450" y="805" text-anchor="end" class="mono" font-size="25" fill="${a}">MEMESCOPE RESULT ENGINE</text>
  </svg>`;

  return {
    tier,
    buffer: await sharp(base)
      .composite([{ input: Buffer.from(svg) }])
      .webp({ quality: 94 })
      .toBuffer(),
  };
}

async function telegramApi(method: string, body: Record<string, unknown>) {
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

async function sendPhoto(
  chatId: string | number,
  buffer: Buffer,
  caption: string,
  replyMarkup?: Record<string, unknown>,
) {
  const form = new FormData();
  form.append("chat_id", String(chatId));
  form.append("parse_mode", "HTML");
  form.append("caption", caption);
  if (replyMarkup) form.append("reply_markup", JSON.stringify(replyMarkup));
  form.append(
    "photo",
    new Blob([buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength) as ArrayBuffer], { type: "image/webp" }),
    "memescope-content.webp",
  );

  const response = await fetch(
    `https://api.telegram.org/bot${botToken()}/sendPhoto`,
    { method: "POST", body: form, cache: "no-store" },
  );
  const payload = (await response.json()) as {
    ok?: boolean;
    result?: { message_id?: number };
    description?: string;
  };
  if (!response.ok || !payload.ok || !payload.result) {
    throw new Error(payload.description ?? "Telegram sendPhoto failed.");
  }
  return payload.result;
}

async function contentChatId() {
  const { getContentHqStatus } = await import("@/lib/call-story");
  const hq = await getContentHqStatus();
  return hq.configured && hq.chatId ? hq.chatId : null;
}

function tagsFor(multiple: number) {
  const tier = tierTitle(tierFromMultiple(multiple));
  const pretty = `${tier.slice(0, 1)}${tier.slice(1).toLowerCase()}`;
  return `#MemeScope #Solana #Memecoin #${pretty}`;
}

function xCaption(call: CallRow) {
  const gain = Math.max(0, (call.peakMultiple - 1) * 100);
  const symbol = `$${call.symbol}`;

  if (call.peakMultiple >= 20) {
    return [
      `${symbol} moved from ${usd(call.callMarketCapUsd)} MC to a ${usd(call.peakMarketCapUsd)} peak after the MemeScope call.`,
      "",
      `+${gain.toFixed(0)}% peak move.`,
      "",
      "tracked from the original call.",
    ].join("\n");
  }

  if (call.peakMultiple >= 5) {
    return [
      `${symbol} kept expanding after the MemeScope call.`,
      "",
      `${usd(call.callMarketCapUsd)} MC -> ${usd(call.peakMarketCapUsd)} peak`,
      `+${gain.toFixed(0)}%`,
      "",
      "tracking the move from the original call.",
    ].join("\n");
  }

  return [
    `${symbol} is developing after the MemeScope call.`,
    "",
    `${usd(call.callMarketCapUsd)} MC -> ${usd(call.peakMarketCapUsd)} peak`,
    `+${gain.toFixed(0)}%`,
    "",
    "still tracking the move.",
  ].join("\n");
}

function draftCaption(call: CallRow) {
  const tier = tierTitle(tierFromMultiple(call.peakMultiple));
  return [
    `<b>CONTENT DRAFT · ${tier}</b>`,
    "",
    "<b>Caption</b>",
    esc(xCaption(call)),
    "",
    "<b>Tags</b>",
    tagsFor(call.peakMultiple),
    "",
    `<code>${esc(call.publicId)}</code>`,
  ].join("\n");
}

async function sendCallDraft(
  chatId: string | number,
  call: CallRow,
  buttons = false,
) {
  const rendered = await renderResultCard(call);
  const replyMarkup = buttons && call.opportunityId
    ? {
        inline_keyboard: [[
          { text: "Used", callback_data: `content:used:${call.opportunityId}` },
          { text: "Skip", callback_data: `content:skip:${call.opportunityId}` },
        ]],
      }
    : undefined;
  return sendPhoto(chatId, rendered.buffer, draftCaption(call), replyMarkup);
}

export async function publishPendingContentOpportunityDrafts() {
  await ensureContentBackgroundSchema();
  const chatId = await contentChatId();
  if (!chatId) return { configured: false, sent: 0 };

  const sql = sqlClient();
  const rows = await sql`
    SELECT
      o.id AS opportunity_id,
      o.priority,
      o.opportunity_type,
      o.milestone_multiple,
      c.*
    FROM memescope_content_opportunities o
    JOIN memescope_call_story c
      ON c.signal_record_id = o.signal_record_id
    WHERE o.status = 'pending'
      AND o.telegram_message_id IS NULL
    ORDER BY o.created_at ASC
    LIMIT 4
  `;

  let sent = 0;
  for (const raw of rows) {
    const call = normalizeCall(raw as DbRow);
    try {
      const message = await sendCallDraft(chatId, call, true);
      await sql`
        UPDATE memescope_content_opportunities
        SET telegram_message_id = ${Number(message.message_id ?? 0)},
            status = 'sent',
            sent_at = NOW(),
            updated_at = NOW()
        WHERE id = ${call.opportunityId}
      `;
      sent += 1;
    } catch (error) {
      console.error("MemeScope Content V5 image draft failed; using text fallback:", error);
      const fallback = await telegramApi("sendMessage", {
        chat_id: chatId,
        text: draftCaption(call),
        parse_mode: "HTML",
        reply_markup: call.opportunityId
          ? {
              inline_keyboard: [[
                { text: "Used", callback_data: `content:used:${call.opportunityId}` },
                { text: "Skip", callback_data: `content:skip:${call.opportunityId}` },
              ]],
            }
          : undefined,
      }) as { message_id?: number };
      if (fallback?.message_id) {
        await sql`
          UPDATE memescope_content_opportunities
          SET telegram_message_id = ${fallback.message_id},
              status = 'sent',
              sent_at = NOW(),
              updated_at = NOW()
          WHERE id = ${call.opportunityId}
        `;
        sent += 1;
      }
    }
  }

  return { configured: true, sent };
}

function jakartaDate() {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Jakarta",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

async function last72Rows() {
  const sql = sqlClient();
  const rows = await sql`
    SELECT signal_record_id, public_id, symbol, called_at,
           call_market_cap_usd, peak_market_cap_usd, peak_multiple
    FROM memescope_call_story
    WHERE called_at >= NOW() - INTERVAL '72 hours'
      AND COALESCE(peak_multiple, 1) >= 3
    ORDER BY peak_multiple DESC, called_at DESC
    LIMIT 5
  `;
  return rows.map((raw: DbRow) => normalizeCall(raw));
}

export async function renderLast72Card(rows: CallRow[]) {
  const base = await background("legend");
  const rowHtml = rows.slice(0, 5).map((row, index) => {
    const gain = Math.max(0, (row.peakMultiple - 1) * 100);
    const y = 245 + index * 118;
    return `<g>
      <rect x="95" y="${y - 48}" width="1410" height="96" rx="18" fill="#06100c" opacity=".87" stroke="#41534d"/>
      <text x="125" y="${y + 12}" font-family="monospace" font-size="38" font-weight="700" fill="${index === 0 ? "#ffd167" : "#87958f"}">${index + 1}</text>
      <text x="205" y="${y + 12}" font-family="monospace" font-size="38" font-weight="700" fill="#f2f6f4">$${esc(row.symbol.toUpperCase().slice(0, 12))}</text>
      <text x="850" y="${y + 12}" text-anchor="end" font-family="monospace" font-size="38" font-weight="700" fill="#75efad">+${gain.toFixed(0)}%</text>
      <text x="895" y="${y + 8}" font-family="monospace" font-size="25" fill="#9caaa5">${esc(usd(row.callMarketCapUsd))} -> ${esc(usd(row.peakMarketCapUsd))}</text>
      <text x="1460" y="${y + 8}" text-anchor="end" font-family="monospace" font-size="22" fill="#75847f">${esc(row.publicId.toUpperCase().slice(0, 18))}</text>
    </g>`;
  }).join("");

  const svg = `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
    <rect width="1600" height="900" fill="#010302" opacity=".28"/>
    <text x="100" y="105" font-family="monospace" font-size="34" font-weight="700" fill="#f2f6f4">MEMESCOPE</text>
    <text x="100" y="170" font-family="monospace" font-size="62" font-weight="800" fill="#cfa1ff">LAST 72 HOURS</text>
    <text x="1460" y="160" text-anchor="end" font-family="monospace" font-size="25" fill="#91a09b">TOP TRACKED MOVERS FROM ORIGINAL CALLS</text>
    ${rowHtml}
    <text x="100" y="835" font-family="monospace" font-size="22" fill="#73827d">ROLLING 72H WINDOW · TRACKED CALL PERFORMANCE</text>
  </svg>`;

  return sharp(base)
    .composite([{ input: Buffer.from(svg) }])
    .webp({ quality: 94 })
    .toBuffer();
}

export async function publishDailyLast72Draft(force = false) {
  await ensureContentBackgroundSchema();
  const chatId = await contentChatId();
  if (!chatId) return { configured: false, sent: false };

  const sql = sqlClient();
  const key = `content-last72:${jakartaDate()}`;
  if (!force) {
    const existing = await sql`
      SELECT report_key FROM memescope_content_v5_daily
      WHERE report_key = ${key}
      LIMIT 1
    `;
    if (existing.length) return { configured: true, sent: false, reason: "already-sent" };
  }

  const rows = await last72Rows();
  if (!rows.length) return { configured: true, sent: false, reason: "no-rows" };

  const buffer = await renderLast72Card(rows);
  const caption = [
    "<b>CONTENT DRAFT · LAST 72 HOURS</b>",
    "",
    "<b>Caption</b>",
    "MemeScope // Last 72 Hours",
    "",
    ...rows.map((row: CallRow, index: number) => {
      const gain = Math.max(0, (row.peakMultiple - 1) * 100);
      return `${index + 1}. $${esc(row.symbol)} · +${gain.toFixed(0)}%`;
    }),
    "",
    "<b>Tags</b>",
    "#MemeScope #Solana #Memecoin #Last72Hours",
  ].join("\n");

  const message = await sendPhoto(chatId, buffer, caption);
  if (!force) {
    await sql`
      INSERT INTO memescope_content_v5_daily (report_key, telegram_message_id)
      VALUES (${key}, ${Number(message.message_id ?? 0)})
      ON CONFLICT (report_key) DO NOTHING
    `;
  }
  return { configured: true, sent: true, messageId: message.message_id };
}

export async function sendLatestResultDraftPreview() {
  await ensureContentBackgroundSchema();
  const chatId = await contentChatId();
  if (!chatId) return { configured: false, sent: false };

  const sql = sqlClient();
  const rows = await sql`
    SELECT signal_record_id, public_id, symbol, called_at,
           call_market_cap_usd, peak_market_cap_usd, peak_multiple
    FROM memescope_call_story
    WHERE called_at >= NOW() - INTERVAL '72 hours'
      AND COALESCE(peak_multiple, 1) >= 3
    ORDER BY peak_multiple DESC, called_at DESC
    LIMIT 1
  `;
  if (!rows.length) return { configured: true, sent: false, reason: "no-result" };

  const call = normalizeCall(rows[0] as DbRow);
  const message = await sendCallDraft(chatId, call, false);
  return {
    configured: true,
    sent: true,
    symbol: call.symbol,
    publicId: call.publicId,
    peakMultiple: call.peakMultiple,
    messageId: message.message_id,
  };
}
