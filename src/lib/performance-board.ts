import "server-only";

import {
  neon,
} from "@neondatabase/serverless";

type DbRow =
  Record<string, unknown>;

type BoardRow = {
  signalRecordId: string;
  tokenAddress: string;
  symbol: string;
  calledAt: string;
  callMarketCapUsd: number | null;
  peakMarketCapUsd: number | null;
  peakMultiple: number;
};

let schemaPromise:
  Promise<void> | null = null;

function sqlClient() {
  const url =
    process.env.DATABASE_URL?.trim();

  if (!url) {
    throw new Error(
      "DATABASE_URL is not configured.",
    );
  }

  return neon(url);
}

function botToken() {
  return (
    process.env
      .TELEGRAM_BOT_TOKEN
      ?.trim() ?? ""
  );
}

function siteUrl() {
  const direct =
    process.env
      .NEXT_PUBLIC_SITE_URL
      ?.trim()
      .replace(/\/+$/, "");

  if (direct) {
    return direct;
  }

  const production =
    process.env
      .VERCEL_PROJECT_PRODUCTION_URL
      ?.trim()
      .replace(/\/+$/, "");

  if (production) {
    return production.startsWith("http")
      ? production
      : `https://${production}`;
  }

  return "https://memescopes.vercel.app";
}

function html(
  value: unknown,
) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function numOrNull(
  value: unknown,
) {
  if (
    value === null ||
    value === undefined ||
    value === ""
  ) {
    return null;
  }

  const parsed =
    Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : null;
}

function compactUsd(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1_000_000_000) {
    return `$${(
      value / 1_000_000_000
    ).toFixed(2)}B`;
  }

  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(2)}M`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(
      value >= 100_000
        ? 0
        : 1,
    )}K`;
  }

  return `$${value.toFixed(0)}`;
}

function gainPercent(
  multiple: number,
) {
  return Math.max(
    0,
    (multiple - 1) * 100,
  );
}

function pctText(
  multiple: number,
) {
  const value =
    gainPercent(multiple);

  return `+${value.toLocaleString(
    "en-US",
    {
      maximumFractionDigits:
        value >= 1000 ? 0 : 1,
      minimumFractionDigits: 0,
    },
  )}%`;
}

function ageText(
  calledAt: string,
) {
  const timestamp =
    new Date(calledAt)
      .getTime();

  if (
    !Number.isFinite(timestamp)
  ) {
    return "N/A";
  }

  const minutes =
    Math.max(
      0,
      Math.floor(
        (Date.now() -
          timestamp) /
          60_000,
      ),
    );

  if (minutes < 60) {
    return `${minutes}m ago`;
  }

  return `${Math.floor(
    minutes / 60,
  )}h ago`;
}

function tokenUrl(
  tokenAddress: string,
) {
  return `${siteUrl()}/token/${encodeURIComponent(
    tokenAddress,
  )}`;
}

function medal(
  index: number,
) {
  if (index === 0) return "🥇";
  if (index === 1) return "🥈";
  if (index === 2) return "🥉";
  return "🟢";
}

function normalizeRow(
  row: DbRow,
): BoardRow {
  return {
    signalRecordId:
      String(
        row.signal_record_id ??
          "",
      ),
    tokenAddress:
      String(
        row.token_address ??
          "",
      ),
    symbol:
      String(
        row.symbol ??
          "UNKNOWN",
      ),
    calledAt:
      String(
        row.called_at ??
          "",
      ),
    callMarketCapUsd:
      numOrNull(
        row.call_market_cap_usd,
      ),
    peakMarketCapUsd:
      numOrNull(
        row.peak_market_cap_usd,
      ),
    peakMultiple:
      Math.max(
        1,
        Number(
          row.peak_multiple ??
            1,
        ) || 1,
      ),
  };
}

async function ensureSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise =
    (async () => {
      const sql =
        sqlClient();

      await sql`
        CREATE TABLE IF NOT EXISTS memescope_performance_board_state (
          channel_key TEXT PRIMARY KEY,
          chat_id TEXT NOT NULL,
          message_id BIGINT,
          last_success_at TIMESTAMPTZ,
          updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      `;

      await sql`
        CREATE TABLE IF NOT EXISTS memescope_performance_board_meta (
          id INTEGER PRIMARY KEY,
          last_run_at TIMESTAMPTZ NOT NULL DEFAULT TO_TIMESTAMP(0)
        )
      `;

      await sql`
        INSERT INTO memescope_performance_board_meta (
          id,
          last_run_at
        ) VALUES (
          1,
          TO_TIMESTAMP(0)
        )
        ON CONFLICT (id)
        DO NOTHING
      `;
    })().catch(
      (error) => {
        schemaPromise = null;
        throw error;
      },
    );

  return schemaPromise;
}

async function claimFiveMinuteSlot() {
  await ensureSchema();

  const sql =
    sqlClient();

  const rows =
    await sql`
      UPDATE memescope_performance_board_meta
      SET last_run_at = NOW()
      WHERE id = 1
        AND last_run_at <=
          NOW() - INTERVAL '4 minutes 30 seconds'
      RETURNING id
    `;

  return rows.length > 0;
}

async function loadBoardRows() {
  await ensureSchema();

  const sql =
    sqlClient();

  const rows =
    await sql`
      SELECT
        c.signal_record_id,
        c.token_address,
        c.symbol,
        c.called_at,
        c.call_market_cap_usd,
        c.peak_market_cap_usd,
        c.peak_multiple
      FROM memescope_call_story c
      WHERE
        c.called_at >=
          NOW() - INTERVAL '72 hours'
        AND COALESCE(
          c.baseline,
          FALSE
        ) = FALSE
        AND EXISTS (
          SELECT 1
          FROM memescope_telegram_posts p
          WHERE
            p.signal_record_id =
              c.signal_record_id
        )
      ORDER BY
        COALESCE(
          c.peak_multiple,
          1
        ) DESC,
        c.called_at DESC
      LIMIT 15
    `;

  const countRows =
    await sql`
      SELECT
        COUNT(*)::integer AS count
      FROM memescope_call_story c
      WHERE
        c.called_at >=
          NOW() - INTERVAL '72 hours'
        AND COALESCE(
          c.baseline,
          FALSE
        ) = FALSE
        AND EXISTS (
          SELECT 1
          FROM memescope_telegram_posts p
          WHERE
            p.signal_record_id =
              c.signal_record_id
        )
    `;

  return {
    rows:
      rows.map(
        (row: unknown) =>
          normalizeRow(
            row as DbRow,
          ),
      ),
    totalCalls:
      Number(
        (
          countRows[0] as
            | DbRow
            | undefined
        )?.count ?? 0,
      ),
  };
}

function boardText(
  rows: BoardRow[],
  totalCalls: number,
) {
  const parts = [
    "🔥 <b>MEMESCOPE — LAST 72 HRS</b>",
    "",
  ];

  if (rows.length === 0) {
    parts.push(
      "No published calls in the last 72 hours yet.",
    );
  } else {
    rows.forEach(
      (
        row,
        index,
      ) => {
        const url =
          tokenUrl(
            row.tokenAddress,
          );

        parts.push(
          `${medal(
            index,
          )} <a href="${html(
            url,
          )}">$${html(
            row.symbol,
          )}</a>  <b>${pctText(
            row.peakMultiple,
          )}</b>`,
        );

        parts.push(
          `   └ ${compactUsd(
            row.callMarketCapUsd,
          )} → ${compactUsd(
            row.peakMarketCapUsd,
          )} · ${ageText(
            row.calledAt,
          )}`,
        );

        if (
          index !==
          rows.length - 1
        ) {
          parts.push("");
        }
      },
    );
  }

  const utc =
    new Intl.DateTimeFormat(
      "en-GB",
      {
        timeZone: "UTC",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      },
    ).format(new Date());

  parts.push(
    "",
    `📊 Published calls in window: <b>${totalCalls}</b>`,
    `⚡ Last update: <b>${utc} UTC</b>`,
    "🔄 Updates every 5 minutes",
    "",
    "<i>Ranked by actual post-call peak. Percentages are historical peak performance, not future returns.</i>",
  );

  return parts.join("\n");
}

async function telegramApi(
  method: string,
  payload: Record<
    string,
    unknown
  >,
) {
  const token =
    botToken();

  if (!token) {
    throw new Error(
      "TELEGRAM_BOT_TOKEN is not configured.",
    );
  }

  const response =
    await fetch(
      `https://api.telegram.org/bot${token}/${method}`,
      {
        method: "POST",
        headers: {
          "content-type":
            "application/json",
        },
        body:
          JSON.stringify(
            payload,
          ),
        cache:
          "no-store",
      },
    );

  const body =
    (await response.json()) as {
      ok?: boolean;
      result?: unknown;
      description?: string;
    };

  if (
    !response.ok ||
    !body.ok
  ) {
    throw new Error(
      body.description ??
        `Telegram ${method} failed.`,
    );
  }

  return body.result;
}

async function stateFor(
  channelKey: string,
) {
  const sql =
    sqlClient();

  const rows =
    await sql`
      SELECT *
      FROM memescope_performance_board_state
      WHERE channel_key =
        ${channelKey}
      LIMIT 1
    `;

  return rows[0]
    ? (rows[0] as DbRow)
    : null;
}

async function saveState(
  channelKey: string,
  chatId: string,
  messageId: number,
) {
  const sql =
    sqlClient();

  await sql`
    INSERT INTO memescope_performance_board_state (
      channel_key,
      chat_id,
      message_id,
      last_success_at,
      updated_at
    ) VALUES (
      ${channelKey},
      ${chatId},
      ${messageId},
      NOW(),
      NOW()
    )
    ON CONFLICT (
      channel_key
    )
    DO UPDATE SET
      chat_id =
        EXCLUDED.chat_id,
      message_id =
        EXCLUDED.message_id,
      last_success_at =
        NOW(),
      updated_at =
        NOW()
  `;
}

async function touchState(
  channelKey: string,
) {
  const sql =
    sqlClient();

  await sql`
    UPDATE memescope_performance_board_state
    SET
      last_success_at =
        NOW(),
      updated_at =
        NOW()
    WHERE channel_key =
      ${channelKey}
  `;
}

async function publishBoard(
  channelKey:
    | "vip"
    | "free",
  chatId: string,
  text: string,
) {
  const state =
    await stateFor(
      channelKey,
    );

  const oldMessageId =
    numOrNull(
      state?.message_id,
    );

  if (oldMessageId) {
    try {
      await telegramApi(
        "editMessageText",
        {
          chat_id:
            chatId,
          message_id:
            oldMessageId,
          text,
          parse_mode:
            "HTML",
          disable_web_page_preview:
            true,
        },
      );

      await touchState(
        channelKey,
      );

      return {
        action: "edited",
        messageId:
          oldMessageId,
      };
    } catch (error) {
      const message =
        error instanceof Error
          ? error.message
          : "";

      if (
        message
          .toLowerCase()
          .includes(
            "message is not modified",
          )
      ) {
        await touchState(
          channelKey,
        );

        return {
          action:
            "unchanged",
          messageId:
            oldMessageId,
        };
      }

      console.error(
        `MemeScope ${channelKey} performance board edit failed; recreating:`,
        error,
      );
    }
  }

  const result =
    (await telegramApi(
      "sendMessage",
      {
        chat_id:
          chatId,
        text,
        parse_mode:
          "HTML",
        disable_web_page_preview:
          true,
        disable_notification:
          true,
      },
    )) as {
      message_id?: number;
    };

  const messageId =
    Number(
      result?.message_id ??
        0,
    );

  if (!messageId) {
    throw new Error(
      `Telegram ${channelKey} performance board did not return a message_id.`,
    );
  }

  await saveState(
    channelKey,
    chatId,
    messageId,
  );

  try {
    await telegramApi(
      "pinChatMessage",
      {
        chat_id:
          chatId,
        message_id:
          messageId,
        disable_notification:
          true,
      },
    );
  } catch (error) {
    console.error(
      `MemeScope ${channelKey} performance board pin failed. Give the bot permission to pin/edit channel messages:`,
      error,
    );
  }

  return {
    action: "created",
    messageId,
  };
}

export async function updatePerformanceBoards(
  options?: {
    force?: boolean;
  },
) {
  const vipChannel =
    process.env
      .TELEGRAM_CHANNEL_ID
      ?.trim() ?? "";

  const freeChannel =
    process.env
      .TELEGRAM_FREE_CHANNEL_ID
      ?.trim() ?? "";

  if (!botToken()) {
    return {
      configured:
        false,
      reason:
        "TELEGRAM_BOT_TOKEN missing",
    };
  }

  if (
    !vipChannel &&
    !freeChannel
  ) {
    return {
      configured:
        false,
      reason:
        "No Telegram channel IDs configured",
    };
  }

  if (!options?.force) {
    const claimed =
      await claimFiveMinuteSlot();

    if (!claimed) {
      return {
        configured:
          true,
        skipped:
          true,
      };
    }
  } else {
    await ensureSchema();
  }

  const data =
    await loadBoardRows();

  const text =
    boardText(
      data.rows,
      data.totalCalls,
    );

  const result: Record<
    string,
    unknown
  > = {
    configured: true,
    skipped: false,
    rows:
      data.rows.length,
    totalCalls:
      data.totalCalls,
  };

  if (vipChannel) {
    result.vip =
      await publishBoard(
        "vip",
        vipChannel,
        text,
      );
  }

  if (
    freeChannel &&
    freeChannel !==
      vipChannel
  ) {
    result.free =
      await publishBoard(
        "free",
        freeChannel,
        text,
      );
  }

  return result;
}
