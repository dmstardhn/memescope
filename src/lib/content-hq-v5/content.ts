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

const CONTENT_GLYPHS: Record<string, string[]> = {
  " ": ["00000","00000","00000","00000","00000","00000","00000"],
  "A": ["01110","10001","10001","11111","10001","10001","10001"],
  "B": ["11110","10001","10001","11110","10001","10001","11110"],
  "C": ["01111","10000","10000","10000","10000","10000","01111"],
  "D": ["11110","10001","10001","10001","10001","10001","11110"],
  "E": ["11111","10000","10000","11110","10000","10000","11111"],
  "F": ["11111","10000","10000","11110","10000","10000","10000"],
  "G": ["01111","10000","10000","10111","10001","10001","01111"],
  "H": ["10001","10001","10001","11111","10001","10001","10001"],
  "I": ["11111","00100","00100","00100","00100","00100","11111"],
  "J": ["00111","00010","00010","00010","10010","10010","01100"],
  "K": ["10001","10010","10100","11000","10100","10010","10001"],
  "L": ["10000","10000","10000","10000","10000","10000","11111"],
  "M": ["10001","11011","10101","10101","10001","10001","10001"],
  "N": ["10001","11001","10101","10011","10001","10001","10001"],
  "O": ["01110","10001","10001","10001","10001","10001","01110"],
  "P": ["11110","10001","10001","11110","10000","10000","10000"],
  "Q": ["01110","10001","10001","10001","10101","10010","01101"],
  "R": ["11110","10001","10001","11110","10100","10010","10001"],
  "S": ["01111","10000","10000","01110","00001","00001","11110"],
  "T": ["11111","00100","00100","00100","00100","00100","00100"],
  "U": ["10001","10001","10001","10001","10001","10001","01110"],
  "V": ["10001","10001","10001","10001","10001","01010","00100"],
  "W": ["10001","10001","10001","10101","10101","11011","10001"],
  "X": ["10001","10001","01010","00100","01010","10001","10001"],
  "Y": ["10001","10001","01010","00100","00100","00100","00100"],
  "Z": ["11111","00001","00010","00100","01000","10000","11111"],
  "0": ["01110","10001","10011","10101","11001","10001","01110"],
  "1": ["00100","01100","00100","00100","00100","00100","01110"],
  "2": ["01110","10001","00001","00010","00100","01000","11111"],
  "3": ["11110","00001","00001","01110","00001","00001","11110"],
  "4": ["00010","00110","01010","10010","11111","00010","00010"],
  "5": ["11111","10000","10000","11110","00001","00001","11110"],
  "6": ["01110","10000","10000","11110","10001","10001","01110"],
  "7": ["11111","00001","00010","00100","01000","01000","01000"],
  "8": ["01110","10001","10001","01110","10001","10001","01110"],
  "9": ["01110","10001","10001","01111","00001","00001","01110"],
  "$": ["00100","01111","10100","01110","00101","11110","00100"],
  "+": ["00000","00100","00100","11111","00100","00100","00000"],
  "%": ["11001","11010","00100","01000","10110","00110","00000"],
  ".": ["00000","00000","00000","00000","00000","00110","00110"],
  ",": ["00000","00000","00000","00000","00110","00110","00100"],
  "-": ["00000","00000","00000","11111","00000","00000","00000"],
  "/": ["00001","00010","00010","00100","01000","01000","10000"],
  ":": ["00000","00110","00110","00000","00110","00110","00000"],
  "(": ["00010","00100","01000","01000","01000","00100","00010"],
  ")": ["01000","00100","00010","00010","00010","00100","01000"],
  ">": ["10000","01000","00100","00010","00100","01000","10000"],
  "<": ["00001","00010","00100","01000","00100","00010","00001"],
  "?": ["11110","00001","00010","00100","00100","00000","00100"],
};

function contentTextWidth(
  value: string,
  scale: number,
) {
  return Math.max(
    0,
    value.length * 6 * scale - scale,
  );
}

function contentPixelText(
  raw: string,
  x: number,
  y: number,
  scale: number,
  color: string,
  options?: {
    anchor?: "start" | "middle" | "end";
    opacity?: number;
  },
) {
  const value =
    raw
      .toUpperCase()
      .replace(
        /[^A-Z0-9 $+%.,\-/:()<>]/g,
        "?",
      );

  const width =
    contentTextWidth(
      value,
      scale,
    );

  let left = x;

  if (
    options?.anchor === "middle"
  ) {
    left -= width / 2;
  } else if (
    options?.anchor === "end"
  ) {
    left -= width;
  }

  const opacity =
    options?.opacity ?? 1;

  const pieces: string[] = [];

  for (
    let index = 0;
    index < value.length;
    index += 1
  ) {
    const glyph =
      CONTENT_GLYPHS[
        value[index]
      ] ??
      CONTENT_GLYPHS["?"];

    const ox =
      left +
      index * scale * 6;

    for (
      let row = 0;
      row < 7;
      row += 1
    ) {
      for (
        let col = 0;
        col < 5;
        col += 1
      ) {
        if (
          glyph[row]?.[col] !== "1"
        ) {
          continue;
        }

        pieces.push(
          `<rect x="${(ox + col * scale).toFixed(1)}" y="${(y + row * scale).toFixed(1)}" width="${scale}" height="${scale}" rx="${Math.max(0, scale * 0.08).toFixed(2)}" fill="${color}" opacity="${opacity}"/>`,
        );
      }
    }
  }

  return pieces.join("");
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
  const tier =
    tierFromMultiple(
      call.peakMultiple,
    );

  const a =
    accent(tier);

  const gain =
    Math.max(
      0,
      (
        call.peakMultiple -
        1
      ) * 100,
    );

  const base =
    await background(
      tier,
    );

  const symbol =
    `${call.symbol
      .toUpperCase()
      .replace(
        /[^A-Z0-9]/g,
        "",
      )
      .slice(
        0,
        14,
      )}`;

  const symbolScale =
    symbol.length >= 13
      ? 4
      : symbol.length >= 10
        ? 5
        : 6;

  const gainText =
    `+${gain.toFixed(0)}%`;

  const svg =
    `<svg
      width="1600"
      height="900"
      xmlns="http://www.w3.org/2000/svg"
    >
      <rect
        width="1600"
        height="900"
        fill="#010302"
        opacity=".25"
      />

      <rect
        x="615"
        y="74"
        width="870"
        height="86"
        rx="22"
        fill="#07100d"
        opacity=".82"
        stroke="${a}"
        stroke-width="2"
      />

      ${contentPixelText(
        "MEMESCOPE",
        105,
        90,
        5,
        "#edf4f1",
      )}

      ${contentPixelText(
        tierTitle(
          tier,
        ),
        650,
        101,
        4,
        a,
      )}

      ${contentPixelText(
        "TRACKED PERFORMANCE",
        1450,
        105,
        3,
        "#8c9a95",
        {
          anchor:
            "end",
        },
      )}

      ${contentPixelText(
        symbol,
        650,
        245,
        symbolScale,
        "#f4f7f6",
      )}

      ${contentPixelText(
        gainText,
        650,
        360,
        9,
        a,
      )}

      ${contentPixelText(
        "PEAK MOVE SINCE CALL",
        650,
        480,
        4,
        "#8c9a95",
      )}

      <rect
        x="650"
        y="555"
        width="245"
        height="146"
        rx="18"
        fill="#06100c"
        opacity=".86"
        stroke="#52635d"
      />

      <rect
        x="920"
        y="555"
        width="245"
        height="146"
        rx="18"
        fill="#06100c"
        opacity=".86"
        stroke="#52635d"
      />

      <rect
        x="1190"
        y="555"
        width="280"
        height="146"
        rx="18"
        fill="#06100c"
        opacity=".86"
        stroke="#52635d"
      />

      ${contentPixelText(
        "CALL MC",
        675,
        582,
        3,
        "#8c9a95",
      )}

      ${contentPixelText(
        usd(
          call.callMarketCapUsd,
        ),
        675,
        630,
        5,
        "#f3f7f5",
      )}

      ${contentPixelText(
        "PEAK MC",
        945,
        582,
        3,
        "#8c9a95",
      )}

      ${contentPixelText(
        usd(
          call.peakMarketCapUsd,
        ),
        945,
        630,
        5,
        a,
      )}

      ${contentPixelText(
        "ELAPSED",
        1215,
        582,
        3,
        "#8c9a95",
      )}

      ${contentPixelText(
        elapsed(
          call.calledAt,
        ),
        1215,
        630,
        5,
        "#f3f7f5",
      )}

      <rect
        x="82"
        y="712"
        width="455"
        height="120"
        rx="18"
        fill="#06100c"
        opacity=".86"
        stroke="#52635d"
      />

      ${contentPixelText(
        "CALL ID",
        108,
        742,
        3,
        "#8c9a95",
      )}

      ${contentPixelText(
        call.publicId
          .toUpperCase()
          .slice(
            0,
            22,
          ),
        108,
        788,
        4,
        "#f3f7f5",
      )}

      ${contentPixelText(
        "MEMESCOPE RESULT ENGINE",
        1450,
        790,
        3,
        a,
        {
          anchor:
            "end",
        },
      )}
    </svg>`;

  return {
    tier,

    buffer:
      await sharp(
        base,
      )
        .composite([
          {
            input:
              Buffer.from(
                svg,
                "utf8",
              ),
          },
        ])
        .webp({
          quality:
            94,
        })
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


export async function sendLatestRealTierPreview(
  tier: ContentTier,
) {
  await ensureContentBackgroundSchema();

  const chatId =
    await contentChatId();

  if (!chatId) {
    return {
      configured: false,
      sent: false,
      reason: "content-hq-not-configured",
    };
  }

  const sql =
    sqlClient();

  const min =
    tier === "momentum" ? 1 :
    tier === "breakout" ? 3 :
    tier === "surge" ? 5 :
    tier === "apex" ? 10 :
    tier === "legend" ? 20 :
    tier === "titan" ? 50 :
    100;

  const max =
    tier === "momentum" ? 3 :
    tier === "breakout" ? 5 :
    tier === "surge" ? 10 :
    tier === "apex" ? 20 :
    tier === "legend" ? 50 :
    tier === "titan" ? 100 :
    null;

  const rows =
    max === null
      ? await sql`
          SELECT
            signal_record_id,
            public_id,
            symbol,
            called_at,
            call_market_cap_usd,
            peak_market_cap_usd,
            peak_multiple
          FROM memescope_call_story
          WHERE COALESCE(
            peak_multiple,
            1
          ) >= ${min}
          ORDER BY
            called_at DESC
          LIMIT 1
        `
      : await sql`
          SELECT
            signal_record_id,
            public_id,
            symbol,
            called_at,
            call_market_cap_usd,
            peak_market_cap_usd,
            peak_multiple
          FROM memescope_call_story
          WHERE COALESCE(
            peak_multiple,
            1
          ) >= ${min}
            AND COALESCE(
              peak_multiple,
              1
            ) < ${max}
          ORDER BY
            called_at DESC
          LIMIT 1
        `;

  if (!rows.length) {
    return {
      configured: true,
      sent: false,
      reason: `no-real-${tier}-call`,
    };
  }

  const call =
    normalizeCall(
      rows[0] as DbRow,
    );

  const message =
    await sendCallDraft(
      chatId,
      call,
      false,
    );

  return {
    configured: true,
    sent: true,
    tier,
    symbol: call.symbol,
    publicId: call.publicId,
    callMarketCapUsd:
      call.callMarketCapUsd,
    peakMarketCapUsd:
      call.peakMarketCapUsd,
    peakMultiple:
      call.peakMultiple,
    messageId:
      message.message_id,
  };
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
  const base =
    await background(
      "legend",
    );

  const rowHtml =
    rows
      .slice(
        0,
        5,
      )
      .map(
        (
          row,
          index,
        ) => {
          const gain =
            Math.max(
              0,
              (
                row.peakMultiple -
                1
              ) * 100,
            );

          const y =
            245 +
            index * 118;

          return [
            `<rect x="95" y="${y - 48}" width="1410" height="96" rx="18" fill="#06100c" opacity=".87" stroke="#41534d"/>`,
            contentPixelText(
              String(index + 1),
              125,
              y - 12,
              4,
              index === 0
                ? "#ffd167"
                : "#87958f",
            ),
            contentPixelText(
              `$${row.symbol
                .toUpperCase()
                .replace(
                  /[^A-Z0-9]/g,
                  "",
                )
                .slice(
                  0,
                  12,
                )}`,
              205,
              y - 12,
              4,
              "#f2f6f4",
            ),
            contentPixelText(
              `+${gain.toFixed(0)}%`,
              850,
              y - 12,
              4,
              "#75efad",
              {
                anchor: "end",
              },
            ),
            contentPixelText(
              `${usd(row.callMarketCapUsd)} > ${usd(row.peakMarketCapUsd)}`,
              895,
              y - 6,
              3,
              "#9caaa5",
            ),
          ].join("");
        },
      )
      .join("");

  const svg =
    `<svg width="1600" height="900" xmlns="http://www.w3.org/2000/svg">
      <rect width="1600" height="900" fill="#010302" opacity=".28"/>
      ${contentPixelText("MEMESCOPE", 100, 80, 5, "#f2f6f4")}
      ${contentPixelText("LAST 72 HOURS", 100, 132, 7, "#cfa1ff")}
      ${contentPixelText("", 1460, 148, 4, "#91a09b", { anchor: "end" })}
      ${rowHtml}
      ${contentPixelText("ROLLING 72H WINDOW / TRACKED CALL PERFORMANCE", 100, 810, 3, "#73827d")}
    </svg>`;

  return sharp(base)
    .composite([
      {
        input:
          Buffer.from(
            svg,
          ),
      },
    ])
    .webp({
      quality:
        94,
    })
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
