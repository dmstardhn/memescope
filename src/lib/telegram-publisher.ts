import "server-only";

import {
  neon,
} from "@neondatabase/serverless";

import {
  escapeTelegramHtml,
  telegramConfig,
  telegramConfigured,
  telegramEditMessage,
  telegramSendMessage,
  telegramSiteUrl,
} from "@/lib/telegram";

type DbRow = Record<
  string,
  unknown
>;

type SignalRecord = {
  id: string;
  signalId: string;
  tokenAddress: string;
  symbol: string;
  name: string;
  label: string;
  openedAt: number;
  closedAt: number | null;
  entryPriceUsd: number | null;
  currentPriceUsd: number | null;
  targetPercent: number;
  targetPriceUsd: number | null;
  planReason: string;
  scoreAtEntry: number;
  lastScore: number;
  status:
    | "active"
    | "target_hit"
    | "stop_loss";
  currentGainPercent: number | null;
  peakGainPercent: number | null;
  maxDrawdownPercent: number | null;
};

let schemaPromise:
  | Promise<void>
  | null = null;

function sqlClient() {
  const databaseUrl =
    process.env.DATABASE_URL?.trim();

  if (!databaseUrl) {
    throw new Error(
      "DATABASE_URL is not configured.",
    );
  }

  return neon(databaseUrl);
}

function num(
  value: unknown,
  fallback = 0,
) {
  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : fallback;
}

function numOrNull(
  value: unknown,
) {
  if (
    value === null ||
    value === undefined
  ) {
    return null;
  }

  const parsed = Number(value);

  return Number.isFinite(parsed)
    ? parsed
    : null;
}

function millis(
  value: unknown,
) {
  if (value instanceof Date) {
    return value.getTime();
  }

  const parsed =
    Date.parse(String(value));

  return Number.isFinite(parsed)
    ? parsed
    : Date.now();
}

function nullableMillis(
  value: unknown,
) {
  if (
    value === null ||
    value === undefined
  ) {
    return null;
  }

  return millis(value);
}

function normalizeRecord(
  row: DbRow,
): SignalRecord {
  const rawStatus =
    String(
      row.status ?? "active",
    );

  const status:
    SignalRecord["status"] =
    rawStatus === "target_hit" ||
    rawStatus === "stop_loss"
      ? rawStatus
      : "active";

  return {
    id: String(row.id),
    signalId:
      String(row.signal_id),
    tokenAddress:
      String(row.token_address),
    symbol:
      String(row.symbol),
    name:
      String(row.name),
    label:
      String(row.label),
    openedAt:
      millis(row.opened_at),
    closedAt:
      nullableMillis(
        row.closed_at,
      ),
    entryPriceUsd:
      numOrNull(
        row.entry_price_usd,
      ),
    currentPriceUsd:
      numOrNull(
        row.current_price_usd,
      ),
    targetPercent:
      num(row.target_pct),
    targetPriceUsd:
      numOrNull(
        row.target_price_usd,
      ),
    planReason:
      String(
        row.plan_reason ?? "",
      ),
    scoreAtEntry:
      num(row.score_at_entry),
    lastScore:
      num(row.last_score),
    status,
    currentGainPercent:
      numOrNull(
        row.current_gain_pct,
      ),
    peakGainPercent:
      numOrNull(
        row.peak_gain_pct,
      ),
    maxDrawdownPercent:
      numOrNull(
        row.max_drawdown_pct,
      ),
  };
}

function money(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  if (value >= 1) {
    return `$${value.toFixed(4)}`;
  }

  return `$${value.toPrecision(6)}`;
}

function pct(
  value: number | null,
) {
  if (
    value === null ||
    !Number.isFinite(value)
  ) {
    return "N/A";
  }

  return `${
    value > 0 ? "+" : ""
  }${value.toFixed(2)}%`;
}

function holdText(
  openedAt: number,
  closedAt: number | null,
) {
  const elapsed =
    Math.max(
      0,
      (closedAt ??
        Date.now()) -
        openedAt,
    ) / 60_000;

  if (elapsed < 60) {
    return `${Math.round(
      elapsed,
    )}m`;
  }

  const hours =
    elapsed / 60;

  if (hours < 24) {
    return `${hours.toFixed(
      1,
    )}h`;
  }

  return `${(
    hours / 24
  ).toFixed(1)}d`;
}

function signalButtons(
  record: SignalRecord,
) {
  const site =
    telegramSiteUrl();

  return {
    inline_keyboard: [
      [
        {
          text:
            "🛡 Analyze Risk",
          url:
            `${site}/token/` +
            encodeURIComponent(
              record.tokenAddress,
            ),
        },
        {
          text:
            "📊 DexScreener",
          url:
            "https://dexscreener.com/solana/" +
            encodeURIComponent(
              record.tokenAddress,
            ),
        },
      ],
      [
        {
          text:
            "🔎 Solscan",
          url:
            "https://solscan.io/token/" +
            encodeURIComponent(
              record.tokenAddress,
            ),
        },
        {
          text:
            "🌐 MemeScope",
          url: site,
        },
      ],
    ],
  };
}

function channelText(
  record: SignalRecord,
) {
  const targetHit =
    record.status ===
    "target_hit";

  const title =
    targetHit
      ? "✅ MEMESCOPE TARGET HIT"
      : "🔥 MEMESCOPE HQ SIGNAL";

  const status =
    targetHit
      ? "TARGET HIT"
      : "ACTIVE";

  const reason =
    record.planReason
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 750);

  return [
    `<b>${title}</b>`,
    "",
    `<b>$${escapeTelegramHtml(
      record.symbol,
    )}</b> — ${escapeTelegramHtml(
      record.name,
    )}`,
    "",
    `Quality Score: <b>${Math.round(
      record.scoreAtEntry,
    )}/100</b>`,
    `Entry: <b>${money(
      record.entryPriceUsd,
    )}</b>`,
    `Current: <b>${money(
      record.currentPriceUsd,
    )}</b>`,
    `Potential TP: <b>+${record.targetPercent.toFixed(
      1,
    )}%</b>`,
    record.targetPriceUsd ===
    null
      ? null
      : `TP Price: <b>${money(
          record.targetPriceUsd,
        )}</b>`,
    "",
    `Current Gain: <b>${pct(
      record.currentGainPercent,
    )}</b>`,
    `Maximum Gain: <b>${pct(
      record.peakGainPercent,
    )}</b>`,
    `Maximum Drawdown: <b>${pct(
      record.maxDrawdownPercent,
    )}</b>`,
    `Hold: <b>${holdText(
      record.openedAt,
      record.closedAt,
    )}</b>`,
    `Status: <b>${status}</b>`,
    "",
    reason
      ? `<b>Why it passed</b>\n${escapeTelegramHtml(
          reason,
        )}`
      : null,
    "",
    "<b>Contract Address</b>",
    `<code>${escapeTelegramHtml(
      record.tokenAddress,
    )}</code>`,
    "",
    "<i>Potential TP is a heuristic estimate from the confirmed setup, not a guaranteed future return.</i>",
  ]
    .filter(
      (
        value,
      ): value is string =>
        value !== null,
    )
    .join("\n");
}

function targetReply(
  record: SignalRecord,
) {
  return [
    `🎯 <b>TARGET HIT — $${escapeTelegramHtml(
      record.symbol,
    )}</b>`,
    "",
    `Potential TP: <b>+${record.targetPercent.toFixed(
      1,
    )}%</b>`,
    `Observed Gain: <b>${pct(
      record.currentGainPercent,
    )}</b>`,
    `Maximum Gain: <b>${pct(
      record.peakGainPercent,
    )}</b>`,
    `Maximum Drawdown: <b>${pct(
      record.maxDrawdownPercent,
    )}</b>`,
    `Hold: <b>${holdText(
      record.openedAt,
      record.closedAt,
    )}</b>`,
  ].join("\n");
}

export async function ensureTelegramPublisherSchema() {
  if (schemaPromise) {
    return schemaPromise;
  }

  schemaPromise =
    (async () => {
      const sql =
        sqlClient();

      await sql`
        CREATE TABLE IF NOT EXISTS memescope_telegram_state (
          id INTEGER PRIMARY KEY,
          initialized_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      `;

      await sql`
        CREATE TABLE IF NOT EXISTS memescope_telegram_posts (
          signal_record_id TEXT PRIMARY KEY,
          signal_id TEXT NOT NULL,
          channel_id TEXT NOT NULL,
          message_id BIGINT,
          baseline BOOLEAN NOT NULL DEFAULT FALSE,
          first_sent_at TIMESTAMPTZ,
          last_edited_at TIMESTAMPTZ,
          target_notified_at TIMESTAMPTZ,
          last_status TEXT NOT NULL DEFAULT 'active',
          last_current_gain_pct DOUBLE PRECISION,
          last_peak_gain_pct DOUBLE PRECISION,
          last_drawdown_pct DOUBLE PRECISION,
          created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      `;

      await sql`
        CREATE INDEX IF NOT EXISTS memescope_telegram_signal_idx
        ON memescope_telegram_posts (signal_id)
      `;
    })().catch(
      (error) => {
        schemaPromise = null;
        throw error;
      },
    );

  return schemaPromise;
}

export async function initializeTelegramBaseline() {
  await ensureTelegramPublisherSchema();

  const sql =
    sqlClient();

  const current =
    await sql`
      SELECT initialized_at
      FROM memescope_telegram_state
      WHERE id = 1
      LIMIT 1
    `;

  if (current[0]) {
    return {
      initialized: false,
      baselineCount: 0,
      initializedAt:
        millis(
          (
            current[0] as DbRow
          ).initialized_at,
        ),
    };
  }

  const now =
    new Date();

  await sql`
    INSERT INTO memescope_telegram_state (
      id,
      initialized_at
    )
    VALUES (
      1,
      ${now.toISOString()}
    )
    ON CONFLICT (id)
    DO NOTHING
  `;

  const { channelId } =
    telegramConfig();

  const baselineRows =
    await sql`
      SELECT id, signal_id, status
      FROM memescope_signal_records
      WHERE opened_at <= ${now.toISOString()}
    `;

  for (
    const raw of baselineRows
  ) {
    const row =
      raw as DbRow;

    await sql`
      INSERT INTO memescope_telegram_posts (
        signal_record_id,
        signal_id,
        channel_id,
        baseline,
        last_status
      )
      VALUES (
        ${String(row.id)},
        ${String(
          row.signal_id,
        )},
        ${channelId},
        TRUE,
        ${String(
          row.status ??
            "active",
        )}
      )
      ON CONFLICT (
        signal_record_id
      )
      DO NOTHING
    `;
  }

  return {
    initialized: true,
    baselineCount:
      baselineRows.length,
    initializedAt:
      now.getTime(),
  };
}

export async function publishPendingTelegramSignals() {
  if (!telegramConfigured()) {
    return {
      configured: false,
      initialized: false,
      sent: 0,
      edited: 0,
      targetReplies: 0,
    };
  }

  await ensureTelegramPublisherSchema();

  const baseline =
    await initializeTelegramBaseline();

  if (baseline.initialized) {
    return {
      configured: true,
      initialized: true,
      baselineCount:
        baseline.baselineCount,
      sent: 0,
      edited: 0,
      targetReplies: 0,
    };
  }

  const sql =
    sqlClient();

  const { channelId } =
    telegramConfig();

  const rows =
    await sql`
      SELECT
        r.*,
        p.message_id AS telegram_message_id,
        p.last_edited_at AS telegram_last_edited_at,
        p.target_notified_at AS telegram_target_notified_at,
        p.last_status AS telegram_last_status,
        p.last_current_gain_pct AS telegram_last_current_gain_pct,
        p.last_peak_gain_pct AS telegram_last_peak_gain_pct,
        p.last_drawdown_pct AS telegram_last_drawdown_pct
      FROM memescope_signal_records r
      LEFT JOIN memescope_telegram_posts p
        ON p.signal_record_id = r.id
      WHERE r.opened_at > ${new Date(
        baseline.initializedAt,
      ).toISOString()}
      ORDER BY r.opened_at ASC
      LIMIT 150
    `;

  let sent = 0;
  let edited = 0;
  let targetReplies = 0;

  for (const raw of rows) {
    const row =
      raw as DbRow;

    const record =
      normalizeRecord(row);

    const messageId =
      numOrNull(
        row.telegram_message_id,
      );

    if (messageId === null) {
      const message =
        await telegramSendMessage(
          channelId,
          channelText(record),
          {
            replyMarkup:
              signalButtons(
                record,
              ),
          },
        );

      await sql`
        INSERT INTO memescope_telegram_posts (
          signal_record_id,
          signal_id,
          channel_id,
          message_id,
          baseline,
          first_sent_at,
          last_edited_at,
          last_status,
          last_current_gain_pct,
          last_peak_gain_pct,
          last_drawdown_pct
        )
        VALUES (
          ${record.id},
          ${record.signalId},
          ${channelId},
          ${message.message_id},
          FALSE,
          NOW(),
          NOW(),
          ${record.status},
          ${record.currentGainPercent},
          ${record.peakGainPercent},
          ${record.maxDrawdownPercent}
        )
        ON CONFLICT (
          signal_record_id
        )
        DO UPDATE SET
          message_id = EXCLUDED.message_id,
          channel_id = EXCLUDED.channel_id,
          first_sent_at = COALESCE(
            memescope_telegram_posts.first_sent_at,
            NOW()
          ),
          last_edited_at = NOW(),
          last_status = EXCLUDED.last_status,
          last_current_gain_pct = EXCLUDED.last_current_gain_pct,
          last_peak_gain_pct = EXCLUDED.last_peak_gain_pct,
          last_drawdown_pct = EXCLUDED.last_drawdown_pct
      `;

      sent += 1;

      if (
        record.status ===
        "target_hit"
      ) {
        await telegramSendMessage(
          channelId,
          targetReply(record),
          {
            replyToMessageId:
              message.message_id,
          },
        );

        await sql`
          UPDATE memescope_telegram_posts
          SET target_notified_at = NOW()
          WHERE signal_record_id = ${record.id}
        `;

        targetReplies += 1;
      }

      continue;
    }

    const previousStatus =
      String(
        row.telegram_last_status ??
          "active",
      );

    const targetNotified =
      row.telegram_target_notified_at !==
        null &&
      row.telegram_target_notified_at !==
        undefined;

    const lastEdited =
      row.telegram_last_edited_at
        ? millis(
            row.telegram_last_edited_at,
          )
        : 0;

    const currentChanged =
      Math.abs(
        (record.currentGainPercent ??
          0) -
          num(
            row.telegram_last_current_gain_pct,
          ),
      ) >= 1;

    const peakChanged =
      Math.abs(
        (record.peakGainPercent ??
          0) -
          num(
            row.telegram_last_peak_gain_pct,
          ),
      ) >= 1;

    const drawdownChanged =
      Math.abs(
        (record.maxDrawdownPercent ??
          0) -
          num(
            row.telegram_last_drawdown_pct,
          ),
      ) >= 1;

    const statusChanged =
      previousStatus !==
      record.status;

    const editDue =
      statusChanged ||
      (Date.now() -
        lastEdited >=
        60_000 &&
        (currentChanged ||
          peakChanged ||
          drawdownChanged));

    if (editDue) {
      await telegramEditMessage(
        channelId,
        messageId,
        channelText(record),
        signalButtons(record),
      );

      await sql`
        UPDATE memescope_telegram_posts
        SET
          last_edited_at = NOW(),
          last_status = ${record.status},
          last_current_gain_pct = ${record.currentGainPercent},
          last_peak_gain_pct = ${record.peakGainPercent},
          last_drawdown_pct = ${record.maxDrawdownPercent}
        WHERE signal_record_id = ${record.id}
      `;

      edited += 1;
    }

    if (
      record.status ===
        "target_hit" &&
      !targetNotified
    ) {
      await telegramSendMessage(
        channelId,
        targetReply(record),
        {
          replyToMessageId:
            messageId,
        },
      );

      await sql`
        UPDATE memescope_telegram_posts
        SET target_notified_at = NOW()
        WHERE signal_record_id = ${record.id}
      `;

      targetReplies += 1;
    }
  }

  return {
    configured: true,
    initialized: false,
    sent,
    edited,
    targetReplies,
  };
}
